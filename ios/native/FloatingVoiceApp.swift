import SwiftUI
import WebKit
import AVFoundation

enum InstalledBuild {
    static var number: Int { Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") ?? 0 }
    static var label: String { "build \(number)" }
}

@main struct FloatingVoiceApp: App {
    @UIApplicationDelegateAdaptor(PushAppDelegate.self) private var delegate
    @StateObject private var model = PhoneModel.shared
    var body: some Scene { WindowGroup {
#if DEBUG && targetEnvironment(simulator)
        if PolishPreview.enabled { PolishPreview().preferredColorScheme(.dark) }
        else if ProcessInfo.processInfo.arguments.contains("-FVRichFixture") { RichContentFixtureScreen().preferredColorScheme(.dark) }
        else if DeviceAudioProbe.enabled { DeviceAudioProbeView() }
        else { ConversationView(model: model).preferredColorScheme(.dark) }
#else
        if DeviceAudioProbe.enabled { DeviceAudioProbeView() }
        else { ConversationView(model: model).preferredColorScheme(.dark) }
#endif
    } }
}

@MainActor final class PhoneModel: ObservableObject {
    static let shared = PhoneModel()
    @Published var reachOutHistory = false
    @Published var historyMessageID: String?
    @Published var historyNavigation = HistoryNavigation()
    private var joiningInvitation: IncomingCallOwner?
    @Published var status = ConversationController.Status()
    @Published var error: String?
    @Published var routeRetryAvailable = false
    @Published var routeRetryInProgress = false
    @Published var historyGap = false
    var turnControls: VoiceTurnControls {
        VoiceTurnControls(status: status, bargeIn: { [weak self] in self?.controller?.bargeIn() })
    }
    var principalError: String? { PrincipalError.message(error ?? status.lastError, captureRunning: surface.captureRunning) }
    @Published var messages: [MessageRow] = []
    @Published var canvasMessages: [MessageRow] = []
    @Published var sessions: [SessionSummary] = []
    @Published var voices: [String] = []
    private var defaultVoice: String?
    @Published var review: [BoundDraft] = []
    @Published var live = ""
    @Published var cue = ""
    @Published var sendDeadline: Date?
    @Published var noisy = false
#if DEBUG && targetEnvironment(simulator)
    @Published var discardFixturePromptCount = 0
#endif
    @Published var paired = false
    @Published var connecting = false
    @Published var selection = "chief"
    let canvasProbeGate = LaunchRouteGate()
    @Published var canvasProbeError: String?
    @Published var canvasProbeReady = false
    @Published var typed = ""
    let surface = VoiceSurface()
    var historyVisible = false
    @Published var link: LinkDestination?
    let coordinator = AudioSessionCoordinator()
    private var probeMode: Bool { DeviceAudioProbe.enabled || ProcessInfo.processInfo.arguments.contains("-FVSimulatorProof") }
    lazy var calls: CallCoordinator = {
        let calls: CallCoordinator
#if DEBUG && targetEnvironment(simulator)
        if PolishPreview.enabled { calls = CallCoordinator(makeProvider: { _ in PolishCallProvider() }) }
        else { calls = CallCoordinator(audio: coordinator) }
#else
        calls = CallCoordinator(audio: coordinator)
#endif
        calls.beginMedia = { [weak self] epoch in await self?.beginVoice(callEpoch: epoch) == true }
        calls.pauseMedia = { [weak self] in
            guard let self else { return }
            self.voiceLifecycle.invalidate()
            self.surface.preparing = false
            self.controller?.speaker.pause()
            self.audio?.pauseForCall()
            self.controller?.onReviewDraft = { [weak self] in self?.retainReview($0) }
            self.controller?.pauseForCall()
            self.objectWillChange.send()
        }
        calls.endMedia = { [weak self] in self?.endVoiceMedia() }
        calls.onTerminal = { [weak self] in self?.reconcileAfterCall() }
        calls.recoveryPaused = { [weak self] _ in self?.showRecoveryPause() }
        calls.mediaReady = { [weak self] in
            self?.routeRetryInProgress = false; self?.routeRetryAvailable = false
            if self?.error == RouteRecoveryNotice.paused || self?.error == RouteSwitchError.unavailable.localizedDescription { self?.error = nil }
        }
        calls.setMuted = { [weak self] in self?.voiceLifecycle.setMicMuted($0) }
        calls.changed = { [weak self] in
            guard let self else { return }
            self.recordCallState()
            self.objectWillChange.send()
        }
        calls.failed = { [weak self] message in
            self?.error = message
            if !message.hasPrefix("Audio route") && (message.contains("Voice") || message.contains("Audio")) { self?.surface.updateCapture(.failed, owner: self?.surface.binding ?? UUID()) }
        }
        coordinator.onRouteError = { [weak self] message in
            guard let self else { return }
            if self.hasCall { self.calls.pauseMediaForRouteRecovery() } else { self.error = message }
        }
        return calls
    }()
    var hasCall: Bool { !probeMode && calls.hasCall }
    private var lastCallSnapshot = ""
    private func recordCallState() {
        let state = calls.lifecycle.state
        let code = [CallLifecycle.State.idle, .starting, .ringing, .connecting, .active, .held, .ending, .ended].firstIndex(of: state) ?? 0
        let key = "\(code):\(calls.lifecycle.activationGranted):\(calls.lifecycle.muted):\(calls.routeLabel)"
        guard key != lastCallSnapshot else { return }; lastCallSnapshot = key
        StageDiagnostics.shared.record(.call, .complete, audio: CaptureSnapshot([
            .callState: Double(code), .callActivation: calls.lifecycle.activationGranted ? 1 : 0,
            .callMuted: calls.lifecycle.muted ? 1 : 0, .callEpoch: Double(calls.lifecycle.epoch)]))
        VoiceTrace.shared.event("call.state", ["state": state.rawValue, "activation": String(calls.lifecycle.activationGranted), "muted": String(calls.lifecycle.muted), "route": calls.routeLabel])
    }
    func recordProbeLiveness() {
        StageDiagnostics.shared.availability(UIApplication.shared.isProtectedDataAvailable)
        audio?.recordLiveness()
        StageDiagnostics.shared.record(.probe, .complete, audio: CaptureSnapshot([
            .networkConnected: backend?.connection == "connected" ? 1 : 0,
            .appActive: UIApplication.shared.applicationState == .active ? 1 : 0,
            .streamBytes: Double(backend?.streamLiveness?.bytes ?? 0),
            .streamIdleSeconds: backend?.streamLiveness?.idleSeconds ?? 0]))
    }
    var backend: RemoteSessionBackend?
    var controller: ConversationController?
    private var transport: BridgeTransport?
    private var audio: IOSAudio?
    var routeCaptureReady: Bool { audio?.captureGraphReady == true }
    private var preparation: Task<Void, Never>?
    private var preparationEpoch = 0
    private var stopping = false
    var savedSettings: LoadedSettings { SettingsStore.load(env: ["FV_SETTINGS": URL.applicationSupportDirectory.appendingPathComponent("settings.json").path, "FV_CHIEF_FILE": "/nonexistent-native-chief"]) }
    let voiceLifecycle = NativeVoiceLifecycle()
    private let credentialRecovery = CredentialRecoveryGate()
    private init() {
        surface.pill.onDiscardAnnouncement = { UIAccessibility.post(notification: .announcement, argument: "Discarded") }
        StageDiagnostics.shared.configure(file: URL.applicationSupportDirectory.appendingPathComponent("Diagnostics/stages.json"), build: InstalledBuild.number)
        if ProcessInfo.processInfo.arguments.contains("-FVProbeCleanup") {
            // Only the harness-owned fixture, never settings, credentials or the container.
            let fixture = URL.documentsDirectory.appendingPathComponent("phone-loop.wav")
            if FileManager.default.fileExists(atPath: fixture.path) { try? FileManager.default.removeItem(at: fixture) }
            StageDiagnostics.shared.record(.probe, .cancelled, status: 1)
        }
        if PhoneLoopProbe.enabled { PhoneLoopProbe.install(); selection = PhoneLoopProbe.target }
        if SpeakerEchoProbe.enabled { selection = PhoneLoopProbe.target }
    }
    func resume() {
#if DEBUG && targetEnvironment(simulator)
        if PolishPreview.enabled { return }
#endif
        PushCoordinator.shared.foreground()
        guard !hasCall else { return } // the retained backend handles its own reconnects
        guard UIApplication.shared.isProtectedDataAvailable, UIApplication.shared.applicationState == .active else { return }
        guard credentialRecovery.permit(available: true) else { return }
        StageDiagnostics.shared.availability(true)
        if !paired && !connecting { preparation = Task { await prepare() } }
    }
    func suspend() {
        // Inactive, lock and protected-data notifications are not hang-up. Networking owns its
        // own recovery; never replace/disconnect the call's backend, controller or transport here.
        guard !hasCall else {
            StageDiagnostics.shared.record(.call, .suspended, callEvent: .scenePreserved, reportedRinging: calls.incomingReportedRinging)
            return
        }
        preparationEpoch += 1; preparation?.cancel(); preparation = nil
        voiceLifecycle.suspend(typed: &typed, target: backend?.lease,
            retain: { [weak self] in self?.retainReview($0) }, disconnect: { [self] in backend?.disconnect(cause: .background) })
        updateConversation()
        paired = false
        StageDiagnostics.shared.availability(UIApplication.shared.isProtectedDataAvailable)
        StageDiagnostics.shared.record(.startup, .suspended)
    }
    private func reconcileAfterCall() {
        CallSceneReconciler.reconcile(hasCall: hasCall,
            foreground: UIApplication.shared.applicationState == .active,
            protectedDataAvailable: UIApplication.shared.isProtectedDataAvailable,
            suspend: { self.suspend() })
    }
    func prepare() async {
#if DEBUG && targetEnvironment(simulator)
        if PolishPreview.enabled { return }
#endif
        guard !hasCall else { return }
        guard UIApplication.shared.isProtectedDataAvailable, UIApplication.shared.applicationState == .active else { return }
        guard !connecting else { return }; connecting = true
        let owner = preparationEpoch, started = Date()
        defer {
            connecting = false
            if owner != preparationEpoch { resume() }
        }
        StageDiagnostics.shared.record(.startup, .begin)
        do {
            guard let endpoint = Bundle.main.object(forInfoDictionaryKey: "BridgeURL") as? String, let base = URL(string: endpoint) else { throw ClientError("Missing signed endpoint configuration") }
            let keychain = KeychainCredential()
#if DEBUG && targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains("-FVSimulatorProof") {
                selection = try SimulatorAudioProof.shared.identity(keychain)
            }
#endif
            let transport = try BridgeTransport(base: base, credentials: keychain)
            self.transport = transport
            if try keychain.load() == nil {
                guard let bootstrap = Bundle.main.object(forInfoDictionaryKey: "PairingBootstrap") as? String, !bootstrap.isEmpty else { throw ClientError("Update has no readable device credential. Unlock and reconnect; if still missing, contact the lead before re-pairing.") }
                try await transport.pair(bootstrap: bootstrap, pending: KeychainCredential(account: "pairing-pending"), makeProof: KeychainCredential.makeProof)
            }
            let backend = RemoteSessionBackend(transport: transport)
            if PhoneLoopProbe.enabled { PhoneLoopProbe.shared.observe(backend) }
#if DEBUG && targetEnvironment(simulator)
            backend.onActivity = { stage, count in SimulatorAudioProof.shared.event(stage, ["count": Double(count)]) }
#endif
            self.backend = backend
            backend.onChange = { [weak self] in self?.updateConversation() }
            backend.onError = { _ in StageDiagnostics.shared.record(.events, .failed, status: 1) }
            _ = try await backend.connect()
            try Task.checkCancellation(); guard owner == preparationEpoch else { return }
            try await select(selection)
            paired = true
            PushCoordinator.shared.retry()
            var speechFailure: String?
            do {
                let available = try await transport.json("/tts/v1/voices")
                let parsed = HTTPSpeechSynthesizer.parseVoices(available)
                voices = parsed.voices.map(\.name); defaultVoice = parsed.serverDefault
            } catch {
                // Speech availability is not device pairing or session authority.
                speechFailure = SpeechServiceError.describe(url: transport.base.absoluteString + "/tts/v1/audio/speech", error: error)
            }
            sessions = try await backend.listSessions()
            StageDiagnostics.shared.record(.startup, .complete, since: started)
            credentialRecovery.succeeded()
            error = speechFailure
        } catch {
            credentialRecovery.failed(status: StageDiagnostics.code(error))
            StageDiagnostics.shared.record(.startup, .failed, since: started, status: StageDiagnostics.code(error))
            if owner == preparationEpoch { self.paired = false; self.error = error.localizedDescription }
        }
    }
    func select(_ selection: String) async throws {
        guard !hasCall else { throw ClientError("End the call before changing session; drafts remain in History") }
        guard let backend else { return }
        // Preserve owner before granting any replacement lease, including same-session reselection.
        endVoiceMedia() // No active call is admitted above; selection never impersonates user End.
        if !typed.isEmpty, let lease = backend.lease { review.append(BoundDraft(target: lease, text: typed)); typed = "" }
        surface.replaceBinding(target: nil)
        live = ""; cue = ""; sendDeadline = nil; noisy = false
        controller = nil; voiceLifecycle.controller = nil
        try await backend.select(selection)
        self.selection = selection
        StageDiagnostics.shared.record(.selection, .complete, audio: CaptureSnapshot([.chiefSelection: selection == "chief" ? 1 : 0]))
        controller = nil
        updateConversation()
    }
    func updateConversation() {
        guard let backend else { return }
        if hasCall, joiningInvitation == nil, calls.lifecycle.target != nil, calls.lifecycle.target != backend.lease {
            calls.mediaFailed(.leaseFailure)
        }
        let records = backend.displayRecords
        historyGap = backend.catchUpIncomplete
#if DEBUG && targetEnvironment(simulator)
        SimulatorAudioProof.shared.event("history.projected", ["records": Double(records.count)])
#endif
        if surface.target != backend.lease { surface.replaceBinding(target: backend.lease) }
        if historyVisible {
            messages = records.compactMap(MessageRow.init)
            historyNavigation.rowsChanged(newestRow: messages.last?.id)
        }
        canvasMessages = records.suffix(40).compactMap(MessageRow.init).filter { row in row.body.contains { $0.reference?.format == "canvas_show" } }
        surface.update(records: records, connection: backend.connection, active: backend.store?.active == true)
        let combined = backend.review + (controller?.draftsForReview ?? [])
        for draft in combined { retainReview(draft) }
        objectWillChange.send()
    }
    func retainReview(_ draft: BoundDraft) {
        if let id = draft.recoveryID, let index = review.firstIndex(where: { $0.recoveryID == id }) { review[index] = draft }
        else if !review.contains(draft) { review.append(draft) }
    }
    /// Answer is explicit authority to select this invitation, not the previously viewed chief.
    func joinInvitation(_ context: ReachOutContext, owner: IncomingCallOwner) async throws -> TargetLease {
        try owner.validate(calls.lifecycle) // No mutation, including draft cleanup, before this fence.
        joiningInvitation = owner
        defer { if joiningInvitation == owner { joiningInvitation = nil } }
        preparationEpoch += 1; preparation?.cancel(); preparation = nil
        if !typed.isEmpty, let lease = backend?.lease { retainReview(BoundDraft(target: lease, text: typed)); typed = "" }
        controller?.onReviewDraft = { [weak self] in self?.retainReview($0) }
        controller?.suspendForReview(); controller?.stop(discardUnfinished: true)
        for draft in (backend?.review ?? []) + (controller?.draftsForReview ?? []) { retainReview(draft) }
        controller = nil; voiceLifecycle.controller = nil; surface.replaceBinding(target: nil)
        backend?.disconnect()
        guard let endpoint = Bundle.main.object(forInfoDictionaryKey: "BridgeURL") as? String, let base = URL(string: endpoint) else { throw ClientError("Bridge unavailable") }
        let transport = try BridgeTransport(base: base, credentials: KeychainCredential())
        let backend = RemoteSessionBackend(transport: transport)
        self.transport = transport; self.backend = backend
        backend.onChange = { [weak self] in self?.updateConversation() }
        backend.onError = { _ in StageDiagnostics.shared.record(.events, .failed, status: 1) }
        _ = try await backend.connect()
        try owner.validate(calls.lifecycle)
        try await backend.select(context.session)
        try owner.validate(calls.lifecycle)
        guard let lease = backend.lease, lease.sessionID == context.session else { throw ClientError("Call ended") }
        selection = context.session; paired = true; updateConversation()
        return lease
    }
    func openReachOut(_ context: ReachOutContext, reviewBuild: Bool) async throws {
        try await NotificationRouting.step(.prepare) {
            guard !self.hasCall else { throw NotificationRouteFailure.targetChanged }
            let deadline = Date().addingTimeInterval(12)
            while self.connecting, Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
            guard !self.connecting else { throw NotificationRouteFailure.preparation }
            if self.backend == nil || !self.paired { await self.prepare() }
            guard self.paired, self.backend != nil else { throw NotificationRouteFailure.preparation }
        }
        guard let routeBackend = backend else { throw NotificationRouteFailure.preparation }
        let target = try await NotificationRouting.step(.select) {
            try await self.select(context.session)
            guard self.backend === routeBackend, let target = routeBackend.lease, target.sessionID == context.session else { throw NotificationRouteFailure.targetChanged }
            return target
        }
        try await NotificationRouting.step(.catchUp) { try await routeBackend.waitForAuthoritativeCatchUp(target) }
        try await NotificationRouting.step(.message) {
            if let id = context.messageID { try await routeBackend.locateMessage(id, target: target, maxOlderPages: 20) }
        }
        let request = try await NotificationRouting.step(.present) {
            guard UIApplication.shared.applicationState == .active, UIApplication.shared.isProtectedDataAvailable else { throw NotificationRouteFailure.inactive }
            guard self.backend === routeBackend, routeBackend.lease == target, !self.hasCall else { throw NotificationRouteFailure.targetChanged }
            if reviewBuild, let url = context.reviewURL, phoneLinkPolicy.install(url) == nil { throw NotificationRouteFailure.invalidContext }
            let records = routeBackend.displayRecords
            guard let sourceID = context.messageID ?? records.compactMap(MessageRow.init).last?.id,
                  let anchor = HistoryAnchor.resolve(sourceID, records: records) else { throw NotificationRouteFailure.messageUnavailable }
            self.historyMessageID = sourceID
            self.historyVisible = true; self.updateConversation()
            let request = self.historyNavigation.request(anchor, newestRow: self.messages.last?.id)
            self.reachOutHistory = true
            self.error = nil
            return request
        }
        try await NotificationRouting.step(.viewport) {
            let deadline = Date().addingTimeInterval(15)
            while self.historyNavigation.confirmedRequest != request {
                try Task.checkCancellation()
                guard self.backend === routeBackend, routeBackend.lease == target,
                      self.historyNavigation.requestID == request, self.historyNavigation.pinned,
                      self.historyVisible, !self.hasCall else { throw NotificationRouteFailure.targetChanged }
                guard UIApplication.shared.applicationState == .active, UIApplication.shared.isProtectedDataAvailable else { throw NotificationRouteFailure.inactive }
                guard Date() < deadline else {
                    self.historyNavigation.dismiss()
                    throw NotificationRouteFailure.viewportTimeout
                }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            guard self.backend === routeBackend, routeBackend.lease == target,
                  UIApplication.shared.applicationState == .active, UIApplication.shared.isProtectedDataAvailable else { throw NotificationRouteFailure.targetChanged }
        }
        if reviewBuild, let url = context.reviewURL {
            link = LinkDestination(url: url)
        }
    }
    func startVoice() async {
        if probeMode { _ = await beginVoice(); return }
        guard !hasCall, !surface.preparing else { return }
        let owner = voiceLifecycle.requestStart()
        surface.preparing = true
        defer { surface.preparing = false }
        do {
            guard UIApplication.shared.applicationState == .active, paired, let backend, let lease = backend.lease else { throw ClientError("Select a connected session first") }
            try await coordinator.permission()
            let validated = try await backend.targetLease(sessionID: lease.sessionID)
            guard voiceLifecycle.isCurrent(owner) else { return }
            guard backend.lease == lease, validated == lease, !hasCall else { throw ClientError("Session changed; try Start again") }
            calls.start(target: lease)
        } catch { self.error = error.localizedDescription }
    }
    private func beginVoice(callEpoch: Int? = nil) async -> Bool {
        StageDiagnostics.shared.record(.startUI, .begin)
        guard callEpoch != nil || !surface.preparing else { StageDiagnostics.shared.record(.startUI, .failed, status: 1); return false }
        let owner = voiceLifecycle.requestStart()
        surface.preparing = true
        defer { if voiceLifecycle.generation == owner { surface.preparing = false } }
        let started = Date(); StageDiagnostics.shared.record(.capture, .begin)
        do {
            guard !stopping, let backend, let transport, let lease = backend.lease else {
                StageDiagnostics.shared.record(.startUI, .failed, status: 2)
                throw ClientError("Select a connected session first")
            }
            _ = try await backend.targetLease(sessionID: lease.sessionID)
            guard voiceLifecycle.isCurrent(owner), callEpoch == nil || (calls.lifecycle.admits(callEpoch!) && calls.lifecycle.mayRunMedia && calls.lifecycle.target == lease) else { return false }
            if controller == nil {
                let audio = IOSAudio(coordinator: coordinator); self.audio = audio
                audio.onRoutePaused = { [weak self] in self?.pauseRouteRecovery() }
                audio.onRecoveryRequest = { [weak self] event in
                    guard let self else { return }
                    if self.probeMode { self.voiceLifecycle.handle(event); return }
                    switch event {
                    case .interruptionBegan: self.calls.interrupted()
                    case .mediaReset: self.calls.mediaReset()
                    case .interruptionEnded, .routeChanged: break // only didActivate may resume
                    }
                }
                let file = URL.applicationSupportDirectory.appendingPathComponent("settings.json").path
                var settings = SettingsStore.load(env: ["FV_SETTINGS": file, "FV_CHIEF_FILE": "/nonexistent-native-chief"])
                let stored = (try? Data(contentsOf: URL(fileURLWithPath: file))).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
                if stored?["voice"] == nil, let defaultVoice { settings.voice.voice = defaultVoice }
                settings.app.target = lease.sessionID
                settings.voice = try transport.voiceConfig(settings.voice)
                let cfg = settings.voice
                let warmup = SpeechWarmup()
                let synth = HealthCheckedSynthesizer(config: { [weak self] in self?.controller?.voice ?? cfg }, warmup: warmup)
                let controller = ConversationController(settings: settings, backend: backend, synth: synth, output: audio, input: audio,
                    makeRecognition: { callbacks in
                        HealthCheckedRecognition(endpoint: cfg.asrUrl, key: cfg.asrApiKey, callbacks: callbacks, warmup: warmup) {
                            WebSocketRecognition(url: cfg.asrUrl, apiKey: cfg.asrApiKey, partials: true, callbacks: $0)
                        }
                    }, chiefPollInterval: 15, partialsProbe: { true }, speechWarmup: warmup)
                self.controller = controller
                voiceLifecycle.controller = controller
                let binding = surface.replaceBinding(target: lease)
                audio.onCaptureState = { [weak self] state in self?.surface.updateCapture(state, owner: binding) }
                controller.onStatus = { [weak self] status in
                    guard let self, self.surface.binding == binding, self.backend?.lease == lease else { return }
                    self.status = status; self.surface.update(status: status, owner: binding); self.updateConversation()
                    if PhoneLoopProbe.enabled { PhoneLoopProbe.shared.status(self) }
#if DEBUG && targetEnvironment(simulator)
                    SimulatorAudioProof.shared.event("controller.status", ["ready": status.phase == "ready" ? 1 : 0, "connected": status.connection == "connected" ? 1 : 0])
#endif
                }
                controller.onCaption = { [weak self] event in
                    guard let self, self.backend?.lease == lease else { return }
                    self.caption(event, owner: binding)
                }
                backend.onNarration = { [weak controller] in controller?.consumeNarration($0) }
            }
            await voiceLifecycle.start(owner)
            StageDiagnostics.shared.record(.capture, status.running ? .ready : .failed, since: started)
            guard voiceLifecycle.isCurrent(owner) else { return false }
            audio?.onFailure = { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    if let callEpoch {
                        guard self.calls.lifecycle.admits(callEpoch) else { return }
                        self.calls.mediaFailed(.captureFailure)
                    } else if !self.hasCall {
                        self.audio?.pauseForCall()
                        self.error = "Microphone paused. Try Start voice again."
                        self.surface.updateCapture(.failed, owner: self.surface.binding)
                    }
                }
            }
            let deadline = Date().addingTimeInterval(12)
            while status.running, status.phase != "ready", Date() < deadline, !Task.isCancelled {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            let ready = status.running && status.phase == "ready" && !Task.isCancelled
            return ready
        } catch {
            guard voiceLifecycle.isCurrent(owner), callEpoch == nil || calls.lifecycle.admits(callEpoch!) else { return false }
            StageDiagnostics.shared.record(.capture, .failed, since: started, status: StageDiagnostics.code(error))
            self.error = error.localizedDescription
        }
        return false
    }
    private func pauseRouteRecovery() {
        guard hasCall else { audio?.pauseForCall(); error = RouteRecoveryNotice.paused; return }
        // Cancels initial/resumed beginMedia ownership too; its late false result
        // must not turn a nonterminal route pause into CallCoordinator.finish().
        calls.pauseMediaForRouteRecovery()
    }
    private func showRecoveryPause() {
        routeRetryInProgress = false; routeRetryAvailable = true
        error = RouteRecoveryNotice.paused
        surface.updateCapture(.failed, owner: surface.binding)
    }
    func retryRouteAudio() {
        guard routeRetryAvailable, !routeRetryInProgress, hasCall,
              calls.lifecycle.mayRunMedia, coordinator.active else { return }
        routeRetryAvailable = false; routeRetryInProgress = true
        audio?.retryRouteCapture()
        calls.resumeMediaAfterRouteRecovery()
    }
    func stopVoiceByUser() async {
        if hasCall { calls.end(); return }
        endVoiceMedia()
    }
    private func endVoiceMedia() {
        routeRetryAvailable = false; routeRetryInProgress = false
        if error == RouteRecoveryNotice.paused { error = nil }
        voiceLifecycle.invalidate()
        surface.preparing = false
        guard let controller, !stopping else { return }
        stopping = true; defer { stopping = false }
        // Stop is not Send: fence recognition and discard unfinished words, never flush to a session.
        controller.onReviewDraft = { [weak self] in self?.retainReview($0) }
        controller.suspendForReview()
        controller.stop(discardUnfinished: true)
        if !controller.composer.held.isEmpty, let lease = controller.currentLease {
            let draft = BoundDraft(target: lease, text: controller.composer.held)
            if !review.contains(draft) { review.append(draft) }
        }
        updateConversation()
    }
    func sendTyped() async {
        guard let backend, let lease = backend.lease, !typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let text = typed; typed = ""
        let binding = surface.binding
        surface.beginTypedTurn(text, owner: binding)
        surface.submitting = true
        defer { surface.submitting = false }
        do {
            try await backend.prompt(target: lease, text: text, delivery: backend.store?.active == true ? .queue : nil)
            surface.typedPosted(text, owner: binding)
        }
        catch { self.error = "Message: " + error.localizedDescription }
        updateConversation()
    }
    func stopReply() async {
        if controller?.status.running == true { await controller?.stopReply() }
        else if let backend, let lease = backend.lease {
            do { _ = try await backend.interrupt(target: lease) } catch { self.error = "Reply: " + error.localizedDescription }
        }
    }
    func discardPending() {
        controller?.discardPending()
    }
    func caption(_ event: CaptionEvent, owner: UUID) {
        guard owner == surface.binding else { return }
        switch event {
        case .chiefStarted: // PhoneModel's speech error comes from the optional TTS voice list.
            if error?.hasPrefix("Speech service at ") == true { error = nil }
        default: break
        }
        if PhoneLoopProbe.enabled { PhoneLoopProbe.shared.caption(event, model: self) }
#if DEBUG && targetEnvironment(simulator)
        switch event {
        case .youLive(let text): SimulatorAudioProof.shared.event("asr.partial", ["characters": Double(text.count)])
        case .youFinal(let text): SimulatorAudioProof.shared.event("asr.final", ["characters": Double(text.count)])
        case .posted(let text): SimulatorAudioProof.shared.event("composer.posting", ["characters": Double(text.count)])
        case .chiefQueued(_, let text): SimulatorAudioProof.shared.event("model.sentence", ["characters": Double(text.count)])
        default: break
        }
#endif
        surface.handle(event, owner: owner)
        switch event {
        case .youLive(let text): live = text
        case .youFinal(let text): live = text
        case .youIdle: live = ""
        case .countdown(let total, let elapsed, _): sendDeadline = Date().addingTimeInterval(max(0, total-elapsed)/1000); cue = ""
        case .countdownCancelled: cue = ""; sendDeadline = nil
        case .posted: cue = "Sent · thinking"; sendDeadline = nil
        case .discarded:
            live = ""; cue = ""; sendDeadline = nil
        case .noisy(let value): noisy = value
        default: break
        }
    }
    func change(_ change: SettingChange) async {
        do {
            if let controller { try await controller.apply(change) }
            else { try SettingsStore.save([change.key: change.value], to: URL.applicationSupportDirectory.appendingPathComponent("settings.json").path) }
        } catch { self.error = error.localizedDescription }
    }
}

struct LinkDestination: Identifiable { let id = UUID(); let url: URL }

struct ConversationView: View {
    @ObservedObject var model: PhoneModel
    @State private var settings = false
    @State private var history = false
    @Environment(\.scenePhase) private var phase
    var body: some View {
        NavigationStack {
            VoiceMainView(model: model, surface: model.surface, pill: model.surface.pill)
                .navigationTitle("Voicestack").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button("History", systemImage: "clock") { model.historyVisible = true; model.updateConversation(); history = true } }
                    ToolbarItem(placement: .topBarTrailing) { Button("Settings", systemImage: "gearshape") { settings = true } }
                }
                .sheet(isPresented: $history, onDismiss: { model.historyVisible = false; model.messages = []; model.historyNavigation.dismiss(); model.historyMessageID = nil }) { HistoryView(model: model) }
                .sheet(isPresented: $settings) { SettingsView(model: model) }
                .sheet(item: Binding(get: { history ? nil : model.link }, set: { model.link = $0 })) { destination in NavigationStack { PrivateLinkView(url: destination.url).toolbar { Button("Done") { model.link = nil } } } }
                .environment(\.openURL, OpenURLAction { url in
                    guard phoneLinkPolicy.web(url) || phoneLinkPolicy.install(url) != nil else { return .discarded }
                    model.link = LinkDestination(url: url); return .handled
                })
                .task { model.resume() }
                .task { if PhoneLoopProbe.enabled { await PhoneLoopProbe.shared.run(model) } }
                .task { if SpeakerEchoProbe.enabled { await SpeakerEchoProbe.shared.run(model) } }
                .task { if CanvasDeviceProbe.enabled { await CanvasDeviceProbe.run(model) } }
                .safeAreaInset(edge: .top, spacing: 0) { CanvasProbeStatus(model: model) }
                .onReceive(NotificationCenter.default.publisher(for: PhoneLoopProbe.showHistory)) { _ in
                    model.historyVisible = true; model.updateConversation(); history = true
                }
                .onChange(of: model.reachOutHistory, initial: true) { _, value in if value { settings = false; history = true; model.reachOutHistory = false } }
                .onChange(of: phase) { _, phase in if phase == .active { model.resume() } else { model.suspend() } }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataWillBecomeUnavailableNotification)) { _ in model.suspend() }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataDidBecomeAvailableNotification)) { _ in model.resume() }
        }
    }
}

struct VoiceMainView: View {
    @ObservedObject var model: PhoneModel
    @ObservedObject var surface: VoiceSurface
    @ObservedObject var pill: PillModel
    @State private var followLog = BottomFollow()
    @State private var browsingLog = false
    @State private var audioSettings = false
    private let blue = Color(red: 0.42, green: 0.73, blue: 1)
    private let amber = Color(red: 1, green: 0.72, blue: 0.36)
    var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.turnControls.sendDeadlineMs != nil ? "Ready to send" : model.turnControls.halfDuplex && model.turnControls.listeningSuppressed ? "\(AgentPresentation.name) speaking" : surface.state).font(.headline).accessibilityAddTraits(.updatesFrequently).accessibilityIdentifier("voice.state")
                Spacer()
                Text(InstalledBuild.label).font(.caption2).foregroundStyle(.secondary).accessibilityIdentifier("voice.build")
            }
            if model.selection != "chief" {
                Text(sessionDisplayName)
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("voice.target")
            }
            // voice-turns merge seam: status.sendCountdown + tap controller.send(), not a second timer here.
            if let deadline = model.turnControls.sendDeadlineMs {
                TimelineView(.periodic(from: .now, by: 0.25)) { context in
                    Button("Sending in \(max(0, Int(ceil((deadline - countdownTime(context.date)) / 1000))))") { model.controller?.send() }
                        .font(.callout).accessibilityIdentifier("voice.sendCountdown")
                }
            }
            if model.hasCall && model.calls.lifecycle.state == .held { Text("Call on hold · not listening").font(.caption) }
            if !surface.captureRunning && surface.capture != .repairing && (surface.preparing || model.status.running && model.status.phase != "ready") { ProgressView().controlSize(.small) }
            if let notice = surface.connectionNotice { Text(notice).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("voice.connectionNotice") }
            HStack(spacing: 16) {
                VStack(spacing: 2) {
                Text("YOU").font(.caption2).foregroundStyle(blue)
                NativeWaveform(levels: pill.micLevels, voice: .you, ready: surface.captureRunning)
                    .frame(height: 28).accessibilityElement(children: .ignore).accessibilityLabel("Your measured microphone level").accessibilityIdentifier("voice.inputWaveform")
                }
                VStack(spacing: 2) {
                Text(AgentPresentation.name.uppercased()).font(.caption2).foregroundStyle(amber).accessibilityLabel(AgentPresentation.name).accessibilityIdentifier("voice.assistantWaveformLabel")
                NativeWaveform(levels: pill.outputLevels, voice: .chief, ready: surface.captureRunning)
                    .frame(height: 28).accessibilityElement(children: .ignore).accessibilityLabel("\(AgentPresentation.name) measured rendered level").accessibilityIdentifier("voice.outputWaveform")
                    .contentShape(Rectangle()).onTapGesture { if model.turnControls.canBargeIn { model.turnControls.bargeIn?() } }
                if model.turnControls.canBargeIn && model.turnControls.halfDuplex && model.turnControls.listeningSuppressed {
                    Button("Tap to cut in") { model.turnControls.bargeIn?() }.font(.caption).accessibilityIdentifier("voice.bargeIn")
                } else if model.turnControls.halfDuplex && model.turnControls.listeningSuppressed {
                    Text("\(AgentPresentation.name) speaking").font(.caption).foregroundStyle(.secondary)
                }
                }
            }.padding(.horizontal, 6)
            ScrollViewReader { proxy in
                VStack(spacing: 4) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            if surface.log.turns.isEmpty { Text("Your conversation appears here").foregroundStyle(.secondary).padding() }
                            ForEach(surface.log.turns) { turn in
                                VoiceLogBubble(turn: turn, latestUser: lastUserID, latestChief: lastChiefID)
                                    .contentShape(Rectangle()).onTapGesture {
                                        if turn.role == .chief && turn.id == lastChiefID && model.turnControls.canBargeIn { model.turnControls.bargeIn?() }
                                    }
                                    .accessibilityAction(named: "Cut in") {
                                        if turn.role == .chief && turn.id == lastChiefID && model.turnControls.canBargeIn { model.turnControls.bargeIn?() }
                                     }.id(turn.id)
                                ForEach(turn.panelMessageIDs, id: \.self) { messageID in
                                    if let row = model.canvasMessages.first(where: { $0.id == messageID }) {
                                        ForEach(Array(row.body.enumerated()), id: \.offset) { ordinal, part in
                                            if part.reference?.format == "canvas_show" {
                                                MessageContentView(model: model, row: row, part: part, ordinal: ordinal)
                                            }
                                        }
                                    }
                                }
                            }
                            Color.clear.frame(height: 1).id("voice.log.bottom")
                                .onAppear { followLog.userScrolled(bottomVisible: true); browsingLog = false }
                                .onDisappear { if browsingLog { followLog.userScrolled(bottomVisible: false) } }
                        }.padding(6)
                    }.accessibilityIdentifier("voice.conversationLog").defaultScrollAnchor(.bottom).scrollIndicators(.visible)
                        .task { await Task.yield(); proxy.scrollTo("voice.log.bottom", anchor: .bottom) }
                        .simultaneousGesture(DragGesture().onChanged { value in if value.translation.height > 8 { browsingLog = true; followLog.userScrolled(bottomVisible: false) } })
                        .onChange(of: surface.log.turns) { _, _ in if followLog.following { Task { @MainActor in await Task.yield(); if followLog.following { proxy.scrollTo("voice.log.bottom", anchor: .bottom) } } } }
                        .onChange(of: surface.target) { _, _ in followLog.selected(); browsingLog = false; proxy.scrollTo("voice.log.bottom", anchor: .bottom) }
                    if !followLog.following { Button("Jump to latest") { followLog.selected(); browsingLog = false; proxy.scrollTo("voice.log.bottom", anchor: .bottom) }.font(.caption).accessibilityIdentifier("voice.jumpLatest") }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).layoutPriority(1).background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 16))
            if let message = model.principalError { Text(message).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("voice.error") }
            routeRecoveryControls
            if model.status.warmingSpeech { Text(SpeechWarmup.text).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("voice.warming") }
            if model.historyGap { Text("Some earlier replies could not be recovered. Open History to check them.").font(.caption).foregroundStyle(.secondary) }
            if model.noisy { Text("Room is noisy · words determine the pause").font(.caption).foregroundStyle(.orange) }
            if !model.review.isEmpty { Text("\(model.review.count) earlier draft(s) retained for review in History").font(.caption).foregroundStyle(.orange) }
            if model.status.canDiscard {
                callButton("Discard", symbol: "arrow.counterclockwise", on: true, id: "voice.discard", accessibility: "Discard and start over", value: "") {
                    model.discardPending()
                }.frame(maxWidth: 100)
            } else if surface.discardConfirmation {
                Text("Discarded").font(.callout).accessibilityIdentifier("voice.discardConfirmation")
            }
#if DEBUG && targetEnvironment(simulator)
            if PolishPreview.enabled && PolishPreview.mode.hasPrefix("discard-") {
                Text("Prompts: \(model.discardFixturePromptCount)").font(.caption2).accessibilityIdentifier("discard.fixture.posts")
            }
#endif
            HStack(alignment: .top, spacing: 12) {
                // Reusable callButton styling leaves the manual controller.bargeIn() action to voice-turns.
                callButton("Mute mic", symbol: model.voiceLifecycle.micMuted ? "mic.slash.fill" : "mic.fill", on: model.voiceLifecycle.micMuted, id: "voice.micMute") {
                    if model.hasCall { model.calls.mute(!model.voiceLifecycle.micMuted) }
                    else { model.voiceLifecycle.setMicMuted(!model.voiceLifecycle.micMuted); model.objectWillChange.send() }
                }
                callButton("Mute voice", symbol: model.voiceLifecycle.outputMuted ? "speaker.slash.fill" : "speaker.wave.2.fill", on: model.voiceLifecycle.outputMuted, id: "voice.outputMute") {
                    model.voiceLifecycle.setOutputMuted(!model.voiceLifecycle.outputMuted); model.objectWillChange.send()
                }
                callButton(routeLabel, symbol: routeLabel.hasPrefix("Bluetooth") ? "headphones" : speakerOn ? "speaker.wave.2.fill" : "phone.fill", on: speakerOn, id: "voice.speaker", accessibility: speakerOn ? "Speaker" : "Speaker, current route \(routeLabel)") {
                    if model.hasCall || model.status.running {
                        if [.speaker, .phone].contains(model.coordinator.currentPhoneRoute) {
                            do { try model.coordinator.toggleLiveRoute() }
                            catch RouteSwitchError.unavailable {
                                if model.hasCall { model.calls.routeControlRejected() }
                                else { model.error = RouteSwitchError.unavailable.localizedDescription }
                            }
                            catch {
                                if model.hasCall { model.calls.pauseMediaForRouteRecovery() }
                                else { model.error = error.localizedDescription }
                            }
                        } else { audioSettings = true }
                    } else { audioSettings = true }
                }.contextMenu { if model.hasCall { Button("Audio route settings") { audioSettings = true } } }
                    .disabled(model.hasCall && !model.calls.mayChangeLiveRoute)
                callButton(model.hasCall || model.status.running ? "End" : "Start", symbol: model.hasCall || model.status.running ? "phone.down.fill" : "phone.fill", on: false, id: "voice.startStop", end: model.hasCall || model.status.running, accessibility: model.hasCall ? "End call" : model.status.running || surface.preparing ? "Stop voice" : "Start voice", value: model.hasCall ? model.calls.lifecycle.state == .active ? "In call" : model.calls.lifecycle.state == .held ? "On hold" : "Starting call" : nil) {
                    Task { if model.hasCall || model.status.running || surface.preparing { await model.stopVoiceByUser() } else { await model.startVoice() } }
                }.disabled(!model.paired && !surface.preparing)
            }
            HStack(spacing: 8) {
                TextField("Message", text: $model.typed, axis: .vertical).textFieldStyle(.roundedBorder).font(.callout).lineLimit(1...2)
                Button("Send", systemImage: "arrow.up.circle.fill") { Task { await model.sendTyped() } }.labelStyle(.iconOnly).font(.title2).frame(minWidth: 44, minHeight: 36).disabled(model.backend?.lease == nil || model.typed.isEmpty || surface.submitting)
            }
            routeProbe
            if model.status.manualSend || model.status.holding != nil { Button("Send now") { model.controller?.send() }.buttonStyle(.bordered).disabled(!model.status.running) }
        }.padding().background(Color(white: 0.055))
            .task { while !Task.isCancelled { surface.tick(); try? await Task.sleep(nanoseconds: 50_000_000) } }
            .sheet(isPresented: $audioSettings) { NavigationStack { Form { CallAudioSettings(model: model) }.navigationTitle("Audio & call").toolbar { Button("Done") { audioSettings = false } } } }
    }
    @ViewBuilder private var routeRecoveryControls: some View {
        if model.routeRetryAvailable {
            Button("Retry audio") { model.retryRouteAudio() }
                .buttonStyle(.bordered).accessibilityIdentifier("voice.retryAudio")
                .disabled(!model.coordinator.mayRunMedia || !model.coordinator.active)
        }
        if model.routeRetryInProgress { Text("Retrying audio…").font(.caption).accessibilityIdentifier("voice.retryingAudio") }
    }
    @ViewBuilder private var routeProbe: some View {
        if ProcessInfo.processInfo.arguments.contains("-FVRoute28Probe") {
            Text("Route check: \(routeLabel)").font(.caption2)
                .accessibilityIdentifier("voice.route.actual").accessibilityValue(routeProbeValue)
        }
    }
    private var routeProbeValue: String {
        let session = AVAudioSession.sharedInstance()
        let output = session.currentRoute.outputs.reduce(0) { bits, port in
            bits | (port.portType == .builtInSpeaker ? 2 : port.portType == .builtInReceiver ? 4 : 32768)
        }
        let active = model.coordinator.active ? 1 : 0, media = model.coordinator.mayRunMedia ? 1 : 0
        let ready = model.routeCaptureReady ? 1 : 0
        return "schema=route-recovery-2;outputPort=\(output);active=\(active);media=\(media);options=\(session.categoryOptions.rawValue);captureReady=\(ready)"
    }
    private var lastUserID: String? { surface.log.turns.last { $0.isPrincipal }?.id }
    private func countdownTime(_ date: Date) -> Double {
#if DEBUG && targetEnvironment(simulator)
        if let frozen = PolishPreview.countdownTime { return frozen }
#endif
        return date.timeIntervalSince1970 * 1000
    }
    private var sessionDisplayName: String {
        let title = model.sessions.first { $0.id == model.selection }?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? "Conversation" : title
    }
    private var lastChiefID: String? { surface.log.turns.last { $0.role == .chief }?.id }
    private var speakerOn: Bool { (model.hasCall || model.status.running) && model.coordinator.currentPhoneRoute == .speaker }
    private var routeLabel: String {
        guard model.hasCall || model.status.running else { return "Audio" }
        switch model.coordinator.currentPhoneRoute {
        case .speaker: return "Speaker"
        case .phone: return "Phone"
        case .bluetooth: return "Bluetooth"
        case .headphones: return "Headphones"
        case .external: return "External audio"
        }
    }
    private func callButton(_ label: String, symbol: String, on: Bool, id: String, end: Bool = false, accessibility: String? = nil, value: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 24, weight: .medium)).frame(width: 62, height: 62)
                    .foregroundStyle(end || !on ? Color.white : Color.black)
                    .background(end ? Color.red : on ? Color.white.opacity(0.94) : Color.white.opacity(0.13), in: Circle())
                Text(label).font(.caption).lineLimit(2).multilineTextAlignment(.center)
            }.frame(maxWidth: .infinity, minHeight: 88).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(accessibility ?? label).accessibilityValue(value ?? (end ? "" : on ? "on" : "off")).accessibilityIdentifier(id)
    }
}

/// Copied lens/ripple geometry and blue/amber palette from the accepted Mac pill (read-only).
/// Heights only consume measured PCM RMS; no thinking animation or synthetic input levels.
struct NativeWaveform: View {
    let levels: [Double]
    let voice: PillModel.Voice
    let ready: Bool
    var body: some View {
        GeometryReader { geo in
            let color: Color = !ready || voice == .none ? .gray : (voice == .chief ? Color(red: 1, green: 0.72, blue: 0.36) : Color(red: 0.42, green: 0.73, blue: 1))
            let count = 25, mid = count / 2
            let width = geo.size.width / (CGFloat(count) * 1.65 - 0.65)
            HStack(spacing: width * 0.65) {
                ForEach(0..<count, id: \.self) { index in
                    let distance = abs(index - mid)
                    let value = ready && distance < levels.count ? levels[levels.count - 1 - distance] : 0
                    let lens = 0.5 + 0.5 * cos(Double(distance) / Double(mid + 1) * .pi / 2)
                    Capsule().fill(color.gradient).frame(width: width, height: max(width, geo.size.height * value * lens))
                }
            }.frame(width: geo.size.width, height: geo.size.height)
        }.animation(.linear(duration: 0.06), value: levels)
    }
}

private enum SenderPalette {
    // Light violet on the dark bubble, keeping sender headers comfortably above
    // normal-text contrast while preserving the principal's existing blue.
    static let external = Color(red: 0.76, green: 0.65, blue: 1.0)
}

struct VoiceLogBubble: View {
    let turn: VoiceLogTurn
    let latestUser: String?
    let latestChief: String?
    private var tint: Color { turn.isPrincipal ? Color(red: 0.42, green: 0.73, blue: 1) : turn.role == .you ? SenderPalette.external : Color(red: 1, green: 0.72, blue: 0.36) }
    private var captionID: String {
        if turn.isPrincipal && turn.id == latestUser { return "voice.userCaption" }
        if turn.role == .chief && turn.id == latestChief { return "voice.chiefCaption" }
        return "voice.turn." + turn.id
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(turn.displayLabel).font(.caption.bold()).foregroundStyle(tint).accessibilityLabel(turn.accessibilityLabel).accessibilityIdentifier("voice.sender." + turn.id)
            if !turn.spoken.isEmpty { MarkdownView(text: turn.spoken).accessibilityElement(children: .ignore).accessibilityLabel(turn.spoken).accessibilityIdentifier(captionID) }
            if !turn.details.isEmpty { MarkdownView(text: turn.details).font(.callout).foregroundStyle(.secondary).accessibilityIdentifier("voice.chiefDetails") }
            if turn.pending { Text("Not confirmed sent").font(.caption2).foregroundStyle(.secondary) }
        }.fixedSize(horizontal: false, vertical: true).padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(turn.role == .you ? tint.opacity(0.07) : Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
    }
}

struct CallAudioSettings: View {
    @ObservedObject var model: PhoneModel
    var body: some View {
        Section("Call audio") {
            HStack { Text("Choose audio route"); Spacer(); CallRoutePicker().frame(width: 44, height: 44) }
            if model.hasCall {
                Button(model.calls.lifecycle.state == .held ? "Resume call" : "Hold call") { model.calls.hold(model.calls.lifecycle.state != .held) }.accessibilityIdentifier("voice.hold")
                Button("Stop reply", role: .destructive) { Task { await model.stopReply() } }
            }
        }
    }
}

private struct HistoryTargetFrames: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue()) { _, new in new } }
}

private struct HistoryMessageCard: View {
    @ObservedObject var model: PhoneModel
    let row: MessageRow
    private var targeted: Bool { model.historyNavigation.anchor?.rowID == row.id }
    private var senderTint: Color { row.role == "You" && !row.isPrincipal ? SenderPalette.external : .secondary }
    private var background: Color {
        if row.isPrincipal { return .white.opacity(0.08) }
        if row.role == "You" { return SenderPalette.external.opacity(0.07) }
        return .white.opacity(0.035)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(row.displayLabel).font(.caption.bold()).foregroundStyle(senderTint)
                    .accessibilityLabel(row.accessibilityLabel)
                    .accessibilityIdentifier(row.text.isEmpty && row.steps > 0 ? "history.work." + row.id : "history.role." + row.id)
                if targeted {
                    Spacer()
                    Text("Notification target").font(.caption.bold()).foregroundStyle(.orange)
                        .accessibilityIdentifier("history.notificationTarget." + row.id).accessibilityValue("highlighted")
                }
            }.background(GeometryReader { header in
                Color.clear.preference(key: HistoryTargetFrames.self, value: targeted ? [row.id: header.frame(in: .named("history.viewport"))] : [:])
            })
            ForEach(Array(row.body.enumerated()), id: \.offset) { ordinal, part in
                MessageContentView(model: model, row: row, part: part, ordinal: ordinal)
            }
        }.padding().frame(maxWidth: .infinity, alignment: .leading)
            .background(background).clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(targeted ? Color.orange : Color.clear, lineWidth: 2))
            .accessibilityElement(children: .contain).accessibilityIdentifier("history.message." + row.id)
            .accessibilityValue(targeted ? "Notification target · highlighted" : "")
            .onAppear { if PhoneLoopProbe.enabled { PhoneLoopProbe.shared.visible(row.id, model: model) } }
    }
}

struct HistoryView: View {
    @ObservedObject var model: PhoneModel
    @State private var follow = BottomFollow()
    @State private var browsing = false
    @State private var targetFrames: [String: CGRect] = [:]
    @State private var viewportSize: CGSize = .zero
    @State private var initiallyPositioned = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                Text(model.surface.state)
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal)
                Text("Conversation").font(.caption2).foregroundStyle(.secondary).accessibilityIdentifier("history.session." + (model.backend?.lease?.sessionID ?? "unavailable"))
                if let message = model.principalError {
                    Text(message).font(.caption).foregroundStyle(.secondary).padding(.horizontal)
                }
                ScrollViewReader { proxy in
                GeometryReader { viewport in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if model.backend?.olderCursor != nil {
                            Button("Load older messages") {
                                model.historyNavigation.userScrolled()
                                follow.userScrolled(bottomVisible: false)
                                let anchor = model.messages.first?.id
                                Task {
                                    do { try await model.backend?.loadOlder(); if let anchor { proxy.scrollTo(anchor, anchor: .top) } }
                                    catch { model.error = "History: " + error.localizedDescription }
                                }
                            }.onAppear {
                                guard browsing, !follow.following, !model.historyNavigation.pinned else { return }
                                let anchor = model.messages.first?.id
                                Task {
                                    do { try await model.backend?.loadOlder(); if let anchor { proxy.scrollTo(anchor, anchor: .top) } }
                                    catch { model.error = "History: " + error.localizedDescription }
                                }
                            }
                        }
                        ForEach(model.messages) { row in
                            HistoryMessageCard(model: model, row: row).id(row.id)
                        }
                        if !model.live.isEmpty { Text(model.live).foregroundStyle(.secondary).padding() }
                        if let held = model.status.holding { Text("Holding: " + held).padding() }
                        if !model.review.isEmpty {
                            DisclosureGroup("Pending review · \(model.review.count) · never auto-sent") {
                                ForEach(Array(model.review.enumerated()), id: \.offset) { _, draft in
                                    VStack(alignment: .leading) {
                                        Text("Earlier conversation").font(.caption).foregroundStyle(.secondary)
                                        Text(draft.text).textSelection(.enabled)
                                        if draft.nonAuthoritative { Text("Unfinished words · review before sending.").font(.caption).foregroundStyle(.secondary) }
                                        Text("Check history for delivery before explicitly copying into a new message.").font(.caption)
                                    }.padding(.vertical, 6)
                                }
                            }.padding()
                        }
                        Color.clear.frame(height: 1).id("bottom")
                            .onAppear { if !model.historyNavigation.pinned { follow.userScrolled(bottomVisible: true); browsing = false } }
                            .onDisappear { if browsing { follow.userScrolled(bottomVisible: false) } }
                    }.scrollTargetLayout().padding(.horizontal)
                }
                .coordinateSpace(name: "history.viewport")
                .onAppear { viewportSize = viewport.size }
                .onChange(of: viewport.size) { _, size in viewportSize = size }
                .onPreferenceChange(HistoryTargetFrames.self) { targetFrames = $0 }
                // Never ask SwiftUI to keep a bottom anchor while targeting an old row.
                .defaultScrollAnchor(.top)
                .task(id: model.historyNavigation.pinned ? model.historyNavigation.requestID : nil) {
                    if let request = model.historyNavigation.requestID, let anchor = model.historyNavigation.anchor {
                        initiallyPositioned = true; follow.userScrolled(bottomVisible: false); browsing = true
                        // Re-issue only when layout has not put the target header in the
                        // viewport. This survives lazy height estimates and sheet layout;
                        // user scrolling/new turns cancel the pin and this task immediately.
                        while !Task.isCancelled, model.historyNavigation.requestID == request, model.historyNavigation.pinned {
                            // Leave space beneath the highlighted header for its
                            // collapsed work line, not just a clipped bottom-edge pixel.
                            let bounds = CGRect(x:0,y:0,width:viewportSize.width,height:max(0,viewportSize.height-80))
                            let frame = targetFrames[anchor.rowID] ?? .null
                            if !model.historyNavigation.scrollRequested || !HistoryNavigation.headerIsVisible(frame, in: bounds) {
                                model.historyNavigation.requestedScroll(request)
                                proxy.scrollTo(anchor.rowID, anchor: .top)
                            } else {
                                model.historyNavigation.observedViewport(request: request, rowID: anchor.rowID, rowFrame: frame, viewport: bounds)
                            }
                            do { try await Task.sleep(nanoseconds: 120_000_000) } catch { return }
                        }
                    } else if !initiallyPositioned {
                        initiallyPositioned = true; await Task.yield()
                        proxy.scrollTo("bottom", anchor: .bottom)
                    } else if model.historyNavigation.releasedByNewTurn {
                        follow.selected(); browsing = false; proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
                .simultaneousGesture(DragGesture().onChanged { value in if abs(value.translation.height) > 8 { model.historyNavigation.userScrolled(); browsing = true; follow.userScrolled(bottomVisible: false) } })
                .onChange(of: model.messages.count) { _, _ in if follow.following && model.historyNavigation.allowsLatestFollow { proxy.scrollTo("bottom", anchor: .bottom) } }
                .onChange(of: model.messages.last?.detail) { _, _ in if follow.following && model.historyNavigation.allowsLatestFollow { proxy.scrollTo("bottom", anchor: .bottom) } }
                .onChange(of: model.backend?.lease) { _, _ in if model.historyNavigation.allowsLatestFollow { follow.selected(); browsing = false; proxy.scrollTo("bottom", anchor: .bottom) } }
                }
                if !follow.following { Button("Latest ↓") { model.historyNavigation.userScrolled(); follow.selected(); browsing = false; proxy.scrollTo("bottom", anchor: .bottom) }.font(.caption) }
                }
            }.padding(.bottom).background(Color(white: 0.075))
                .navigationTitle("History").navigationBarTitleDisplayMode(.inline)
                .safeAreaInset(edge: .top, spacing: 0) { CanvasProbeStatus(model: model) }
                .toolbar { Button("Done") { dismiss() } }
                .sheet(item: $model.link) { destination in NavigationStack { PrivateLinkView(url: destination.url).toolbar { Button("Done") { model.link = nil } } } }
                .environment(\.openURL, OpenURLAction { url in
                    guard phoneLinkPolicy.web(url) || phoneLinkPolicy.install(url) != nil else { return .discarded }
                    model.link = LinkDestination(url: url); return .handled
                })
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: PhoneModel
    @Environment(\.dismiss) private var dismiss
    @State private var pasted = ""
    @State private var voice = "alloy"
    @State private var manual = false
    @State private var pause = 3200.0
    @State private var sensitivity = "normal"
    @State private var busyDelivery = "queue"
    @State private var diagnostics = ""
    var body: some View {
        NavigationStack { Form {
            Section { Text(InstalledBuild.label).accessibilityIdentifier("settings.build") }
            Section("Conversation") {
                NavigationLink { SessionPickerView(model: model) } label: {
                    LabeledContent("Session", value: model.selection == "chief" ? "Chief-of-staff session" : (model.sessions.first { $0.id == model.selection }?.title ?? "Selected conversation"))
                }.accessibilityIdentifier("settings.session")
                if !model.paired { Button("Pair / reconnect") { Task { await model.prepare() } } }
            }
            if model.hasCall { CallAudioSettings(model: model) }
            Section("Voice") {
                Toggle("Manual Send", isOn: $manual).onChange(of: manual) { _, value in Task { await model.change(.sendMode(value ? .manual : .auto)) } }
                Picker("While busy", selection: $busyDelivery) { Text("Queue").tag("queue"); Text("Steer").tag("steer") }.onChange(of: busyDelivery) { _, value in Task { await model.change(.busyDelivery(value == "steer" ? .steer : .queue)) } }
                Slider(value: $pause, in: 1100...6000, step: 100).onChange(of: pause) { _, value in Task { await model.change(.pauseMs(value)) } }
                Text("Pause before sending: \(pause / 1000, specifier: "%.1f") s")
                Picker("Noise sensitivity", selection: $sensitivity) { ForEach(["low", "normal", "high"], id: \.self) { Text($0) } }.onChange(of: sensitivity) { _, value in Task { await model.change(.sensitivity(value)) } }
                Picker("Voice", selection: $voice) { ForEach(Array(Set(model.voices + [voice])).sorted(), id: \.self) { Text($0).tag($0) } }
                    .pickerStyle(.menu).onChange(of: voice) { _, value in Task { await model.change(.voice(value)) } }
                Toggle("Speaker for new calls", isOn: Binding(get: { model.coordinator.speaker }, set: { model.coordinator.speaker = $0; model.objectWillChange.send() }))
                Text("Bluetooth follows your iPhone's selected audio route. Use Speaker or Phone on the voice screen to change it during a call.").font(.caption).foregroundStyle(.secondary)
            }
            ReachOutSettingsView()
            Section("Diagnostics") {
                Text(InstalledBuild.label)
                NavigationLink("View / export diagnostics") {
                    ScrollView { Text(diagnostics).font(.caption.monospaced()).textSelection(.enabled).padding() }
                        .navigationTitle("Diagnostics")
                        .toolbar { ShareLink("Export", item: diagnostics) }
                        .onAppear { diagnostics = StageDiagnostics.shared.export() }
                }
                Text("Only stage, timing, numeric status and protected-data availability; no conversation, URLs or credentials.").font(.caption)
            }
        }.navigationTitle("Sessions & settings").toolbar { Button("Done") { dismiss() } }.onAppear {
            let saved = model.savedSettings
            manual = (model.controller?.app ?? saved.app).sendMode == .manual; pause = model.controller?.voice.pauseMs ?? saved.voice.pauseMs
            voice = model.controller?.voice.voice ?? saved.voice.voice
            sensitivity = model.controller?.voice.sensitivity ?? saved.voice.sensitivity
            busyDelivery = model.controller?.app.busyDelivery.rawValue ?? saved.app.busyDelivery.rawValue
        } }
    }
}

struct SessionPickerView: View {
    @ObservedObject var model: PhoneModel
    @State private var search = ""
    @State private var pasted = ""
    @Environment(\.dismiss) private var dismiss
    func choose(_ value: String) { Task { do { try await model.select(value); dismiss() } catch { model.error = error.localizedDescription } } }
    var body: some View {
        List {
            Button(model.selection == "chief" ? "✓ Chief-of-staff session" : "Chief-of-staff session") { choose("chief") }.accessibilityIdentifier("picker.chief")
            ForEach(CompactPicker.sessions(model.sessions, search: search), id: \.id) { session in
                Button((model.selection == session.id ? "✓ " : "") + (session.title.isEmpty ? "Conversation" : session.title)) { choose(session.id) }.accessibilityIdentifier("picker." + session.id)
            }
        }.searchable(text: $search).navigationTitle("Choose session")
    }
}

struct MarkdownView: View {
    let blocks: [MarkdownBlock]
    init(text: String) { blocks = BlockMarkdown.renderBlocks(text) }
    init(blocks: [MarkdownBlock]) { self.blocks = blocks }
    var depth = 0
    @ScaledMetric(relativeTo: .callout) private var codeLineHeight = 22.0
    @ScaledMetric(relativeTo: .body) private var tableLineHeight = 24.0
    func inline(_ text: String) -> Text {
        var value = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        for run in value.runs {
            if let url = run.link, !phoneLinkPolicy.web(url), phoneLinkPolicy.install(url) == nil { value[run.range].link = nil }
        }
        return Text(value)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let value): inline(value)
                case .list(let value):
                    HStack(alignment: .top) {
                        let pieces = value.split(separator: " ", maxSplits: 1)
                        Text(pieces.first.map(String.init).map { ["-", "*", "+"].contains($0) ? "•" : $0 } ?? "•").foregroundStyle(.secondary)
                        inline(pieces.count > 1 ? String(pieces[1]) : value)
                    }.padding(.leading, 8)
                case .heading(let level, let value): inline(value).font(level <= 2 ? .headline : .subheadline).bold()
                case .quote(let value): HStack { Rectangle().frame(width: 3).foregroundStyle(.secondary); inline(value).foregroundStyle(.secondary) }
                case .code(let language, let value):
                    VStack(alignment: .leading) {
                        Text(language.isEmpty ? "Code" : language).font(.caption)
                        ViewThatFits(in: .horizontal) {
                            Text(value).font(.callout.monospaced()).fixedSize(horizontal: true, vertical: true)
                            ScrollView(.horizontal) {
                                Text(value).font(.callout.monospaced()).fixedSize(horizontal: true, vertical: true)
                            }
                        }.frame(height: codeLineHeight * Double(max(1, value.components(separatedBy: "\n").count)), alignment: .leading)
                    }.padding(8).background(Color.white.opacity(0.06))
                case .markdown(let value):
                    Text(value).font(.callout.monospaced()) // defensive only; renderBlocks expands md
                case .table(let rows):
                     ViewThatFits(in: .horizontal) {
                         table(rows)
                         ScrollView(.horizontal) { table(rows) }
                     }.frame(height: rows.reduce(0.0) { height, cells in
                         height + tableLineHeight * Double(cells.map { max(1, $0.components(separatedBy: "\n").count) }.max() ?? 1) + 12
                     }, alignment: .leading)
                }
            }
        }.textSelection(.enabled).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
    }
    func table(_ rows: [[String]]) -> some View {
        Grid(alignment: .topLeading) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, cells in
                GridRow { ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in inline(cell).fontWeight(index == 0 ? .bold : .regular).padding(6) } }
            }
        }.fixedSize(horizontal: true, vertical: true).background(Color.white.opacity(0.04))
    }
}
