import Foundation
import Testing
@testable import FloatingVoiceCore

/// The wait before sending: no stacked holds, a countdown cue, "Sent", "Chief is thinking…"; the mic level log reads
/// real chunks; the session the pill attaches to (explicit, chief.json, then the latest "Chief of staff").
@Suite(.serialized) @MainActor struct WaitCueTests {
    func say(_ rig: Rig, _ text: String) async {
        rig.transcript = text
        rig.input.frames(30, voiced: true)
        rig.input.frames(Int(rig.controller.voice.pauseMs / 20) + 5, voiced: false) // the whole pause, so the utterance ends
        try? await Task.sleep(nanoseconds: 30_000_000)
    }

    // MARK: 1. No stacking: the mid-sentence hold only applies below 2.5 s of pause

    @Test func patientPauseSendsAtOnceEvenMidSentence() async {
        let rig = Rig(holdMs: 5_000) { $0.pauseMs = 3200 }
        await rig.start()
        await say(rig, "So what I was thinking about the mock-up and")
        #expect(await waitUntil(0.5) { rig.backend.prompts.count == 1 }, "no extra hold on top of the 3.2 s pause")
        #expect(rig.backend.prompts.first?.text == "[voice] So what I was thinking about the mock-up and")
        #expect(rig.controller.status.holding == nil)
        rig.controller.stop()
    }

    @Test func shortPauseStillHoldsMidSentence() async {
        let rig = Rig(holdMs: 400) { $0.pauseMs = 1500 }
        await rig.start()
        await say(rig, "So what I was thinking about the mock-up and")
        try? await Task.sleep(nanoseconds: 150_000_000)
        #expect(rig.backend.prompts.isEmpty && rig.controller.status.holding != nil)
        #expect(await waitUntil(1.5) { rig.backend.prompts.count == 1 })
        rig.controller.stop()
    }

    @Test func holdThresholdIsExactlyTwoAndAHalfSeconds() async {
        for (pause, holds) in [(2400.0, true), (2500.0, false)] {
            let rig = Rig(holdMs: 5_000) { $0.pauseMs = pause }
            await rig.start()
            await say(rig, "and then the")
            try? await Task.sleep(nanoseconds: 100_000_000)
            #expect(rig.backend.prompts.isEmpty == holds, "pauseMs \(pause)")
            rig.controller.stop()
        }
    }

    // MARK: 2. The countdown cue

    @Test func silenceCueStartsAfterHalfASecondAndCancelsOnSpeech() {
        var events: [Double?] = []
        var cb = TurnCallbacks()
        cb.silence = { events.append($0) }
        var config = VoiceConfig()
        config.pauseMs = 3200
        let t = TurnTaker(config: config, callbacks: cb) { FakeRecognition($0, transcript: "x") }
        let mic = FakeInput()
        mic.onPCM = { t.push($0) }
        mic.frames(20, voiced: true)
        mic.frames(24, voiced: false)
        #expect(events.isEmpty, "a gap under 500 ms is just a pause between words")
        mic.frames(1, voiced: false)
        #expect(events == [500])
        mic.frames(30, voiced: false)
        mic.frames(1, voiced: true)
        #expect(events == [500, nil], "new speech cancels the countdown")
        mic.frames(3, voiced: true); mic.frames(2, voiced: false); mic.frames(1, voiced: true)
        #expect(events == [500, nil], "brief gaps do not start a cue")
    }

    @Test func countdownCountsThreeTwoOneThenSendingThenSent() {
        let r = PillRig()
        r.pill.handle(.youSpeaking)
        r.pill.handle(.youFinal("Check the build."))
        // Silence reached 500 ms of a 3200 ms pause: 2700 ms left.
        r.pill.handle(.countdown(totalMs: 3200, elapsedMs: 500, hold: false))
        #expect(r.pill.wait == .countdown(seconds: 3, fraction: 0.84))
        r.advance(699)
        #expect(r.pill.wait == .countdown(seconds: 3, fraction: 0.62), "2001 ms left")
        r.advance(1)
        #expect(r.pill.wait == .countdown(seconds: 2, fraction: 0.62))
        r.advance(1000)
        #expect(r.pill.wait == .countdown(seconds: 1, fraction: 0.32), "1000 ms left")
        r.advance(700)
        #expect(r.pill.wait == .countdown(seconds: 1, fraction: 0.1), "300 ms left: still shows 1")
        r.advance(300)
        #expect(r.pill.wait == .sending)
        #expect(r.pill.history.map(\.1).filter { $0.hasPrefix("countdown") } == ["countdown 3", "countdown 2", "countdown 1"])
        #expect(r.pill.expanded)
        r.set { $0.busy = true }
        r.pill.handle(.posted("Check the build."))
        #expect(r.pill.wait == .sent)
        #expect(r.pill.chief.current == "" && r.pill.expanded)
    }

    @Test func newSpeechOrAFinalCancelsTheCountdown() {
        let r = PillRig()
        r.pill.handle(.countdown(totalMs: 3200, elapsedMs: 500, hold: false))
        r.advance(300)
        #expect(r.pill.wait != .none)
        r.pill.handle(.countdownCancelled) // voice resumed
        #expect(r.pill.wait == .none)
        r.pill.handle(.countdown(totalMs: 3200, elapsedMs: 500, hold: false))
        r.pill.handle(.youFinal("Done."))
        #expect(r.pill.wait == .none, "the final transcript replaces the silence cue")
        // A hold countdown set after the final survives the idle callback that follows it.
        r.pill.handle(.countdown(totalMs: 1500, elapsedMs: 0, hold: true))
        r.pill.handle(.youIdle)
        #expect(r.pill.wait == .countdown(seconds: 2, fraction: 1))
        r.pill.handle(.countdownCancelled)
        #expect(r.pill.wait == .none)
    }

    @Test func sentThenThinkingThenTheChiefsFirstWords() {
        let r = PillRig()
        r.pill.sentMs = 900
        r.set { $0.busy = true }
        r.pill.handle(.posted("Please check the build."))
        #expect(r.pill.wait == .sent)
        r.advance(899)
        #expect(r.pill.wait == .sent)
        r.advance(1)
        #expect(r.pill.wait == .thinking)
        // A subtle animated visualizer in the chief's colour while it thinks.
        r.advance(300)
        #expect(r.pill.voice == .chief && r.pill.levels.last! > 0.05)
        r.advance(10_000)
        #expect(r.pill.wait == .thinking && r.pill.expanded, "the card stays open while the chief works")
        r.pill.handle(.chiefQueued(label: "m:0", text: "The build passed."))
        #expect(r.pill.wait == .none && r.pill.chief.current == "The build passed.")
    }

    @Test func thinkingEndsWhenTheTurnEndsWithoutText() {
        let r = PillRig()
        r.set { $0.busy = true }
        r.pill.handle(.posted("Do the thing."))
        r.advance(1500)
        #expect(r.pill.wait == .thinking)
        r.set { $0.busy = false }
        #expect(r.pill.wait == .none)
    }

    @Test func sentShowsEvenWhenNoTurnStarts() {
        let r = PillRig()
        r.pill.handle(.posted("Added to the thread."))
        #expect(r.pill.wait == .sent)
        r.advance(1000)
        #expect(r.pill.wait == .none, "idle chief: nothing to wait for")
    }

    @Test func controllerEmitsTheCountdownFromRealSilence() async {
        let rig = Rig { $0.pauseMs = 1000 }
        var events: [CaptionEvent] = []
        rig.controller.onCaption = { events.append($0) }
        await rig.start()
        rig.transcript = "Please check the logs."
        rig.input.frames(20, voiced: true)
        rig.input.frames(26, voiced: false)
        #expect(events.contains(.countdown(totalMs: 1000, elapsedMs: 500, hold: false)))
        rig.input.frames(30, voiced: true)
        #expect(events.contains(.countdownCancelled))
        rig.input.frames(60, voiced: false)
        #expect(await waitUntil { rig.backend.prompts.count == 1 })
        #expect(events.contains { if case .posted = $0 { return true } else { return false } })
        rig.controller.stop()
    }

    @Test func manualModeShowsNoCountdown() async {
        let rig = Rig { $0.pauseMs = 1000 }
        rig.controller.setSendMode(.manual)
        var events: [CaptionEvent] = []
        rig.controller.onCaption = { events.append($0) }
        await rig.start()
        rig.input.frames(20, voiced: true)
        rig.input.frames(40, voiced: false)
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(!events.contains { if case .countdown = $0 { return true } else { return false } })
        rig.controller.stop()
    }

    @Test func sendNowDuringTheCountdownSendsImmediately() async {
        let rig = Rig { $0.pauseMs = 3200 }
        await rig.start()
        rig.transcript = "Send this now."
        rig.input.frames(20, voiced: true)
        rig.input.frames(30, voiced: false) // 600 ms into the silence: the cue is showing
        rig.controller.send()
        #expect(await waitUntil(1) { rig.backend.prompts.count == 1 })
        #expect(rig.backend.prompts.first?.text == "[voice] Send this now.")
        rig.controller.stop()
    }

    @Test func holdWaitsAreAnnouncedAndCancelled() async {
        let rig = Rig(holdMs: 400) { $0.pauseMs = 1500 }
        var events: [CaptionEvent] = []
        rig.controller.onCaption = { events.append($0) }
        await rig.start()
        await say(rig, "and then the")
        #expect(events.contains(.countdown(totalMs: 400, elapsedMs: 0, hold: true)))
        rig.input.frames(20, voiced: true) // speaking again cancels it
        #expect(events.contains(.countdownCancelled))
        rig.input.frames(60, voiced: false)
        rig.controller.stop()
    }

    // MARK: 3. Mic level log reads real chunk sizes

    @Test func micStatsCountOddSizedChunks() {
        var s = MicStats()
        // The capture path delivers about 21 ms chunks (341 samples at 16 kHz), never whole 20 ms frames.
        let tone = FakeInput.tone
        var stream = Data()
        for _ in 0..<50 { stream.append(tone) }
        var i = 0
        while i < stream.count {
            let n = min(682, stream.count - i)
            s.add(stream.subdata(in: i..<i + n), threshold: 0.012, playing: false, ignored: false)
            i += n
        }
        #expect(s.frames == 50 && s.voiced == 50)
        #expect(s.line(threshold: 0.012).contains("rms avg 0.17") && s.line(threshold: 0.012).contains("50/50 frames voiced"))
        // Tiny chunks too.
        var t = MicStats()
        for k in 0..<(tone.count / 100) { t.add(tone.subdata(in: k * 100..<(k + 1) * 100), threshold: 0.012, playing: true, ignored: false) }
        t.add(tone.subdata(in: (tone.count / 100) * 100..<tone.count), threshold: 0.012, playing: true, ignored: false)
        #expect(t.frames == 1 && t.duringPlayback == 1)
    }

    @Test func micLogReportsLevelsFromOddChunksThroughTheController() async {
        let rig = Rig(duration: 3.0)
        await rig.start()
        let chunk = FakeInput.tone.prefix(682)
        for _ in 0..<150 { rig.input.onPCM?(Data(chunk)) }
        rig.clock += 1000
        #expect(await waitUntil { rig.lines.contains { $0.hasPrefix("mic: rms avg") } })
        #expect(!rig.lines.contains("mic: no audio in the last second"))
        rig.controller.stop()
    }

    // MARK: 4. The session the pill attaches to

    func summary(_ id: String, _ title: String, _ updated: Double) -> SessionSummary { .init(id: id, title: title, updated: updated) }

    @Test func fallbackPicksTheMostRecentChiefOfStaff() {
        let list = [summary("ses_aaa111", "Chief of staff", 100), summary("ses_bbb222", "chief of staff ", 300),
                    summary("ses_ccc333", "[lead] Floating voice", 900), summary("ses_ddd444", "Chief of staff (old)", 999)]
        #expect(ChiefDiscovery.pick(from: list) == "ses_bbb222")
        #expect(ChiefDiscovery.pick(from: [summary("ses_x", "Other", 1)]) == nil)
        #expect(ChiefDiscovery.pick(from: []) == nil)
        #expect(SessionSummary.shortID("ses_a10001fixture0000000000") == "a10001")
        #expect(summary("ses_a10001fixture0000000000", "Chief of staff", 0).label == "Chief of staff · a10001")
        #expect(summary("ses_a10001fixture0000000000", "", 0).label == "Untitled · a10001")
    }

    @Test func targetOrderExplicitThenChiefFileThenLatestChief() async {
        // 1. chief.json present: it wins over the server's list.
        let rig = Rig()
        rig.backend.sessions = [summary("ses_Z", "Chief of staff", 500)]
        await rig.start()
        #expect(rig.controller.status.target == "ses_A")
        #expect(rig.controller.chiefSource == "chief.json")
        rig.controller.stop()

        // 2. No chief.json: the most recent "Chief of staff" session.
        let rig2 = Rig()
        try? FileManager.default.removeItem(atPath: rig2.chief)
        rig2.backend.sessions = [summary("ses_old", "Chief of staff", 100), summary("ses_new", "Chief of staff", 700), summary("ses_other", "Notes", 900)]
        await rig2.start()
        #expect(await waitUntil { rig2.controller.status.target == "ses_new" })
        #expect(rig2.controller.chiefSource.contains("Chief of staff"))
        #expect(rig2.controller.status.targetLabel?.hasSuffix("· new") == true || rig2.controller.status.targetLabel?.contains("new") == true)
        rig2.controller.stop()

        // 3. An explicit session id beats both.
        let rig3 = Rig(target: "ses_pinned")
        rig3.backend.sessions = [summary("ses_new", "Chief of staff", 700)]
        await rig3.start()
        #expect(rig3.controller.status.target == "ses_pinned")
        rig3.controller.stop()

        // 4. chief.json appearing later is followed.
        let rig4 = Rig()
        try? FileManager.default.removeItem(atPath: rig4.chief)
        rig4.backend.sessions = [summary("ses_new", "Chief of staff", 700)]
        await rig4.start()
        #expect(await waitUntil { rig4.controller.status.target == "ses_new" })
        writeChief(rig4.chief, "ses_filed")
        #expect(await waitUntil(3) { rig4.controller.status.target == "ses_filed" })
        rig4.controller.stop()
    }

    @Test func noChiefAnywhereIsAClearError() async {
        let rig = Rig()
        try? FileManager.default.removeItem(atPath: rig.chief)
        rig.backend.sessions = [summary("ses_x", "Something else", 1)]
        await rig.controller.start() // Deliberate negative start: no authority can become ready.
        #expect(await waitUntil { rig.controller.status.lastError?.contains("no session is titled") == true })
        #expect(rig.controller.status.target == nil)
        rig.backend.sessions = [summary("ses_late", "Chief of staff", 5)]
        #expect(await waitUntil(5) { rig.controller.status.target == "ses_late" })
        rig.controller.stop()
    }

    @Test func serverListFailureFallsThroughToTheError() async {
        let rig = Rig()
        try? FileManager.default.removeItem(atPath: rig.chief)
        rig.backend.sessionListFails = true
        await rig.controller.start() // Deliberate negative start, not Rig's successful-readiness helper.
        #expect(await waitUntil { rig.controller.status.lastError?.contains("no session is titled") == true })
        rig.controller.stop()
    }

    @Test func sessionChoicesAreMostRecentFirst() async {
        let rig = Rig()
        rig.backend.sessions = [summary("ses_1", "Old", 1), summary("ses_3", "New", 3), summary("ses_2", "Mid", 2)]
        let choices = await rig.controller.sessionChoices(limit: 2)
        #expect(choices.map(\.id) == ["ses_3", "ses_2"])
    }

    @Test func headerNamesTheSessionWithAShortID() {
        var s = ConversationController.Status()
        #expect(s.targetLabel == nil)
        s.target = "ses_a10001fixture0000000000"
        #expect(s.targetLabel == "Session · a10001")
        s.targetTitle = "Chief of staff"
        #expect(s.targetLabel == "Chief of staff · a10001")
    }
    @Test func syntheticSessionPrefixesRemainDistinct() {
        let ids = ["ses_a10001fixture0000000000", "ses_a10002fixture0000000000", "ses_a10003fixture0000000000"]
        #expect(ids.map(SessionSummary.shortID) == ["a10001", "a10002", "a10003"])
        #expect(Set(ids.map(SessionSummary.shortID)).count == 3)
    }
}
