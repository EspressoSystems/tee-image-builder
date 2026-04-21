#!/usr/bin/env python3
"""
check_config.py - validates that sensitive fields in chain config JSON files
contain only PLACEHOLDER values and no real credentials or provider URLs.

Usage: git show ":file.json" | python3 check_config.py
"""

import json
import sys

PLACEHOLDER = "PLACEHOLDER"

# Known RPC providers whose URLs must never be committed.
FORBIDDEN_PROVIDERS = ["alchemy", "infura"]

# Fields that must be set to PLACEHOLDER in committed configs.
# Each entry is (display_name, path_as_list_of_keys).
# Fields that are absent are silently skipped (not all chains use all features).
SENSITIVE_FIELDS = [
    (
        "node.batch-poster.parent-chain-wallet.private-key",
        ["node", "batch-poster", "parent-chain-wallet", "private-key"],
    ),
    (
        "node.data-availability.rest-aggregator.urls",
        ["node", "data-availability", "rest-aggregator", "urls"],
    ),
    (
        "node.data-availability.rpc-aggregator.backends",
        ["node", "data-availability", "rpc-aggregator", "backends"],
    ),
    (
        "node.celestia-cfg.url",
        ["node", "celestia-cfg", "url"],
    ),
]


def get_nested(data, path):
    for key in path:
        if not isinstance(data, dict):
            return None
        data = data.get(key)
        if data is None:
            return None
    return data


def is_placeholder(value):
    if value is None:
        return True
    if isinstance(value, str):
        return value == PLACEHOLDER
    if isinstance(value, list):
        return all(is_placeholder(v) for v in value)
    # Unexpected type (e.g. a real object) — not a placeholder
    return False


def find_provider_urls(data):
    """Recursively scan all string values for known provider URLs."""
    found = []
    if isinstance(data, str):
        for provider in FORBIDDEN_PROVIDERS:
            if provider in data.lower():
                found.append(data)
    elif isinstance(data, list):
        for item in data:
            found.extend(find_provider_urls(item))
    elif isinstance(data, dict):
        for value in data.values():
            found.extend(find_provider_urls(value))
    return found


def main():
    try:
        data = json.load(sys.stdin)
    except json.JSONDecodeError:
        sys.exit(0)  # not a config file we recognise, skip

    errors = []

    for name, key_path in SENSITIVE_FIELDS:
        value = get_nested(data, key_path)
        if not is_placeholder(value):
            errors.append(f"sensitive field '{name}' must be set to PLACEHOLDER")

    for url in find_provider_urls(data):
        errors.append(f"provider URL must not be committed: {url}")

    if errors:
        print()
        print("❌ ERROR: Committed config contains sensitive values:")
        for error in errors:
            print(f"   - {error}")
        print()
        sys.exit(1)


if __name__ == "__main__":
    main()
