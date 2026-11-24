#!/usr/bin/env python3
"""Forced SSH command: only catalogued files; never evaluate client shell text."""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

ROOT = Path('/opt/logos-dashboard')

def call(method, *args):
    result = json.loads(subprocess.check_output(
        ['logosctl', '--config-dir=/var/lib/logoscore', 'call', 'storage_module', method, *args], timeout=30))['result']
    if not result.get('success'):
        raise RuntimeError(result.get('error') or 'Storage operation failed')
    return result.get('value')

def progress(phase, downloaded, total):
    print('PROGRESS ' + json.dumps({'phase': phase, 'nodeBytes': downloaded, 'totalBytes': total}),
          file=sys.stderr, flush=True)

def main():
    command = os.environ.get('SSH_ORIGINAL_COMMAND', '')
    if not command:
        os.execv('/opt/logos/health-snapshot.sh', ['health-snapshot.sh'])
    parts = command.split()
    if len(parts) != 2 or parts[0] not in ('direct', 'mix', 'delete'):
        raise ValueError('Unsupported operation')
    action, file_id = parts
    config = json.loads((ROOT / 'files.json').read_text())
    item = next(f for f in config['files'] if f['id'] == file_id)
    if action == 'delete' and config['protected']:
        raise ValueError('RS1 keeps the source files; deletion is disabled')
    with open('/opt/logos/dashboard-files.lock', 'w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        target = Path('/opt/logos/dashboard-download.bin')
        if action == 'delete':
            call('remove', item['cid'])
            for _ in range(120):
                if not any(m['cid'] == item['cid'] for m in call('manifests')):
                    target.unlink(missing_ok=True)
                    print('{}')
                    return
                time.sleep(2)
            raise TimeoutError('Removal did not finish')
        target.unlink(missing_ok=True)
        progress('downloading', 0, item['size'])
        call('downloadToUrl', item['cid'], str(target), 'false', '65536',
             'true' if action == 'mix' else 'false', 'false' if action == 'mix' else 'true')
        for _ in range(300):
            size = target.stat().st_size if target.exists() else 0
            progress('downloading', min(size, item['size']), item['size'])
            if size == item['size']:
                progress('verifying-node', size, item['size'])
                with target.open('rb') as source:
                    digest = hashlib.file_digest(source, 'sha256').hexdigest()
                if digest == item['sha256']:
                    progress('copying', size, item['size'])
                    with target.open('rb') as source:
                        shutil.copyfileobj(source, sys.stdout.buffer)
                    target.unlink(missing_ok=True)
                    return
            time.sleep(2)
        try:
            call('downloadCancel', item['cid'])
        finally:
            target.unlink(missing_ok=True)
        raise TimeoutError('Download did not finish within ten minutes')

if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
