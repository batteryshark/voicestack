import SwiftUI
import FloatingVoiceCore

/// Choices and current values for the settings view. The app fills the choices (voices from the speech server,
/// devices from CoreAudio) and refreshes the values from the controller after each change.
@MainActor
public final class SettingsState: ObservableObject {
    public struct Choice: Hashable, Sendable {
        public let id: String
        public let label: String
        public init(id: String, label: String) { self.id = id; self.label = label }
    }

    @Published public var voices: [Choice] = []
    @Published public var serverDefaultVoice: String?
    @Published public var inputs: [Choice] = []
    @Published public var outputs: [Choice] = []
    /// The server's sessions, most recent first, as "Title · a10001".
    @Published public var sessions: [Choice] = []
    /// Where "the chief" comes from now: chief.json or the latest "Chief of staff" session.
    @Published public var chiefSource = "chief.json"

    @Published public var voice = "default"
    @Published public var inputDevice = "default"
    @Published public var outputDevice = "default"
    @Published public var echoCancellation = "auto"
    @Published public var pauseMs = 3200.0
    @Published public var sensitivity = "normal"
    @Published public var busyDelivery: BusyDelivery = .queue
    @Published public var target = "chief"
    @Published public var sendMode: SendMode = .auto
    @Published public var sendHotkey = Hotkey.defaultSpec
    @Published public var running = false
    /// Where changes are written, shown at the bottom.
    @Published public var appFile = ""
    /// Last save problem, if any.
    @Published public var saveError: String?

    public init() {}

    public func load(voice v: VoiceConfig, app: AppSettings, running: Bool) {
        voice = v.voice; inputDevice = v.inputDevice; outputDevice = v.outputDevice
        echoCancellation = v.echoCancellation; pauseMs = v.pauseMs; sensitivity = v.sensitivity
        busyDelivery = app.busyDelivery; target = app.target
        sendMode = app.sendMode; sendHotkey = app.sendHotkey
        self.running = running
    }

    public static let pauseChoices: [Double] = [1500, 2000, 2500, 3200, 4000, 5000]

    public static let pasteSessionID = "__paste__"

    /// The Session menu's current value.
    var sessionTitle: String {
        if target == "chief" { return "The chief (\(chiefSource))" }
        return sessions.first { $0.id == target }?.label ?? "Session · \(SessionSummary.shortID(target))"
    }

    var sessionChoices: [Choice] {
        [Choice(id: "chief", label: "The chief (\(chiefSource))")] + sessions + [Choice(id: SettingsState.pasteSessionID, label: "Paste a session id…")]
    }

    func label(_ list: [Choice], _ id: String, fallback: String) -> String {
        if id == "default" || id.isEmpty { return fallback }
        return list.first { $0.id == id }?.label ?? id
    }
}

struct SettingsView: View {
    @ObservedObject var model: PillModel
    @ObservedObject var settings: SettingsState
    let actions: PillActions
    @Environment(\.pillTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "waveform").font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.you)
                Text("Voicestack").font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.primary)
                Spacer()
                if model.status.pendingSpeech {
                    DiscardButton(compact: true, action: actions.discard)
                }
                Button(action: actions.closeSettings) {
                    Text("Done").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(theme.onAccent)
                        .padding(.horizontal, 11).frame(height: 22)
                        .background(Capsule().fill(LinearGradient(colors: [theme.you, theme.youDeep], startPoint: .top, endPoint: .bottom)))
                        .contentShape(Capsule())
                }
                .buttonStyle(PressStyle())
                .keyboardShortcut(.cancelAction)
            }
            .frame(height: 24)
            .padding(.bottom, 2)
            group("Voice") {
                inline("Voice") {
                    ChoiceMenu(title: settings.label(settings.voices, settings.voice, fallback: "Server default\(settings.serverDefaultVoice.map { " (\($0))" } ?? "")"),
                               choices: [SettingsState.Choice(id: "default", label: "Server default\(settings.serverDefaultVoice.map { " (\($0))" } ?? "")")] + settings.voices,
                               selected: settings.voice) { actions.change(.voice($0)) }
                    IconChip(symbol: "play.fill", help: "Preview the voice") { actions.preview(settings.voice) }
                }
                divider
                inline("Output") {
                    ChoiceMenu(title: settings.label(settings.outputs, settings.outputDevice, fallback: "System default"),
                               choices: [SettingsState.Choice(id: "default", label: "System default")] + settings.outputs,
                               selected: settings.outputDevice) { actions.change(.outputDevice($0)) }
                }
            }
            group("Listening") {
                inline("Microphone") {
                    ChoiceMenu(title: settings.label(settings.inputs, settings.inputDevice, fallback: "System default"),
                               choices: [SettingsState.Choice(id: "default", label: "System default")] + settings.inputs,
                               selected: settings.inputDevice) { actions.change(.inputDevice($0)) }
                }
                divider
                inline("Echo cancellation") {
                    Segmented(options: [("auto", "Auto"), ("on", "On"), ("off", "Off")], selected: settings.echoCancellation) { actions.change(.echoCancellation($0)) }
                }
                divider
                inline("Sensitivity") {
                    Segmented(options: [("low", "Low"), ("normal", "Normal"), ("high", "High")], selected: settings.sensitivity) { actions.change(.sensitivity($0)) }
                        .help("How far above the room's background noise speech must be. Low ignores more noise.")
                }
                divider
                stacked("Pause before sending") {
                    Segmented(options: SettingsState.pauseChoices.map { (String(Int($0)), String(format: "%g s", $0 / 1000)) },
                              selected: String(Int(settings.pauseMs)), stretch: true) { if let v = Double($0) { actions.change(.pauseMs(v)) } }
                }
            }
            group("Sending") {
                stacked("Send") {
                    Segmented(options: [("auto", "After a pause"), ("manual", "When I press Send")], selected: settings.sendMode.rawValue, stretch: true) {
                        if let m = SendMode(rawValue: $0) { actions.change(.sendMode(m)) }
                    }
                }
                divider
                inline("Send hotkey") {
                    ChoiceMenu(title: Hotkey.parse(settings.sendHotkey)?.display ?? settings.sendHotkey,
                               choices: Hotkey.presets.compactMap { spec in Hotkey.parse(spec).map { SettingsState.Choice(id: spec, label: $0.display) } },
                               selected: settings.sendHotkey) { actions.change(.sendHotkey($0)) }
                        .opacity(settings.sendMode == .manual ? 1 : 0.55)
                        .help("Global Send hotkey (manual mode)")
                }
                divider
                inline("While \(model.assistantName) is busy") {
                    Segmented(options: [("queue", "Queue"), ("steer", "Steer")], selected: settings.busyDelivery.rawValue) {
                        if let d = BusyDelivery(rawValue: $0) { actions.change(.busyDelivery(d)) }
                    }
                }
                divider
                inline("Session") {
                    ChoiceMenu(title: settings.sessionTitle, choices: settings.sessionChoices, selected: settings.target) {
                        if $0 == SettingsState.pasteSessionID { actions.setSessionID() } else { actions.change(.target($0)) }
                    }
                }
            }
            if let e = settings.saveError {
                Text(e).font(.system(size: 10.5, weight: .medium)).foregroundStyle(theme.error).lineLimit(2)
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                PlainChip(symbol: settings.running ? "stop.circle" : "play.circle", label: settings.running ? "Stop voice" : "Start voice", action: actions.toggleVoice)
                Spacer()
                PlainChip(symbol: "power", label: "Quit", action: actions.quit)
            }
            Text("Saved to \(settings.appFile)").font(.system(size: 9.5)).foregroundStyle(theme.tail).lineLimit(1).truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 11)
        .frame(width: PillLayout.settings.width, height: PillLayout.settings.height, alignment: .topLeading)
    }

    var divider: some View { Rectangle().fill(theme.divider).frame(height: 0.5).padding(.leading, 12) }

    /// A titled, rounded group of rows, like System Settings.
    func group<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased()).font(.system(size: 9.5, weight: .bold)).tracking(0.9).foregroundStyle(theme.secondary)
                .padding(.leading, 12)
            VStack(alignment: .leading, spacing: 0) { content() }
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.groupFill))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(theme.groupStroke, lineWidth: 0.5))
        }
    }

    /// Label on the left, control on the right.
    func inline<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(theme.primary.opacity(0.9)).lineLimit(1)
            Spacer(minLength: 8)
            content()
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
    }

    /// Label above a wide control.
    func stacked<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(theme.primary.opacity(0.9))
            content()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

/// A chip that opens a menu of choices (the selected one checked).
struct ChoiceMenu: View {
    let title: String
    let choices: [SettingsState.Choice]
    let selected: String
    let pick: (String) -> Void
    @Environment(\.pillTheme) private var theme

    var body: some View {
        Menu {
            ForEach(choices, id: \.self) { c in
                Button { pick(c.id) } label: {
                    if c.id == selected { Label(c.label, systemImage: "checkmark") } else { Text(c.label) }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(title).lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 7.5, weight: .bold)).foregroundStyle(theme.secondary)
            }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(theme.primary)
            .padding(.horizontal, 10).frame(height: 24)
            .background(Capsule().fill(theme.buttonFill))
            .overlay(Capsule().strokeBorder(theme.buttonStroke, lineWidth: 0.5))
            .frame(maxWidth: 196, alignment: .trailing)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct IconChip: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @Environment(\.pillTheme) private var theme

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 9, weight: .bold))
                .foregroundStyle(theme.you)
                .frame(width: 24, height: 24)
                .background(Circle().fill(theme.you.opacity(0.16)))
                .overlay(Circle().strokeBorder(theme.you.opacity(0.3), lineWidth: 0.5))
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle())
        .help(help)
    }
}

struct PlainChip: View {
    let symbol: String
    let label: String
    let action: () -> Void
    @Environment(\.pillTheme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                Text(label)
            }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(theme.primary.opacity(0.9))
            .padding(.horizontal, 11).frame(height: 26)
            .background(Capsule().fill(theme.buttonFill))
            .overlay(Capsule().strokeBorder(theme.buttonStroke, lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
    }
}

/// Capsule segmented choice, drawn in SwiftUI. `stretch` spreads the segments over the full width.
struct Segmented: View {
    let options: [(String, String)]
    let selected: String
    var stretch = false
    let pick: (String) -> Void
    @Environment(\.pillTheme) private var theme

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { id, label in
                Button { pick(id) } label: {
                    Text(label)
                        .font(.system(size: 11, weight: id == selected ? .semibold : .medium))
                        .foregroundStyle(id == selected ? theme.segmentText : theme.primary.opacity(0.78))
                        .lineLimit(1)
                        .padding(.horizontal, 8).frame(height: 22)
                        .frame(maxWidth: stretch ? .infinity : nil)
                        .background(Capsule().fill(id == selected ? theme.segmentFill : Color.clear)
                            .shadow(color: .black.opacity(id == selected ? 0.18 : 0), radius: 1.5, y: 0.5))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Capsule().fill(theme.buttonFill))
        .overlay(Capsule().strokeBorder(theme.buttonStroke, lineWidth: 0.5))
    }
}
