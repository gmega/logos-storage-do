#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
out=../artifacts/local-test
mkdir -p "$out"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
{
  echo 'static const char file_action[] ='
  jq -Rs . file-action.sh
  echo ';'
  echo 'static const struct item catalog[] = {'
  jq -r '.[] | "{" + ([.label,.filename,.cid,.sha256,(.size|tostring)] | map(@json) | join(",")) + "},"' catalog.json
  echo '};'
} > "$tmp/embedded.h"
cc -Wall -Wextra -Werror -O2 -static -I"$tmp" tui.c -lncursesw -ltinfo -o "$tmp/logos-devnet"
mv "$tmp/logos-devnet" "$out/"
# Put the executable inside the standalone installer for offline extraction.
{
  head -n 1 install.sh
  echo 'unpack_tui() {'
  echo "base64 --decode <<'LOGOS_TUI' | gzip -dc"
  gzip -nc "$out/logos-devnet" | base64
  echo 'LOGOS_TUI'
  echo '}'
  tail -n +2 install.sh
} > "$tmp/install.sh"
chmod 755 "$tmp/install.sh"
mv "$tmp/install.sh" "$out/install.sh"
tar czf "$out/logos-devnet-linux-x86_64.tar.gz" -C "$out" logos-devnet install.sh
