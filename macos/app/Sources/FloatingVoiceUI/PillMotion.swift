import SwiftUI
import AppKit
import FloatingVoiceCore

/// Sizes of the pill's states. The card's height follows its content (only the sides that have words), so it never
/// leaves an empty block; the panel animates to these sizes, keeping its top-left corner in place.
public enum PillLayout {
    public static let radius: CGFloat = 22
    public static let pill = CGSize(width: 182, height: 44)
    public static let cardWidth: CGFloat = 360
    public static let settings = CGSize(width: 360, height: 602)

    // Card metrics (points).
    static let inset: CGFloat = 8          // buttons nest concentrically in the corners: radius 22 - button 14
    static let side: CGFloat = 16
    static let top: CGFloat = 13
    static let header: CGFloat = 16
    static let headerGap: CGFloat = 11
    static let sectionGap: CGFloat = 11
    static let label: CGFloat = 13
    static let labelGap: CGFloat = 3
    static let rowGap: CGFloat = 12
    static let button: CGFloat = 28
    static let rail: CGFloat = 3
    static let railGap: CGFloat = 10
    static let lineSpacing: CGFloat = 2.5
    static let youLines = 2
    static let chiefLines = 3
    static let bannerPad: CGFloat = 8

    static let captionFont = NSFont.systemFont(ofSize: 14, weight: .medium)
    static let errorFont = NSFont.systemFont(ofSize: 11.5, weight: .medium)
    static var textWidth: CGFloat { cardWidth - side * 2 - rail - railGap }
    static var bannerTextWidth: CGFloat { cardWidth - side * 2 - bannerPad * 2 - 14 - 7 - 16 - 6 }
    /// Height of the area the control row takes at the bottom (row plus its inset).
    static var rowArea: CGFloat { button + inset }

    @MainActor public static func size(_ model: PillModel) -> CGSize {
        if model.settingsOpen { return settings }
        return model.expanded ? CGSize(width: cardWidth, height: cardHeight(CardContent(model))) : pill
    }

    static func cardHeight(_ c: CardContent) -> CGFloat {
        var h = top + header + headerGap
        var blocks: [CGFloat] = []
        if let e = c.error { blocks.append(lines(e, errorFont, bannerTextWidth, limit: c.errorLines).height + bannerPad * 2) }
        if c.showYou { blocks.append(label + labelGap + lines(c.youString, captionFont, textWidth, limit: youLines).height) }
        if c.showChief { blocks.append(label + labelGap + lines(c.chiefString, captionFont, textWidth, limit: chiefLines).height) }
        if c.showExternal { blocks.append(label + labelGap + lines(c.external.string, captionFont, textWidth, limit: 2).height) }
        h += blocks.reduce(0, +) + sectionGap * CGFloat(max(0, blocks.count - 1))
        return ceil(h + rowGap + rowArea)
    }

    /// Lines the text wraps to at `width` (at most `limit`), and the height they take with the card's line spacing.
    static func lines(_ text: String, _ font: NSFont, _ width: CGFloat, limit: Int) -> (count: Int, height: CGFloat) {
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let key = "\(font.pointSize)|\(width)|\(text)"
        let count: Int
        if let cached = measured[key] { count = cached } else {
            let rect = NSAttributedString(string: text.isEmpty ? " " : text, attributes: [.font: font])
                .boundingRect(with: NSSize(width: width, height: 10_000), options: [.usesLineFragmentOrigin, .usesFontLeading])
            count = max(1, Int((rect.height / lineHeight).rounded()))
            if measured.count > 400 { measured.removeAll() }
            measured[key] = count
        }
        let n = min(limit, count)
        let spacing = font == captionFont ? lineSpacing : 1
        return (n, CGFloat(n) * lineHeight + CGFloat(n - 1) * spacing)
    }
    nonisolated(unsafe) private static var measured: [String: Int] = [:]

    /// The newest words that fit in `limit` lines: how many leading words to drop (shown as "…") so the end of what
    /// was said stays visible. 0 when it all fits.
    static func wordsToDrop(_ text: String, _ font: NSFont, _ width: CGFloat, limit: Int) -> Int {
        if lines(text, font, width, limit: Int.max).count <= limit { return 0 }
        let words = text.split(separator: " ", omittingEmptySubsequences: false)
        var lo = 1, hi = max(1, words.count - 1)
        while lo < hi {
            let mid = (lo + hi) / 2
            let rest = "… " + words[mid...].joined(separator: " ")
            if lines(rest, font, width, limit: Int.max).count <= limit { hi = mid } else { lo = mid + 1 }
        }
        return lo
    }
}

/// Text in runs of one colour, trimmed from the front as a whole (so a dim earlier sentence goes first).
struct Runs {
    var runs: [(String, Int)] = []   // text, style id
    var string: String { runs.map(\.0).filter { !$0.isEmpty }.joined(separator: " ") }

    /// Drop `n` leading words across the runs and mark the cut with "…".
    func droppingWords(_ n: Int) -> Runs {
        guard n > 0 else { return self }
        var left = n
        var out = Runs()
        for (text, style) in runs where !text.isEmpty {
            let words = text.split(separator: " ", omittingEmptySubsequences: false)
            if left >= words.count { left -= words.count; continue }
            let kept = words[left...].joined(separator: " ")
            out.runs.append((out.runs.isEmpty ? "… " + kept : kept, style))
            left = 0
        }
        return out
    }
}

/// What the card shows, derived once from the model so the size and the view agree.
struct CardContent {
    // Run styles.
    static let primary = 0, tail = 1, placeholder = 2

    var error: String?
    var errorLines = 2
    var showYou = false
    var showChief = false
    var showExternal = false
    var external = Runs()
    var you = Runs()
    var chief = Runs()
    /// The chief is working: its placeholder breathes.
    var thinking = false
    var youString: String { you.string }
    var chiefString: String { chief.string }

    @MainActor init(_ model: PillModel) {
        error = model.errorText
        errorLines = model.errorDetailsOpen ? 5 : 2
        let y = model.you, c = model.chief
        if let update = model.external {
            showExternal = true
            external.runs = [(update.displayText, CardContent.primary)]
            external = external.droppingWords(PillLayout.wordsToDrop(external.string, PillLayout.captionFont, PillLayout.textWidth, limit: 2))
        }
        // Between your words going in and the chief's first words: "Sent", then "<name> is thinking…" (not the old reply).
        let waiting = model.wait == .sent || model.wait == .thinking
        showChief = !c.isEmpty || waiting
        // You: your words, a held or discarded thought, or "Listening…" while you start talking or nothing else shows.
        showYou = !y.isEmpty || y.holding || y.discarded || model.status.hearing || (!showChief && !showExternal && error == nil)
        if y.isEmpty {
            you.runs = [(model.micMuted ? "Mic muted" : model.status.running ? "Listening…" : "Voice is off", CardContent.placeholder)]
        } else if y.discarded {
            you.runs = [(y.final, CardContent.tail)]
        } else {
            you.runs = [(y.final, CardContent.primary), (y.tail, CardContent.tail)]
        }
        if waiting {
            chief.runs = [(model.wait == .sent ? "Sent" : "\(model.assistantName) is thinking…", CardContent.placeholder)]
            thinking = model.wait == .thinking
        } else if !c.earlier.isEmpty {
            chief.runs = [(c.earlier, CardContent.tail), (c.current, c.speaking ? CardContent.primary : CardContent.tail)]
        } else {
            chief.runs = [(c.current, CardContent.primary)]
        }
        let f = PillLayout.captionFont, w = PillLayout.textWidth
        you = you.droppingWords(PillLayout.wordsToDrop(you.string, f, w, limit: PillLayout.youLines))
        chief = chief.droppingWords(PillLayout.wordsToDrop(chief.string, f, w, limit: PillLayout.chiefLines))
    }
}

/// The panel's size over time. One spring drives both the window frame (the app sets it from `size` every display
/// frame) and the SwiftUI layout (which reads the same `size`), so the shape and its content move together. Stills
/// and the animation frames step it by hand.
@MainActor
public final class PillMotion: ObservableObject {
    @Published public private(set) var size: CGSize
    /// 0 while the settings view is hidden, 1 when it is shown; eased when read.
    @Published public private(set) var settingsFade: Double = 0
    public private(set) var target: CGSize
    public private(set) var settingsTarget: Double = 0
    /// The spring's exact state; `size` is it rounded to whole points, so the window frame and the layout agree.
    private var exact: CGSize
    private var velocity = CGVector.zero

    /// Spring: `response` seconds per oscillation, `damping` fraction of critical.
    public var response = 0.40
    public var damping = 0.84
    public static let settingsFadeSeconds = 0.26

    public init(size: CGSize = PillLayout.pill) {
        self.size = size
        self.target = size
        self.exact = size
    }

    public var settled: Bool { exact == target && settingsFade == settingsTarget }

    /// Point the spring at the model's current size; it keeps its velocity, so a change mid-flight stays smooth.
    public func retarget(_ model: PillModel) {
        target = PillLayout.size(model)
        settingsTarget = model.settingsOpen ? 1 : 0
    }

    /// Jump straight to the target (first show, stills).
    public func snap(_ model: PillModel) {
        retarget(model)
        size = target
        exact = target
        velocity = .zero
        settingsFade = settingsTarget
    }

    /// Advance by `dt` seconds.
    public func step(_ dt: Double) {
        let dt = min(max(dt, 0), 1.0 / 20)
        var w = Double(exact.width), h = Double(exact.height)
        var vw = Double(velocity.dx), vh = Double(velocity.dy)
        let tw = Double(target.width), th = Double(target.height)
        let k = pow(2 * Double.pi / response, 2)
        let c = 4 * Double.pi * damping / response
        let n = max(1, Int(ceil(dt * 480)))
        let h1 = dt / Double(n)
        for _ in 0..<n {
            vw += (-k * (w - tw) - c * vw) * h1; w += vw * h1
            vh += (-k * (h - th) - c * vh) * h1; h += vh * h1
        }
        if abs(w - tw) < 0.2 && abs(vw) < 2 { w = tw; vw = 0 }
        if abs(h - th) < 0.2 && abs(vh) < 2 { h = th; vh = 0 }
        exact = CGSize(width: w, height: h)
        let next = CGSize(width: w.rounded(), height: h.rounded())
        if next != size { size = next }
        velocity = CGVector(dx: vw, dy: vh)

        if settingsFade != settingsTarget {
            let d = dt / PillMotion.settingsFadeSeconds
            settingsFade = settingsTarget > settingsFade ? min(settingsTarget, settingsFade + d) : max(settingsTarget, settingsFade - d)
        }
    }

    /// How far the shape is from the resting pill toward the card, 0...1, from its width.
    public var cardness: Double {
        let span = Double(PillLayout.cardWidth - PillLayout.pill.width)
        return min(1, max(0, Double(size.width - PillLayout.pill.width) / span))
    }
}

func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
    let t = min(1, max(0, (x - a) / (b - a)))
    return t * t * (3 - 2 * t)
}

func lerp(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat { a + (b - a) * CGFloat(t) }
