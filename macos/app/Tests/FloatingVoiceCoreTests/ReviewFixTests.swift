import Foundation
import Testing
@testable import FloatingVoiceCore

/// Fixes from the 2026-10-15 review: no held words lost at quit, manual mode never sends unsent words, interrupts
/// admit words only after a real interrupt, recognition never stalls, corrupt settings are kept, Send in auto
/// mode, mutes survive a restart.
@Suite(.serialized) @MainActor struct ReviewFixTests {
    func say(_ rig: Rig, _ text: String) async {
        rig.transcript = text
        rig.speak()
        try? await Task.sleep(nanoseconds: 30_000_000)
    }

    func manualRig(appFile: String = "/nonexistent") async -> Rig {
        let rig = Rig(appFile: appFile)
        rig.controller.setSendMode(.manual)
        await rig.start()
        return rig
    }

    // 1. Quit: held words are posted and the post is awaited.
    @Test func stopPostsHeldWordsAndQuitCanAwaitThePost() async {
        let rig = Rig(holdMs: 10_000)
        rig.backend.promptDelay = 0.3
        await rig.start()
        await say(rig, "I was going to say that")
        rig.controller.stop()
        #expect(rig.backend.prompts.isEmpty) // still in flight
        let done = await rig.controller.waitForPosts(timeout: 2)
        #expect(done)
        #expect(rig.backend.prompts.map(\.text) == ["[voice] I was going to say that"])
    }

    @Test func waitForPostsGivesUpAfterTheCap() async {
        let rig = Rig(holdMs: 10_000)
        rig.backend.promptDelay = 3
        await rig.start()
        await say(rig, "Slow server here and")
        rig.controller.stop()
        let started = Date()
        let done = await rig.controller.waitForPosts(timeout: 0.3)
        #expect(!done && Date().timeIntervalSince(started) < 1.5)
    }

    // 2. Manual mode keeps holding through Stop, outside interrupts, target changes and device restarts.
    @Test func manualStopAndOutsideInterruptKeepHolding() async {
        let rig = await manualRig()
        rig.backend.send("session.execution.started", "ses_A")
        #expect(await waitUntil { rig.controller.status.busy })
        await say(rig, "Wait, that's the wrong file.")
        await rig.controller.stopReply()
        #expect(rig.backend.interrupts == ["ses_A"])
        rig.backend.send("session.execution.interrupted", "ses_A")
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(rig.backend.admits.isEmpty && rig.backend.prompts.isEmpty)
        #expect(rig.controller.status.holding == "Wait, that's the wrong file.")
        rig.controller.send()
        #expect(await waitUntil { rig.backend.prompts.count == 1 })
        rig.controller.stop()
    }

    @Test func manualTargetChangeRetainsOldWordsForReviewNeverRedirects() async {
        let rig = await manualRig()
        await say(rig, "This is for the other session.")
        rig.controller.setTargetSetting("ses_B")
        #expect(rig.controller.status.target == "ses_B")
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(rig.backend.prompts.isEmpty)
        rig.controller.send()
        #expect(await rig.controller.waitForPosts(timeout: 1))
        #expect(rig.backend.prompts.isEmpty)
        #expect(rig.controller.draftsForReview == ["This is for the other session."])
        rig.controller.stop()
    }

    @Test func manualDeviceRestartKeepsHoldingAndMutesSurvive() async throws {
        let rig = await manualRig(appFile: tempDir() + "/settings.json")
        await say(rig, "Keep this through the restart.")
        rig.controller.setMicMuted(true)
        rig.controller.setOutputMuted(true)
        let starts = rig.input.starts
        try await rig.controller.apply(.outputDevice("Other-Output"))
        #expect(rig.input.starts == starts + 1 && rig.controller.status.running)
        #expect(rig.controller.status.micMuted && rig.controller.status.outputMuted)
        #expect(rig.controller.status.holding == "Keep this through the restart.")
        #expect(rig.controller.status.pendingSpeech && rig.controller.status.discardHotkeyEligible)
        #expect(rig.controller.status.manualSend)
        #expect(rig.backend.prompts.isEmpty)
        rig.controller.discardPending()
        #expect(rig.controller.status.holding == nil && rig.controller.composer.held.isEmpty)
        #expect(!rig.controller.status.pendingSpeech && !rig.controller.status.discardHotkeyEligible)
        #expect(rig.controller.status.micMuted && rig.controller.status.outputMuted)
        rig.controller.composer.utterance("New words after the restart and discard.")
        rig.controller.send()
        #expect(await waitUntil { rig.backend.prompts.count == 1 })
        #expect(rig.backend.prompts.first?.text == "[voice] New words after the restart and discard.")
        rig.controller.stop()
    }

    @Test func mutesSurviveARestartInAutoMode() async throws {
        let rig = Rig(appFile: tempDir() + "/settings.json")
        await rig.start()
        rig.controller.setOutputMuted(true)
        try await rig.controller.apply(.echoCancellation("on"))
        #expect(rig.controller.status.outputMuted && !rig.controller.status.micMuted && rig.controller.status.running)
        rig.controller.stop()
    }

    @Test func manualVoiceStopDiscardsAndShowsIt() async {
        let rig = await manualRig()
        let pill = PillModel()
        pill.attach(rig.controller)
        rig.controller.onStatus = { pill.update(status: $0) }
        await say(rig, "Never mind, I was still thinking.")
        rig.controller.stop()
        let done = await rig.controller.waitForPosts(timeout: 1)
        #expect(done && rig.backend.prompts.isEmpty && rig.backend.admits.isEmpty)
        #expect(rig.lines.contains { $0.hasPrefix("discarded (voice stopped") && $0.hasSuffix("Never mind, I was still thinking.") })
        #expect(pill.you.discarded && pill.you.final == "Discarded" && pill.expanded)
        #expect(rig.controller.composer.held.isEmpty)
    }

    // 3. Interrupts admit buffered words only after a real interrupt, never while the principal is speaking.
    @Test func stopWithNoTurnRunningKeepsAMidSentenceHold() async {
        let rig = Rig(holdMs: 400)
        rig.backend.interruptResult = false
        await rig.start()
        await say(rig, "So what I want is")
        await rig.controller.stopReply()
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(rig.backend.admits.isEmpty && rig.backend.prompts.isEmpty, "no turn was interrupted: nothing admitted")
        await say(rig, "a longer pause before sending.")
        #expect(await waitUntil { rig.backend.prompts.count == 1 })
        #expect(rig.backend.prompts[0].text == "[voice] So what I want is a longer pause before sending.")
        #expect(rig.backend.admits.isEmpty)
        rig.controller.stop()
    }

    @Test func interruptWhileThePrincipalIsSpeakingKeepsHolding() async {
        let rig = Rig(quietMs: 10_000)
        await rig.start()
        rig.backend.send("session.execution.started", "ses_A")
        #expect(await waitUntil { rig.controller.status.busy })
        await say(rig, "First part of it,")
        rig.transcript = "and the second part."
        rig.input.frames(30, voiced: true) // speaking again
        rig.backend.send("session.execution.interrupted", "ses_A")
        try? await Task.sleep(nanoseconds: 150_000_000)
        #expect(rig.backend.admits.isEmpty, "never while they are speaking")
        rig.input.frames(60, voiced: false)
        // The thought arrives whole once they finish (the chief is idle now).
        #expect(await waitUntil(2) { rig.backend.prompts.count == 1 })
        #expect(rig.backend.prompts[0].text == "[voice] First part of it, and the second part.")
        rig.controller.stop()
    }

    // 4. A final transcript that never comes does not leave the app deaf.
    @Test func missingFinalTranscriptTimesOut() async {
        var events: [String] = []
        var cb = TurnCallbacks()
        cb.start = { events.append("start") }
        cb.transcript = { events.append("transcript:\($0)") }
        cb.idle = { events.append("idle") }
        cb.error = { events.append("error:\($0.localizedDescription)") }
        var config = VoiceConfig()
        config.pauseMs = 200
        var silent = true
        let t = TurnTaker(config: config, callbacks: cb) { c in
            let r = FakeRecognition(c, transcript: "second try")
            r.silentEnd = silent
            return r
        }
        t.finalTimeout = 0.2
        let mic = FakeInput()
        mic.onPCM = { t.push($0) }
        mic.frames(20, voiced: true); mic.frames(12, voiced: false)
        #expect(t.inUtterance)
        mic.frames(10, voiced: true)
        #expect(events == ["start"], "still waiting for the final: deaf until it comes or times out")
        #expect(await waitUntil(1) { events.contains("idle") })
        #expect(events.contains { $0.hasPrefix("error:No final transcript within 0 s") || $0.hasPrefix("error:No final transcript") })
        #expect(!t.inUtterance)
        silent = false
        mic.frames(20, voiced: true)
        #expect(!t.inUtterance, "uncertain tail cannot reopen until a fresh gap")
        mic.frames(TurnTaker.silenceCueFrames, voiced: false)
        mic.frames(20, voiced: true); mic.frames(12, voiced: false)
        #expect(await waitUntil(1) { events.contains("transcript:second try") })
    }

    // 5. A corrupt settings file is kept as .bad and reported, never silently dropped.
    @Test func corruptSettingsAreKeptAndReported() async throws {
        let dir = tempDir()
        let appFile = dir + "/settings.json"
        try "{\"voice\": \"ganyu\", oops".write(toFile: appFile, atomically: true, encoding: .utf8)
        let loaded = SettingsStore.load(env: ["FV_SETTINGS": appFile, "FV_AGENT_VOICE_SETTINGS": dir + "/none.json", "HOME": dir])
        #expect(loaded.appFileUnreadable)
        let rig = Rig(appFile: appFile)
        await rig.start()
        try await rig.controller.apply(.pauseMs(2500))
        #expect(try String(contentsOfFile: appFile + ".bad", encoding: .utf8) == "{\"voice\": \"ganyu\", oops")
        #expect(rig.controller.status.lastError == "settings.json was unreadable; saved a copy as settings.json.bad and wrote a new one")
        #expect((SettingsStore.readJSON(appFile)?["pauseMs"] as? NSNumber)?.doubleValue == 2500)
        // A readable file is merged, with no warning.
        rig.controller.clearError()
        try await rig.controller.apply(.voice("mizuki"))
        #expect(rig.controller.status.lastError == nil)
        let stored = SettingsStore.readJSON(appFile) ?? [:]
        #expect(stored["voice"] as? String == "mizuki" && (stored["pauseMs"] as? NSNumber)?.doubleValue == 2500)
        rig.controller.stop()
    }

    // 7. Send in auto mode mid-utterance sends the thought as soon as its final arrives; the flag does not linger.
    @Test func sendInAutoModeMidUtterance() async {
        let rig = Rig(holdMs: 10_000, quietMs: 10_000)
        await rig.start()
        await say(rig, "I was going to say that")
        rig.transcript = "we should ship it"
        rig.input.frames(30, voiced: true)
        rig.controller.send()
        #expect(await waitUntil { rig.backend.prompts.count == 1 })
        #expect(rig.backend.prompts[0].text == "[voice] I was going to say that we should ship it")
        // The next mid-sentence utterance holds as usual.
        await say(rig, "and another thing")
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(rig.backend.prompts.count == 1, "\(rig.backend.prompts.map(\.text)) \(rig.lines.suffix(12))")
        #expect(rig.controller.status.holding == "and another thing")
        rig.controller.stop()
    }
}
