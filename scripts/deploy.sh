#!/usr/bin/env bash
# End-to-end deploy of the Logos Storage Mix-Proxy network.
#
#   0. (once) create the Spaces key out-of-band  -> scripts/.spaces.env
#   1. terraform apply  -> 4 droplets + firewall + Spaces bucket + inventory
#   2. ansible-playbook -> build logoscore, start MP network, export artifacts
#   3. terraform apply  -> publish mix-pool.json + tcp-sprs.* to the bucket
#
# Prerequisites: DO_TOKEN set; conda env 'logos-storage-do' with ansible-core;
# SSH key 'giulianos-public-key' in the DO account.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "${HERE}")"

# 0. Ensure the Spaces key exists, then load all credentials.
"${HERE}/00-spaces-key.sh"
# shellcheck disable=SC1091
source "${HERE}/env.sh"

# Ansible lives in a dedicated conda env (never installed globally).
# shellcheck disable=SC1091
source "${HOME}/anaconda3/etc/profile.d/conda.sh"
conda activate logos-storage-do

# 1. Infrastructure: droplets + firewall + bucket + Ansible inventory.
cd "${ROOT}/terraform"
terraform init -input=false
terraform apply -input=false -auto-approve

# 2. Provisioning: build + run + export + merge.
cd "${ROOT}/ansible"
ansible-playbook playbook.yml

# 3. Publish artifacts (now that Ansible has produced them locally).
cd "${ROOT}/terraform"
terraform apply -input=false -auto-approve

echo
echo "=== Mix-Proxy network deployed. Public artifact URLs: ==="
terraform output -raw mix_pool_url;      echo
terraform output -raw tcp_sprs_txt_url;  echo
terraform output -raw tcp_sprs_json_url; echo
terraform output -raw udp_sprs_txt_url;  echo
terraform output -raw udp_sprs_json_url; echo
