#!/bin/bash

set -e

echo "Using config hash: $EXPECTED_CONFIG_SHA256"

ENCLAVE_CONFIG_SOURCE_DIR=/mnt/config        # temporary mounted directory in enclave to read config from parent instance
PARENT_SOURCE_CONFIG_DIR=/opt/nitro/config   # config path on parent directory
ENCLAVE_CONFIG_TARGET_DIR=/config            # directory to copy config contents to inside enclave
PARENT_SOURCE_DB_DIR=/opt/nitro/arbitrum     # database path on parent directory

echo "Set memory"
echo 'net.ipv4.tcp_rmem = 4096 87380 16777216' >> /etc/sysctl.conf
echo 'net.ipv4.tcp_wmem = 4096 87380 16777216' >> /etc/sysctl.conf
echo 'net.core.rmem_max = 16777216' >> /etc/sysctl.conf
echo 'net.core.wmem_max = 16777216' >> /etc/sysctl.conf
sysctl -p

echo "Start vsock proxy"
socat -b65536 TCP-LISTEN:2049,bind=127.0.0.1,fork,reuseaddr,keepalive VSOCK-CONNECT:3:8004,keepalive,rcvbuf-late=16384,sndbuf-late=16384 >/dev/null 2>&1 &
sleep 2

echo "Mount config from ${PARENT_SOURCE_CONFIG_DIR} to ${ENCLAVE_CONFIG_SOURCE_DIR}"
mount -t nfs4 "127.0.0.1:${PARENT_SOURCE_CONFIG_DIR}" "${ENCLAVE_CONFIG_SOURCE_DIR}"

echo "Checking Mounts:"
mount -t nfs4

echo "Copying config files from ${ENCLAVE_CONFIG_SOURCE_DIR} to ${ENCLAVE_CONFIG_TARGET_DIR}"
if ! cp -a "${ENCLAVE_CONFIG_SOURCE_DIR}/." "${ENCLAVE_CONFIG_TARGET_DIR}/"; then
    echo "ERROR: Failed to copy config files"
    exit 1
fi

# Verify files were copied
if [ -z "$(ls -A "${ENCLAVE_CONFIG_TARGET_DIR}")" ]; then
    echo "ERROR: No files were copied to target directory"
    exit 1
fi

# Unmount config as we copied files out of mnt directory
echo "Unmounting config"
umount "${ENCLAVE_CONFIG_SOURCE_DIR}"

SECRET=$(aws secretsmanager get-secret-value \
  --secret-id "$AWS_SECRET_ID" \
  --region "$AWS_REGION" \
  --query SecretString \
  --output text) || {
  echo "ERROR: Failed to retrieve config from Secrets Manager"
  exit 1
}

SECRET_JSON=$(echo "$SECRET" | jq -r '.parameters')
if [[ "$SECRET_JSON" == "null" || -z "$SECRET_JSON" ]]; then
  echo "ERROR: no parameters found in retrieved secret" >&2
  exit 1
fi

echo "Succesfully retrieved secrets from aws"
RPC_URL=$(echo "$SECRET_JSON" | jq -r '."rpc-url"')
if [[ "$RPC_URL" == "null" || -z "$RPC_URL" ]]; then
  echo "ERROR: 'rpc-url' is missing or null in config" >&2
  exit 1
fi
PRIVATE_KEY=$(echo "$SECRET_JSON" | jq -r '."private-key"')
if [[ "$PRIVATE_KEY" == "null" || -z "$PRIVATE_KEY" ]]; then
  echo "ERROR: 'private-key' is missing or null in config" >&2
  exit 1
fi
# Set these to default if not present
TXN_MONITOR_INTERVAL=$(echo "$SECRET_JSON" | jq -r '."txn-monitor-interval" // "125ms"')
TXN_RESUBMIT_INTERVAL=$(echo "$SECRET_JSON" | jq -r '."txn-resubmit-interval" // "125ms"')
STREAMER_POLLING_INTERVAL=$(echo "$SECRET_JSON" | jq -r '."streamer-polling-interval" //"10s"')
DA_REST_AGGREGATOR=$(echo "$SECRET_JSON" | jq -c '."da-rest-aggregator" // empty')
DA_RPC_AGGREGATOR=$(echo "$SECRET_JSON" | jq -c '."da-rpc-aggregator" // empty')
DA_ENABLED=$(jq -r '.node."data-availability".enable // false' "${ENCLAVE_CONFIG_TARGET_DIR}/poster_config.json")
if [[ "$DA_ENABLED" == "true" ]]; then
  if [[ -z "$DA_REST_AGGREGATOR" || -z "$DA_RPC_AGGREGATOR" ]]; then
    echo "ERROR: data-availability is enabled but da-rest-aggregator or da-rpc-aggregator are missing from secret config" >&2
    exit 1
  fi
fi
CONFIG_SHA=$(jq -cS 'del(
      .node."batch-poster"."parent-chain-wallet"."private-key",
      .node.espresso."batch-poster"."txns-monitoring-interval",
      .node.espresso."batch-poster"."txns-resubmission-interval",
      .node.espresso.streamer."txns-polling-interval",
      ."parent-chain".connection.url,
      .node."data-availability"
    )' "${ENCLAVE_CONFIG_TARGET_DIR}/poster_config.json" | sha256sum | cut -d' ' -f1) || {
    echo "ERROR: Failed to calculate config sha256"
    exit 1
}

echo "Comparing config sha without da"
if [ "$CONFIG_SHA" != "$EXPECTED_CONFIG_SHA256" ]; then
    echo "ERROR: Config sha256 mismatch"
    echo "Expected: $EXPECTED_CONFIG_SHA256"
    echo "Actual:   $CONFIG_SHA"
    exit 1
fi

echo "Config sha256 verified"

if [[ "$DA_ENABLED" == "true" ]]; then
  echo "Injecting data-availability aggregators from aws secrets into config"
  jq --argjson rest "$DA_REST_AGGREGATOR" --argjson rpc "$DA_RPC_AGGREGATOR" --arg rpc_url "$RPC_URL" \
    '.node["data-availability"]["rest-aggregator"] = $rest | .node["data-availability"]["rpc-aggregator"] = $rpc | .node["data-availability"]["parent-chain-node-url"] = $rpc_url' \
    "${ENCLAVE_CONFIG_TARGET_DIR}/poster_config.json" > /tmp/poster_config_patched.json
  mv /tmp/poster_config_patched.json "${ENCLAVE_CONFIG_TARGET_DIR}/poster_config.json"

  CONFIG_SHA_DA=$(jq -cS 'del(
        .node."batch-poster"."parent-chain-wallet"."private-key",
        .node.espresso."batch-poster"."txns-monitoring-interval",
        .node.espresso."batch-poster"."txns-resubmission-interval",
        .node.espresso.streamer."txns-polling-interval",
        ."parent-chain".connection.url
      )' "${ENCLAVE_CONFIG_TARGET_DIR}/poster_config.json" | sha256sum | cut -d' ' -f1) || {
      echo "ERROR: Failed to calculate DA config sha256"
      exit 1
  }
  echo "Comparing config sha with da"
  echo "Expected config sha with da: $EXPECTED_CONFIG_SHA256_DA"
  if [ "$CONFIG_SHA_DA" != "$EXPECTED_CONFIG_SHA256_DA" ]; then
    echo "ERROR: Config sha256 mismatch"
    echo "Expected: $EXPECTED_CONFIG_SHA256_DA"
    echo "Actual:   $CONFIG_SHA_DA"
    exit 1
  fi
fi

echo "Starting vsock server"
socat VSOCK-LISTEN:8005,fork,keepalive SYSTEM:./server.sh &
sleep 5

echo "Mount NFS database from ${PARENT_SOURCE_DB_DIR}"
mount -t nfs4 -o rsize=16384,wsize=16384 "127.0.0.1:${PARENT_SOURCE_DB_DIR}" "/home/user/.arbitrum"

echo "Checking Mounts:"
mount -t nfs4

exec /usr/local/bin/nitro \
  --validation.wasm.enable-wasmroots-check=false \
  --conf.file "${ENCLAVE_CONFIG_TARGET_DIR}/poster_config.json" \
  --node.batch-poster.parent-chain-wallet.private-key="${PRIVATE_KEY}" \
  --parent-chain.connection.url="${RPC_URL}" \
  --node.espresso.batch-poster.txns-monitoring-interval="${TXN_MONITOR_INTERVAL}" \
  --node.espresso.batch-poster.txns-resubmission-interval="${TXN_RESUBMIT_INTERVAL}" \
  --node.espresso.streamer.txns-polling-interval="${STREAMER_POLLING_INTERVAL}" \
  2>&1 | while IFS= read -r line || [[ -n "$line" ]]; do [ ${#line} -gt 4096 ] && echo "${line:0:4076}... [line truncated]" || echo "$line"; done