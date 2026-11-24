#!/usr/bin/env python3
"""Bounded file jobs. The service has no cloud credentials or arbitrary SSH access."""
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import secrets
import shutil
import subprocess
import threading
import time

ROOT = Path('/opt/logos-dashboard')
CACHE = Path('/var/lib/logos-dashboard/downloads')
JOBS = {}
LOCK = threading.Lock()
NODES = {}
FILES = {}

def ssh(node, action, file_id):
    return ['ssh', '-i', '/var/lib/logos-dashboard/id_ed25519', '-o', 'BatchMode=yes',
            '-o', 'StrictHostKeyChecking=yes', '-o', 'UserKnownHostsFile=/var/lib/logos-dashboard/known_hosts',
            '-o', 'ConnectTimeout=8', f'root@{NODES[node]["ip"]}', f'{action} {file_id}']

def validate(data):
    node, file_id, action = data.get('node'), data.get('file'), data.get('action')
    if node not in NODES or file_id not in FILES or action not in ('direct', 'mix', 'delete'):
        raise ValueError('Unknown node, file, or action')
    if action == 'delete' and NODES[node]['protected']:
        raise ValueError('RS1 retains the source files; deletion is disabled')
    return node, file_id, action

def transfer(job, path):
    errors = []
    with path.open('wb') as output:
        process = subprocess.Popen(ssh(job['node'], job['action'], job['file']),
                                   stdout=output, stderr=subprocess.PIPE, text=True)
        def read_progress():
            for line in process.stderr:
                if line.startswith('PROGRESS '):
                    try:
                        progress = json.loads(line[9:])
                        total = FILES[job['file']]['size']
                        if progress['phase'] in ('downloading', 'verifying-node', 'copying'):
                            job.update(phase=progress['phase'], totalBytes=total,
                                       nodeBytes=max(0, min(int(progress['nodeBytes']), total)))
                    except (ValueError, KeyError, TypeError):
                        pass
                else:
                    errors.append(line[-500:])
                    del errors[:-5]
        reader = threading.Thread(target=read_progress, daemon=True)
        reader.start()
        try:
            process.wait(timeout=660)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
            raise
        finally:
            reader.join(timeout=5)
            process.stderr.close()
        if process.returncode:
            raise RuntimeError(''.join(errors)[-500:] or 'Node operation failed')

def run_job(token):
    job = JOBS[token]
    path = CACHE / token
    try:
        transfer(job, path)
        if job['action'] != 'delete':
            job['phase'] = 'verifying-dashboard'
            with path.open('rb') as source:
                digest = hashlib.file_digest(source, 'sha256').hexdigest()
            if digest != FILES[job['file']]['sha256']:
                raise RuntimeError('Downloaded checksum does not match')
        else:
            path.unlink(missing_ok=True)
        job.update(state='ready', phase='ready')
    except Exception as error:
        path.unlink(missing_ok=True)
        job.update(state='failed', error=str(error))
    finally:
        job['expires'] = time.time() + 900

class Handler(BaseHTTPRequestHandler):
    def reply(self, status, value):
        body = json.dumps(value).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        if self.path != '/api/jobs':
            return self.reply(404, {'error': 'Not found'})
        # Custom header + JSON require a same-origin browser request; no CORS allowed.
        if self.headers.get('X-Dashboard-Request') != '1' or self.headers.get('Content-Type') != 'application/json':
            return self.reply(403, {'error': 'Same-origin JSON request required'})
        if self.headers.get('Sec-Fetch-Site') not in (None, 'same-origin'):
            return self.reply(403, {'error': 'Cross-origin request denied'})
        try:
            length = int(self.headers.get('Content-Length', '0'))
            if not 0 < length <= 1024:
                raise ValueError('Invalid request size')
            node, file_id, action = validate(json.loads(self.rfile.read(length)))
        except (ValueError, TypeError, AttributeError):
            return self.reply(400, {'error': 'Invalid request or protected source node'})
        with LOCK:
            for token, job in list(JOBS.items()):
                if job['state'] != 'running' and job['expires'] < time.time():
                    (CACHE / token).unlink(missing_ok=True)
                    del JOBS[token]
            running = [j for j in JOBS.values() if j['state'] == 'running']
            if len(running) >= 2 or any(j['node'] == node for j in running) or len(JOBS) >= 8:
                return self.reply(429, {'error': 'Transfer capacity is busy. Please try again later.'})
            token = secrets.token_hex(24)
            JOBS[token] = dict(node=node, file=file_id, action=action, state='running', phase='connecting', nodeBytes=0, totalBytes=FILES[file_id]['size'], expires=time.time()+1800)
            threading.Thread(target=run_job, args=(token,), daemon=True).start()
        self.reply(202, {'id': token})

    def do_GET(self):
        parts = self.path.split('/')
        if len(parts) not in (4, 5) or parts[1:3] != ['api', 'jobs']:
            return self.reply(404, {'error': 'Not found'})
        job = JOBS.get(parts[3])
        if not job or job['expires'] < time.time():
            return self.reply(404, {'error': 'Job expired'})
        if len(parts) == 4:
            payload = dict(job)
            path = CACHE / parts[3]
            try:
                payload['dashboardBytes'] = path.stat().st_size
            except FileNotFoundError:
                payload['dashboardBytes'] = 0
            return self.reply(200, payload)
        if parts[4] != 'content' or job['state'] != 'ready' or job['action'] == 'delete':
            return self.reply(409, {'error': 'File not ready'})
        item = FILES[job['file']]
        try:
            with (CACHE / parts[3]).open('rb') as source:
                self.send_response(200)
                self.send_header('Content-Type', item['type'])
                self.send_header('Content-Length', str(item['size']))
                disposition = 'inline' if item['type'] == 'application/pdf' else 'attachment'
                self.send_header('Content-Disposition', f'{disposition}; filename="{item["filename"]}"')
                self.end_headers()
                shutil.copyfileobj(source, self.wfile)
        except (BrokenPipeError, ConnectionResetError, FileNotFoundError):
            pass

if __name__ == '__main__':
    NODES.update((n['name'], n) for n in json.loads((ROOT / 'nodes.json').read_text()))
    FILES.update((f['id'], f) for f in json.loads((ROOT / 'files.json').read_text())['files'])
    CACHE.mkdir(exist_ok=True, mode=0o700)
    for path in CACHE.iterdir():
        path.unlink()
    ThreadingHTTPServer(('127.0.0.1', 8787), Handler).serve_forever()
