#if DEBUG && targetEnvironment(simulator)
import SwiftUI

/// Offline screenshots of the PRODUCTION views. No credential reads, networking or real audio.
@MainActor final class PolishCallProvider: CallProviderAdapter {
    var onEvent: ((CallProviderEvent) -> Void)?
    var routeLabel: String { PolishPreview.mode == "main-phone" ? "Phone" : "Speaker" }
    func requestStart(_ id: UUID, completion: @escaping (Error?) -> Void) {
        completion(nil); onEvent?(.start(id, { _ in })); onEvent?(.activated)
    }
    func requestEnd(_ id: UUID) {}
    func requestMute(_ id: UUID, muted: Bool) { onEvent?(.mute(id, muted, { _ in })) }
    func requestHold(_ id: UUID, held: Bool) {}
    func configure() throws {}
    func connecting(_ id: UUID) {}
    func connected(_ id: UUID) {}
    func ended(_ id: UUID, reason: CallEndReason) {}
    func observeActivation(_ granted: Bool) {}
    func refresh(proximity: Bool) {}
    func toggleSpeaker() {}
    func invalidate() {}
}

struct PolishPreview: View {
    static var countdownTime: Double? { enabled && mode == "countdown-two" ? 1_000_000 : nil }
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("-FVPolish") }
    static var mode: String { ProcessInfo.processInfo.arguments.last ?? "main-speaker" }
    @ObservedObject var model = PhoneModel.shared
    @State private var ready = false
    var body: some View {
        Group {
            if !ready { ProgressView() }
            else {
            switch Self.mode {
            case "sender-history": HistoryView(model: model)
            case "sender-main": VoiceMainView(model: model, surface: model.surface, pill: model.surface.pill)
            case let mode where mode.hasPrefix("canvas-history"): HistoryView(model: model)
            case let mode where mode.hasPrefix("canvas-main"): VoiceMainView(model: model, surface: model.surface, pill: model.surface.pill)
            case let mode where mode.hasPrefix("history"): HistoryView(model: model)
            case "settings": SettingsView(model: model)
            case "notifications", "notifications-denied": NavigationStack { Form { ReachOutSettingsView() }.navigationTitle("\(AgentPresentation.name) reach-out") }
            case "diagnostics": NavigationStack { ScrollView { Text(StageDiagnostics.shared.export()).font(.caption.monospaced()).padding() }.navigationTitle("Diagnostics") }
            case "install-review": NavigationStack { PrivateLinkView(url: URL(string: "itms-services://?action=download-manifest&url=https%3A%2F%2Fmac.ts.net%2Fbuilds%2F20%2Fmanifest.plist")!) }
            default: ConversationView(model: model)
            }
            }
        }.task { if !ready {
            if Self.mode.hasPrefix("sender-") { seedSenders() }
            else if Self.mode.hasPrefix("discard-") { do { try await DiscardFixture.seed(model, mode: Self.mode) } catch { model.error = "Synthetic discard fixture unavailable" } }
            else if Self.mode.hasPrefix("canvas-") { do { try await CanvasShowFixture.seed(model, mode: Self.mode) } catch { model.error = "Synthetic fixture unavailable" } }
            else {
                seed()
                if Self.mode.hasSuffix("probe-stopped") {
                    model.canvasProbeError = "Canvas check stopped (preparation). No input was sent."
                    model.error = nil // A successful startup must not erase the dedicated probe label.
                }
            }
            ready = true
        } }
    }
    private func seedSenders() {
        let target = TargetLease(sessionID: "ses_sender_preview", generation: "sender-preview")
        model.paired = true
        let owner = model.surface.replaceBinding(target: target)
        let records: [[String: Any]] = [
            ["id":"sender_you", "type":"user", "text":"[voice] Let’s review before installing.", "sender":["kind":"principal", "label":"You"]],
            ["id":"sender_agent", "type":"assistant", "content":[["type":"text", "text":"I’ll keep you in control."]]],
            ["id":"sender_lead", "type":"user", "text":"From the Voicestack iPhone lead:\nBuild is ready for review.", "displayText":"Build is ready for review.", "sender":["kind":"lead", "label":"Lead · Voicestack iPhone"]],
            ["id":"sender_docket", "type":"user", "text":"[Docket]\nReview reminder.", "displayText":"Review reminder.", "sender":["kind":"docket", "label":"Docket"]],
            ["id":"sender_canvas", "type":"user", "text":"[Agent Canvas]\nSelected: Review first.", "displayText":"Selected: Review first.", "sender":["kind":"canvas", "label":"Agent Canvas"]],
            ["id":"sender_unknown", "type":"user", "text":"Origin not provided.", "sender":["kind":"system", "label":MessageSender.unknownLabel]]
        ]
        let raw = records.map { try! JSONSerialization.data(withJSONObject: $0) }
        model.messages = raw.compactMap(MessageRow.init)
        model.historyVisible = true
        model.surface.update(status: ConversationController.Status(), owner: owner)
        model.surface.update(records: raw, connection: "connected", active: false)
    }
    private func seed() {
        let target = TargetLease(sessionID: "ses_preview", generation: "preview")
        model.paired = true
        let owner = model.surface.replaceBinding(target: target)
        var status = ConversationController.Status()
        status.running = true; status.phase = "ready"; status.connection = "connected"
        model.status = status; model.surface.update(status: status, owner: owner)
        model.surface.updateCapture(.running, owner: owner)
        let record: [String: Any] = ["id":"m_preview", "type":"assistant", "content":[["type":"text", "text":"## Ready when you are\nThe iPhone update is ready to review. Open **History** for the details, or tell me what you'd like to do next."]]]
        let raw = try! JSONSerialization.data(withJSONObject: record)
        let question = "Let's review the update before installing."
        let userRaw = try! JSONSerialization.data(withJSONObject: ["id":"u_preview", "type":"user", "text":question, "sender":["kind":"principal", "label":"You"]])
        model.messages = [MessageRow(userRaw)!, MessageRow(raw)!]
        model.historyVisible = true
        if Self.mode.hasPrefix("history-target") {
            var records: [Data] = []
            for i in 0..<100 {
                let parts: [[String: Any]]
                if i == 36 { parts = [["type":"tool","name":"fixture","state":["status":"completed","content":[]]]] }
                else if i == 37 { parts = [["type":"text","text":"  "]] }
                else { parts = [["type":"text","text":String(repeating:"Offline varied-height history paragraph \(i). ",count:1+i%9)]] }
                records.append(try! JSONSerialization.data(withJSONObject:["id":"fixture_\(i)","type":"assistant","content":parts]))
            }
            let sourceID = Self.mode == "history-target-empty" ? "fixture_37" : "fixture_36"
            model.messages = records.compactMap(MessageRow.init)
            model.historyMessageID = sourceID
            model.historyNavigation.request(HistoryAnchor.resolve(sourceID,records:records)!,newestRow:model.messages.last?.id)
            if Self.mode == "history-target-race" {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    let tail = try! JSONSerialization.data(withJSONObject:["id":"fixture_99","type":"assistant","content":[["type":"text","text":String(repeating:"Streaming latest-row height change. ",count:35)]]])
                    model.messages[model.messages.count-1] = MessageRow(tail)!
                    model.historyNavigation.rowsChanged(newestRow:model.messages.last?.id)
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    let older = try! JSONSerialization.data(withJSONObject:["id":"fixture_older","type":"user","text":"Older page merge."])
                    model.messages.insert(MessageRow(older)!,at:0)
                    model.historyNavigation.rowsChanged(newestRow:model.messages.last?.id)
                }
            }
        }
        model.surface.handle(.youStarted, owner: owner)
        model.surface.handle(.youFinal(question), owner: owner)
        model.surface.handle(.posted(question), owner: owner)
        model.surface.update(records: [userRaw, raw], connection: "connected", active: false)
        let spoken = cleanSpeech(MessageRow(raw)!.text)
        model.surface.handle(.chiefQueued(label: "m_preview:0", text: spoken), owner: owner)
        model.surface.handle(.chiefStarted(label: "m_preview:0", text: spoken), owner: owner)
        model.surface.handle(.chiefEnded(label: "m_preview:0", text: spoken, outcome: "played"), owner: owner)
        model.calls.beginMedia = { _ in true } // Offline fake provider; never constructs capture/networking.
        model.calls.start(target: target)
        if Self.mode == "main-mic-muted" || Self.mode == "main-all-muted" { model.voiceLifecycle.setMicMuted(true); status.micMuted = true }
        if Self.mode == "main-voice-muted" || Self.mode == "main-all-muted" { model.voiceLifecycle.setOutputMuted(true); status.outputMuted = true }
        model.status = status; model.surface.update(status: status, owner: owner)
        if Self.mode == "error" { model.error = "Microphone capture failed (-50)"; model.surface.updateCapture(.failed, owner: owner) }
        if Self.mode == "notification-error" { model.error = "Notification: Couldn't open that message" }
        if Self.mode == "speech-unavailable" { model.error = "Speech service at 127.0.0.1:8446 isn't running" }
        if Self.mode == "speech-warming" { status.warmingSpeech = true; model.status = status; model.surface.update(status: status, owner: owner) }
        if Self.mode == "audio-switching" { model.surface.updateCapture(.repairing, owner: owner) }
        if Self.mode == "reconnect" { model.surface.update(records: [raw], connection: "reconnecting", active: false) }
        if Self.mode == "notifications-denied" { PushCoordinator.shared.polishDenied() }
        if Self.mode.hasPrefix("caption-") || ["chief-speaker", "chief-phone"].contains(Self.mode) {
            let first = "The update is ready for you to review."
            let second = "Nothing will install until you confirm it."
            let raw = first + " " + second + "\n```md\n## Before you try it\n- Review the build on your iPhone\n- Keep your current conversation\n\n**Your choice:** install when you are ready.\n```"
            let record: [String: Any] = ["id":"caption", "type":"assistant", "content":[["type":"text", "text":raw]]]
            if Self.mode == "caption-muted" { status.outputMuted = true; model.voiceLifecycle.setOutputMuted(true) }
            let speaking = ["caption-mid", "chief-speaker", "chief-phone"].contains(Self.mode)
            status.speaking = speaking
            status.canBargeIn = speaking; status.halfDuplex = Self.mode != "chief-phone"
            status.listeningSuppressed = speaking && status.halfDuplex
            model.status = status; model.surface.update(status: status, owner: owner)
            model.surface.update(records: [userRaw, try! JSONSerialization.data(withJSONObject: record)], connection: "connected", active: Self.mode == "caption-mid" || Self.mode == "caption-muted")
            model.surface.handle(.chiefQueued(label: "caption:0", text: first), owner: owner)
            model.surface.handle(.chiefQueued(label: "caption:0", text: second), owner: owner)
            model.surface.handle(.chiefStarted(label: "caption:0", text: first), owner: owner)
            if !speaking {
                model.surface.handle(.chiefEnded(label: "caption:0", text: first, outcome: "played"), owner: owner)
                model.surface.handle(.chiefStarted(label: "caption:0", text: second), owner: owner)
                model.surface.handle(.chiefEnded(label: "caption:0", text: second, outcome: "played"), owner: owner)
            }
            if Self.mode == "caption-next-turn" { model.surface.handle(.youStarted, owner: owner); model.surface.handle(.youLive("Let's try it after lunch."), owner: owner) }
        }
        if Self.mode == "countdown-two" {
            model.surface.handle(.youStarted, owner: owner)
            model.surface.handle(.youLive("Let's review it after lunch."), owner: owner)
            status.sendCountdown = ConversationController.SendCountdown(totalMs: 3200, deadlineMs: 1_002_000, hold: false)
            model.status = status; model.surface.update(status: status, owner: owner)
        }
        if Self.mode.hasPrefix("log-") {
            var page: [Data] = []
            let count = Self.mode == "log-scrolled" ? 12 : 3
            for i in 1...count {
                page.append(try! JSONSerialization.data(withJSONObject: ["id":"u_log_\(i)", "type":"user", "text":i == 1 ? "Can we review the update?" : "What happens next?"]))
                page.append(try! JSONSerialization.data(withJSONObject: ["id":"a_log_\(i)", "type":"assistant", "content":[["type":"text", "text":i == 1 ? "It's ready to review." : "Your conversation stays as it is."]]]))
            }
            var historical = status; historical.running = false; model.surface.update(status: historical, owner: owner)
            model.surface.update(records: page, connection: "connected", active: false)
            model.surface.update(status: status, owner: owner)
            if Self.mode == "log-live-user" || Self.mode == "log-live-user-grown" {
                model.surface.handle(.youStarted, owner: owner)
                model.surface.handle(.youLive(Self.mode == "log-live-user" ? "Let's review it after" : "Let's review it after lunch, once the build is ready."), owner: owner)
            }
        }
    }
}

/// In-process fake bridge: real RemoteSessionBackend/HTTP transport, no credentials or live services.
private final class DiscardFixtureProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var posts = 0
    static func reset() { lock.lock(); posts = 0; lock.unlock() }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "discard-fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        let events = path.hasSuffix("/events")
        var body: [String: Any] = [:]
        if path.hasSuffix("/selection") { body = ["generation": "discard-fixture"] }
        else if path.hasSuffix("/messages") { body = ["data": []] }
        else if path.hasSuffix("/state") { body = ["active": false] }
        else if path.hasSuffix("/prompt"), request.httpMethod == "POST" {
            Self.lock.lock(); Self.posts += 1; let count = Self.posts; Self.lock.unlock()
            Task { @MainActor in PhoneModel.shared.discardFixturePromptCount = count }
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": events ? "text/event-stream" : "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: events ? Data(": fixture\n\n".utf8) : try! JSONSerialization.data(withJSONObject: body))
        if !events { client?.urlProtocolDidFinishLoading(self) }
    }
    override func stopLoading() {}
}
private final class DiscardFixtureCredential: DeviceCredentialStore {
    func load() throws -> String? { "synthetic-discard" }
    func save(_ value: String) throws {}
    func clear() throws {}
}
@MainActor private final class DiscardFixtureInput: AudioInput {
    var onPCM: ((Data) -> Void)?
    var onFailure: ((Error) -> Void)?
    func start() async throws {}
    func stop() {}
    func speak() {
        var frame = Data()
        for index in 0..<320 {
            let value = Int16(8000 * sin(Double(index) / 320 * 2 * .pi * 8))
            frame.append(UInt8(truncatingIfNeeded: value)); frame.append(UInt8(truncatingIfNeeded: value >> 8))
        }
        for _ in 0..<30 { onPCM?(frame) }
    }
}
private final class DiscardFixtureRecognition: RecognitionSession {
    let callbacks: RecognitionCallbacks
    init(_ callbacks: RecognitionCallbacks) { self.callbacks = callbacks }
    func start() {}
    func write(_ pcm: Data) {}
    func end() { callbacks.done("Synthetic final should not leak after discard.") }
    func cancel() {
        // Deliberately hostile recognizer: a late final still arrives after cancellation.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.callbacks.done("Retired private utterance.") }
    }
}
private final class DiscardFixtureSynth: SpeechSynthesizer, SpeechTicket {
    let text = ""
    func prepare(_ text: String) -> SpeechTicket { self }
    func audio() async throws -> SpeechAudio { .whole(Data(), sampleRate: 24000) }
    func cancel() {}
}
@MainActor private final class DiscardFixtureOutput: AudioOutput {
    func play(_ audio: SpeechAudio, label: String, onStart: @escaping () -> Void) async throws { onStart() }
    func stopPlayback() {}
}
@MainActor private enum DiscardFixture {
    static func seed(_ model: PhoneModel, mode: String) async throws {
        DiscardFixtureProtocol.reset(); model.discardFixturePromptCount = 0
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [DiscardFixtureProtocol.self]
        let transport = try BridgeTransport(base: URL(string: "https://discard-fixture.invalid/floating-voice")!, credentials: DiscardFixtureCredential(), configuration: config)
        let backend = RemoteSessionBackend(transport: transport)
        try await backend.select("ses_discard")
        model.backend = backend; model.selection = "ses_discard"; model.paired = true
        let owner = model.surface.replaceBinding(target: backend.lease!)
        var settings = LoadedSettings(app: AppSettings(), voice: VoiceConfig(), voiceFile: nil, appFile: "/nonexistent", chiefFile: "/nonexistent")
        settings.app.target = "ses_discard"; settings.app.holdMidSentenceMs = 6000
        let input = DiscardFixtureInput()
        var recognition: DiscardFixtureRecognition?
        let controller = ConversationController(settings: settings, backend: backend, synth: DiscardFixtureSynth(), output: DiscardFixtureOutput(), input: input,
            makeRecognition: { recognition = DiscardFixtureRecognition($0); return recognition! })
        model.controller = controller; model.voiceLifecycle.controller = controller
        controller.onStatus = { [weak model] status in model?.status = status; model?.surface.update(status: status, owner: owner) }
        controller.onCaption = { [weak model] event in model?.caption(event, owner: owner) }
        await controller.start()
        let deadline = Date().addingTimeInterval(5)
        while controller.status.phase != "ready" {
            guard Date() < deadline else { throw ClientError("Fixture readiness") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        model.surface.updateCapture(.running, owner: owner)
        model.calls.beginMedia = { _ in true }; model.calls.start(target: backend.lease!)
        if mode != "discard-idle" {
            input.speak()
            if mode == "discard-posted" {
                recognition?.callbacks.done("Already posted.")
            } else if mode == "discard-countdown" {
                recognition?.callbacks.done("Let's review the plan")
            } else if mode != "discard-recording" {
                recognition?.callbacks.live("Let's review the plan")
            }
        }
    }
}
#endif
