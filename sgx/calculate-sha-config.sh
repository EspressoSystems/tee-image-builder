#!/bin/bash
# Ensure FILE_PATH is set as an environment variable
if [ -z "$POSTER_CONFIG_PATH" ]; then
  echo "POSTER_CONFIG_PATH is not set. Exiting."
  exit 1
fi

# Compute the SHA-256 hash
HASH=$(sha256sum "$POSTER_CONFIG_PATH" | awk '{print $1}')
echo "SHA256 Hash: $HASH"
