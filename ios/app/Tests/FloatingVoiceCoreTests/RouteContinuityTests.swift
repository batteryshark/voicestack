import Foundation
import Testing
@testable import FloatingVoiceCore

@Suite(.serialized) @MainActor struct RouteContinuityTests {
    private let io = [RouteIOFormat(rate: 48_000, channels: 1, common: 1, interleaved: false)]
    @Test func plainBuiltInChangesKeepProductionGraphAndAllFrames() {
        let pcm = PlaybackContinuity(queue: PlaybackBufferScheduler())
        var stops = 0, interruptions = 0, requests = 1, actual: [UInt16] = []
        for start in stride(from: 0, to: 160, by: 40) { pcm.append(data(start..<start+40), token: pcm.queue.schedule()!) }
        for route in [PhoneAudioRoute.speaker, .phone, .speaker, .phone] {
            let rebuild = RouteContinuity.needsRebuild(before: io, after: io,
                previous: route == .phone ? .speaker : .phone, current: route, reason: route == .phone ? 3 : 4,
                configurationChanged: false, running: true, active: true)
            if rebuild { stops += 1; interruptions += 1; requests += 1 }
            let segment = pcm.segments[0]
            actual += samples(segment.pcm)
            #expect(pcm.completed(segment.token, revision: pcm.revision))
        }
        #expect(stops == 0 && interruptions == 0 && requests == 1)
        #expect(actual == Array(0..<160).map(UInt16.init) && pcm.queue.depth == 0)
    }
    @Test func actualChangesStillRebuildAndInactiveCallCannotRepair() {
        let changed = [RouteIOFormat(rate: 24_000, channels: 2, common: 1, interleaved: false)]
        for route in [PhoneAudioRoute.bluetooth, .headphones, .external] {
            #expect(RouteContinuity.needsRebuild(before: io, after: io, previous: .phone, current: route,
                reason: 1, configurationChanged: false, running: true, active: true))
            #expect(RouteContinuity.needsRebuild(before: io, after: io, previous: route, current: .phone,
                reason: 2, configurationChanged: false, running: true, active: true))
        }
        #expect(RouteContinuity.needsRebuild(before: io, after: changed, previous: .phone, current: .speaker,
            reason: 4, configurationChanged: false, running: true, active: true))
        #expect(RouteContinuity.needsRebuild(before: io, after: io, previous: .phone, current: .phone,
            reason: 8, configurationChanged: true, running: true, active: true))
        #expect(!RouteContinuity.needsRebuild(before: io, after: changed, previous: .phone, current: .phone,
            reason: 8, configurationChanged: true, running: false, active: false))
    }
    @Test func forcedRebuildTrimsPlayedPrefixKeepsUnplayedBuffersAndProducerCarry() {
        let pcm = PlaybackContinuity(queue: PlaybackBufferScheduler())
        for start in stride(from: 0, to: 160, by: 40) { pcm.append(data(start..<start+40), token: pcm.queue.schedule()!) }
        let stale = pcm.segments[0].token, oldRevision = pcm.revision
        let carry = data(160..<200) // Existing HTTP iterator/carry remain with the suspended producer.
        let consumed = pcm.suspend(renderedFrames: 53)
        #expect(consumed.count == 1 && pcm.position == 53 && pcm.queue.depth == 3)
        #expect(pcm.positionKnown && pcm.skippedFrames == 0)
        #expect(pcm.segments[0].first == 53 && samples(pcm.segments[0].pcm).first == 53)
        #expect(!pcm.completed(stale, revision: oldRevision))
        var actual = Array(0..<53).map(UInt16.init)
        pcm.resume()
        for segment in pcm.segments {
            actual += samples(segment.pcm)
            #expect(pcm.completed(segment.token, revision: pcm.revision))
        }
        pcm.append(carry, token: pcm.queue.schedule()!)
        actual += samples(pcm.segments[0].pcm)
        #expect(pcm.completed(pcm.segments[0].token, revision: pcm.revision))
        #expect(actual == Array(0..<200).map(UInt16.init))
        #expect(pcm.submitted == 200 && pcm.position == 200 && pcm.queue.depth == 0)
    }
    @Test func multipleRebuildsUseRelativePlayerClockAndRejectStoppedCompletions() {
        let pcm = PlaybackContinuity(queue: PlaybackBufferScheduler())
        pcm.append(data(0..<100), token: pcm.queue.schedule()!)
        _ = pcm.suspend(renderedFrames: 25); pcm.resume()
        _ = pcm.suspend(renderedFrames: 15)
        #expect(pcm.position == 40 && pcm.segments[0].first == 40)
        let token = pcm.segments[0].token, revision = pcm.revision
        pcm.cancel(); pcm.queue.cancel()
        #expect(!pcm.completed(token, revision: revision) && pcm.segments.isEmpty)
    }
    @Test func emptyStreamingNodeClockIsRebasedBeforeNextSourceBuffer() {
        let pcm = PlaybackContinuity(queue: PlaybackBufferScheduler())
        pcm.append(data(0..<40), token: pcm.queue.schedule()!)
        #expect(pcm.queue.startIfNeeded())
        pcm.completed(pcm.segments[0].token, revision: 0)
        pcm.restartEmptyRun() // Hardware time through source starvation is NOT source progress.
        pcm.append(data(40..<80), token: pcm.queue.schedule()!)
        #expect(!pcm.queue.startIfNeeded()) // Same utterance/onStart identity.
        _ = pcm.suspend(renderedFrames: 15)
        #expect(pcm.position == 55 && pcm.segments[0].first == 55)
        #expect(samples(pcm.segments[0].pcm) == Array(55..<80).map(UInt16.init))
    }
    @Test func unknownCursorSkipsOnlyOneUnprovenBufferAndContinuesThroughCarryToEOF() {
        for partial in [0, 13, 39] {
            let pcm = PlaybackContinuity(queue: PlaybackBufferScheduler())
            for start in stride(from: 0, to: 160, by: 40) { pcm.append(data(start..<start+40), token: pcm.queue.schedule()!) }
            #expect(pcm.completed(pcm.segments[0].token, revision: 0)) // [0,40) proven played.
            let unknown = pcm.segments[0].token, revision = pcm.revision
            var actual = Array(0..<40+partial).map(UInt16.init) // Unknown progress within [40,80).
            let consumed = pcm.suspend(renderedFrames: nil)
            #expect(!pcm.positionKnown && pcm.position == 80 && pcm.skippedFrames == 40)
            #expect(Double(pcm.skippedFrames) / 200 * 1000 == 200) // One maximum-size buffer.
            #expect(consumed == [unknown] && pcm.queue.depth == 2 && pcm.segments[0].first == 80)
            #expect(!pcm.completed(unknown, revision: revision))
            #expect(pcm.suspend(renderedFrames: nil).isEmpty && pcm.skippedFrames == 40) // Coalesced notice cannot skip twice.
            pcm.resume()
            for segment in pcm.segments {
                actual += samples(segment.pcm); pcm.completed(segment.token, revision: pcm.revision)
            }
            pcm.append(data(160..<200), token: pcm.queue.schedule()!) // Same producer/carry.
            actual += samples(pcm.segments[0].pcm); pcm.completed(pcm.segments[0].token, revision: pcm.revision)
            #expect(actual == Array(0..<40+partial).map(UInt16.init) + Array(80..<200).map(UInt16.init))
            #expect(Set(actual).count == actual.count && 200 - actual.count <= pcm.skippedFrames)
            #expect(pcm.position == 200 && pcm.queue.depth == 0 && !pcm.queue.cancelled && !pcm.suspended)
        }
    }
    @Test func unknownCursorWithOnlyFinalShortBufferCompletesDrainAndEmptyQueueDoesNotSkip() async throws {
        let pcm = PlaybackContinuity(queue: PlaybackBufferScheduler())
        pcm.append(data(0..<17), token: pcm.queue.schedule()!)
        var drained = 0
        pcm.queue.whenDrained { drained += 1 }
        _ = pcm.suspend(renderedFrames: nil)
        #expect(pcm.skippedFrames == 17 && !pcm.positionKnown && pcm.segments.isEmpty && drained == 1)
        pcm.resume(); try await pcm.waitUntilResumed(); try await pcm.queue.waitForDrain()
        #expect(!pcm.queue.cancelled && pcm.position == 17)
        _ = pcm.suspend(renderedFrames: nil)
        #expect(pcm.skippedFrames == 0 && pcm.positionKnown)
        pcm.resume()
    }
    @Test func reasonThreeClearsEstablishedSystemOrAppOverrideWithoutSpendingBudget() {
        for app in [false, true] {
            var tracker = RouteRecoveryTracker(), budget = RouteRecoveryBudget()
            tracker.begin(route: .phone)
            if app { _ = tracker.expect(.speaker, now: 0) }
            let on = tracker.notification(route: .speaker, reason: app ? 3 : 4, now: 0.1)
            let off = tracker.notification(route: .phone, reason: 3, now: 11.277)
            #expect(on.deliberate && off.source == .systemChoice)
            #expect(budget.admit(on, now: 0.1) && budget.admit(off, now: 11.277))
            #expect(budget.unexpected.isEmpty)
            tracker.begin(route: .speaker)
            #expect(tracker.notification(route: .phone, reason: 3, now: 12).source == .unexpected)
        }
    }
    @Test func repairWaitDoesNotResumeOnStaleCallbackAndStopReleasesIt() async {
        let pcm = PlaybackContinuity(queue: PlaybackBufferScheduler())
        let token = pcm.queue.schedule()!; pcm.append(data(0..<40), token: token)
        _ = pcm.suspend(renderedFrames: 10)
        let task = Task { @MainActor in try await pcm.waitUntilResumed() }
        #expect(!pcm.completed(token, revision: 0))
        await Task.yield(); pcm.cancel(); pcm.queue.cancel()
        do { try await task.value } catch { Issue.record(error) }
        #expect(!pcm.suspended && pcm.segments.isEmpty)
    }
    @Test func speakerKeepsSameSynthesisTicketAcrossRequiredRebuild() async {
        await exerciseSpeakerRebuild(unknown: false)
    }
    @Test func unknownCursorContinuesSameSpeakerTicketWithoutPauseNoticeOrSynthesis() async {
        await exerciseSpeakerRebuild(unknown: true)
    }
    private func exerciseSpeakerRebuild(unknown: Bool) async {
        let synth = ContinuitySynth(), output = ContinuityOutput()
        let speaker = Speaker(synth: synth, output: output, onError: { Issue.record($0) })
        speaker.enqueue("fixture")
        #expect(await waitUntil { output.continuity?.queue.depth == 4 })
        let pcm = output.continuity!
        for reason: UInt in [4, 3] { // System and app clear both leave this exact play/ticket running.
            #expect(!RouteContinuity.needsRebuild(before: io, after: io, previous: .phone, current: .speaker,
                reason: reason, configurationChanged: false, running: true, active: true))
            #expect(!pcm.suspended && output.plays == 1 && synth.prepares == 1)
        }
        output.actual += Array(0..<53).map(UInt16.init)
        if unknown { pcm.completed(pcm.segments[0].token, revision: pcm.revision) } // First full buffer is proven.
        _ = pcm.suspend(renderedFrames: unknown ? nil : 53)
        #expect(pcm.position == (unknown ? 80 : 53) && pcm.skippedFrames == (unknown ? 40 : 0))
        pcm.resume()
        for _ in 0..<20 {
            if let segment = pcm.segments.first {
                output.actual += samples(segment.pcm)
                pcm.completed(segment.token, revision: pcm.revision)
            }
            await Task.yield()
        }
        #expect(await waitUntil { !speaker.active })
        #expect(synth.prepares == 1 && synth.cancels == 0 && output.plays == 1 && output.interruptions == 0)
        let expected = unknown ? Array(0..<53).map(UInt16.init) + Array(80..<200).map(UInt16.init) : Array(0..<200).map(UInt16.init)
        #expect(output.actual == expected && Set(output.actual).count == output.actual.count)
        speaker.stop()
    }
    private func data(_ frames: Range<Int>) -> Data { frames.reduce(into: Data()) { $0.append(UInt8($1 & 255)); $0.append(UInt8($1 >> 8)) } }
    private func samples(_ pcm: Data) -> [UInt16] {
        let bytes = [UInt8](pcm)
        return stride(from: 0, to: bytes.count, by: 2).map { UInt16(bytes[$0]) | UInt16(bytes[$0+1]) << 8 }
    }
}

private final class ContinuitySynth: SpeechSynthesizer {
    var prepares = 0, cancels = 0
    func prepare(_ text: String) -> SpeechTicket { prepares += 1; return ContinuityTicket(synth: self, text: text) }
}
private final class ContinuityTicket: SpeechTicket {
    let synth: ContinuitySynth, text: String
    init(synth: ContinuitySynth, text: String) { self.synth = synth; self.text = text }
    func audio() async throws -> SpeechAudio {
        .whole((0..<200).reduce(into: Data()) { $0.append(UInt8($1 & 255)); $0.append(0) }, sampleRate: 200)
    }
    func cancel() { synth.cancels += 1 }
}
@MainActor private final class ContinuityOutput: AudioOutput, PlaybackRepairReporting {
    var onPlaybackRepair: (() -> Void)?
    var continuity: PlaybackContinuity?, plays = 0, interruptions = 0
    var actual: [UInt16] = []
    func play(_ audio: SpeechAudio, label: String, onStart: @escaping () -> Void) async throws {
        plays += 1
        let pcm = PlaybackContinuity(queue: PlaybackBufferScheduler()); continuity = pcm
        for try await chunk in audio.chunks {
            var carry = chunk
            while carry.count >= 2 {
                try await pcm.waitUntilResumed()
                let frames = PlaybackBufferScheduler.frameCount(bytes: carry.count, sampleRate: audio.sampleRate)
                pcm.append(Data(carry.prefix(frames * 2)), token: pcm.queue.schedule()!)
                carry.removeFirst(frames * 2)
                if pcm.queue.startIfNeeded() { onStart() }
                if pcm.queue.depth == 4 { try await pcm.queue.waitForCapacity() }
            }
        }
        try await pcm.queue.waitForDrain(); try await pcm.waitUntilResumed()
    }
    func stopPlayback() { continuity?.cancel(); continuity?.queue.cancel() }
}
