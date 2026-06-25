#!/usr/bin/env bash
# Creates a DigitalOcean Spaces access key (out-of-band, via doctl) and writes
# it to scripts/.spaces.env (gitignored, chmod 600). Terraform consumes it as an
# input through the SPACES_ACCESS_KEY_ID / SPACES_SECRET_ACCESS_KEY env vars.
#
# Idempotent: if .spaces.env already exists it does nothing (the secret is only
# shown once, at creation).
#
# Env overrides:
#   BUCKET      bucket the key is for          (default: logos-storage-network)
#   KEY_NAME    Spaces key name               (default: <BUCKET>-deploy)
#   PERMISSION  read | readwrite | fullaccess (default: fullaccess)
#
# Note: DigitalOcean rejects bucket-scoped grants (read/readwrite) for buckets
# that do not exist yet ("403 invalid grant"). Since Terraform creates the
# bucket, the deploy key needs 'fullaccess'.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUCKET="${BUCKET:-logos-storage-network}"
KEY_NAME="${KEY_NAME:-${BUCKET}-deploy}"
PERMISSION="${PERMISSION:-fullaccess}"
OUT="${HERE}/.spaces.env"

export DIGITALOCEAN_ACCESS_TOKEN="${DIGITALOCEAN_ACCESS_TOKEN:-${DO_TOKEN:-}}"
if [[ -z "${DIGITALOCEAN_ACCESS_TOKEN}" ]]; then
  echo "ERROR: set DO_TOKEN or DIGITALOCEAN_ACCESS_TOKEN first." >&2
  exit 1
fi

if [[ -f "${OUT}" ]]; then
  echo "${OUT} already exists; reusing it. Delete it to mint a new key." >&2
  exit 0
fi

if [[ "${PERMISSION}" == "fullaccess" ]]; then
  grant="bucket=;permission=fullaccess"
else
  grant="bucket=${BUCKET};permission=${PERMISSION}"
fi

echo "Creating Spaces key '${KEY_NAME}' (grant: ${grant})..." >&2
json="$(doctl spaces keys create "${KEY_NAME}" --grants "${grant}" --output json)"

access="$(echo "${json}" | jq -r 'if type=="array" then .[0] else . end | .access_key // .accessKey // empty')"
secret="$(echo "${json}" | jq -r 'if type=="array" then .[0] else . end | .secret_key // .secretKey // empty')"

if [[ -z "${access}" || -z "${secret}" ]]; then
  echo "ERROR: could not parse access/secret from doctl output:" >&2
  echo "${json}" >&2
  exit 1
fi

umask 077
cat > "${OUT}" <<EOF
SPACES_ACCESS_KEY_ID=${access}
SPACES_SECRET_ACCESS_KEY=${secret}
EOF

echo "Wrote ${OUT} (chmod 600). Run 'source scripts/env.sh' to load it." >&2
