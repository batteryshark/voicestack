import Foundation
import Testing
@testable import FloatingVoiceCore

/// A pill model on a fake clock, with voice on and connected.
@MainActor
final class PillRig {
    var clock = 1_000_000.0
    var status = ConversationController.Status()
    let pill: PillModel

    init() {
        var model: PillModel!
        var clockRef: () -> Double = { 0 }
        model = PillModel(now: { clockRef() })
        pill = model
        clockRef = { [weak self] in self?.clock ?? 0 }
        status.running = true
        status.phase = "ready"
        status.connection = "connected"
        pill.update(status: status)
    }

    func set(_ change: (inout ConversationController.Status) -> Void) { change(&status); pill.update(status: status) }
    func advance(_ ms: Double) { clock += ms; pill.tick() }
}

@Suite @MainActor struct PillModelTests {
    @Test func liveWordsTurnWhiteBehindAGreyTail() {
        let r = PillRig()
        r.pill.handle(.youStarted)
        r.pill.handle(.youLive("check on"))
        #expect(r.pill.you.final == "" && r.pill.you.tail == "check on")
        r.pill.handle(.youLive("check on dream studio"))
        #expect(r.pill.you.final == "check on" && r.pill.you.tail == "dream studio")
        // Several new words in one snapshot are all unconfirmed (grey).
        r.pill.handle(.youLive("check on dream studio and tell me if the PC"))
        #expect(r.pill.you.final == "check on dream studio" && r.pill.you.tail == "and tell me if the PC")
        r.pill.handle(.youLive("check on dream studio and tell me if the PC test"))
        #expect(r.pill.you.final == "check on dream studio and tell me if the")
        #expect(r.pill.you.tail == "PC test")
        #expect(r.pill.expanded)
        // The final transcript (the server's offline pass) replaces the live hypothesis and is all white.
        r.pill.handle(.youFinal("Check on Dream Studio and tell me if the PC test passed."))
        r.pill.handle(.youIdle)
        #expect(r.pill.you.final == "Check on Dream Studio and tell me if the PC test passed.")
        #expect(r.pill.you.tail == "")
        #expect(!r.pill.you.holding)
    }

    @Test func withoutPartialsTheFinalTextShows() {
        let r = PillRig()
        r.set { $0.hearing = true }
        r.pill.handle(.youStarted)
        r.pill.handle(.youSpeaking)
        #expect(r.pill.expanded)
        #expect(r.pill.you.isEmpty)
        r.pill.handle(.youFinal("Please do the thing."))
        #expect(r.pill.you.final == "Please do the thing." && r.pill.you.tail.isEmpty)
    }

    @Test func holdingShowsHeldWordsThenTheNextUtteranceLive() {
        let r = PillRig()
        r.pill.handle(.youFinal("Although I don't see the mock-up that we wanted with"))
        r.set { $0.holding = "Although I don't see the mock-up that we wanted with" }
        #expect(r.pill.you.holding)
        #expect(r.pill.you.final == "Although I don't see the mock-up that we wanted with")
        r.pill.handle(.youLive("all of the"))
        r.pill.handle(.youLive("all of the different voice"))
        #expect(r.pill.you.holding)
        #expect(r.pill.you.final == "Although I don't see the mock-up that we wanted with all of the")
        #expect(r.pill.you.tail == "different voice")
        // The composer merges and posts: the whole thought stays on screen in white until new speech.
        r.pill.handle(.youFinal("all of the different voice controls in the window."))
        r.set { $0.holding = nil }
        r.pill.handle(.posted("Although I don't see the mock-up that we wanted with all of the different voice controls in the window."))
        #expect(!r.pill.you.holding)
        #expect(r.pill.you.final == "Although I don't see the mock-up that we wanted with all of the different voice controls in the window.")
        // The next thought starts fresh.
        r.pill.handle(.youLive("next thing"))
        #expect(r.pill.you.final == "" && r.pill.you.tail == "next thing")
    }

    @Test func chiefCaptionFollowsPlaybackSentenceBySentence() {
        let r = PillRig()
        let s1 = "Dream Studio's PC test passed.", s2 = "The English patch is live."
        r.set { $0.speaking = true }
        r.pill.handle(.chiefQueued(label: "m1:0", text: s1))
        r.pill.handle(.chiefQueued(label: "m1:0", text: s2))
        // Queued text is not shown ahead of the voice.
        #expect(r.pill.chief.current == "" && !r.pill.chief.speaking)
        r.pill.handle(.chiefStarted(label: "m1:0", text: s1))
        #expect(r.pill.chief.current == s1 && r.pill.chief.speaking && r.pill.chief.earlier == "")
        #expect(r.pill.expanded)
        r.pill.handle(.chiefEnded(label: "m1:0", text: s1, outcome: "played"))
        #expect(r.pill.chief.current == s1) // between sentences: still the last one spoken, nothing ahead
        r.pill.handle(.chiefStarted(label: "m1:0", text: s2))
        #expect(r.pill.chief.current == s2 && r.pill.chief.earlier == s1 && r.pill.chief.speaking)
        r.pill.handle(.chiefEnded(label: "m1:0", text: s2, outcome: "played"))
        r.set { $0.speaking = false }
        // Quiet: the recent reply text.
        #expect(r.pill.chief.current == s1 + " " + s2 && !r.pill.chief.speaking && r.pill.chief.earlier == "")
        // A new reply's first sentence replaces it when it starts playing.
        r.set { $0.speaking = true }
        r.pill.handle(.chiefQueued(label: "m2:0", text: "Next reply here."))
        r.pill.handle(.chiefStarted(label: "m2:0", text: "Next reply here."))
        #expect(r.pill.chief.current == "Next reply here." && r.pill.chief.earlier == "")
    }

    @Test func mutedAgentVoiceShowsTheReplyText() {
        let r = PillRig()
        r.set { $0.outputMuted = true }
        #expect(r.pill.outputMuted)
        r.pill.handle(.chiefQueued(label: "m1:0", text: "First sentence of the reply."))
        r.pill.handle(.chiefQueued(label: "m1:0", text: "Second one."))
        #expect(r.pill.chief.current == "First sentence of the reply. Second one.")
        #expect(r.pill.expanded)
    }

    @Test func growsWhileTalkingAndShrinksAfterQuiet() {
        let r = PillRig()
        r.pill.shrinkAfterMs = 4000
        #expect(!r.pill.expanded)
        r.pill.tick()
        #expect(!r.pill.expanded) // nothing happening: stays a pill
        r.set { $0.hearing = true }
        r.pill.handle(.youStarted)
        #expect(r.pill.expanded) // onset exposes Discard even before the first word
        r.pill.handle(.youSpeaking)
        #expect(r.pill.expanded)
        r.advance(10_000)
        #expect(r.pill.expanded) // still hearing you
        r.pill.handle(.youFinal("Hello there."))
        r.set { $0.hearing = false }
        r.advance(50)
        r.advance(3900)
        #expect(r.pill.expanded)
        r.advance(100)
        #expect(!r.pill.expanded)
        #expect(r.pill.history.contains { $0.1.hasPrefix("shrink after") })
        // The chief speaking keeps it open however long it talks, then the same quiet period applies.
        r.set { $0.speaking = true }
        r.pill.handle(.chiefStarted(label: "m:0", text: "A long reply."))
        #expect(r.pill.expanded)
        r.advance(20_000)
        #expect(r.pill.expanded)
        r.pill.handle(.chiefEnded(label: "m:0", text: "A long reply.", outcome: "played"))
        r.set { $0.speaking = false }
        // Quiet counts from the last tick that saw the chief speaking.
        r.advance(3999)
        #expect(r.pill.expanded)
        r.advance(1)
        #expect(!r.pill.expanded)
        // Held words keep it open too.
        r.set { $0.holding = "and then" }
        #expect(r.pill.expanded)
        r.advance(30_000)
        #expect(r.pill.expanded)
        r.set { $0.holding = nil }
        r.advance(50)
        r.advance(4000)
        #expect(!r.pill.expanded)
    }

    @Test func hoverAndSettingsKeepTheCardOpen() {
        let r = PillRig()
        r.pill.handle(.youFinal("Hi."))
        r.pill.hovering = true
        r.advance(10_000)
        #expect(r.pill.expanded)
        r.pill.hovering = false
        r.advance(50)
        r.advance(4000)
        #expect(!r.pill.expanded)
        r.pill.settingsOpen = true
        #expect(r.pill.expanded)
        r.advance(60_000)
        #expect(r.pill.expanded)
    }

    @Test func muteAndErrorStates() {
        let r = PillRig()
        #expect(r.pill.phase == .ready && !r.pill.dimmed && !r.pill.hasError)
        r.set { $0.micMuted = true; $0.outputMuted = true }
        #expect(r.pill.micMuted && r.pill.outputMuted)
        r.set { $0.lastError = "Recognition: connection refused" }
        #expect(r.pill.hasError && r.pill.errorText == "Recognition: connection refused")
        #expect(r.pill.phase == .ready) // still working; the error shows as a badge
        r.pill.errorDetailsOpen = true
        #expect(r.pill.expanded)
        r.set { $0.lastError = nil }
        #expect(!r.pill.errorDetailsOpen && !r.pill.hasError)
        // Voice off with an error: dimmed, and the pill's line is the error.
        r.set { s in s = ConversationController.Status(); s.lastError = ConversationController.agentVoiceBusyMessage }
        #expect(r.pill.phase == .off && r.pill.dimmed && r.pill.stateLine == ConversationController.agentVoiceBusyMessage)
        r.set { s in s = ConversationController.Status(); s.running = true; s.phase = "ready"; s.connection = "reconnecting" }
        #expect(r.pill.phase == .connecting && r.pill.dimmed)
        r.set { $0.phase = "starting" }
        #expect(r.pill.phase == .starting)
    }

    @Test func visualizerShowsWhoeverIsTalking() {
        let r = PillRig()
        r.pill.handle(.micLevel(0.0001))
        r.advance(50)
        #expect(r.pill.voice == .you && r.pill.levels.last! == 0) // quiet room: flat, principal's colour
        r.set { $0.hearing = true }
        r.pill.handle(.micLevel(0.1))
        r.advance(50)
        #expect(r.pill.voice == .you && r.pill.levels.last! > 0.5)
        r.set { $0.hearing = false; $0.speaking = true }
        r.pill.handle(.outputLevel(0.05))
        r.advance(50)
        #expect(r.pill.voice == .chief && r.pill.levels.last! > 0.3)
        // Barge-in: the principal wins.
        r.set { $0.hearing = true }
        r.pill.handle(.outputLevel(0.05))
        r.pill.handle(.micLevel(0.02))
        r.advance(50)
        #expect(r.pill.voice == .you)
        // Mic muted and nothing playing: no one.
        r.set { $0.hearing = false; $0.speaking = false; $0.micMuted = true }
        r.advance(50)
        #expect(r.pill.voice == .none && r.pill.levels.last! == 0)
        #expect(r.pill.levels.count == PillModel.barCount)
        #expect(PillModel.normalize(0) == 0 && PillModel.normalize(1) == 1 && PillModel.normalize(0.00001) == 0)
    }
}

@Suite struct PartialsPlumbingTests {
    @Test func partialsURLAndHealth() {
        #expect(WebSocketRecognition.withPartials("ws://127.0.0.1:8446/v1/transcribe")?.absoluteString == "ws://127.0.0.1:8446/v1/transcribe?partials=1")
        #expect(WebSocketRecognition.withPartials("ws://h:1/v1/transcribe?language=en&partials=0")?.absoluteString == "ws://h:1/v1/transcribe?language=en&partials=1")
        #expect(ServiceChecks.healthURL("ws://127.0.0.1:8446/v1/transcribe")?.absoluteString == "http://127.0.0.1:8446/health")
        #expect(ServiceChecks.healthURL("wss://h/v1/transcribe?x=1")?.absoluteString == "https://h/health")
        #expect(ServiceChecks.healthURL("http://h/x") == nil)
        #expect(ServiceChecks.advertisesPartials(["streaming_partials": true, "partials": ["enabled": true]]))
        #expect(ServiceChecks.advertisesPartials(["streaming_partials": true]))
        #expect(!ServiceChecks.advertisesPartials(["streaming_partials": true, "partials": ["enabled": false]]))
        #expect(!ServiceChecks.advertisesPartials(["streaming_partials": false]))
        #expect(!ServiceChecks.advertisesPartials(["status": "ok"]))
    }

    @Test func voicesListParses() {
        let body: [String: Any] = ["default": "mizuki", "voices": [["name": "female_a", "label": "Original (female_a)"], ["name": "ganyu"], "plain"]]
        let v = HTTPSpeechSynthesizer.parseVoices(body)
        #expect(v.serverDefault == "mizuki")
        #expect(v.voices.map(\.name) == ["female_a", "ganyu", "plain"])
        #expect(v.voices.map(\.label) == ["Original (female_a)", "ganyu", "plain"])
    }
}

@Suite(.serialized) @MainActor struct PillControllerTests {
    @Test func livePartialsReachThePillBeforeTheFinalAndOnlyTheFinalIsSent() async {
        let rig = Rig(partialsProbe: { true })
        rig.transcript = "Please check the build."
        rig.live = [(12, "please"), (18, "please check"), (24, "please check the build")]
        let pill = PillModel()
        pill.attach(rig.controller)
        var events: [String] = []
        pill.onHistory = { events.append($0) }
        await rig.start()
        #expect(rig.controller.livePartials)
        rig.speak()
        #expect(await waitUntil { rig.backend.prompts.count == 1 })
        #expect(rig.backend.prompts[0].text == "[voice] Please check the build.")
        let firstLive = events.firstIndex { $0.hasPrefix("you live") }
        let final = events.firstIndex { $0.hasPrefix("you final") }
        #expect(firstLive != nil && final != nil && firstLive! < final!)
        #expect(events.filter { $0.hasPrefix("you live") }.count == 3)
        #expect(pill.you.final == "Please check the build.")
        #expect(rig.lines.contains { $0.contains("live words on (?partials=1)") })
        rig.controller.stop()
    }

    @Test func partialsOffWhenNotAdvertisedOrDisabled() async {
        let rig = Rig(partialsProbe: { false })
        await rig.start()
        #expect(!rig.controller.livePartials)
        #expect(rig.lines.contains { $0.contains("live words off") })
        rig.controller.stop()
        let rig2 = Rig(partialsProbe: { true })
        rig2.controller.app.livePartials = false
        await rig2.start()
        #expect(!rig2.controller.livePartials)
        rig2.controller.stop()
    }

    @Test func chiefCaptionInStepWithPlaybackThroughTheController() async {
        let rig = Rig(duration: 0.3)
        let pill = PillModel()
        pill.attach(rig.controller)
        rig.controller.onStatus = { pill.update(status: $0) }
        await rig.start()
        rig.reply(id: "m1", one + " " + two)
        #expect(await waitUntil { rig.output.playing == [one] })
        #expect(pill.chief.current == one && pill.chief.speaking)
        #expect(await waitUntil { rig.output.playing == [two] })
        #expect(pill.chief.current == two && pill.chief.earlier == one)
        #expect(await waitUntil { !rig.controller.speaker.active })
        #expect(pill.chief.current == one + " " + two && !pill.chief.speaking)
        rig.controller.stop()
    }

    @Test func micLevelsAndPlaybackLevelsFeedTheVisualizer() async {
        let rig = Rig()
        let pill = PillModel()
        pill.attach(rig.controller)
        rig.controller.onStatus = { pill.update(status: $0) }
        await rig.start()
        rig.input.frames(10, voiced: true) // onset after 8 voiced frames
        pill.tick()
        #expect(pill.voice == .you && pill.levels.last! > 0.5)
        rig.controller.stop()
    }
}

@Suite(.serialized) @MainActor struct SettingsWriteTests {
    @Test func changesWriteOnlyTheAppFileAndApplyLive() async throws {
        let dir = tempDir()
        let appFile = dir + "/floating-voice/settings.json"
        let agentVoice = dir + "/agent-voice.json"
        let agentText = #"{"voice": "default", "pauseMs": 1100, "inputDevice": "default"}"# + "\n"
        try agentText.write(toFile: agentVoice, atomically: true, encoding: .utf8)
        let before = try FileManager.default.attributesOfItem(atPath: agentVoice)[.modificationDate] as? Date
        let rig = Rig(appFile: appFile, voiceFile: agentVoice)
        await rig.start()
        let startsBefore = rig.input.starts

        try await rig.controller.apply(.voice("ganyu"))
        try await rig.controller.apply(.pauseMs(400))
        try await rig.controller.apply(.busyDelivery(.steer))
        writeChief(rig.chief, "ses_A")
        try await rig.controller.apply(.target("ses_B"))
        #expect(rig.controller.voice.voice == "ganyu")
        #expect(rig.controller.app.busyDelivery == .steer)
        #expect(rig.controller.status.target == "ses_B")
        #expect(await waitUntil { rig.controller.currentLease?.sessionID == "ses_B" })
        #expect(rig.input.starts == startsBefore) // none of these restart voice

        // The new pause length applies to the next utterance: 500 ms of silence now ends it (it was 1100 ms).
        rig.input.frames(30, voiced: true)
        rig.input.frames(25, voiced: false)
        #expect(await waitUntil { rig.backend.prompts.count == 1 })
        #expect(rig.backend.prompts.first?.session == "ses_B")

        // Device and echo changes restart voice so the engine reopens with them.
        try await rig.controller.apply(.inputDevice("Some-Mic-UID"))
        try await rig.controller.apply(.echoCancellation("off"))
        #expect(rig.input.starts == startsBefore + 2)
        #expect(rig.controller.voice.inputDevice == "Some-Mic-UID" && rig.controller.voice.echoCancellation == "off")
        #expect(rig.controller.status.running)

        let stored = SettingsStore.readJSON(appFile) ?? [:]
        #expect(stored["voice"] as? String == "ganyu")
        #expect((stored["pauseMs"] as? NSNumber)?.doubleValue == 400)
        #expect(stored["busyDelivery"] as? String == "steer")
        #expect(stored["target"] as? String == "ses_B")
        #expect(stored["inputDevice"] as? String == "Some-Mic-UID")
        #expect(stored["echoCancellation"] as? String == "off")
        // agent-voice's file is untouched.
        #expect(try String(contentsOfFile: agentVoice, encoding: .utf8) == agentText)
        #expect((try FileManager.default.attributesOfItem(atPath: agentVoice)[.modificationDate] as? Date) == before)
        // Settings load back the same way at the next launch.
        var env = ["FV_SETTINGS": appFile, "FV_AGENT_VOICE_SETTINGS": agentVoice, "FV_CHIEF_FILE": rig.chief, "HOME": dir]
        env["XDG_CONFIG_HOME"] = dir + "/config"
        let loaded = SettingsStore.load(env: env)
        #expect(loaded.voice.voice == "ganyu" && loaded.voice.pauseMs == 400 && loaded.app.busyDelivery == .steer && loaded.app.target == "ses_B")
        rig.controller.stop()
        // Back to the chief.
        try await rig.controller.apply(.target("chief"))
        #expect(rig.controller.app.followsChief)
    }

    @Test func refusesToWriteAgentVoicesFile() throws {
        let dir = tempDir()
        let agentVoice = dir + "/agent-voice.json"
        try "{}\n".write(toFile: agentVoice, atomically: true, encoding: .utf8)
        #expect(throws: (any Error).self) { try SettingsStore.saveAppSetting(["voice": "x"], appFile: agentVoice, voiceFile: agentVoice) }
        #expect(throws: (any Error).self) {
            try SettingsStore.saveAppSetting(["voice": "x"], appFile: agentVoice, voiceFile: nil, env: ["FV_AGENT_VOICE_SETTINGS": agentVoice])
        }
        #expect(try String(contentsOfFile: agentVoice, encoding: .utf8) == "{}\n")
        // The default candidates (opencode's and Pi's files) are protected too.
        let home = dir + "/home"
        let pi = home + "/.pi/agent/agent-voice.json"
        #expect(throws: (any Error).self) { try SettingsStore.saveAppSetting(["voice": "x"], appFile: pi, voiceFile: nil, env: ["HOME": home]) }
        #expect(!FileManager.default.fileExists(atPath: pi))
    }
}
