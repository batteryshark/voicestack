import Foundation
import Testing
import AVFoundation
@testable import FloatingVoiceCore

@Suite(.serialized) @MainActor struct PlaybackBufferSchedulerTests {
    @Test func productionLowWaterAvoidsOld125msRefillGapAcrossSixteenBuffers() throws {
        let old = VirtualPlayback(lowWater: 0), current = VirtualPlayback()
        try old.run(); try current.run()
        #expect(old.gaps == [125, 125, 125])
        #expect(current.gaps.isEmpty)
        for player in [old, current] {
            #expect(player.maximumDepth == 4 && player.starts == 1)
            #expect(player.playedFrames == Array(0..<76_800))
            #expect(player.finishedAt >= player.lastPlayedAt)
            #expect(player.scheduler.depth == 0 && player.finished)
            #expect(player.maximumBufferFrames == 4800)
        }
        #expect(current.finishedAt == 3200 && current.finishedAt == current.lastPlayedAt)
        // Old refill wait also delays discovering EOF after its final full batch.
        #expect(old.lastPlayedAt == 3575 && old.finishedAt == 3700)
    }
    @Test func eofWaitsForTrueDrainIncludingHighWaterAndOneBufferTails() throws {
        for frames in [0, 1, 4800, 19_200, 19_201, 24_000] {
            let player = VirtualPlayback(frames: frames, resumeDelay: 0)
            try player.run()
            #expect(player.finished && player.scheduler.depth == 0)
            #expect(player.playedFrames == Array(0..<frames))
            #expect(player.finishedAt == player.lastPlayedAt)
            #expect(player.starts == (frames == 0 ? 0 : 1))
        }
    }
    @Test func streamingTinyOddChunksKeepOrderCapAndReportSupplyGaps() throws {
        let tiny = VirtualPlayback(frames: 241, chunkBytes: [1, 3, 7, 2, 13], resumeDelay: 0)
        try tiny.run()
        #expect(tiny.playedFrames == Array(0..<241) && tiny.starts == 1)
        #expect(tiny.maximumDepth <= 4 && tiny.maximumBufferFrames <= 4800)
        #expect(tiny.finishedAt == tiny.lastPlayedAt)
        let stream = VirtualPlayback(frames: 28_800, chunkBytes: [19_200], resumeDelay: 0,
                                     arrivals: [0, 600, 1200])
        try stream.run()
        #expect(stream.playedFrames == Array(0..<28_800) && stream.finished)
        #expect(!stream.supplyGaps.isEmpty && stream.maximumDepth <= 4)
        #expect(stream.starts == 1)
    }
    @Test func reserveExhaustionIsMeasuredNotHidden() throws {
        let player = VirtualPlayback(resumeDelay: 325)
        try player.run()
        #expect(!player.gaps.isEmpty && player.gaps.allSatisfy { $0 == 125 })
        #expect(player.playedFrames == Array(0..<76_800))
    }
    @Test func separateWaitersStopExactlyOnceAndRejectDuplicateAndForeignCallbacks() {
        let queue = PlaybackBufferScheduler()
        let tokens = (0..<4).map { _ in queue.schedule()! }
        #expect(queue.schedule() == nil)
        var capacity = 0, drain = 0
        queue.played(tokens[0]) // Completion before waiter registration is not a lost wake.
        queue.whenCapacityAvailable { capacity += 1 }
        queue.whenDrained { drain += 1 }
        queue.played(tokens[1])
        #expect(capacity == 0 && drain == 0)
        queue.played(tokens[2])
        #expect(capacity == 1 && drain == 0 && queue.depth == 1)
        #expect(!queue.played(tokens[2]))
        queue.cancel(); queue.cancel()
        #expect(capacity == 1 && drain == 1 && queue.depth == 0)
        #expect(!queue.played(tokens[3]) && queue.schedule() == nil)
        let replacement = PlaybackBufferScheduler(), fresh = replacement.schedule()!
        #expect(!replacement.played(tokens[0]) && replacement.depth == 1)
        #expect(replacement.played(fresh))
    }
    @Test func stopWhileCapacityBlockedAndStaleCallbacksCannotRestartProducer() throws {
        let player = VirtualPlayback()
        try player.step() // Four scheduled, producer blocked.
        let stale = player.buffers.map(\.token)
        player.stop()
        for _ in 0..<1000 { try player.step() }
        #expect(player.maximumDepth == 4 && player.scheduler.depth == 0)
        #expect(player.starts == 1 && player.playedFrames.count == 24 && !player.finished)
        for token in stale { #expect(!player.scheduler.played(token)) }
    }
    @Test func taskCancellationReleasesCapacityAndFinalDrainWithoutPlaybackCallbacks() async {
        for draining in [false, true] {
            let queue = PlaybackBufferScheduler()
            for _ in 0..<(draining ? 1 : 4) { _ = queue.schedule() }
            let task = Task { @MainActor in
                do {
                    if draining { try await queue.waitForDrain() }
                    else { try await queue.waitForCapacity() }
                    return false
                } catch is CancellationError { return true }
                catch { return false }
            }
            await Task.yield()
            task.cancel()
            #expect(await task.value)
        }
    }
    @Test func queueStopReleasesWaitWithoutErasingNativeRecoverableEpochCause() async {
        for draining in [false, true] {
            let queue = PlaybackBufferScheduler()
            for _ in 0..<(draining ? 1 : 4) { _ = queue.schedule() }
            let waiter = Task { @MainActor in
                do {
                    if draining { try await queue.waitForDrain() }
                    else { try await queue.waitForCapacity() }
                    return true // Native checkPlayback(owner) still classifies repair/stop next.
                } catch { return false }
            }
            await Task.yield(); queue.cancel()
            #expect(await waiter.value)
        }
    }
    @Test func offlineContinuousToneExposesOldInternalGapAndNewQueueHasNone() throws {
        let oldRenderer = try OfflineToneRenderer(), newRenderer = try OfflineToneRenderer()
        let old = VirtualPlayback(lowWater: 0), current = VirtualPlayback()
        old.render = { try oldRenderer.render() }; current.render = { try newRenderer.render() }
        old.scheduleTone = { try oldRenderer.schedule(first: $0, frames: $1) }
        current.scheduleTone = { try newRenderer.schedule(first: $0, frames: $1) }
        try old.run(); try current.run()
        let oldGaps = toneGaps(old.rendered), newGaps = toneGaps(current.rendered)
        #expect(oldGaps.count >= 3 && oldGaps.maxMs > 80)
        #expect(newGaps.count == 0)
        #expect(old.gaps == [125, 125, 125] && current.gaps.isEmpty)
    }

    private func toneGaps(_ samples: [Float]) -> RenderDropoutMeter.Counts {
        let meter = RenderDropoutMeter(); meter.begin(token: 1, graph: 1)
        for start in stride(from: 0, to: samples.count, by: 240) {
            let block = samples[start..<min(start + 240, samples.count)]
            let rms = sqrt(block.reduce(0.0) { $0 + Double($1 * $1) } / Double(block.count))
            meter.consume(rms: rms, frames: block.count, rate: 24_000, graph: 1)
        }
        return meter.end(token: 1)
    }
}

/// Virtual player/producer, not a second implementation of watermark decisions.
/// All capacity, completion, final-drain and stop decisions use production code.
@MainActor private final class VirtualPlayback {
    struct Buffer { let token: PlaybackBufferScheduler.Token; var next: Int; let end: Int }
    let scheduler: PlaybackBufferScheduler
    let totalFrames: Int, resumeDelay: Int, chunkBytes: [Int], arrivals: [Int]
    var buffers: [Buffer] = []
    var now = 0, bytesRead = 0, carry = 0, nextFrame = 0, chunkIndex = 0
    var producerAt: Int? = 0
    var blocked = false, stopped = false, eof = false
    var finished = false, finishedAt = 0, lastPlayedAt = 0
    var maximumDepth = 0, maximumBufferFrames = 0, starts = 0
    var playedFrames: [Int] = [], gaps: [Int] = [], supplyGaps: [Int] = []
    var emptyAt: Int?, emptyWithReadyPCM = false
    var scheduleTone: ((Int, Int) throws -> Void)?
    var render: (() throws -> [Float])?
    var rendered: [Float] = []
    init(lowWater: Int = 1, frames: Int = 76_800, chunkBytes: [Int] = [153_600],
         resumeDelay: Int = 125, arrivals: [Int] = []) {
        scheduler = PlaybackBufferScheduler(lowWater: lowWater)
        totalFrames = frames; self.resumeDelay = resumeDelay
        self.chunkBytes = chunkBytes; self.arrivals = arrivals
    }
    func run() throws {
        while !finished && now < 20_000 { try step() }
        #expect(finished, "Virtual playback stalled")
    }
    func pump() throws {
        guard !stopped, !eof else { return }
        while true {
            if carry < 2 {
                if bytesRead == totalFrames * 2 {
                    eof = true
                    scheduler.whenDrained { self.finished = true; self.finishedAt = self.now }
                    return
                }
                let arrival = arrivals.isEmpty ? 0 : arrivals[min(chunkIndex, arrivals.count - 1)]
                if now < arrival { producerAt = arrival; return }
                let bytes = min(chunkBytes[chunkIndex % chunkBytes.count], totalFrames * 2 - bytesRead)
                bytesRead += bytes; carry += bytes; chunkIndex += 1
                continue
            }
            let frames = PlaybackBufferScheduler.frameCount(bytes: carry, sampleRate: 24_000)
            guard let token = scheduler.schedule() else { Issue.record("Producer exceeded cap"); return }
            if let since = emptyAt {
                if emptyWithReadyPCM { gaps.append(now - since) } else { supplyGaps.append(now - since) }
                emptyAt = nil
            }
            try scheduleTone?(nextFrame, frames)
            buffers.append(Buffer(token: token, next: nextFrame, end: nextFrame + frames))
            nextFrame += frames; carry -= frames * 2
            maximumBufferFrames = max(maximumBufferFrames, frames)
            maximumDepth = max(maximumDepth, scheduler.depth)
            if scheduler.startIfNeeded() { starts += 1 }
            if scheduler.depth == PlaybackBufferScheduler.highWater {
                blocked = true
                scheduler.whenCapacityAvailable {
                    if !self.stopped { self.producerAt = self.now + self.resumeDelay }
                }
                return
            }
        }
    }
    func step() throws {
        guard !stopped else { now += 1; return }
        if let due = producerAt, due <= now { producerAt = nil; blocked = false; try pump() }
        if finished { return }
        if let render { rendered.append(contentsOf: try render()) }
        var available = 24 // One ms of hardware playback, independent of producer scheduling.
        while available > 0, !buffers.isEmpty {
            let count = min(available, buffers[0].end - buffers[0].next)
            playedFrames.append(contentsOf: buffers[0].next..<(buffers[0].next + count))
            buffers[0].next += count; available -= count
            if buffers[0].next == buffers[0].end {
                let token = buffers.removeFirst().token
                // Completion at the end of this rendered millisecond.
                now += 1; lastPlayedAt = now
                scheduler.played(token)
                now -= 1
            }
        }
        now += 1
        if buffers.isEmpty, !finished, emptyAt == nil {
            emptyAt = now
            emptyWithReadyPCM = carry >= 2 || (bytesRead < totalFrames * 2 &&
                (arrivals.isEmpty || arrivals[min(chunkIndex, arrivals.count - 1)] <= now))
        }
    }
    func stop() { stopped = true; buffers.removeAll(); scheduler.cancel(); producerAt = nil }
}

/// Real AVAudioEngine manual/offline rendering: no device, microphone or network.
/// The virtual producer schedules actual tone buffers via the production queue.
@MainActor private final class OfflineToneRenderer {
    let engine = AVAudioEngine(), player = AVAudioPlayerNode()
    let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
    init() throws {
        engine.attach(player); engine.connect(player, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 240)
        try engine.start(); player.play()
    }
    deinit { engine.stop() }
    func schedule(first: Int, frames: Int) throws {
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        for i in 0..<frames { buffer.floatChannelData![0][i] = Float(0.2 * sin(2 * .pi * 440 * Double(first + i) / 24_000)) }
        player.scheduleBuffer(buffer)
    }
    func render() throws -> [Float] {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 24)!
        let status = try engine.renderOffline(24, to: buffer)
        #expect(status == .success)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }
}
