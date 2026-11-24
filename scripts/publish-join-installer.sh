#!/usr/bin/env bash
# Publish the standalone install.sh from the reviewed platform-specific Actions bundle.
set -euo pipefail
installer=${1:?Usage: publish-join-installer.sh /path/to/bundled/install.sh}
source "$(dirname "$0")/env.sh"
case "$(sed -n '2p' "$installer")" in
  bundle_platform=macos-arm64) object=install-macos-arm64.sh ;;
  bundle_platform=linux-x86_64|"unpack_tui() {") object=install-linux-x86_64.sh ;;
  *) echo "Unknown installer platform" >&2; exit 1 ;;
esac
url="https://logos-storage-network.fra1.digitaloceanspaces.com/v0.4/$object"
grep -q '^unpack_tui() {' "$installer" || { echo "Expected the bundled installer" >&2; exit 1; }
bash -n "$installer"
printf 'user = "%s:%s"\n' "${SPACES_ACCESS_KEY_ID:?}" "${SPACES_SECRET_ACCESS_KEY:?}" |
  curl --config - --fail --silent --show-error --aws-sigv4 'aws:amz:fra1:s3' \
    --header 'x-amz-acl: public-read' --header 'Content-Type: text/plain' \
    --header 'Cache-Control: no-cache' --upload-file "$installer" "$url"
curl -fsS "$url" | cmp "$installer" -
echo "Published $url"
