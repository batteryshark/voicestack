import Foundation
import Testing
@testable import FloatingVoiceCore

@Suite(.serialized) @MainActor struct VoiceTurnDiagnosticTests {
    func opened() -> (TurnTaker, FakeInput, FakeRecognition, StageDiagnostics) {
        var cfg = VoiceConfig(); cfg.pauseMs = 3200
        var recognition: FakeRecognition!
        let log = StageDiagnostics()
        let turn = TurnTaker(config: cfg, callbacks: TurnCallbacks()) {
            recognition = FakeRecognition($0, transcript: ""); return recognition
        }
        turn.diagnostics = log
        let mic = FakeInput(); mic.onPCM = { turn.push($0) }
        mic.frames(30, voiced: true)
        return (turn, mic, recognition, log)
    }
    func reasons(_ log: StageDiagnostics) throws -> [TurnEndReason] {
        try JSONDecoder().decode([DiagnosticEntry].self, from: Data(log.export().utf8)).compactMap(\.turnEndReason)
    }

    @Test func naturalEnergyPauseAndWordsStoppedAreDistinct() throws {
        let (turn, mic, _, log) = opened()
        mic.frames(160, voiced: false)
        #expect(try reasons(log) == [.pause])
        turn.stop()
        let (words, input, rec, wordsLog) = opened()
        rec.callbacks.live("These words stopped growing")
        input.frames(160, voiced: true)
        #expect(try reasons(wordsLog) == [.wordsStopped])
        words.stop()
    }

    @Test(arguments: [TurnEndReason.manualSend, .muteSend, .stop])
    func explicitEndReasons(_ reason: TurnEndReason) throws {
        let (turn, _, _, log) = opened()
        if reason == .stop { turn.stop() } else { turn.endNow(reason: reason) }
        #expect(try reasons(log) == [reason])
        turn.stop()
    }

    @Test func finalTimeoutAndDiscontinuityAreExportedWithoutErrorText() async throws {
        let (turn, _, rec, log) = opened()
        rec.silentEnd = true; turn.finalTimeout = 0.01
        turn.endNow()
        #expect(await waitUntil { (try? reasons(log).last) == .finalTimeout })
        #expect(try reasons(log) == [.manualSend, .finalTimeout])
        turn.stop()
        let (broken, _, failure, failedLog) = opened()
        failure.callbacks.error(ClientError("private words must never enter stage diagnostics"))
        #expect(try reasons(failedLog) == [.discontinuity])
        #expect(!failedLog.export().contains("private words"))
        broken.stop()
    }

    @Test func stageExportIsClosedAndBackwardCompatible() throws {
        let log = StageDiagnostics()
        for reason in [TurnEndReason.pause, .wordsStopped, .finalTimeout, .manualSend, .muteSend, .discontinuity, .stop] {
            log.record(.utterance, .complete, turnEndReason: reason)
        }
        let entries = try JSONDecoder().decode([DiagnosticEntry].self, from: Data(log.export().utf8))
        #expect(entries.count == 7 && entries.allSatisfy { $0.stage == .utterance && $0.turnEndReason != nil })
        var old = try JSONSerialization.jsonObject(with: Data(log.export().utf8)) as! [[String: Any]]
        for i in old.indices { old[i].removeValue(forKey: "turnEndReason") }
        let decoded = try JSONDecoder().decode([DiagnosticEntry].self, from: JSONSerialization.data(withJSONObject: old))
        #expect(decoded.allSatisfy { $0.turnEndReason == nil })
    }

    @Test func roomGapSchedulePreservesEveryGapSampleAcrossTapBoundaries() {
        let rate = 48000
        let schedule = SpeechGapSchedule(firstFrames: 12345, gapFrames: rate * 5 / 2, secondFrames: 23456)
        var gapSamples = 0, firstSamples = 0, secondSamples = 0
        // Deliberately cross phrase/gap boundaries inside 960-frame hardware buffers.
        for buffer in stride(from: 0, to: 12345 + rate * 5 / 2 + 23456 + 960, by: 960) {
            for i in buffer..<buffer+960 {
                switch schedule.source(at: i) {
                case .first: firstSamples += 1
                case .gap: gapSamples += 1 // native real-room mode must not overwrite this sample
                case .second: secondSamples += 1
                case .finished: break
                }
            }
        }
        #expect(firstSamples == 12345 && secondSamples == 23456 && gapSamples == 120000)
        #expect(schedule.source(at: 12344) == .first(12344))
        #expect(schedule.source(at: 12345) == .gap)
        #expect(schedule.source(at: 132344) == .gap)
        #expect(schedule.source(at: 132345) == .second(0))
    }
}
