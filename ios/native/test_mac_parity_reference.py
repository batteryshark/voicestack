from pathlib import Path
import copy
import hashlib
import json
import os
import selectors
import signal
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch

import test_mac_voice_parity as gate
import mac_parity_reader as reader
import parity_git_ownership as ownership

# Explicit inherited test capability only. Production never activates this.
ownership.activate_test_channel()


# Synthetic origin: SHA1 of an explicit test-policy label, NOT claimed Mac4c.
SYNTHETIC_ORIGIN = hashlib.sha1(b'portable-adapter synthetic origin policy v1').hexdigest()


def fixture_git(root, *args):
    """Future authorized runner only. No fixture creation at module import.

    Identical finite pipe/deadline discipline to the reader, with fixture-only
    fixed call sites below. Local Git writes are confined to TemporaryDirectory.
    """
    env = {'PATH': '/usr/bin:/bin', 'LC_ALL': 'C', 'GIT_CONFIG_NOSYSTEM': '1',
           'GIT_CONFIG_GLOBAL': '/dev/null', 'GIT_TERMINAL_PROMPT': '0',
           'GIT_NO_REPLACE_OBJECTS': '1', 'GIT_NO_LAZY_FETCH': '1',
           'GIT_OPTIONAL_LOCKS': '0', 'GIT_ATTR_NOSYSTEM': '1'}
    argv = ['/usr/bin/git', '-c', 'core.hooksPath=/dev/null', '-c', 'core.fsmonitor=false',
            '-c', 'credential.helper=', '-c', 'protocol.allow=never', '-c', 'gc.auto=0',
            '-c', 'maintenance.auto=false', '-c', 'commit.gpgsign=false',
            '-c', 'user.name=Parity Synthetic Fixture',
            '-c', 'user.email=parity@example.invalid', '-C', str(root), *args]
    supervised = ownership.run_if_configured(argv, env, 65536)
    if supervised is not None:
        if supervised[0]:
            raise RuntimeError('fixture Git failure')
        return supervised[1]
    proc = subprocess.Popen(argv, env=env, stdin=subprocess.DEVNULL,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            start_new_session=True)
    output = bytearray()
    try:
        deadline = time.monotonic() + 10
        counts = {'out': 0, 'err': 0}
        with selectors.DefaultSelector() as selector:
            selector.register(proc.stdout, selectors.EVENT_READ, 'out')
            selector.register(proc.stderr, selectors.EVENT_READ, 'err')
            while selector.get_map():
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise RuntimeError('fixture Git timeout')
                for key, _ in selector.select(remaining):
                    data = os.read(key.fileobj.fileno(), 65536)
                    if not data:
                        selector.unregister(key.fileobj); continue
                    counts[key.data] += len(data)
                    if counts[key.data] > 65536:
                        raise RuntimeError('fixture Git output limit')
                    if key.data == 'out':
                        output.extend(data)
            remaining = deadline - time.monotonic()
            if remaining <= 0 or proc.wait(timeout=remaining):
                raise RuntimeError('fixture Git failure')
        return bytes(output)
    finally:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        proc.wait()
        proc.stdout.close(); proc.stderr.close()


def commit_fixture(root):
    fixture_git(root, 'add', '--all')
    fixture_git(root, 'commit', '-qm', 'Synthetic adapter fixture only')
    return fixture_git(root, 'rev-parse', '--verify', 'HEAD').decode().strip()


class MacParityReferenceTests(unittest.TestCase):
    def test_pinned_reference_reads_committed_bytes_not_dirty_checkout(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            file = root / 'app/Sources/FloatingVoiceCore/VoicePost.swift'
            file.parent.mkdir(parents=True)
            file.write_text('committed reference\n')
            fixture_git(root, 'init', '-q', '--template=')
            reference = commit_fixture(root)
            file.write_text('dirty work in progress must not be read\n')
            external = reader.production_reader({'FV_MAC_PARITY_MODE': 'external',
                'FV_MAC_PARITY_EXTERNAL_REPOSITORY': str(root), 'FV_MAC_PARITY_REF': reference})
            self.assertEqual(external.mac_bytes('VoicePost.swift'), b'committed reference\n')
            self.assertEqual(file.read_text(), 'dirty work in progress must not be read\n')

    def test_missing_committed_reference_fails_closed(self):
        with tempfile.TemporaryDirectory() as folder:
            fixture_git(folder, 'init', '-q', '--template=')
            with self.assertRaisesRegex(RuntimeError, 'no fallback'):
                reader.production_reader({'FV_MAC_PARITY_MODE': 'external',
                    'FV_MAC_PARITY_EXTERNAL_REPOSITORY': folder, 'FV_MAC_PARITY_REF': '0' * 40})

    def test_recorded_default_pin_is_one_full_hash(self):
        self.assertRegex(gate.PIN_FILE.read_text(), r'\A[a-f0-9]{40}\n\Z')
        self.assertEqual(gate.reference({}), gate.PIN_FILE.read_text().strip())

    def test_environment_override_and_explicit_worktree_opt_in(self):
        self.assertEqual(gate.reference({'FV_MAC_PARITY_REF': 'a' * 40}), 'a' * 40)
        self.assertEqual(gate.reference({'FV_MAC_PARITY_REF': 'WORKTREE'}), 'WORKTREE')
        with self.assertRaisesRegex(RuntimeError, 'must not be empty'):
            gate.reference({'FV_MAC_PARITY_REF': ''})
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)/reader.ORIGINAL_PREFIX/'VoicePost.swift'
            path.parent.mkdir(parents=True); path.write_bytes(b'explicit dirty bytes')
            with patch.object(reader, '_git', side_effect=AssertionError('must not invoke git')):
                external = reader.production_reader({'FV_MAC_PARITY_MODE': 'external',
                    'FV_MAC_PARITY_EXTERNAL_REPOSITORY': folder, 'FV_MAC_PARITY_REF': 'WORKTREE'})
                self.assertEqual(external.mac_bytes('VoicePost.swift'), b'explicit dirty bytes')

    def test_missing_or_malformed_pin_fails_without_fallback(self):
        with tempfile.TemporaryDirectory() as folder:
            pin = Path(folder)/'pin.txt'
            with self.assertRaisesRegex(RuntimeError, 'Missing Mac parity pin file'):
                gate.reference({}, pin)
            for value in ['', 'WORKTREE\n', 'a'*40+'\n'+'b'*40+'\n']:
                pin.write_text(value)
                with self.assertRaisesRegex(RuntimeError, 'one full commit hash'):
                    gate.reference({}, pin)

    def test_port_readiness_requires_every_enumerated_function(self):
        sources = {file: '\n'.join('func '+name+'() {}' for name in names).encode()
                   for file, names in gate.CUT_IN_PORT_FUNCTIONS.items()}
        self.assertTrue(gate.cut_in_port_present(sources.__getitem__))
        for file, names in gate.CUT_IN_PORT_FUNCTIONS.items():
            for name in names:
                changed = dict(sources); changed[file] = changed[file].replace(('func '+name+'() {}').encode(), b'')
                self.assertFalse(gate.cut_in_port_present(changed.__getitem__))

    def test_allowance_readiness_guard_rejects_both_stale_and_early_removal(self):
        test = gate.MacVoiceParityTests('test_phone_ahead_allowances_empty_exactly_when_pinned_mac_has_cut_in_port')
        for ported, allowances in [(True, {}), (False, {'sustain': 'pending'})]:
            with patch.object(gate, 'PENDING_MAC_PORT', allowances), patch.object(gate, 'cut_in_port_present', return_value=ported):
                test.test_phone_ahead_allowances_empty_exactly_when_pinned_mac_has_cut_in_port()
        for ported, allowances in [(False, {}), (True, {'sustain': 'stale'})]:
            with patch.object(gate, 'PENDING_MAC_PORT', allowances), patch.object(gate, 'cut_in_port_present', return_value=ported):
                with self.assertRaises(AssertionError):
                    test.test_phone_ahead_allowances_empty_exactly_when_pinned_mac_has_cut_in_port()


class CommittedPackageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='portable-parity-synthetic-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        fixture_git(self.root, 'init', '-q', '--template=')
        self.script = self.root / 'ios/native/test_mac_voice_parity.py'
        self.script.parent.mkdir(parents=True)
        self.data = {name: ('// synthetic only: ' + name + '\n').encode() for name in reader.NAMES}
        entries = []
        for name, data in self.data.items():
            path = self.root / reader.PACKAGE_PREFIX / name
            path.parent.mkdir(parents=True, exist_ok=True); path.write_bytes(data)
            digest = hashlib.sha256(data).hexdigest()
            entries.append({'name': name, 'original_path': reader.ORIGINAL_PREFIX + name,
                'packaged_path': reader.PACKAGE_PREFIX + name, 'original_blob_sha256': digest,
                'packaged_blob_sha256': digest, 'sanitization': None})
        self.doc = {'schema': 1, 'original_commit': SYNTHETIC_ORIGIN,
            'original_core_prefix': reader.ORIGINAL_PREFIX,
            'packaged_core_prefix': reader.PACKAGE_PREFIX, 'files': entries}
        self.manifest = self.root / reader.MANIFEST
        self.manifest.parent.mkdir(parents=True, exist_ok=True)
        self.write_manifest()
        self.sha = commit_fixture(self.root)

    def write_manifest(self):
        self.manifest.write_text(json.dumps(self.doc))

    def load(self, sha=None):
        return reader.CommittedPackageReader(self.root, sha or self.sha,
                                             origin_policy=SYNTHETIC_ORIGIN)

    def reject_committed(self):
        sha = commit_fixture(self.root)
        with self.assertRaises(RuntimeError):
            self.load(sha)

    def test_valid_all_eight_and_closed_request(self):
        package = self.load()
        for name, data in self.data.items():
            self.assertEqual(package.mac_bytes(name), data)
        for name in ['Remote.swift', '../VoicePost.swift', '', None]:
            with self.assertRaises(RuntimeError):
                package.mac_bytes(name)

    def test_tampered_committed_last_consumer_stale_hash(self):
        (self.root / reader.PACKAGE_PREFIX / reader.NAMES[-1]).write_bytes(b'committed tamper')
        self.reject_committed()  # Constructor fails before even VoicePost can be returned.

    def test_missing_committed_file_working_valid_cannot_rescue(self):
        path = self.root / reader.PACKAGE_PREFIX / reader.NAMES[-1]
        path.unlink(); sha = commit_fixture(self.root)
        path.write_bytes(self.data[reader.NAMES[-1]])
        with self.assertRaises(RuntimeError): self.load(sha)

    def test_missing_committed_manifest_working_valid_cannot_rescue(self):
        self.manifest.unlink(); sha = commit_fixture(self.root)
        self.write_manifest()
        with self.assertRaises(RuntimeError): self.load(sha)

    def test_wrong_manifest_origin(self):
        self.doc['original_commit'] = hashlib.sha1(b'other synthetic policy').hexdigest()
        self.write_manifest(); self.reject_committed()

    def test_dirty_files_manifest_pin_are_ignored(self):
        for name in reader.NAMES:
            (self.root / reader.PACKAGE_PREFIX / name).write_bytes(b'dirty bytes')
        self.manifest.write_text('not JSON')
        (self.manifest.parent / 'mac-parity-ref.txt').write_text('WORKTREE')
        package = self.load()
        self.assertEqual({n: package.mac_bytes(n) for n in reader.NAMES}, self.data)

    def test_other_legitimate_core_file_permitted(self):
        (self.root / reader.PACKAGE_PREFIX / 'Other.swift').write_bytes(b'synthetic other')
        package = self.load(commit_fixture(self.root))
        self.assertEqual(package.mac_bytes(reader.NAMES[0]), self.data[reader.NAMES[0]])

    def test_invalid_manifest_cases(self):
        baseline = copy.deepcopy(self.doc)
        cases = [
            ('extra consumer', lambda d: d['files'].append(copy.deepcopy(d['files'][0]))),
            ('duplicate consumer', lambda d: d['files'].__setitem__(1, copy.deepcopy(d['files'][0]))),
            ('unknown consumer', lambda d: d['files'][0].__setitem__('name', 'Remote.swift')),
            ('unknown field', lambda d: d.__setitem__('unified_commit', self.sha)),
            ('schema bool', lambda d: d.__setitem__('schema', True)),
            ('schema version', lambda d: d.__setitem__('schema', 2)),
            ('hash format', lambda d: d['files'][0].__setitem__('packaged_blob_sha256', 'A'*64)),
            ('path traversal', lambda d: d['files'][0].__setitem__('packaged_path', '../VoicePost.swift')),
            ('original path', lambda d: d['files'][0].__setitem__('original_path', 'wrong')),
            ('arbitrary prefix', lambda d: d.__setitem__('packaged_core_prefix', 'other/')),
            ('original prefix', lambda d: d.__setitem__('original_core_prefix', 'other/')),
            ('files type', lambda d: d.__setitem__('files', {})),
            ('missing consumer', lambda d: d['files'].pop()),
            ('missing field', lambda d: d['files'][0].pop('sanitization')),
            ('stale hash no mapping', lambda d: d['files'][0].__setitem__('packaged_blob_sha256', '0'*64)),
            ('equal hash mapping', lambda d: d['files'][0].__setitem__('sanitization', {})),
        ]
        for label, mutate in cases:
            with self.subTest(case=label):
                self.doc = copy.deepcopy(baseline); mutate(self.doc)
                self.write_manifest(); self.reject_committed()

    def test_duplicate_json_key(self):
        self.manifest.write_text(json.dumps(self.doc).replace('"schema": 1', '"schema": 1, "schema": 1'))
        self.reject_committed()

    def test_changed_hash_mapping_and_packaged_mismatch(self):
        item = self.doc['files'][0]
        original = b'explicit synthetic before region'
        item['original_blob_sha256'] = hashlib.sha256(original).hexdigest()
        item['sanitization'] = {'mapping_id': 'synthetic-label-1', 'changes': [{
            'original_region_sha256': hashlib.sha256(original).hexdigest(),
            'packaged_region_sha256': item['packaged_blob_sha256'],
            'description': 'Synthetic label substitution.'}]}
        self.write_manifest(); sha = commit_fixture(self.root)
        self.assertEqual(self.load(sha).mac_bytes(reader.NAMES[0]), self.data[reader.NAMES[0]])
        item['packaged_blob_sha256'] = '0'*64
        self.write_manifest(); self.reject_committed()

    def test_invalid_mapping_cases(self):
        item = self.doc['files'][0]
        item['original_blob_sha256'] = hashlib.sha256(b'synthetic before').hexdigest()
        valid = {'mapping_id': 'synthetic', 'changes': [{'original_region_sha256': '1'*64,
            'packaged_region_sha256': '2'*64, 'description': 'Synthetic substitution.'}]}
        bad = [None, {}, {'mapping_id': 'synthetic', 'changes': []},
               dict(valid, unknown=True), dict(valid, mapping_id='../bad'),
               dict(valid, changes=[dict(valid['changes'][0], description='')]),
               dict(valid, changes=[dict(valid['changes'][0], description='Synthetic\x7fdescription')]),
               dict(valid, changes=[dict(valid['changes'][0], description='Synthetic\x85description')]),
               dict(valid, changes=[dict(valid['changes'][0], original_region_sha256='bad')])]
        for index, mapping in enumerate(bad):
            with self.subTest(case=index):
                item['sanitization'] = mapping; self.write_manifest(); self.reject_committed()

    def test_blob_and_manifest_caps(self):
        self.manifest.write_bytes(b' ' * (reader.MANIFEST_CAP + 1))
        self.reject_committed()
        self.write_manifest()
        (self.root / reader.PACKAGE_PREFIX / reader.NAMES[0]).write_bytes(b'x' * (reader.SOURCE_CAP + 1))
        self.reject_committed()

    def test_symlink_file_and_non_tree_ancestor(self):
        path = self.root / reader.PACKAGE_PREFIX / reader.NAMES[0]
        path.unlink(); path.symlink_to('Other.swift'); self.reject_committed()
        path.unlink(); path.mkdir(); (path / 'nested').write_bytes(b'synthetic')
        self.reject_committed()
        # Ancestor tree substitution: remove only our fixture-owned subtree files.
        for child in path.iterdir(): child.unlink()
        path.rmdir()
        core = self.root / reader.PACKAGE_PREFIX
        for child in core.iterdir(): child.unlink()
        core.rmdir(); core.write_bytes(b'not a tree'); self.reject_committed()

    def test_manifest_symlink(self):
        self.manifest.unlink(); self.manifest.symlink_to('other.json')
        self.reject_committed()

    def test_executable_blob_rejected(self):
        path = self.root / reader.PACKAGE_PREFIX / reader.NAMES[0]
        path.chmod(0o755)
        self.reject_committed()

    def test_manifest_tree_rejected(self):
        self.manifest.unlink(); self.manifest.mkdir()
        (self.manifest / 'nested').write_bytes(b'synthetic')
        self.reject_committed()

    def test_symlink_ancestor_rejected(self):
        core = self.root / reader.PACKAGE_PREFIX
        for child in core.iterdir(): child.unlink()
        core.rmdir(); core.symlink_to('elsewhere', target_is_directory=True)
        self.reject_committed()

    def test_explicit_commit_ignores_later_head(self):
        path = self.root / reader.PACKAGE_PREFIX / reader.NAMES[0]
        path.write_bytes(b'later committed tamper')
        commit_fixture(self.root)
        self.assertEqual(self.load().mac_bytes(reader.NAMES[0]), self.data[reader.NAMES[0]])

    def test_factory_policy_is_fixed_and_locator_not_cwd(self):
        env = {'FV_MAC_PARITY_PACKAGE_COMMIT': self.sha}
        with patch.object(reader, 'CommittedPackageReader') as constructor:
            reader.production_reader(env, self.script)
        constructor.assert_called_once_with(self.root, self.sha, origin_policy=reader.ORIGINAL_COMMIT)

    def test_submodule_consumer(self):
        path = self.root / reader.PACKAGE_PREFIX / reader.NAMES[0]
        path.unlink()
        fixture_git(self.root, 'add', '--all')
        fixture_git(self.root, 'update-index', '--add', '--cacheinfo',
                    '160000,' + self.sha + ',' + reader.PACKAGE_PREFIX + reader.NAMES[0])
        fixture_git(self.root, 'commit', '-qm', 'Synthetic gitlink only')
        sha = fixture_git(self.root, 'rev-parse', 'HEAD').decode().strip()
        with self.assertRaises(RuntimeError): self.load(sha)

    def test_selection_failures(self):
        cases = [{}, {'FV_MAC_PARITY_PACKAGE_COMMIT': ''},
            {'FV_MAC_PARITY_PACKAGE_COMMIT': 'HEAD'},
            {'FV_MAC_PARITY_PACKAGE_COMMIT': 'A'*40},
            {'FV_MAC_PARITY_PACKAGE_COMMIT': '0'*40},
            {'FV_MAC_PARITY_MODE': ''}, {'FV_MAC_PARITY_MODE': 'other'},
            {'FV_MAC_PARITY_PACKAGE_COMMIT': self.sha, 'FV_MAC_PARITY_REF': ''},
            {'FV_MAC_PARITY_PACKAGE_COMMIT': self.sha, 'FV_MAC_PARITY_EXTERNAL_REPOSITORY': str(self.root)},
            {'FV_MAC_PARITY_MODE': 'external', 'FV_MAC_PARITY_PACKAGE_COMMIT': self.sha},
            {'FV_MAC_PARITY_MODE': 'external'},
            {'FV_MAC_PARITY_MODE': 'external', 'FV_MAC_PARITY_EXTERNAL_REPOSITORY': 'relative'},
            {'FV_MAC_PARITY_MODE': 'external', 'FV_MAC_PARITY_EXTERNAL_REPOSITORY': str(self.root), 'FV_MAC_PARITY_REF': ''}]
        for index, env in enumerate(cases):
            with self.subTest(case=index), self.assertRaises(RuntimeError):
                reader.production_reader(env, self.script)

    def test_noncommit_selection(self):
        tree = fixture_git(self.root, 'rev-parse', self.sha + '^{tree}').decode().strip()
        with self.assertRaises(RuntimeError): self.load(tree)

    def test_production_policy_cannot_be_selected_by_manifest_or_env(self):
        env = {'FV_MAC_PARITY_PACKAGE_COMMIT': self.sha,
               'FV_MAC_PARITY_ORIGINAL_COMMIT': SYNTHETIC_ORIGIN,
               'FV_MAC_PARITY_ORIGIN_POLICY': SYNTHETIC_ORIGIN}
        with self.assertRaisesRegex(RuntimeError, 'origin policy'):
            reader.production_reader(env, self.script)
        with self.assertRaises(TypeError):
            reader.production_reader(env, self.script, origin_policy=SYNTHETIC_ORIGIN)


from test_parity_git_ownership import OwnershipProtocolTests


if __name__ == '__main__':
    unittest.main()
