import AVFoundation
import Testing
@testable import FloatingVoiceCore

@Suite struct CaptureIngressTests {
    @Test func discardFencesQueuedFramesAndConverterCarryWithoutStoppingCapture() throws {
        let ingress = CaptureIngress()
        let old = ingress.speechGeneration
        // Include a fractional frame so both converter and PCM framing have old carry.
        _ = try ingress.consume(buffer(signal: true, length: 479), hardware: true)
        #expect(ingress.admitsSpeech(old))
        ingress.discardPendingAudio()
        #expect(!ingress.admitsSpeech(old))
        #expect(try ingress.consume(buffer(signal: true), hardware: true, speechGeneration: old).isEmpty)
        let fresh = ingress.speechGeneration
        var frames: [Data] = []
        for _ in 0..<6 { frames += try ingress.consume(buffer(), hardware: true) }
        #expect(ingress.admitsSpeech(fresh) && ingress.snapshot().ready)
        #expect(!frames.isEmpty && frames.allSatisfy { TurnTaker.rms($0) == 0 })
    }
    func buffer(channels: AVAudioChannelCount = 1, interleaved: Bool = false, signal: Bool = false, length: AVAudioFrameCount = 960) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: channels, interleaved: interleaved)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 960)!
        buffer.frameLength = length
        for audio in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
            let values = audio.mData!.assumingMemoryBound(to: Float.self)
            for i in 0..<Int(audio.mDataByteSize)/4 { values[i] = signal ? Float(sin(Double(i) * 0.07) * 0.2) : 0 }
        }
        return buffer
    }
    @Test func actual48kMonoStereoZeroThenSignal() throws {
        for channels: AVAudioChannelCount in [1, 2] {
            for interleaved in [false, true] {
                let ingress = CaptureIngress()
                var zeros = [Data]()
                for _ in 0..<20 { zeros += try ingress.consume(buffer(channels: channels, interleaved: interleaved), hardware: true) }
                #expect(ingress.snapshot().ready, "Quiet must be ready before speech")
                #expect(zeros.allSatisfy { $0.count == 640 && TurnTaker.rms($0) == 0 })
                #expect(zeros.count >= 18)
                var speech = [Data]()
                for _ in 0..<20 { speech += try ingress.consume(buffer(channels: channels, interleaved: interleaved, signal: true), hardware: true) }
                #expect(speech.contains { TurnTaker.rms($0) > 0.01 })
                #expect(ingress.snapshot().hardwareCallbacks == 40)
                #expect(ingress.snapshot().inputFrames == 38400)
                print("REAL_CONVERTER rate=48000 channels=\(channels) interleaved=\(interleaved) zeroFrames=\(zeros.count) signalFrames=\(speech.count) rms=\(ingress.snapshot().rms)")
            }
        }
    }
    @Test func noTapInvalidAndZeroConversionAreDistinct() throws {
        let ingress = CaptureIngress()
        #expect(ingress.snapshot().failureCode == 1)
        #expect(try ingress.consume(buffer(length: 0), hardware: true).isEmpty)
        #expect(ingress.snapshot().failureCode == 2)
        #expect(try ingress.consume(buffer(length: 1), hardware: true).isEmpty)
        #expect(ingress.snapshot().failureCode == 3)
        #expect(!ingress.snapshot().ready)
    }
    @Test func ownerInvalidationAndFormatTransitionCannotSplice() throws {
        let old = CaptureIngress()
        _ = try old.consume(buffer(), hardware: true)
        old.invalidate()
        #expect(try old.consume(buffer(signal: true), hardware: true).isEmpty)
        let fresh = CaptureIngress()
        #expect(!fresh.snapshot().ready)
        for _ in 0..<5 { _ = try fresh.consume(buffer(), hardware: true) }
        #expect(fresh.snapshot().ready)
        #expect(throws: (any Error).self) { try fresh.consume(buffer(channels: 2), hardware: true) }
        fresh.invalidate()
        #expect(try fresh.consume(buffer(channels: 2), hardware: true).isEmpty)
    }
    @Test @MainActor func quietFramesSatisfyProductionLifecycleWithoutSpeech() async throws {
        let lifecycle = CaptureLifecycle(), ingress = CaptureIngress()
        try await lifecycle.start(permission: {}, activate: {}, open: { _ in
            for _ in 0..<5 { _ = try ingress.consume(buffer(), hardware: true) }
        }, close: { ingress.invalidate() }, deactivate: {}, ready: { owner in
            #expect(lifecycle.admits(owner))
            #expect(ingress.snapshot().ready && ingress.snapshot().rms == 0)
        })
        #expect(lifecycle.capturing)
        lifecycle.stop(close: { ingress.invalidate() }, deactivate: {})
        #expect(!lifecycle.capturing)
        #expect(try ingress.consume(buffer(signal: true), hardware: true).isEmpty)
    }
    @Test func closedSnapshotSurvivesPollingWithoutPersonalFields() throws {
        let log = StageDiagnostics()
        log.record(.capture, .failed, audio: CaptureSnapshot([.hardwareCallbacks: 0, .convertedFrames: 0, .failure: 1]))
        for _ in 0..<400 { log.record(.state, .complete) }
        let json = log.export()
        let entries = try JSONDecoder().decode([DiagnosticEntry].self, from: Data(json.utf8))
        #expect(entries.count <= 256)
        #expect(entries.contains { $0.audio?.values["failure"] == 1 })
        #expect(!json.contains("UID") && !json.contains("name") && !json.contains("http"))
    }
}
