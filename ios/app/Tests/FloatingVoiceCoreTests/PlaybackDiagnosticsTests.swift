import Foundation
import Testing
@testable import FloatingVoiceCore

private final class TTSMetricsProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let head = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["X-Test-Attempt": request.value(forHTTPHeaderField: "X-FV-Attempt") ?? ""])!
        client?.urlProtocol(self, didReceive: head, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data([1, 2])); client?.urlProtocol(self, didLoad: Data([3, 4, 5]))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite struct PlaybackDiagnosticsTests {
    @Test func realHTTPDelegateLogsFirstBodyByteAndCompletionWithAttemptAndOriginalCall() async throws {
        let log = StageDiagnostics(); log.beginCall()
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [TTSMetricsProtocol.self]
        let request = URLRequest(url: URL(string: "https://synthetic.invalid/tts/v1/audio/speech")!)
        let stream = HTTPChunkStream(request, idleTimeout: 1, configuration: config, ttsStreaming: true, diagnostics: log)
        log.beginCall()
        let head = try await stream.headers()
        #expect(head.value(forHTTPHeaderField: "X-Test-Attempt") == stream.requestAttempt.uuidString)
        #expect(try await stream.collect() == Data([1, 2, 3, 4, 5]))
        let rows = try JSONDecoder().decode([DiagnosticEntry].self, from: Data(log.export().utf8)).filter { $0.attempt == stream.requestAttempt }
        #expect(rows.allSatisfy { $0.diagnosticCall == 1 })
        #expect(rows.filter { $0.playbackEvent == .ttsFirstByte }.count == 1)
        let completed = try #require(rows.first { $0.playbackEvent == .ttsComplete })
        #expect(completed.audio?.values["bytesReceived"] == 5)
        #expect(completed.audio?.values["streaming"] == 1)
        #expect((completed.audio?.values["firstByteMs"] ?? -1) >= 0)
    }
    @Test func transferMeasuresArrivalBytesFirstByteAndBoundedP95NotConsumerDelay() {
        var timing = AudioTransferTiming(now: 10)
        #expect(timing.fields(now: 11)[.firstByteMs] == -1)
        let empty = timing.receive(bytes: 0, now: 10), first = timing.receive(bytes: 100, now: 10.5)
        #expect(!empty && first)
        for i in 1...19 { let first = timing.receive(bytes: 100, now: 10.5 + Double(i) / 8); #expect(!first) }
        timing.receive(bytes: 100, now: 14.875) // 2s outlier, after nineteen125ms gaps
        let fields = timing.fields(now: 20) // Consumption may happen much later; gaps do not change.
        #expect(fields[.bytesReceived] == 2100 && fields[.chunksReceived] == 21)
        #expect(fields[.firstByteMs] == 500 && fields[.requestTotalMs] == 10_000)
        #expect(fields[.chunkGapP95Ms] == 125 && fields[.chunkGapMaxMs] == 2000)
        #expect(fields[.chunkGapSamples] == 20 && fields[.chunkGapClipped] == 0)
    }
    @Test func transferEmptyAndClippedGapAreExplicit() {
        var timing = AudioTransferTiming(now: 0)
        #expect(timing.fields(now: 1)[.bytesReceived] == 0)
        timing.receive(bytes: 2, now: 1); timing.receive(bytes: 2, now: 21)
        #expect(timing.fields(now: 22)[.chunkGapP95Ms] == 10_000)
        #expect(timing.fields(now: 22)[.chunkGapMaxMs] == 20_000)
        #expect(timing.fields(now: 22)[.chunkGapClipped] == 1)
    }
    @Test func fourBufferDrainThenRefillIsCountedWithoutChangingQueuePolicy() {
        var queue = PlaybackQueueCounter()
        for i in 1...4 { let gap = queue.schedule(now: 0); #expect(gap == nil); #expect(queue.depth == i) }
        for _ in 1...3 { let empty = queue.played(now: 1, moreExpected: true); #expect(!empty) }
        let empty = queue.played(now: 1, moreExpected: true), gap = queue.schedule(now: 1.125)
        #expect(empty && gap == 125)
        #expect(queue.starvationCount == 1 && queue.starvationMaxMs == 125)
        let final = queue.played(now: 2, moreExpected: false)
        #expect(!final) // Final drain is not starvation.
    }
    @Test func eofOrCancellationClosesCandidateWithoutCountingARefill() {
        var queue = PlaybackQueueCounter()
        _ = queue.schedule(now: 0); queue.played(now: 1, moreExpected: true)
        let gap = queue.closeGap(now: 1.5, count: false)
        #expect(gap == 500)
        #expect(queue.starvationCount == 0)
        let next = queue.schedule(now: 2); #expect(next == nil)
    }
    @Test func renderCountsOnlySignalBoundedOver80msAndIgnoresAttackAndTail() {
        let meter = RenderDropoutMeter(); meter.begin(token: 1, graph: 10)
        meter.consume(rms: 0, frames: 4800, rate: 48000, graph: 10) // Initial100ms.
        meter.consume(rms: 0.1, frames: 960, rate: 48000, graph: 10)
        meter.consume(rms: 0, frames: 3840, rate: 48000, graph: 10) // Exactly80: not over.
        meter.consume(rms: 0.1, frames: 960, rate: 48000, graph: 10)
        for _ in 0..<4 { meter.consume(rms: 0, frames: 1024, rate: 48000, graph: 10) }
        meter.consume(rms: 0.1, frames: 960, rate: 48000, graph: 10)
        meter.consume(rms: 0, frames: 48000, rate: 48000, graph: 10) // Trailing second is excluded.
        let counts = meter.end(token: 1)
        #expect(counts.count == 1)
        #expect(abs(counts.maxMs - 85.3333333) < 0.001)
    }
    @Test func staleRenderGraphOrTokenCannotContaminateNewUtterance() {
        let meter = RenderDropoutMeter(); meter.begin(token: 2, graph: 20)
        meter.consume(rms: 0.1, frames: 960, rate: 48000, graph: 20)
        meter.consume(rms: 0, frames: 48000, rate: 48000, graph: 19)
        #expect(meter.end(token: 1).count == 0) // Must not stop token2.
        meter.consume(rms: 0, frames: 4800, rate: 48000, graph: 20)
        meter.consume(rms: 0.1, frames: 960, rate: 48000, graph: 20)
        #expect(meter.end(token: 2).count == 1)
        meter.begin(token: 3, graph: 30); meter.suspend()
        meter.consume(rms: 0.1, frames: 960, rate: 48000, graph: 30)
        #expect(meter.end(token: 3).count == 0)
    }
    @Test func invalidOrUnsupportedRenderBuffersAreNotMistakenForDigitalSilence() {
        let meter = RenderDropoutMeter(); meter.begin(token: 1, graph: 1)
        meter.consume(rms: 0.1, frames: 960, rate: 48000, graph: 1)
        meter.consume(rms: .nan, frames: 4800, rate: 48000, graph: 1)
        meter.consume(rms: 0, frames: 4800, rate: 48000, graph: 1, valid: false)
        meter.consume(rms: 0.1, frames: 960, rate: 48000, graph: 1)
        let counts = meter.end(token: 1)
        #expect(counts.invalidBuffers == 2 && counts.count == 0)
    }
    @Test func asyncPlaybackAndTTSKeepOriginalCallBankAndCannotResurrectExpiredCalls() throws {
        let log = StageDiagnostics(); log.beginCall(); let first = log.playbackCallToken
        log.recordPlayback(.scheduled, fields: [.queueDepth: 4], callToken: first)
        log.beginCall()
        log.record(.tts, .complete, audio: CaptureSnapshot([.bytesReceived: 100]), playbackEvent: .ttsComplete, callBank: first)
        for _ in 0..<600 { log.record(.state, .complete) }
        log.flushPlaybackDiagnostics()
        var rows = try JSONDecoder().decode([DiagnosticEntry].self, from: Data(log.export().utf8))
        #expect(rows.contains { $0.diagnosticCall == first && $0.playbackEvent == .scheduled })
        #expect(rows.contains { $0.diagnosticCall == first && $0.playbackEvent == .ttsComplete })
        log.beginCall()
        log.recordPlayback(.utteranceEnd, fields: [:], callToken: first); log.flushPlaybackDiagnostics()
        rows = try JSONDecoder().decode([DiagnosticEntry].self, from: Data(log.export().utf8))
        #expect(!rows.contains { $0.diagnosticCall == first })
    }
    @Test func pendingDiagnosticsAreBoundedAndAnyDropsAreExplicitNumericCounts() throws {
        let log = StageDiagnostics(); log.beginCall()
        for i in 0..<512 { log.recordPlayback(.scheduled, fields: [.utteranceOrdinal: Double(i)]) }
        log.flushPlaybackDiagnostics()
        log.recordPlayback(.utteranceEnd, fields: [:]); log.flushPlaybackDiagnostics()
        let rows = try JSONDecoder().decode([DiagnosticEntry].self, from: Data(log.export().utf8)).filter { $0.stage == .playback }
        let dropped = rows.reduce(0) { $0 + Int($1.audio?.values[CaptureField.diagnosticsDropped.rawValue] ?? 0) }
        #expect(rows.count + dropped == 513)
        #expect(!log.export().contains("http") && !log.export().contains("sentence text"))
    }
}
