#!/usr/bin/env python3
"""Forced SSH command: catalogued file operations and read-only name resolution."""
import errno
import fcntl
import hashlib
import json
import os
import pty
import re
import select
import signal
from pathlib import Path
import shutil
import subprocess
import sys
import time

ROOT = Path('/opt/logos-dashboard')

CLI = ['logosctl', '--config-dir=/var/lib/logoscore']

def call(method, *args):
    result = json.loads(subprocess.check_output(
        [*CLI, 'call', 'storage_module', method, *args], timeout=30))['result']
    if not result.get('success'):
        raise RuntimeError(result.get('error') or 'Storage operation failed')
    return result.get('value')

def watch_lines(fd, timeout):
    deadline = time.monotonic() + timeout
    pending = b''
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0 or not select.select([fd], [], [], remaining)[0]:
            raise TimeoutError('Timed out waiting for a name service event')
        try:
            chunk = os.read(fd, 8192)
        except OSError as error:
            if error.errno == errno.EIO:  # Linux PTY peer closed
                raise RuntimeError('Name service watcher exited') from error
            raise
        if not chunk:
            raise RuntimeError('Name service watcher exited')
        pending += chunk
        while b'\n' in pending:
            line, pending = pending.split(b'\n', 1)
            yield line.decode().strip()

def name_operation(method, args, expected):
    event = 'storage' + method[0].upper() + method[1:] + 'Done'
    # The CLI prints its subscription-ready message only when stdout is a TTY.
    reader, terminal = pty.openpty()
    try:
        with subprocess.Popen([*CLI, 'watch', 'storage_module', '--event', event],
                              stdout=terminal, stderr=terminal, start_new_session=True) as watch:
            try:
                os.close(terminal)
                terminal = None
                matching_event = False
                for line in watch_lines(reader, 15):
                    if line.startswith("Watching events from 'storage_module'"):
                        break
                call(method, *args)
                for line in watch_lines(reader, 150):
                    if ' :: ' in line and line.startswith('['):
                        matching_event = line.endswith('storage_module :: ' + event)
                    elif matching_event and line.startswith('arg0: '):
                        payload = json.loads(line[6:])
                        if all(payload.get(k) == v for k, v in expected.items()):
                            if payload.get('success') is not True:
                                raise RuntimeError(payload.get('error') or 'Name service operation failed')
                            return payload
            finally:
                if watch.poll() is None:
                    os.killpg(watch.pid, signal.SIGKILL)
    finally:
        os.close(reader)
        if terminal is not None:
            os.close(terminal)

def publish(label, cid):
    result = name_operation('namePublish', [label, cid, '0'], {'label': label, 'cid': cid})
    if not result.get('nameKey'):
        raise ValueError('Publisher returned an empty name CID')
    print(json.dumps({'label': label, 'nameKey': result['nameKey']}))

def progress(phase, downloaded, total):
    print('PROGRESS ' + json.dumps({'phase': phase, 'nodeBytes': downloaded, 'totalBytes': total}),
          file=sys.stderr, flush=True)

def main():
    command = os.environ.get('SSH_ORIGINAL_COMMAND', '')
    if not command:
        os.execv('/opt/logos/health-snapshot.sh', ['health-snapshot.sh'])
    parts = command.split()
    if len(parts) == 2 and parts[0] == 'resolve':
        key = parts[1]
        if not re.fullmatch(r'[A-Za-z0-9]{1,512}', key) or call('isNameKey', key) is not True:
            raise ValueError('Enter a valid name CID')
        result = name_operation('nameResolve', [key], {'nameKey': key})
        print(json.dumps({'cid': result['cid']}))
        return
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
        if len(sys.argv) == 4 and sys.argv[1] == 'publish':
            publish(*sys.argv[2:])
        else:
            main()
    except Exception as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
