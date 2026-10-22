#!/usr/bin/env bash
# Shared release publisher for Nitro/Arb, Nitro/CAS and Nitro/OP.
# Usage: bash scripts/publish-nitro-release.sh TAG TITLE MEASUREMENTS_JSON [ASSET...]
# Assets accept gh's path#display-name syntax.
set -euo pipefail

RELEASE_TAG=${1:?release tag required}
RELEASE_TITLE=${2:?release title required}
MEASUREMENTS=${3:?measurements.json required}
shift 3
: "${GITHUB_REPOSITORY:?}" "${GITHUB_SHA:?}"

RELEASE_URL="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY}/releases/tag/${RELEASE_TAG}"
NOTES=$(mktemp)
trap 'rm -f "$NOTES"' EXIT

# Preserve the established table format while allowing chain-specific fields.
# Markdown backticks below are literal.
# shellcheck disable=SC2016
{
  printf '## Chain: `%s`\n\n' "$(jq -er '.chain' "$MEASUREMENTS")"
  printf '| | |\n|---|---|\n'
  jq -r '
    {"tee-type": "TEE type", "nitro-image": "Nitro image", "cas-image": "CAS image",
     "runner-image": "Runner image", "runner-image-pinned": "Runner image (pinned)",
     "source-repo": "Source registry", "app-image-pinned": "App image (pinned)",
     "tee-image-pinned": "TEE image (pinned)", pcr0: "PCR0", pcr1: "PCR1", pcr2: "PCR2",
     "enclave-hash": "Enclave hash (keccak)", "config-hash": "Config hash",
     "config-url": "Committed config", "build-workflow": "Build workflow", "git-sha": "Git SHA"} as $labels
    | to_entries[] | select(.key != "chain")
    | "| **" + ($labels[.key] // .key) + "** | "
      + (if (.key == "build-workflow" or .key == "config-url") then .value
         else "`" + (.value | tostring) + "`" end) + " |"
  ' "$MEASUREMENTS"
  printf '\n### Assets\n'
  printf '%s\n' '- `measurements.json` — machine-readable image references, PCR values, hashes and build provenance.'
  for ASSET in "$@"; do
    NAME=${ASSET##*/}
    NAME=${NAME##*#}
    printf -- '- `%s` — public build configuration.\n' "$NAME"
  done
} > "$NOTES"

if gh release view "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" >/dev/null 2>&1; then
  gh release edit "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" \
    --title "$RELEASE_TITLE" --notes-file "$NOTES"
else
  gh release create "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" --target "$GITHUB_SHA" \
    --title "$RELEASE_TITLE" --notes-file "$NOTES"
fi
gh release upload "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" \
  "${MEASUREMENTS}#measurements.json" "$@" --clobber

if [[ -n "${GITHUB_ENV:-}" ]]; then
  echo "RELEASE_URL=$RELEASE_URL" >> "$GITHUB_ENV"
fi
