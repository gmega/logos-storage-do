#!/usr/bin/env bash
# Generate client configuration; only bootstrap records are static.
set -euo pipefail
format=${1:-json}
data_dir=${2:-./logos-storage-data}
artifact_url=${ARTIFACT_URL:-https://logos-storage-network.fra1.digitaloceanspaces.com/v0.4}
sprs=$(curl -fsSL "${artifact_url}/tcp-sprs.json")
config=$(jq -n --arg data "$data_dir" --argjson bootstrap "$sprs" \
  '{nat:"auto", "log-level":"DEBUG", "mix-enabled":true, "listen-port":8080,
    "bootstrap-node":$bootstrap, "data-dir":$data}')
case "$format" in
  json) printf '%s\n' "$config" ;;
  toml) printf '%s\n' "$config" | python3 -c 'import json,sys,tomli_w; print(tomli_w.dumps(json.load(sys.stdin)))' ;;
  *) echo 'Usage: gen_config.sh [json|toml] [data-dir]' >&2; exit 2 ;;
esac
