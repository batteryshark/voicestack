"""Only ephemeral fake loopback servers and temporary state; no real enrollment."""
import base64
import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import stat
import tempfile
import threading
import time
import unittest
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest import mock

spec = importlib.util.spec_from_file_location('pair_openchamber',
    Path(__file__).with_name('pair_openchamber.py'))
pair = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pair)

SECRET = 'synthetic_pairing_secret_NEVER_PRINT'
TOKEN = 'oc_client_synthetic_token_NEVER_PRINT'


class PairingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve() / 'openchamber'
        self.posts = []
        self.gets = 0
        self.mode = 'success'
        self.client_changes = {}
        self.server_changes = {}
        test = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_args):
                pass

            def reply(self, code, value):
                raw = json.dumps(value).encode()
                self.send_response(code)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(raw)))
                self.send_header('X-Untrusted', SECRET)
                self.end_headers()
                self.wfile.write(raw)

            def do_GET(self):
                test.gets += 1
                if test.mode == 'redirect':
                    self.send_response(302)
                    self.send_header('Location', test.origin + '/leak?' + SECRET)
                    self.end_headers()
                elif test.mode == 'bad-health':
                    self.reply(200, {'body': SECRET})
                else:
                    self.reply(200, {'openchamberVersion': 'fake-test'})

            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                test.posts.append((self.path, body))
                if test.mode == '400':
                    self.reply(400, {'body': SECRET, 'token': TOKEN})
                    return
                self.reply(200, {'ok': True,
                    'server': {'fingerprint': 'wrong' if test.mode == 'fingerprint' else 'fp-test',
                               'url': test.origin, **test.server_changes},
                    'client': {'id': 'client-test', 'clientKind': 'desktop',
                               'label': 'Voicestack', 'deviceName': 'Voicestack', **test.client_changes},
                    'clientToken': TOKEN})

        self.server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.origin = 'http://127.0.0.1:' + str(self.server.server_port)
        thread = threading.Thread(target=self.server.serve_forever, kwargs={'poll_interval': 0.01}, daemon=True)
        thread.start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)

    def link(self, **changes):
        data = {'pairingId': 'pair-test', 'secret': SECRET, 'fingerprint': 'fp-test',
                'expiresAt': datetime.fromtimestamp(time.time() + 300, timezone.utc).isoformat(),
                'candidates': [{'type': 'loopback', 'url': self.origin}]}
        data.update(changes)
        return 'openchamber://connect?v=2&p=' + base64.urlsafe_b64encode(
            json.dumps(data).encode()).decode().rstrip('=')

    def cli(self, command, link=''):
        out, err = io.StringIO(), io.StringIO()
        with mock.patch.object(pair.sys, 'stdin', io.StringIO(link)), \
                contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = pair.main(command, root=self.root)
        output = out.getvalue() + err.getvalue()
        # Boolean assertions intentionally cannot include secrets in failure output.
        for secret in (SECRET, TOKEN, link):
            if secret:
                self.assertFalse(secret in output, 'sensitive output detected')
        return code, output

    def test_success_private_binding_status_and_request(self):
        link = self.link()
        self.assertEqual(self.cli(['redeem'], link)[0], 0)
        binding = pair.read_private(self.root / 'client.json')
        self.assertTrue(binding['clientToken'] == TOKEN)
        self.assertEqual(set(binding), {'version', 'clientId', 'clientToken', 'clientKind',
            'label', 'fingerprint', 'enrolledOrigin', 'dedupeKey'})
        self.assertEqual(stat.S_IMODE(self.root.stat().st_mode), 0o700)
        for path in self.root.iterdir():
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        self.assertEqual(len(self.posts), 1)
        path, request = self.posts[0]
        self.assertEqual(path, '/api/client-auth/pairing/redeem')
        self.assertTrue(request['secret'] == SECRET)
        self.assertEqual(request['clientLabel'], 'Voicestack')
        self.assertEqual(request['deviceName'], 'Voicestack')
        self.assertEqual(request['clientKind'], 'desktop')
        self.assertEqual(request['dedupeKey'], binding['dedupeKey'])
        self.assertEqual(pair.identity(self.root), binding['dedupeKey'])
        ledger = pair.read_private(self.root / 'attempt.json')
        self.assertEqual(ledger, {'linkDigests': [hashlib.sha256(link.encode()).hexdigest()]})
        code, output = self.cli(['status'])
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(output), {'bindingExists': True, 'clientId': 'client-test',
            'label': 'Voicestack', 'clientKind': 'desktop', 'origin': self.origin})

    def test_expired(self):
        link = self.link(expiresAt='2020-01-01T00:00:00Z')
        self.assertEqual(self.cli(['redeem'], link)[0], 1)
        self.assertEqual((self.gets, len(self.posts)), (0, 0))

    def test_expiry_rechecked_after_health(self):
        link = self.link()
        original = pair.health
        def health(origin):
            original(origin)
            clock.return_value = time.time() + 601
        with mock.patch.object(pair.time, 'time', wraps=time.time) as clock, \
                mock.patch.object(pair, 'health', side_effect=health):
            self.assertEqual(self.cli(['redeem'], link)[0], 1)
        self.assertEqual((self.gets, len(self.posts)), (1, 0))

    def test_wrong_fingerprint(self):
        self.mode = 'fingerprint'
        code, output = self.cli(['redeem'], self.link())
        self.assertEqual(code, 1)
        self.assertIn('device was created but not stored', output)
        self.assertIn('Revoke the device', output)
        self.assertEqual(len(self.posts), 1)
        self.assertFalse((self.root / 'client.json').exists())

    def assert_label_saved(self, label):
        self.client_changes = {'label': label}
        self.assertEqual(self.cli(['redeem'], self.link())[0], 0)
        self.assertTrue(pair.read_private(self.root / 'client.json')['label'] == label)
        code, output = self.cli(['status'])
        self.assertEqual(code, 0)
        self.assertTrue(json.loads(output)['label'] == label)

    def test_label_case_preserved(self):
        self.assert_label_saved('VoiceStack')

    def test_principal_chosen_label_preserved(self):
        self.assert_label_saved('My voice bridge')

    def test_device_name_mismatch_nonblocking_no_values_logged(self):
        self.client_changes = {'deviceName': SECRET}
        code, output = self.cli(['redeem'], self.link())
        self.assertEqual(code, 0)
        self.assertIn('returned device name differs', output)
        self.assertTrue((self.root / 'client.json').exists())

    def test_device_name_case_nonblocking(self):
        self.client_changes = {'deviceName': 'VoiceStack'}
        code, output = self.cli(['redeem'], self.link())
        self.assertEqual(code, 0)
        self.assertNotIn('returned device name differs', output)

    def test_device_name_optional(self):
        self.assertTrue(pair.active_client({'id': 'id', 'label': 'Chosen label', 'clientKind': 'desktop'}))

    def test_invalid_client_checks_still_refuse_and_require_revocation(self):
        for changes in ({'label': ''}, {'label': None}, {'id': ''}, {'clientKind': 'mobile'},
                        {'revokedAt': 'now'}, {'expiresAt': 'later'}):
            self.client_changes = changes
            code, output = self.cli(['redeem'], self.link())
            self.assertEqual(code, 1)
            self.assertIn('device was created but not stored', output)
            self.assertIn('Revoke the device', output)
            self.assertFalse((self.root / 'client.json').exists())

    def test_wrong_server_origin_requires_revocation(self):
        for origin in ('http://127.0.0.1:1', 'http://192.0.2.1:1234'):
            self.server_changes = {'url': origin}
            code, output = self.cli(['redeem'], self.link())
            self.assertEqual(code, 1)
            self.assertIn('device was created but not stored', output)
            self.assertIn('Revoke the device', output)
            self.assertFalse((self.root / 'client.json').exists())

    def test_storage_failure_requires_revocation(self):
        original = pair.atomic_private
        def write(path, *args, **kwargs):
            if path.name == 'client.json':
                raise OSError(SECRET)
            return original(path, *args, **kwargs)
        with mock.patch.object(pair, 'atomic_private', side_effect=write):
            code, output = self.cli(['redeem'], self.link())
        self.assertEqual(code, 1)
        self.assertIn('device was created but not stored', output)
        self.assertIn('Revoke the device', output)

    def test_non_loopback(self):
        link = self.link(candidates=[{'type': 'lan', 'url': 'http://192.0.2.1:1234'}])
        self.assertEqual(self.cli(['redeem'], link)[0], 1)
        self.assertEqual(self.gets, 0)

    def test_multiple_origins_no_fallback(self):
        link = self.link(candidates=[{'type': 'loopback', 'url': self.origin},
            {'type': 'loopback', 'url': 'http://127.0.0.1:1'}])
        self.assertEqual(self.cli(['redeem'], link)[0], 1)
        self.assertEqual(self.gets, 0)

    def test_400_and_reused_link_never_retried(self):
        self.mode = '400'
        link = self.link()
        self.assertEqual(self.cli(['redeem'], link)[0], 1)
        self.assertEqual(self.cli(['redeem'], link)[0], 1)
        self.assertEqual((self.gets, len(self.posts)), (1, 1))

    def test_existing_binding_not_replaced(self):
        pair.atomic_private(self.root / 'client.json', {'clientToken': TOKEN})
        self.assertEqual(self.cli(['redeem'], self.link())[0], 1)
        self.assertEqual(self.gets, 0)
        self.assertTrue(pair.read_private(self.root / 'client.json')['clientToken'] == TOKEN)

    def test_concurrent_lock(self):
        pair.private_dir(self.root)
        (self.root / '.enrolling').touch(mode=0o600)
        self.assertEqual(self.cli(['redeem'], self.link())[0], 1)
        self.assertTrue((self.root / '.enrolling').exists())
        self.assertEqual(self.gets, 0)

    def test_symlink_binding_refused(self):
        pair.private_dir(self.root)
        (self.root / 'client.json').symlink_to(self.root / 'missing')
        self.assertEqual(self.cli(['redeem'], self.link())[0], 1)
        self.assertEqual(self.gets, 0)

    def test_symlink_ledger_refused(self):
        pair.private_dir(self.root)
        (self.root / 'attempt.json').symlink_to(self.root / 'missing')
        self.assertEqual(self.cli(['redeem'], self.link())[0], 1)
        self.assertEqual(self.gets, 0)

    def test_unidentified_host(self):
        self.mode = 'bad-health'
        self.assertEqual(self.cli(['redeem'], self.link())[0], 1)
        self.assertEqual(len(self.posts), 0)

    def test_redirect_not_followed(self):
        self.mode = 'redirect'
        self.assertEqual(self.cli(['redeem'], self.link())[0], 1)
        self.assertEqual((self.gets, len(self.posts)), (1, 0))

    def test_missing_status_no_network(self):
        code, output = self.cli(['status'])
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(output), {'bindingExists': False})
        self.assertEqual(self.gets, 0)

    def test_argv_link_rejected(self):
        self.assertEqual(self.cli(['redeem', self.link()])[0], 1)
        self.assertEqual(self.gets, 0)

    def test_hidden_intake(self):
        stream = mock.Mock()
        stream.isatty.return_value = True
        link = self.link()
        with mock.patch.object(pair.getpass, 'getpass', return_value=link):
            self.assertTrue(pair.intake(stream) == link)
        with mock.patch.object(pair.getpass, 'getpass', side_effect=pair.getpass.GetPassWarning):
            with self.assertRaises(pair.PairingError):
                pair.intake(stream)

    def test_strict_parsing(self):
        link = self.link()
        for invalid in (link + '&v=2', link + '#fragment', link.replace('v=2', 'v=1'),
                        link + '\n', 'openchamber://connect?v=2&p=%%%'):
            with self.assertRaises(pair.PairingError):
                pair.parse_link(invalid)


if __name__ == '__main__':
    unittest.main()
