import Foundation
import Testing
@testable import FloatingVoiceCore

@Suite(.serialized) @MainActor struct RecognitionDeadlineWireTests {
    func fixture() throws -> (Process, Int) {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        let script = Bundle.module.url(forResource: "stt-deadline", withExtension: "mjs", subdirectory: "Fixtures")!
        process.arguments = ["node", script.path]; process.standardOutput = pipe
        try process.run()
        let port = try #require(Int(String(decoding: pipe.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
        try #require(![8444, 8446, 8450].contains(port))
        return (process, port)
    }

    @Test func realWireFinalAfterEightSecondsDeliversOnceWithOwnedFeedback() async throws {
        let (process, port) = try fixture()
        defer { process.terminate(); process.waitUntilExit() }
        var finals: [String] = [], errors = 0, feedback: [Bool] = []
        var cb = TurnCallbacks(); cb.transcript = { finals.append($0) }; cb.error = { _ in errors += 1 }; cb.transcribing = { feedback.append($0) }
        let t = TurnTaker(config: VoiceConfig(), callbacks: cb) { callbacks in
            HealthCheckedRecognition(endpoint: "ws://fixture", key: nil, callbacks: callbacks, warmup: SpeechWarmup(), probe: { _, _ in .loaded }) {
                WebSocketRecognition(url: "ws://127.0.0.1:\(port)/slow", apiKey: nil, callbacks: $0)
            }
        }
        defer { t.stop() }
        t.push(Data(count: 640 * 50)); for _ in 0..<12 { t.push(FakeInput.tone) }; t.endNow()
        #expect(await waitUntil(12) { finals.count == 1 || errors > 0 })
        #expect(finals == ["Whole wire thought."] && errors == 0 && feedback == [true, false])
        let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/stats")!)
        let stats = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Int]])
        #expect(stats.count == 1 && stats[0]["ends"] == 1 && stats[0]["bytes"] == 640 * 54)
    }

    @Test func productionWriteCompletionAndExistingClosureProtocol() async throws {
        let (process, port) = try fixture()
        defer { process.terminate(); process.waitUntilExit() }
        for mode in ["delta", "empty", "abnormal", "early"] {
            var finals: [String] = [], partials: [String] = [], errors = 0
            let cb = RecognitionCallbacks(partial: { partials.append($0) }, error: { _ in errors += 1 }, done: { finals.append($0) })
            let r = WebSocketRecognition(url: "ws://127.0.0.1:\(port)/\(mode)", apiKey: nil, callbacks: cb)
            r.start()
            if mode != "early" {
                // Exercise both async admitted and queued direct PCM before the end frame.
                try await r.writeBuffered(Data(count: 640))
                for _ in 0..<20 { r.write(Data(count: 640)) }
                r.end()
                _ = try await r.waitForEndTransmission()
            }
            if mode == "delta" {
                #expect(await waitUntil { !partials.isEmpty })
                #expect(finals.isEmpty, "transcript delta is not a terminal event")
            }
            #expect(await waitUntil { finals.count == 1 })
            #expect(finals == [mode == "delta" ? "First second." : mode == "early" ? "Early final." : ""])
            #expect(errors == (mode == "abnormal" ? 1 : 0))
            r.cancel()
            #expect(finals.count == 1)
        }
        let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/stats")!)
        let stats = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Int]])
        #expect(stats.prefix(3).allSatisfy { $0["bytes"] == 21 * 640 && $0["ends"] == 1 })
    }
}
