import Foundation
import Testing
@testable import FloatingVoiceCore

/// Background noise cannot hold an utterance open: an adaptive noise floor raises the voiced threshold, and once words
/// are streaming the words decide when the thought is over.
@Suite(.serialized) @MainActor struct NoiseTests {
    // MARK: The floor tracker

    @Test func floorCalibratesWithinAboutASecond() {
        var f = NoiseFloor()
        for _ in 0..<50 { f.add(0.017, inUtterance: false) }
        #expect(!f.calibrating)
        #expect(abs(f.value - 0.017) < 0.0005)
        #expect(abs(f.threshold(base: 0.012, factor: Sensitivity.normal.factor) - 0.034) < 0.001)
        // A quiet room keeps the fixed threshold.
        var q = NoiseFloor()
        for _ in 0..<50 { q.add(0.003, inUtterance: false) }
        #expect(q.threshold(base: 0.012, factor: 2) == 0.012)
    }

    @Test func floorIgnoresSpeechBurstsAndIsCapped() {
        var f = NoiseFloor()
        for _ in 0..<100 { f.add(0.004, inUtterance: false) }
        // Two seconds of speech-level frames outside an utterance (the pre-onset moments): the 10th percentile holds.
        for _ in 0..<20 { f.add(0.2, inUtterance: false) }
        #expect(f.value < 0.006)
        var loud = NoiseFloor()
        for _ in 0..<60 { loud.add(0.3, inUtterance: false) }
        #expect(loud.value == NoiseFloor.maxFloor)
    }

    @Test func floorRisesSlowlyAndFallsQuickly() {
        var f = NoiseFloor()
        for _ in 0..<100 { f.add(0.003, inUtterance: false) }
        // Noise starts: it takes a few seconds to be believed, then the floor climbs.
        for _ in 0..<150 { f.add(0.02, inUtterance: false) } // 3 s
        #expect(f.value < 0.005, "slow to rise: \(f.value)")
        for _ in 0..<500 { f.add(0.02, inUtterance: false) } // 10 s more
        #expect(f.value > 0.017, "\(f.value)")
        // Noise stops: gone within about a second.
        for _ in 0..<60 { f.add(0.003, inUtterance: false) }
        #expect(f.value < 0.006, "quick to fall: \(f.value)")
    }

    @Test func insideAnUtteranceTheFloorOnlySinks() {
        var f = NoiseFloor()
        for _ in 0..<100 { f.add(0.01, inUtterance: false) }
        let before = f.value
        for _ in 0..<500 { f.add(0.2, inUtterance: true) } // 10 s of speech: no rise
        #expect(f.value == before)
        for _ in 0..<100 { f.add(0.002, inUtterance: true) } // gaps between words: it can fall
        #expect(f.value < before)
    }

    @Test func sensitivityScalesTheThreshold() {
        var f = NoiseFloor()
        for _ in 0..<50 { f.add(0.02, inUtterance: false) }
        let low = f.threshold(base: 0.012, factor: Sensitivity.low.factor)
        let normal = f.threshold(base: 0.012, factor: Sensitivity.normal.factor)
        let high = f.threshold(base: 0.012, factor: Sensitivity.high.factor)
        #expect(low > normal && normal > high && high > 0.012)
        var cfg = VoiceConfig()
        cfg.apply(["sensitivity": "low"])
        #expect(cfg.sensitivityLevel == .low)
        cfg.apply(["sensitivity": "bogus"])
        #expect(cfg.sensitivityLevel == .low, "unknown values are ignored")
    }

    // MARK: Utterances in noise

    func taker(_ box: Box, pauseMs: Double = 1000, sensitivity: String = "normal", live: [(Int, String)] = []) -> TurnTaker {
        var cb = TurnCallbacks()
        cb.start = { box.events.append("start") }
        cb.silence = { box.events.append($0.map { "cue \(Int($0))" } ?? "cue off") }
        cb.noisy = { box.events.append($0 ? "noisy" : "quiet") }
        cb.transcript = { _ in box.events.append("transcript") }
        cb.ended = { (_: Double, _: Double) in box.events.append("ended") }
        var config = VoiceConfig()
        config.pauseMs = pauseMs
        config.sensitivity = sensitivity
        return TurnTaker(config: config, callbacks: cb) { cbs in
            let r = FakeRecognition(cbs, transcript: "hello there", live: live)
            box.recognitions.append(r)
            return r
        }
    }
    final class Box { var events: [String] = []; var recognitions: [FakeRecognition] = [] }

    @Test func steadyNoiseAboveTheOldThresholdNoLongerHoldsAnUtteranceOpen() {
        let box = Box(), t = taker(box), mic = FakeInput()
        mic.onPCM = { t.push($0) }
        mic.noise(60, rms: 0.018)            // the room: calibrates the floor, no utterance (0.018 > the old 0.012)
        #expect(box.events.isEmpty, "noise alone never opens an utterance: \(box.events)")
        #expect(abs(t.noiseFloor - 0.018) < 0.001 && t.threshold > 0.03)
        mic.frames(20, voiced: true)          // speech over the noise
        #expect(box.events == ["start"])
        mic.noise(60, rms: 0.018)            // the pause: only noise
        #expect(box.events.contains("ended"), "the pause is heard through the noise: \(box.events)")
        #expect(box.recognitions.first?.ended == true)
    }

    @Test func theOldFixedThresholdWouldHaveHeldItOpen() {
        // Same audio with the floor taken out of play (a noise floor of zero): 0.018 counts as voice forever.
        var config = VoiceConfig()
        config.pauseMs = 1000
        config.threshold = 0.012
        let box = Box()
        var cb = TurnCallbacks()
        cb.ended = { (_: Double, _: Double) in box.events.append("ended") }
        let t = TurnTaker(config: config, callbacks: cb) { FakeRecognition($0, transcript: "x") }
        let mic = FakeInput()
        mic.onPCM = { t.push($0) }
        // Speech first (so the utterance opens before any calibration), then noise at 0.018: with the floor frozen
        // inside an utterance it cannot raise the bar, but it can never fall below it either.
        mic.frames(20, voiced: true)
        mic.noise(120, rms: 0.018)
        #expect(!box.events.contains("ended"), "noise above the fixed threshold keeps it open (why the floor must be calibrated before speech)")
    }

    @Test func wordsStoppedEndsTheUtteranceThroughNoiseThatStaysVoiced() {
        // Noise that still counts as voice (louder than the floor ever saw): the live words stopping ends it.
        let box = Box()
        let live: [(Int, String)] = [(10, "please"), (20, "please say"), (30, "please say hello")]
        let t = taker(box, pauseMs: 1000, live: live)
        let mic = FakeInput()
        mic.onPCM = { t.push($0) }
        mic.frames(30, voiced: true)               // the live words arrive with audio frames 10, 20 and 30
        // Loud steady sound from here on (above the threshold), no new words: pauseMs (50 frames) after the last growth.
        mic.frames(24, voiced: true)               // 500 ms of no new words: the countdown starts
        #expect(box.events.contains("cue 500") && !box.events.contains("ended"), "\(box.events)")
        mic.frames(24, voiced: true)
        #expect(!box.events.contains("ended"))
        mic.frames(2, voiced: true)                // 1000 ms without new words
        #expect(box.events.contains("ended"), "the words stopped, not the sound: \(box.events)")
    }

    @Test func withoutLiveWordsEnergyAloneEndsIt() {
        let box = Box()
        let t = taker(box, pauseMs: 1000)
        let mic = FakeInput()
        mic.onPCM = { t.push($0) }
        mic.frames(30, voiced: true)
        mic.frames(60, voiced: true)               // no words ever: voiced audio keeps it open
        #expect(!box.events.contains("ended"))
        mic.frames(49, voiced: false)
        #expect(!box.events.contains("ended"))
        mic.frames(1, voiced: false)
        #expect(box.events.contains("ended"))
    }

    @Test func energySilenceStillEndsItWhenWordsAreStreaming() {
        let box = Box()
        // The last words are recognized a little after they are spoken (frame 40), so silence is first to run out.
        let t = taker(box, pauseMs: 1000, live: [(10, "hello"), (40, "hello there")])
        let mic = FakeInput()
        mic.onPCM = { t.push($0) }
        mic.frames(30, voiced: true)
        mic.frames(49, voiced: false)
        #expect(!box.events.contains("ended"))
        mic.frames(1, voiced: false)
        #expect(box.events.contains("ended"), "whichever comes first: \(box.events)")
    }

    @Test func aThinkingPauseOfAlmostPauseMsIsNotCutByTheWordsClock() {
        // The words take ~1 s to start again after a quiet gap; that lag must not count as "no new words".
        let box = Box()
        let live: [(Int, String)] = [(10, "so I was thinking"), (33, "so I was thinking about it"),
                                     (130, "so I was thinking about it and then"), (140, "so I was thinking about it and then some")]
        let t = taker(box, pauseMs: 1000, live: live)
        let mic = FakeInput()
        mic.onPCM = { t.push($0) }
        mic.frames(30, voiced: true)        // speech, words by frame 20
        mic.frames(45, voiced: false)       // a 900 ms thinking pause (< pauseMs)
        mic.frames(60, voiced: true)        // speech resumes; the first new words only at frame 130 (about 1 s later)
        #expect(!box.events.contains("ended"), "\(box.events)")
        mic.frames(20, voiced: true)
        #expect(!box.events.contains("ended"))
    }

    @Test func noisyRoomHintAfterTenSecondsWithoutADip() {
        let box = Box()
        let t = taker(box, pauseMs: 60_000)
        let mic = FakeInput()
        mic.onPCM = { t.push($0) }
        mic.frames(8, voiced: true)           // onset
        mic.frames(499, voiced: true)         // 499 frames without a 100 ms gap
        #expect(!box.events.contains("noisy"))
        mic.frames(1, voiced: true)           // 10 s
        #expect(box.events.contains("noisy"))
        mic.frames(6, voiced: false)         // 120 ms gap
        #expect(box.events.last == "quiet")
    }

    @Test func bargeInUsesTheAdaptiveThresholdToo() async {
        // Steady 0.02 noise raises the floor; it must not look like speech to the barge-in logic.
        let rig = Rig(duration: 2.0)
        await rig.start()
        rig.input.noise(120, rms: 0.02) // learn ambient before render; playback never trains the floor
        rig.reply(id: "m1", one)
        #expect(await waitUntil { rig.output.playing == [one] })
        rig.input.noise(120, rms: 0.02)
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(rig.output.plays.first?.outcome == "playing", "noise did not barge in")
        #expect(rig.controller.noiseFloorForLog > 0.015)
        rig.input.frames(30, voiced: true)   // real speech (0.17) still does
        #expect(await waitUntil { rig.output.plays.first?.outcome == "stopped" })
        rig.controller.stop()
    }

    @Test func micLogLineShowsTheFloorAndThreshold() async {
        let rig = Rig(duration: 3.0)
        await rig.start()
        rig.input.noise(100, rms: 0.018)
        rig.clock += 1000
        #expect(await waitUntil { rig.lines.contains { $0.hasPrefix("mic: rms avg 0.0180") && $0.contains("noise floor 0.018") && $0.contains("voiced threshold 0.03") } })
        rig.controller.stop()
    }

    // MARK: Settings and the hint

    @Test func sensitivityIsASettingAppliedLive() async throws {
        let rig = Rig(appFile: tempDir() + "/settings.json")
        await rig.start()
        let starts = rig.input.starts
        try await rig.controller.apply(.sensitivity("low"))
        #expect(rig.controller.voice.sensitivity == "low" && rig.input.starts == starts, "no restart")
        #expect((SettingsStore.readJSON(rig.controller.appFile)?["sensitivity"] as? String) == "low")
        await #expect(throws: (any Error).self) { try await rig.controller.apply(.sensitivity("extreme")) }
        rig.controller.stop()
    }

    @Test func noiseHintShowsInTheCardAndFades() {
        let r = PillRig()
        r.pill.handle(.noisy(true))
        #expect(r.pill.noiseHint && r.pill.expanded)
        r.advance(1000)
        #expect(r.pill.noiseHint, "stays while the room is loud")
        r.pill.handle(.noisy(false))
        r.advance(5000)
        #expect(r.pill.noiseHint, "and for a few seconds after, to be read")
        r.advance(1100)
        #expect(!r.pill.noiseHint)
    }

    @Test func controllerPassesTheNoiseSignalToThePill() async {
        let rig = Rig { $0.pauseMs = 60_000 }
        var events: [CaptionEvent] = []
        rig.controller.onCaption = { events.append($0) }
        await rig.start()
        rig.input.frames(520, voiced: true)
        #expect(events.contains(.noisy(true)))
        #expect(rig.lines.contains { $0.hasPrefix("noise: sound with no gap") })
        rig.controller.stop()
    }
}

@Suite(.serialized) @MainActor struct NoiseOnsetTests {
    final class Box { var events: [String] = [] }

    func taker(_ box: Box, pauseMs: Double = 1000, expectWords: Bool = false) -> TurnTaker {
        var cb = TurnCallbacks()
        cb.start = { box.events.append("start") }
        cb.noisy = { box.events.append($0 ? "noisy" : "quiet") }
        cb.idle = { box.events.append("idle") }
        var config = VoiceConfig()
        config.pauseMs = pauseMs
        let t = TurnTaker(config: config, callbacks: cb) { FakeRecognition($0, transcript: "") }
        t.expectLiveWords = expectWords
        return t
    }

    @Test func noisyRoomAtStartCannotOpenAnUtteranceDuringCalibration() {
        let box = Box(), t = taker(box), mic = FakeInput()
        mic.onPCM = { t.push($0) }
        mic.noise(49, rms: 0.03)
        #expect(box.events.isEmpty, "level unknown: only clearly loud sound counts for the first second")
        mic.noise(100, rms: 0.03)
        #expect(box.events.isEmpty, "calibrated: 0.03 is the room")
        #expect(abs(t.noiseFloor - 0.03) < 0.001)
        mic.frames(20, voiced: true)
        #expect(box.events == ["start"], "speech over the noise still opens one")
    }

    @Test func loudSpeechInTheFirstSecondStillCounts() {
        let box = Box(), t = taker(box), mic = FakeInput()
        mic.onPCM = { t.push($0) }
        mic.frames(10, voiced: true)
        #expect(box.events == ["start"])
    }

    @Test func noiseThatStartsLaterIsDroppedWhenNoWordsComeAndTheFloorLearnsIt() {
        // The room was quiet; a TV goes on at 0.03. It opens an utterance (the floor has not caught up), the recognizer
        // hears no word for 5 s, so it is dropped; the floor then rises and the noise stops counting.
        let box = Box(), t = taker(box, pauseMs: 3200, expectWords: true), mic = FakeInput()
        mic.onPCM = { t.push($0) }
        mic.noise(100, rms: 0.003)
        mic.noise(60, rms: 0.03)
        #expect(box.events.contains("start"))
        mic.noise(190, rms: 0.03)
        #expect(!box.events.contains("idle"))
        mic.noise(20, rms: 0.03)
        #expect(box.events.contains("idle"), "dropped after 5 s with no words: \(box.events)")
        #expect(box.events.contains("noisy") && box.events.contains("quiet"))
        // The level of that sound is now the floor: the noise stops counting as voice, no more false starts.
        #expect(t.noiseFloor > 0.025, "\(t.noiseFloor)")
        let starts = box.events.filter { $0 == "start" }.count
        mic.noise(400, rms: 0.03)
        #expect(box.events.filter { $0 == "start" }.count == starts, "no more false starts")
    }

    @Test func withoutLiveWordsLongNoiseTeachesTheFloorInsideTheUtterance() async {
        let box = Box(), t = taker(box, pauseMs: 1000, expectWords: false), mic = FakeInput()
        mic.onPCM = { t.push($0) }
        mic.noise(100, rms: 0.003)
        mic.noise(60, rms: 0.03)               // false start
        #expect(box.events.contains("start"))
        mic.noise(520, rms: 0.03)              // 10 s with no gap: noisy, the floor may rise now
        #expect(box.events.contains("noisy"))
        mic.noise(500, rms: 0.03)              // 10 s more: the floor has risen, the noise counts as silence, the pause ends it
        #expect(t.noiseFloor > 0.015, "\(t.noiseFloor)")
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(box.events.contains("idle") && !t.inUtterance, "the pause is heard once the floor has risen: \(box.events)")
    }
}
