import Foundation
import Testing
import AVFoundation
@testable import FloatingVoiceCore

private final class TimeoutInspectProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        // Real production URLSession request, inspected at its transport boundary.
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(String(request.timeoutInterval).utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite @MainActor struct SimulatorPreparationTests {
    @Test func actualRecordedEOFContinuesZeroBuffersWithoutEofError() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try WAV.encode(Data(repeating: 7, count: 128), sampleRate: 24000).write(to: url)
        let source = try AVAudioFile(forReading: url)
        let first = try CaptureConversion.fixtureBuffer(source)
        #expect(first.frameLength == 64 && source.framePosition == source.length)
        for _ in 0..<3 {
            let quiet = try CaptureConversion.fixtureBuffer(source)
            #expect(quiet.frameLength == 960)
            #expect((0..<Int(quiet.frameLength)).allSatisfy { quiet.floatChannelData![0][$0] == 0 })
        }
    }
    @Test(arguments: [44100.0, 48000.0]) func realCaptureFramingPreservesAlternatingSilenceAndSpeech(_ rate: Double) throws {
        let hardware = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false))
        let target = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true))
        let ingress = CaptureConversion(converter: try #require(AVAudioConverter(from: hardware, to: target)), target: target)
        var measured: [Double] = []
        for section in 0..<3 {
            for _ in 0..<50 {
                let size = AVAudioFrameCount(rate / 50)
                let buffer = try #require(AVAudioPCMBuffer(pcmFormat: hardware, frameCapacity: size))
                buffer.frameLength = size
                for i in 0..<Int(size) { buffer.floatChannelData![0][i] = section == 1 ? 0.2 : 0 }
                for frame in try ingress.convert(buffer) {
                    #expect(frame.count == TurnTaker.frameBytes)
                    measured.append(TurnTaker.rms(frame))
                }
            }
        }
        #expect((148...150).contains(measured.count))
        #expect(measured.prefix(40).allSatisfy { $0 < 0.001 })
        #expect(measured[60..<90].allSatisfy { abs($0 - 0.2) < 0.01 })
        #expect(measured.suffix(40).allSatisfy { $0 < 0.001 })
    }
    @Test func explicitJSONTimeoutDoesNotOverrideStreamIdlePolicy() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [TimeoutInspectProtocol.self]
        var request = URLRequest(url: URL(string: "https://synthetic.invalid/events")!)
        request.timeoutInterval = 30
        let stream = HTTPChunkStream(request, idleTimeout: 75, configuration: config)
        let bytes = try await stream.collect()
        #expect(String(data: bytes, encoding: .utf8) == "75.0")
    }
    @Test func readinessFailureUnwindsAndStoppedWaitCannotCloseReplacement() async throws {
        let capture = CaptureLifecycle()
        var closeCount = 0, deactivateCount = 0
        var pending: CheckedContinuation<Void, Error>?
        let old = Task {
            try await capture.start(permission: {}, activate: {}, open: { _ in },
                close: { closeCount += 1 }, deactivate: { deactivateCount += 1 },
                ready: { _ in try await withCheckedThrowingContinuation { pending = $0 } })
        }
        #expect(await waitUntil { pending != nil })
        capture.stop(close: { closeCount += 1 }, deactivate: { deactivateCount += 1 })
        try await capture.start(permission: {}, activate: {}, open: { _ in }, close: {}, deactivate: {})
        let replacement = capture.generation
        pending?.resume(throwing: ClientError("no samples"))
        do { try await old.value; Issue.record("old readiness should fail") } catch {}
        #expect(capture.admits(replacement) && closeCount == 1 && deactivateCount == 1)
        capture.stop(close: {}, deactivate: {})
        do {
            try await capture.start(permission: {}, activate: {}, open: { _ in },
                close: { closeCount += 1 }, deactivate: { deactivateCount += 1 },
                ready: { _ in throw ClientError("no samples") })
            Issue.record("missing PCM must not report capture ready")
        } catch {}
        #expect(!capture.capturing && closeCount == 2 && deactivateCount == 2)
    }
    @Test func simultaneousMeasuredLanesNeverHideInputBehindOutput() {
        let pill = PillModel(); pill.thinkingSwell = false
        var status = ConversationController.Status()
        status.running = true; status.phase = "ready"; status.connection = "connected"; status.speaking = true
        pill.update(status: status)
        pill.handle(.micLevel(0.1)); pill.handle(.outputLevel(0.2)); pill.tick()
        #expect(pill.micLevels.last == PillModel.normalize(0.1))
        #expect(pill.outputLevels.last == PillModel.normalize(0.2))
        pill.tick()
        #expect(pill.micLevels.last == 0 && pill.outputLevels.last == 0)
        pill.resetCaptions()
        #expect(pill.micLevels.allSatisfy { $0 == 0 } && pill.outputLevels.allSatisfy { $0 == 0 })
    }
}
