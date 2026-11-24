#!/usr/bin/env python3
"""Verify public HTTPS access and fresh node health."""
import json
from pathlib import Path
import ssl
import sys
import time
import urllib.request

root = Path(__file__).resolve().parent / '.dashboard'
context = ssl.create_default_context(cafile=str(root / 'server.crt'))
url = sys.argv[1].rstrip('/') + '/health.json'
with urllib.request.urlopen(sys.argv[1], context=context, timeout=15) as response:
    assert response.status == 200
request = urllib.request.Request(url)
for attempt in range(12):
    with urllib.request.urlopen(request, context=context, timeout=15) as response:
        data = json.load(response)
    if (time.time() - data['updatedAt'] < 90 and data['nodes'] and
        all(n['ok'] and n.get('discoveryReady') for n in data['nodes'])):
        print(f'Dashboard verified: public HTTPS, {len(data["nodes"])} healthy nodes')
        break
    if attempt == 11:
        raise SystemExit('Dashboard snapshots are stale or nodes/discovery are unhealthy')
    time.sleep(5)
