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

# Required environment variables
: ${L1_RPC_URL:?Error: L1_RPC_URL is required}
: ${L2_RPC_URL:?Error: L2_RPC_URL is required}
: ${ROLLUP_RPC_URL:?Error: ROLLUP_RPC_URL is required}
: ${ESPRESSO_URL1:?Error: ESPRESSO_URL1 is required}
: ${OP_BATCHER_PRIVATE_KEY:?Error: OP_BATCHER_PRIVATE_KEY is required}
: ${ESPRESSO_ATTESTATION_SERVICE_URL:?Error: ESPRESSO_ATTESTATION_SERVICE_URL is required}
: ${EIGENDA_PROXY_URL:?Error: EIGENDA_PROXY_URL is required}

# Optional configuration with defaults
ESPRESSO_URL2="${ESPRESSO_URL2:-$ESPRESSO_URL1}"
ESPRESSO_ORIGIN_HEIGHT_ESPRESSO="${ESPRESSO_ORIGIN_HEIGHT_ESPRESSO:-0}"
ESPRESSO_ORIGIN_HEIGHT_L2="${ESPRESSO_ORIGIN_HEIGHT_L2:-0}"
ENCLAVE_DEBUG="${ENCLAVE_DEBUG:-false}"
MAX_CHANNEL_DURATION="${MAX_CHANNEL_DURATION:-0}"
TARGET_NUM_FRAMES="${TARGET_NUM_FRAMES:-1}"
MAX_L1_TX_SIZE_BYTES="${MAX_L1_TX_SIZE_BYTES:-120000}"
DATA_AVAILABILITY_TYPE="${DATA_AVAILABILITY_TYPE:-auto}"
ALTDA_MAX_CONCURRENT_DA_REQUESTS="${ALTDA_MAX_CONCURRENT_DA_REQUESTS:-1}"
ALTDA_DA_SERVICE="${ALTDA_DA_SERVICE:-false}"
ALTDA_VERIFY_ON_READ="${ALTDA_VERIFY_ON_READ:-true}"
ALTDA_PUT_TIMEOUT="${ALTDA_PUT_TIMEOUT:-0}"
ALTDA_GET_TIMEOUT="${ALTDA_GET_TIMEOUT:-0}"
THROTTLE_THRESHOLD="${THROTTLE_THRESHOLD:-1000000}"
POLL_INTERVAL="${POLL_INTERVAL:-1s}"
NUM_CONFIRMATIONS="${NUM_CONFIRMATIONS:-8}"
RESUBMISSION_TIMEOUT="${RESUBMISSION_TIMEOUT:-30s}"
RPC_ENABLE_ADMIN="${RPC_ENABLE_ADMIN:-false}"
ESPRESSO_POLL_INTERVAL="${ESPRESSO_POLL_INTERVAL:-1s}"
COMPRESSION_ALGO="${COMPRESSION_ALGO:-zlib}"
SUB_SAFETY_MARGIN="${SUB_SAFETY_MARGIN:-10}"
TXMGR_MIN_TIP_CAP="${TXMGR_MIN_TIP_CAP:-1.0}"
MAX_PENDING_TX="${MAX_PENDING_TX:-32}"

# Get light client address from env var or use default
if [ -n "$ESPRESSO_LIGHT_CLIENT_ADDR" ]; then
    echo "Using ESPRESSO_LIGHT_CLIENT_ADDR from environment variable"
else
    # Decaf light client address for ETH Sepoliaß
    ESPRESSO_LIGHT_CLIENT_ADDR="0x303872bb82a191771321d4828888920100d0b3e4"
    echo "ESPRESSO_LIGHT_CLIENT_ADDR not set, using default"
fi

# Override OP_BATCHER_ESPRESSO_LIGHT_CLIENT_ADDR so the batcher's env var matches,
# preventing any outer deployment env from leaking a stale value into the enclave.
export OP_BATCHER_ESPRESSO_LIGHT_CLIENT_ADDR="$ESPRESSO_LIGHT_CLIENT_ADDR"

echo "=== Enclave Batcher Configuration ==="
echo "L1 RPC URL: $L1_RPC_URL"
echo "L2 RPC URL: $L2_RPC_URL"
echo "Rollup RPC URL: $ROLLUP_RPC_URL"
echo "Espresso URLs: $ESPRESSO_URL1, $ESPRESSO_URL2"
echo "Attestation service url: $ESPRESSO_ATTESTATION_SERVICE_URL"
echo "EigenDA Proxy URL: $EIGENDA_PROXY_URL"
echo "Light Client Address: $ESPRESSO_LIGHT_CLIENT_ADDR"
echo "Espresso Origin Height: $ESPRESSO_ORIGIN_HEIGHT_ESPRESSO"
echo "L2 Origin Height: $ESPRESSO_ORIGIN_HEIGHT_L2"
echo "Debug Mode: $ENCLAVE_DEBUG"
echo "Max Channel Duration: $MAX_CHANNEL_DURATION"
echo "Target Num Frames: $TARGET_NUM_FRAMES"
echo "Max L1 Tx Size Bytes: $MAX_L1_TX_SIZE_BYTES"
echo "AltDA Max Concurrent DA Requests: $ALTDA_MAX_CONCURRENT_DA_REQUESTS"
echo "AltDA DA Service: $ALTDA_DA_SERVICE"
echo "AltDA Verify On Read: $ALTDA_VERIFY_ON_READ"
echo "AltDA Put Timeout: $ALTDA_PUT_TIMEOUT"
echo "AltDA Get Timeout: $ALTDA_GET_TIMEOUT"
echo "Throttle Threshold: $THROTTLE_THRESHOLD"
echo "Poll Interval: $POLL_INTERVAL"
echo "Num Confirmations: $NUM_CONFIRMATIONS"
echo "Resubmission Timeout: $RESUBMISSION_TIMEOUT"
echo "RPC Enable Admin: $RPC_ENABLE_ADMIN"
echo "Espresso Poll Interval: $ESPRESSO_POLL_INTERVAL"
echo "Compression Algo: $COMPRESSION_ALGO"
echo "Sub Safety Margin: $SUB_SAFETY_MARGIN"
echo "TxMgr Min Tip Cap: $TXMGR_MIN_TIP_CAP"
echo "Max Pending Tx: $MAX_PENDING_TX"
echo "====================================="

# Send batcher args as a NUL-separated stream.
# Protocol matches enclave-entrypoint.bash: each arg is NUL-terminated;
# a second consecutive NUL (empty string) signals end-of-args.
# NOTE: private key is not logged here — enclave-entrypoint.bash redacts it.
send_batcher_args() {
    printf '%s\0' \
        "--l1-eth-rpc=$L1_RPC_URL" \
        "--l2-eth-rpc=$L2_RPC_URL" \
        "--rollup-rpc=$ROLLUP_RPC_URL" \
        "--espresso.enabled=true" \
        "--espresso.urls=$ESPRESSO_URL1" \
        "--espresso.urls=$ESPRESSO_URL2" \
        "--espresso.espresso-attestation-service=$ESPRESSO_ATTESTATION_SERVICE_URL" \
        "--espresso.origin-height-espresso=$ESPRESSO_ORIGIN_HEIGHT_ESPRESSO" \
        "--espresso.origin-height-l2=$ESPRESSO_ORIGIN_HEIGHT_L2" \
        "--espresso.poll-interval=$ESPRESSO_POLL_INTERVAL" \
        "--private-key=$OP_BATCHER_PRIVATE_KEY" \
        "--poll-interval=$POLL_INTERVAL" \
        "--num-confirmations=$NUM_CONFIRMATIONS" \
        "--resubmission-timeout=$RESUBMISSION_TIMEOUT" \
        "--rpc.enable-admin=$RPC_ENABLE_ADMIN" \
        "--throttle-threshold=$THROTTLE_THRESHOLD" \
        "--max-channel-duration=$MAX_CHANNEL_DURATION" \
        "--target-num-frames=$TARGET_NUM_FRAMES" \
        "--max-l1-tx-size-bytes=$MAX_L1_TX_SIZE_BYTES" \
        "--espresso.light-client-addr=$ESPRESSO_LIGHT_CLIENT_ADDR" \
        "--altda.enabled=true" \
        "--altda.da-server=$EIGENDA_PROXY_URL" \
        "--altda.da-service=$ALTDA_DA_SERVICE" \
        "--altda.verify-on-read=$ALTDA_VERIFY_ON_READ" \
        "--altda.max-concurrent-da-requests=$ALTDA_MAX_CONCURRENT_DA_REQUESTS" \
        "--altda.put-timeout=$ALTDA_PUT_TIMEOUT" \
        "--altda.get-timeout=$ALTDA_GET_TIMEOUT" \
        "--data-availability-type=$DATA_AVAILABILITY_TYPE" \
        "--compression-algo=$COMPRESSION_ALGO" \
        "--sub-safety-margin=$SUB_SAFETY_MARGIN" \
        "--txmgr.min-tip-cap=$TXMGR_MIN_TIP_CAP" \
        "--max-pending-tx=$MAX_PENDING_TX"
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
