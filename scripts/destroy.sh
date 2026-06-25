#!/usr/bin/env bash
# Tears down everything created by deploy.sh: droplets, firewall, Spaces bucket
# and its public objects.
#
# The Spaces key itself is external (created by 00-spaces-key.sh); it is left in
# place. Pass --delete-key to also delete it and remove scripts/.spaces.env.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "${HERE}")"

# shellcheck disable=SC1091
source "${HERE}/env.sh"

cd "${ROOT}/terraform"
terraform destroy -input=false -auto-approve

if [[ "${1:-}" == "--delete-key" ]]; then
  export DIGITALOCEAN_ACCESS_TOKEN="${DIGITALOCEAN_ACCESS_TOKEN:-${DO_TOKEN:-}}"
  if [[ -n "${SPACES_ACCESS_KEY_ID:-}" ]]; then
    echo "Deleting Spaces key ${SPACES_ACCESS_KEY_ID}..." >&2
    doctl spaces keys delete "${SPACES_ACCESS_KEY_ID}" || true
  fi
  rm -f "${HERE}/.spaces.env"
fi
