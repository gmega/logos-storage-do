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
install_runtime() {
  if [[ $platform == macos-arm64 ]]; then
    archive=logosctl-aarch64-macos.tar.gz
    cli_sha=f78e8ffdb88e44db1733d43cdea66e7bf558a799fac4f9b88748680f53d79a71
  else
    archive=logosctl-x86_64-linux.tar.gz
    cli_sha=294fbcc6409a8851b7471582bdad2dbfaf681b5d1c67dfffec38ada925dc6762
  fi
  fetch "https://github.com/logos-co/logos-logoscore-cli/releases/download/0.3.2/$archive" cli.tar.gz
  verify "$cli_sha" cli.tar.gz
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
  mv "$runtime" "$root/runtime"
}
main() {
root=${LOGOS_DEVNET_HOME:-"${XDG_DATA_HOME:-$HOME/.local/share}/logos-devnet"}
mkdir -p "$root"
cd "$root"
root=$PWD
exec 9>install.lock
lock_fd() {
  if [[ $platform == macos-arm64 ]]; then
    perl -MFcntl=:flock -e 'open(my $fd, ">&=$ARGV[0]") or die $!; exit !flock($fd, LOCK_EX|LOCK_NB)' "$1"
  else
    flock -n "$1"
  fi
}
lock_fd 9 || { echo 'Another installation is running' >&2; exit 1; }
exec 8>"$root/tui.lock"
lock_fd 8 || { echo 'Stop your node and quit the TUI, then rerun the installer.' >&2; exit 1; }
stage=$(mktemp -d "$root/.setup.XXXXXX")
cli="$root/runtime/AppRun"
session="--config-dir=$root/session"
live_module="$root/session/modules/storage_module"
previous="$root/.previous-storage-module"
cleanup() {
  if [[ -d "$previous" && ! -e "$live_module" ]]; then mv "$previous" "$live_module"; fi
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
fetch "$bucket/metadata.json" metadata
version=$(jq -er '.version | select(test("^[a-zA-Z0-9.+-]+$"))' metadata)
digest=$(jq -er '.module_sha256 | select(test("^[0-9a-f]{64}$"))' metadata)
# Preserve local settings, including the data directory that holds the node identity.
if [[ -f "$root/config.json" ]]; then
  jq --slurpfile records sprs 'del(.network, ."no-bootstrap-node") |
    ."bootstrap-node" = $records[0]' "$root/config.json" >config.json
else
  jq -n --arg data "$root/data" --slurpfile records sprs '{
    "data-dir":$data, "log-level":"DEBUG", "listen-ip":"0.0.0.0",
    "listen-port":8090, "mix-enabled":true, "bootstrap-node":$records[0]
  }' >config.json
fi

if [[ ! -x "$cli" ]]; then
  install_runtime
fi
mkdir -p "$root"/{session/modules,data,home}
if [[ $platform == macos-arm64 ]]; then
  variant=darwin-arm64
  plugin=storage_module_plugin.dylib
else
  variant=linux-amd64
  plugin=storage_module_plugin.so
fi
if [[ -f "$root/installed" && -s "$live_module/$plugin" && ! -e "$previous" ]] &&
   jq -e --arg v "$version" --arg d "$digest" '.version == $v and .module_sha256 == $d' "$root/installed" >/dev/null &&
   jq -e --arg v "$version" '.version == $v' "$live_module/manifest.json" >/dev/null; then
  echo "Storage module $version is current"
else
  if [[ -d "$root/session/daemon" ]]; then
    # logosctl also returns exit code 1 for a normally stopped daemon.
    daemon_info=$("$cli" "$session" daemon status) || [[ $? == 1 ]]
    case $(jq -er '.daemon.status' <<<"$daemon_info") in
      not_running|not_configured) ;;
      running) echo 'Stop your node before updating the storage module, then rerun the installer.' >&2; exit 1 ;;
      *) echo 'Could not confirm that the local node is stopped.' >&2; exit 1 ;;
    esac
  fi
  fetch "https://github.com/logos-co/logos-modules-dev/releases/download/storage_module-v$version/storage_module-$version.lgx" storage.lgx
  verify "$digest" storage.lgx
  # Stage a complete native module before touching the installed copy.
  tar -xzf storage.lgx manifest.json assets "variants/$variant"
  module="variants/$variant"
  test -s "$module/$plugin"
  jq -e --arg v "$version" '.name == "storage_module" and .version == $v' manifest.json >/dev/null
  mv manifest.json assets "$module/"
  printf %s "$variant" >"$module/variant"
  if [[ -d "$live_module" ]]; then
    rm -rf -- "$previous"
    mv "$live_module" "$previous"
  fi
  mv "$module" "$live_module"
  echo "Installed storage module $version"
fi
mv config.json "$root/config.json"
mv sprs "$root/devnet-sprs.json"
finish_tui
mv metadata "$root/installed"
rm -rf -- "$previous"
}
main </dev/null
