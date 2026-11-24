# Embedded in the TUI. The caller supplies catalog fields as environment variables.
set -euo pipefail
umask 077
exec 8>file-action.lock
flock -n 8 || { echo "A file operation is already running"; exit 1; }

call() {
    timeout 35 ./runtime/AppRun "--config-dir=$PWD/session" call storage_module "$@" |
        jq -ce '.result | if .success then .value else error(.error // "Storage operation failed") end'
}
if [[ $ACTION == delete ]]; then
    echo "Removing $NAME from local storage..."
    call remove "$CID" >/dev/null
    for ((i=0; i<120; i++)); do
        manifests=$(call manifests)
        if jq -e --arg cid "$CID" 'type == "array" and all(.[]; .cid != $cid)' <<<"$manifests" >/dev/null; then
            echo "Removed from node. Exported copies are kept."
            exit 0
        fi
        sleep 2
    done
    echo "Removal timed out"
    exit 1
fi

mkdir -p downloads
stage=$(mktemp -d "$PWD/downloads/.transfer.XXXXXXXX")
pending=false
cleanup() {
    if $pending; then call downloadCancel "$CID" >/dev/null 2>&1 || true; fi
    rm -rf -- "$stage"
}
trap cleanup EXIT
private=false
advertise=true
if [[ $ACTION == mix ]]; then private=true; advertise=false; fi
echo "Starting $ACTION download..."
pending=true
call downloadToUrl "$CID" "$stage/payload" false 65536 "$private" "$advertise" >/dev/null
for ((i=0; i<300; i++)); do
    bytes=$(stat -c %s "$stage/payload" 2>/dev/null || echo 0)
    echo "$ACTION download: $((bytes*100/SIZE))%  ($bytes / $SIZE bytes)"
    if [[ $bytes == "$SIZE" ]]; then
        echo "Verifying SHA-256..."
        if ! (cd "$stage" && echo "$DIGEST  payload" | sha256sum --check --status); then
            echo "SHA-256 mismatch. Download discarded."
            exit 1
        fi
        mv -fT "$stage/payload" "downloads/$NAME"
        pending=false
        echo "Saved downloads/$NAME"
        exit 0
    fi
    sleep 2
done
echo "Download timed out"
exit 1
