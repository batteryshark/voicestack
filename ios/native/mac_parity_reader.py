"""Committed package reader. Manifest consistency is not provenance authentication."""
from pathlib import Path
import hashlib
import json
import os
import re
import selectors
import signal
import subprocess
import sys
import time
from types import MappingProxyType
import parity_git_ownership as ownership

ORIGINAL_COMMIT = '4c33124f8bf318313e460210ecf55018f648e692'
ORIGINAL_PREFIX = 'app/Sources/FloatingVoiceCore/'
PACKAGE_PREFIX = 'macos/' + ORIGINAL_PREFIX
MANIFEST = 'ios/shared/mac-parity-manifest.json'
NAMES = ('VoicePost.swift', 'NoiseFloor.swift', 'Composer.swift', 'Settings.swift',
         'TurnTaking.swift', 'Controller.swift', 'Speaker.swift', 'Pill.swift')
MANIFEST_CAP = 256 * 1024
SOURCE_CAP = 4 * 1024 * 1024
HEX40 = re.compile(r'[0-9a-f]{40}\Z')
HEX64 = re.compile(r'[0-9a-f]{64}\Z')


def fail(message):
    raise RuntimeError('Mac parity: ' + message)


def _git(root, args, cap=4096):
    """Internal fixed-argv reads only; scrub inherited Git/config/trace credentials.

    Both pipes are drained with hard byte caps and a ten-second deadline. Kill
    and reap the process group on every abnormal exit, including pipe overflow.
    No shell, lazy fetch, replacement objects, hooks, filters or index operations.
    """
    env = {'PATH': '/usr/bin:/bin', 'LC_ALL': 'C', 'GIT_CONFIG_NOSYSTEM': '1',
           'GIT_CONFIG_GLOBAL': '/dev/null', 'GIT_OPTIONAL_LOCKS': '0',
           'GIT_NO_REPLACE_OBJECTS': '1', 'GIT_NO_LAZY_FETCH': '1',
           'GIT_TERMINAL_PROMPT': '0', 'GIT_ATTR_NOSYSTEM': '1'}
    argv = ['/usr/bin/git', '--no-optional-locks', '-c', 'core.hooksPath=/dev/null',
            '-c', 'core.fsmonitor=false', '-c', 'credential.helper=',
            '-c', 'protocol.allow=never', '-c', 'maintenance.auto=false',
            '-c', 'gc.auto=0', '-C', str(root), *args]
    supervised = ownership.run_if_configured(argv, env, cap)
    if supervised is not None:
        if supervised[0]:
            fail('required local Git object/read unavailable; no fallback')
        return supervised[1]
    proc = None
    output = bytearray()
    try:
        proc = subprocess.Popen(argv, env=env, stdin=subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                start_new_session=True)
        deadline = time.monotonic() + 10
        with selectors.DefaultSelector() as selector:
            selector.register(proc.stdout, selectors.EVENT_READ, 'out')
            selector.register(proc.stderr, selectors.EVENT_READ, 'err')
            counts = {'out': 0, 'err': 0}
            while selector.get_map():
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    fail('local Git read timed out')
                for key, _ in selector.select(remaining):
                    data = os.read(key.fileobj.fileno(), 65536)
                    if not data:
                        selector.unregister(key.fileobj)
                        continue
                    kind = key.data
                    counts[kind] += len(data)
                    if counts[kind] > (cap if kind == 'out' else 65536):
                        fail('local Git output exceeds limit')
                    if kind == 'out':
                        output.extend(data)
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                fail('local Git read timed out')
            if proc.wait(timeout=remaining):
                fail('required local Git object/read unavailable; no fallback')
        return bytes(output)
    except (OSError, subprocess.SubprocessError):
        fail('local Git read failed; no fallback')
    finally:
        if proc is not None:
            # Also terminate any unexpected descendants after a successful read.
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            proc.wait()
            proc.stdout.close()
            proc.stderr.close()


def reference(environ=None, pin_file=None):
    environ = os.environ if environ is None else environ
    if 'FV_MAC_PARITY_REF' in environ:
        value = environ['FV_MAC_PARITY_REF']
        if not value.strip():
            raise RuntimeError('FV_MAC_PARITY_REF must not be empty; unset it to use the recorded pin')
        return value
    if pin_file is None:
        pin_file = Path(__file__).resolve().parent.parent / 'shared/mac-parity-ref.txt'
    try:
        value = pin_file.read_text()
    except OSError as error:
        raise RuntimeError(f'Missing Mac parity pin file: {pin_file}') from error
    if not re.fullmatch(r'[a-f0-9]{40}\n?', value):
        raise RuntimeError(f'Mac parity pin must contain one full commit hash: {pin_file}')
    return value.strip()


class _Tree:
    def __init__(self, root, commit, exact=True):
        self.root = Path(root).resolve()
        if exact:
            if not isinstance(commit, str) or not HEX40.fullmatch(commit):
                fail('package commit must be explicit full lowercase 40-hex SHA')
            resolved = commit
        else:
            # Preserve explicit external ref semantics, but resolve once only.
            resolved = _git(self.root, ['rev-parse', '--verify', '--end-of-options',
                                        commit + '^{commit}']).decode('ascii').strip()
        if not HEX40.fullmatch(resolved):
            fail('commit resolution invalid')
        if _git(self.root, ['cat-file', '-t', resolved]) != b'commit\n':
            fail('selected object is not a commit')
        self.commit = resolved
        data = _git(self.root, ['cat-file', 'commit', resolved], MANIFEST_CAP)
        first = data.split(b'\n', 1)[0]
        if not re.fullmatch(rb'tree [0-9a-f]{40}', first):
            fail('invalid commit tree')
        self.tree = first[5:].decode('ascii')

    def blob(self, path, cap):
        tree = self.tree
        parts = path.split('/')
        for index, part in enumerate(parts):
            entry = _git(self.root, ['ls-tree', '-z', tree, '--', part])
            match = re.fullmatch(rb'([0-7]{6}) (blob|tree) ([0-9a-f]{40})\t' +
                                 re.escape(part.encode()) + b'\x00', entry)
            if match is None:
                fail('required committed path missing or invalid: ' + path)
            mode, kind, oid = match.groups()
            if index < len(parts) - 1:
                if (mode, kind) != (b'040000', b'tree'):
                    fail('non-tree ancestor: ' + path)
                tree = oid.decode('ascii')
            else:
                if (mode, kind) != (b'100644', b'blob'):
                    fail('nonregular committed blob: ' + path)
                oid = oid.decode('ascii')
                size = _git(self.root, ['cat-file', '-s', oid])
                if not re.fullmatch(rb'[0-9]+\n', size) or int(size) > cap:
                    fail('committed blob exceeds limit: ' + path)
                data = _git(self.root, ['cat-file', 'blob', oid], cap)
                if len(data) != int(size):
                    fail('committed blob size mismatch: ' + path)
                return data


def _keys(value, keys):
    if type(value) is not dict or set(value) != set(keys.split()):
        fail('manifest object fields invalid')


def _hash(value):
    if type(value) is not str or not HEX64.fullmatch(value):
        fail('manifest SHA256 invalid')


def _pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            fail('duplicate JSON key')
        result[key] = value
    return result


def _manifest(raw, origin):
    try:
        doc = json.loads(raw.decode('utf-8'), object_pairs_hook=_pairs,
                         parse_constant=lambda _: fail('nonfinite JSON value'))
    except (ValueError, UnicodeError, RecursionError):
        fail('manifest JSON invalid')
    _keys(doc, 'schema original_commit original_core_prefix packaged_core_prefix files')
    if type(doc['schema']) is not int or doc['schema'] != 1:
        fail('unsupported manifest schema')
    if doc['original_commit'] != origin:
        fail('manifest original commit violates origin policy')
    if (doc['original_core_prefix'], doc['packaged_core_prefix']) != (ORIGINAL_PREFIX, PACKAGE_PREFIX):
        fail('manifest prefixes invalid')
    if type(doc['files']) is not list or len(doc['files']) != len(NAMES):
        fail('manifest must declare exactly eight consumers')
    result = {}
    for item in doc['files']:
        _keys(item, 'name original_path original_blob_sha256 packaged_path packaged_blob_sha256 sanitization')
        name = item['name']
        if type(name) is not str or name not in NAMES or name in result:
            fail('unknown or duplicate consumer')
        if item['original_path'] != ORIGINAL_PREFIX + name or item['packaged_path'] != PACKAGE_PREFIX + name:
            fail('manifest derived path invalid')
        _hash(item['original_blob_sha256']); _hash(item['packaged_blob_sha256'])
        mapping = item['sanitization']
        if item['original_blob_sha256'] == item['packaged_blob_sha256']:
            if mapping is not None:
                fail('unchanged blob requires null sanitization')
        else:
            _keys(mapping, 'mapping_id changes')
            if type(mapping['mapping_id']) is not str or not re.fullmatch(r'[A-Za-z0-9._-]{1,128}', mapping['mapping_id']):
                fail('invalid mapping id')
            if type(mapping['changes']) is not list or not mapping['changes']:
                fail('changed blob requires nonempty mapping')
            for change in mapping['changes']:
                _keys(change, 'original_region_sha256 packaged_region_sha256 description')
                _hash(change['original_region_sha256']); _hash(change['packaged_region_sha256'])
                description = change['description']
                if type(description) is not str or not description.strip() or len(description) > 1024 or any(ord(c) < 0x20 or 0x7F <= ord(c) <= 0x9F for c in description):
                    fail('invalid publishable mapping description')
        result[name] = item
    return result


class CommittedPackageReader:
    """Explicit policy constructor for synthetic unit data; not an environment knob.

    Production callers must use production_reader(), whose policy is fixed Mac4c.
    """
    def __init__(self, root, commit, *, origin_policy):
        if type(origin_policy) is not str or not HEX40.fullmatch(origin_policy):
            fail('invalid constructor origin policy')
        tree = _Tree(root, commit)
        manifest = _manifest(tree.blob(MANIFEST, MANIFEST_CAP), origin_policy)
        verified = {}
        for name in NAMES:
            data = tree.blob(PACKAGE_PREFIX + name, SOURCE_CAP)
            if hashlib.sha256(data).hexdigest() != manifest[name]['packaged_blob_sha256']:
                fail('committed packaged SHA256 mismatch: ' + name)
            verified[name] = data
        self.commit = tree.commit
        self._verified = MappingProxyType(verified)

    def mac_bytes(self, name):
        if type(name) is not str or name not in NAMES:
            fail('undeclared consumer request')
        return self._verified[name]


class ExternalReader:
    def __init__(self, root, ref):
        self.root = Path(root).resolve()
        self.tree = None if ref == 'WORKTREE' else _Tree(self.root, ref, exact=False)

    def mac_bytes(self, name):
        if type(name) is not str or name not in NAMES:
            fail('undeclared consumer request')
        if self.tree is not None:
            return self.tree.blob(ORIGINAL_PREFIX + name, SOURCE_CAP)
        path = self.root / ORIGINAL_PREFIX / name
        # Explicit diagnostic only; never reported as committed proof.
        try:
            with path.open('rb') as stream:
                data = stream.read(SOURCE_CAP + 1)
        except OSError:
            fail('external WORKTREE source unavailable')
        if len(data) > SOURCE_CAP:
            fail('external WORKTREE source exceeds limit')
        return data


def production_reader(environ=None, script_file=__file__):
    env = os.environ if environ is None else environ
    mode = env.get('FV_MAC_PARITY_MODE', 'package')
    if mode not in ('package', 'external'):
        fail('mode must be package or external')
    if mode == 'package':
        if any(key in env for key in ('FV_MAC_PARITY_REF', 'FV_MAC_PARITY_EXTERNAL_REPOSITORY')):
            fail('package mode rejects external configuration')
        commit = env.get('FV_MAC_PARITY_PACKAGE_COMMIT')
        root = Path(script_file).resolve().parents[2]
        # Do not accidentally use an enclosing repository when a package is absent.
        if not (root / '.git').exists():
            fail('packaged repository marker missing')
        reader = CommittedPackageReader(root, commit, origin_policy=ORIGINAL_COMMIT)
        print('Mac parity: packaged committed inputs verified (phone working seams unchanged)', file=sys.stderr)
        return reader
    if 'FV_MAC_PARITY_PACKAGE_COMMIT' in env:
        fail('external mode rejects package commit')
    path = env.get('FV_MAC_PARITY_EXTERNAL_REPOSITORY')
    if not path or not Path(path).is_absolute() or not Path(path).is_dir():
        fail('external mode requires explicit absolute repository directory')
    ref = reference(env, Path(script_file).resolve().parent.parent / 'shared/mac-parity-ref.txt')
    print('Mac parity: EXTERNAL diagnostic; NOT packaged committed proof', file=sys.stderr)
    return ExternalReader(path, ref)
