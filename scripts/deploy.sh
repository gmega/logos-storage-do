#!/usr/bin/env bash
# Resolve one catalog release, provision, verify, then publish global metadata.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
force=()
case "${1:-}" in
  --force) force=(--force) ;;
  '') ;;
  *) echo 'Usage: scripts/deploy.sh [--force]' >&2; exit 2 ;;
esac
[[ $# -le 1 ]] || { echo 'Too many arguments' >&2; exit 2; }
mkdir -p "${ROOT}/artifacts"
# Prevent two local deployments from racing version checks and metadata writes.
exec 9>"${ROOT}/artifacts/deploy.lock"
flock -n 9 || { echo 'Another deployment is running' >&2; exit 1; }
source "${HERE}/env.sh"
source "${HERE}/conda.sh"
cd "${ROOT}/terraform"
terraform init -input=false
# Derive the endpoint from configured variables, including on a fresh deployment.
bucket_url=${BUCKET_URL:-$(printf '"https://${var.bucket_name}.${var.region}.digitaloceanspaces.com"\n' | terraform console | jq -r .)}
python3 "${HERE}/resolve-release.py" --bucket-url "$bucket_url" \
  --output "${ROOT}/artifacts/release.json" "${force[@]}"
# Duplicate-version refusal happens before any infrastructure or node mutation.
"${HERE}/00-spaces-key.sh"
source "${HERE}/env.sh"
# Infrastructure stage excludes generated objects so old local bootstrap records
# cannot be published under the new namespace before provisioning finishes.
terraform apply -input=false -auto-approve \
  -target=local_file.ansible_inventory -target=digitalocean_firewall.mp \
  -target=digitalocean_firewall.dashboard -target=digitalocean_spaces_bucket.artifacts
cd "${ROOT}/ansible"
release_vars="@${ROOT}/artifacts/release.json"
ansible-playbook playbook.yml -e "$release_vars"
if grep -q '^logos-rs' inventory.ini; then
  ansible-playbook rs-playbook.yml -e "$release_vars"
fi
ansible-playbook dashboard-playbook.yml -e "$release_vars"
# Publish current bootstrap records for external clients; keep the previous
# successful global version until health/discovery/transfer verification passes.
terraform -chdir="${ROOT}/terraform" apply -input=false -auto-approve
spr_url=$(terraform -chdir="${ROOT}/terraform" output -raw tcp_sprs_json_url)
ansible-playbook verify-playbook.yml -e "$release_vars" -e "artifact_url=${spr_url%/tcp-sprs.json}"
dashboard_url=$(terraform -chdir="${ROOT}/terraform" output -raw dashboard_url)
python3 "${HERE}/verify-dashboard.py" "$dashboard_url"
python3 - "$ROOT" <<'PY'
import datetime,json,sys
from pathlib import Path
root=Path(sys.argv[1]); release=json.loads((root/'artifacts/release.json').read_text())
metadata={'version':release['deployment_version'], 'module_sha256':release['module_sha256'],
          'module_url':release['module_url'], 'deployed_at':datetime.datetime.now(datetime.timezone.utc).isoformat()}
target=root/'artifacts/metadata.json'
temp=target.with_suffix('.tmp');temp.write_text(json.dumps(metadata,indent=2)+'\n');temp.replace(target)
PY
terraform -chdir="${ROOT}/terraform" apply -input=false -auto-approve
printf '\nDeployment verified. Dashboard: '
terraform -chdir="${ROOT}/terraform" output -raw dashboard_url
printf '\n'
