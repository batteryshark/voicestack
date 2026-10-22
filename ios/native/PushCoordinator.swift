import UIKit
import PushKit
import SwiftUI

@MainActor final class PushAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        PushCoordinator.shared.start(model: PhoneModel.shared)
        return true
    }
}

/// VoIP/CallKit only. Messages and notifications go through Nod; this app neither
/// requests notification permission nor registers an alert token (none is revoked).
@MainActor final class PushCoordinator: NSObject, ObservableObject, @preconcurrency PKPushRegistryDelegate {
    static let shared = PushCoordinator()
    @Published private(set) var policy: PushPolicySync
    @Published private(set) var syncStatus = "Not synced"
    @Published private(set) var localPolicy = ReachOutPolicy()
    private var phonePolicy: ReachOutPolicy { var p = localPolicy; p.timeZone = TimeZone.current.identifier; return p }
    private var pilotPolicyAllowed: Bool { policy.allowsPilotCall(at:Date(),timeZone:TimeZone.current.identifier) }
    func editLocalPolicy(_ value: ReachOutPolicy) {
        localPolicy = value
        defaults.set(try? JSONEncoder().encode(value),forKey:"phone.callPolicy")
        if !phonePolicy.localCallsAllowed(at:Date()), model?.calls.lifecycle.state == .ringing { model?.calls.restrictPolicy() }
    }
    private var registry: PKPushRegistry?
    private weak var model: PhoneModel?
    private var worker: Task<Void, Never>?
    private var dirty = false
    private let defaults = UserDefaults.standard
    private var voipToken: String?
    private var revision: Int
    private var enrollmentAck = 0
    private var fallbackIDs: [String: UUID] = [:]
    private let receiptOutbox: PushReceiptOutbox
    private var receiptWorker: Task<Void, Never>?
    private var seenCalls: Set<String>
    @Published private(set) var openVoiceEnabled = UserDefaults.standard.bool(forKey:"openVoice.enabled")
    private var capabilityExpiry: Date { capabilitySync.expiresAt }
    private lazy var capabilitySync = OpenVoiceCapabilitySync(state:.init(desiredEnabled:openVoiceEnabled,mayBeEnabled:defaults.bool(forKey:"openVoice.advertised"),enableNeedsExplicitChoice:defaults.bool(forKey:"openVoice.enableUncertain")),persist:{ [weak self] state in
        guard let self else { throw ClientError("Capability storage unavailable") }
        self.defaults.set(state.desiredEnabled,forKey:"openVoice.enabled")
        self.defaults.set(state.mayBeEnabled,forKey:"openVoice.advertised")
        self.defaults.set(state.enableNeedsExplicitChoice,forKey:"openVoice.enableUncertain")
        guard self.defaults.synchronize() else { throw ClientError("Capability storage unavailable") }
    },upload:{ [weak self] enabled in
        guard let self else { throw ClientError("Capability unavailable") }
        let control = try self.candidateControl(); defer { control.close() }
        return try await control.capability(enabled:enabled,build:String(InstalledBuild.number))
    })
    private var operationReviewWorker: Task<Void,Never>?
    func setOpenVoiceEnabled(_ enabled: Bool) {
        // Initialize from persisted state BEFORE changing the published local gate.
        let sync = capabilitySync
        openVoiceEnabled = enabled; sync.setDesired(enabled)
        refreshOpenVoiceCapability()
        if !enabled { model?.revokeOpenVoiceReadiness() }
    }
    private func candidateControl() throws -> OpenVoiceRecipientControl {
        let transport = try transport()
        guard let bearer = try KeychainCredential().load(),
              var origin = URLComponents(url:transport.base,resolvingAgainstBaseURL:false) else { throw ClientError("Pairing unavailable") }
        origin.path = ""; origin.query = nil; origin.fragment = nil
        guard let url = origin.url else { throw ClientError("Bridge unavailable") }
        return try OpenVoiceRecipientControl(origin:url,credential:OpenVoiceDeviceCredential(pairedDeviceBearer:bearer))
    }
    private func refreshOpenVoiceCapability() {
        guard !isTest else { return }
        capabilitySync.refresh()
    }
    func reviewOpenVoiceOperation() {
        guard !isTest, let model, !model.hasCall, operationReviewWorker == nil else { return }
        operationReviewWorker = Task {
            defer { operationReviewWorker = nil }
            do { await model.reviewOpenVoiceOperation(using:try candidateControl()) }
            catch { model.error = "Pilot operation unavailable; no resend" }
        }
    }
    override init() {
        receiptOutbox = PushReceiptOutbox(file: URL.applicationSupportDirectory.appendingPathComponent("Push/receipt-outbox23.json"))
        policy = UserDefaults.standard.data(forKey: "push.policy").flatMap { try? JSONDecoder().decode(PushPolicySync.self, from: $0) } ?? PushPolicySync()
        revision = max(1, UserDefaults.standard.integer(forKey: "push.revision"))
        seenCalls = Set(UserDefaults.standard.stringArray(forKey: "push.seenCalls") ?? [])
        // Tokens are reacquired from the OS, not copied or stored in diagnostics/defaults.
        super.init()
        localPolicy = defaults.data(forKey:"phone.callPolicy").flatMap { try? JSONDecoder().decode(ReachOutPolicy.self,from:$0) } ?? policy.desired
    }
    private var isTest: Bool {
        DeviceAudioProbe.enabled || PhoneLoopProbe.enabled || SpeakerEchoProbe.enabled || ProcessInfo.processInfo.arguments.contains("-FVSimulatorProof") || ProcessInfo.processInfo.arguments.contains("-FVRichFixture") || ProcessInfo.processInfo.arguments.contains("-FVPolish")
    }
    func start(model: PhoneModel) {
        self.model = model
        _ = model.calls
        model.calls.resolveIncoming = { [weak model, weak self] invitation in
            guard let self, let model, let id = invitation.reachoutID else { throw ClientError("Call unavailable") }
            guard self.phonePolicy.localCallsAllowed(at: Date()), (invitation.expiry ?? .distantPast) > Date() else { throw ClientError("Call no longer allowed") }
            let owner = try IncomingCallOwner(lifecycle:model.calls.lifecycle,invitation:invitation)
            let record = try await self.transport().json("/v1/push/reachouts/" + id)
            try owner.validate(model.calls.lifecycle)
            let isPilot = record["context"] as? String == "open-voice"
            let target: TargetLease
            if isPilot {
                guard self.pilotPolicyAllowed, self.openVoiceEnabled, self.capabilityExpiry > Date() else { throw ClientError("New conversation capability unavailable") }
                let control = try self.candidateControl()
                do {
                    target = try await model.joinOpenVoice(record:JSONSerialization.data(withJSONObject:record),push:invitation,owner:owner,control:control) {
                        self.openVoiceEnabled && self.capabilityExpiry > Date() && self.pilotPolicyAllowed
                    }
                } catch { control.close(); throw error }
            } else {
                let context = try ReachOutContext(record:record,reachoutID:id,invitation:invitation)
                guard self.phonePolicy.localCallsAllowed(at:Date()) else { throw ClientError("Call no longer allowed") }
                target = try await model.joinInvitation(context,owner:owner)
            }
            try owner.validate(model.calls.lifecycle)
            guard !isPilot || self.pilotPolicyAllowed else { throw ClientError("Call no longer allowed") }
            guard self.phonePolicy.localCallsAllowed(at: Date()), (invitation.expiry ?? .distantPast) > Date() else { throw ClientError("Call no longer allowed") }
            return target
        }
        model.calls.detailedReceipt = { [weak self, weak model] invitation, receipt in
            guard let model, let id = invitation.reachoutID else { return }
            var receipt = receipt
            if receipt.event == .ended, receipt.endReason == .admissionRejected,
               let policy = self?.phonePolicy, policy.isValid, policy.quietHoursEnabled, policy.isQuiet(at:Date()) {
                receipt.quietUntil = policy.quietUntil(at:Date()).map { $0.timeIntervalSince1970 * 1000 }
                receipt.quietEnd = policy.quietStart == policy.quietEnd ? "all-day" : policy.quietEnd
            }
            if receipt.event == .ended, model.deferOpenVoiceReceipt(invitation.id,send:{ [weak self] in self?.sendReceipt(id,call:invitation.id,receipt:receipt) }) { return }
            self?.sendReceipt(id, call: invitation.id, receipt: receipt)
        }
        guard registry == nil, !isTest else { return }
        if receiptOutbox.loadFailed { StageDiagnostics.shared.record(.pushReceipt, .failed, status: 1, callEvent: .receiptDeferred) }
        flushReceiptOutbox()
        let registry = PKPushRegistry(queue: .main); self.registry = registry
        registry.delegate = self; registry.desiredPushTypes = [.voIP]
        NotificationCenter.default.addObserver(forName: NSNotification.Name.NSSystemTimeZoneDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.foreground() }
        }
        foreground()
    }
    private func transport() throws -> BridgeTransport {
        guard !isTest, let endpoint = Bundle.main.object(forInfoDictionaryKey: "BridgeURL") as? String, let base = URL(string: endpoint) else { throw ClientError("Push unavailable") }
        return try BridgeTransport(base: base, credentials: KeychainCredential())
    }
    func foreground() {
        guard !isTest else { return }
        refreshOpenVoiceCapability()
        flushReceiptOutbox()
        var desired = policy.desired; desired.timeZone = TimeZone.current.identifier
        edit(desired)
        // Refresh server-invalidated enrollment at a newer revision on each foreground.
        revision += 1; defaults.set(revision, forKey: "push.revision")
        retry()
    }
    func token(_ data: Data?) {
        let value = data?.map { String(format: "%02x", $0) }.joined()
        guard voipToken != value else { return }
        voipToken = value
        revision += 1; defaults.set(revision, forKey: "push.revision"); retry()
    }
    func edit(_ desired: ReachOutPolicy) {
        policy.edit(desired)
        if !phonePolicy.localCallsAllowed(at: Date()), model?.calls.lifecycle.state == .ringing { model?.calls.restrictPolicy() }
        defaults.set(try? JSONEncoder().encode(policy), forKey: "push.policy")
        syncStatus = "Not synced · restrictive changes apply now"
        retry()
    }
    /// One worker serializes full snapshots. Edits during an upload cannot be acknowledged by it.
    func retry() {
        guard !isTest else { return }
        dirty = true
        guard worker == nil else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            defer { self.worker = nil }
            while self.dirty {
                self.dirty = false
                // A new snapshot can differ after launch (tokens are reacquired, build/environment
                // can change) or server token invalidation, even without a settings/token callback.
                // Persist a fresh revision BEFORE the first upload. bounded() retries this immutable
                // snapshot at the SAME revision; later dirty snapshots always receive a newer one.
                self.revision += 1; self.defaults.set(self.revision, forKey: "push.revision")
                let snapshot = self.policy.desired, revision = self.revision
                // Generated from the signing entitlements; verify checks the exported signature agrees.
                let environment = Bundle.main.object(forInfoDictionaryKey: "PushEnvironment") as? String ?? ""
                let enrollment: [String: Any] = ["alertToken": NSNull(), "voipToken": self.voipToken as Any? ?? NSNull(), "environment": environment, "build": String(InstalledBuild.number), "revision": revision]
                var stage = DiagnosticStage.pushEnrollment
                do {
                    let transport = try self.transport()
                    try await self.bounded {
                        _ = try await transport.json("/v1/push/enrollment", method: "PUT", body: enrollment)
                    }
                    self.enrollmentAck = revision
                    stage = .pushSettings
                    let body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as! [String: Any]
                    var ack: [String: Any] = [:]
                    try await self.bounded { ack = try await transport.json("/v1/push/settings", method: "PUT", body: body) }
                    let decoded = try JSONDecoder().decode(ReachOutPolicy.self, from: JSONSerialization.data(withJSONObject: ack))
                    guard let ms = ack["syncedAt"] as? Double else { throw ClientError("Settings not acknowledged") }
                    _ = self.policy.acknowledge(decoded, at: Date(timeIntervalSince1970: ms / 1000))
                    self.defaults.set(try? JSONEncoder().encode(self.policy), forKey: "push.policy")
                    self.syncStatus = self.policy.synced && self.enrollmentAck == self.revision ? "Synced" : "Not synced"
                } catch {
                    self.syncStatus = "Not synced · Retry"
                    StageDiagnostics.shared.record(stage, .failed, status: StageDiagnostics.code(error))
                }
            }
        }
    }
    private func bounded(_ operation: () async throws -> Void) async throws {
        for attempt in 0..<3 {
            do { try Task.checkCancellation(); try await operation(); return }
            catch {
                // Refused test identities/auth/schema are not transient; don't retry them.
                if case HTTPError.status(let code, _) = error, (400..<500).contains(code) { throw error }
                if attempt == 2 { throw error }
                try await Task.sleep(nanoseconds: UInt64(1 << attempt) * 1_000_000_000)
            }
        }
    }
    private func sendReceipt(_ id: String, call: UUID? = nil, event: String) {
        guard let event = CallReceipt.Event(rawValue: event) else { return }
        sendReceipt(id, call: call, receipt: CallReceipt(event))
    }
    private func sendReceipt(_ id: String, call: UUID?, receipt: CallReceipt) {
        guard PushInvitation.validID(id), !isTest else { return }
        do {
            try receiptOutbox.enqueue(PendingPushReceipt(reachoutID: id, call: call, receipt: receipt))
            StageDiagnostics.shared.record(.pushReceipt, .begin, callEvent: .receiptQueued,
                callEndInitiator: receipt.endInitiator, callEndReason: receipt.endReason, reportedRinging: receipt.reportedRinging, reportFailure: receipt.reportFailure)
        } catch { StageDiagnostics.shared.record(.pushReceipt, .failed, status: StageDiagnostics.code(error), callEvent: .receiptDeferred) }
        // Begin synchronously, BEFORE finish() invalidates the provider and iOS
        // removes CallKit's execution grant. Disk survives an exhausted assertion.
        flushReceiptOutbox()
    }
    private func flushReceiptOutbox() {
        guard !isTest, receiptWorker == nil, !receiptOutbox.entries.isEmpty else { return }
        let assertion = UIApplication.shared.beginBackgroundTask(withName: "Call terminal receipts") { [weak self] in
            Task { @MainActor in self?.receiptWorker?.cancel() }
        }
        receiptWorker = Task {
            defer {
                receiptWorker = nil
                if assertion != .invalid { UIApplication.shared.endBackgroundTask(assertion) }
            }
            while let entry = receiptOutbox.entries.first {
                do {
                    try Task.checkCancellation()
                    let transport = try transport(), body = try entry.body()
                    try await bounded { _ = try await transport.json("/v1/push/events", method: "POST", body: body) }
                    try receiptOutbox.acknowledge(entry.id)
                    StageDiagnostics.shared.record(.pushReceipt, .complete, callEvent: .receiptAcknowledged,
                        callEndInitiator: entry.receipt.endInitiator, callEndReason: entry.receipt.endReason, reportedRinging: entry.receipt.reportedRinging)
                } catch {
                    if case HTTPError.status(let code, _) = error, [404,410].contains(code) {
                        try? receiptOutbox.acknowledge(entry.id)
                    } else {
                        StageDiagnostics.shared.record(.pushReceipt, .failed, status: StageDiagnostics.code(error), callEvent: .receiptDeferred)
                        return // Durable item remains for the next launch/foreground, never spin/re-send a call.
                    }
                }
            }
        }
    }
    func pushRegistry(_ registry: PKPushRegistry, didUpdate credentials: PKPushCredentials, for type: PKPushType) { token(credentials.token) }
    func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        voipToken = nil; revision += 1; defaults.set(revision, forKey: "push.revision"); retry()
    }
    func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType, completion: @escaping () -> Void) {
        let values = payload.dictionaryPayload.reduce(into: [String: Any]()) { if let key = $1.key as? String { $0[key] = $1.value } }
        let key = values["reachoutID"] as? String ?? "malformed"
        let fallback = fallbackIDs[key] ?? UUID()
        if fallbackIDs.count < 512 { fallbackIDs[key] = fallback }
        let invitation = PushInvitation(payload: values, fallbackID: fallback)
        let replay = seenCalls.contains(invitation.id.uuidString)
        let capacity = seenCalls.count < 10_000
        let normalPolicy = phonePolicy.localCallsAllowed(at:Date())
        PhoneModel.shared.calls.receivePush(invitation, allowed: !replay && capacity && normalPolicy, completion: completion)
        // Mandatory report has already been invoked. Never put disk access ahead of it.
        StageDiagnostics.shared.record(.call, .policyGate, audio: CaptureSnapshot([.pushReplay: replay ? 1 : 0, .pushCapacity: capacity ? 1 : 0,
            .pushPolicyAllowed: normalPolicy ? 1 : 0]), callEvent: .pushAdmission)
        if !replay && capacity {
            seenCalls.insert(invitation.id.uuidString); defaults.set(Array(seenCalls), forKey: "push.seenCalls")
        }
    }
}

struct ReachOutSettingsView: View {
    @ObservedObject var push = PushCoordinator.shared
    var body: some View {
        Section("\(AgentPresentation.name) reach-out") {
            Toggle("Calls", isOn: binding(\.callsEnabled))
            Toggle("New conversation calls · pilot", isOn: Binding(get:{ push.openVoiceEnabled },set:{ push.setOpenVoiceEnabled($0) }))
            if push.openVoiceEnabled { Button("Review last pilot operation") { push.reviewOpenVoiceOperation() } }
            Toggle("Quiet hours · decline calls on this phone", isOn: binding(\.quietHoursEnabled))
            HStack {
                time("From", key: \.quietStart)
                time("Until", key: \.quietEnd)
            }
            Text("\(TimeZone.current.identifier) · call settings saved on this phone").font(.caption)
            HStack { Spacer(); Button("Retry") { push.foreground() } }
            Text("Calls are for urgent decisions. An unanswered call only reports its outcome; messages arrive through Nod. Focus is respected.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func binding(_ key: WritableKeyPath<ReachOutPolicy, Bool>) -> Binding<Bool> {
        Binding(get: { push.localPolicy[keyPath: key] }, set: { var p = push.localPolicy; p[keyPath: key] = $0; push.editLocalPolicy(p) })
    }
    private func time(_ title: String, key: WritableKeyPath<ReachOutPolicy, String>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.caption)
        DatePicker(title, selection: Binding(get: {
            let parts = push.localPolicy[keyPath: key].split(separator: ":").compactMap { Int($0) }
            return Calendar.current.date(from: DateComponents(hour: parts.first ?? 22, minute: parts.last ?? 0)) ?? Date()
        }, set: { date in
            let c = Calendar.current.dateComponents([.hour, .minute], from: date)
            var p = push.localPolicy; p[keyPath: key] = String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0); push.editLocalPolicy(p)
        }), displayedComponents: .hourAndMinute).labelsHidden().accessibilityLabel(title)
        }
    }
}
