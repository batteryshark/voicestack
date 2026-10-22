import SwiftUI
import AppKit
import Combine
import FloatingVoiceCore
import FloatingVoiceAudio
import FloatingVoiceUI

/// Owns the controller, the real audio engine, the pill's model and the settings state; logs the run to
/// ~/Library/Logs/FloatingVoice/<timestamp>.log.
@MainActor
final class VoiceModel {
    let controller: ConversationController
    let audio: MacAudio
    let pill = PillModel()
    let settingsState = SettingsState()
    let runLog = FileLog.forThisRun()
    private(set) var audioDiagnostics: AudioLifecycleDiagnostics!
    let hotkey = GlobalHotkey()
    let discardHotkey = GlobalHotkey(purpose: "Discard")
    private lazy var discardBinding = DiscardShortcutBinding(
        register: { [weak self] in self?.discardHotkey.register(Hotkey.discardSpec) },
        unregister: { [weak self] in self?.discardHotkey.unregister() },
        reportError: { [weak self] error in
            self?.controller.reportShortcutError(error)
            self?.runLog.write(error)
        })
    private var lastStatus = ConversationController.Status()

    init() {
        let settings = SettingsStore.load()
        let runLog = self.runLog
        var observe: ((AudioLifecycleDiagnostics.Stage) -> Void)?
        let log: (String) -> Void = { line in
            runLog.write(line)
            if let stage = AudioLifecycleDiagnostics.stage(for: line) { observe?(stage) }
        }
        // Audio and speech read the controller's current voice settings, so changes apply without a restart.
        final class Ref { weak var controller: ConversationController? }
        let ref = Ref()
        let current: () -> VoiceConfig = { MainActor.assumeIsolated { ref.controller?.voice ?? settings.voice } }
        audio = MacAudio(config: current, log: log)
        let warmup = SpeechWarmup()
        let synth = HealthCheckedSynthesizer(config: current, warmup: warmup)
        let partialsConfig = settings.voice
        controller = ConversationController(settings: settings, backend: OpenChamberClient(), synth: synth, output: audio, input: audio,
                                            micCheck: CoreAudioMicHolders(),
                                             preflight: [ServiceChecks.speech(settings.voice, warmup: warmup), ServiceChecks.recognition(settings.voice, warmup: warmup)],
                                            partialsProbe: { await ServiceChecks.partialsAdvertised(partialsConfig) },
                                             speechWarmup: warmup, log: log)
        ref.controller = controller
        audioDiagnostics = AudioLifecycleDiagnostics(write: { runLog.write($0) })
        observe = { [weak self] stage in self?.diagnose(stage) }
        audio.onDiagnosticConfiguration = { [weak self] in self?.diagnose(.graphConfig) }
        controller.outcomeDiagnostics = UtteranceOutcomeLog(write: { value, _ in
            if let data = try? JSONEncoder().encode(value), let json = String(data: data, encoding: .utf8) {
                runLog.write("utterance.outcome " + json)
            }
        }, segment: { count, _ in
            runLog.write("utterance.segment {\"segmentRollover\":\(count),\"segmentEndReason\":\"durationLimit\"}")
        })
        controller.onPrivateNotice = { [weak self] notice in
            guard self?.controller.status.running == true else { return }
            NSAccessibility.post(element: NSApp!, notification: .announcementRequested,
                                 userInfo: [.announcement: notice.rawValue, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
        let v = settings.voice
        log("Voicestack started; settings: app=\(settings.appFile) (\(FileManager.default.fileExists(atPath: settings.appFile) ? "present" : "absent")), voice=\(settings.voiceFile ?? "defaults"), target=\(settings.app.target), chiefFile=\(settings.chiefFile), busyDelivery=\(settings.app.busyDelivery.rawValue)")
        log("voice: tts=\(v.ttsUrl) model=\(v.ttsModel) voice=\(v.voice) stream=\(v.ttsStream) asr=\(v.asrUrl) input=\(v.inputDevice) output=\(v.outputDevice) echo=\(v.echoCancellation) duplex=\(v.duplex) pauseMs=\(v.pauseMs)")
        pill.attach(controller)
        pill.onDiscardAnnouncement = {
            NSAccessibility.post(element: NSApp!, notification: .announcementRequested,
                                 userInfo: [.announcement: "Discarded", .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
        pill.onHistory = { line in if !line.hasPrefix("you live") { log("pill: \(line)") } }
        settingsState.appFile = settings.appFile
        settingsState.load(voice: controller.voice, app: controller.app, running: false)
        controller.onStatus = { [weak self] s in
            guard let self else { return }
            if s.line != self.lastStatus.line { log("status: \(s.line)") }
            if s.lastError != self.lastStatus.lastError, let e = s.lastError { log("status error: \(e)") }
            self.holdActivity(s.running)
            let runningChanged = s.running != self.lastStatus.running
            self.lastStatus = s
            if runningChanged { self.syncHotkey() }
            self.pill.update(status: s)
            self.syncDiscardHotkey()
            if self.settingsState.running != s.running { self.settingsState.running = s.running }
        }
        refreshChoices()
        hotkey.onPress = { [weak self] in
            guard let self else { return }
            self.runLog.write("send hotkey pressed")
            self.controller.send()
        }
        discardHotkey.onPress = { [weak self] in
            guard let self, self.controller.status.discardHotkeyEligible else { return }
            self.controller.discardPending()
        }
        syncHotkey()
    }

    func syncDiscardHotkey() {
        discardBinding.update(controller.status)
    }

    /// The Send hotkey is registered only while voice is on in manual send mode.
    func syncHotkey() {
        guard controller.app.sendMode == .manual && controller.status.running else {
            if hotkey.registered != nil {
                hotkey.unregister()
                runLog.write("send hotkey unregistered (\(controller.status.running ? "auto send" : "voice off"))")
            }
            return
        }
        if hotkey.registered == Hotkey.parse(controller.app.sendHotkey) { return }
        if let error = hotkey.register(controller.app.sendHotkey) {
            settingsState.saveError = error
            runLog.write("send hotkey: \(error)")
        } else {
            runLog.write("send hotkey registered: \(hotkey.registered?.display ?? controller.app.sendHotkey)")
        }
    }

    /// Voices from the speech server and devices from CoreAudio, for the settings view.
    func refreshChoices() {
        let devices = audioDevices()
        settingsState.inputs = devices.filter(\.input).map { .init(id: $0.uid, label: $0.name) }
        settingsState.outputs = devices.filter(\.output).map { .init(id: $0.uid, label: $0.name) }
        let cfg = controller.voice
        Task {
            do {
                guard let list = try await HTTPSpeechSynthesizer.listVoices(cfg) else { runLog.write("settings: the speech server has no voice list"); return }
                settingsState.voices = list.voices.map { .init(id: $0.name, label: $0.label) }
                settingsState.serverDefaultVoice = list.serverDefault
                controller.speechServiceReached()
            } catch {
                runLog.write("settings: could not list voices: \(error.localizedDescription)")
                controller.speechServiceFailed(error)
            }
        }
        // Sessions on the server (title and short id, most recent first) for the Session picker.
        Task {
            let sessions = await controller.sessionChoices()
            settingsState.sessions = sessions.map { .init(id: $0.id, label: $0.label) }
            settingsState.chiefSource = controller.chiefSource
        }
        settingsState.chiefSource = controller.chiefSource
    }

    /// Keep App Nap from throttling audio and timers while voice is on.
    private var activity: NSObjectProtocol?
    private func holdActivity(_ on: Bool) {
        if on, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Voicestack is listening and speaking")
            runLog.write("app nap: activity begun")
        } else if !on, let a = activity {
            ProcessInfo.processInfo.endActivity(a)
            activity = nil
            runLog.write("app nap: activity ended")
        }
    }

    func diagnose(_ stage: AudioLifecycleDiagnostics.Stage) {
        audioDiagnostics.record(stage, audio: audio, active: controller.speaker.active, busy: controller.status.busy, queued: controller.speaker.queuedCount)
    }

    func change(_ c: SettingChange) {
        Task {
            do {
                try await controller.apply(c)
                settingsState.saveError = nil
            } catch {
                settingsState.saveError = "Not saved: \(error.localizedDescription)"
                runLog.write("settings: \(error.localizedDescription)")
            }
            settingsState.load(voice: controller.voice, app: controller.app, running: controller.status.running)
            settingsState.chiefSource = controller.chiefSource
            if case .sendMode = c { syncHotkey() }
            if case .sendHotkey = c { syncHotkey() }
        }
    }

    /// Quit path: end voice and release the microphone; held words are posted (auto send, waiting up to 2 s for the
    /// post) or discarded and logged (manual send).
    func shutdown(deliberateQuit: Bool) async {
        hotkey.unregister()
        discardHotkey.unregister()
        let done = await controller.shutdown(deliberateQuit: deliberateQuit)
        runLog.write("Voicestack quitting; microphone released\(done ? "" : "; a post may not have finished")")
    }
}

/// Borderless, non-activating floating panel: above other apps on every Space, never activates the app, and can
/// still take keystrokes for the session-id field.
final class PillPanel: NSPanel {
    var discardIfEligible: (() -> Bool)?
    override func cancelOperation(_ sender: Any?) {
        // Responder-chain Escape only, never a global/local event monitor. Settings editors and menus
        // keep their own Escape semantics; this panel never asks to become key for Discard.
        if isKeyWindow, !(firstResponder is NSTextView), !(firstResponder is NSTextField),
           discardIfEligible?() == true { return }
        super.cancelOperation(sender)
    }
    init() {
        super.init(contentRect: NSRect(origin: .zero, size: PillLayout.pill), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        becomesKeyOnlyIfNeeded = true
        isMovable = false // moved by the pill's own drag, so a click can start and stop voice
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Clicks reach the controls on the first click, without the panel having to become key first.
final class PillHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The panel's content view: the system's behind-window blur, masked to the pill's rounded shape (a stretchable
/// image, so it follows every size the panel animates through). The SwiftUI content sits on top and fills it.
final class PillGlassView: NSVisualEffectView {
    init(theme: PillTheme) {
        super.init(frame: NSRect(origin: .zero, size: PillLayout.pill))
        material = theme.material
        blendingMode = .behindWindow
        state = .active // the app is never frontmost; keep the blur live anyway
        appearance = NSAppearance(named: theme.appearance)
        let r = PillLayout.radius
        let mask = NSImage(size: NSSize(width: r * 2 + 1, height: r * 2 + 1), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        mask.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        mask.resizingMode = .stretch
        maskImage = mask
    }
    required init?(coder: NSCoder) { fatalError() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Calls back on every display frame while the pill is animating.
final class FrameTicker: NSObject {
    var onFrame: (CADisplayLink) -> Void = { _ in }
    @objc func frame(_ link: CADisplayLink) { onFrame(link) }
}

/// Places the panel, resizes it as the pill grows and shrinks (top-left corner fixed), moves it on drag and
/// remembers where it was left.
@MainActor
final class PanelController {
    let panel = PillPanel()
    let model: VoiceModel
    /// The size the panel has this frame; the SwiftUI content lays itself out at the same size.
    let motion = PillMotion()
    private let ticker = FrameTicker()
    private var link: CADisplayLink?
    private var lastFrame: CFTimeInterval?
    private var subscriptions: Set<AnyCancellable> = []
    private var levelTimer: Timer?
    private var dragStart: (mouse: NSPoint, origin: NSPoint)?
    private var dragMoved = false
    static let positionKey = "pillTopLeft"

    init(model: VoiceModel) {
        self.model = model
        var actions = PillActions.conversation(controller: model.controller,
            willStart: { [weak model] in model?.audioDiagnostics.beginVoiceRun() },
            willStopReply: { [weak model] in model?.diagnose(.stopEntry) })
        let pill = model.pill
        panel.discardIfEligible = { [weak model] in
            guard let model, !model.pill.settingsOpen, model.controller.status.pendingSpeech else { return false }
            model.controller.discardPending()
            return true
        }
        actions.openSettings = { [weak model] in model?.refreshChoices(); pill.settingsOpen = true }
        actions.closeSettings = { pill.settingsOpen = false }
        actions.showError = { pill.errorDetailsOpen = true }
        actions.clearError = { [weak model] in pill.errorDetailsOpen = false; model?.controller.clearError() }
        actions.change = { [weak model] in model?.change($0) }
        actions.preview = { [weak model] name in Task { await model?.controller.previewVoice(name) } }
        actions.setSessionID = { [weak self] in self?.askSessionID() }
        actions.quit = { NSApp.sendAction(#selector(AppDelegate.quitDeliberately(_:)), to: NSApp.delegate, from: nil) }
        actions.hover = { pill.hovering = $0 }
        actions.dragChanged = { [weak self] in self?.dragChanged() }
        actions.dragEnded = { [weak self] in self?.dragEnded() }
        // Graphite (dark glass) unless `defaults write local.floating-voice pillTheme frost`.
        let theme = PillTheme.named(PillTheme.Name(rawValue: UserDefaults.standard.string(forKey: "pillTheme") ?? "") ?? .graphite)
        motion.snap(pill)
        let root = PillRootView(model: pill, settings: model.settingsState, motion: motion, actions: actions)
            .environment(\.pillTheme, theme)
            .contextMenu { ContextMenu(model: model, pill: pill, actions: actions) }
        let host = PillHostingView(rootView: root)
        host.sizingOptions = []
        let glass = PillGlassView(theme: theme)
        host.frame = glass.bounds
        host.autoresizingMask = [.width, .height]
        glass.addSubview(host)
        panel.contentView = glass
        panel.setFrame(NSRect(origin: initialOrigin(for: motion.size), size: motion.size), display: false)
        ticker.onFrame = { [weak self] link in MainActor.assumeIsolated { self?.animate(link) } }

        pill.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.fit() }
            .store(in: &subscriptions)
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in MainActor.assumeIsolated { pill.tick() } }
        // Displays added, removed or rearranged: keep the whole pill on a screen.
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.clampToScreens() }
        }
    }

    /// Move the panel fully onto the screen it overlaps most (or the main screen), keeping its size.
    func clampToScreens() {
        let frame = panel.frame
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }
        let best = screens.max { a, b in
            let ia = a.visibleFrame.intersection(frame), ib = b.visibleFrame.intersection(frame)
            return ia.width * ia.height < ib.width * ib.height
        }
        let overlap = best.map { $0.visibleFrame.intersection(frame) } ?? .null
        let visible = (overlap.isNull || overlap.isEmpty ? (NSScreen.main ?? screens[0]) : best!).visibleFrame
        var f = frame
        f.origin.x = min(max(f.minX, visible.minX), visible.maxX - f.width)
        f.origin.y = min(max(f.minY, visible.minY), visible.maxY - f.height)
        if f.origin != frame.origin {
            panel.setFrameOrigin(f.origin)
            savePosition()
        }
    }

    func show() { panel.orderFrontRegardless() }

    // MARK: Size

    /// Point the spring at the model's size and run it on the display's frames until it settles. Each frame sets the
    /// panel's frame and the content's layout from the same value, so the shape and the words move together.
    private func fit() {
        motion.retarget(model.pill)
        guard !motion.settled else { return }
        if link == nil {
            let l = panel.contentView!.displayLink(target: ticker, selector: #selector(FrameTicker.frame(_:)))
            l.add(to: .main, forMode: .common)
            link = l
        }
        link?.isPaused = false
    }

    private func animate(_ link: CADisplayLink) {
        let dt = lastFrame.map { link.timestamp - $0 } ?? (link.targetTimestamp - link.timestamp)
        lastFrame = link.timestamp
        motion.step(dt)
        let size = motion.size
        if panel.frame.size != size {
            setFrame(topLeft: NSPoint(x: panel.frame.minX, y: panel.frame.maxY), size: size)
        }
        if motion.settled {
            link.isPaused = true
            lastFrame = nil
        }
    }

    private func setFrame(topLeft: NSPoint, size: NSSize) {
        panel.setFrame(NSRect(x: topLeft.x, y: topLeft.y - size.height, width: size.width, height: size.height), display: true)
        panel.contentView?.layoutSubtreeIfNeeded()
        clampToScreens()
        panel.invalidateShadow()
    }

    // MARK: Position

    private func initialOrigin(for size: NSSize) -> NSPoint {
        let screens = NSScreen.screens
        if let saved = UserDefaults.standard.array(forKey: Self.positionKey) as? [Double], saved.count == 2 {
            let topLeft = NSPoint(x: saved[0], y: saved[1])
            let rect = NSRect(x: topLeft.x, y: topLeft.y - size.height, width: size.width, height: size.height)
            if screens.contains(where: { $0.visibleFrame.intersects(rect) }) { return rect.origin }
        }
        let visible = (NSScreen.main ?? screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: visible.maxX - size.width - 24, y: visible.maxY - size.height - 24)
    }

    private func savePosition() {
        UserDefaults.standard.set([Double(panel.frame.minX), Double(panel.frame.maxY)], forKey: Self.positionKey)
    }

    private func dragChanged() {
        let mouse = NSEvent.mouseLocation
        guard let start = dragStart else {
            dragStart = (mouse, panel.frame.origin)
            dragMoved = false
            return
        }
        let dx = mouse.x - start.mouse.x, dy = mouse.y - start.mouse.y
        if !dragMoved && hypot(dx, dy) < 3 { return }
        dragMoved = true
        panel.setFrameOrigin(NSPoint(x: start.origin.x + dx, y: start.origin.y + dy))
    }

    /// A drag only moves the pill; clicks on its background do nothing (voice starts from its power button).
    private func dragEnded() {
        defer { dragStart = nil; dragMoved = false }
        if dragMoved { clampToScreens(); savePosition() }
    }

    // MARK: Session id

    private func askSessionID() {
        let alert = NSAlert()
        alert.messageText = "Follow a specific session"
        alert.informativeText = "Paste a session id (ses_…). Choose \"The chief\" in settings to follow the chief again."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = "ses_…"
        if model.controller.app.target != "chief" { field.stringValue = model.controller.app.target }
        alert.accessoryView = field
        alert.addButton(withTitle: "Follow")
        alert.addButton(withTitle: "Cancel")
        // The alert needs the app active; give focus back to whoever had it afterwards.
        let previous = NSWorkspace.shared.frontmostApplication
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        let answer = alert.runModal()
        if let previous, previous != NSRunningApplication.current { previous.activate() }
        guard answer == .alertFirstButtonReturn else { return }
        let id = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard id.hasPrefix("ses") else { model.settingsState.saveError = "Not saved: a session id starts with ses_"; return }
        model.change(.target(id))
    }
}

/// Right-click menu: state, voice on/off, mutes, Stop, quick settings, Settings…, Quit.
struct ContextMenu: View {
    let model: VoiceModel
    @ObservedObject var pill: PillModel
    let actions: PillActions

    var body: some View {
        Text(pill.status.running ? pill.status.line : "Voice off")
        if let e = pill.errorText {
            Text("Error: \(e)")
            Button("Clear error", action: actions.clearError)
        }
        Divider()
        Button(pill.status.running ? "Stop voice" : "Start voice", action: actions.toggleVoice)
        Button(pill.micMuted ? "Unmute mic" : "Mute mic", action: actions.toggleMic).disabled(!pill.status.running)
        Button(pill.outputMuted ? "Unmute agent voice" : "Mute agent voice", action: actions.toggleOutput).disabled(!pill.status.running)
        Button("Stop the reply", action: actions.stopReply).disabled(!pill.status.running)
        // Send now: during the countdown in auto mode, or any time in manual mode (where the hotkey also does it).
        let hotkey = model.controller.app.sendMode == .manual ? " (\(Hotkey.parse(model.controller.app.sendHotkey)?.display ?? model.controller.app.sendHotkey))" : ""
        Button("Send now\(hotkey)", action: actions.send).disabled(!pill.status.running)
        Button("Discard and start over", action: actions.discard).disabled(!pill.status.pendingSpeech)
        Divider()
        Menu("Send") {
            ForEach([SendMode.auto, .manual], id: \.self) { m in
                Button { actions.change(.sendMode(m)) } label: {
                    let label = m == .auto ? "After a pause" : "When I press Send"
                    if m == model.controller.app.sendMode { Label(label, systemImage: "checkmark") } else { Text(label) }
                }
            }
        }
        Menu("Voice") {
            ForEach(model.settingsState.voices, id: \.self) { v in
                Button { actions.change(.voice(v.id)) } label: {
                    if v.id == model.controller.voice.voice { Label(v.label, systemImage: "checkmark") } else { Text(v.label) }
                }
            }
        }
        Menu("While \(AssistantLabel.name) is busy") {
            ForEach([BusyDelivery.queue, .steer], id: \.self) { d in
                Button { actions.change(.busyDelivery(d)) } label: {
                    if d == model.controller.app.busyDelivery { Label(d == .queue ? "Queue" : "Steer", systemImage: "checkmark") } else { Text(d == .queue ? "Queue" : "Steer") }
                }
            }
        }
        Button("Settings…", action: actions.openSettings)
        Divider()
        Button("Quit Voicestack", action: actions.quit)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: VoiceModel!
    var panel: PanelController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        model = VoiceModel()
        panel = PanelController(model: model)
        panel.show()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { panel.show(); return false }
    @objc func quitDeliberately(_ sender: Any?) {
        quitIntent.requestQuit()
        NSApp.terminate(sender)
    }
    /// Quit waits (up to 2 s) for held words to be posted before the process exits.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        guard !shuttingDown else { return .terminateLater }
        let event = NSAppleEventManager.shared().currentAppleEvent
        let deliberate = quitIntent.consume(appleEvent: event)
        shuttingDown = true
        Task { @MainActor in
            await model.shutdown(deliberateQuit: deliberate)
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    private var shuttingDown = false
    private var quitIntent = QuitIntentGate()
}

// A regular app (Dock icon, Quit with ⌘Q or from the Dock); the pill itself never activates it.
let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.regular)
let mainMenu = NSMenu()
let appItem = NSMenuItem()
mainMenu.addItem(appItem)
let appMenu = NSMenu()
let quitItem = appMenu.addItem(withTitle: "Quit Voicestack", action: #selector(AppDelegate.quitDeliberately(_:)), keyEquivalent: "q")
quitItem.target = delegate
appItem.submenu = appMenu
app.mainMenu = mainMenu
app.run()
