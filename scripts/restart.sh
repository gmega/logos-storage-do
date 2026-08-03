#!/usr/bin/env bash
# Restarts the running Logos Storage network in dependency order:
# bootstrap first, then followers one at a time, then the RS node(s). Each node
# is gated on its readiness (the daemon announcing a non-null discovery SPR).
#
# Only restarts daemons — it does NOT re-export or republish bucket artifacts.
# SPR strings change on restart (timestamp seq), but stay valid for routing;
# republish on redeploy via deploy.sh. Requires an existing inventory.ini.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "${HERE}")"

if [[ ! -f "${ROOT}/ansible/inventory.ini" ]]; then
  echo "ansible/inventory.ini not found — is the network deployed? (run deploy.sh)" >&2
  exit 1
fi

# Ansible lives in a dedicated conda env (never installed globally).
# shellcheck disable=SC1091
source "${HERE}/conda.sh"

cd "${ROOT}/ansible"
ansible-playbook -i inventory.ini restart-playbook.yml
