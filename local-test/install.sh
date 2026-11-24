#!/usr/bin/env bash
# Install the v0.4 devnet runtime for the current user.
set -euo pipefail
umask 077
case "$(uname -sm)" in
  'Linux x86_64') platform=linux-x86_64 ;;
  'Darwin arm64') platform=macos-arm64
    [[ $(sw_vers -productVersion | cut -d. -f1) -ge 14 ]] || { echo 'Requires macOS 14 or newer' >&2; exit 1; } ;;
  *) echo 'Requires Linux x86-64 or macOS on Apple Silicon' >&2; exit 1 ;;
esac
[[ ${bundle_platform:-$platform} == "$platform" ]] || { echo "Use the $platform installer from Join Devnet" >&2; exit 1; }
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
  [[ ! -d "$root/logos-devnet" ]] || return 1
  mv -f logos-devnet "$root/logos-devnet"
  printf 'Launch the TUI with %q\n' "$root/logos-devnet"
}
main() {
root=${LOGOS_DEVNET_HOME:-"${XDG_DATA_HOME:-$HOME/.local/share}/logos-devnet"}
mkdir -p "$root"
cd "$root"
root=$PWD
exec 9>install.lock
lock_install() {
  if [[ $platform == macos-arm64 ]]; then
    perl -MFcntl=:flock -e 'open(my $fd, ">&=9") or die $!; exit !flock($fd, LOCK_EX|LOCK_NB)'
  else
    flock -n 9
  fi
}
lock_install || { echo 'Another installation is running' >&2; exit 1; }
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
verify() {
  if [[ $platform == macos-arm64 ]]; then
    echo "$1  $2" | shasum -a 256 -c >/dev/null
  else
    echo "$1  $2" | sha256sum --check --status
  fi
}
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
if [[ $platform == macos-arm64 ]]; then
  archive=logosctl-aarch64-macos.tar.gz
  cli_sha=f78e8ffdb88e44db1733d43cdea66e7bf558a799fac4f9b88748680f53d79a71
else
  archive=logosctl-x86_64-linux.tar.gz
  cli_sha=294fbcc6409a8851b7471582bdad2dbfaf681b5d1c67dfffec38ada925dc6762
fi
fetch "https://github.com/logos-co/logos-logoscore-cli/releases/download/0.3.2/$archive" cli.tar.gz
verify "$cli_sha" cli.tar.gz
fetch "https://github.com/logos-co/logos-modules-dev/releases/download/storage_module-v$version/storage_module-$version.lgx" storage.lgx
verify "$digest" storage.lgx
tar xf cli.tar.gz
if [[ $platform == macos-arm64 ]]; then
  runtime=logosctl-aarch64-macos
  mv "$runtime"/modules-pkg/{storage_module,package_downloader} .
  cat >"$runtime/AppRun" <<'LAUNCH'
#!/bin/sh
exec "$(dirname "$0")/bin/logosctl" "$@"
LAUNCH
  chmod 755 "$runtime/AppRun"
else
  ./logosctl-x86_64.AppImage --appimage-extract >/dev/null
  runtime=squashfs-root
  mv "$runtime"/usr/modules-pkg/{storage_module,package_downloader} .
fi
if [[ ! -e "$root/runtime" ]]; then mv "$runtime" "$root/runtime"; fi
mkdir -p "$root"/{session,data,home}
# Some modules use HOME for their own files. Isolate them from existing nodes.
export HOME="$root/home"
if [[ $platform == macos-arm64 ]]; then
  # Match the installed LGX layout used by the module loader.
  mkdir package
  tar -xzf storage.lgx -C package manifest.json assets variants/darwin-arm64
  module=package/variants/darwin-arm64
  test -f "$module/storage_module_plugin.dylib"
  mv package/manifest.json package/assets "$module/"
  printf %s darwin-arm64 >"$module/variant"
  mkdir -p "$root/session/modules/storage_module"
  cp -R "$module/." "$root/session/modules/storage_module/"
else
  "$cli" "$session" daemon start --detach 9>&-
  started=true
  "$cli" "$session" install "$stage/storage.lgx" -y
  "$cli" "$session" daemon stop
  started=false
fi
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
