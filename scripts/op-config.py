#!/usr/bin/env python3
"""
OP batcher config helper for the EIF build workflow.

Reads chains/op/<chain>.yaml and outputs one of three artifacts:

  dockerfile-params  — Dockerfile that bakes EXPECTED_COMMITTED_PARAMS_SHA256
                       into the intermediate app image (affects PCR0).
                       Requires --app-image.

  committed-json     — Canonical JSON of committed: section, baked into the
                       outer runner image as /committed-params.json.
                       run-eif.sh sends this to the enclave for hash validation.

  labels             — Dockerfile LABEL lines for config.committed.* and
                       config.runtime.* OCI labels on the outer runner image.

Usage:
  python3 scripts/op-config.py <config-path> dockerfile-params --app-image <image>
  python3 scripts/op-config.py <config-path> committed-json
  python3 scripts/op-config.py <config-path> labels
"""
import sys
import json
import hashlib
import argparse
import yaml


def load_config(config_path):
    with open(config_path) as f:
        cfg = yaml.safe_load(f)
    committed = cfg.get("committed", {})
    if not committed:
        sys.exit(f"ERROR: committed: section is empty or missing in {config_path}")
    return cfg, committed


def canonical_json(committed):
    return json.dumps(committed, sort_keys=True, separators=(",", ":"))


def committed_hash(committed):
    return hashlib.sha256(canonical_json(committed).encode()).hexdigest()


def mode_dockerfile_params(cfg, committed, app_image):
    sha256 = committed_hash(committed)
    print(f"FROM {app_image}")
    print(f'ENV EXPECTED_COMMITTED_PARAMS_SHA256="{sha256}"')
    print(f"Committed params hash: {sha256}", file=sys.stderr)


def mode_committed_json(cfg, committed):
    print(canonical_json(committed))
    print(f"SHA256: {committed_hash(committed)}", file=sys.stderr)


def mode_labels(cfg, committed):
    for k, v in committed.items():
        print(f'LABEL config.committed.{k}="{v}"')
        print(f'LABEL config.committed.{k}="{v.replace('"', '\"')}"')
        print(f'LABEL config.runtime.{k}="{v}"')
        print(f'LABEL config.runtime.{k}="{v.replace('"', '\"')}"')

def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("config_path", help="Path to chain config YAML")
    parser.add_argument("mode", choices=["dockerfile-params", "committed-json", "labels"])
    parser.add_argument("--app-image", help="App image reference (required for dockerfile-params)")
    args = parser.parse_args()

    if args.mode == "dockerfile-params" and not args.app_image:
        sys.exit("ERROR: --app-image is required for dockerfile-params mode")

    cfg, committed = load_config(args.config_path)

    if args.mode == "dockerfile-params":
        mode_dockerfile_params(cfg, committed, args.app_image)
    elif args.mode == "committed-json":
        mode_committed_json(cfg, committed)
    elif args.mode == "labels":
        mode_labels(cfg, committed)


if __name__ == "__main__":
    main()
