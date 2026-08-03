#!/usr/bin/env bash
set -e

data_dir=${1:-"./logos-storage-data"}
udp_spr_json=$(curl -s https://logos-storage-network.fra1.digitaloceanspaces.com/v0.2/udp-sprs.json)
tcp_spr_json=$(curl -s https://logos-storage-network.fra1.digitaloceanspaces.com/v0.2/tcp-sprs.json)
mp_json=$(curl -s https://logos-storage-network.fra1.digitaloceanspaces.com/v0.2/mix-pool.json | jq -c 'tostring')

cat <<EOF | jq .
{
  "nat": "auto",
  "log-level": "DEBUG",
  "mix-enabled": true,
  "listen-port": 8080,
  "disc-port": 8090,
  "bootstrap-node": $udp_spr_json,
  "dht-mix-proxy": $tcp_spr_json,
  "data-dir": "${data_dir}",
  "mix-pool-json": ${mp_json}
}
EOF