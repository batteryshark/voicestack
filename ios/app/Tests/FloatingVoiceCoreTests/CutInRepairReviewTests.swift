import Foundation
import AVFoundation
import Testing
@testable import FloatingVoiceCore

/// Offline native-node adapter using the production repair barrier and ledger.
/// Python wiring tests gate the same ordering in IOSAudio (not built for macOS).
@MainActor private final class RepairReviewOutput: AutomaticCutInOutput {
    let engine = AVAudioEngine(), player = AVAudioPlayerNode()
    let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
    let ledger = PlaybackContinuity(queue: PlaybackBufferScheduler())
    var barrier = PlaybackGraphRepairBarrier()
    var automaticallyPaused = false
    var scheduled = 0, resumes = 0, deferredRollbacks = 0
    var receipts: [PlaybackContinuity.CompletionReceipt] = []
    private var finished: CheckedContinuation<Void, Never>?
    init() throws {
        engine.attach(player); engine.connect(player, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 240)
        try engine.start()
    }
    func play(_ audio: SpeechAudio, label: String, onStart: @escaping () -> Void) async throws {
        // Four distinct 200ms source buffers: the entire retained 800ms repro.
        for first in stride(from: 0, to: 19_200, by: 4800) {
            let data = (first..<first+4800).reduce(into: Data()) {
                $0.append(UInt8($1 & 255)); $0.append(UInt8($1 >> 8))
            }
            ledger.append(data, token: ledger.queue.schedule()!)
            schedule(ledger.segments.last!)
        }
        _ = ledger.queue.startIfNeeded()
        player.play(at: AVAudioTime(sampleTime: engine.manualRenderingSampleTime, atRate: 24_000))
        onStart()
        await withCheckedContinuation { finished = $0 }
    }
    private func schedule(_ segment: PlaybackContinuity.Segment) {
        let bytes = [UInt8](segment.pcm), count = bytes.count / 2
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
        buffer.frameLength = buffer.frameCapacity
        for i in 0..<count {
            buffer.floatChannelData![0][i] = Float(Int16(bitPattern: UInt16(bytes[i*2]) | UInt16(bytes[i*2+1]) << 8)) / 32768
        }
        let receipt = ledger.completionReceipt(for: segment)
        receipts.append(receipt); scheduled += 1
        player.scheduleBuffer(buffer, completionCallbackType: .dataRendered) { _ in receipt.record() }
    }
    func setCutInGain(_ gain: Float) {} // Gain is covered by the separate real-node meter fixture.
    func pauseForAutomaticCutIn() -> Bool { automaticallyPaused = true; player.pause(); return true }
    func resumeAfterAutomaticCutIn() throws {
        guard automaticallyPaused else { return }
        automaticallyPaused = false
        guard !barrier.inProgress else { deferredRollbacks += 1; return }
        try resumeRetained()
    }
    private func resumeRetained() throws {
        if ledger.suspended {
            for segment in ledger.segments { schedule(segment) }
            ledger.resume(); resumes += 1
        }
        ledger.startRetainedRun {
            player.play(at: AVAudioTime(sampleTime: engine.manualRenderingSampleTime, atRate: 24_000))
        }
    }
    func beginRepair(closeAdmission: () -> Void) -> Int {
        let owner = barrier.begin() // Must precede the reentrant Controller callback.
        player.pause(); _ = ledger.suspend(renderedFrames: 0)
        closeAdmission()
        return owner
    }
    func destructiveStop() { engine.stop(); player.stop() }
    func installReplacement(_ owner: Int) throws {
        if !engine.isRunning { try engine.start() }
        guard barrier.replacementInstalled(owner) else { return }
        if !automaticallyPaused { try resumeRetained() }
    }
    func renderRetainedFrames() throws -> [Float] {
        var result: [Float] = []
        for _ in 0..<80 {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 240)!
            #expect(try engine.renderOffline(240, to: buffer) == .success)
            result += Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: 240))
        }
        return result
    }
    func stopPlayback() {
        engine.stop(); player.stop(); ledger.cancel(); ledger.queue.cancel()
        let finish = finished; finished = nil; finish?.resume()
    }
}

@Suite(.serialized) @MainActor struct CutInRepairReviewTests {
    @Test func graphCloseCancelsRecognizerAndRollsBackWithoutResumingOldRunningEngine() async throws {
        let output = try RepairReviewOutput(), input = FakeInput(), backend = FakeBackend()
        var app = AppSettings(); app.target = "ses_A"
        let settings = LoadedSettings(app: app, voice: VoiceConfig(), voiceFile: nil, appFile: "/nonexistent", chiefFile: "/nonexistent")
        var recognition: FakeRecognition?
        let controller = ConversationController(settings: settings, backend: backend, synth: FakeSynth(), output: output, input: input,
            makeRecognition: { let r = FakeRecognition($0, transcript: ""); recognition = r; return r })
        defer { controller.stop(); output.stopPlayback() }
        await controller.start()
        #expect(await waitUntil { controller.status.phase == "ready" })
        controller.speaker.enqueue("Retain all four source buffers.")
        #expect(await waitUntil { output.scheduled == 4 })
        input.frames(8, voiced: true); recognition?.callbacks.live("stop")
        #expect(output.automaticallyPaused && output.engine.isRunning)
        let oldRevision = output.ledger.revision, oldReceipts = output.receipts
        let oldTokens = output.ledger.segments.map(\.token)
        let repairOwner = output.beginRepair { input.captureGraphReady = false }
        // Actual Controller -> refreshDuplexPolicy -> TurnTaker.discard ->
        // outcome.cancelled -> Speaker.restoreAutomaticCutIn -> native rollback.
        #expect(recognition?.cancelled == true && output.deferredRollbacks == 1)
        #expect(output.engine.isRunning && !output.automaticallyPaused)
        #expect(output.ledger.suspended && output.scheduled == 4 && output.resumes == 0)
        #expect(output.ledger.position == 0 && output.ledger.segments.reduce(0) { $0 + $1.pcm.count / 2 } == 19_200)
        output.destructiveStop()
        // Explicitly deliver all flushed callbacks, whether or not AVFoundation
        // has delivered its own callbacks yet. No unplayed receipt may be accepted.
        #expect(oldReceipts.allSatisfy { !$0.record() })
        #expect(oldTokens.allSatisfy { !output.ledger.completed($0, revision: oldRevision) })
        #expect(output.ledger.suspended && output.ledger.position == 0 && output.ledger.queue.depth == 4)
        try output.installReplacement(repairOwner)
        try output.installReplacement(repairOwner) // Cannot reschedule twice.
        #expect(output.scheduled == 8 && output.resumes == 1 && !output.ledger.suspended)
        let actual = try output.renderRetainedFrames()
        #expect(actual.count == 19_200)
        #expect(actual.enumerated().allSatisfy { abs($0.element - Float($0.offset) / 32768) < 0.000001 })
        #expect(output.ledger.segments.map(\.token) == oldTokens)
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

    @Test(arguments: [false, true]) func realNodeInitialGainLossIsDropoutEvenForWholeHundredMsUtterance(_ whole: Bool) throws {
        let engine = AVAudioEngine(), player = AVAudioPlayerNode(), meter = PlaybackSignalMeter()
        let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
        engine.attach(player); engine.connect(player, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 2400)
        try engine.start(); defer { engine.stop() }
        let frames = whole ? 2400 : 4800
        let source = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        source.frameLength = source.frameCapacity
        for i in 0..<frames { source.floatChannelData![0][i] = 0.2 }
        player.scheduleBuffer(source); player.volume = 0
        meter.begin(token: 1, graph: 1, rate: 24_000)
        meter.source(Data(repeating: 32, count: frames * 2)); meter.sourceFinished(); meter.start(token: 1, now: 0)
        player.play(at: AVAudioTime(sampleTime: 0, atRate: 24_000))
        for block in 0..<(whole ? 1 : 2) {
            if block == 1 { player.volume = 1 }
            let stamp = AVAudioTime(sampleTime: engine.manualRenderingSampleTime, atRate: 24_000)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2400)!
            #expect(try engine.renderOffline(2400, to: buffer) == .success)
            let rms = (0..<2400).reduce(0.0) { $0 + pow(Double(buffer.floatChannelData![0][$1]), 2) }.squareRoot() / sqrt(2400)
            let cursor = try #require(player.playerTime(forNodeTime: stamp)).sampleTime
            #expect(cursor == block * 2400)
            _ = meter.render(rms: rms, frames: 2400, renderRate: 24_000, sourceFrame: Int(cursor), graph: 1, now: Double(block) / 10)
        }
        // Independent real source END clock; production supplies validated
        // completion evidence after continuity.completed instead.
        let end = try #require(player.playerTime(forNodeTime: AVAudioTime(sampleTime: engine.manualRenderingSampleTime, atRate: 24_000)))
        meter.confirmRendered(through: Int(end.sampleTime), token: 1)
        let result = meter.end(token: 1)
        #expect(result.dropoutCount == 1 && result.dropoutMaxMs == 100 && result.startLatencyMs == 0)
    }
}
