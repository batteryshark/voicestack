import Foundation
import Testing
@testable import FloatingVoiceCore
@testable import FloatingVoiceUI

@Suite @MainActor struct PillMotionTests {
    /// Step the spring at 60 fps until it settles (or give up after `seconds`); returns the sizes it passed through.
    func run(_ m: PillMotion, seconds: Double = 2) -> [CGSize] {
        var sizes: [CGSize] = []
        for _ in 0..<Int(seconds * 60) where !m.settled { m.step(1.0 / 60); sizes.append(m.size) }
        return sizes
    }

    @Test func growsSmoothlyAndSettlesOnTheCard() {
        let r = PillRig()
        let m = PillMotion()
        m.snap(r.pill)
        #expect(m.size == PillLayout.pill)
        r.pill.handle(.youSpeaking)
        r.pill.handle(.youLive("check on dream studio"))
        m.retarget(r.pill)
        let sizes = run(m)
        #expect(m.settled && m.size == PillLayout.size(r.pill))
        #expect(sizes.count > 10 && sizes.count < 60) // animated over several frames, done within a second
        // No frame jumps more than a fifth of the way.
        let jumps = zip(sizes, sizes.dropFirst()).map { abs($1.width - $0.width) }
        #expect(jumps.max()! < (PillLayout.cardWidth - PillLayout.pill.width) / 5)
        // Overshoot stays within a couple of points.
        #expect(sizes.map(\.width).max()! <= PillLayout.cardWidth + 2)
    }

    @Test func retargetMidFlightKeepsGoingFromWhereItIs() {
        let r = PillRig()
        let m = PillMotion()
        m.snap(r.pill)
        r.pill.handle(.youSpeaking)
        m.retarget(r.pill)
        for _ in 0..<6 { m.step(1.0 / 60) }
        let mid = m.size
        r.set { $0.micMuted = true }
        r.pill.settingsOpen = true
        m.retarget(r.pill)
        m.step(1.0 / 60)
        #expect(abs(m.size.width - mid.width) < 40 && abs(m.size.height - mid.height) < 40)
        _ = run(m)
        #expect(m.size == PillLayout.settings && m.settingsFade == 1)
    }

    @Test func cardOnlyAsTallAsItsWords() {
        let youOnly = PillRig()
        youOnly.pill.handle(.youFinal("Check the build."))
        let both = PillRig()
        both.pill.handle(.youFinal("Check the build."))
        both.set { $0.speaking = true }
        both.pill.handle(.chiefStarted(label: "m", text: "The build passed."))
        let a = PillLayout.size(youOnly.pill), b = PillLayout.size(both.pill)
        #expect(a.width == PillLayout.cardWidth && b.width == PillLayout.cardWidth)
        #expect(b.height > a.height + 25)
        #expect(a.height < 150)
    }

    @Test func longWordsKeepTheNewestEnd() {
        let r = PillRig()
        let long = (1...80).map { "word\($0)" }.joined(separator: " ")
        r.pill.handle(.youFinal(long))
        let c = CardContent(r.pill)
        #expect(c.youString.hasPrefix("… "))
        #expect(c.youString.hasSuffix("word80"))
        #expect(PillLayout.lines(c.youString, PillLayout.captionFont, PillLayout.textWidth, limit: 99).count <= PillLayout.youLines)
    }
}
