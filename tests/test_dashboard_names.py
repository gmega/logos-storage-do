import io
import json
import os
import subprocess
import unittest
from unittest.mock import Mock, patch

from test_dashboard_files import node, server


class NameServiceTests(unittest.TestCase):
    def request(self, data):
        handler = Mock(path='/api/resolve')
        body = json.dumps(data).encode()
        handler.headers = {'X-Dashboard-Request': '1', 'Content-Type': 'application/json',
                           'Content-Length': str(len(body))}
        handler.rfile = io.BytesIO(body)
        with patch.dict(server.NODES, mp={'protected': False}, rs={'protected': True}):
            server.Handler.do_POST(handler)
        return handler

    def test_api_dispatches_lookup_only_for_valid_target_and_key(self):
        self.request({'node': 'mp', 'nameKey': 'zABC'}).resolve.assert_called_once_with('mp', 'zABC')
        for host, key in [('mp', 'a b'), ('rs', 'zABC'), ('missing', 'zABC'), ('mp', None)]:
            handler = self.request({'node': host, 'nameKey': key})
            handler.resolve.assert_not_called()
            self.assertEqual(handler.reply.call_args.args[0], 400)

    def test_resolver_returns_empty_lookup_or_node_failure(self):
        for code, output, status in [(0, '{"cid":""}', 200), (1, '', 502), (0, '{}', 502)]:
            handler = Mock()
            reply = subprocess.CompletedProcess([], code, output, 'Node lookup failed')
            with patch.object(server, 'ssh', return_value=[]), patch.object(server.subprocess, 'run', return_value=reply):
                server.Handler.resolve(handler, 'mp', 'zABC')
            self.assertEqual(handler.reply.call_args.args[0], status)
            if status == 200:
                self.assertEqual(handler.reply.call_args.args[1], {'cid': ''})

    def test_node_validates_name_before_network_lookup(self):
        with patch.dict(os.environ, SSH_ORIGINAL_COMMAND='resolve dataset'), patch.object(node, 'call', return_value=False) as check, patch.object(node, 'name_operation') as lookup:
            with self.assertRaisesRegex(ValueError, 'valid name CID'):
                node.main()
            check.assert_called_once_with('isNameKey', 'dataset')
            lookup.assert_not_called()
