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
compiler=(cc)
host=$(uname -sm)
if [[ $# == 2 && $1 == --macos-sdk && $host == 'Linux x86_64' ]]; then
  sdk=$2
  [[ -f "$sdk/usr/include/ncurses.h" ]] || { echo "Expected a macOS SDK with ncurses headers" >&2; exit 1; }
  compiler=(clang -target arm64-apple-macos14 -isysroot "$sdk" --ld-path="$(command -v ld64.lld)" -Wl,-platform_version,macos,14.0,14.4)
  host='Darwin arm64'
elif [[ $# != 0 ]]; then
  echo 'Usage: build.sh [--macos-sdk /path/to/MacOSX14.4.sdk]' >&2
  exit 1
fi
case "$host" in
  'Linux x86_64') platform=linux-x86_64; libs=(-static -lncursesw -ltinfo); decoder='base64 --decode' ;;
  'Darwin arm64') platform=macos-arm64; libs=(-mmacosx-version-min=14.0 -lncurses); decoder='base64 -D' ;;
  *) echo "Unsupported build host: $(uname -sm)" >&2; exit 1 ;;
esac
"${compiler[@]}" -Wall -Wextra -Werror -O2 -I"$tmp" tui.c "${libs[@]}" -o "$tmp/logos-devnet"
mv "$tmp/logos-devnet" "$out/"
# Put the executable inside the standalone installer for offline extraction.
{
  head -n 1 install.sh
  echo "bundle_platform=$platform"
  echo 'unpack_tui() {'
  echo "$decoder <<'LOGOS_TUI' | gzip -dc"
  gzip -nc "$out/logos-devnet" | base64
  echo 'LOGOS_TUI'
  echo '}'
  tail -n +2 install.sh
} > "$tmp/install.sh"
chmod 755 "$tmp/install.sh"
mv "$tmp/install.sh" "$out/install.sh"
tar czf "$out/logos-devnet-$platform.tar.gz" -C "$out" logos-devnet install.sh
