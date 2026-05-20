#!/bin/bash

# Exit immediately if any command fails
set -e

sudo sed -i \
  -e '/^cpu_count:/s/:.*$/: 4/' \
  -e '/^memory_mib:/s/:.*$/: 8192/' \
  "/etc/nitro_enclaves/allocator.yaml"

sudo systemctl enable --now nitro-enclaves-allocator.service

echo "All services configured successfully!"