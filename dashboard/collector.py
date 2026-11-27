#!/usr/bin/env python3
"""Collect read-only debug snapshots over forced-command SSH, atomically."""
import concurrent.futures
import json
import os
from pathlib import Path
import subprocess
import time

ROOT = Path('/opt/logos-dashboard')
REQUIRED_SERVICES = (
    '/mix/1.0.0',
    '/libp2p/autonat/2/dial-request', '/libp2p/circuit/relay/0.2.0/hop',
)

def discovery_ready(providers):
    if not isinstance(providers, dict):
        return False
    def populated(service):
        peers = providers.get(service)
        return isinstance(peers, list) and bool(peers)
    return all(map(populated, REQUIRED_SERVICES)) and any(map(populated, (
        '/storage/dht-proxy/1.0.0', '/storage/dht-proxy/2.0.0',
    )))

def collect(node):
    result = {**node, 'checkedAt': int(time.time()), 'ok': False}
    try:
        command = ['ssh', '-i', '/var/lib/logos-dashboard/id_ed25519',
                   '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes',
                   '-o', 'UserKnownHostsFile=/var/lib/logos-dashboard/known_hosts',
                   '-o', 'ConnectTimeout=8', f'root@{node["ip"]}']
        response = subprocess.run(command, capture_output=True, text=True, timeout=40, check=True)
        snapshot = json.loads(response.stdout)
        result['manifests'] = snapshot.get('manifests', {}).get('result', {}).get('value')
        result.update(service=snapshot['service'], version=snapshot.get('version'))
        debug = snapshot['debug']['result']
        if not isinstance(debug, dict) or debug.get('success') is False:
            raise ValueError('debug call failed')
        value = debug['value']
        if not isinstance(value, dict):
            raise ValueError('debug value is not an object')
        providers = value.get('serviceProviders', {})
        result.update(debug=value, service=snapshot['service'], version=snapshot.get('version'),
                      ok=snapshot['service'] == 'active' and bool(value.get('spr')),
                      discoveryAvailable='serviceProviders' in value,
                      discoveryReady=discovery_ready(providers))
    except (subprocess.SubprocessError, ValueError, KeyError, TypeError) as error:
        result['error'] = str(error)
    return result

def main():
    nodes = json.loads((ROOT / 'nodes.json').read_text())
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        snapshots = list(pool.map(collect, nodes))
    payload = {'files': json.loads((ROOT / 'files.json').read_text())['files'], 'updatedAt': int(time.time()), 'nodes': snapshots}
    target = Path('/var/lib/logos-dashboard/health.json')
    temp = target.with_suffix('.tmp')
    temp.write_text(json.dumps(payload))
    os.chmod(temp, 0o644)
    temp.replace(target)

if __name__ == '__main__':
    main()
