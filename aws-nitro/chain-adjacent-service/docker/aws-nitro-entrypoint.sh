#!/bin/bash

set -e

echo "Using config hash: $EXPECTED_CONFIG_SHA256"

ENCLAVE_CONFIG_SOURCE_DIR=/mnt/config       # temporary mounted directory in enclave to read config from parent instance
PARENT_SOURCE_CONFIG_DIR=/opt/cas/config    # config path on parent directory
ENCLAVE_CONFIG_TARGET_DIR=/config           # directory to copy config contents to inside enclave

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
mount -t nfs4 "127.0.0.1:${PARENT_SOURCE_CONFIG_DIR}" "${ENCLAVE_CONFIG_SOURCE_DIR}" || { echo "ERROR: Failed to mount config directory"; exit 1; }

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
umount "${ENCLAVE_CONFIG_SOURCE_DIR}" || echo "WARNING: Failed to unmount config directory" >&2

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

echo "Successfully retrieved secrets from aws"

# Extract required secrets
ESPRESSO_URL=$(echo "$SECRET_JSON" | jq -r '."espresso-url"')
if [[ "$ESPRESSO_URL" == "null" || -z "$ESPRESSO_URL" ]]; then
  echo "ERROR: 'espresso-url' is missing or null in config" >&2
  exit 1
fi

L1_WS_URL=$(echo "$SECRET_JSON" | jq -r '."l1-ws-url"')
if [[ "$L1_WS_URL" == "null" || -z "$L1_WS_URL" ]]; then
  echo "ERROR: 'l1-ws-url' is missing or null in config" >&2
  exit 1
fi

FEED_WS_URL=$(echo "$SECRET_JSON" | jq -r '."feed-ws-url"')
if [[ "$FEED_WS_URL" == "null" || -z "$FEED_WS_URL" ]]; then
  echo "ERROR: 'feed-ws-url' is missing or null in config" >&2
  exit 1
fi

# Optional: DA provider overrides (JSON array)
DA_PROVIDERS=$(echo "$SECRET_JSON" | jq -c '."da-providers" // empty')

# Compute config hash excluding secret fields
CONFIG_SHA=$(jq -cS 'del(
      .espresso_client.base_url,
      .rollup.stack.l1_ws_url,
      .rollup.stack.feed.web_socket_url,
      .da_server.da_providers
    )' "${ENCLAVE_CONFIG_TARGET_DIR}/cas_config.json" | sha256sum | cut -d' ' -f1) || {
    echo "ERROR: Failed to calculate config sha256"
    exit 1
}

echo "Comparing config sha"
if [[ "${ENFORCE_CONFIG}" == "false" ]]; then
    echo "WARNING: Config hash enforcement disabled — skipping check (Expected: $EXPECTED_CONFIG_SHA256, Actual: $CONFIG_SHA)"
elif [ "$CONFIG_SHA" != "$EXPECTED_CONFIG_SHA256" ]; then
    echo "ERROR: Config sha256 mismatch"
    echo "Expected: $EXPECTED_CONFIG_SHA256"
    echo "Actual:   $CONFIG_SHA"
    exit 1
else
    echo "Config sha256 verified"
fi

# Inject secret values into config
echo "Injecting secrets into CAS config"
jq --arg espresso_url "$ESPRESSO_URL" \
   --arg l1_ws_url "$L1_WS_URL" \
   --arg feed_ws_url "$FEED_WS_URL" \
   '.espresso_client.base_url = $espresso_url |
    .rollup.stack.l1_ws_url = $l1_ws_url |
    .rollup.stack.feed.web_socket_url = $feed_ws_url' \
   "${ENCLAVE_CONFIG_TARGET_DIR}/cas_config.json" > /tmp/cas_config_patched.json

# Inject DA providers if provided in secrets
if [[ -n "$DA_PROVIDERS" ]]; then
  echo "Injecting DA provider URLs from aws secrets into config"
  jq --argjson da_providers "$DA_PROVIDERS" \
    '.da_server.da_providers = $da_providers' \
    /tmp/cas_config_patched.json > /tmp/cas_config_final.json
  mv /tmp/cas_config_final.json /tmp/cas_config_patched.json
fi

mv /tmp/cas_config_patched.json "${ENCLAVE_CONFIG_TARGET_DIR}/cas_config.json"

echo "Starting vsock server"
socat VSOCK-LISTEN:8005,fork,keepalive SYSTEM:./server.sh &
sleep 5

exec /chain-adjacent-service --config "${ENCLAVE_CONFIG_TARGET_DIR}/cas_config.json" \
  2>&1 | while IFS= read -r line || [[ -n "$line" ]]; do [ ${#line} -gt 4096 ] && echo "${line:0:4076}... [line truncated]" || echo "$line"; done
