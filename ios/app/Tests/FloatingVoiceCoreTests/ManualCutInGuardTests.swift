import Foundation
import Testing
@testable import FloatingVoiceCore

@Suite(.serialized) @MainActor struct ManualCutInGuardTests {
    func stoppedSpeaker(turnEndMs: Double = 2000) async -> Rig {
        let rig = Rig(duration: 8, turnEndQuietMs: turnEndMs)
        rig.recordRecognitionPCM = true
        rig.input.duplexSafe = false
        await rig.start()
        rig.input.noise(100, rms: 0.005) // actual ambient calibration before playback
        rig.controller.speaker.enqueue(one)
        #expect(await waitUntil { rig.controller.speaker.playing })
        rig.input.noise(1, rms: 0.2) // mic-domain playback anchor, not digital render RMS
        rig.controller.bargeIn()
        return rig
    }
    func frame(_ rig: Rig, _ rms: Double) {
        rig.input.noise(1, rms: rms)
        rig.clock += 20
    }
    func finish(_ rig: Rig) async {
        rig.input.frames(60, voiced: false)
        #expect(await waitUntil { rig.backend.prompts.count == 1 })
        #expect(rig.backend.prompts.first?.text == "[voice] Yes.")
        #expect(rig.backend.interrupts.isEmpty)
        rig.controller.stop()
    }

    @Test(arguments: [300.0, 2000.0]) func yesStartingWithTheTapIncludesGuardPreroll(turnEndMs: Double) async {
        let rig = await stoppedSpeaker(turnEndMs: turnEndMs)
        rig.transcript = "Yes."
        for _ in 0..<20 { frame(rig, 0.06) } // word crosses the 300ms boundary
        #expect(rig.recognitions.count == 1)
        #expect(rig.recognitions.first?.written == 20, "ASR must get the onset at the tap, not only post-guard samples")
        await finish(rig)
    }

    @Test func yesStartingTwoHundredMillisecondsAfterTapIsPreserved() async {
        let rig = await stoppedSpeaker()
        rig.transcript = "Yes."
        for _ in 0..<10 { frame(rig, 0.005) }
        for _ in 0..<20 { frame(rig, 0.06) }
        #expect(rig.recognitions.count == 1)
        #expect(rig.recognitions.first?.written == 30, "normal 8-of-12 onset must include the held beginning")
        await finish(rig)
    }

    @Test func decayingTailAboveFloorAt301msExtendsInsteadOfPosting() async {
        let rig = await stoppedSpeaker()
        rig.transcript = "Will do."
        let began = rig.clock
        for i in 0..<15 { frame(rig, 0.2 * pow(0.97, Double(i + 1))) }
        rig.clock = began + 301
        for i in 15..<45 { frame(rig, 0.2 * pow(0.97, Double(i + 1))) }
        #expect(rig.recognitions.isEmpty && rig.controller.status.listeningSuppressed)
        frame(rig, 0.001) // decay finally reached the floor; held tail is dropped
        rig.input.frames(60, voiced: false)
        try? await Task.sleep(nanoseconds: 30_000_000)
        #expect(rig.recognitions.isEmpty && rig.backend.prompts.isEmpty)
        rig.controller.stop()
    }

    @Test func tailQuietBy300msIsDroppedRatherThanRetainedForTheNextWord() async {
        let rig = await stoppedSpeaker()
        for i in 0..<15 { frame(rig, 0.2 * pow(0.6, Double(i + 1))) }
        frame(rig, 0.008) // t=300: below normal onset threshold, despite ambient jitter above the floor
        #expect(rig.recognitions.isEmpty && rig.backend.prompts.isEmpty)
        rig.transcript = "Yes."
        for _ in 0..<8 { frame(rig, 0.06) }
        #expect(rig.recognitions.first?.written == 8, "the quiet tail must not ride into later ASR pre-roll")
        await finish(rig)
    }

    @Test func genuineWordAfterTheCapUsesAFreshNormalOnsetWindow() async {
        let rig = await stoppedSpeaker()
        rig.transcript = "Will do."
        let began = rig.clock
        for i in 0..<100 { frame(rig, 0.2 * pow(0.995, Double(i + 1))) }
        #expect(rig.recognitions.isEmpty)
        rig.clock = began + 2001
        rig.transcript = "Yes."
        for _ in 0..<8 { frame(rig, 0.06) }
        #expect(rig.recognitions.count == 1 && rig.recognitions.first?.written == 8)
        await finish(rig)
    }

    @Test(arguments: [UInt64(0), 1, 17, 923])
    func noisyRingDownDoesNotRetireOnSmallUpticks(seed: UInt64) async {
        let rig = await stoppedSpeaker()
        rig.transcript = "Will do."
        var random = seed
        for i in 0..<75 {
            let jitter: Double
            if seed == 0 {
                jitter = i == 10 ? 1.08 : 1 // the independent reviewer's probe
            } else {
                random = random &* 6364136223846793005 &+ 1442695040888963407
                jitter = 0.9 + 0.2 * Double(random >> 32) / Double(UInt32.max)
            }
            frame(rig, 0.2 * pow(0.97, Double(i + 1)) * jitter)
        }
        #expect(rig.recognitions.isEmpty && rig.controller.status.listeningSuppressed)
        frame(rig, 0.001)
        rig.input.frames(60, voiced: false)
        try? await Task.sleep(nanoseconds: 30_000_000)
        #expect(rig.recognitions.isEmpty && rig.backend.prompts.isEmpty)
        rig.controller.stop()
    }

    @Test(arguments: [25, 60])
    func sustainedWordRiseDropsAllPreRiseTailPCM(decayFrames: Int) async {
        let rig = await stoppedSpeaker()
        for i in 0..<decayFrames { frame(rig, 0.2 * pow(0.97, Double(i + 1))) }
        #expect(rig.recognitions.isEmpty)
        rig.transcript = "Yes."
        let wordLevel = decayFrames == 25 ? 0.25 : 0.08
        for _ in 0..<12 { frame(rig, wordLevel) }
        #expect(rig.recognitions.count == 1 && rig.recognitions.first?.written == 12,
                "only the candidate rise and continuing word may reach the fresh onset")
        let pcm = rig.recognitions.first?.recordedPCM ?? []
        #expect(pcm.count == 12 && pcm.allSatisfy { abs(TurnTaker.rms($0) - wordLevel) < 0.0001 },
                "ASR must not receive any held acoustic tail")
        await finish(rig)
    }
}
