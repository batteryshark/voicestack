import Foundation
import Testing
@testable import FloatingVoiceCore

@Suite(.serialized) @MainActor struct DiscardTests {
    /// Confirmation is emitted only by a successful core discard, never by a stale button tap.
    private func discard(_ controller: ConversationController) -> Bool {
        var confirmed = false
        let previous = controller.onCaption
        controller.onCaption = { event in
            if case .discarded("") = event { confirmed = true }
            previous?(event)
        }
        controller.discardPending()
        controller.onCaption = previous
        return confirmed
    }
    @Test func activeBeforeWordsAndLateCallbacksAreDiscardedAndListeningContinues() async throws {
        let rig = Rig(); await rig.start(); defer { rig.controller.stop() }
        var captions: [CaptionEvent] = []
        rig.controller.onCaption = { captions.append($0) }
        rig.input.frames(30, voiced: true)
        let old = try #require(rig.recognitions.first)
        #expect(rig.controller.status.canDiscard)
        #expect(discard(rig.controller))
        #expect(old.cancelled && !rig.controller.status.canDiscard && rig.controller.status.running && !rig.controller.status.micMuted)
        old.callbacks.live("private interruption"); old.callbacks.partial("old partial"); old.callbacks.done("old final.")
        #expect(!captions.contains { if case .youLive = $0 { return true }; return false })
        #expect(!captions.contains { if case .youFinal = $0 { return true }; return false })
        rig.transcript = "A fresh thought."; rig.speak()
        #expect(await waitUntil { rig.backend.prompts.count == 1 })
        #expect(rig.backend.prompts.map(\.text) == ["[voice] A fresh thought."])
    }
    @Test func liveWordsAndAwaitingFinalCannotResurrectAfterDiscard() async throws {
        let rig = Rig(); rig.silentEnd = true; await rig.start(); defer { rig.controller.stop() }
        rig.input.frames(30, voiced: true)
        let old = try #require(rig.recognitions.first)
        old.callbacks.live("words to abandon")
        rig.controller.turnTaker?.finalTimeout = 0.03
        rig.controller.turnTaker?.endNow()
        #expect(rig.controller.status.canDiscard && old.ended)
        #expect(discard(rig.controller))
        old.callbacks.done("Must never send.")
        try await Task.sleep(nanoseconds: 70_000_000)
        #expect(rig.backend.prompts.isEmpty && rig.controller.draftsForReview.isEmpty && rig.controller.status.lastError == nil)
        #expect(!rig.controller.status.canDiscard)
    }
    @Test(arguments: [false, true]) func heldAndCountdownAreCancelled(_ manual: Bool) async throws {
        let rig = Rig(holdMs: 70); await rig.start(); defer { rig.controller.stop() }
        if manual { rig.controller.setSendMode(.manual) }
        rig.controller.composer.utterance("Unsent fragment")
        #expect(rig.controller.status.canDiscard)
        if !manual { #expect(rig.controller.status.sendCountdown != nil) }
        #expect(discard(rig.controller))
        #expect(rig.controller.composer.held.isEmpty && rig.controller.status.sendCountdown == nil)
        try await Task.sleep(nanoseconds: 110_000_000)
        #expect(rig.backend.prompts.isEmpty && !rig.controller.status.canDiscard && rig.controller.status.running)
    }
    @Test func locallyDeferredManualSendLosesToDiscardBeforeBackendIssue() async {
        let rig = Rig(); await rig.start(); defer { rig.controller.stop() }
        rig.controller.setSendMode(.manual)
        rig.controller.composer.utterance("Not issued yet.")
        rig.controller.send()
        #expect(rig.controller.status.canDiscard)
        #expect(discard(rig.controller))
        #expect(await rig.controller.waitForPosts(timeout: 1))
        #expect(rig.backend.prompts.isEmpty && rig.controller.draftsForReview.isEmpty)
    }
    @Test func manualSendAwaitingFinalIsInvalidatedBeforeLateFinal() async throws {
        let rig = Rig(); rig.silentEnd = true; await rig.start(); defer { rig.controller.stop() }
        rig.controller.setSendMode(.manual)
        rig.input.frames(30, voiced: true)
        let old = try #require(rig.recognitions.first)
        rig.controller.send()
        #expect(old.ended && rig.controller.status.pendingSpeech)
        #expect(discard(rig.controller))
        old.callbacks.done("Retired final after Send.")
        rig.silentEnd = false; rig.transcript = "New manual thought."
        rig.speak()
        #expect(await waitUntil { rig.controller.status.holding == "New manual thought." })
        rig.controller.send()
        #expect(await waitUntil { rig.backend.prompts.count == 1 })
        #expect(rig.backend.prompts.map(\.text) == ["[voice] New manual thought."])
    }
    @Test func retiredCountdownCannotFlushANewerThought() async throws {
        let rig = Rig(holdMs: 60); await rig.start(); defer { rig.controller.stop() }
        rig.controller.composer.utterance("Old held thought")
        #expect(discard(rig.controller))
        rig.controller.app.holdMidSentenceMs = 250
        rig.controller.composer.utterance("New held thought")
        try await Task.sleep(nanoseconds: 120_000_000)
        #expect(rig.backend.prompts.isEmpty && rig.controller.status.holding == "New held thought")
        #expect(await waitUntil { rig.backend.prompts.count == 1 })
        #expect(rig.backend.prompts.map(\.text) == ["[voice] New held thought"])
    }
    @Test func issuedPromptWinsEvenWhileAcknowledgementIsPending() async {
        let rig = Rig(); await rig.start(); defer { rig.controller.stop() }
        rig.backend.promptDelay = 0.15
        rig.controller.composer.utterance("Already issued.")
        #expect(await waitUntil { rig.controller.status.sending })
        #expect(!rig.controller.status.canDiscard && !discard(rig.controller))
        #expect(await rig.controller.waitForPosts(timeout: 1))
        #expect(rig.backend.prompts.map(\.text) == ["[voice] Already issued."] && rig.backend.interrupts.isEmpty)
    }
    @Test func committedThoughtDoesNotPreventDiscardingDistinctNewSpeech() async {
        let rig = Rig(); await rig.start(); defer { rig.controller.stop() }
        rig.backend.promptDelay = 0.15
        rig.controller.composer.utterance("Committed thought.")
        #expect(await waitUntil { rig.controller.status.sending })
        rig.controller.setSendMode(.manual)
        rig.controller.composer.utterance("A different unsent thought")
        #expect(rig.controller.status.pendingSpeech && discard(rig.controller))
        #expect(await rig.controller.waitForPosts(timeout: 1))
        #expect(rig.backend.prompts.map(\.text) == ["[voice] Committed thought."])
        #expect(rig.backend.admits.isEmpty && rig.backend.interrupts.isEmpty && rig.controller.status.running)
    }
    @Test(arguments: [false, true]) func muteAndDiscardRaceNeverSendsRetiredFinal(_ muteFirst: Bool) async throws {
        let rig = Rig(); rig.silentEnd = true; await rig.start(); defer { rig.controller.stop() }
        rig.input.frames(30, voiced: true)
        let old = try #require(rig.recognitions.first)
        old.callbacks.live("Unsent speech")
        if muteFirst { rig.controller.setMicMuted(true) }
        #expect(discard(rig.controller))
        if !muteFirst { rig.controller.setMicMuted(true) }
        old.callbacks.done("This retired final must not send.")
        await Task.yield()
        #expect(rig.controller.status.micMuted && rig.backend.prompts.isEmpty && !rig.controller.status.canDiscard)
        rig.input.frames(40, voiced: true)
        #expect(rig.recognitions.count == 1)
    }
    @Test func busyHeldAndReviewDraftsAreIndependent() async {
        let rig = Rig(quietMs: 80); await rig.start(); defer { rig.controller.stop() }
        rig.controller.setSendMode(.manual); rig.controller.composer.utterance("Earlier review draft")
        rig.controller.setTargetSetting("ses_B")
        #expect(await waitUntil { rig.controller.currentLease?.sessionID == "ses_B" })
        let review = rig.controller.draftsForReview
        #expect(!review.isEmpty)
        rig.controller.setSendMode(.auto)
        rig.backend.send("session.execution.started", "ses_B")
        #expect(await waitUntil { rig.controller.status.busy })
        rig.controller.composer.utterance("New unsent busy fragment")
        #expect(discard(rig.controller))
        rig.backend.send("session.execution.succeeded", "ses_B")
        try? await Task.sleep(nanoseconds: 120_000_000)
        #expect(rig.backend.prompts.isEmpty && rig.controller.draftsForReview == review && rig.backend.interrupts.isEmpty)
    }
    @Test func noOldPrerollSurvivesIntoNextRecognition() async throws {
        let rig = Rig(); rig.recordRecognitionPCM = true; await rig.start(); defer { rig.controller.stop() }
        rig.input.frames(45, voiced: false); rig.input.frames(30, voiced: true)
        #expect(discard(rig.controller))
        // No fresh quiet/preroll: a new onset must contain new frames only.
        rig.input.frames(20, voiced: true)
        let fresh = try #require(rig.recognitions.last?.recordedPCM)
        #expect(rig.recognitions.count == 2 && fresh.allSatisfy { $0 == FakeInput.tone })
        #expect(rig.input.speechDiscards == 1)
    }
    @Test func discardDuringCallLeavesCallAndPlaybackAlone() async throws {
        let rig = Rig(duration: 0.5)
        let call = CallCoordinatorRig()
        call.begin = { await rig.start(); return true }
        let provider = await call.active()
        defer { rig.controller.stop(); call.cleanup(provider) }
        rig.controller.setSendMode(.manual); rig.controller.composer.utterance("Unsent call fragment")
        rig.reply(id: "chief", one)
        #expect(await waitUntil { !rig.output.plays.isEmpty })
        let stops = rig.output.stops, state = call.calls.lifecycle.state
        #expect(discard(rig.controller))
        #expect(call.calls.lifecycle.state == state && call.ends == 0 && provider.endedCount == 0)
        #expect(rig.output.stops == stops && rig.backend.interrupts.isEmpty && rig.controller.status.running)
    }
    @Test func halfDuplexAndMutedOrOffStateArePreserved() async {
        let rig = Rig(duration: 0.2); rig.input.duplexSafe = false
        await rig.start(); defer { rig.controller.stop() }
        rig.controller.setSendMode(.manual); rig.controller.composer.utterance("Held before playback")
        rig.reply(id: "chief", one)
        #expect(await waitUntil { rig.controller.status.speaking })
        let stops = rig.output.stops
        #expect(discard(rig.controller))
        #expect(rig.controller.status.halfDuplex && rig.controller.status.listeningSuppressed && rig.output.stops == stops)
        rig.controller.setMicMuted(true)
        rig.controller.composer.utterance("Muted held fragment")
        #expect(discard(rig.controller) && rig.controller.status.micMuted)
        rig.controller.stop()
        #expect(!discard(rig.controller) && !rig.controller.status.running)
    }
    @Test func confirmationContainsNoOldTextAndCannotEraseNewCaptions() {
        var clock = 0.0
        let surface = VoiceSurface(now: { clock }, pill: PillModel(now: { clock }))
        let owner = surface.replaceBinding(target: TargetLease(sessionID: "ses_A", generation: "one"))
        surface.handle(.youLive("Private old words"), owner: owner)
        surface.handle(.discarded(""), owner: owner)
        #expect(surface.discardConfirmation && surface.log.turns.isEmpty && surface.pill.you.text == "Discarded")
        clock = 500
        surface.handle(.youStarted, owner: owner); surface.handle(.youLive("A new thought"), owner: owner)
        clock = 2000; surface.tick()
        #expect(!surface.discardConfirmation && surface.pill.you.text == "A new thought")
        #expect(surface.log.turns.last?.spoken == "A new thought")
    }
    @Test func coldBufferedCaptureCanBeDiscardedBeforeOrAfterHealthResolves() async throws {
        let backend = FakeBackend(), input = FakeInput(), warmup = SpeechWarmup()
        var settings = LoadedSettings(app: AppSettings(), voice: VoiceConfig(), voiceFile: nil, appFile: "/nonexistent", chiefFile: "/nonexistent")
        settings.app.target = "ses_A"
        var opened: [FakeRecognition] = []
        let controller = ConversationController(settings: settings, backend: backend, synth: FakeSynth(), output: FakeOutput(), input: input,
            makeRecognition: { cbs in
                HealthCheckedRecognition(endpoint: "ws://fixture/x", key: nil, callbacks: cbs, warmup: warmup, probe: { _, _ in
                    try? await Task.sleep(nanoseconds: 60_000_000); return .unloaded
                }) { let rec = FakeRecognition($0, transcript: "Unsent cold speech."); opened.append(rec); return rec }
            }, speechWarmup: warmup)
        await controller.start(); defer { controller.stop() }
        #expect(await waitUntil { controller.status.phase == "ready" && controller.currentLease != nil })
        input.frames(30, voiced: true)
        #expect(controller.status.canDiscard && discard(controller))
        try await Task.sleep(nanoseconds: 90_000_000)
        #expect(opened.isEmpty && backend.prompts.isEmpty)
        input.frames(30, voiced: true)
        #expect(await waitUntil { controller.status.warmingSpeech })
        #expect(discard(controller))
        #expect(!controller.status.warmingSpeech && controller.status.running && !controller.status.micMuted)
        opened.last?.callbacks.done("A retired cold final.")
        #expect(backend.prompts.isEmpty)
    }
    @Test func discardDiagnosticsAreClosedAndPrivacySafe() async throws {
        let rig = Rig(); await rig.start(); defer { rig.controller.stop() }
        rig.controller.composer.utterance("Private daughter interruption")
        #expect(discard(rig.controller))
        let entries = try JSONDecoder().decode([DiagnosticEntry].self, from: Data(StageDiagnostics.shared.export().utf8))
        let event = try #require(entries.last { $0.stage == .discard })
        #expect(event.audio?.values["discardHeld"] == 1 && event.audio?.values["discardCountdown"] == 1)
        let encoded = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
        #expect(!encoded.contains("Private") && !encoded.contains("daughter"))
    }
    @Test(arguments: [SettingChange.inputDevice("fixture"), .echoCancellation("off")])
    func retainedManualThoughtIsDiscardableThroughoutDeviceAndEchoRestarts(_ change: SettingChange) async throws {
        let rig = Rig(appFile: tempDir() + "/settings.json")
        await rig.start(); defer { rig.controller.stop() }
        rig.controller.setSendMode(.manual)
        rig.controller.composer.utterance("Retained manual thought")
        var pendingDuringStart = false
        rig.controller.onStatus = { status in
            if status.running && status.phase == "starting" && status.pendingSpeech && status.holding == "Retained manual thought" { pendingDuringStart = true }
        }
        try await rig.controller.apply(change)
        #expect(pendingDuringStart && rig.controller.status.pendingSpeech && rig.controller.status.running)
        #expect(discard(rig.controller) && rig.controller.composer.held.isEmpty && rig.backend.prompts.isEmpty)
    }
    @Test(arguments: [false, true]) func directKeepHeldRestartAndOffDiscardNeverStartVoice(_ hasInput: Bool) async {
        let backend = FakeBackend(), input = FakeInput()
        var settings = LoadedSettings(app: AppSettings(), voice: VoiceConfig(), voiceFile: nil, appFile: "/nonexistent", chiefFile: "/nonexistent")
        settings.app.target = "ses_A"; settings.app.sendMode = .manual
        let controller = ConversationController(settings: settings, backend: backend, synth: FakeSynth(), output: FakeOutput(), input: hasInput ? input : nil)
        await controller.start(); defer { controller.stop() }
        #expect(await waitUntil { controller.status.phase == "ready" })
        controller.composer.utterance("Direct retained thought")
        controller.stop(keepHeld: true)
        #expect(!controller.status.running && controller.status.pendingSpeech)
        var eligibleDuringStart = false
        controller.onStatus = { if $0.running && $0.phase == "starting" && $0.pendingSpeech && $0.holding == "Direct retained thought" { eligibleDuringStart = true } }
        await controller.start()
        #expect(eligibleDuringStart && controller.status.pendingSpeech)
        controller.stop(keepHeld: true)
        let starts = input.starts
        #expect(discard(controller))
        #expect(!controller.status.running && !controller.status.pendingSpeech && input.starts == starts && backend.prompts.isEmpty)
    }
    @Test(arguments: [0, 1, 2]) func sharedPillConfirmationIsPrivateAndNeverErasesNewerEvents(_ next: Int) {
        var clock = 0.0, announcements = 0
        let pill = PillModel(now: { clock })
        pill.onDiscardAnnouncement = { announcements += 1 }
        pill.handle(.discarded("Private discarded transcript"))
        #expect(pill.you.text == "Discarded" && announcements == 1)
        #expect(!pill.history.contains { $0.1.contains("Private discarded") })
        clock = 500
        if next == 0 { pill.handle(.youStarted) }
        else if next == 1 { pill.handle(.youLive("New words")) }
        else { pill.handle(.youFinal("New words")) }
        clock = 2000; pill.tick()
        #expect(!pill.you.discarded && announcements == 1)
        #expect(pill.you.text == (next == 0 ? "" : "New words"))
    }
}
