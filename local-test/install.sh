#!/usr/bin/env bash
# Install the v0.4 devnet runtime for the current user.
set -euo pipefail
umask 077
[[ $(uname -sm) == 'Linux x86_64' ]] || { echo 'Requires Linux x86-64' >&2; exit 1; }
if ! declare -F unpack_tui >/dev/null; then
  script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
fi
# The release build inserts its precompiled TUI here.
stage_tui() {
  if declare -F unpack_tui >/dev/null; then
    unpack_tui >logos-devnet
  elif [[ -f "$script_dir/logos-devnet" ]]; then
    cp -- "$script_dir/logos-devnet" logos-devnet
  else
    "$script_dir/build.sh"
    cp -- "$script_dir/../artifacts/local-test/logos-devnet" logos-devnet
  fi
  chmod 755 logos-devnet
}
finish_tui() {
  mv -fT -- logos-devnet "$root/logos-devnet"
  printf 'Launch the TUI with %q\n' "$root/logos-devnet"
}
main() {
root=${LOGOS_DEVNET_HOME:-"${XDG_DATA_HOME:-$HOME/.local/share}/logos-devnet"}
mkdir -p "$root"
cd "$root"
root=$PWD
exec 9>install.lock
flock -n 9 || { echo 'Another installation is running' >&2; exit 1; }
stage=$(mktemp -d "$root/.setup.XXXXXX")
cli="$root/runtime/AppRun"
session="--config-dir=$root/session"
started=false
cleanup() {
  if $started; then "$cli" "$session" daemon stop || true; fi
  rm -rf -- "$stage"
}
trap cleanup EXIT
cd "$stage"
stage_tui
fetch() { curl --fail --location --silent --show-error --retry 2 "$1" -o "$2"; }
verify() { echo "$1  $2" | sha256sum --check --status; }
bucket=https://logos-storage-network.fra1.digitaloceanspaces.com
fetch "$bucket/v0.4/tcp-sprs.json" sprs
jq -e 'type == "array" and length > 0 and all(.[]; type == "string" and startswith("spr:"))' sprs >/dev/null
# Keep the authoritative records separately so Start can replace a stale preset.
if [[ -f "$root/installed" ]]; then
    jq --slurpfile records sprs 'del(.network, ."no-bootstrap-node") |
      ."bootstrap-node" = $records[0]' "$root/config.json" >config.json
    mv sprs "$root/devnet-sprs.json"
    mv config.json "$root/config.json"
    echo "Refreshed private devnet bootstrap records in $root"
    finish_tui
    exit 0
fi
fetch "$bucket/metadata.json" metadata
version=$(jq -er '.version | select(test("^[a-zA-Z0-9.+-]+$"))' metadata)
digest=$(jq -er '.module_sha256 | select(test("^[0-9a-f]{64}$"))' metadata)
fetch https://github.com/logos-co/logos-logoscore-cli/releases/download/0.3.2/logosctl-x86_64-linux.tar.gz cli.tar.gz
verify 294fbcc6409a8851b7471582bdad2dbfaf681b5d1c67dfffec38ada925dc6762 cli.tar.gz
fetch "https://github.com/logos-co/logos-modules-dev/releases/download/storage_module-v$version/storage_module-$version.lgx" storage.lgx
verify "$digest" storage.lgx
tar xf cli.tar.gz
./logosctl-x86_64.AppImage --appimage-extract >/dev/null
mv squashfs-root/usr/modules-pkg/{storage_module,package_downloader} .
if [[ ! -e "$root/runtime" ]]; then mv squashfs-root "$root/runtime"; fi
mkdir -p "$root"/{session,data,home}
# Some modules use HOME for their own files. Isolate them from existing nodes.
export HOME="$root/home"
"$cli" "$session" daemon start --detach 9>&-
started=true
"$cli" "$session" install "$stage/storage.lgx" -y
"$cli" "$session" daemon stop
started=false
jq -n --arg data "$root/data" --slurpfile sprs sprs '{
  "data-dir":$data, "log-level":"DEBUG", "listen-ip":"0.0.0.0",
  "listen-port":8090, "mix-enabled":true, "bootstrap-node":$sprs[0]
}' >config.json
mv config.json "$root/config.json"
mv sprs "$root/devnet-sprs.json"
mv metadata "$root/installed"
echo "Installed $version in $root"
finish_tui
}
main </dev/null
