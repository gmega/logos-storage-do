#!/usr/bin/env python3
"""Resolve the newest published Linux dev build, refusing repeat deployments."""
import argparse
import datetime
import hashlib
import hmac
import os
import urllib.parse
import json
import re
import urllib.error
import urllib.request
from pathlib import Path

CATALOG = 'https://raw.githubusercontent.com/logos-co/logos-modules-dev/main/logos-repo.json'

def signed_metadata_request(url):
    """Spaces hides absent private-bucket keys behind anonymous HTTP 403."""
    key = os.environ.get('SPACES_ACCESS_KEY_ID')
    secret = os.environ.get('SPACES_SECRET_ACCESS_KEY')
    if not key or not secret:
        raise ValueError('Spaces credentials required to verify deployment metadata')
    parsed = urllib.parse.urlsplit(url)
    region = parsed.hostname.split('.')[-3]
    now = datetime.datetime.now(datetime.timezone.utc)
    stamp, day = now.strftime('%Y%m%dT%H%M%SZ'), now.strftime('%Y%m%d')
    payload_hash = hashlib.sha256(b'').hexdigest()
    headers = {'host': parsed.netloc, 'x-amz-content-sha256': payload_hash, 'x-amz-date': stamp}
    names = ';'.join(sorted(headers))
    canonical_headers = ''.join(f'{k}:{headers[k]}\n' for k in sorted(headers))
    canonical = '\n'.join(['GET', parsed.path or '/', parsed.query, canonical_headers, names, payload_hash])
    scope = f'{day}/{region}/s3/aws4_request'
    to_sign = '\n'.join(['AWS4-HMAC-SHA256', stamp, scope, hashlib.sha256(canonical.encode()).hexdigest()])
    signing_key = ('AWS4' + secret).encode()
    for value in [day, region, 's3', 'aws4_request']:
        signing_key = hmac.new(signing_key, value.encode(), hashlib.sha256).digest()
    signature = hmac.new(signing_key, to_sign.encode(), hashlib.sha256).hexdigest()
    headers['Authorization'] = f'AWS4-HMAC-SHA256 Credential={key}/{scope}, SignedHeaders={names}, Signature={signature}'
    return urllib.request.Request(url, headers=headers)

def fetch(url, missing_ok=False):
    try:
        with urllib.request.urlopen(url, timeout=60) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        if missing_ok and error.code == 404:
            return None
        if not missing_ok or error.code != 403:
            raise
    # Authenticate only the configured bucket metadata request. Never treat a
    # permission error as absence: the signed response must explicitly be 404.
    try:
        with urllib.request.urlopen(signed_metadata_request(url), timeout=60) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return None
        raise

def select_release(index):
    versions = next(p['versions'] for p in index['packages'] if p['name'] == 'storage_module')
    newest = max(versions, key=lambda v: v['releasedAt'])
    if 'linux-amd64' not in newest['manifest']['main']:
        raise ValueError('Newest release has no linux-amd64 binary; refusing an older fallback')
    if not re.fullmatch(r'[0-9A-Za-z.+-]+', newest['manifest']['version']):
        raise ValueError('Invalid catalog version')
    if not re.fullmatch(r'[a-f0-9]{64}', newest['sha256']):
        raise ValueError('Invalid catalog digest')
    return newest

def check_version(version, deployed, force=False):
    if deployed and deployed.get('version') == version and not force:
        raise ValueError(f'{version} is already deployed; use --force to redeploy')

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bucket-url', required=True)
    parser.add_argument('--output', required=True)
    parser.add_argument('--force', action='store_true')
    args = parser.parse_args()
    release = select_release(fetch(fetch(CATALOG)['indexUrl']))
    version = release['manifest']['version']
    deployed = fetch(args.bucket_url.rstrip('/') + '/metadata.json', True)
    check_version(version, deployed, args.force)
    result = {'deployment_version': version, 'module_url': release['url'],
              'module_sha256': release['sha256'], 'released_at': release['releasedAt']}
    output = Path(args.output)
    output.write_text(json.dumps(result, indent=2) + '\n')
    # Preserve the authoritative prior successful deployment through the
    # intermediate Terraform apply, even when this controller has stale files.
    metadata = output.parent / 'metadata.json'
    if deployed is None:
        metadata.unlink(missing_ok=True)
    else:
        metadata.write_text(json.dumps(deployed, indent=2) + '\n')
    print(f'Selected storage_module {version} ({release["releasedAt"]})')

if __name__ == '__main__':
    main()
