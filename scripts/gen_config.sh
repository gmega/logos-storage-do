#!/usr/bin/env bash
set -e

data_dir=${1:-"./logos-storage-data"}
tcp_spr_json=$(curl -s https://logos-storage-network.fra1.digitaloceanspaces.com/v0.2/tcp-sprs.json)
mp_json=$(curl -s https://logos-storage-network.fra1.digitaloceanspaces.com/v0.2/mix-pool.json | jq -c 'tostring')

format=${1:-"json"}

if [ "$format" == "json" ]; then
  format() {
    jq .
  }
elif [ "$format" == "toml" ]; then
  # requires tomli-w
  format() {
    python -c "import json, os, sys, tomli_w; print(tomli_w.dumps(json.load(sys.stdin)))"
  }
fi

cat <<EOF | format
{
  "nat": "auto",
  "log-level": "DEBUG",
  "mix-enabled": true,
  "listen-port": 8080,
  "bootstrap-node": $tcp_spr_json,
  "dht-mix-proxy": $tcp_spr_json,
  "data-dir": "${data_dir}",
  "mix-pool-json": ${mp_json}
}
EOF
