"""Single reviewed test invocation, local socketpair broker, no listening service.

Trusted source/process contract, NOT an OS security sandbox. Never imported by
product code. No process, directory or socket is created merely by importing it.
"""
from pathlib import Path
import base64
import json
import os
import re
import select
import signal
import socket
import struct
import subprocess
import sys
import time
import parity_git_ownership as wire

PYTHON = '/usr/bin/python3'
WALL = 600
LOG_CAP = 2 * 1024 * 1024
CANCELLED = False
READER_PREFIX = ['/usr/bin/git', '--no-optional-locks', '-c', 'core.hooksPath=/dev/null',
    '-c', 'core.fsmonitor=false', '-c', 'credential.helper=', '-c', 'protocol.allow=never',
    '-c', 'maintenance.auto=false', '-c', 'gc.auto=0', '-C']
FIXTURE_PREFIX = ['/usr/bin/git', '-c', 'core.hooksPath=/dev/null', '-c', 'core.fsmonitor=false',
    '-c', 'credential.helper=', '-c', 'protocol.allow=never', '-c', 'gc.auto=0',
    '-c', 'maintenance.auto=false', '-c', 'commit.gpgsign=false',
    '-c', 'user.name=Parity Synthetic Fixture', '-c', 'user.email=parity@example.invalid', '-C']
GIT_ENV = {'PATH': '/usr/bin:/bin', 'LC_ALL': 'C', 'GIT_CONFIG_NOSYSTEM': '1',
    'GIT_CONFIG_GLOBAL': '/dev/null', 'GIT_TERMINAL_PROMPT': '0',
    'GIT_NO_REPLACE_OBJECTS': '1', 'GIT_NO_LAZY_FETCH': '1',
    'GIT_OPTIONAL_LOCKS': '0', 'GIT_ATTR_NOSYSTEM': '1'}


def validate_intent(message, number, temp):
    if set(message) != {'op', 'id', 'argv', 'env', 'cap'} or message['op'] != 'intent' or type(message['id']) is not int or message['id'] != number:
        raise RuntimeError('invalid ownership intent')
    argv = message['argv']
    if type(argv) is not list or not all(type(a) is str for a in argv) or sum(len(a) for a in argv) > 4096 or len(argv) > 40:
        raise RuntimeError('invalid Git argv')
    prefix = next((p for p in (READER_PREFIX, FIXTURE_PREFIX) if argv[:len(p)] == p), None)
    if prefix is None or len(argv) <= len(prefix) + 1 or message['env'] != GIT_ENV:
        raise RuntimeError('Git command/environment outside contract')
    root = Path(argv[len(prefix)]).resolve()
    if temp.resolve() not in root.parents or not root.is_dir():
        raise RuntimeError('Git cwd outside owned synthetic fixtures')
    args = argv[len(prefix) + 1:]
    # Fixed local built-ins only. No executable/config supplied as an operand.
    patterns = ([r'cat-file -t [0-9a-f]{40}', r'cat-file commit [0-9a-f]{40}',
        r'cat-file -s [0-9a-f]{40}', r'cat-file blob [0-9a-f]{40}',
        r'ls-tree -z [0-9a-f]{40} -- [A-Za-z0-9._-]+',
        r'rev-parse --verify --end-of-options [0-9a-f]{40}\^\{commit\}']
        if prefix == READER_PREFIX else
        [r'init -q --template=', r'add --all',
         r'commit -qm Synthetic (?:adapter fixture only|reference|gitlink only)',
         r'rev-parse (?:--verify )?HEAD', r'rev-parse [0-9a-f]{40}\^\{tree\}',
         r'update-index --add --cacheinfo 160000,[0-9a-f]{40},macos/app/Sources/FloatingVoiceCore/VoicePost\.swift'])
    if not any(re.fullmatch(pattern, ' '.join(args)) for pattern in patterns):
        raise RuntimeError('Git operation outside contract')
    cap = message['cap']
    if type(cap) is not int or cap not in ((4096, 262144, 4194304) if prefix == READER_PREFIX else (65536,)):
        raise RuntimeError('Git output cap outside contract')
    return argv, cap


def parent_first_cleanup(parent, children):
    """Only recorded direct Popen children, no ancestry polling/pattern killing.

    Stop the test parent before touching Git. Direct children are wait-reaped;
    none of these Git PIDs is an adopted descendant of the test parent.
    """
    if parent is not None and parent.poll() is None:
        try:
            os.kill(parent.pid, signal.SIGSTOP)
        except ProcessLookupError:
            pass
    errors = []
    try:
        for proc in children:
            try:
                if proc.poll() is None:
                    proc.kill()
                proc.wait(timeout=2)
                if proc.returncode is None:
                    raise RuntimeError('owned Git cleanup unverified')
            except (OSError, subprocess.SubprocessError, RuntimeError) as error:
                errors.append(type(error).__name__)
    finally:
        if parent is not None:
            if parent.poll() is None:
                parent.kill()
            parent.wait(timeout=2)
            if parent.returncode is None:
                errors.append('test-parent cleanup unverified')
    if errors:
        raise RuntimeError('owned direct-child cleanup unverified: ' + ','.join(errors))


class Supervisor:
    def __init__(self, parent, sock, log, temp):
        self.parent, self.sock, self.log, self.temp = parent, sock, log, temp
        self.deadline = time.monotonic() + WALL
        self.logs = 0
        self.messages = 0
        self.registry = []
        self.log_pipes = [parent.stdout, parent.stderr]
        self.active = None
        self.git_pipes = {}
        self.git_data = {}
        self.git_deadline = None
        for stream in self.log_pipes:
            os.set_blocking(stream.fileno(), False)
        self.sock.setblocking(False)

    def pump(self, deadline, want_read=False, want_write=False):
        if CANCELLED:
            raise RuntimeError('supervision cancelled')
        now = time.monotonic()
        limits = [deadline, self.deadline]
        if self.git_deadline is not None:
            limits.append(self.git_deadline)
        remaining = min(limits) - now
        if remaining <= 0:
            raise RuntimeError('supervision deadline')
        reads = list(self.log_pipes) + list(self.git_pipes)
        if want_read:
            reads.append(self.sock)
        ready, writable, _ = select.select(reads, [self.sock] if want_write else [], [], min(remaining, 0.05))
        for stream in ready:
            if stream is self.sock:
                continue
            data = os.read(stream.fileno(), 65536)
            if stream in self.log_pipes:
                if not data:
                    self.log_pipes.remove(stream)
                else:
                    if self.logs + len(data) > LOG_CAP:
                        raise RuntimeError('combined log limit; no truncation accepted')
                    written = self.log.write(data)
                    if type(written) is not int or not 0 <= written <= len(data):
                        raise RuntimeError('invalid log write count; retained bytes unknown')
                    self.logs += written
                    if written != len(data):
                        raise RuntimeError('short log write; no truncation accepted')
            else:
                kind, cap = self.git_pipes[stream]
                if not data:
                    del self.git_pipes[stream]
                else:
                    self.git_data[kind].extend(data)
                    if len(self.git_data[kind]) > cap:
                        raise RuntimeError('Git output limit')
        return self.sock in ready, bool(writable)

    def receive(self, deadline, allow_end=False):
        def exact(size):
            result = bytearray()
            while len(result) < size:
                readable, _ = self.pump(deadline, want_read=True)
                if readable:
                    data = self.sock.recv(size - len(result))
                    if not data:
                        if allow_end and not result and size == 4 and self.active is None:
                            return None
                        raise RuntimeError('ownership disconnect during transaction')
                    result.extend(data)
                if self.parent.poll() is not None and not readable:
                    if allow_end and not result and self.active is None:
                        return None
                    raise RuntimeError('test parent exited during transaction')
            return bytes(result)
        header = exact(4)
        if header is None:
            return None
        size = struct.unpack('!I', header)[0]
        if size > 16384:
            raise RuntimeError('ownership request limit')
        self.messages += 1
        if self.messages > wire.SPAWN_CAP * 3:
            raise RuntimeError('ownership message limit')
        return wire.decode(exact(size))

    def send(self, message, deadline):
        data = wire.frame(message)
        position = 0
        while position < len(data):
            _, writable = self.pump(deadline, want_write=True)
            if self.parent.poll() is not None:
                raise RuntimeError('test parent exited before report delivery')
            if writable:
                sent = self.sock.send(data[position:position + 65536])
                if sent <= 0:
                    raise RuntimeError('ownership send disconnected')
                position += sent

    def transaction(self, intent, number):
        argv, cap = validate_intent(intent, number, self.temp)
        self.send({'op': 'ready', 'id': number}, time.monotonic() + 2)
        if self.receive(time.monotonic() + 2) != {'op': 'start', 'id': number}:
            raise RuntimeError('missing/invalid START; no Git spawned')
        if self.parent.poll() is not None:
            raise RuntimeError('test parent exited before spawn')
        # Ownership slot precedes spawn; only supervisor performs Popen. Test
        # parent death at ANY later instruction cannot orphan this direct child.
        slot = {'id': number, 'pid': None, 'argv': argv, 'returncode': None}
        self.registry.append(slot)
        self.active = subprocess.Popen(argv, env=GIT_ENV, stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
        slot['pid'] = self.active.pid
        self.git_deadline = time.monotonic() + 10
        self.git_data = {'out': bytearray(), 'err': bytearray()}
        self.git_pipes = {self.active.stdout: ('out', cap), self.active.stderr: ('err', 65536)}
        for stream in self.git_pipes:
            os.set_blocking(stream.fileno(), False)
        self.send({'op': 'child', 'id': number, 'pid': self.active.pid}, time.monotonic() + 2)
        if self.receive(time.monotonic() + 2) != {'op': 'ack', 'id': number, 'pid': self.active.pid}:
            raise RuntimeError('missing/invalid child ACK')
        # Early Git exit remains owned and reaped normally, including nonzero.
        while self.git_pipes or self.active.poll() is None:
            readable, _ = self.pump(self.git_deadline, want_read=True)
            if readable:
                if not self.sock.recv(1, socket.MSG_PEEK):
                    raise RuntimeError('ownership disconnect while Git active')
                raise RuntimeError('unexpected request while Git active')
            if self.parent.poll() is not None:
                raise RuntimeError('test parent exited while Git active')
        slot['returncode'] = self.active.wait(timeout=2)
        self.active.stdout.close(); self.active.stderr.close()
        self.active = None
        self.git_deadline = None
        self.send({'op': 'result', 'id': number, 'pid': slot['pid'],
            'returncode': slot['returncode'],
            'stdout': base64.b64encode(self.git_data['out']).decode('ascii')}, time.monotonic() + 2)
        self.git_data = {}

    def run(self):
        number = 0
        while True:
            intent = self.receive(self.deadline, allow_end=True)
            if intent is None:
                break
            number += 1
            if number > wire.SPAWN_CAP:
                raise RuntimeError('Git spawn limit')
            self.transaction(intent, number)
        while self.parent.poll() is None or self.log_pipes:
            self.pump(self.deadline)
        return self.parent.wait(timeout=2)


def main():
    if sys.argv[1:] != ['--execute-reviewed-tests']:
        raise RuntimeError('explicit execution GO and exact flag required')
    # Defer cancellation to a pump boundary so a signal cannot interrupt the
    # Popen-return/ownership-assignment window. No signal handler spawns/kills.
    def cancel(signum, frame):
        global CANCELLED
        CANCELLED = True
    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, cancel)
    started = time.monotonic()
    native = Path(__file__).resolve().parent
    execution = native.parents[2] / 'execution-once'
    execution.mkdir(mode=0o700, exist_ok=False)
    home, temp = execution / 'home', execution / 'tmp'
    home.mkdir(mode=0o700); temp.mkdir(mode=0o700)
    parent = None; server = None; left = None; right = None
    status = 'FAILED'
    command = [PYTHON, '-B', '-E', '-S', '-m', 'unittest', '-v', 'test_mac_parity_reference']
    fd = os.open(str(execution / 'combined.log'), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'wb', buffering=0) as log:
        try:
            left, right = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)
            env = {'PATH': '/usr/bin:/bin', 'LC_ALL': 'C', 'HOME': str(home),
                'TMPDIR': str(temp), 'FV_MAC_PARITY_SUPERVISOR_FD': str(right.fileno())}
            parent = subprocess.Popen(command, cwd=native, env=env, stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, pass_fds=(right.fileno(),),
                start_new_session=True)
            right.close(); right = None
            server = Supervisor(parent, left, log, temp)
            # Reserve the final ten seconds of the 600s contract for cleanup.
            server.deadline = min(server.deadline, started + WALL - 10)
            code = server.run()
            status = 'PASS' if code == 0 else 'TEST FAILURE'
        finally:
            for sig in (signal.SIGINT, signal.SIGTERM):
                signal.signal(sig, signal.SIG_IGN)
            # Parent first, then every still-active Git direct child. Reaped
            # historical registry PIDs are NOT signaled (avoids PID reuse).
            parent_first_cleanup(parent, [server.active] if server and server.active else [])
            if server and server.active:
                server.registry[-1]['returncode'] = server.active.returncode
                server.active.stdout.close(); server.active.stderr.close()
            if parent:
                parent.stdout.close(); parent.stderr.close()
            if left: left.close()
            if right: right.close()
            receipt = {'status': status, 'test_pid': parent.pid if parent else None,
                'test_argv': command, 'test_returncode': parent.returncode if parent else None,
                'log_bytes': server.logs if server else 0,
                'git': server.registry if server else [],
                'ownership': 'all spawned Git are supervisor direct children; no adopted-child reaping claim'}
            data = json.dumps(receipt, indent=2).encode()
            if len(data) > LOG_CAP:
                raise RuntimeError('receipt limit')
            fd = os.open(str(execution / 'receipt.json'), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, 'wb') as output:
                output.write(data)
    if status != 'PASS':
        raise RuntimeError('reviewed test invocation failed')


if __name__ == '__main__':
    main()
