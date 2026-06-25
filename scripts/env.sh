#!/usr/bin/env bash
# Source this file before running terraform/ansible:  source scripts/env.sh
#
# Exports the credentials the tooling reads from the environment:
#   - DIGITALOCEAN_ACCESS_TOKEN : Droplets, firewall, SSH keys (from $DO_TOKEN)
#   - SPACES_ACCESS_KEY_ID      : Spaces bucket + objects (from scripts/.spaces.env)
#   - SPACES_SECRET_ACCESS_KEY

export DIGITALOCEAN_ACCESS_TOKEN="${DIGITALOCEAN_ACCESS_TOKEN:-${DO_TOKEN:-}}"

_env_here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
if [[ -f "${_env_here}/.spaces.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "${_env_here}/.spaces.env"
  set +a
fi
unset _env_here

if [[ -z "${DIGITALOCEAN_ACCESS_TOKEN}" ]]; then
  echo "WARNING: DIGITALOCEAN_ACCESS_TOKEN/DO_TOKEN is not set." >&2
fi
