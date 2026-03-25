# OP Batcher EIF

This directory contains the runtime entrypoint (`run-eif.sh`) for the OP batcher running inside an AWS Nitro Enclave, and the GitHub Actions workflow that builds and publishes the EIF image.

## How it works

The build produces a self-contained Docker image (`op-batcher-eif`) that bundles:
- The **EIF** (Enclave Image File) baked in at `/enclave/application.eif` by [enclaver](https://github.com/enclaver-io/enclaver)
- The **`run-eif.sh` entrypoint** that assembles batcher arguments from environment variables and delivers them to the enclave

The outer image is scratch-based — no shell or standard tools — so `run-eif.sh` must be POSIX sh and relies only on a statically linked busybox.

## Source images

The build pulls two images from `ghcr.io/espressosystems/optimism-espresso-integration`:

| Image | Purpose |
|-------|---------|
| `op-batcher-enclave-app:<tag>` | The batcher binary that runs inside the enclave |
| `op-batcher-tee:<tag>` | Provides `enclave-tools` used to build the EIF |

Both are pinned to their `sha256` digest at build time so re-runs always produce the same EIF and identical PCR measurements.

## Generating a new image

### Automatically

The workflow runs on every push and pull request to `main`, using the default tag `celo-integration-rebase-14.2`.

### Manually

Trigger via GitHub Actions UI (on `main` branch) or via CLI:

```bash
gh workflow run build-eif-op.yml \
  --ref <branch> \
  --field tag=<image-tag>
```

Where `<image-tag>` is any tag published to the espressosystems source registry — typically a branch name (e.g. `light-client-env-to-enclave-sh`), a release tag, or a commit SHA.

The workflow will:
1. Pull and pin both source images by digest
2. Build the EIF and capture PCR0/PCR1/PCR2 measurements
3. Compute `keccak256(PCR0)` as the on-chain enclave hash
4. Layer `run-eif.sh` on top and embed all measurements as OCI labels
5. Push the final image to `ghcr.io/<owner>/op-batcher-eif:<tag>`

## Running the image

Pull and run on a Nitro-enabled EC2 instance:

```bash
docker run --rm \
  -e L1_RPC_URL=... \
  -e L2_RPC_URL=... \
  -e ROLLUP_RPC_URL=... \
  -e ESPRESSO_URL1=... \
  -e OP_BATCHER_PRIVATE_KEY=... \
  -e ESPRESSO_ATTESTATION_SERVICE_URL=... \
  -e EIGENDA_PROXY_URL=... \
  ghcr.io/<owner>/op-batcher-eif:<tag>
```

### Required environment variables

| Variable | Description |
|----------|-------------|
| `L1_RPC_URL` | HTTP provider URL for L1 |
| `L2_RPC_URL` | HTTP provider URL for L2 execution engine |
| `ROLLUP_RPC_URL` | HTTP provider URL for the Rollup node |
| `ESPRESSO_URL1` | Espresso query service URL |
| `OP_BATCHER_PRIVATE_KEY` | Batcher signing key |
| `ESPRESSO_ATTESTATION_SERVICE_URL` | Espresso attestation service URL |
| `EIGENDA_PROXY_URL` | EigenDA proxy URL (AltDA server) |

### Key optional environment variables (with defaults)

| Variable | Default | Description |
|----------|---------|-------------|
| `ESPRESSO_URL2` | `$ESPRESSO_URL1` | Second Espresso URL for redundancy |
| `ESPRESSO_LIGHT_CLIENT_ADDR` | Decaf Sepolia default | Espresso light client contract address |
| `DATA_AVAILABILITY_TYPE` | `auto` | DA type: `calldata`, `blobs`, or `auto` |
| `COMPRESSION_ALGO` | `zlib` | Batch compression algorithm |
| `MAX_CHANNEL_DURATION` | `0` | Max L1 blocks to keep a channel open (0 = disabled) |
| `THROTTLE_THRESHOLD` | `1000000` | Pending bytes threshold before throttling |
| `POLL_INTERVAL` | `1s` | L2 polling interval |
| `ESPRESSO_POLL_INTERVAL` | `1s` | HotShot polling interval |
| `NUM_CONFIRMATIONS` | `8` | L1 confirmations before tx is considered final |
| `RESUBMISSION_TIMEOUT` | `30s` | Time before resubmitting a stuck tx |
| `MAX_PENDING_TX` | `32` | Max concurrent pending L1 transactions |
| `SUB_SAFETY_MARGIN` | `10` | L1 blocks subtracted from channel timeout as safety buffer |
| `TXMGR_MIN_TIP_CAP` | `1.0` | Minimum tip cap in GWei |
| `RPC_ENABLE_ADMIN` | `false` | Enable `admin_startBatcher`/`admin_stopBatcher` RPC |
| `ENCLAVE_DEBUG` | `false` | Enable debug logging inside the enclave |

## What run-eif.sh does

1. **Validates** all required environment variables are set, failing fast if any are missing
2. **Applies defaults** for all optional variables
3. **Logs** the full configuration to stdout (private key is redacted inside the enclave)
4. **Cleans up** any stale Nitro enclaves left by a previous task
5. **Starts `enclaver-run`** which launches the Nitro enclave from the baked-in EIF and bridges TCP ports 8337/8338 to vsock
6. **Waits for the enclave** to appear via `nitro-cli describe-enclaves` (up to 120s)
7. **Waits for a readiness signal** from the enclave on port 8338
8. **Delivers batcher arguments** as a NUL-separated stream over TCP port 8337 — the enclave reads these and starts `op-batcher`
9. **Monitors `enclaver-run`** and exits with its exit code when it stops

## Clean shutdown

The container handles `SIGTERM` and `SIGINT` gracefully. On either signal, `run-eif.sh` forwards the signal to `enclaver-run`, which terminates the Nitro enclave cleanly before exiting.

To stop the batcher from outside the container:

```bash
# Stop the container (sends SIGTERM)
docker stop <container-id>
```

If `RPC_ENABLE_ADMIN=true`, you can also control the batcher directly via its admin RPC without stopping the enclave:

```bash
# Stop batching (enclave stays running)
curl -X POST http://localhost:8545 \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"admin_stopBatcher","params":[],"id":1}'

# Resume batching
curl -X POST http://localhost:8545 \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"admin_startBatcher","params":[],"id":1}'
```
