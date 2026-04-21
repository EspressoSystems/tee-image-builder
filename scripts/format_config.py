#!/usr/bin/env python3
"""
format_config.py - formats a JSON config file in place with 4-space indentation.

Usage: python3 format_config.py <file.json>
"""

import json
import sys
from pathlib import Path


INDENT = 4


def main():
    if len(sys.argv) != 2:
        print("Usage: python3 format_config.py <file.json>", file=sys.stderr)
        sys.exit(1)

    path = Path(sys.argv[1])

    try:
        content = path.read_text()
        data = json.loads(content)
    except json.JSONDecodeError as e:
        print(f"Skipping {path}: not valid JSON ({e})", file=sys.stderr)
        sys.exit(0)
    except OSError as e:
        print(f"Error reading {path}: {e}", file=sys.stderr)
        sys.exit(1)

    formatted = json.dumps(data, indent=INDENT) + "\n"

    if formatted != content:
        path.write_text(formatted)
        print(f"Formatted {path}")


if __name__ == "__main__":
    main()
