"""Offline native wiring assertions; no device or live bridge access."""
from pathlib import Path
import unittest
from test_mac_voice_parity import block

ROOT = Path(__file__).resolve().parents[1]
AUDIO = (ROOT/'native/IOSAudio.swift').read_text()
APP = (ROOT/'native/FloatingVoiceApp.swift').read_text()


class AutomaticCutInWiringTests(unittest.TestCase):
    def test_reversible_cut_is_native_pause_never_stop_or_pcm_skip(self):
        pause = block(AUDIO, r'func pauseForAutomaticCutIn\(')
        self.assertIn('player.pause()', pause)
        for forbidden in ['player.stop()', 'suspendPlaybackForRouteRepair', 'continuity.suspend', 'epoch +=', 'cancel()']:
            self.assertNotIn(forbidden, pause)
        self.assertIn('sourceSignals.suspend()', pause)
        self.assertIn('renderDropouts.suspend()', pause)
        resume = block(AUDIO, r'func resumeAfterAutomaticCutIn\(')
        self.assertIn('playbackQueue.depth > 0', resume)
        self.assertIn('player.play()', resume)
        self.assertIn('engine.isRunning, coordinator.mayRunMedia', resume)

    def test_producer_and_repair_do_not_restart_while_tentatively_paused(self):
        play = block(AUDIO, r'func play\(')
        self.assertIn('while automaticCutInPaused', play)
        repair = block(AUDIO, r'private func scheduleRecovery\(')
        self.assertIn('if !self.automaticCutInPaused', repair)
        self.assertIn('self.playbackContinuity?.startRetainedRun', repair)

    def test_duck_gain_is_real_player_volume_and_meter_expectation(self):
        gain = block(AUDIO, r'func setCutInGain\(')
        self.assertIn('player.volume = gain', gain)
        self.assertIn('sourceSignals.setExpectedGain(Double(gain))', gain)

    def test_notice_is_local_visible_and_owner_fenced_accessibility(self):
        notice = block(APP, r'controller.onPrivateNotice =')
        self.assertIn('self.surface.binding == binding, self.backend?.lease == lease', notice)
        self.assertIn('UIAccessibility.post(notification: .announcement, argument: notice.rawValue)', notice)
        self.assertIn('.accessibilityIdentifier("voice.privateNotice")', APP)
        self.assertNotIn('backend.prompt', notice)

    def test_tap_alignment_uses_its_own_timestamp_and_records_start_latency(self):
        tap = block(AUDIO, r'private func installRenderHandler\(')
        self.assertIn('buffer, time in', tap)
        self.assertIn('renderPlayer.playerTime(forNodeTime: time)', tap)
        self.assertNotIn('renderPlayer.lastRenderTime', tap)
        self.assertIn('.startLatencyMs: signals.startLatencyMs', AUDIO)

    def test_repair_barrier_precedes_all_reentrant_admission_and_is_released_only_after_install(self):
        repair = block(AUDIO, r'private func scheduleRecovery\(')
        begin = repair.index('let repairOwner = graphRepairBarrier.begin()')
        self.assertLess(begin, repair.index('suspendPlaybackForRouteRepair()'))
        self.assertLess(begin, repair.index('graphAdmission.beginRepair()'))
        self.assertLess(begin, repair.index('onDuplexChange?()'))
        self.assertLess(repair.index('onDuplexChange?()'), repair.index('recoveryTask = Task'))
        install = repair.index('self.graphRepairBarrier.replacementInstalled(repairOwner)')
        self.assertLess(repair.index('self.engine.stop(); self.player.stop()'), install)
        self.assertLess(repair.index('try self.engine.start()'), install)
        self.assertLess(install, repair.index('try self.resumeRetainedPlayback?()'))
        rollback = block(AUDIO, r'func resumeAfterAutomaticCutIn\(')
        barrier = rollback.index('guard !graphRepairBarrier.inProgress else { return }')
        self.assertLess(rollback.index('automaticCutInPaused = false'), barrier)
        self.assertLess(barrier, rollback.index('try resumeRetainedPlayback?()'))
        self.assertLess(barrier, rollback.index('player.play()'))
        close = block(AUDIO, r'private func close\(')
        self.assertLess(close.index('engine.stop()'), close.index('graphRepairBarrier.resetAfterClose()'))

    def test_first_low_interval_gets_independent_validated_completion_proof(self):
        enqueue = block(AUDIO, r'private func enqueueRetainedSegment\(')
        self.assertLess(enqueue.index('continuity.completed(segment.token, revision: revision)'),
                        enqueue.index('sourceSignals.confirmRendered(through: continuity.position, token: ordinal)'))


if __name__ == '__main__': unittest.main()
