import Foundation
import AVFoundation
import Testing
@testable import FloatingVoiceCore

@Suite(.serialized) @MainActor struct RouteContinuityReviewTests {
    @Test func nativePauseResumesSamePartialBufferAndAlreadyQueuedNextBuffer() throws {
        let engine = AVAudioEngine(), player = AVAudioPlayerNode()
        let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
        engine.attach(player); engine.connect(player, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 256)
        try engine.start(); defer { engine.stop() }
        for value: Float in [0.2, 0.4] {
            let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!
            pcm.frameLength = 480
            for i in 0..<480 { pcm.floatChannelData![0][i] = value }
            player.scheduleBuffer(pcm)
        }
        player.play(at: AVAudioTime(sampleTime: 0, atRate: 24_000))
        try render(240, engine: engine, format: format)
        player.pause()
        for _ in 0..<8 { try render(240, engine: engine, format: format) }
        // No player.stop, node reconnect, new buffer scheduling, or synthesis.
        player.play(at: AVAudioTime(sampleTime: engine.manualRenderingSampleTime, atRate: 24_000))
        try render(240, engine: engine, format: format)
        let position = player.playerTime(forNodeTime: AVAudioTime(sampleTime: engine.manualRenderingSampleTime, atRate: 24_000))
        #expect(position?.sampleTime == 480)
        let next = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 240)!
        #expect(try engine.renderOffline(240, to: next) == .success)
        #expect(abs(next.floatChannelData![0][100] - 0.4) < 0.001)
    }
    @Test func rebuildBeforeFirstStreamingChunkLeavesRealNodeClockStopped() throws {
        let engine = AVAudioEngine(), player = AVAudioPlayerNode()
        let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
        engine.attach(player); engine.connect(player, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 256)
        try engine.start()
        defer { engine.stop() }
        let pcm = PlaybackContinuity(queue: PlaybackBufferScheduler()), signal = PlaybackSignalMeter()
        signal.begin(token: 1, graph: 1, rate: 24_000)
        _ = pcm.suspend(renderedFrames: nil) // Rebuild BEFORE the first streamed chunk.
        engine.stop(); player.stop(); try engine.start()
        pcm.resume(); signal.resume(graph: 2, base: pcm.position)
        var starts = 0
        let startedEmpty = pcm.startRetainedRun {
            player.play(at: AVAudioTime(sampleTime: engine.manualRenderingSampleTime, atRate: 24_000))
            signal.start(token: 1); starts += 1
        }
        #expect(!startedEmpty && !player.isPlaying && starts == 0)
        for _ in 0..<48 {
            try render(256, engine: engine, format: format) // 512 ms of delayed supply.
            let stamp = AVAudioTime(sampleTime: engine.manualRenderingSampleTime, atRate: 24_000)
            let idle = player.playerTime(forNodeTime: stamp).map { Int($0.sampleTime) }
            _ = signal.render(rms: 0, frames: 256, renderRate: 24_000, sourceFrame: idle,
                graph: 2, now: Double(engine.manualRenderingSampleTime) / 24_000)
        }
        #expect(signal.renderedPosition == nil && !player.isPlaying)

        let token = pcm.queue.schedule()!
        pcm.append(data(0..<4800), token: token)
        signal.source(data(0..<4800))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800))
        buffer.frameLength = 4800
        for i in 0..<4800 { buffer.floatChannelData![0][i] = 0.2 }
        let receipt = pcm.completionReceipt(for: pcm.segments[0])
        // .dataPlayedBack is device-only; offline uses the real rendered callback.
        player.scheduleBuffer(buffer, completionCallbackType: .dataRendered) { _ in receipt.record() }
        if pcm.queue.startIfNeeded() {
            player.play(at: AVAudioTime(sampleTime: engine.manualRenderingSampleTime, atRate: 24_000))
            signal.start(token: 1); starts += 1
        }
        try render(240, engine: engine, format: format) // Only 10 ms of actual source.
        // lastRenderTime can describe the START of the last block. Translate
        // the real engine's current end timestamp through the real player clock.
        let nodeNow = AVAudioTime(sampleTime: engine.manualRenderingSampleTime, atRate: 24_000)
        let clock = try #require(player.playerTime(forNodeTime: nodeNow))
        player.pause()
        #expect(clock.sampleTime == 240) // NEVER includes the 12288 idle frames.
        _ = pcm.suspend(renderedFrames: Int(clock.sampleTime))
        #expect(pcm.positionKnown && pcm.skippedFrames == 0 && pcm.position == 240)
        #expect(pcm.segments.reduce(0) { $0 + $1.pcm.count / 2 } == 4560)
        engine.stop(); player.stop(); try engine.start() // Second real rebuild.
        let suffix = pcm.segments[0]
        let resumed = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(suffix.pcm.count / 2))!
        resumed.frameLength = resumed.frameCapacity
        for i in 0..<Int(resumed.frameLength) { resumed.floatChannelData![0][i] = 0.2 }
        let completion = pcm.completionReceipt(for: suffix)
        player.scheduleBuffer(resumed, completionCallbackType: .dataRendered) { _ in completion.record() }
        pcm.resume(); signal.resume(graph: 3, base: pcm.position)
        #expect(pcm.startRetainedRun {
            player.play(at: AVAudioTime(sampleTime: engine.manualRenderingSampleTime, atRate: 24_000))
            signal.start(token: 1)
        })
        #expect(!pcm.queue.startIfNeeded())
        try render(240, engine: engine, format: format)
        let secondClock = try #require(player.playerTime(forNodeTime:
            AVAudioTime(sampleTime: engine.manualRenderingSampleTime, atRate: 24_000)))
        #expect(secondClock.sampleTime == 240)
        _ = pcm.suspend(renderedFrames: Int(secondClock.sampleTime))
        #expect(pcm.position == 480 && pcm.segments[0].first == 480 && pcm.skippedFrames == 0)
        #expect(starts == 1)
    }

    @Test func delayedActorCompletionsCannotReplayAlreadyFinishedBuffersWithUnknownClock() {
        let pcm = PlaybackContinuity(queue: PlaybackBufferScheduler())
        var receipts: [PlaybackContinuity.CompletionReceipt] = []
        for first in stride(from: 0, to: 160, by: 40) {
            pcm.append(data(first..<first+40), token: pcm.queue.schedule()!)
            receipts.append(pcm.completionReceipt(for: pcm.segments.last!))
        }
        let tokens = pcm.segments.map(\.token), oldRevision = pcm.revision
        // Audio callbacks happen, but only the FIRST bookkeeping Task reaches MainActor.
        let proofs = DispatchQueue.global().sync { receipts.prefix(3).map { $0.record() } }
        #expect(proofs == [true, true, true])
        pcm.completed(tokens[0], revision: oldRevision)
        var actual = Array(0..<133).map(UInt16.init) // Hardware has played 133, not just 40.
        let consumed = pcm.suspend(renderedFrames: nil)
        #expect(!pcm.positionKnown && pcm.position == 160 && pcm.skippedFrames == 40)
        #expect(consumed == Array(tokens.dropFirst()) && pcm.segments.isEmpty && pcm.queue.depth == 0)
        #expect(!pcm.completed(tokens[1], revision: oldRevision))
        #expect(!receipts[3].record(), "stop/late callbacks from the retired run cannot prove unplayed data")
        pcm.resume()
        pcm.append(data(160..<200), token: pcm.queue.schedule()!) // Continue existing producer/carry to EOF.
        actual += samples(pcm.segments[0].pcm)
        let currentReceipt = pcm.completionReceipt(for: pcm.segments[0])
        #expect(currentReceipt.record())
        pcm.completed(pcm.segments[0].token, revision: pcm.revision)
        #expect(actual == Array(0..<133).map(UInt16.init) + Array(160..<200).map(UInt16.init))
        #expect(Set(actual).count == actual.count && 200 - actual.count == 27)
        #expect(pcm.skippedFrames == 40 && pcm.queue.depth == 0 && pcm.position == 200)
    }

    @Test func callbackProofIsMonotonicDuplicateSafeAndRevisionFenced() {
        let pcm = PlaybackContinuity(queue: PlaybackBufferScheduler())
        for first in stride(from: 0, to: 160, by: 40) { pcm.append(data(first..<first+40), token: pcm.queue.schedule()!) }
        let receipts = pcm.segments.map { pcm.completionReceipt(for: $0) }
        // Completion dispatch may reorder callbacks; later completed audio proves its prefix.
        #expect(receipts[2].record() && receipts[0].record() && !receipts[2].record())
        _ = pcm.suspend(renderedFrames: 133)
        #expect(pcm.position == 133 && pcm.positionKnown && pcm.skippedFrames == 0)
        #expect(pcm.segments.count == 1 && pcm.segments[0].first == 133)
        let resumed = pcm.segments[0]
        pcm.resume()
        let nextReceipt = pcm.completionReceipt(for: resumed)
        #expect(!receipts[3].record()) // Same token, OLD revision: cannot advance this run.
        #expect(nextReceipt.record() && !nextReceipt.record())
        _ = pcm.suspend(renderedFrames: nil)
        #expect(pcm.position == 160 && pcm.positionKnown && pcm.skippedFrames == 0 && pcm.segments.isEmpty)
        pcm.resume(); pcm.cancel()
        #expect(!nextReceipt.record())
    }

    private func render(_ frames: AVAudioFrameCount, engine: AVAudioEngine, format: AVAudioFormat) throws {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        #expect(try engine.renderOffline(frames, to: buffer) == .success)
    }
    private func data(_ frames: Range<Int>) -> Data {
        frames.reduce(into: Data()) { $0.append(UInt8($1 & 255)); $0.append(UInt8($1 >> 8)) }
    }
    private func samples(_ pcm: Data) -> [UInt16] {
        let bytes = [UInt8](pcm)
        return stride(from: 0, to: bytes.count, by: 2).map { UInt16(bytes[$0]) | UInt16(bytes[$0+1]) << 8 }
    }
}
