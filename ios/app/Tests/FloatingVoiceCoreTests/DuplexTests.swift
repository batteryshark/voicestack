import Foundation
import Testing
@testable import FloatingVoiceCore

/// Speech while the chief is speaking (the principal's live setup: full duplex, echo cancellation off, Bluetooth
/// headphones) is always captured and barges in, and the run log shows the mic level once a second.
@Suite(.serialized) @MainActor struct DuplexTests {
    /// Soft, choppy speech: 4 voiced frames then 2 below the threshold, repeated (never 8 in a row).
    func softSpeech(_ rig: Rig, cycles: Int) {
        for _ in 0..<cycles { rig.input.frames(4, voiced: true); rig.input.frames(2, voiced: false) }
    }

    @Test func softSpeechDuringPlaybackIsCapturedAndBargesIn() async {
        let rig = Rig(duration: 3.0)
        rig.transcript = "I think it should be better planned."
        await rig.start()
        #expect(rig.lines.contains { $0.hasPrefix("full duplex") })
        #expect(!rig.controller.halfDuplex)
        rig.reply(id: "m1", one)
        #expect(await waitUntil { rig.output.playing == [one] })
        softSpeech(rig, cycles: 12)
        #expect(rig.lines.contains("speech onset"))
        #expect(rig.output.cutInPaused && rig.output.stops == 0)
        rig.input.frames(60, voiced: false)
        #expect(await waitUntil { rig.backend.prompts.count == 1 })
        #expect(rig.backend.prompts[0].text == "[voice] I think it should be better planned.")
        rig.controller.stop()
    }

    @Test func openingWordsBeforeOnsetReachRecognition() async {
        // Up to 1 s before the onset goes to recognition with the utterance.
        let rig = Rig(duration: 3.0)
        rig.transcript = "Better planned."
        await rig.start()
        rig.reply(id: "m1", one)
        #expect(await waitUntil { rig.output.playing == [one] })
        rig.input.frames(60, voiced: false)
        rig.input.frames(8, voiced: true)
        #expect(rig.lines.contains("speech onset"))
        #expect(rig.recognitions.last?.written == 50) // 1 s of pre-roll: 42 frames before the voice, 8 voiced
        rig.input.frames(60, voiced: false)
        #expect(await waitUntil { rig.backend.prompts.count == 1 })
        rig.controller.stop()
    }

    @Test func micLevelIsLoggedOnceASecond() async {
        let rig = Rig(duration: 3.0)
        await rig.start()
        rig.reply(id: "m1", one)
        #expect(await waitUntil { rig.output.playing == [one] })
        rig.input.frames(50, voiced: true)
        rig.clock += 1000
        let ok = await waitUntil { rig.lines.contains { $0.hasPrefix("mic: rms avg") && $0.contains("50/50 frames voiced") && $0.contains("50 during playback") } } // reversible cut-in retains playback ownership
        #expect(ok, "\(rig.lines.filter { $0.hasPrefix("mic:") })")
        rig.clock += 1000
        #expect(await waitUntil { rig.lines.contains("mic: no audio in the last second") })
        rig.controller.stop()
    }

    @Test func halfDuplexIsLoggedAndIgnoredFramesCounted() async {
        let rig = Rig(duration: 3.0)
        rig.input.duplexSafe = false
        await rig.start()
        #expect(rig.controller.halfDuplex)
        #expect(rig.lines.contains { $0.hasPrefix("half duplex") })
        rig.reply(id: "m1", one)
        #expect(await waitUntil { rig.output.playing == [one] })
        rig.input.frames(20, voiced: true)
        rig.clock += 1000
        #expect(await waitUntil { rig.lines.contains { $0.contains("20 ignored (half duplex)") } })
        rig.controller.stop()
    }

    @Test func micStatsLine() {
        var s = MicStats()
        #expect(s.line(threshold: 0.012) == "mic: no audio in the last second")
        s.add(FakeInput.tone + Data(count: 640), threshold: 0.012, playing: true, ignored: false)
        #expect(s.frames == 2 && s.voiced == 1 && s.duringPlayback == 2 && s.ignored == 0)
        #expect(s.line(threshold: 0.012).hasPrefix("mic: rms avg 0.12"))
        #expect(s.line(threshold: 0.012).hasSuffix("1/2 frames voiced, 2 during playback"))
    }
}
