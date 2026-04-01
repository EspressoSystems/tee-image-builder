#!/usr/bin/env python3
"""
Nitro batch poster config helper for the EIF build workflow.

Reads chains/nitro/<chain>.json and outputs one of:

  da-enabled  — prints "true" or "false" indicating whether
                data-availability is enabled in the config.

  labels      — Dockerfile LABEL lines for OCI labels on the runner image.

Usage:
  python3 scripts/nitro-config.py <config-path> da-enabled
  python3 scripts/nitro-config.py <config-path> labels
"""
import json
import argparse


def load_config(config_path):
    with open(config_path) as f:
        return json.load(f)


def mode_da_enabled(config):
    enabled = config.get("node", {}).get("data-availability", {}).get("enable", False)
    print("true" if enabled else "false")


def mode_labels(config):
    chain_name = config.get("chain", {}).get("name", "unknown")
    chain_info_raw = config.get("chain", {}).get("info-json", "[]")
    try:
        chain_info = json.loads(chain_info_raw)
        entry = chain_info[0] if chain_info else {}
        chain_id = entry.get("chain-id", "unknown")
        parent_chain_id = entry.get("parent-chain-id", "unknown")
    except (json.JSONDecodeError, IndexError, KeyError):
        chain_id = parent_chain_id = "unknown"

    bp = config.get("node", {}).get("batch-poster", {})
    light_client = bp.get("light-client-address", "")
    hotshot_urls = bp.get("hotshot-urls", [])

    print(f'LABEL config.chain.name="{chain_name}"')
    print(f'LABEL config.chain.id="{chain_id}"')
    print(f'LABEL config.chain.parent-chain-id="{parent_chain_id}"')
    if light_client:
        print(f'LABEL config.batch-poster.light-client-address="{light_client}"')
    if hotshot_urls:
        print(f'LABEL config.batch-poster.hotshot-urls="{",".join(hotshot_urls)}"')


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("config_path", help="Path to chains/nitro/<chain>.json")
    parser.add_argument("mode", choices=["da-enabled", "labels"])
    args = parser.parse_args()

    config = load_config(args.config_path)

    if args.mode == "da-enabled":
        mode_da_enabled(config)
    elif args.mode == "labels":
        mode_labels(config)


if __name__ == "__main__":
    main()
