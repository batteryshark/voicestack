"""Read-only policy wiring, with transport/catch-up behavior covered in Swift."""
from pathlib import Path
import importlib.util
import json
import tempfile
import unittest
from test_mac_voice_parity import block

CORE = Path(__file__).resolve().parents[1] / 'app/Sources/FloatingVoiceCore'


class EventsPathPolicyWiringTests(unittest.TestCase):
    def test_monitor_uses_effective_interface_identity_not_unused_inventory_or_names(self):
        source = (CORE/'Remote.swift').read_text()
        adapter = block(source, r'private extension NetworkPathSnapshot')
        self.assertIn('path.availableInterfaces.filter { path.usesInterfaceType($0.type) }', adapter)
        self.assertIn('Interface(kind, index: value.index)', adapter)
        self.assertIn('satisfied: path.status == .satisfied', adapter)
        self.assertNotIn('.name', adapter)
        handler = block(source, r'pathMonitor.pathUpdateHandler =')
        self.assertIn('NetworkPathSnapshot(path: path)', handler)
        self.assertIn('networkPathChanged(snapshot)', handler)
        self.assertNotIn('if path.status', handler)  # Unsatisfied transitions reach policy too.

    def test_usable_hint_never_cancels_stream_or_advances_path_revision(self):
        source = (CORE/'Remote.swift').read_text()
        hint = block(source, r'public func networkPathChanged\(\)')
        self.assertIn('retryWait?.cancel()', hint)
        self.assertNotIn('currentStream', hint)
        self.assertNotIn('pathRevision', hint)
        change = block(source, r'public func networkPathChanged\(_ path:')
        reconnect = change.index('case .reconnect:')
        self.assertGreater(change.index('pathRevision += 1'), reconnect)
        self.assertGreater(change.index('currentStream?.cancel(cause: .pathChange)'), reconnect)

    def test_watchdog_clock_and_resource_lifetime_are_not_shortened(self):
        policy = (CORE/'NetworkPolicy.swift').read_text()
        self.assertIn('now - lastByte >= 75', policy)
        stream = (CORE/'HTTPStream.swift').read_text()
        self.assertIn('self?.checkIdle(now: ProcessInfo.processInfo.systemUptime)', stream)
        self.assertIn('resourceTimeout: TimeInterval = 300', stream)
        self.assertIn('watchdog.received(now: now)', stream)

    def test_follow_path_generation_survives_lane_wait_and_fences_new_read_creation(self):
        source = (CORE/'Remote.swift').read_text()
        lane = block(source, r'private func readInLatestLane\(')
        self.assertIn('readPath = expectedPath ?? pathRevision', lane)
        wait = lane.index('_ = try? await pending.value')
        check = lane.index('readPath == pathRevision', wait)
        create = lane.index('let task = Task')
        self.assertLess(wait, check)
        self.assertLess(check, create)
        self.assertLess(lane.index('readPath == self.pathRevision', create), lane.index('self.store?.beginReconnect()'))
        follow = block(source, r'private func follow\(')
        self.assertIn('readInLatestLane(target, reconnecting: true, expectedPath: pathAtAttempt)', follow)
        ready = follow.index('connection = "connected"')
        self.assertLess(follow.index('guard pathAtAttempt == pathRevision', follow.index('expectedPath: pathAtAttempt')), ready)

    def test_analysis_deduplicates_snapshots_and_does_not_count_generic_error_companions(self):
        path = CORE.parents[2] / 'tools/analyze_events_churn.py'
        spec = importlib.util.spec_from_file_location('events_evidence', path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            phone = root / 'pull-b29-call-0900'
            phone.mkdir()
            rows = [
                {'time': 100, 'build': 29, 'stage': 'startup', 'category': 'begin'},
                {'time': 110, 'build': 29, 'stage': 'events', 'category': 'failed', 'attempt': 'a', 'elapsedMs': 5000, 'cancellationCause': 'pathChange'},
                {'time': 110.01, 'build': 29, 'stage': 'events', 'category': 'failed', 'status': 1},
                {'time': 111, 'build': 29, 'stage': 'events', 'category': 'begin', 'attempt': 'b'},
            ]
            for name in ['stages.json', 'stages-final.json']:
                (phone / name).write_text(json.dumps(rows))
            bridge = root / 'bridge.jsonl'
            bridge.write_text('\n'.join(json.dumps(r) for r in [
                {'time': 1000, 'stage': 'events', 'category': 'begin', 'attempt': 'a'},
                {'time': 2000, 'stage': 'events', 'category': 'cancelled', 'reason': 'downstream_closed', 'attempt': 'a', 'elapsedMs': 1000},
                {'time': 2100, 'stage': 'events', 'category': 'begin', 'attempt': 'b'},
            ]))
            result = module.analyze(root, bridge)
            self.assertEqual(result['unique_records'], 4)
            self.assertEqual(result['phone_closed_causes'], {'b29:pathChange': 1})
            self.assertEqual(result['launch_windows'][0]['retained_path_cancels'], 1)
            self.assertEqual(result['bridge']['reconnect_closes'], 1)


if __name__ == '__main__': unittest.main()
