import SwiftUI
import FloatingVoiceCore

/// What the pill's controls do. The app wires these to the controller and the panel; still rendering leaves them empty.
@MainActor
public struct PillActions {
    public var toggleVoice: () -> Void = {}
    /// The power button shown while voice is off.
    public var startVoice: () -> Void = {}
    public var toggleMic: () -> Void = {}
    public var toggleOutput: () -> Void = {}
    public var stopReply: () -> Void = {}
    /// Send held words now (manual send mode).
    public var send: () -> Void = {}
    public var discard: () -> Void = {}
    public var openSettings: () -> Void = {}
    public var closeSettings: () -> Void = {}
    public var showError: () -> Void = {}
    public var clearError: () -> Void = {}
    public var change: (SettingChange) -> Void = { _ in }
    public var preview: (String) -> Void = { _ in }
    public var setSessionID: () -> Void = {}
    public var quit: () -> Void = {}
    /// Background drag: the app moves the panel with the pointer; a drag that never moved is a click.
    public var dragChanged: () -> Void = {}
    public var dragEnded: () -> Void = {}
    public var hover: (Bool) -> Void = { _ in }
    public init() {}
}

/// The whole floating module in one shape. It is laid out at `motion.size`, the size the panel has this frame, and
/// morphs between the resting pill and the card: the control row rides the bottom edge (the visualizer widens, the
/// gear turns into Stop), the words are revealed above it, and settings cross-fade in.
public struct PillRootView: View {
    @ObservedObject var model: PillModel
    @ObservedObject var settings: SettingsState
    @ObservedObject var motion: PillMotion
    let actions: PillActions
    @Environment(\.pillTheme) private var theme

    public init(model: PillModel, settings: SettingsState, motion: PillMotion, actions: PillActions) {
        self.model = model; self.settings = settings; self.motion = motion; self.actions = actions
    }

    public var body: some View {
        let size = motion.size
        let p = motion.cardness
        // Settings and the pill/card swap in sequence (out, then in), so their words never overlap mid-fade.
        let f = motion.settingsFade
        let s = smoothstep(0, 0.6, f)
        let settingsIn = smoothstep(0.4, 1, f)
        let shape = RoundedRectangle(cornerRadius: min(PillLayout.radius, size.height / 2), style: .circular)
        let content = CardContent(model)
        ZStack(alignment: .topLeading) {
            PillSurface(shape: shape, size: size)
                .contentShape(shape)
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { _ in actions.dragChanged() }
                    .onEnded { _ in actions.dragEnded() })

            // The words, revealed above the control row as the card opens.
            CardTop(model: model, settings: settings, content: content, actions: actions)
                .offset(y: CGFloat(1 - smoothstep(0.2, 1, p)) * -8)
                .opacity(smoothstep(0.15, 0.75, p) * (1 - s))
                .frame(width: size.width, height: max(0, size.height - PillLayout.rowArea - 2), alignment: .topLeading)
                .mask(RevealMask(height: max(1, size.height - PillLayout.rowArea - 2)))
                .allowsHitTesting(p > 0.95 && s < 0.05)

            ControlRow(model: model, settings: settings, actions: actions, p: p)
                .frame(width: size.width, height: PillLayout.button)
                .offset(y: size.height - PillLayout.inset - PillLayout.button)
                .opacity(1 - s)
                .allowsHitTesting(s < 0.05)

            if motion.settingsFade > 0 {
                SettingsView(model: model, settings: settings, actions: actions)
                    .frame(width: PillLayout.settings.width, height: PillLayout.settings.height, alignment: .topLeading)
                    .offset(y: CGFloat(1 - settingsIn) * 6)
                    .opacity(settingsIn)
                    .allowsHitTesting(settingsIn > 0.95)
            }

            PillEdges(shape: shape, error: model.hasError)
                .allowsHitTesting(false)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipShape(shape)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .environment(\.colorScheme, theme.colorScheme)
        .onHover { actions.hover($0) }
        .help(model.stateLine)
    }
}

/// Opaque, with a short fade along the bottom edge, so words are revealed softly above the control row as the card
/// grows (when it is open the fade falls in the gap below the words).
struct RevealMask: View {
    let height: CGFloat
    var body: some View {
        let fade = min(1, 9 / height)
        LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 1 - fade), .init(color: .clear, location: 1)],
                       startPoint: .top, endPoint: .bottom)
    }
}

// MARK: Surface

/// The glass: the system blur shows through in the app (or a simulated one in stills), a tint, and a soft sheen.
struct PillSurface<S: Shape>: View {
    let shape: S
    let size: CGSize
    @Environment(\.pillTheme) private var theme
    @Environment(\.pillBackdrop) private var backdrop

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let backdrop {
                Image(nsImage: backdrop.image)
                    .resizable()
                    .frame(width: backdrop.image.size.width, height: backdrop.image.size.height)
                    .offset(x: -backdrop.origin.x, y: -backdrop.origin.y)
                Rectangle().fill(theme.materialWash.opacity(theme.materialWashOpacity))
            }
            Rectangle().fill(theme.tint)
            // A little light from above.
            LinearGradient(colors: [Color.white.opacity(theme.name == .graphite ? 0.06 : 0.18), Color.white.opacity(0)],
                           startPoint: .top, endPoint: UnitPoint(x: 0.5, y: min(1, 70 / max(size.height, 1))))
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipShape(shape)
    }
}

/// Hairline edges: a dark outer line that separates the module from light content, a lit inner line along the top.
struct PillEdges<S: InsettableShape>: View {
    let shape: S
    let error: Bool
    @Environment(\.pillTheme) private var theme

    var body: some View {
        ZStack {
            shape.strokeBorder(error ? theme.error.opacity(0.85) : theme.outerStroke, lineWidth: error ? 1.25 : 0.5)
            shape.inset(by: error ? 1.25 : 0.5)
                .strokeBorder(LinearGradient(colors: [theme.innerHighlight, theme.innerShade, theme.innerShade.opacity(0.6)],
                                             startPoint: .top, endPoint: .bottom), lineWidth: 0.5)
        }
    }
}

// MARK: Control row

/// Visualizer on the left, buttons on the right, pinned to the bottom edge. In the pill: mic, speaker, gear. In the
/// card: (Send,) mic, speaker, Stop, with Stop taking the gear's place in the corner.
struct ControlRow: View {
    @ObservedObject var model: PillModel
    @ObservedObject var settings: SettingsState
    let actions: PillActions
    let p: Double
    @Environment(\.pillTheme) private var theme

    var body: some View {
        let running = model.status.running
        let card = smoothstep(0.5, 1, p)
        HStack(spacing: 0) {
            VisualizerView(levels: model.levels, voice: model.voice, dimmed: model.dimmed || !running)
                .frame(width: lerp(running ? 52 : 34, model.status.pendingSpeech ? 40 : 92, p), height: 22)
                .allowsHitTesting(false)
                .overlay(alignment: .topTrailing) {
                    if model.hasError {
                        // Compact error state: a red dot (and border); clicking it opens the details in the card.
                        Button(action: actions.showError) {
                            Circle().fill(theme.error).frame(width: 7, height: 7)
                                .overlay(Circle().strokeBorder(Color.black.opacity(0.25), lineWidth: 0.5))
                                .padding(4).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .offset(x: 9, y: -7)
                        .opacity(1 - card)
                        .help(model.errorText ?? "")
                    }
                }
                .padding(.leading, 16)
            Spacer(minLength: 10)
            HStack(spacing: 6) {
                if model.status.pendingSpeech {
                    DiscardButton(action: actions.discard)
                }
                if running && model.status.manualSend {
                    SendButton(holding: model.you.holding, hotkey: hotkeyLabel, action: actions.send)
                        .fixedSize()
                        .frame(width: CGFloat(card) * 74, alignment: .trailing)
                        .opacity(card)
                        .padding(.trailing, CGFloat(card) * 6 - 6)
                        .allowsHitTesting(card > 0.9)
                }
                if running {
                    CircleButton(symbol: model.micMuted ? "mic.slash.fill" : "mic.fill", active: model.micMuted,
                                 help: model.micMuted ? "Unmute mic" : "Mute mic", action: actions.toggleMic)
                    CircleButton(symbol: model.outputMuted ? "speaker.slash.fill" : "speaker.wave.2.fill", active: model.outputMuted,
                                 help: model.outputMuted ? "Unmute agent voice" : "Mute agent voice", action: actions.toggleOutput)
                } else {
                    StartButton(action: actions.startVoice)
                }
                // The corner slot: the gear in the pill, Stop in the card.
                ZStack {
                    CircleButton(symbol: "gearshape.fill", active: false, plain: true, help: "Settings", action: actions.openSettings)
                        .opacity(1 - card)
                        .allowsHitTesting(card < 0.5)
                    if running {
                        CircleButton(symbol: "stop.fill", active: false, accent: model.status.speaking ? theme.chief : nil,
                                     help: "Stop: stop speaking and interrupt \(model.assistantName)'s turn", action: actions.stopReply)
                            .opacity(card)
                            .scaleEffect(0.7 + 0.3 * card)
                            .allowsHitTesting(card >= 0.5)
                    }
                }
                // Voice off: the card has no Stop, so the slot closes up.
                .frame(width: running ? PillLayout.button : PillLayout.button * CGFloat(1 - card), height: PillLayout.button)
                .padding(.leading, running ? 0 : -6 * CGFloat(card))
            }
            .padding(.trailing, PillLayout.inset)
        }
    }

    var hotkeyLabel: String { Hotkey.parse(settings.sendHotkey)?.display ?? settings.sendHotkey }
}

// MARK: Card

/// Header (session and state, gear), an error banner, then You and Chief, each only when it has something to show.
struct CardTop: View {
    @ObservedObject var model: PillModel
    @ObservedObject var settings: SettingsState
    let content: CardContent
    let actions: PillActions
    @Environment(\.pillTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Circle().fill(dotColor).frame(width: 6, height: 6)
                    .shadow(color: dotColor.opacity(model.phase == .ready ? 0.7 : 0), radius: 3)
                if model.status.warmingSpeech {
                    Text(SpeechWarmup.text)
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.secondary)
                        .lineLimit(1).layoutPriority(1)
                } else if model.noiseHint {
                    // The room is too loud for the pause to be heard: say so, and where to fix it.
                    Button(action: actions.openSettings) {
                        HStack(spacing: 5) {
                            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10, weight: .semibold))
                            Text(PillModel.noiseHintText).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                        }
                        .foregroundStyle(theme.chief)
                    }
                    .buttonStyle(PressStyle())
                    .help("Open Settings › Sensitivity")
                } else {
                // While the "Sending in 3" cue is shown it says what is happening, so the state word makes room for it.
                (Text(title).foregroundColor(theme.primary.opacity(0.78)) + Text(countdownCue == nil ? "  ·  \(stateWord)" : "").foregroundColor(theme.secondary))
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1).truncationMode(.middle)
                    .layoutPriority(1)
                }
                Spacer(minLength: 4)
                if let cue = countdownCue {
                    CountdownCue(wait: cue, action: actions.send)
                        .transition(.opacity)
                }
                Button(action: actions.openSettings) {
                    Image(systemName: "gearshape.fill").font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.secondary)
                        .frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
                .help("Settings")
                .padding(.trailing, -5)
            }
            .frame(height: PillLayout.header)
            Color.clear.frame(height: PillLayout.headerGap)
            VStack(alignment: .leading, spacing: PillLayout.sectionGap) {
                if let e = content.error {
                    ErrorBanner(text: e, lines: content.errorLines, clear: actions.clearError)
                }
                if content.showYou {
                    CaptionSection(label: youLabel, labelColor: youLabelColor, rail: model.you.discarded ? theme.error : theme.you,
                                   active: model.voice == .you && !model.dimmed, runs: content.you, limit: PillLayout.youLines,
                                    strike: false)
                }
                if content.showChief {
                    CaptionSection(label: model.assistantLabel, labelColor: theme.chief, rail: theme.chief,
                                   active: model.voice == .chief || model.chief.speaking, runs: content.chief, limit: PillLayout.chiefLines,
                                   strike: false, breathing: content.thinking)
                }
                if content.showExternal, let update = model.external {
                    CaptionSection(label: update.sender.label, labelColor: update.sender.isYou ? theme.you : theme.external,
                                   rail: update.sender.isYou ? theme.you : theme.external,
                                   active: false, runs: content.external, limit: 2, strike: false)
                }
            }
        }
        .padding(.top, PillLayout.top)
        .padding(.horizontal, PillLayout.side)
        .frame(width: PillLayout.cardWidth, alignment: .topLeading)
    }

    /// "Chief of staff · a10001": the attached session's title and a short id.
    var title: String { model.status.targetLabel ?? (model.status.running ? "No session yet" : "Voicestack") }

    var countdownCue: PillModel.Wait? {
        switch model.wait {
        case .countdown, .sending: return model.wait
        default: return nil
        }
    }

    var stateWord: String {
        switch model.phase {
        case .off: return "Voice off"
        case .starting: return "Starting…"
        case .connecting: return "Connecting…"
        case .ready:
            if model.status.speaking && !model.outputMuted { return "Speaking" }
            if model.micMuted { return "Mic muted" }
            if model.status.hearing { return "Hearing you" }
            if model.status.busy { return "Working" }
            return "Listening"
        }
    }

    var dotColor: Color {
        if model.hasError { return theme.error }
        switch model.phase {
        case .ready: return theme.ready
        case .off: return theme.idle
        default: return theme.chief
        }
    }

    var hotkeyLabel: String { Hotkey.parse(settings.sendHotkey)?.display ?? settings.sendHotkey }

    var youLabel: String {
        if model.you.discarded { return "You · unsent speech cleared" }
        if model.status.manualSend { return model.you.holding ? "Holding · Send or \(hotkeyLabel)" : "You · manual send" }
        return model.you.holding ? "Holding" : "You"
    }

    var youLabelColor: Color { model.you.discarded ? theme.error : theme.you }
}

/// "Sending in 3": a ring that empties and the seconds left, in the header while you are quiet before your words go in.
/// Clicking it sends now.
struct CountdownCue: View {
    let wait: PillModel.Wait
    let action: () -> Void
    @StateObject private var hovering = Hover()
    @Environment(\.pillTheme) private var theme

    var body: some View {
        let (fraction, label): (Double, String) = {
            switch wait {
            case .countdown(let s, let f): return (f, "Sending in \(s)")
            default: return (0, "Sending…")
            }
        }()
        Button(action: action) {
            HStack(spacing: 5) {
                ZStack {
                    Circle().stroke(theme.you.opacity(0.28), lineWidth: 1.6)
                    Circle().trim(from: 0, to: CGFloat(fraction))
                        .stroke(theme.you, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 11, height: 11)
                Text(label).font(.system(size: 10.5, weight: .semibold)).monospacedDigit()
            }
            .foregroundStyle(theme.you)
            .padding(.horizontal, 8).frame(height: 20)
            .background(Capsule().fill(theme.you.opacity(hovering.on ? 0.26 : 0.15)))
            .overlay(Capsule().strokeBorder(theme.you.opacity(0.35), lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
        .onHover { hovering.on = $0 }
        .help("Send now")
    }
}

/// A coloured rail, a small caps label and the words.
struct CaptionSection: View {
    let label: String
    let labelColor: Color
    let rail: Color
    let active: Bool
    let runs: Runs
    let limit: Int
    let strike: Bool
    /// The words slowly fade in and out (the chief is thinking).
    var breathing = false
    @Environment(\.pillTheme) private var theme

    var body: some View {
        let height = PillLayout.lines(runs.string, PillLayout.captionFont, PillLayout.textWidth, limit: limit).height
        HStack(alignment: .top, spacing: PillLayout.railGap) {
            Capsule()
                .fill(LinearGradient(colors: [rail, rail.opacity(0.55)], startPoint: .top, endPoint: .bottom))
                .opacity(active ? 1 : 0.38)
                .shadow(color: rail.opacity(active ? theme.glow * 0.8 : 0), radius: 4)
                .frame(width: PillLayout.rail, height: PillLayout.label + PillLayout.labelGap + height)
            VStack(alignment: .leading, spacing: PillLayout.labelGap) {
                Text(label.uppercased())
                    .font(.system(size: 9.5, weight: .bold))
                    .tracking(0.9)
                    .foregroundStyle(labelColor.opacity(active ? 1 : 0.78))
                    .lineLimit(1)
                    .frame(height: PillLayout.label, alignment: .leading)
                TimelineView(.animation(minimumInterval: 1 / 20, paused: !breathing)) { context in
                    text
                        .font(Font(PillLayout.captionFont))
                        .lineSpacing(PillLayout.lineSpacing)
                        .lineLimit(limit)
                        .opacity(breathing ? 0.62 + 0.38 * (0.5 + 0.5 * sin(context.date.timeIntervalSinceReferenceDate * 3.2)) : 1)
                        .frame(width: PillLayout.textWidth, height: height, alignment: .topLeading)
                }
            }
        }
    }

    var text: Text {
        var t: Text?
        for (s, style) in runs.runs where !s.isEmpty {
            var piece = Text((t == nil ? "" : " ") + s).foregroundColor(style == CardContent.primary ? theme.primary : theme.tail)
            if style == CardContent.placeholder { piece = piece.italic() }
            if strike { piece = piece.strikethrough(true, color: theme.tail) }
            t = t.map { $0 + piece } ?? piece
        }
        return t ?? Text(" ")
    }
}

struct ErrorBanner: View {
    let text: String
    let lines: Int
    let clear: () -> Void
    @Environment(\.pillTheme) private var theme

    var body: some View {
        let height = PillLayout.lines(text, PillLayout.errorFont, PillLayout.bannerTextWidth, limit: lines).height
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.error)
                .frame(width: 14, height: 15)
            Text(text)
                .font(Font(PillLayout.errorFont))
                .lineSpacing(1)
                .foregroundStyle(theme.primary.opacity(0.9))
                .lineLimit(lines)
                .textSelection(.enabled)
                .frame(width: PillLayout.bannerTextWidth, height: height, alignment: .topLeading)
            Spacer(minLength: 0)
            Button(action: clear) {
                Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(theme.secondary)
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(theme.buttonFill))
            }
            .buttonStyle(PressStyle())
            .help("Dismiss")
        }
        .padding(PillLayout.bannerPad)
        .frame(width: PillLayout.cardWidth - PillLayout.side * 2, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.error.opacity(theme.name == .graphite ? 0.14 : 0.09)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(theme.error.opacity(0.30), lineWidth: 0.5))
    }
}

// MARK: Buttons

struct DiscardButton: View {
    var compact = false
    let action: () -> Void
    @Environment(\.pillTheme) private var theme
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.counterclockwise").font(.system(size: 10, weight: .semibold))
                Text("Discard")
            }
            .font(.system(size: compact ? 11 : 12, weight: .semibold))
            .foregroundStyle(theme.secondary)
            .padding(.horizontal, compact ? 7 : 10).frame(height: compact ? 22 : PillLayout.button)
            .background(Capsule().fill(theme.buttonFill))
            .overlay(Capsule().strokeBorder(theme.buttonStroke, lineWidth: 0.5))
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel("Discard and start over")
        .help(Hotkey.discardHelp)
    }
}

/// Pointer-over state for a button (@State needs SwiftUI's macro plugin, which the Command Line Tools lack).
final class Hover: ObservableObject { @Published var on = false }

/// Shrinks a little while pressed.
struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// A round glass button. `active` (a mute that is on) fills it; `accent` tints it (Stop while the chief speaks);
/// `plain` has no fill until hovered.
struct CircleButton: View {
    let symbol: String
    let active: Bool
    var accent: Color? = nil
    var plain = false
    let help: String
    let action: () -> Void
    @StateObject private var hovering = Hover()
    private var hover: Bool { hovering.on }
    @Environment(\.pillTheme) private var theme
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: symbol == "stop.fill" ? 10.5 : 12, weight: .semibold))
                .foregroundStyle(glyph)
                .frame(width: PillLayout.button, height: PillLayout.button)
                .background(Circle().fill(fill))
                .overlay(Circle().strokeBorder(stroke, lineWidth: 0.5))
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle())
        .onHover { hovering.on = $0 }
        .help(help)
    }

    var glyph: Color {
        if active { return theme.activeGlyph }
        if let accent { return accent }
        return plain ? theme.secondary : theme.glyph.opacity(enabled ? 1 : 0.45)
    }
    var fill: Color {
        if active { return theme.activeFill }
        if let accent { return accent.opacity(hover ? 0.30 : 0.20) }
        if plain { return hover ? theme.buttonFill : .clear }
        return hover ? theme.buttonHover : theme.buttonFill
    }
    var stroke: Color {
        if active || plain { return .clear }
        if let accent { return accent.opacity(0.35) }
        return theme.buttonStroke
    }
}

/// Start voice (shown while it is off). Stopping is in the right-click menu and Settings, so a stray click on the
/// pill never cuts voice off.
struct StartButton: View {
    let action: () -> Void
    @Environment(\.pillTheme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "power").font(.system(size: 10.5, weight: .bold))
                Text("Start")
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(theme.onAccent)
            .padding(.horizontal, 12).frame(height: PillLayout.button)
            .background(Capsule().fill(LinearGradient(colors: [theme.you, theme.youDeep], startPoint: .top, endPoint: .bottom)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.22), lineWidth: 0.5))
            .shadow(color: theme.you.opacity(theme.glow * 0.6), radius: 6, y: 1)
            .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
        .help("Start voice")
    }
}

/// Send held words (manual send mode): filled while words are held.
struct SendButton: View {
    let holding: Bool
    let hotkey: String
    let action: () -> Void
    @Environment(\.pillTheme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up").font(.system(size: 10, weight: .bold))
                Text("Send")
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(holding ? theme.onAccent : theme.secondary)
            .padding(.horizontal, 12).frame(height: PillLayout.button)
            .background(Capsule().fill(holding ? AnyShapeStyle(LinearGradient(colors: [theme.you, theme.youDeep], startPoint: .top, endPoint: .bottom))
                                               : AnyShapeStyle(theme.buttonFill)))
            .overlay(Capsule().strokeBorder(holding ? Color.white.opacity(0.22) : theme.buttonStroke, lineWidth: 0.5))
            .shadow(color: theme.you.opacity(holding ? theme.glow * 0.6 : 0), radius: 6, y: 1)
            .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
        .help("Send what you said (\(hotkey))")
    }
}

// MARK: Visualizer

/// One visualizer for whoever is talking: blue for the principal, amber for the chief. The newest level is in the
/// middle and older ones ripple outward on both sides, under a soft lens-shaped envelope.
public struct VisualizerView: View {
    let levels: [Double]
    let voice: PillModel.Voice
    let dimmed: Bool
    var bars = 13
    @Environment(\.pillTheme) private var theme

    public init(levels: [Double], voice: PillModel.Voice, dimmed: Bool, bars: Int = 13) {
        self.levels = levels; self.voice = voice; self.dimmed = dimmed; self.bars = bars
    }

    public var body: some View {
        GeometryReader { geo in
            let mid = bars / 2
            let w = geo.size.width / (CGFloat(bars) + 0.65 * CGFloat(bars - 1))
            let gap = w * 0.65
            let (top, bottom) = colors
            let peak = levels.suffix(4).max() ?? 0
            HStack(alignment: .center, spacing: gap) {
                ForEach(0..<bars, id: \.self) { i in
                    let d = abs(i - mid)
                    let v = d < levels.count ? levels[levels.count - 1 - d] : 0
                    let envelope = 0.5 + 0.5 * cos(Double(d) / Double(mid + 1) * .pi / 2)
                    let shown = dimmed ? 0 : v * envelope
                    Capsule()
                        .fill(LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom))
                        .frame(width: w, height: max(w, geo.size.height * CGFloat(0.10 + 0.90 * shown)))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .shadow(color: top.opacity(dimmed || voice == .none ? 0 : theme.glow * min(1, 0.35 + peak)), radius: 5)
        }
        .animation(.linear(duration: 0.06), value: levels)
    }

    var colors: (Color, Color) {
        if dimmed { return (theme.idle, theme.idle) }
        switch voice {
        case .you: return (theme.you, theme.youDeep)
        case .chief: return (theme.chief, theme.chiefDeep)
        case .none: return (theme.idle, theme.idle)
        }
    }
}
