import Foundation
import Testing
@testable import FloatingVoiceCore

@MainActor
final class Rig {
    let backend = FakeBackend()
    let synth = FakeSynth()
    let output: FakeOutput
    let input = FakeInput()
    let mic = FakeMicHolders()
    let chief: String
    var clock = 100_000.0
    var transcript = "Please do the thing."
    var partialAfter: Int?
    /// Live words the fake recognition reports after so many frames: (frame, whole hypothesis).
    var live: [(Int, String)] = []
    var recognitions: [FakeRecognition] = []
    var recordRecognitionPCM = false
    var silentEnd = false
    var lines: [String] = []
    let controller: ConversationController

    init(target: String = "chief", busyDelivery: BusyDelivery = .queue, duration: TimeInterval = 0.25, preflight: [PreflightCheck] = [],
         holdMs: Double = 200, quietMs: Double = 300, turnEndQuietMs: Double = 300, appFile: String = "/nonexistent", voiceFile: String? = nil,
         partialsProbe: (() async -> Bool)? = nil, configure: (inout VoiceConfig) -> Void = { _ in }) {
        output = FakeOutput(duration: duration)
        chief = tempDir() + "/chief.json"
        writeChief(chief, "ses_A")
        var app = AppSettings()
        app.target = target
        app.busyDelivery = busyDelivery
        app.holdMidSentenceMs = holdMs
        app.busyMergeQuietMs = quietMs
        app.turnEndQuietMs = turnEndQuietMs
        var voice = VoiceConfig()
        voice.onsetGraceMs = 1200
        configure(&voice)
        let settings = LoadedSettings(app: app, voice: voice, voiceFile: voiceFile, appFile: appFile, chiefFile: chief)
        var clockRef: () -> Double = { 0 }
        var rec: (RecognitionCallbacks) -> RecognitionSession = { FakeRecognition($0, transcript: "") }
        var logRef: (String) -> Void = { _ in }
        controller = ConversationController(settings: settings, backend: backend, synth: synth, output: output, input: input,
                                            makeRecognition: { rec($0) }, micCheck: mic, now: { clockRef() },
                                            chiefPollInterval: 0.2, micPollInterval: 0.2, reconnectDelay: 0.05,
                                            preflight: preflight, partialsProbe: partialsProbe, log: { logRef($0) })
        clockRef = { [weak self] in self?.clock ?? 0 }
        rec = { [weak self] cbs in
            let r = FakeRecognition(cbs, transcript: self?.transcript ?? "", partialAfterFrames: self?.partialAfter, live: self?.live ?? [])
            if self?.recordRecognitionPCM == true { r.recordedPCM = [] }
            r.silentEnd = self?.silentEnd ?? false
            self?.recognitions.append(r)
            return r
        }
        logRef = { [weak self] in self?.lines.append($0) }
    }

    func start() async {
        await controller.start()
        #expect(await waitUntil { self.controller.status.connection == "connected" && self.controller.status.phase == "ready" && self.controller.currentLease != nil })
        clock += 5000 // past onset grace
    }

    func reply(_ session: String = "ses_A", id: String, _ text: String) {
        backend.send("session.text.started", session, ["assistantMessageID": id, "ordinal": 0])
        backend.send("session.text.delta", session, ["assistantMessageID": id, "ordinal": 0, "delta": text])
        backend.send("session.text.ended", session, ["assistantMessageID": id, "ordinal": 0, "text": text])
    }

    /// A spoken utterance: onset, sustained speech, then a pause that ends it.
    func speak(voicedFrames: Int = 30) { input.frames(voicedFrames, voiced: true); input.frames(60, voiced: false) }
}

let one = "This is the first reply, sentence number one."
let two = "This is the first reply, and sentence number two."
let three = "A second reply arrives here while the first is playing."

@Suite(.serialized) @MainActor struct ControllerTests {
    @Test func idleUtteranceIsANormalMessage() async {
        let rig = Rig()
        await rig.start()
        #expect(rig.controller.status.target == "ses_A")
        rig.speak()
        #expect(await waitUntil { rig.backend.prompts.count == 1 })
        #expect(rig.backend.prompts[0] == .init(session: "ses_A", text: "[voice] Please do the thing.", delivery: nil))
        rig.controller.stop()
    }

    @Test func busyUtteranceUsesConfiguredDelivery() async {
        for delivery in [BusyDelivery.queue, .steer] {
            let rig = Rig(busyDelivery: delivery)
            await rig.start()
            rig.backend.send("session.execution.started", "ses_A")
            #expect(await waitUntil { rig.controller.status.busy })
            rig.speak()
            #expect(await waitUntil { rig.backend.prompts.count == 1 })
            #expect(rig.backend.prompts[0].delivery == delivery)
            rig.controller.stop()
        }
    }

    @Test func otherSessionsAndInboxNeverStopPlayback() async {
        let rig = Rig(duration: 0.3)
        await rig.start()
        rig.backend.send("session.execution.started", "ses_A")
        rig.reply(id: "m1", one + " " + two)
        #expect(await waitUntil { rig.output.playing == [one] })
        // A lead's message lands in the thread, a new turn starts and ends, and a new reply arrives.
        rig.backend.send("session.execution.succeeded", "ses_A")
        rig.backend.send("session.inbox.enqueued", "ses_A", ["item": ["type": "user", "delivery": "steer", "payload": ["text": "lead update"]]])
        rig.backend.send("session.execution.started", "ses_A")
        rig.reply(id: "m2", three)
        rig.backend.send("session.execution.succeeded", "ses_A")
        // Another session's reply is ignored entirely.
        rig.reply("ses_OTHER", id: "x1", "Some other session's text that must never be spoken.")
        #expect(await waitUntil(4) { rig.output.plays.count == 3 && rig.output.plays.allSatisfy { $0.outcome == "played" } })
        #expect(rig.output.plays.map(\.text) == [one, two, three])
        #expect(rig.output.stops == 0)
        rig.controller.stop()
    }

    @Test func bargeInStopsPlaybackWithoutInterrupting() async {
        let rig = Rig(duration: 1.0)
        await rig.start()
        rig.backend.send("session.execution.started", "ses_A")
        rig.reply(id: "m1", one + " " + two)
        #expect(await waitUntil { rig.output.playing == [one] })
        rig.input.frames(16, voiced: true) // 320 ms of speech = bargeInMs
        #expect(await waitUntil { rig.output.plays.first?.outcome == "stopped" })
        #expect(rig.backend.interrupts.isEmpty)
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(rig.output.plays.count == 1, "the queued second sentence is silenced too")
        // Text that arrives after the barge-in plays normally.
        rig.reply(id: "m2", three)
        #expect(await waitUntil { rig.output.playing == [three] })
        rig.controller.stop()
    }

    @Test func partialTranscriptAlsoBargesIn() async {
        let rig = Rig(duration: 1.0, configure: { $0.bargeInMs = 10_000 })
        rig.partialAfter = 2
        await rig.start()
        rig.reply(id: "m1", one)
        #expect(await waitUntil { rig.output.playing == [one] })
        rig.input.frames(10, voiced: true)
        #expect(await waitUntil { rig.output.plays.first?.outcome == "stopped" })
        rig.controller.stop()
    }

    @Test func onsetGraceIgnoresEarlyNoise() async {
        let rig = Rig(duration: 1.0)
        await rig.controller.start()
        _ = await waitUntil { rig.controller.status.connection == "connected" }
        rig.reply(id: "m1", one)
        #expect(await waitUntil { rig.output.playing == [one] })
        rig.clock += 500 // still within onsetGraceMs of the mic going live
        rig.input.frames(20, voiced: true)
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(rig.output.plays.first?.outcome == "playing")
        rig.controller.stop()
    }

    @Test func stopControlInterruptsAndClears() async {
        let rig = Rig(duration: 1.0)
        await rig.start()
        rig.backend.send("session.execution.started", "ses_A")
        rig.reply(id: "m1", one + " " + two)
        #expect(await waitUntil { rig.output.playing == [one] })
        await rig.controller.stopReply()
        #expect(rig.backend.interrupts == ["ses_A"])
        #expect(await waitUntil { rig.output.plays.first?.outcome == "stopped" })
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(rig.output.plays.count == 1)
        rig.controller.stop()
    }

    @Test func muteAgentVoiceDropsSpeechUntilUnmuted() async {
        let rig = Rig(duration: 1.0)
        await rig.start()
        rig.reply(id: "m1", one)
        #expect(await waitUntil { rig.output.playing == [one] })
        rig.controller.setOutputMuted(true)
        #expect(await waitUntil { rig.output.plays.first?.outcome == "stopped" })
        rig.reply(id: "m2", two)
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(rig.output.plays.count == 1)
        rig.controller.setOutputMuted(false)
        rig.reply(id: "m3", three)
        #expect(await waitUntil { rig.output.playing == [three] })
        rig.controller.stop()
    }

    @Test func muteMicStopsListeningAndBargeIn() async {
        let rig = Rig(duration: 1.0)
        await rig.start()
        rig.controller.setMicMuted(true)
        rig.reply(id: "m1", one)
        #expect(await waitUntil { rig.output.playing == [one] })
        rig.speak()
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(rig.output.plays.first?.outcome == "playing")
        #expect(rig.backend.prompts.isEmpty)
        rig.controller.stop()
    }

    @Test func followsChiefFileChanges() async {
        let rig = Rig()
        await rig.start()
        #expect(rig.controller.status.target == "ses_A")
        writeChief(rig.chief, "ses_B")
        #expect(await waitUntil { rig.controller.status.target == "ses_B" })
        rig.reply("ses_B", id: "b1", three)
        #expect(await waitUntil { rig.output.playing == [three] })
        rig.speak()
        #expect(await waitUntil { rig.backend.prompts.first?.session == "ses_B" })
        rig.controller.stop()
    }

    @Test func explicitTargetIgnoresChiefFile() async {
        let rig = Rig(target: "ses_X")
        await rig.start()
        #expect(rig.controller.status.target == "ses_X")
        writeChief(rig.chief, "ses_B")
        try? await Task.sleep(nanoseconds: 400_000_000)
        #expect(rig.controller.status.target == "ses_X")
        rig.controller.stop()
    }

    @Test func reconnectResyncsBusyState() async {
        let rig = Rig()
        await rig.start()
        #expect(rig.controller.status.busy == false)
        rig.backend.active = ["ses_A"] // the turn started while the stream was down
        rig.backend.drop()
        #expect(await waitUntil { rig.backend.connects == 2 && rig.controller.status.busy })
        rig.backend.active = []
        rig.backend.drop()
        #expect(await waitUntil { rig.backend.connects == 3 && !rig.controller.status.busy })
        rig.controller.stop()
    }

    @Test func textEndedRepairsMissedDeltas() async {
        let rig = Rig()
        await rig.start()
        rig.backend.send("session.text.started", "ses_A", ["assistantMessageID": "m", "ordinal": 0])
        rig.backend.send("session.text.delta", "ses_A", ["assistantMessageID": "m", "ordinal": 0, "delta": "This is the first reply, sen"])
        rig.backend.send("session.text.ended", "ses_A", ["assistantMessageID": "m", "ordinal": 0, "text": one])
        #expect(await waitUntil { rig.output.playing == [one] })
        rig.controller.stop()
    }

    @Test func agentVoiceHoldingMicBlocksStart() async {
        let rig = Rig()
        rig.mic.holders = [MicHolder(pid: 42, path: "/x/agent-voice/bin/audio-macos", isAgentVoice: true)]
        await rig.controller.start()
        #expect(!rig.controller.status.running)
        #expect(rig.controller.status.lastError?.contains("agent-voice") == true)
        #expect(!rig.input.started)
    }

    @Test func agentVoiceTakingMicPausesThisApp() async {
        let rig = Rig()
        await rig.start()
        #expect(rig.input.started)
        rig.mic.holders = [MicHolder(pid: 42, path: "/x/agent-voice/bin/audio-macos", isAgentVoice: true)]
        #expect(await waitUntil { !rig.controller.status.running })
        #expect(rig.input.stopped)
        #expect(rig.controller.status.notice?.contains("agent-voice") == true)
    }

    @Test func interruptFromElsewhereStopsPlayback() async {
        let rig = Rig(duration: 1.0)
        await rig.start()
        rig.backend.send("session.execution.started", "ses_A")
        rig.reply(id: "m1", one + " " + two)
        #expect(await waitUntil { rig.output.playing == [one] })
        // Someone pressed stop in OpenChamber: no interrupt call from this app, just the event.
        rig.backend.send("session.execution.interrupted", "ses_A")
        #expect(await waitUntil { rig.output.plays.first?.outcome == "stopped" })
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(rig.output.plays.count == 1, "the queued sentence is cleared")
        #expect(rig.backend.interrupts.isEmpty)
        #expect(!rig.controller.status.busy)
        rig.controller.stop()
    }

    @Test func failedTurnKeepsQueuedSpeech() async {
        let rig = Rig(duration: 0.2)
        await rig.start()
        rig.reply(id: "m1", one + " " + two)
        #expect(await waitUntil { rig.output.playing == [one] })
        rig.backend.send("session.execution.failed", "ses_A")
        #expect(await waitUntil { rig.output.plays.count == 2 && rig.output.plays.allSatisfy { $0.outcome == "played" } })
        rig.controller.stop()
    }

    @Test func showsTheAttachedSessionTitle() async {
        let rig = Rig()
        rig.backend.titles["ses_A"] = "Chief of staff"
        await rig.start()
        #expect(await waitUntil { rig.controller.status.targetName == "Chief of staff (ses_A)" })
        #expect(rig.controller.status.line.contains("Chief of staff (ses_A)"))
        rig.controller.stop()
    }

    @Test func selfCheckFailureShowsErrorAndReleasesMic() async {
        let rig = Rig(preflight: [PreflightCheck(name: "speech server") { throw ClientError("The speech server at http://x is not working: refused") }])
        await rig.controller.start()
        #expect(!rig.controller.status.running)
        #expect(rig.controller.status.lastError == "The speech server at http://x is not working: refused")
        #expect(rig.input.stopped)
    }

    @Test func readyOnlyAfterSelfCheck() async {
        var passed = false
        let rig = Rig(preflight: [PreflightCheck(name: "slow") { try await Task.sleep(nanoseconds: 200_000_000); passed = true }])
        let start = Task { await rig.controller.start() }
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(rig.controller.status.phase == "starting")
        #expect(rig.controller.status.line.hasPrefix("Starting"))
        await start.value
        #expect(passed && rig.controller.status.phase == "ready" && rig.controller.status.running)
        rig.controller.stop()
    }

    @Test func agentVoiceMessagesSayWhatToDo() {
        for m in [ConversationController.agentVoiceBusyMessage, ConversationController.agentVoiceTookMicMessage] {
            #expect(m.contains("agent-voice") && m.contains("Turn voice off there") && m.contains("press Start voice"))
        }
    }

    @Test func echoUnsafeOutputForcesHalfDuplex() async {
        let rig = Rig(duration: 1.0)
        rig.input.duplexSafe = false // echo cancellation off, output is speakers
        await rig.start()
        #expect(rig.controller.halfDuplex)
        rig.reply(id: "m1", one)
        #expect(await waitUntil { rig.output.playing == [one] })
        rig.speak()
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(rig.output.plays.first?.outcome == "playing", "no barge-in while speaking in half duplex")
        #expect(rig.backend.prompts.isEmpty, "nothing captured while speaking")
        #expect(await waitUntil { rig.output.plays.first?.outcome == "played" })
        try? await Task.sleep(nanoseconds: 100_000_000)
        rig.clock += rig.controller.app.turnEndQuietMs + 1
        rig.speak() // after playback and the deliberate speaker tail, the mic works again
        #expect(await waitUntil { rig.backend.prompts.count == 1 })
        rig.controller.stop()
    }

    @Test func echoSafeOutputStaysDuplex() async {
        let rig = Rig()
        await rig.start()
        #expect(!rig.controller.halfDuplex)
        rig.controller.stop()
    }

    @Test func repeatedStartStopCycles() async {
        let rig = Rig(duration: 0.2)
        for cycle in 1...4 {
            await rig.start()
            #expect(rig.controller.status.running && rig.controller.status.phase == "ready")
            #expect(rig.input.starts == cycle && rig.input.started)
            rig.reply(id: "c\(cycle)", "This is cycle number \(cycle) speaking one complete sentence.")
            #expect(await waitUntil { rig.output.plays.count == cycle && rig.output.plays.last?.outcome == "played" })
            rig.speak()
            #expect(await waitUntil { rig.backend.prompts.count == cycle })
            rig.controller.stop()
            #expect(rig.input.stops == cycle && !rig.input.started && !rig.controller.status.running)
            #expect(rig.input.onPCM == nil, "the stopped run no longer receives mic audio")
        }
        #expect(rig.backend.connects == 4)
        #expect(rig.output.plays.count == 4, "no duplicate playback from an old run's event stream")
    }

    // MARK: Holding and merging

    func say(_ rig: Rig, _ text: String) async {
        rig.transcript = text
        rig.speak()
        try? await Task.sleep(nanoseconds: 30_000_000) // recognition finishes on the next main-queue turn
    }

    @Test func midSentenceFragmentsMerge() async {
        let rig = Rig()
        await rig.start()
        await say(rig, "Although I don't see")
        #expect(rig.controller.status.holding == "Although I don't see")
        await say(rig, "the mock-up that we wanted with")
        await say(rig, "all of the different uh")
        await say(rig, "voice controls in the window.")
        #expect(await waitUntil { rig.backend.prompts.count == 1 })
        #expect(rig.backend.prompts[0] == .init(session: "ses_A", text: "[voice] Although I don't see the mock-up that we wanted with all of the different uh voice controls in the window.", delivery: nil))
        #expect(rig.controller.status.holding == nil)
        rig.controller.stop()
    }

    @Test func punctuatedSentenceWhileIdleGoesImmediately() async {
        let rig = Rig(holdMs: 5000)
        await rig.start()
        await say(rig, "Yeah, this looks pretty cool.")
        #expect(await waitUntil(0.5) { rig.backend.prompts.count == 1 })
        #expect(rig.backend.prompts.first?.delivery == nil)
    }

    @Test func heldFragmentIsSentAfterTheHoldWindow() async {
        let rig = Rig(holdMs: 300)
        await rig.start()
        await say(rig, "So I was thinking about the mock-up and uh.")
        try? await Task.sleep(nanoseconds: 150_000_000)
        #expect(rig.backend.prompts.isEmpty, "a trailing filler holds even with a period")
        #expect(await waitUntil { rig.backend.prompts.count == 1 })
        #expect(rig.backend.prompts[0].text == "[voice] So I was thinking about the mock-up and uh.")
        rig.controller.stop()
    }

    @Test func busyFragmentsBecomeOneQueuedMessage() async {
        let rig = Rig(quietMs: 400)
        await rig.start()
        rig.backend.send("session.execution.started", "ses_A")
        #expect(await waitUntil { rig.controller.status.busy })
        await say(rig, "Although I don't see")
        await say(rig, "The")
        await say(rig, "mock-up that we wanted.")
        await say(rig, "It interrupts me a little quickly.")
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(rig.backend.prompts.isEmpty, "complete sentences still merge while the chief is busy")
        #expect(rig.controller.status.holding?.hasPrefix("Although I don't see The mock-up") == true)
        #expect(await waitUntil { rig.backend.prompts.count == 1 })
        #expect(rig.backend.prompts[0] == .init(session: "ses_A", text: "[voice] Although I don't see The mock-up that we wanted. It interrupts me a little quickly.", delivery: .queue))
        // Later speech starts a new buffer.
        await say(rig, "One more thing.")
        #expect(await waitUntil { rig.backend.prompts.count == 2 })
        #expect(rig.backend.prompts[1].text == "[voice] One more thing.")
        rig.controller.stop()
    }

    @Test func turnEndFlushesTheBufferAsANormalMessage() async {
        let rig = Rig(quietMs: 10_000, turnEndQuietMs: 300)
        await rig.start()
        rig.backend.send("session.execution.started", "ses_A")
        #expect(await waitUntil { rig.controller.status.busy })
        await say(rig, "When you are done, also check the logs.")
        try? await Task.sleep(nanoseconds: 400_000_000) // quiet longer than turnEndQuietMs already
        #expect(rig.backend.prompts.isEmpty)
        rig.backend.send("session.execution.succeeded", "ses_A")
        #expect(await waitUntil(0.2) { rig.backend.prompts.count == 1 }, "posted at once: the principal was already quiet")
        #expect(rig.backend.prompts[0] == .init(session: "ses_A", text: "[voice] When you are done, also check the logs.", delivery: nil))
        rig.controller.stop()
    }

    @Test func turnEndWaitsForQuietAfterTheLastUtterance() async {
        let rig = Rig(quietMs: 10_000, turnEndQuietMs: 600)
        await rig.start()
        rig.backend.send("session.execution.started", "ses_A")
        #expect(await waitUntil { rig.controller.status.busy })
        await say(rig, "When you are done, also check the logs.")
        let ended = Date()
        rig.backend.send("session.execution.succeeded", "ses_A")
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(rig.backend.prompts.isEmpty, "the turn ended right after they spoke: wait for turnEndQuietMs of quiet")
        #expect(await waitUntil(2) { rig.backend.prompts.count == 1 })
        #expect(Date().timeIntervalSince(ended) >= 0.5)
        #expect(rig.backend.prompts[0] == .init(session: "ses_A", text: "[voice] When you are done, also check the logs.", delivery: nil))
        rig.controller.stop()
    }

    @Test func turnEndNeverCutsThePrincipalOff() async {
        let rig = Rig(quietMs: 10_000, turnEndQuietMs: 400)
        await rig.start()
        rig.backend.send("session.execution.started", "ses_A")
        #expect(await waitUntil { rig.controller.status.busy })
        await say(rig, "When you are done, also check the logs.")
        try? await Task.sleep(nanoseconds: 500_000_000)
        // They start talking again; the turn ends mid-utterance.
        rig.transcript = "And the build too."
        rig.input.frames(30, voiced: true)
        rig.backend.send("session.execution.succeeded", "ses_A")
        try? await Task.sleep(nanoseconds: 600_000_000)
        #expect(rig.backend.prompts.isEmpty, "never posted while they are speaking")
        rig.input.frames(60, voiced: false) // the utterance ends
        try? await Task.sleep(nanoseconds: 150_000_000)
        #expect(rig.backend.prompts.isEmpty, "and not before turnEndQuietMs of quiet")
        #expect(await waitUntil(2) { rig.backend.prompts.count == 1 })
        #expect(rig.backend.prompts[0] == .init(session: "ses_A", text: "[voice] When you are done, also check the logs. And the build too.", delivery: nil))
        rig.controller.stop()
    }

    @Test func stopControlDoesNotLoseBufferedWords() async {
        let rig = Rig(quietMs: 10_000)
        await rig.start()
        rig.backend.send("session.execution.started", "ses_A")
        #expect(await waitUntil { rig.controller.status.busy })
        await say(rig, "Actually wait, stop and")
        await rig.controller.stopReply()
        #expect(rig.backend.interrupts == ["ses_A"])
        #expect(await waitUntil { rig.backend.admits == ["[voice] Actually wait, stop and"] })
        #expect(rig.backend.prompts.isEmpty, "admitted without starting a turn")
        rig.controller.stop()
    }

    @Test func outsideInterruptDoesNotLoseBufferedWords() async {
        let rig = Rig(quietMs: 10_000)
        await rig.start()
        rig.backend.send("session.execution.started", "ses_A")
        #expect(await waitUntil { rig.controller.status.busy })
        await say(rig, "Here is what I meant to say.")
        rig.backend.send("session.execution.interrupted", "ses_A")
        #expect(await waitUntil { rig.backend.admits == ["[voice] Here is what I meant to say."] })
        rig.controller.stop()
    }

    @Test func steerModeStillPostsImmediately() async {
        let rig = Rig(busyDelivery: .steer, quietMs: 10_000)
        await rig.start()
        rig.backend.send("session.execution.started", "ses_A")
        #expect(await waitUntil { rig.controller.status.busy })
        await say(rig, "Please also check the logs.")
        #expect(await waitUntil(0.5) { rig.backend.prompts.count == 1 })
        #expect(rig.backend.prompts[0].delivery == .steer)
        rig.controller.stop()
    }

    @Test func stoppingVoicePostsHeldWords() async {
        let rig = Rig(holdMs: 10_000)
        await rig.start()
        await say(rig, "I was going to say that")
        rig.controller.stop()
        #expect(await waitUntil { rig.backend.prompts.first?.text == "[voice] I was going to say that" })
    }

    @Test func bargeInStillFiresImmediatelyWhileHolding() async {
        let rig = Rig(duration: 1.0, holdMs: 5000)
        await rig.start()
        rig.reply(id: "m1", one)
        #expect(await waitUntil { rig.output.playing == [one] })
        await say(rig, "Hold on, I")
        #expect(rig.output.plays.first?.outcome == "stopped")
        #expect(rig.backend.prompts.isEmpty)
        rig.controller.stop()
    }

    @Test func stopReleasesMic() async {
        let rig = Rig()
        await rig.start()
        rig.controller.stop()
        #expect(rig.input.stopped && !rig.controller.status.running)
    }
}
