#!/usr/bin/python3
"""Handle-relative, no-follow walk. No shell, network, or caller-controlled roots.

Node has no openat binding. Walking by directory descriptors avoids the ancestor
rename/symlink race that realpath + O_NOFOLLOW on just the final file cannot close.
Only invoked by the broker after deriving the exact reference and approved root.
"""
import os
import stat
import sys

root, relative = sys.argv[1:]
parts = root.split('/') + relative.split('/')
assert root.startswith('/') and all(p not in ('.', '..') for p in parts)
fd = os.open('/', os.O_RDONLY | os.O_DIRECTORY)
try:
    components = [p for p in parts if p]
    for index, part in enumerate(components):
        last = index == len(components) - 1
        next_fd = os.open(part, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | (0 if last else os.O_DIRECTORY), dir_fd=fd)
        os.close(fd)
        fd = next_fd
    info = os.fstat(fd)
    assert stat.S_ISREG(info.st_mode) and 0 < info.st_size <= 8 * 1024 * 1024
    chunks = []
    remaining = info.st_size
    while remaining:
        chunk = os.read(fd, min(remaining, 65536))
        assert chunk
        chunks.append(chunk)
        remaining -= len(chunk)
    after = os.fstat(fd)
    assert (after.st_size, after.st_mtime_ns, after.st_ctime_ns) == (info.st_size, info.st_mtime_ns, info.st_ctime_ns)
    sys.stdout.buffer.write(b''.join(chunks))
finally:
    os.close(fd)
