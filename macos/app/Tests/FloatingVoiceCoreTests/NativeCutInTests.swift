import Foundation
import AVFoundation
import Testing
@testable import FloatingVoiceCore
@testable import FloatingVoiceAudio

@Suite(.serialized) @MainActor struct NativeCutInTests {
    // Reviewed RouteContinuityReviewTests nativePause regression, now driving MacAudio hooks.
    @Test func nativePauseResumesSamePartialBufferAndAlreadyQueuedNextBuffer() throws {
        let engine = AVAudioEngine(), player = AVAudioPlayerNode()
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        engine.attach(player); engine.connect(player, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 256)
        try engine.start(); defer { engine.stop() }
        let audio = MacAudio(offlineEngine: engine, player: player)
        for value: Float in [0.2, 0.4] {
            let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!
            pcm.frameLength = 480
            for i in 0..<480 { pcm.floatChannelData![0][i] = value }
            player.scheduleBuffer(pcm)
        }
        func render() throws -> [Float] {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 240)!
            #expect(try engine.renderOffline(240, to: buffer) == .success)
            return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: 240))
        }
        player.play(at: AVAudioTime(sampleTime: 0, atRate: 48_000))
        #expect(try render().allSatisfy { abs($0 - 0.2) < 0.000001 })
        #expect(audio.pauseForAutomaticCutIn())
        for _ in 0..<8 { #expect(try render().allSatisfy { $0 == 0 }) }
        try audio.resumeAfterAutomaticCutIn()
        #expect(try render().allSatisfy { abs($0 - 0.2) < 0.000001 })
        let position = player.playerTime(forNodeTime: AVAudioTime(sampleTime: engine.manualRenderingSampleTime, atRate: 48_000))
        #expect(position?.sampleTime == 480)
        #expect(try render().allSatisfy { abs($0 - 0.4) < 0.000001 })
        #expect(try render().allSatisfy { abs($0 - 0.4) < 0.000001 })
    }
    @Test func nativeDuckGainChangesWithoutReplacingSourceOrQueue() throws {
        let engine = AVAudioEngine(), player = AVAudioPlayerNode()
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        engine.attach(player); engine.connect(player, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 2400)
        try engine.start(); defer { engine.stop() }
        let audio = MacAudio(offlineEngine: engine, player: player)
        let source = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 9600)!
        source.frameLength = 9600
        for i in 0..<9600 { source.floatChannelData![0][i] = 0.4 }
        player.scheduleBuffer(source); audio.setCutInGain(AutomaticCutInTuning.duckGain)
        player.play(at: AVAudioTime(sampleTime: 0, atRate: 48_000))
        let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2400)!
        #expect(try engine.renderOffline(2400, to: out) == .success)
        #expect(abs(out.floatChannelData![0][2399] - 0.1) < 0.000001)
        audio.setCutInGain(1)
        #expect(try engine.renderOffline(2400, to: out) == .success)
        #expect(abs(out.floatChannelData![0][2399] - 0.4) < 0.000001)
    }
    @Test func staleReplacementCannotReleaseNewRepairBarrier() {
        var barrier = PlaybackGraphRepairBarrier()
        let old = barrier.begin(), current = barrier.begin()
        #expect(!barrier.replacementInstalled(old) && barrier.inProgress)
        #expect(barrier.replacementInstalled(current) && !barrier.inProgress)
        let cancelled = barrier.begin(); barrier.resetAfterClose()
        let accepted = barrier.replacementInstalled(cancelled)
        #expect(!accepted)
    }
    @Test func rollbackReleasesIntentButOldRunningGraphCannotResume() throws {
        let engine = AVAudioEngine(), player = AVAudioPlayerNode()
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        engine.attach(player); engine.connect(player, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 240)
        try engine.start(); defer { engine.stop() }
        let audio = MacAudio(offlineEngine: engine, player: player)
        let source = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!
        source.frameLength = 480
        for i in 0..<480 { source.floatChannelData![0][i] = Float(i) / 1000 }
        player.scheduleBuffer(source); player.play(at: AVAudioTime(sampleTime: 0, atRate: 48_000))
        #expect(audio.pauseForAutomaticCutIn())
        let old = audio.beginPlaybackGraphRepair(), current = audio.beginPlaybackGraphRepair()
        try audio.resumeAfterAutomaticCutIn() // reentrant cancellation rollback
        #expect(engine.isRunning && !player.isPlaying)
        audio.playbackGraphReplacementInstalled(old)
        #expect(!player.isPlaying)
        // Mac repairs only before capture admission, with no accepted PCM. This
        // test isolates the barrier; it does NOT claim retained-PCM graph repair.
        audio.playbackGraphReplacementInstalled(current)
        #expect(player.isPlaying)
        let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 240)!
        #expect(try engine.renderOffline(240, to: out) == .success)
        #expect((0..<240).allSatisfy { abs(out.floatChannelData![0][$0] - Float($0) / 1000) < 0.000001 })
    }
    @Test func pausedProducerRetainsStreamChunksAndStopReleasesIt() async throws {
        let engine = AVAudioEngine(), player = AVAudioPlayerNode()
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        engine.attach(player); engine.connect(player, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 240)
        try engine.start(); defer { engine.stop() }
        let audio = MacAudio(offlineEngine: engine, player: player)
        var stream: AsyncThrowingStream<Data, Error>.Continuation!
        let chunks = AsyncThrowingStream<Data, Error> { stream = $0 }
        var started = 0, finished = false
        let task = Task {
            try await audio.play(SpeechAudio(sampleRate: 48_000, chunks: chunks), label: "offline") { started += 1 }
            finished = true
        }
        #expect(audio.pauseForAutomaticCutIn())
        stream.yield(Data(repeating: 32, count: 960)); stream.finish()
        for _ in 0..<4 { await Task.yield() }
        #expect(started == 0 && !finished)
        try audio.resumeAfterAutomaticCutIn()
        #expect(await waitUntil { started == 1 })
        // Exercise the real native partial buffer, then pause beyond its old
        // five-second wall-clock timeout without consuming the queued source.
        let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 240)!
        #expect(try engine.renderOffline(240, to: out) == .success)
        #expect(out.floatChannelData![0][200] > 0)
        #expect(audio.pauseForAutomaticCutIn())
        try await Task.sleep(nanoseconds: 5_200_000_000)
        #expect(!finished)
        audio.stopPlayback()
        try await task.value
        #expect(finished && started == 1)
    }
}
