"""Source wiring guards; behavioral coverage lives in VoiceEndedTests."""
from pathlib import Path
import unittest
from test_mac_voice_parity import block

ROOT = Path(__file__).resolve().parent.parent


class VoiceEndedWiringTests(unittest.TestCase):
    def test_only_deliberate_terminal_authority_can_emit_a_call_notice(self):
        source = (ROOT / 'app/Sources/FloatingVoiceCore/CallOrchestration.swift').read_text()
        self.assertIn('deliberate: [.userEnd, .systemEnd].contains(cause)', source)
        self.assertIn('termination != .declined && lifecycle.state != .ringing', source)
        self.assertIn('guard lifecycle.end(epoch) else { return }', source)
        self.assertEqual(source.count('onDeliberateEnd?(endedSession)'), 1)

    def test_native_wires_silent_existing_admit_not_controller_post(self):
        source = (ROOT / 'native/FloatingVoiceApp.swift').read_text()
        start = source.index('private func enqueueVoiceEnded(')
        end = source.index('private func endVoiceMedia()', start)
        notice = source[start:end]
        self.assertIn('boundBackend.admit(target: target, text: text)', notice)
        self.assertNotIn('VoicePost', notice)
        self.assertNotIn('controller.post', notice)
        self.assertNotIn('delivery:', notice)
        self.assertIn('self.backend === boundBackend', notice)

    def test_selection_failure_and_new_start_revoke_but_recovery_does_not_remint(self):
        source = (ROOT / 'native/FloatingVoiceApp.swift').read_text()
        self.assertIn('if let session = pendingVoiceEnded, session.target != backend.lease { session.invalidate() }', source)
        self.assertIn('pendingVoiceEnded?.invalidate()', source)
        self.assertIn('appVoiceSession?.invalidate(); appVoiceSession = nil', source)
        self.assertIn('if callEpoch == nil, appVoiceSession == nil', source)

    def test_system_note_has_dedicated_quiet_history_and_log_paths(self):
        source = (ROOT / 'native/FloatingVoiceApp.swift').read_text()
        self.assertIn('if turn.role == .system', source)
        self.assertIn('"voice.systemNote." + turn.id', source)
        self.assertIn('"history.systemNote." + row.id', source)
        self.assertIn('if row.isSystemNote', source)

    def test_wire_text_is_shared_exact_and_never_contains_old_suffixes(self):
        source = (ROOT / 'app/Sources/FloatingVoiceCore/VoiceEnded.swift').read_text()
        self.assertIn('public static let text = "[voice] ended"', source)
        self.assertNotIn('[voice] ended (', source)

    def test_failed_repair_revokes_before_both_noncall_and_call_pause(self):
        source = (ROOT / 'native/FloatingVoiceApp.swift').read_text()
        handler = block(source, r'private func pauseRouteRecovery\(')
        revoke = handler.index('invalidateVoiceEnded()')
        self.assertLess(revoke, handler.index('guard hasCall'))
        self.assertLess(revoke, handler.index('calls.pauseMediaForRouteRecovery()'))

    def test_scene_waiters_reconcile_current_state_and_new_owners_invalidate(self):
        source = (ROOT / 'native/FloatingVoiceApp.swift').read_text()
        suspend = block(source, r'func suspend\(')
        self.assertNotIn('await voiceEndedPost.value', suspend)
        self.assertNotIn('self?.suspend()', suspend)
        reconcile = block(source, r'private func reconcileCallScene\(')
        self.assertIn('UIApplication.shared.applicationState == .active', reconcile)
        self.assertIn('UIApplication.shared.isProtectedDataAvailable', reconcile)
        self.assertIn('hasCall: hasCall', reconcile)
        self.assertIn('reconcileCallScene(admissionDeferralFinished: true)', reconcile)
        resume = block(source, r'func resume\(')
        resumed = resume.index('voiceEndedScene.sceneResumed(')
        self.assertGreater(resumed, resume.index('guard UIApplication.shared.isProtectedDataAvailable'))
        self.assertGreater(resumed, resume.index('guard credentialRecovery.permit'))
        self.assertIn('foreground: true, protectedDataAvailable: true', resume)
        for declaration in [r'func startVoice\(', r'func select\(']:
            self.assertIn('voiceEndedScene.invalidate()', block(source, declaration))


if __name__ == '__main__':
    unittest.main()
