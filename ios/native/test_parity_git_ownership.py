"""Protocol/cleanup test SOURCE only; fake peers/Popen, no actual child launches."""
from pathlib import Path
import base64
import socket
import time
import unittest
from unittest.mock import Mock, patch
import parity_git_ownership as wire
import parity_test_supervisor as supervisor


class ScriptedSocket:
    def __init__(self, messages=(), error=None):
        self.incoming = bytearray(b''.join(wire.frame(m) for m in messages))
        self.sent = []
        self.error = error
        self.closed = False

    def recv(self, count):
        if self.error:
            raise self.error
        data = bytes(self.incoming[:count]); del self.incoming[:count]
        return data

    def sendall(self, data):
        self.sent.append(data)

    def settimeout(self, value):
        if value <= 0:
            raise AssertionError('timeout must be finite positive')

    def close(self):
        self.closed = True


class OwnershipProtocolTests(unittest.TestCase):
    def test_log_short_or_invalid_write_fails_closed(self):
        # Pure mocks: no real descriptors, files, sockets or child launches.
        for written in [0, 1, 3, None, True, -1, 5, '4', 4.0]:
            with self.subTest(written=written):
                server = object.__new__(supervisor.Supervisor)
                stream = Mock()
                server.sock = Mock(); server.log = Mock()
                server.log.write.return_value = written
                server.logs = 7; server.deadline = 100; server.git_deadline = None
                server.log_pipes = [stream]; server.git_pipes = {}
                with patch.object(supervisor, 'CANCELLED', False), patch.object(supervisor.time, 'monotonic', return_value=1), patch.object(supervisor.select, 'select', return_value=([stream], [], [])), patch.object(supervisor.os, 'read', return_value=b'data'), patch.object(supervisor.subprocess, 'Popen') as spawn:
                    with self.assertRaisesRegex(RuntimeError, 'log write'):
                        server.pump(100)
                expected = 7 + written if type(written) is int and 0 <= written <= 4 else 7
                self.assertEqual(server.logs, expected)
                server.log.write.assert_called_once_with(b'data')
                spawn.assert_not_called()

    def test_log_full_write_counts_retained_bytes(self):
        server = object.__new__(supervisor.Supervisor)
        stream = Mock()
        server.sock = Mock(); server.log = Mock(); server.log.write.return_value = 4
        server.logs = 7; server.deadline = 100; server.git_deadline = None
        server.log_pipes = [stream]; server.git_pipes = {}
        with patch.object(supervisor, 'CANCELLED', False), patch.object(supervisor.time, 'monotonic', return_value=1), patch.object(supervisor.select, 'select', return_value=([stream], [], [])), patch.object(supervisor.os, 'read', return_value=b'data'), patch.object(supervisor.subprocess, 'Popen') as spawn:
            self.assertEqual(server.pump(100), (False, False))
        self.assertEqual(server.logs, 11)
        server.log.write.assert_called_once_with(b'data')
        spawn.assert_not_called()

    def test_no_channel_normal_mode(self):
        with patch.object(wire, '_channel', None):
            self.assertIsNone(wire.run_if_configured(['unchanged caller argv'], {}, 4096))

    def test_missing_or_invalid_ready_no_fallback(self):
        for messages in [[], [{'op': 'wrong', 'id': 1}]]:
            peer = ScriptedSocket(messages)
            channel = wire.Channel(peer)
            with self.assertRaises(RuntimeError):
                channel.exchange([], {}, 4096)
            self.assertTrue(channel.broken); self.assertTrue(peer.closed)
            with self.assertRaises(RuntimeError): channel.exchange([], {}, 4096)

    def test_disconnect_before_child_report(self):
        peer = ScriptedSocket([{'op': 'ready', 'id': 1}])
        with self.assertRaises(RuntimeError): wire.Channel(peer).exchange([], {}, 4096)
        self.assertTrue(peer.closed)

    def test_channel_timeout(self):
        peer = ScriptedSocket(error=socket.timeout('synthetic timeout'))
        with self.assertRaises(RuntimeError): wire.Channel(peer).exchange([], {}, 4096)
        self.assertTrue(peer.closed)

    def test_early_git_exit_is_reported_not_hidden(self):
        peer = ScriptedSocket([{'op': 'ready', 'id': 1}, {'op': 'child', 'id': 1, 'pid': 123},
            {'op': 'result', 'id': 1, 'pid': 123, 'returncode': 7,
             'stdout': base64.b64encode(b'early result').decode()}])
        self.assertEqual(wire.Channel(peer).exchange([], {}, 4096), (7, b'early result'))
        self.assertEqual(wire.decode(peer.sent[2][4:]), {'op': 'ack', 'id': 1, 'pid': 123})

    def test_invalid_child_and_result(self):
        cases = [
            [{'op': 'child', 'id': 1, 'pid': -1}],
            [{'op': 'child', 'id': 1, 'pid': 123}, {'op': 'result', 'id': 2, 'pid': 123, 'returncode': 0, 'stdout': ''}],
            [{'op': 'child', 'id': 1, 'pid': 123}, {'op': 'result', 'id': 1, 'pid': 123, 'returncode': 0, 'stdout': '!'}],
        ]
        for messages in cases:
            with self.assertRaises(RuntimeError):
                wire.Channel(ScriptedSocket([{'op': 'ready', 'id': 1}] + messages)).exchange([], {}, 4096)

    def test_client_spawn_cap_and_deadline(self):
        peer = ScriptedSocket()
        channel = wire.Channel(peer); channel.sequence = wire.SPAWN_CAP
        with self.assertRaises(RuntimeError): channel.exchange([], {}, 4096)
        with self.assertRaises(RuntimeError): wire.Channel(peer).receive(time.monotonic() - 1)

    def test_frame_bounds_and_duplicate_fields(self):
        with self.assertRaises(RuntimeError): wire.frame({'too_big': 'x' * wire.FRAME_CAP})
        with self.assertRaises(RuntimeError): wire.decode(b'{"id":1,"id":1}')

    def test_parent_stopped_before_git_kill_then_direct_reap(self):
        events = []
        parent, child = Mock(), Mock()
        parent.pid = 123; parent.returncode = -9; child.returncode = -9
        parent.poll.return_value = None; child.poll.return_value = None
        child.kill.side_effect = lambda: events.append('git kill')
        child.wait.side_effect = lambda timeout: events.append('git direct wait')
        parent.kill.side_effect = lambda: events.append('parent kill')
        parent.wait.side_effect = lambda timeout: events.append('parent direct wait')
        with patch.object(supervisor.os, 'kill', side_effect=lambda pid, sig: events.append('parent stop')):
            supervisor.parent_first_cleanup(parent, [child])
        self.assertEqual(events, ['parent stop', 'git kill', 'git direct wait', 'parent kill', 'parent direct wait'])

    def test_cleanup_still_kills_parent_if_git_wait_fails(self):
        parent, child = Mock(), Mock()
        parent.poll.return_value = None; child.poll.return_value = None
        parent.returncode = -9
        child.wait.side_effect = supervisor.subprocess.TimeoutExpired('synthetic', 2)
        with patch.object(supervisor.os, 'kill'), self.assertRaises(RuntimeError):
            supervisor.parent_first_cleanup(parent, [child])
        parent.kill.assert_called_once(); parent.wait.assert_called_once_with(timeout=2)

    def test_invalid_or_missing_ack_keeps_direct_child_owned(self):
        # Exercise real transaction control with fake transport/Popen only.
        for response in [None, {'op': 'ack', 'id': 1, 'pid': 999}]:
            server = object.__new__(supervisor.Supervisor)
            server.temp = Path('/unused'); server.registry = []; server.active = None
            server.parent = Mock(); server.parent.poll.return_value = None
            server.send = Mock()
            server.receive = Mock(side_effect=[{'op': 'start', 'id': 1}, response])
            child = Mock(); child.pid = 123; child.returncode = -9
            with patch.object(supervisor, 'validate_intent', return_value=(['/usr/bin/git'], 4096)), patch.object(supervisor.subprocess, 'Popen', return_value=child), patch.object(supervisor.os, 'set_blocking'):
                with self.assertRaises(RuntimeError): server.transaction({}, 1)
            self.assertIs(server.active, child)
            self.assertEqual(server.registry[0]['pid'], 123)

    def test_parent_early_exit_prevents_spawn(self):
        server = object.__new__(supervisor.Supervisor)
        server.temp = Path('/unused'); server.registry = []; server.active = None
        server.parent = Mock(); server.parent.poll.return_value = 1
        server.send = Mock(); server.receive = Mock(return_value={'op': 'start', 'id': 1})
        with patch.object(supervisor, 'validate_intent', return_value=(['/usr/bin/git'], 4096)), patch.object(supervisor.subprocess, 'Popen') as spawn:
            with self.assertRaises(RuntimeError): server.transaction({}, 1)
        spawn.assert_not_called()
