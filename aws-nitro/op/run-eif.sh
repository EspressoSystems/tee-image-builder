#!/bin/sh
#
# Run the pre-built EIF for the op-batcher.
#
# This script is the ENTRYPOINT of the op-batcher-eif image produced by the
# build-eif workflow.  The EIF is baked in at /enclave/application.eif by
# enclaver; this script assembles the batcher arguments from environment
# variables and delivers them to the enclave via enclaver-run.
#
# The outer image is scratch-based (enclaver v0.5.0) so this script must be
# POSIX sh and rely only on busybox (installed alongside it in build-eif.yml).
#
# run-enclave.sh — builds EIF from source, registers PCR0, then runs (local/dev)
# run-eif.sh     — starts enclaver-run against baked-in EIF (production/infra repo)

set -e

# Validate committed-params.json is present (baked into this image at build time).
# This file is sent to the enclave so it can validate the committed config hash.
COMMITTED_PARAMS_FILE="/committed-params.json"
if [ ! -f "$COMMITTED_PARAMS_FILE" ]; then
    echo "ERROR: $COMMITTED_PARAMS_FILE not found — image was not built correctly"
    exit 1
fi
COMMITTED_PARAMS_JSON=$(cat "$COMMITTED_PARAMS_FILE")
echo "Committed params loaded from ${COMMITTED_PARAMS_FILE}"

# Required environment variables
: ${L1_RPC_URL:?Error: L1_RPC_URL is required}
: ${L2_RPC_URL:?Error: L2_RPC_URL is required}
: ${ROLLUP_RPC_URL:?Error: ROLLUP_RPC_URL is required}
: ${ESPRESSO_URL1:?Error: ESPRESSO_URL1 is required}
: ${ESPRESSO_ATTESTATION_SERVICE_URL:?Error: ESPRESSO_ATTESTATION_SERVICE_URL is required}
: ${EIGENDA_PROXY_URL:?Error: EIGENDA_PROXY_URL is required}

# Authentication: either a remote signer (SIGNER_ENDPOINT + SIGNER_ADDRESS) or a
# plaintext private key (OP_BATCHER_PRIVATE_KEY). Remote signer takes precedence
# when both are set.
if [ -n "${SIGNER_ENDPOINT:-}" ] || [ -n "${SIGNER_ADDRESS:-}" ]; then
    : ${SIGNER_ENDPOINT:?Error: SIGNER_ENDPOINT is required when SIGNER_ADDRESS is set}
    : ${SIGNER_ADDRESS:?Error: SIGNER_ADDRESS is required when SIGNER_ENDPOINT is set}
elif [ -z "${OP_BATCHER_PRIVATE_KEY:-}" ]; then
    echo "Error: set either SIGNER_ENDPOINT + SIGNER_ADDRESS (remote signer) or OP_BATCHER_PRIVATE_KEY (plaintext)" >&2
    exit 1
fi

ESPRESSO_URL2="${ESPRESSO_URL2:-$ESPRESSO_URL1}"
ENCLAVE_DEBUG="${ENCLAVE_DEBUG:-false}"

echo "=== Enclave Batcher Configuration ==="
echo "L1 RPC URL: $L1_RPC_URL"
echo "L2 RPC URL: $L2_RPC_URL"
echo "Rollup RPC URL: $ROLLUP_RPC_URL"
echo "Espresso URLs: $ESPRESSO_URL1, $ESPRESSO_URL2"
echo "Attestation Service URL: $ESPRESSO_ATTESTATION_SERVICE_URL"
echo "EigenDA Proxy URL: $EIGENDA_PROXY_URL"
if [ -n "${SIGNER_ENDPOINT:-}" ]; then
    echo "Auth: remote signer at $SIGNER_ENDPOINT (address $SIGNER_ADDRESS, tls=${SIGNER_TLS_ENABLED:-false})"
else
    echo "Auth: plaintext private key"
fi
echo "Extra Args: $EXTRA_ARGS"
echo "Debug Mode: $ENCLAVE_DEBUG"
echo "====================================="

# Send batcher args as a NUL-separated stream.
# Protocol matches enclave-entrypoint.bash: each arg is NUL-terminated;
# a second consecutive NUL (empty string) signals end-of-args.
# NOTE: private key is not logged here — enclave-entrypoint.bash redacts it.
send_batcher_args() {
    # TODO: add "--committed-params-json=${COMMITTED_PARAMS_JSON}" once
    # op-batcher registers that flag upstream (optimism-espresso-integration).

    # Required endpoints and secrets
    printf '%s\0' \
        "--l1-eth-rpc=$L1_RPC_URL" \
        "--l2-eth-rpc=$L2_RPC_URL" \
        "--rollup-rpc=$ROLLUP_RPC_URL" \
        "--espresso.enabled=true" \
        "--espresso.urls=$ESPRESSO_URL1" \
        "--espresso.urls=$ESPRESSO_URL2" \
        "--espresso.espresso-attestation-service=$ESPRESSO_ATTESTATION_SERVICE_URL" \
        "--altda.enabled=true" \
        "--altda.da-server=$EIGENDA_PROXY_URL"

    # Auth flags: remote signer takes precedence over plaintext key.
    if [ -n "${SIGNER_ENDPOINT:-}" ]; then
        printf '%s\0' \
            "--signer.endpoint=$SIGNER_ENDPOINT" \
            "--signer.address=$SIGNER_ADDRESS" \
            "--signer.tls.enabled=${SIGNER_TLS_ENABLED:-false}"
    else
        printf '%s\0' "--private-key=$OP_BATCHER_PRIVATE_KEY"
    fi

    # Extra args — runtime tuning, new flags, anything not committed
    # Pass as space-separated flags, e.g. "--poll-interval=1s --num-confirmations=8"
    if [ -n "$EXTRA_ARGS" ]; then
        set -f
        for arg in $EXTRA_ARGS; do
            printf '%s\0' "$arg"
        done
        set +f
    fi

    if [ "$ENCLAVE_DEBUG" = "true" ]; then
        printf '%s\0' "--log.level=debug"
        echo "Debug logging enabled" >&2
    fi
    printf '\0'  # double-NUL terminator
}

# ---------------------------------------------------------------------------
# Enclave lifecycle helpers
# ---------------------------------------------------------------------------

# List IDs of all running Nitro enclaves (one per line).
enclave_list_ids() {
    /bin/nitro-cli describe-enclaves 2>&1 | awk -F'"' '/"EnclaveID"/{print $4}'
}

# Terminate all running enclaves by their specific ID.
enclave_terminate_all() {
    for id in $(enclave_list_ids); do
        echo "Terminating enclave: $id"
        /bin/nitro-cli terminate-enclave --enclave-id "$id" 2>/dev/null || true
    done
}

enclave_shutdown() {
    echo "Received shutdown signal"
    # Signal enclaver-run and let it terminate the enclave — it owns that lifecycle.
    kill "$ENCLAVER_PID" 2>/dev/null
    wait "$ENCLAVER_PID" 2>/dev/null
    exit 0
}

trap 'enclave_shutdown' TERM INT

# ---------------------------------------------------------------------------
# Startup: ensure a clean slate before launching our enclave
# ---------------------------------------------------------------------------

# Terminate any stale enclaves left by a previous task.
enclave_terminate_all

# Assert no enclaves are running — guarantees the ID we capture later is ours.
LEFTOVER=$(enclave_list_ids)
if [ -n "$LEFTOVER" ]; then
    echo "ERROR: enclave still running after cleanup: $LEFTOVER"
    exit 1
fi

# Verify TCP:8337 is free before starting — fail fast rather than letting
# enclaver-run silently fail with EADDRINUSE on vsock:17002 later.
if nc -z 127.0.0.1 8337 2>/dev/null; then
    echo "ERROR: TCP port 8337 already bound after enclave cleanup."
    echo "       A stale enclaver-run process is likely holding vsock:17002."
    echo "       Terminate the EC2 instance to release the vsock port."
    exit 1
fi

# Start enclaver-run — reads /enclave/enclaver.yaml, starts the Nitro enclave
# from /enclave/application.eif, and bridges TCP:8337/8338 → vsock:8337/8338.
echo "Starting enclaver-run..."
/usr/local/bin/enclaver-run &
ENCLAVER_PID=$!
echo "enclaver-run started with PID: $ENCLAVER_PID"

# Poll describe-enclaves until the enclave ID appears (up to 120 s).
echo "Waiting for enclave to start (via describe-enclaves)..."
i=0
while [ $i -lt 120 ]; do
    ENCLAVE_ID=$(enclave_list_ids)
    if [ -n "$ENCLAVE_ID" ]; then
        echo "Enclave started with ID: $ENCLAVE_ID"
        break
    fi
    if ! kill -0 "$ENCLAVER_PID" 2>/dev/null; then
        echo "ERROR: enclaver-run exited prematurely"
        exit 1
    fi
    sleep 1
    i=$((i + 1))
done

if [ -z "$ENCLAVE_ID" ]; then
    echo "ERROR: Enclave did not start within 120 seconds"
    exit 1
fi

# Wait for the enclave's readiness signal on port 8338 (handshake).
# enclave-entrypoint.bash sends "READY" on 8338 after nc:8337 is listening
# and Odyn is verified.
echo "Waiting for enclave readiness signal on port 8338..."
READY=""
i=0
while [ $i -lt 30 ]; do
    READY=$(timeout 3 nc 127.0.0.1 8338 2>/dev/null || true)
    if [ -n "$READY" ]; then
        echo "Enclave ready (readiness signal received)"
        break
    fi
    if ! kill -0 "$ENCLAVER_PID" 2>/dev/null; then
        echo "ERROR: enclaver-run exited before readiness signal"
        exit 1
    fi
    sleep 1
    i=$((i + 1))
done
if [ -z "$READY" ]; then
    echo "WARNING: readiness signal not received within 30 seconds, proceeding anyway"
fi

# Deliver batcher arguments to the enclave's nc listener (args not logged here).
echo "Sending batcher arguments to enclave..."
send_batcher_args | timeout 30 nc 127.0.0.1 8337
echo "Arguments sent to enclave"

# Wait for enclaver-run — it stays alive as long as the enclave is running.
echo "Monitoring enclaver process $ENCLAVER_PID..."
wait "$ENCLAVER_PID"
EXIT_CODE=$?
echo "enclaver-run exited with code: $EXIT_CODE"
exit "$EXIT_CODE"
