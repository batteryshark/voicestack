#!/usr/bin/env python3
"""Reserve fresh output only. No removal, replacement, signing or app access."""
import os
from pathlib import Path
import re
import sys


def reserve(root, output):
    # Inspect the original spelling before abspath/Path erase dot/empty components.
    if not isinstance(output, str) or not output:
        raise ValueError('unsafe lexical output route')
    parts = output.split('/')[1:] if output.startswith('/') else output.split('/')
    if any(part in ('', '.', '..') for part in parts):
        raise ValueError('unsafe lexical output route')
    root = Path(root).resolve(strict=True)
    area = root / 'build'
    # Check lexical spelling before resolving: no symlink/.. alternate routes.
    output = os.path.abspath(output) if not os.path.isabs(output) else output
    path = Path(output)
    if str(path) != output or path.parent != area or not re.fullmatch(r'[A-Za-z0-9_-]+\.app', path.name):
        raise ValueError('output must be a fresh direct .app child of the snapshot build area')
    if area.is_symlink() or (area.exists() and not area.is_dir()):
        raise ValueError('unsafe build area')
    area.mkdir(mode=0o700, exist_ok=True)
    # dir_fd + O_NOFOLLOW keeps reservation inside the checked build area.
    fd = os.open(area, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.mkdir(path.name, mode=0o700, dir_fd=fd)  # exclusive; existing files/symlinks all fail
    finally:
        os.close(fd)
    return path


if __name__ == '__main__':
    try:
        print(reserve(*sys.argv[1:]))
    except (OSError, ValueError, TypeError):
        sys.exit('Refusing unsafe or existing output; choose a fresh snapshot build name.')
