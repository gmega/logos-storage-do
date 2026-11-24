import importlib.util
import json
import hashlib
import subprocess
import sys
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

server = load('files_server', 'dashboard/server.py')
node = load('node_files', 'dashboard/node-files.py')

class FileTests(unittest.TestCase):
    def setUp(self):
        server.NODES = {'rs1': {'protected': True}, 'mp1': {'protected': False}}
        server.FILES = {'book': {'cid': 'fixed'}}

    def test_only_allowlisted_actions_and_targets(self):
        for request in [dict(node='elsewhere', file='book', action='direct'),
                        dict(node='mp1', file='../../etc/passwd', action='direct'),
                        dict(node='mp1', file='book', action='reboot'),
                        dict(node='rs1', file='book', action='delete')]:
            with self.assertRaises(ValueError):
                server.validate(request)
        self.assertEqual(server.validate(dict(node='mp1', file='book', action='mix')), ('mp1', 'book', 'mix'))

    def test_ssh_dispatch_never_executes_arbitrary_command(self):
        for command in ['cat /etc/passwd', 'direct book;reboot', 'direct book extra']:
            with patch.dict(os.environ, SSH_ORIGINAL_COMMAND=command), patch.object(node, 'call') as call:
                with self.assertRaises((ValueError, FileNotFoundError, StopIteration)):
                    node.main()
                call.assert_not_called()

    def test_download_ready_only_after_checksum_verification(self):
        for valid in (False, True):
            with tempfile.TemporaryDirectory() as directory:
                server.JOBS = {'token': dict(node='mp1', file='book', action='mix', state='running')}
                server.FILES['book']['sha256'] = hashlib.sha256(b'expected').hexdigest()
                def download(job, path):
                    path.write_bytes(b'expected' if valid else b'truncated')
                with patch.object(server, 'CACHE', Path(directory)), patch.object(server, 'ssh', return_value=[]), patch.object(server, 'transfer', side_effect=download):
                    server.run_job('token')
                self.assertEqual(server.JOBS['token']['state'], 'ready' if valid else 'failed')
                self.assertEqual(Path(directory, 'token').exists(), valid)

    def test_progress_stream_is_separate_from_file_bytes(self):
        server.FILES['book']['size'] = 12
        job = dict(node='mp1', file='book', action='mix')
        command = [sys.executable, '-c',
                   '''import sys; print('PROGRESS {"phase":"copying","nodeBytes":12}', file=sys.stderr, flush=True); sys.stdout.buffer.write(b"file payload")''']
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory, 'download')
            with patch.object(server, 'ssh', return_value=command):
                server.transfer(job, path)
            self.assertEqual(path.read_bytes(), b'file payload')
        self.assertEqual(job['nodeBytes'], 12)
        self.assertEqual(job['phase'], 'copying')

    def test_source_protected_at_node_even_if_server_bypassed(self):
        with tempfile.TemporaryDirectory() as directory:
            Path(directory, 'files.json').write_text(json.dumps({'protected': True, 'files': [{'id': 'book'}]}))
            with patch.object(node, 'ROOT', Path(directory)), patch.dict(os.environ, SSH_ORIGINAL_COMMAND='delete book'), patch.object(node, 'call') as call:
                with self.assertRaises(ValueError):
                    node.main()
                call.assert_not_called()

if __name__ == '__main__':
    unittest.main()
