import UIKit
import PushKit
import UserNotifications
import SwiftUI

@MainActor final class PushAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        PushCoordinator.shared.start(model: PhoneModel.shared)
        return true
    }
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken token: Data) {
        PushCoordinator.shared.token(token, voip: false)
    }
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        PushCoordinator.shared.registrationFailed()
    }
}

@MainActor final class PushCoordinator: NSObject, ObservableObject, @preconcurrency PKPushRegistryDelegate, @preconcurrency UNUserNotificationCenterDelegate {
    static let shared = PushCoordinator()
    @Published private(set) var policy: PushPolicySync
    @Published private(set) var syncStatus = "Not synced"
    @Published private(set) var permission = "Not requested"
    private var registry: PKPushRegistry?
    private weak var model: PhoneModel?
    private var worker: Task<Void, Never>?
    private var dirty = false
    private let defaults = UserDefaults.standard
    private var alertToken: String?
    private var voipToken: String?
    private var revision: Int
    private var enrollmentAck = 0
    private let tapQueue = NotificationTapQueue()
    private var fallbackIDs: [String: UUID] = [:]
    private let receiptOutbox: PushReceiptOutbox
    private var receiptWorker: Task<Void, Never>?
    private var seenCalls: Set<String>
    override init() {
        receiptOutbox = PushReceiptOutbox(file: URL.applicationSupportDirectory.appendingPathComponent("Push/receipt-outbox23.json"))
        policy = UserDefaults.standard.data(forKey: "push.policy").flatMap { try? JSONDecoder().decode(PushPolicySync.self, from: $0) } ?? PushPolicySync()
        revision = max(1, UserDefaults.standard.integer(forKey: "push.revision"))
        seenCalls = Set(UserDefaults.standard.stringArray(forKey: "push.seenCalls") ?? [])
        // Tokens are reacquired from the OS, not copied or stored in diagnostics/defaults.
        super.init()
    }
#if DEBUG && targetEnvironment(simulator)
    func polishDenied() { permission = "Denied · enable in iOS Settings" }
#endif
    private var isTest: Bool {
        DeviceAudioProbe.enabled || PhoneLoopProbe.enabled || SpeakerEchoProbe.enabled || ProcessInfo.processInfo.arguments.contains("-FVSimulatorProof") || ProcessInfo.processInfo.arguments.contains("-FVRichFixture") || ProcessInfo.processInfo.arguments.contains("-FVPolish")
    }
    func start(model: PhoneModel) {
        self.model = model
        _ = model.calls
        model.calls.resolveIncoming = { [weak model, weak self] invitation in
            guard let self, let model, let id = invitation.reachoutID else { throw ClientError("Call unavailable") }
            guard self.policy.allowsCall(at: Date()), (invitation.expiry ?? .distantPast) > Date() else { throw ClientError("Call no longer allowed") }
            let target = try await IncomingCallResolution.resolve(invitation: invitation, lifecycle: model.calls.lifecycle, lookup: {
                let record = try await self.transport().json("/v1/push/reachouts/" + id)
                return try ReachOutContext(record: record, reachoutID: id, invitation: invitation)
            }, join: { context, owner in
                try owner.validate(model.calls.lifecycle)
                guard self.policy.allowsCall(at: Date()) else { throw ClientError("Call no longer allowed") }
                return try await model.joinInvitation(context, owner: owner)
            })
            guard self.policy.desired.timeZone == TimeZone.current.identifier,
                  self.policy.allowsCall(at: Date()), (invitation.expiry ?? .distantPast) > Date() else { throw ClientError("Call no longer allowed") }
            return target
        }
        model.calls.detailedReceipt = { [weak self] invitation, receipt in
            guard let id = invitation.reachoutID else { return }
            self?.sendReceipt(id, call: invitation.id, receipt: receipt)
            if receipt.event == .answered { self?.removeNotifications(id) }
        }
        guard registry == nil, !isTest else { return }
        if receiptOutbox.loadFailed { StageDiagnostics.shared.record(.pushReceipt, .failed, status: 1, callEvent: .receiptDeferred) }
        flushReceiptOutbox()
        let center = UNUserNotificationCenter.current(); center.delegate = self
        center.setNotificationCategories(Set([("NEED", "Open conversation"), ("READY_TO_TRY", "Review build"), ("URGENT_FALLBACK", "Open")].map { category, title in
            UNNotificationCategory(identifier: category, actions: [UNNotificationAction(identifier: "OPEN", title: title, options: [.foreground, .authenticationRequired])], intentIdentifiers: [], options: [.customDismissAction])
        }))
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
        flushReceiptOutbox()
        var desired = policy.desired; desired.timeZone = TimeZone.current.identifier
        edit(desired)
        Task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            let allowed = [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus)
            permission = allowed ? "Allowed · respects Focus" : (settings.authorizationStatus == .denied ? "Denied · enable in iOS Settings" : "Not requested")
            if allowed { UIApplication.shared.registerForRemoteNotifications() }
            else { token(nil, voip: false) }
            // Refresh server-invalidated enrollment at a newer revision on each foreground.
            revision += 1; defaults.set(revision, forKey: "push.revision")
            retry()
            await routePendingTap()
        }
    }
    func requestPermission() {
        Task {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            foreground()
        }
    }
    func registrationFailed() {
        syncStatus = "Alert registration failed · Retry"
        StageDiagnostics.shared.record(.pushEnrollment, .failed, status: 1)
    }
    func token(_ data: Data?, voip: Bool) {
        let value = data?.map { String(format: "%02x", $0) }.joined()
        guard (voip ? voipToken : alertToken) != value else { return }
        if voip { voipToken = value } else { alertToken = value }
        revision += 1; defaults.set(revision, forKey: "push.revision"); retry()
    }
    func edit(_ desired: ReachOutPolicy) {
        policy.edit(desired)
        if !policy.allowsCall(at: Date()), model?.calls.lifecycle.state == .ringing { model?.calls.restrictPolicy() }
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
                let enrollment: [String: Any] = ["alertToken": self.alertToken as Any? ?? NSNull(), "voipToken": self.voipToken as Any? ?? NSNull(), "environment": environment, "build": String(InstalledBuild.number), "revision": revision]
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
    func pushRegistry(_ registry: PKPushRegistry, didUpdate credentials: PKPushCredentials, for type: PKPushType) { token(credentials.token, voip: true) }
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
        let normalPolicy = policy.desired.timeZone == TimeZone.current.identifier && policy.allowsCall(at: Date())
        PhoneModel.shared.calls.receivePush(invitation, allowed: !replay && capacity && normalPolicy, completion: completion)
        // Mandatory report has already been invoked. Never put disk access ahead of it.
        StageDiagnostics.shared.record(.call, .policyGate, audio: CaptureSnapshot([.pushReplay: replay ? 1 : 0, .pushCapacity: capacity ? 1 : 0,
            .pushPolicyAllowed: normalPolicy ? 1 : 0]), callEvent: .pushAdmission)
        if !replay && capacity {
            seenCalls.insert(invitation.id.uuidString); defaults.set(Array(seenCalls), forKey: "push.seenCalls")
        }
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completion: @escaping (UNNotificationPresentationOptions) -> Void) {
        completion([.banner, .list, .sound]) // Generic system text only; no lookup or action on arrival.
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completion: @escaping () -> Void) {
        defer { completion() }
        guard response.actionIdentifier != UNNotificationDismissActionIdentifier,
              [UNNotificationDefaultActionIdentifier, "OPEN"].contains(response.actionIdentifier),
              let id = response.notification.request.content.userInfo["reachoutID"] as? String, PushInvitation.validID(id),
              ReachOutContext.categoryAllowed(response.notification.request.content.categoryIdentifier) else { return }
        StageDiagnostics.shared.record(.notificationRoute, .complete, routePhase: .received)
        tapQueue.enqueue(.init(id: id, category: response.notification.request.content.categoryIdentifier))
        Task { await routePendingTap() }
    }
    private func routePendingTap() async {
        do {
            try await tapQueue.drain(ready: {
                UIApplication.shared.applicationState == .active && UIApplication.shared.isProtectedDataAvailable && self.model != nil
            }, route: { tap in
                guard let model = self.model else { throw NotificationRouteFailure.preparation }
                let context = try await NotificationRouting.step(.lookup) {
                    let record = try await self.transport().json("/v1/push/reachouts/" + tap.id)
                    do { return try ReachOutContext(record: record, reachoutID: tap.id) }
                    catch { throw NotificationRouteFailure.invalidContext }
                }
                try await model.openReachOut(context, reviewBuild: tap.category == "READY_TO_TRY")
                try await NotificationRouting.step(.receipt) { self.sendReceipt(tap.id, event: "notification-opened") }
            })
        } catch { model?.error = "Notification: Couldn't open that message" }
    }
    private func removeNotifications(_ id: String) {
        UNUserNotificationCenter.current().getDeliveredNotifications { notifications in
            let ids = notifications.filter { $0.request.content.userInfo["reachoutID"] as? String == id }.map { $0.request.identifier }
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
        }
    }
}

struct ReachOutSettingsView: View {
    @ObservedObject var push = PushCoordinator.shared
    var body: some View {
        Section("\(AgentPresentation.name) reach-out") {
            Toggle("Calls", isOn: binding(\.callsEnabled))
            Toggle("Quiet hours · notifications only", isOn: binding(\.quietHoursEnabled))
            HStack {
                time("From", key: \.quietStart)
                time("Until", key: \.quietEnd)
            }
            Text("\(push.policy.desired.timeZone) · \(push.syncStatus)").font(.caption)
            Text("Notifications: \(push.permission)").font(.caption)
            HStack {
                Button("Enable notifications") { push.requestPermission() }
                Spacer(); Button("Retry") { push.foreground() }
            }
            Text("\(AgentPresentation.name) can ask for a decision or your hands, or share a build ready to try. No milestone news. Calls are for urgent decisions; unanswered calls become one notification. Focus is respected; lock-screen text stays generic.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func binding(_ key: WritableKeyPath<ReachOutPolicy, Bool>) -> Binding<Bool> {
        Binding(get: { push.policy.desired[keyPath: key] }, set: { var p = push.policy.desired; p[keyPath: key] = $0; push.edit(p) })
    }
    private func time(_ title: String, key: WritableKeyPath<ReachOutPolicy, String>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.caption)
        DatePicker(title, selection: Binding(get: {
            let parts = push.policy.desired[keyPath: key].split(separator: ":").compactMap { Int($0) }
            return Calendar.current.date(from: DateComponents(hour: parts.first ?? 22, minute: parts.last ?? 0)) ?? Date()
        }, set: { date in
            let c = Calendar.current.dateComponents([.hour, .minute], from: date)
            var p = push.policy.desired; p[keyPath: key] = String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0); push.edit(p)
        }), displayedComponents: .hourAndMinute).labelsHidden().accessibilityLabel(title)
        }
    }
}
