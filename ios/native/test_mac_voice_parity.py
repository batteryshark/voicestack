"""Read-only parity: verified committed Mac package versus phone working inputs.

Explicit FV_MAC_PARITY_PACKAGE_COMMIT is required (default mode: package).
External diagnostics require explicit mode and repository; never package proof.
See ../docs/MAC-PARITY.md. Comparison semantics below remain owner-pinned.
"""
from pathlib import Path
import re
import unittest
from mac_parity_reader import production_reader, reference

PHONE = Path(__file__).resolve().parent.parent/'app/Sources/FloatingVoiceCore'
PIN_FILE = Path(__file__).resolve().parent.parent/'shared/mac-parity-ref.txt'
_MAC_READER = None


def mac_bytes(name):
    global _MAC_READER
    if _MAC_READER is None:
        _MAC_READER = production_reader(script_file=__file__)
    return _MAC_READER.mac_bytes(name)

# Reviewed Mac cut-in port is pinned. No phone-ahead statements are exempted.
PENDING_MAC_PORT = {}

# This readiness check is not a parity normalization: after a reviewed Mac port,
# remove ONLY PENDING_MAC_PORT's enumerated statements and run the strict gate.
CUT_IN_PORT_FUNCTIONS = {
    'Controller.swift': ['beginUtteranceOutcome', 'makeUtteranceOutcomeObserver',
        'observeAutomaticInterim', 'observeAutomaticVoice', 'applyAutomaticCutIn',
        'observeUtteranceFinal', 'finishNonwordOutcome', 'finishUtteranceOutcomeIdle',
        'showDidntCatchThat', 'discardUtteranceOutcomes', 'retireUtteranceOutcomeOwnership'],
    'Speaker.swift': ['duckForAutomaticCutIn', 'commitAutomaticCutIn',
        'restoreAutomaticCutIn', 'cancelAutomaticCutIn'],
}


def cut_in_port_present(reader=mac_bytes):
    return all(all(re.search(r'\bfunc\s+'+name+r'\(', source) for name in names)
               for file, names in CUT_IN_PORT_FUNCTIONS.items()
               for source in [reader(file).decode('utf-8')])


def normalized(text):
    return re.sub(r'\s+', '', re.sub(r'//[^\n]*', '', text))


def block(text, declaration):
    match = re.search(declaration, text)
    if not match: raise AssertionError('Missing parity declaration: ' + declaration)
    start = text.index('{', match.start())
    depth = 1
    for i in range(start+1, len(text)):
        if text[i] == '{': depth += 1
        elif text[i] == '}': depth -= 1
        if depth == 0: return text[start+1:i]
    raise AssertionError('Unbalanced parity declaration: ' + declaration)


def region(text, start, end):
    first = text.index(start)
    return text[first:text.index(end, first)]


def controller_start_body(text):
    body = block(text, r'public func start\(')
    if 'status.running = true' in body:
        return body
    # Mac's deliberate Start now delegates to a logical-session-aware helper.
    # Follow ONLY this exact forwarding contract; keep the compared region below
    # unchanged, rather than treating a missing region as permission to skip it.
    if normalized(body) != normalized('await start(preservingLogicalSession: false)'):
        raise AssertionError('Unrecognized Controller.start wrapper')
    return block(text, r'private func start\(preservingLogicalSession:\s*Bool\)')


def without_mac_assistant_name_ui(text):
    # Reviewed allowlist: the principal chose a fixed "Agent" phone label, so only Mac-only naming UI is excluded.
    literal = r'"(?:\\.|[^"\\\r\n])*"'
    for declaration in [r'public var assistantName\s*=\s*'+literal,
                        r'public static let defaultAssistantName\s*=\s*'+literal,
                        r'public static let assistantNameLimit\s*=\s*\d+\b']:
        text = re.sub(declaration, '', text)
    for declaration in [r'public static func normalizedAssistantName\(', r'public var assistantDisplayName:']:
        match = re.search(declaration, text)
        if match:
            opening = text.index('{', match.start())
            end = opening + len(block(text, declaration)) + 2
            text = text[:match.start()] + text[end:]
    return text


class MacVoiceParityTests(unittest.TestCase):
    def test_phone_ahead_allowances_empty_exactly_when_pinned_mac_has_cut_in_port(self):
        self.assertEqual(not PENDING_MAC_PORT, cut_in_port_present(),
                         'Bump the reviewed Mac pin and remove only enumerated phone-ahead allowances together; do not normalize new drift')
    def test_voice_post_marker_matches_mac_and_only_final_voice_boundary_applies_it(self):
        self.assertEqual(mac_bytes('VoicePost.swift'), (PHONE/'VoicePost.swift').read_bytes())
        mac, phone = self.source('Controller')
        for source in [mac, phone]:
            post = block(source, r'func post\(')
            send = block(post, r'func send\(')
            self.assertEqual(source.count('VoicePost.transportText('), 1)
            self.assertEqual(send.count('VoicePost.transportText(text)'), 1)
            for call in ['try await send(nil)', 'try await send(d)', 'try await send(nil, admit: true)']:
                self.assertIn(call, post)
            self.assertIn('\\(text)', post)  # local logs remain raw
        # Reviewed transport-only adapter difference: Mac has postWithReceipt;
        # phone's lease-bound protocol keeps separate prompt/admit operations.
        phone_send = block(block(phone, r'func post\('), r'func send\(')
        self.assertIn('let transport = VoicePost.transportText(text)', phone_send)
        self.assertIn('backend.admit(target: target, text: transport, reviewText: text)', phone_send)
        self.assertIn('backend.prompt(target: target, text: transport, delivery: delivery, reviewText: text)', phone_send)
        for file in ['Composer', 'TurnTaking', 'Remote']:
            self.assertNotIn('VoicePost.transportText(', (PHONE/(file+'.swift')).read_text())

    def source(self, name):
        return mac_bytes(name+'.swift').decode('utf-8'), (PHONE/(name+'.swift')).read_text()

    def same(self, mac, phone, label):
        self.assertEqual(normalized(mac), normalized(phone), label + ': Mac-owned behaviour drifted; review an explicit exception, do not refresh a snapshot')

    def test_noise_floor_and_composer_are_byte_identical(self):
        for name in ['NoiseFloor', 'Composer']:
            with self.subTest(file=name):
                self.assertEqual(mac_bytes(name+'.swift'), (PHONE/(name+'.swift')).read_bytes())

    def test_voice_and_composer_defaults_and_settings_parsing(self):
        mac, phone = self.source('Settings')
        for name in ['VoiceConfig', 'AppSettings']:
            mac_body = block(mac, r'public struct '+name+r'\b')
            if name == 'AppSettings': mac_body = without_mac_assistant_name_ui(mac_body)
            self.same(mac_body, block(phone, r'public struct '+name+r'\b'), name)
        mac_parser = normalized(block(mac, r'func parseApp\('))
        # Exact UI statement only: extra voice/timing statements on that line are NOT swallowed.
        mac_parser = mac_parser.replace(normalized('if let v = stored["assistantName"] as? String { app.assistantName = AppSettings.normalizedAssistantName(v) }'), '')
        self.same(mac_parser, block(phone, r'func parseApp\('), 'composer timing/settings parser')
        # Phone intentionally does not inherit agent-voice; both still assign the
        # accepted app pause before applying persisted app overrides.
        for source in [mac, phone]:
            loader = block(source, r'func load\(env:')
            self.assertLess(loader.index('voice.pauseMs = AppSettings.defaultPauseMs'), loader.rindex('voice.apply(stored)'))

    def test_vad_noise_math_window_preroll_and_live_word_timing(self):
        mac, phone = self.source('TurnTaking')
        for function in ['rms', 'sustain', 'noteLive']:
            body = block(phone, r'func '+function+r'\(')
            self.same(block(mac, r'func '+function+r'\('), body, function)
        for constant in ['frameBytes', 'prerollFrames', 'silenceCueFrames', 'silenceCueMs', 'onsetWindow', 'onsetVoiced', 'noisyCueFrames', 'resumeGraceFrames', 'calibrationOnsetLevel', 'noWordsFrames']:
            pattern = r'(?:static let '+constant+r'\s*=)[^\n]+'
            self.same(re.search(pattern, mac)[0], re.search(pattern, phone)[0], constant)
        self.same(region(mac, 'public var threshold:', '// Live words'), region(phone, 'public var threshold:', '// Live words'), 'adaptive threshold')
        pattern = r'let isVoiced = [^\n]+'
        self.same(re.search(pattern, mac)[0], re.search(pattern, phone)[0], 'VAD decision')
        onset_mac = region(mac, 'preroll.append(frame)', 'spoken = voiced')
        onset_phone = region(phone, 'preroll.append(frame)', 'spoken = voiced').replace('diagnosticStart = Date()', '')
        self.same(onset_mac, onset_phone, 'one-second pre-roll/windowed onset (only diagnostic timestamp allowed)')

    def test_endpoint_rule_and_all_pause_clocks(self):
        mac, phone = self.source('TurnTaking')
        mac_end = region(mac, 'let wasSilent = silent', '\n        }\n    }')
        phone_end = region(phone, 'let wasSilent = silent', '\n        }\n    }')
        self.same(mac_end, phone_end, 'energy/words-stopped/resume-grace/no-words endpoint')
        self.assertIn('public static let segmentFrameLimit = 4_500', phone)
        for source in [mac, phone]: self.assertRegex(source, r'finalTimeout:\s*TimeInterval\s*=\s*8\b')
        manual_mac = block(mac, r'func endNow\(')
        manual_phone = block(phone, r'func endNow\(')
        self.same(manual_mac, manual_phone, 'tap-to-send')

    def test_duplex_barge_admission_and_half_duplex_semantics(self):
        mac, phone = self.source('Controller')
        admitted = block(phone, r'private func bargeIn\(trigger:')
        admitted = admitted.replace('VoiceTrace.shared.event("barge.trigger", ["trigger": trigger])', '')
        # Measurement-only callback; does not participate in admission or timing.
        self.assertIn('onEchoActivity?(true)', admitted)
        admitted = admitted.replace('onEchoActivity?(true)', '')
        self.same(block(mac, r'private func bargeIn\(trigger:'), admitted, 'duplex barge admission; no text/energy gates')
        # Full onset body, not merely the presence of an onset-grace substring.
        onset = block(phone, r'private func onset\(')
        for addition in [
            'VoiceTrace.shared.event("voiceprobe.onset")',
            'onEchoActivity?(false)',
            'utteranceLease = currentLease', 'utteranceBusy = status.busy',
            'if draftLease == nil, let target = currentLease { bindDraft(target, busy: status.busy) }',
        ]:
            self.assertIn(addition, onset)
            onset = onset.replace(addition, '')
        # Single reviewed admission difference: the phone does not arm a barge-in
        # on an unsafe route. No other onset behaviour is allowlisted.
        self.assertIn('bargeArmed = !halfDuplex && now() - liveAt >= voice.onsetGraceMs', onset)
        onset = onset.replace('bargeArmed = !halfDuplex &&', 'bargeArmed =')
        self.same(block(mac, r'private func onset\('), onset, 'entire onset body')

        transcript = block(phone, r'callbacks\.transcript\s*=')
        for addition in [
            'guard let target = self.utteranceLease else { return }',
            'guard target == self.currentLease else { self.quarantine(text, target: target); return }',
            'self.bindDraft(target, busy: self.utteranceBusy)',
            'if !self.voice.bargeInAborts { self.bargeIn(trigger: "final transcript") }',
        ]:
            self.assertIn(addition, transcript)
            transcript = transcript.replace(addition, '')
        mac_transcript = block(mac, r'callbacks\.transcript\s*=')
        self.same(mac_transcript, transcript, 'entire transcript callback; final-only barge disabled when aborts is enabled')
        expression = 'halfDuplex = !voice.duplex || !input.duplexSafe'
        self.assertIn(expression, mac); self.assertIn(expression, phone)
        for source in [mac, phone]:
            self.assertIn('guard bargeArmed, !halfDuplex else { return }', source)
            self.assertIn('now() - liveAt >= voice.onsetGraceMs', source)
        # Deliberate phone-only safety extension: live route updates, speaker tail
        # and explicit manual cut-in. Rendering itself must always mute on half duplex.
        self.assertIn('halfDuplex && (speaker.playing || now() < playbackQuietUntil)', phone)
        self.assertIn('self.halfDuplex && self.speaker.playing', mac)
        for name in ['pauseMs', 'sensitivity']:
            pattern = r'case \.'+name+r'\([^\n]+'
            self.same(re.findall(pattern, mac)[-1], re.findall(pattern, phone)[-1], 'live setting '+name)

    def test_ambient_learning_changes_are_exactly_render_exclusions(self):
        mac, phone = self.source('TurnTaking')
        self.assertIn('floor.add(rms, inUtterance: recognition != nil, learnNoise: noisyFlag)', mac)
        self.assertIn('if !rendering && !guardFrame { floor.add(rms, inUtterance: recognition != nil, learnNoise: noisyFlag) }', phone)
        self.assertIn('if !rendering { utteranceRMS.append(rms) }', phone)
        self.assertIn('if !utteranceRMS.isEmpty { floor.learn(level: NoiseFloor.lowPercentile(utteranceRMS)) }', phone)
        # All math is byte-gated in NoiseFloor; this exception only excludes
        # playback-origin samples, including deferred learning after playback ends.
        self.assertNotIn('playbackThreshold', phone)
        self.assertNotIn('acceptText', phone)

    def test_speaker_queue_contract_has_no_text_echo_filter(self):
        mac, phone = self.source('Speaker')
        self.same(block(mac, r'public extension AudioInput\b'), block(phone, r'public extension AudioInput\b'), 'AudioInput duplex fallback contract')
        self.assertNotIn('EchoGuard', phone)
        self.assertNotIn('novelPlaybackWords', (PHONE/'Controller.swift').read_text())

    def test_gate_rejects_a_changed_onset_body(self):
        mac, phone = self.source('Controller')
        mutated = phone.replace('status.hearing = true', 'status.hearing = false', 1)
        self.assertNotEqual(mutated, phone)
        gate = MacVoiceParityTests('test_duplex_barge_admission_and_half_duplex_semantics')
        gate.source = lambda _: (mac, mutated)
        with self.assertRaises(AssertionError): gate.test_duplex_barge_admission_and_half_duplex_semantics()

    def test_discard_retires_recognition_generation_and_all_pending_pcm(self):
        mac, phone = self.source('TurnTaking')
        phone_discard = block(phone, r'public func discard\(')
        # Phone-only route/manual-cut-in and discontinuity review state. The shared
        # epoch, final watchdog, counters, cancellation ordering and PCM resets remain strict.
        for addition in ['manualGuard = nil']:
            self.assertIn(addition, phone_discard)
            phone_discard = phone_discard.replace(addition, '')
        self.same(block(mac, r'public func discard\('), phone_discard, 'entire discard recognition/reset body')
        for source in [mac, phone]:
            self.assertIn('epoch += 1', block(source, r'public func discard\('))
            self.assertIn('let generation = epoch', source)
            cbs = region(source, 'let cbs = RecognitionCallbacks(', 'session = makeRecognition(cbs)')
            for callback in ['partial', 'error', 'done', 'live']:
                self.assertIn('self.epoch == generation', block(cbs, callback + r': \{'))
        mac_controller, phone_controller = self.source('Controller')
        self.same(block(mac_controller, r'private func refreshPendingSpeech\('),
                  block(phone_controller, r'private func refreshPendingSpeech\('), 'pending speech visibility rule')

    def test_discard_pending_controller_is_a_strict_port(self):
        mac, phone = self.source('Controller')
        for source in [mac, phone]: self.assertIn('public func discardPending()', source)
        body = block(phone, r'public func discardPending\(')
        # Phone-only immutable draft ownership, visible send countdown and closed stage metadata.
        # No send policy, conditional, epoch, callback or shared reset is normalized away.
        for addition in [
            'let hadCountdown = status.sendCountdown != nil',
            'let held = !composer.held.isEmpty || !deferredPosts.isEmpty',
            'let live = turnTaker?.inUtterance == true',
            'draftLease = nil; draftBusy = nil; utteranceLease = nil',
            'status.sendCountdown = nil',
            'StageDiagnostics.shared.record(.discard, .complete, audio: CaptureSnapshot([\n            .discardCountdown: hadCountdown ? 1 : 0, .discardHeld: held ? 1 : 0, .discardLive: live ? 1 : 0]))',
        ]:
            self.assertIn(addition, body)
            body = body.replace(addition, '')
        self.same(block(mac, r'public func discardPending\('), body, 'entire unsent-only discard operation')

    def test_discard_gate_rejects_cancelling_playback_or_skipping_composer_reset(self):
        mac, phone = self.source('Controller')
        for bad in ['speaker.stop()', 'composer.speechIdle()']:
            start = phone.index('public func discardPending()')
            mutated = phone[:start] + phone[start:].replace('composer.reset()', bad, 1)
            self.assertNotEqual(mutated, phone)
            gate = MacVoiceParityTests('test_discard_pending_controller_is_a_strict_port')
            gate.source = lambda _: (mac, mutated)
            with self.assertRaises(AssertionError): gate.test_discard_pending_controller_is_a_strict_port()

    def test_shared_capture_fence_and_discard_confirmation(self):
        mac, phone = self.source('Speaker')
        self.same(block(mac, r'public final class CaptureEpoch\b'), block(phone, r'public final class CaptureEpoch\b'), 'thread-safe capture epoch')
        mac, phone = self.source('Pill')
        self.same(region(mac, 'case .youStarted:', 'case .youSpeaking:'),
                  region(phone, 'case .youStarted:', 'case .youSpeaking:'), 'new onset clears confirmation')
        self.same(region(mac, 'case .discarded:', 'case .youLive('),
                  region(phone, 'case .discarded:', 'case .youLive('), 'privacy-safe discard confirmation and app-only announcement')
        for name in ['startThoughtIfSent', 'clearDiscardConfirmation']:
            self.same(block(mac, r'private func '+name+r'\('), block(phone, r'private func '+name+r'\('), name)
        for source in [mac, phone]:
            self.assertIn('if let until = discardedUntil, t >= until { clearDiscardConfirmation() }', block(source, r'public func tick\('))
        mac, phone = self.source('Controller')
        self.same(region(controller_start_body(mac), 'status.running = true', 'status.phase = "starting"'),
                  region(controller_start_body(phone), 'status.running = true', 'status.phase = "starting"'), 'retained thought eligibility throughout startup')

    def test_start_wrapper_still_rejects_changed_startup_eligibility(self):
        mac, phone = self.source('Controller')
        body = controller_start_body(mac)
        changed = body.replace('refreshPendingSpeech()', '', 1)
        self.assertNotEqual(body, changed)
        gate = MacVoiceParityTests('test_shared_capture_fence_and_discard_confirmation')
        original = gate.source
        gate.source = lambda name: (mac.replace(body, changed, 1), phone) if name == 'Controller' else original(name)
        with self.assertRaises(AssertionError):
            gate.test_shared_capture_fence_and_discard_confirmation()

    def test_start_wrapper_reader_rejects_a_different_forwarding_mode(self):
        source = 'public func start() async { await start(preservingLogicalSession: true) }'
        with self.assertRaises(AssertionError):
            controller_start_body(source)

    def test_gate_rejects_discard_without_generation_invalidation(self):
        mac, phone = self.source('TurnTaking')
        mutated = phone.replace('public func discard() {\n        epoch += 1', 'public func discard() {\n        epoch += 0', 1)
        self.assertNotEqual(mutated, phone)
        gate = MacVoiceParityTests('test_discard_retires_recognition_generation_and_all_pending_pcm')
        original = gate.source
        gate.source = lambda name: (mac, mutated) if name == 'TurnTaking' else original(name)
        with self.assertRaises(AssertionError): gate.test_discard_retires_recognition_generation_and_all_pending_pcm()

    def test_gate_rejects_a_changed_transcript_callback(self):
        mac, phone = self.source('Controller')
        mutated = phone.replace('self.composer.utterance(text)', 'self.composer.utterance("changed")', 1)
        self.assertNotEqual(mutated, phone)
        gate = MacVoiceParityTests('test_duplex_barge_admission_and_half_duplex_semantics')
        gate.source = lambda _: (mac, mutated)
        with self.assertRaises(AssertionError): gate.test_duplex_barge_admission_and_half_duplex_semantics()

    def test_shared_long_thought_rejects_pause_noise_or_rollover_drift(self):
        mac, phone = self.source('TurnTaking')
        for old, new in [('max(silentMs, stalledMs)', 'silentMs'),
                         ('frames >= Self.noWordsFrames', 'frames >= 1'),
                         ('segmentRollovers == 0 || segmentHasLiveWords', 'true'),
                         ('segmentFrameLimit = 4_500', 'segmentFrameLimit = 9_000')]:
            changed = phone.replace(old, new, 1)
            self.assertNotEqual(changed, phone)
            gate = MacVoiceParityTests('test_endpoint_rule_and_all_pause_clocks')
            gate.source = lambda _: (mac, changed)
            with self.assertRaises(AssertionError): gate.test_endpoint_rule_and_all_pause_clocks()

    def test_ui_name_allowlist_does_not_hide_voice_defaults_or_parser_drift(self):
        mac, phone = self.source('Settings')
        for changed in [phone.replace('turnEndQuietMs = 2000.0', 'turnEndQuietMs = 1900.0', 1),
                        phone.replace('stored["turnEndQuietMs"]', 'stored["wrongQuietKey"]', 1)]:
            self.assertNotEqual(changed, phone)
            gate = MacVoiceParityTests('test_voice_and_composer_defaults_and_settings_parsing')
            gate.source = lambda _: (mac, changed)
            with self.assertRaises(AssertionError): gate.test_voice_and_composer_defaults_and_settings_parsing()

    def test_mac_ui_name_allowlist_is_not_a_phone_name_setting_allowlist(self):
        mac, phone = self.source('Settings')
        changed = phone.replace('public struct AppSettings: Sendable {', 'public struct AppSettings: Sendable {\npublic var assistantName = ""', 1)
        self.assertNotEqual(changed, phone)
        gate = MacVoiceParityTests('test_voice_and_composer_defaults_and_settings_parsing')
        gate.source = lambda _: (mac, changed)
        with self.assertRaises(AssertionError): gate.test_voice_and_composer_defaults_and_settings_parsing()


if __name__ == '__main__': unittest.main()
