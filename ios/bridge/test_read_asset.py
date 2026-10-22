"""Deterministic control points around the real helper; synthetic owned files only."""
import io
import os
from pathlib import Path
import runpy
import subprocess
import sys
import tempfile
import types
import unittest
from unittest.mock import patch


HELPER = Path(__file__).with_name('read-asset.py')


class ReadAssetTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='fv-read-asset-')
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        self.root = self.base / 'approved'
        self.root.mkdir()
        self.folder = self.root / 'nested'
        self.folder.mkdir()
        self.file = self.folder / 'image.png'
        self.original = b'original synthetic bytes' * 8192
        self.file.write_bytes(self.original)
        self.outside = self.base / 'outside'
        self.outside.mkdir()
        (self.outside / 'image.png').write_bytes(b'OUTSIDE SYNTHETIC SENTINEL')

    def invoke(self, on_open=None, on_read=None, on_stat=None):
        # Run the production script, not a reimplementation. Hooks execute at exact
        # syscall boundaries; no sleeps, user data, or production test switches.
        real_open, real_read, real_stat, real_close = os.open, os.read, os.fstat, os.close
        owned = set()
        output = io.BytesIO()

        def opened(name, flags, *args, **kwargs):
            fd = real_open(name, flags, *args, **kwargs)
            owned.add(fd)
            if on_open:
                on_open(name, flags, fd)
            return fd

        def read(fd, count):
            value = real_read(fd, count)
            if on_read:
                on_read(fd, value)
            return value

        def stated(fd):
            value = real_stat(fd)
            if on_stat:
                on_stat(fd, value)
            return value

        def closed(fd):
            real_close(fd)
            owned.remove(fd)

        try:
            with patch.object(sys, 'argv', [str(HELPER), str(self.root), 'nested/image.png']), \
                 patch.object(sys, 'stdout', types.SimpleNamespace(buffer=output)), \
                 patch.object(os, 'open', opened), patch.object(os, 'read', read), \
                 patch.object(os, 'fstat', stated), patch.object(os, 'close', closed):
                runpy.run_path(str(HELPER), run_name='__main__')
        finally:
            self.assertEqual(owned, set(), 'helper leaked an opened descriptor')
            self.assertNotIn(b'OUTSIDE', output.getvalue())
            self.output = output.getvalue()
        return self.output

    def test_regular_read_and_every_component_flags(self):
        def check(name, flags, fd):
            if name == '/':
                self.assertTrue(flags & os.O_DIRECTORY)
            else:
                self.assertTrue(flags & os.O_NOFOLLOW)
                self.assertTrue(flags & os.O_NONBLOCK)
                if name != 'image.png':
                    self.assertTrue(flags & os.O_DIRECTORY)
        self.assertEqual(self.invoke(on_open=check), self.original)

    def test_final_symlink_is_refused(self):
        self.file.unlink()
        self.file.symlink_to(self.outside / 'image.png')
        with self.assertRaises(OSError):
            self.invoke()
        self.assertEqual(self.output, b'')

    def test_ancestor_symlink_is_refused(self):
        self.folder.rename(self.root / 'parked')
        self.folder.symlink_to(self.outside, target_is_directory=True)
        with self.assertRaises(OSError):
            self.invoke()
        self.assertEqual(self.output, b'')

    def test_approved_root_symlink_is_refused(self):
        self.root.rename(self.base / 'parked-root')
        self.root.symlink_to(self.outside, target_is_directory=True)
        with self.assertRaises(OSError):
            self.invoke()
        self.assertEqual(self.output, b'')

    def test_open_then_final_rename_keeps_original_descriptor(self):
        def swap(name, flags, fd):
            if name == 'image.png':
                self.file.rename(self.folder / 'parked.png')
                self.file.symlink_to(self.outside / 'image.png')
        self.assertEqual(self.invoke(on_open=swap), self.original)

    def test_open_then_ancestor_rename_keeps_original_directory(self):
        def swap(name, flags, fd):
            if name == 'nested':
                self.folder.rename(self.root / 'parked')
                self.folder.symlink_to(self.outside, target_is_directory=True)
        self.assertEqual(self.invoke(on_open=swap), self.original)

    def test_truncate_between_stat_and_read_is_closed_refusal(self):
        calls = 0
        def truncate(fd, info):
            nonlocal calls
            calls += 1
            if calls == 1:
                self.file.write_bytes(b'')
        with self.assertRaises(AssertionError):
            self.invoke(on_stat=truncate)
        self.assertEqual(self.output, b'')

    def test_same_size_mutation_after_first_chunk_is_closed_refusal(self):
        calls = 0
        def mutate(fd, value):
            nonlocal calls
            calls += 1
            if calls == 1:
                before = self.file.stat()
                with self.file.open('r+b') as writer:
                    writer.write(b'X' * len(self.original))
                # Force an observable timestamp difference even on coarse filesystems.
                os.utime(self.file, ns=(before.st_atime_ns, before.st_mtime_ns + 1_000_000_000))
        with self.assertRaises(AssertionError):
            self.invoke(on_read=mutate)
        self.assertEqual(self.output, b'')

    def test_growth_after_read_is_closed_refusal(self):
        calls = 0
        def grow(fd, value):
            nonlocal calls
            calls += 1
            if calls == 1:
                with self.file.open('ab') as writer:
                    writer.write(b'growth')
        with self.assertRaises(AssertionError):
            self.invoke(on_read=grow)
        self.assertEqual(self.output, b'')

    def test_nonregular_empty_and_oversize_are_bounded_refusals(self):
        # Subprocess watchdog independently verifies O_NONBLOCK on a FIFO.
        self.file.unlink()
        for kind in ('fifo', 'directory', 'empty', 'oversize'):
            with self.subTest(kind=kind):
                if kind == 'fifo':
                    os.mkfifo(self.file)
                elif kind == 'directory':
                    self.file.mkdir()
                else:
                    with self.file.open('wb') as writer:
                        writer.truncate(0 if kind == 'empty' else 8 * 1024 * 1024 + 1)
                result = subprocess.run(['/usr/bin/python3', '-I', str(HELPER), str(self.root), 'nested/image.png'],
                                        capture_output=True, timeout=5, env={'PATH': '/usr/bin:/bin'})
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, b'')
                self.file.rmdir() if kind == 'directory' else self.file.unlink()


if __name__ == '__main__':
    unittest.main()
