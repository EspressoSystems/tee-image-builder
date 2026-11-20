# tee-image-builder
This repository handles building TEE images for batch posters for different stacks (Arbitrum Nitro &amp; OP) on AWS Nitro.

## Setup

> **Important:** Run this once after cloning before making any commits.

```bash
.githooks/install.sh
```

This configures Git to use the repository's hooks, including protection against accidentally committing private keys.

## Active TEE integrations

Verified on 2026-11-20; see [deployed addresses and version evidence](https://github.com/EspressoSystems/espresso-tee-contracts#active-tee-deployments).

| Integration | Image config | Main verifier source |
| --- | --- | --- |
| AppChain mainnet | [CAS](chain-configs/cas/appchain-mainnet.json) | `v1.4.2` equivalent |
| ApeChain testnet | [CAS](chain-configs/cas/apechain-testnet.json) | `v1.4.2` equivalent |
| ApeChain mainnet | [Nitro batch poster](chain-configs/nitro/apechain-mainnet.json) | Identical in `v1.3.0`, `v1.4.0`, `v1.4.1` |

The linked Nitro children also match `v1.4.2` sources. These are source-equivalent versions, separate from image tags.

Existing CAS devnet and OP Celo configs remain workflow build fixtures; shared genesis files remain network inputs.
