"""Explicit private input/output only; descriptor-relative, no symlink traversal."""
import json
import os
import re
import secrets
import stat

LIMIT = 65536


def directory(raw):
    # Check spelling before pathlib/normpath can erase a traversal component.
    raw = os.fspath(raw)
    parts = raw.split('/')
    if not raw.startswith('/') or '..' in parts or '.' in parts:
        raise ValueError('invalid private path')
    fd = os.open('/', os.O_RDONLY | os.O_DIRECTORY)
    try:
        for part in filter(None, parts):
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = child
        return fd
    except BaseException:
        os.close(fd)
        raise ValueError('invalid private path') from None


def owner_directory(raw):
    fd = directory(raw)
    st = os.fstat(fd)
    if st.st_uid != os.getuid() or stat.S_IMODE(st.st_mode) != 0o700:
        os.close(fd)
        raise ValueError('private output directory must be owner-only mode 0700')
    return fd


def unique(pairs):
    obj = {}
    for key, value in pairs:
        if key in obj:
            raise ValueError('invalid private configuration')
        obj[key] = value
    return obj


def read_file(raw):
    raw = os.fspath(raw)
    parent, _, name = raw.rpartition('/')
    if not name or name in ('.', '..') or not raw.startswith('/'):
        raise ValueError('invalid private input')
    dfd = directory(parent or '/')
    fd = None
    try:
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=dfd)
        st = os.fstat(fd)
        if (not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid()
                or stat.S_IMODE(st.st_mode) != 0o600 or st.st_nlink != 1 or st.st_size > LIMIT):
            raise ValueError()
        raw = os.read(fd, LIMIT + 1)
        if len(raw) > LIMIT:
            raise ValueError()
        return raw
    except (OSError, ValueError):
        raise ValueError('invalid private input') from None
    finally:
        if fd is not None:
            os.close(fd)
        os.close(dfd)


def bootstrap(mode, env):
    selectors = [k for k in ('FV_PAIRING_BOOTSTRAP_FILE', 'FV_PAIRING_BOOTSTRAP_JSON') if k in env]
    if mode == 'UPDATE' and not selectors:
        return ''
    if mode != 'ENROLL' or len(selectors) != 1:
        raise ValueError('invalid enrollment input selection')
    try:
        value = env[selectors[0]]
        if not value:
            raise ValueError()
        raw = read_file(value) if selectors[0].endswith('_FILE') else value.encode('utf-8')
        if len(raw) > LIMIT:
            raise ValueError()
        obj = json.loads(raw, object_pairs_hook=unique)
        if (not isinstance(obj, dict) or set(obj) != {'bootstrap'}
                or not isinstance(obj['bootstrap'], str)
                or not re.fullmatch(r'[A-Za-z0-9_-]{43}', obj['bootstrap'])):
            raise ValueError()
        return obj['bootstrap']
    except (ValueError, OSError, UnicodeError):
        raise ValueError('invalid enrollment input') from None


def available(dfd, name):
    try:
        os.stat(name, dir_fd=dfd, follow_symlinks=False)
    except FileNotFoundError:
        return
    raise ValueError('private output already exists; operator recovery required')


def publish(dfd, name, raw):
    available(dfd, name)
    temporary = '.enrollment-' + secrets.token_hex(16)
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=dfd)
    try:
        with os.fdopen(fd, 'wb') as stream:
            os.fchmod(stream.fileno(), 0o600)
            stream.write(raw)
            stream.flush()
            os.fsync(stream.fileno())
        os.link(temporary, name, src_dir_fd=dfd, dst_dir_fd=dfd, follow_symlinks=False)
        os.fsync(dfd)
    finally:
        os.unlink(temporary, dir_fd=dfd)
