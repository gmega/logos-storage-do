# Embedded in the TUI. The caller supplies catalog fields as environment variables.
set -euo pipefail
umask 077
exec 8>file-action.lock
if [[ $(uname -s) == Darwin ]]; then
    lock_file() { perl -MFcntl=:flock -e 'open(my $fd, ">&=8") or die $!; exit !flock($fd, LOCK_EX|LOCK_NB)'; }
    bounded_cli() { perl -e 'alarm 35; exec @ARGV or die $!' ./runtime/AppRun "$@"; }
    file_size() { stat -f %z "$1"; }
    verify_file() { shasum -a 256 -c >/dev/null; }
else
    lock_file() { flock -n 8; }
    bounded_cli() { timeout 35 ./runtime/AppRun "$@"; }
    file_size() { stat -c %s "$1"; }
    verify_file() { sha256sum --check --status; }
fi
lock_file || { echo "A file operation is already running"; exit 1; }

call() {
    bounded_cli "--config-dir=$PWD/session" call storage_module "$@" |
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
if [[ $ACTION == mix ]]; then private=true; fi
echo "Starting $ACTION download..."
pending=true
call downloadToUrl "$CID" "$stage/payload" false 65536 "$private" false >/dev/null
for ((i=0; i<300; i++)); do
    bytes=$(file_size "$stage/payload" 2>/dev/null || echo 0)
    echo "$ACTION download: $((bytes*100/SIZE))%  ($bytes / $SIZE bytes)"
    if [[ $bytes == "$SIZE" ]]; then
        echo "Verifying SHA-256..."
        if ! (cd "$stage" && echo "$DIGEST  payload" | verify_file); then
            echo "SHA-256 mismatch. Download discarded."
            exit 1
        fi
        [[ ! -d "downloads/$NAME" ]] || exit 1
        mv -f "$stage/payload" "downloads/$NAME"
        pending=false
        echo "Saved downloads/$NAME"
        exit 0
    fi
    sleep 2
done
echo "Download timed out"
exit 1
