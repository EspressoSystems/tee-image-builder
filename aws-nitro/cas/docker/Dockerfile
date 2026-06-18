# Inner image for CAS Nitro Enclave deployment.
#
# Consumed by `enclaver build` (see ../enclaver/enclaver.yaml) and wrapped into
# an EIF. Every byte here contributes to PCR0 — including the committed config
# copied in below — so changing this file or the chosen chain-config changes the
# attestation identity and requires a KMS policy update.
#
# Build context is the repo root (see .github/workflows/cas.yml) so the COPY
# below can reach chain-configs/cas/.

ARG SOURCE_IMAGE
FROM ${SOURCE_IMAGE}

ARG CHAIN
ARG CONFIG_HASH
ARG AWS_REGION
ARG AWS_SECRET_ID
ARG AWS_GENESIS_SECRET_ID
ARG ENFORCE_CONFIG=true

ARG RUST_LOG=info

ENV AWS_REGION=${AWS_REGION} \
    AWS_SECRET_ID=${AWS_SECRET_ID} \
    AWS_GENESIS_SECRET_ID=${AWS_GENESIS_SECRET_ID} \
    EXPECTED_CONFIG_SHA256=${CONFIG_HASH} \
    ENFORCE_CONFIG=${ENFORCE_CONFIG} \
    CAS_CONFIG_PATH=/etc/cas/config.json \
    RUST_LOG=${RUST_LOG}

# Bake the committed config. PCR0 attests to these exact bytes; an attacker
# swapping the file post-build invalidates PCR0 and the KMS policy refuses the
# secret. World-readable so a non-root USER in the source image can still read.
#
# We pre-create /etc/cas with 0755 as root. Otherwise BuildKit's COPY auto-
# creates the intermediate directory with the file's --chmod (0644), which
# has no execute bit and blocks traversal for non-root USERs.
USER root
RUN mkdir -p /etc/cas && chmod 0755 /etc/cas
COPY --chmod=644 chain-configs/cas/${CHAIN}.json /etc/cas/config.json
USER user

# Inbound listeners. enclaver-run bridges these to TCP on the outer container.
# 8000  -> da_server.listen_addr
# 9643  -> rollup.stack.feed.server.ws_server.port
EXPOSE 8000
EXPOSE 9643

# ENTRYPOINT/CMD inherited from SOURCE_IMAGE. The Rust binary should read
# CAS_CONFIG_PATH, AWS_REGION, AWS_SECRET_ID from env at startup and pull
# runtime-injected URLs from AWS Secrets Manager.
