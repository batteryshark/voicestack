import Foundation
import Testing
@testable import FloatingVoiceCore

@Suite struct PlaybackSignalMeterTests {
    @Test func deliberateSourcePauseIsSilenceNotDropoutButInjectedOutputGapIsDropout() {
        for inject in [false, true] {
            let meter = PlaybackSignalMeter(); meter.begin(token: 1, graph: 2, rate: 1000)
            meter.start(token: 1)
            var pcm = Data()
            for frame in 0..<800 {
                let pause = (100..<300).contains(frame)
                let sample = pause ? Int16(0) : Int16(8000 * sin(2 * .pi * 100 * Double(frame) / 1000))
                pcm.append(UInt8(truncatingIfNeeded: sample)); pcm.append(UInt8(truncatingIfNeeded: sample >> 8))
            }
            // Producer/chunk boundaries must not reset a source-silence run.
            meter.source(Data(pcm.prefix(350))); meter.source(Data(pcm.dropFirst(350))); meter.sourceFinished()
            for frame in stride(from: 0, to: 800, by: 10) {
                let silence = (100..<300).contains(frame) || (inject && (450..<570).contains(frame))
                _ = meter.render(rms: silence ? 0 : 0.17, frames: 10, renderRate: 1000,
                    sourceFrame: frame, graph: 2, now: Double(frame) / 1000)
            }
            let result = meter.end(token: 1)
            #expect(result.sourceSilenceCount == 1)
            #expect(result.dropoutCount == (inject ? 1 : 0))
            #expect(abs(result.dropoutMaxMs - (inject ? 120 : 0)) < 0.001)
            #expect(result.alignmentUnknown == 0)
        }
    }
    @Test func handoffUsesRenderClockAndGraphResumeOffsetNotActorDeliveryTime() {
        let meter = PlaybackSignalMeter(); meter.begin(token: 1, graph: 1, rate: 1000)
        meter.start(token: 1)
        meter.source(Data(repeating: 32, count: 800)); meter.sourceFinished()
        _ = meter.render(rms: 0.1, frames: 10, renderRate: 1000, sourceFrame: 0, graph: 1, now: 0)
        meter.beginHandoff(generation: 3, now: 0.01)
        let continuous = meter.render(rms: 0.1, frames: 10, renderRate: 1000, sourceFrame: 10, graph: 1, now: 0.01).first
        #expect(continuous?.gapMs == 0 && continuous?.generation == 3)
        #expect(continuous?.positionKnown == true && continuous?.skippedUpToMs == 0)
        meter.beginHandoff(generation: 4, now: 0.02); meter.suspend()
        #expect(meter.renderedPosition == 20)
        meter.resume(graph: 2, base: 20)
        meter.start(token: 1)
        let gap = meter.render(rms: 0.1, frames: 10, renderRate: 1000, sourceFrame: 0, graph: 2, now: 0.145).first
        #expect(abs((gap?.gapMs ?? 0) - 125) < 0.001 && meter.renderedPosition == 30)
    }
    @Test func staleAndUnknownAlignmentNeverInventsDropoutAndLongSilenceCountsOnce() {
        let meter = PlaybackSignalMeter(); meter.begin(token: 3, graph: 1, rate: 1000)
        meter.start(token: 3)
        meter.source(Data(repeating: 0, count: 1200)); meter.sourceFinished()
        _ = meter.render(rms: 0.1, frames: 10, renderRate: 1000, sourceFrame: 0, graph: 1, now: 0)
        _ = meter.render(rms: 0, frames: 500, renderRate: 1000, sourceFrame: 10, graph: 0, now: 1)
        _ = meter.render(rms: 0, frames: 500, renderRate: 1000, sourceFrame: nil, graph: 1, now: 1)
        let result = meter.end(token: 3)
        #expect(result.sourceSilenceCount == 1 && result.dropoutCount == 0 && result.alignmentUnknown == 1)
    }
    @Test func delayedTapFromOldRunCannotCompleteResumedHandoff() {
        let meter = PlaybackSignalMeter(); meter.begin(token: 1, graph: 1, rate: 1000)
        meter.source(Data(repeating: 32, count: 800)); meter.sourceFinished(); meter.start(token: 1, now: 0)
        _ = meter.render(rms: 0.1, frames: 10, renderRate: 1000, sourceFrame: 0, graph: 1, now: 0)
        let oldRevision = meter.renderRevision
        meter.beginHandoff(generation: 4, now: 0.01); meter.suspend()
        meter.resume(graph: 1, base: 10); meter.start(token: 1, now: 0.1)
        // A queued tap can reach the actor after a same-graph pause/resume.
        #expect(meter.render(rms: 0.1, frames: 10, renderRate: 1000, sourceFrame: 10,
            graph: 1, now: 0.01, revision: oldRevision).isEmpty)
        #expect(meter.renderedPosition == 10)
        let handoffs = meter.render(rms: 0.1, frames: 10, renderRate: 1000, sourceFrame: 0,
            graph: 1, now: 0.135, revision: meter.renderRevision)
        #expect(handoffs.count == 1 && handoffs.first?.generation == 4)
        #expect(abs((handoffs.first?.gapMs ?? 0) - 125) < 0.001)
        #expect(meter.render(rms: 0.1, frames: 10, renderRate: 1000, sourceFrame: 10,
            graph: 1, now: 0.145, revision: meter.renderRevision).isEmpty)
    }
    @Test func rapidSwitchesKeepEachGenerationAndHandoffOwnershipIsCaptured() {
        let meter = PlaybackSignalMeter(), attempt = UUID()
        meter.begin(token: 7, graph: 2, rate: 1000, attempt: attempt, callToken: 12)
        meter.start(token: 7)
        meter.source(Data(repeating: 32, count: 100)); meter.sourceFinished()
        for generation in 1...17 { meter.beginHandoff(generation: generation, now: 0) }
        let events = meter.render(rms: 0.1, frames: 10, renderRate: 1000, sourceFrame: 0, graph: 2, now: 0.125)
        #expect(events.count == 16 && Set(events.map(\.generation)) == Set(1...16))
        #expect(events.allSatisfy { $0.ordinal == 7 && $0.attempt == attempt && $0.callToken == 12 && $0.gapMs == 125 })
        #expect(meter.end(token: 7).handoffsDropped == 1)
    }
    @Test func staleEndCannotConsumeNewUtteranceAndMissingWindowCoverageIsNotCleanEvidence() {
        let meter = PlaybackSignalMeter()
        meter.begin(token: 1, graph: 1, rate: 1000)
        meter.begin(token: 2, graph: 2, rate: 1000)
        meter.start(token: 2)
        meter.source(Data(repeating: 0, count: 12_000)); meter.sourceFinished() // Exceeds bounded 512-window bank.
        #expect(meter.end(token: 1).sourceSilenceCount == 0)
        _ = meter.render(rms: 0, frames: 10, renderRate: 1000, sourceFrame: 0, graph: 2, now: 0)
        let result = meter.end(token: 2)
        #expect(result.sourceSilenceCount == 1 && result.dropoutCount == 0 && result.alignmentUnknown == 1)
    }
    @Test func idleAndInFlightOldRunClocksCannotInventPlayedSourceFrames() {
        let meter = PlaybackSignalMeter(); meter.begin(token: 1, graph: 1, rate: 1000)
        meter.source(Data(repeating: 32, count: 400)); meter.sourceFinished()
        let idleRevision = meter.renderRevision
        _ = meter.render(rms: 0, frames: 10, renderRate: 1000, sourceFrame: 100, graph: 1, now: 0)
        #expect(meter.renderedPosition == nil)
        meter.start(token: 1)
        _ = meter.render(rms: 0.1, frames: 10, renderRate: 1000, sourceFrame: 100,
            graph: 1, now: 0, revision: idleRevision)
        #expect(meter.renderedPosition == nil)
        _ = meter.render(rms: 0.1, frames: 10, renderRate: 1000, sourceFrame: 0,
            graph: 1, now: 0, revision: meter.renderRevision)
        #expect(meter.renderedPosition == 10)
    }
    @Test func missingAudibleSourceAtAttackOrTailDoesNotRequireLaterOutputSignal() {
        let meter = PlaybackSignalMeter(); meter.begin(token: 1, graph: 1, rate: 1000)
        meter.source(Data(repeating: 32, count: 400)); meter.sourceFinished(); meter.start(token: 1)
        for frame in stride(from: 0, to: 200, by: 10) {
            _ = meter.render(rms: 0, frames: 10, renderRate: 1000, sourceFrame: frame, graph: 1, now: Double(frame) / 1000)
        }
        let result = meter.end(token: 1)
        #expect(result.sourceSilenceCount == 0 && result.dropoutCount == 1 && result.dropoutMaxMs == 200)
    }
    @Test func unknownPositionHandoffReportsSkipBoundAndStillMeasuresRealGap() {
        let meter = PlaybackSignalMeter(); meter.begin(token: 1, graph: 1, rate: 1000)
        meter.source(Data(repeating: 32, count: 800)); meter.sourceFinished(); meter.start(token: 1)
        _ = meter.render(rms: 0.1, frames: 10, renderRate: 1000, sourceFrame: 0, graph: 1, now: 0)
        meter.beginHandoff(generation: 4, now: 0.01)
        meter.suspend()
        #expect(meter.noteHandoffPosition(generation: 4, positionKnown: false, skippedFrames: 200) == 200)
        meter.beginHandoff(generation: 4, now: 0.02) // Coalescing keeps the position annotation and original timing.
        meter.resume(graph: 2, base: 200); meter.start(token: 1)
        let handoff = meter.render(rms: 0.1, frames: 10, renderRate: 1000, sourceFrame: 0, graph: 2, now: 0.135).first
        #expect(handoff?.positionKnown == false && handoff?.skippedUpToMs == 200)
        #expect(abs((handoff?.gapMs ?? 0) - 125) < 0.001 && meter.renderedPosition == 210)
    }
    @Test func initialUnadvancedTapLatencyAndPostDrainTailAreNotDropouts() {
        let meter = PlaybackSignalMeter(); meter.begin(token: 1, graph: 1, rate: 1000)
        meter.source(Data(repeating: 32, count: 1000)); meter.sourceFinished()
        meter.start(token: 1, now: 10)
        // A 100ms tap spanning pre-render attack with an unadvanced clock.
        _ = meter.render(rms: 0, frames: 100, renderRate: 1000, sourceFrame: 0, graph: 1, now: 10)
        #expect(meter.renderedPosition == nil)
        _ = meter.render(rms: 0.1, frames: 100, renderRate: 1000, sourceFrame: 0, graph: 1, now: 10.1)
        _ = meter.render(rms: 0, frames: 100, renderRate: 1000, sourceFrame: 500, graph: 1, now: 10.6)
        let result = meter.end(token: 1)
        #expect(result.dropoutCount == 0 && abs(result.startLatencyMs - 100) < 0.001)
    }
    @Test func anActualHundredMsGapAfterStartupStillCountsAndDuckIsExpected() {
        let meter = PlaybackSignalMeter(); meter.begin(token: 1, graph: 1, rate: 1000)
        meter.source(Data(repeating: 32, count: 1000)); meter.sourceFinished(); meter.start(token: 1, now: 0)
        _ = meter.render(rms: 0.1, frames: 100, renderRate: 1000, sourceFrame: 0, graph: 1, now: 0)
        _ = meter.render(rms: 0, frames: 100, renderRate: 1000, sourceFrame: 100, graph: 1, now: 0.1)
        meter.setExpectedGain(0.25)
        _ = meter.render(rms: RenderDropoutMeter.floor * 0.3, frames: 100, renderRate: 1000, sourceFrame: 200, graph: 1, now: 0.2)
        let result = meter.end(token: 1)
        #expect(result.dropoutCount == 1 && result.dropoutMaxMs == 100)
    }
    @Test func missingFirstHundredMsIsProvenByTheNextAudibleBlockNotCountedAsLatency() {
        let meter = PlaybackSignalMeter(); meter.begin(token: 1, graph: 1, rate: 24_000)
        meter.source(Data(repeating: 32, count: 9600)); meter.sourceFinished(); meter.start(token: 1, now: 0)
        _ = meter.render(rms: 0, frames: 2400, renderRate: 24_000, sourceFrame: 0, graph: 1, now: 0)
        #expect(meter.renderedPosition == nil) // Provisional, NOT exempted.
        _ = meter.render(rms: 0.1, frames: 2400, renderRate: 24_000, sourceFrame: 2400, graph: 1, now: 0.1)
        let result = meter.end(token: 1)
        #expect(result.dropoutCount == 1 && result.dropoutMaxMs == 100 && result.startLatencyMs == 0)
    }
    @Test func whollyMissingHundredMsIsProvenByCompletionWithoutAnotherTap() {
        let meter = PlaybackSignalMeter(); meter.begin(token: 7, graph: 1, rate: 24_000)
        meter.source(Data(repeating: 32, count: 4800)); meter.sourceFinished(); meter.start(token: 7, now: 0)
        _ = meter.render(rms: 0, frames: 2400, renderRate: 24_000, sourceFrame: 0, graph: 1, now: 0)
        meter.confirmRendered(through: 2400, token: 6) // Stale completion cannot prove it.
        #expect(meter.renderedPosition == nil)
        meter.confirmRendered(through: 2400, token: 7)
        meter.confirmRendered(through: 2400, token: 7) // Idempotent.
        let result = meter.end(token: 7)
        #expect(result.dropoutCount == 1 && result.dropoutMaxMs == 100 && result.startLatencyMs == 0)
    }
    @Test func repeatedZeroPreStartTapsAreExemptButTheLastZeroIntervalIsStillProvisional() {
        for missingFirst in [false, true] {
            let meter = PlaybackSignalMeter(); meter.begin(token: 1, graph: 1, rate: 1000)
            meter.source(Data(repeating: 32, count: 1000)); meter.sourceFinished(); meter.start(token: 1, now: 0)
            for time in [0.0, 0.1, 0.2] {
                _ = meter.render(rms: 0, frames: 100, renderRate: 1000, sourceFrame: 0, graph: 1, now: time)
            }
            _ = meter.render(rms: 0.1, frames: 100, renderRate: 1000, sourceFrame: missingFirst ? 100 : 0, graph: 1, now: 0.3)
            let result = meter.end(token: 1)
            #expect(result.dropoutCount == (missingFirst ? 1 : 0))
            #expect(result.dropoutMaxMs == (missingFirst ? 100 : 0))
            #expect(abs(result.startLatencyMs - (missingFirst ? 200 : 300)) < 0.001)
        }
    }
    @Test func unprovenInitialLowOnCancellationIsUnknownNotInventedDropout() {
        let meter = PlaybackSignalMeter(); meter.begin(token: 1, graph: 1, rate: 1000)
        meter.source(Data(repeating: 32, count: 200)); meter.sourceFinished(); meter.start(token: 1, now: 0)
        _ = meter.render(rms: 0, frames: 100, renderRate: 1000, sourceFrame: 0, graph: 1, now: 0)
        meter.suspend(); meter.confirmRendered(through: 100, token: 1)
        let result = meter.end(token: 1)
        #expect(result.dropoutCount == 0 && result.alignmentUnknown == 1)
    }
}
