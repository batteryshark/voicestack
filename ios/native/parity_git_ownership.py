"""Optional test-only local ownership capability; never selects content/policy.

Production does not activate a channel. In supervised tests the broker creates
Git as its OWN direct child, eliminating test-parent Popen/report races.
"""
import base64
import json
import os
import socket
import struct
import time

FRAME_CAP = 6 * 1024 * 1024
SPAWN_CAP = 2048
_channel = None


def frame(message):
    data = json.dumps(message, separators=(',', ':')).encode('ascii')
    if len(data) > FRAME_CAP:
        raise RuntimeError('ownership frame limit')
    return struct.pack('!I', len(data)) + data


def decode(data):
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise RuntimeError('ownership duplicate key')
            result[key] = value
        return result
    try:
        value = json.loads(data, object_pairs_hook=pairs)
    except (ValueError, UnicodeError, RecursionError):
        raise RuntimeError('ownership invalid JSON') from None
    if type(value) is not dict:
        raise RuntimeError('ownership invalid message')
    return value


class Channel:
    def __init__(self, sock):
        self.sock = sock
        self.sequence = 0
        self.broken = False

    def receive(self, deadline):
        def exact(size):
            data = bytearray()
            while len(data) < size:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise RuntimeError('ownership deadline')
                self.sock.settimeout(remaining)
                chunk = self.sock.recv(size - len(data))
                if not chunk:
                    raise RuntimeError('ownership disconnected')
                data.extend(chunk)
            return bytes(data)
        size = struct.unpack('!I', exact(4))[0]
        if size > FRAME_CAP:
            raise RuntimeError('ownership frame limit')
        return decode(exact(size))

    def exchange(self, argv, env, cap):
        if self.broken or self.sequence >= SPAWN_CAP:
            raise RuntimeError('ownership capability exhausted/broken')
        self.sequence += 1
        number = self.sequence
        # Entire client exchange finite, not a fresh timeout for each chunk.
        deadline = time.monotonic() + 20
        def receive():
            return self.receive(deadline)
        def send(message):
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise RuntimeError('ownership deadline')
            self.sock.settimeout(remaining)
            self.sock.sendall(frame(message))
        try:
            send({'op': 'intent', 'id': number, 'argv': argv, 'env': env, 'cap': cap})
            if receive() != {'op': 'ready', 'id': number}:
                raise RuntimeError('ownership missing/invalid READY')
            send({'op': 'start', 'id': number})
            child = receive()
            if set(child) != {'op', 'id', 'pid'} or child['op'] != 'child' or child['id'] != number or type(child['pid']) is not int or child['pid'] <= 0:
                raise RuntimeError('ownership missing/invalid child report')
            send({'op': 'ack', 'id': number, 'pid': child['pid']})
            result = receive()
            if set(result) != {'op', 'id', 'pid', 'returncode', 'stdout'} or result['op'] != 'result' or result['id'] != number or result['pid'] != child['pid'] or type(result['returncode']) is not int:
                raise RuntimeError('ownership missing/invalid result')
            output = base64.b64decode(result['stdout'], validate=True)
            if len(output) > cap:
                raise RuntimeError('ownership output limit')
            return result['returncode'], output
        except (OSError, ValueError, TypeError, RuntimeError):
            self.broken = True
            self.sock.close()
            raise RuntimeError('ownership handshake failed; no direct-spawn fallback') from None


def activate_test_channel():
    """Called explicitly by reference tests, not reader import or production.

    FD names a private socketpair inherited from the exact supervisor. It grants
    spawn ownership only. Any bad capability fails closed; no spawn fallback.
    """
    global _channel
    value = os.environ.get('FV_MAC_PARITY_SUPERVISOR_FD')
    if value is None:
        return
    if _channel is not None or not value.isdecimal() or int(value) < 3:
        raise RuntimeError('invalid ownership descriptor')
    sock = socket.socket(fileno=int(value))
    if sock.family != socket.AF_UNIX or sock.type != socket.SOCK_STREAM:
        sock.close()
        raise RuntimeError('invalid ownership channel type')
    sock.set_inheritable(False)
    _channel = Channel(sock)


def run_if_configured(argv, env, cap):
    if _channel is None:
        return None
    return _channel.exchange(argv, env, cap)
