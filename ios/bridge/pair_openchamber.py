"""Standalone own-client enrollment; never used by the running bridge yet."""
import base64
import getpass
import hashlib
import http.client
import json
import os
import platform
import re
import stat
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
import warnings
from datetime import datetime
from pathlib import Path

MAX_BYTES = 65536
ROOT = Path(os.environ.get('FV_OC_CLIENT_DIR', Path(__file__).resolve().parent.parent / 'private/openchamber'))


class PairingError(Exception):
    pass


class DeviceNotStored(PairingError):
    """The host issued a token, but no usable binding was saved."""


def fail(detail='invalid Connection link'):
    raise PairingError(detail)


def private_dir(root):
    # Reject symlink ancestors as well as a symlink state directory.
    for parent in reversed((root, *root.parents)):
        if parent.is_symlink():
            fail('client directory must not use symlinks')
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    st = root.lstat()
    if (not stat.S_ISDIR(st.st_mode) or st.st_uid != os.getuid()
            or stat.S_IMODE(st.st_mode) != 0o700):
        fail('client directory must be owned by this user and mode 0700')


def read_private(path):
    private_dir(path.parent)
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        st = os.fstat(fd)
        if (not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid()
                or stat.S_IMODE(st.st_mode) != 0o600 or st.st_nlink != 1
                or st.st_size > MAX_BYTES):
            fail('client state must be an owner-only regular file (0600)')
        raw = os.read(fd, MAX_BYTES + 1)
    finally:
        os.close(fd)
    try:
        value = json.loads(raw, object_pairs_hook=unique_object)
    except (ValueError, UnicodeError):
        fail('invalid client state')
    if not isinstance(value, dict):
        fail('invalid client state')
    return value


def atomic_private(path, value, exclusive=False):
    private_dir(path.parent)
    if os.path.lexists(path):
        if exclusive:
            fail('client state already exists; explicit operator recovery required')
        read_private(path)
    fd, temporary = tempfile.mkstemp(prefix='.client-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            os.fchmod(stream.fileno(), 0o600)
            json.dump(value, stream)
            stream.write('\n')
            stream.flush()
            os.fsync(stream.fileno())
        if exclusive:
            # Atomic publish without replacing even a concurrently created file.
            os.link(temporary, path, follow_symlinks=False)
            os.unlink(temporary)
        else:
            os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY | os.O_NOFOLLOW)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def identity(root):
    path = root / 'identity.json'
    if not os.path.lexists(path):
        atomic_private(path, {'dedupeKey': 'voicestack:' + uuid.uuid4().hex}, exclusive=True)
    value = read_private(path).get('dedupeKey')
    if not isinstance(value, str) or not re.fullmatch(r'voicestack:[0-9a-f]{32}', value):
        fail('invalid client identity')
    return value


def loopback_origin(url):
    try:
        p = urllib.parse.urlsplit(url)
        if (p.scheme != 'http' or p.hostname not in ('127.0.0.1', '::1')
                or p.username is not None or p.password is not None or p.query or p.fragment
                or p.path not in ('', '/') or not p.port or not 0 < p.port < 65536):
            fail()
        host = '[::1]' if p.hostname == '::1' else '127.0.0.1'
        result = f'http://{host}:{p.port}'
        if url not in (result, result + '/'):
            fail()
        return result
    except (ValueError, TypeError):
        fail()


def timestamp(value):
    if not isinstance(value, str):
        fail()
    try:
        dt = datetime.fromisoformat(value.replace('Z', '+00:00'))
        if dt.tzinfo is None:
            fail()
        return dt.timestamp()
    except (ValueError, OverflowError):
        fail()


def unique_object(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            fail()
        value[key] = item
    return value


def parse_link(link, now=None):
    now = time.time() if now is None else now
    if (not isinstance(link, str) or not link or len(link) > MAX_BYTES
            or any(ord(c) < 33 or ord(c) == 127 for c in link)):
        fail()
    try:
        p = urllib.parse.urlsplit(link)
        q = urllib.parse.parse_qs(p.query, strict_parsing=True)
        if (p.scheme != 'openchamber' or p.netloc != 'connect' or p.path or p.fragment
                or set(q) != {'v', 'p'} or q['v'] != ['2'] or len(q['p']) != 1):
            fail()
        encoded = q['p'][0]
        if not re.fullmatch(r'[A-Za-z0-9_-]+', encoded):
            fail()
        data = json.loads(base64.b64decode(encoded + '=' * (-len(encoded) % 4),
                          altchars=b'-_', validate=True), object_pairs_hook=unique_object)
        if not isinstance(data, dict):
            fail()
        for field in ('pairingId', 'secret', 'fingerprint'):
            value = data.get(field)
            if (not isinstance(value, str) or not 1 <= len(value) <= 1024
                    or any(ord(c) < 33 for c in value)):
                fail()
        if not now < timestamp(data.get('expiresAt')) <= now + 600:
            fail('Connection link expired or outside ten-minute validity window')
        candidates = data.get('candidates')
        if not isinstance(candidates, list) or not 1 <= len(candidates) <= 8:
            fail()
        origins = set()
        for candidate in candidates:
            if (not isinstance(candidate, dict)
                    or candidate.get('type') not in ('local', 'lan', 'loopback', 'direct')):
                fail()
            origins.add(loopback_origin(candidate.get('url')))
        if len(origins) != 1:
            fail('Connection link must select exactly one loopback host')
        return data, origins.pop()
    except (ValueError, KeyError, TypeError, UnicodeError):
        fail()


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *_args, **_kwargs):
        return None


def json_request(origin, method, path, body=None):
    origin = loopback_origin(origin)
    if path not in ('/health', '/api/client-auth/pairing/redeem'):
        fail('invalid host route')
    request = urllib.request.Request(origin + path, method=method,
        headers={'Accept': 'application/json', 'Content-Type': 'application/json'},
        data=None if body is None else json.dumps(body).encode())
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    try:
        with opener.open(request, timeout=10) as response:
            raw = response.read(MAX_BYTES + 1)
            if len(raw) > MAX_BYTES:
                fail('OpenChamber response too large')
            return response.status, json.loads(raw, object_pairs_hook=unique_object) if raw else None
    except urllib.error.HTTPError as exc:
        code = exc.code
        exc.close()
        return code, None
    except (OSError, ValueError, urllib.error.URLError, http.client.HTTPException):
        fail('OpenChamber request failed; not retried')


def health(origin):
    status, body = json_request(origin, 'GET', '/health')
    if (status != 200 or not isinstance(body, dict)
            or not isinstance(body.get('openchamberVersion'), str) or not body['openchamberVersion']):
        fail('loopback host is not an identified OpenChamber desktop server')


def active_client(client):
    return (isinstance(client, dict) and isinstance(client.get('id'), str)
            and bool(client['id'])
            and client.get('clientKind') == 'desktop'
            and isinstance(client.get('label'), str) and bool(client['label'])
            and not client.get('revokedAt') and not client.get('expiresAt'))


def redeem(link, root=ROOT):
    private_dir(root)
    lock = root / '.enrolling'
    try:
        fd = os.open(lock, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
    except FileExistsError:
        fail('enrollment locked; inspect previous attempt before retrying')
    os.close(fd)
    try:
        binding = root / 'client.json'
        if os.path.lexists(binding):
            fail('Voicestack already has a client binding; explicit operator recovery required')
        data, origin = parse_link(link)
        digest = hashlib.sha256(link.encode()).hexdigest()
        attempt_path = root / 'attempt.json'
        attempts = read_private(attempt_path).get('linkDigests') if os.path.lexists(attempt_path) else []
        if (not isinstance(attempts, list) or len(attempts) >= 128
                or any(not isinstance(d, str) or not re.fullmatch('[0-9a-f]{64}', d) for d in attempts)):
            fail('enrollment attempt ledger needs operator review')
        if digest in attempts:
            fail('this Connection link was already attempted; not retried')
        dedupe = identity(root)
        # Persist before contacting the host: failures must not replay this link.
        atomic_private(attempt_path, {'linkDigests': attempts + [digest]})
        health(origin)
        # Immediately before the ONLY redeem POST; no retries or candidate fallback.
        if timestamp(data['expiresAt']) <= time.time():
            fail('Connection link expired')
        status, result = json_request(origin, 'POST', '/api/client-auth/pairing/redeem', {
            'pairingId': data['pairingId'], 'secret': data['secret'],
            'clientKind': 'desktop', 'clientLabel': 'Voicestack', 'deviceName': 'Voicestack',
            'devicePlatform': platform.system().lower(), 'dedupeKey': dedupe})
        if status != 200 or not isinstance(result, dict) or result.get('ok') is not True:
            fail('redemption failed or outcome unknown; not retried')
        server, client, token = result.get('server'), result.get('client'), result.get('clientToken')
        if not isinstance(token, str) or not re.fullmatch(r'oc_client_[A-Za-z0-9_-]+', token):
            fail('redemption response binding invalid; outcome unknown, do not retry')
        try:
            if (not isinstance(server, dict) or server.get('fingerprint') != data['fingerprint']
                    or loopback_origin(server.get('url')) != origin or not active_client(client)):
                fail('redemption response binding invalid')
            if 'deviceName' in client:
                name = client['deviceName']
                if not isinstance(name, str) or name.casefold() != 'voicestack':
                    print('Notice: returned device name differs; continuing.', file=sys.stderr)
            atomic_private(binding, {'version': 1, 'clientId': client['id'], 'clientToken': token,
                'clientKind': client['clientKind'], 'label': client['label'],
                'fingerprint': server['fingerprint'], 'enrolledOrigin': origin, 'dedupeKey': dedupe},
                exclusive=True)
        except (PairingError, OSError, ValueError, KeyboardInterrupt):
            raise DeviceNotStored() from None
    finally:
        lock.unlink()


def status(root=ROOT):
    if not os.path.lexists(root / 'client.json'):
        return {'bindingExists': False}
    value = read_private(root / 'client.json')
    if not active_client({'id': value.get('clientId'), 'clientKind': value.get('clientKind'),
                          'label': value.get('label'), 'deviceName': 'Voicestack'}):
        fail('invalid client binding metadata')
    return {'bindingExists': True, 'clientId': value['clientId'], 'label': value['label'],
            'clientKind': 'desktop', 'origin': loopback_origin(value.get('enrolledOrigin'))}


def intake(stream):
    if stream.isatty():
        with warnings.catch_warnings():
            warnings.simplefilter('error', getpass.GetPassWarning)
            try:
                link = getpass.getpass('Connection link (hidden): ')
            except getpass.GetPassWarning:
                fail('hidden terminal input unavailable; use a secure stdin pipe')
    else:
        link = stream.read(MAX_BYTES + 1)
    if len(link) > MAX_BYTES:
        fail()
    return link.strip()


def main(argv=None, root=ROOT):
    argv = sys.argv[1:] if argv is None else argv
    try:
        if argv == ['redeem']:
            redeem(intake(sys.stdin), root)
            print('Voicestack client binding saved. Run the read-only OpenChamber client check.')
        elif argv == ['status']:
            print(json.dumps(status(root)))
        else:
            fail('usage: pair_openchamber.py redeem|status (no link arguments)')
        return 0
    except DeviceNotStored:
        print('The device was created but not stored. Revoke the device in OpenChamber '
              'and pair again with a new link. Do not retry the old link.', file=sys.stderr)
        return 1
    except (PairingError, OSError, ValueError, EOFError, KeyboardInterrupt):
        # Deliberately do not print exceptions: neither host nor local details leak.
        print('Pairing refused or outcome unknown. Do not retry the same link; inspect local state.',
              file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
