import Foundation
import Testing
@testable import FloatingVoiceCore

@Suite struct CleanSpeechTests {
    @Test func dropsCodeLinksAndMarkdown() {
        #expect(cleanSpeech("Run this:\n```sh\nrm -rf /\n```\nThen done.") == "Run this: Then done.")
        #expect(cleanSpeech("An unfinished ```fence keeps going") == "An unfinished")
        #expect(cleanSpeech("See [the docs](http://x.y/z) and ![img](a.png) now") == "See the docs and now")
        #expect(cleanSpeech("Open https://example.com/a?b=1 please") == "Open the linked page please")
        #expect(cleanSpeech("# Title\n- item *one*\n> quoted `code` ~x~") == "Title item one quoted code x")
    }
}

@Suite struct SpeechSegmentsTests {
    @Test func splitsSentencesAtLeast35CharsIn() {
        var out: [String] = []
        let s = SpeechSegments { out.append($0) }
        s.push("Short. This sentence is long enough to be cut here. And then")
        #expect(out == ["Short. This sentence is long enough to be cut here."])
        s.push(" the rest arrives.")
        #expect(out.count == 1) // "And then the rest arrives." starts after 35 chars? no: needs final flush
        s.flush(final: true)
        #expect(out == ["Short. This sentence is long enough to be cut here.", "And then the rest arrives."])
    }

    @Test func cutsLongRunsAtASpace() {
        var out: [String] = []
        let s = SpeechSegments { out.append($0) }
        s.push(String(repeating: "word ", count: 80))
        #expect(!out.isEmpty)
        #expect(out.allSatisfy { $0.count <= 241 })
    }

    @Test func neverNarratesAnOpenCodeFence() {
        var out: [String] = []
        let s = SpeechSegments { out.append($0) }
        s.push("Here is the code you asked for, below.\n```swift\nlet x = 1. let y = 2. let z = 3. More code here.\n")
        #expect(out == ["Here is the code you asked for, below."])
        s.push("```\nAfter the code block there is a sentence.")
        s.flush(final: true)
        #expect(out == ["Here is the code you asked for, below.", "After the code block there is a sentence."])
    }

    @Test func skipToEndSilencesReceivedTextOnly() {
        var out: [String] = []
        let s = SpeechSegments { out.append($0) }
        s.push("This is the first sentence of the reply, unfinished")
        s.skipToEnd()
        s.push(" and later this arrives after the barge-in point.")
        s.flush(final: true)
        #expect(out == ["and later this arrives after the barge-in point."])
    }

    @Test func periodAtChunkEndIsHeldUntilMoreText() {
        var out: [String] = []
        let s = SpeechSegments { out.append($0) }
        s.push("Each file also holds a different number of pears, from 1 in a.")
        #expect(out.isEmpty, "a period at the end of a chunk is not a sentence end yet")
        s.push("txt up to 5 in e.txt. Both passes matched.")
        #expect(out == ["Each file also holds a different number of pears, from 1 in a.txt up to 5 in e.txt."])
        s.flush(final: true)
        #expect(out.last == "Both passes matched.")
    }

    @Test func periodAtChunkEndFollowedByWhitespaceIsASentenceEnd() {
        var out: [String] = []
        let s = SpeechSegments { out.append($0) }
        s.push("This sentence is complete and long enough to speak now. ")
        #expect(out == ["This sentence is complete and long enough to speak now."])
    }

    @Test func textEndedReleasesTheHeldTail() {
        var out: [String] = []
        let s = SpeechSegments { out.append($0) }
        s.push("The whole reply is this single sentence, ending right here.")
        #expect(out.isEmpty)
        s.update("The whole reply is this single sentence, ending right here.")
        s.flush(final: true)
        #expect(out == ["The whole reply is this single sentence, ending right here."])
    }

    @Test func versionNumbersAbbreviationsAndURLsDoNotSplit() {
        var out: [String] = []
        let s = SpeechSegments { out.append($0) }
        s.push("We upgraded OpenChamber to version 2.3.2 and OpenCode to v2.0.28 today. ")
        s.push("Some tools need a restart, e.g. the speech server and the panel, before they work. ")
        s.push("Read the notes at https://example.com/v1.2/notes.html for details. Done.")
        s.flush(final: true)
        #expect(out == [
            "We upgraded OpenChamber to version 2.3.2 and OpenCode to v2.0.28 today.",
            "Some tools need a restart, e.g. the speech server and the panel, before they work.",
            "Read the notes at the linked page for details.",
            "Done.",
        ])
    }

    @Test func updateRepairsMissedDeltas() {
        var out: [String] = []
        let s = SpeechSegments { out.append($0) }
        s.push("The first sentence is right here and complete. The sec")
        s.update("The first sentence is right here and complete. The second one was missed in part.")
        s.flush(final: true)
        #expect(out == ["The first sentence is right here and complete.", "The second one was missed in part."])
    }
}

@Suite struct SettingsTests {
    @Test func defaultsMatchAgentVoice() {
        let c = VoiceConfig()
        #expect(c.ttsModel == "tts-1" && c.voice == "alloy" && c.pauseMs == 1100 && c.threshold == 0.012)
        #expect(c.bargeInMs == 320 && c.onsetGraceMs == 1200 && !c.bargeInAborts && c.echoCancellation == "auto" && c.duplex && !c.ttsStream)
    }

    @Test func loadsAgentVoiceThenAppOverridesWithoutWriting() throws {
        let dir = tempDir()
        let av = dir + "/agent-voice.json", app = dir + "/fv/settings.json", chief = dir + "/chief.json"
        try #"{"asrUrl":"ws://a","ttsUrl":"http://t/v1/audio/speech","ttsModel":"breeze-tts-2","voice":"default","device":"Mic","ttsStream":true,"echoCancellation":false}"#.write(toFile: av, atomically: true, encoding: .utf8)
        var env = ["HOME": dir, "FV_AGENT_VOICE_SETTINGS": av, "FV_SETTINGS": app]
        var s = SettingsStore.load(env: env)
        #expect(s.voice.ttsModel == "breeze-tts-2" && s.voice.inputDevice == "Mic" && s.voice.ttsStream && s.voice.echoCancellation == "off")
        #expect(s.app.target == "chief" && s.app.followsChief && s.app.busyDelivery == .queue, "default target is the chief")
        #expect(s.chiefFile == dir + "/.chief-of-staff/chief.json")
        #expect(!FileManager.default.fileExists(atPath: app), "loading must not create the app settings file")

        try FileManager.default.createDirectory(atPath: dir + "/fv", withIntermediateDirectories: true)
        try #"{"target":"ses_explicit","busyDelivery":"steer","voice":"mizuki","chiefFile":"/x/chief.json"}"#.write(toFile: app, atomically: true, encoding: .utf8)
        s = SettingsStore.load(env: env)
        #expect(s.app.target == "ses_explicit" && s.app.busyDelivery == .steer && s.voice.voice == "mizuki" && s.chiefFile == "/x/chief.json")
        env["FV_CHIEF_FILE"] = chief
        #expect(SettingsStore.load(env: env).chiefFile == chief)
    }

    @Test func appPauseDefaultOverridesAgentVoiceUnlessAppSetsOne() throws {
        let dir = tempDir()
        let av = dir + "/agent-voice.json", app = dir + "/settings.json"
        try #"{"pauseMs": 1100}"#.write(toFile: av, atomically: true, encoding: .utf8)
        let env = ["HOME": dir, "FV_AGENT_VOICE_SETTINGS": av, "FV_SETTINGS": app]
        var s = SettingsStore.load(env: env)
        #expect(s.voice.pauseMs == 3200 && s.app.holdMidSentenceMs == 1500 && s.app.busyMergeQuietMs == 3000 && s.app.turnEndQuietMs == 2000)
        try #"{"pauseMs": 1800, "holdMidSentenceMs": 2500, "busyMergeQuietMs": 4000}"#.write(toFile: app, atomically: true, encoding: .utf8)
        s = SettingsStore.load(env: env)
        #expect(s.voice.pauseMs == 1800 && s.app.holdMidSentenceMs == 2500 && s.app.busyMergeQuietMs == 4000)
    }

    @Test func sentenceCompleteness() {
        #expect(UtteranceComposer.isComplete("Yeah, this looks pretty cool."))
        #expect(UtteranceComposer.isComplete("What do you think?"))
        #expect(UtteranceComposer.isComplete("Well…"))
        #expect(!UtteranceComposer.isComplete("Although I don't see"))
        #expect(!UtteranceComposer.isComplete("all of the different uh"))
        #expect(!UtteranceComposer.isComplete("mock-up that we wanted with."))
        #expect(!UtteranceComposer.isComplete("Well, with like."))
        #expect(!UtteranceComposer.isComplete(""))
    }

    @Test func agentVoiceFileOrder() {
        let files = SettingsPaths.agentVoiceFiles(["HOME": "/h"])
        #expect(files == ["/h/.config/opencode/agent-voice.json", "/h/.pi/agent/agent-voice.json"])
    }

    @Test func chiefFileSession() throws {
        let p = tempDir() + "/chief.json"
        writeChief(p, "ses_abc")
        #expect(ChiefFile.session(at: p) == "ses_abc")
        #expect(ChiefFile.session(at: p + ".missing") == nil)
    }
}

@Suite struct SSEParserTests {
    @Test func splitsEventsAcrossChunks() {
        var p = SSEParser()
        #expect(p.push(Data("data: {\"type\":\"a\"}\n\ndata: {\"ty".utf8)) == ["{\"type\":\"a\"}"])
        #expect(p.push(Data("pe\":\"b\"}\r\n\r\n: comment\n\n".utf8)) == ["{\"type\":\"b\"}"])
        let e = ServerEvent(json: #"{"type":"session.text.delta","data":{"sessionID":"ses_1","assistantMessageID":"m","ordinal":2,"delta":"hi"}}"#)
        #expect(e?.sessionID == "ses_1" && e?.delta == "hi" && e?.blockKey == "m:2")
    }
}

@Suite struct WAVTests {
    @Test func roundTripAndResample() throws {
        let pcm = Data((0..<480).flatMap { i -> [UInt8] in let v = Int16(i * 10); return [UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 8)] })
        let (back, rate) = try WAV.decodeToS16Mono(WAV.encode(pcm, sampleRate: 24000))
        #expect(back == pcm && rate == 24000)
        #expect(resampleS16(pcm, from: 24000, to: 16000).count == 320 * 2)
    }
}

@Suite struct TurnTakingTests {
    final class Box { var events: [String] = []; var recognitions: [FakeRecognition] = [] }

    func make(_ box: Box, config: VoiceConfig = VoiceConfig(), muted: @escaping () -> Bool = { false }, partialAfter: Int? = nil) -> TurnTaker {
        var cb = TurnCallbacks()
        cb.muted = muted
        cb.start = { box.events.append("start") }
        cb.speaking = { box.events.append("speaking") }
        cb.partial = { box.events.append("partial:\($0)") }
        cb.transcript = { box.events.append("transcript:\($0)") }
        cb.idle = { box.events.append("idle") }
        return TurnTaker(config: config, callbacks: cb) { cbs in
            let r = FakeRecognition(cbs, transcript: "hello there", partialAfterFrames: partialAfter)
            box.recognitions.append(r)
            return r
        }
    }

    @MainActor @Test func onsetAfter8VoicedFramesWithPreroll() async {
        let box = Box(), t = make(box), mic = FakeInput()
        mic.onPCM = { t.push($0) }
        mic.frames(10, voiced: false)
        mic.frames(7, voiced: true)
        #expect(box.events.isEmpty)
        mic.frames(1, voiced: true)
        #expect(box.events == ["start"])
        #expect(box.recognitions.first?.written == 18) // all 18 frames so far are pre-roll (up to 50 frames, 1 s)
        mic.frames(8, voiced: true) // 16 voiced frames = 320 ms = bargeInMs
        #expect(box.events == ["start", "speaking"])
        mic.frames(54, voiced: false)
        #expect(box.recognitions.first?.ended == false)
        mic.frames(1, voiced: false) // 55 frames * 20 ms = 1100 ms pause
        #expect(box.recognitions.first?.ended == true)
        #expect(await waitUntil { box.events.last == "idle" })
        #expect(box.events == ["start", "speaking", "transcript:hello there", "idle"])
    }

    @MainActor @Test func prerollKeepsOneSecond() {
        let box = Box(), t = make(box), mic = FakeInput()
        mic.onPCM = { t.push($0) }
        mic.frames(100, voiced: false)
        mic.frames(8, voiced: true)
        #expect(box.events == ["start"])
        #expect(box.recognitions.first?.written == 50)
    }

    @MainActor @Test func softChoppySpeechStillOpensAnUtterance() {
        // Speech hovering at the threshold: never 8 voiced frames in a row, but 8 of every 12.
        let box = Box(), t = make(box), mic = FakeInput()
        mic.onPCM = { t.push($0) }
        mic.frames(20, voiced: false)
        for _ in 0..<3 { mic.frames(4, voiced: true); mic.frames(2, voiced: false) }
        #expect(box.events == ["start"])
        // Scattered noise (a voiced frame now and then) does not.
        let box2 = Box(), t2 = make(box2), mic2 = FakeInput()
        mic2.onPCM = { t2.push($0) }
        for _ in 0..<20 { mic2.frames(2, voiced: true); mic2.frames(3, voiced: false) }
        #expect(box2.events.isEmpty)
    }

    @MainActor @Test func mutedWhileIdleIgnoresSpeech() {
        let box = Box(), t = make(box, muted: { true }), mic = FakeInput()
        mic.onPCM = { t.push($0) }
        mic.frames(20, voiced: true)
        #expect(box.events.isEmpty)
    }

    @MainActor @Test func discardDropsUtterance() async {
        let box = Box(), t = make(box), mic = FakeInput()
        mic.onPCM = { t.push($0) }
        mic.frames(8, voiced: true)
        t.discard()
        #expect(box.recognitions.first?.cancelled == true)
        mic.frames(60, voiced: false)
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(!box.events.contains { $0.hasPrefix("transcript") })
    }
}
