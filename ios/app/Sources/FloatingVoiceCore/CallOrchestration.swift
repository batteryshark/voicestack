import Foundation

public enum CallEndReason { case ended, failed }

/// Callback identity is the adapter instance, not whichever call happens to be current.
public enum CallProviderEvent {
    case start(UUID, (Bool) -> Void), answer(UUID, (Bool) -> Void), end(UUID, (Bool) -> Void)
    case mute(UUID, Bool, (Bool) -> Void), hold(UUID, Bool, (Bool) -> Void)
    case activated, deactivated, reset, timedOut(UUID), systemFailure(UUID), routeChanged, controlRejected, failed(String)
}

@MainActor public protocol CallProviderAdapter: AnyObject {
    var onEvent: ((CallProviderEvent) -> Void)? { get set }
    var routeLabel: String { get }
    func requestStart(_ id: UUID, completion: @escaping (Error?) -> Void)
    func requestEnd(_ id: UUID)
    func requestMute(_ id: UUID, muted: Bool)
    func requestHold(_ id: UUID, held: Bool)
    func configure() throws
    func connecting(_ id: UUID)
    func connected(_ id: UUID)
    func ended(_ id: UUID, reason: CallEndReason)
    func observeActivation(_ granted: Bool)
    func refresh(proximity: Bool)
    func toggleSpeaker()
    func invalidate()
    func reportIncoming(_ id: UUID, completion: @escaping (Error?) -> Void)
}

public extension CallProviderAdapter {
    func reportIncoming(_ id: UUID, completion: @escaping (Error?) -> Void) { completion(ClientError("Incoming calls unavailable")) }
}

/// Production orchestration, shared by CallKit and deterministic fake-provider race tests.
/// A retired provider must release/reset before Start can create a fresh provider identity.
@MainActor public final class CallCoordinator {
    public let lifecycle = CallLifecycle()
    private let makeProvider: (CallLifecycle) -> CallProviderAdapter
    private var provider: CallProviderAdapter?
    private var cycle = 0
    private var draining = false
    private var sessionActive = false
    private var grantGeneration = 0
    private var releasedGrantGeneration = 0
    private var activeGrantGeneration: Int?
    private var pendingGrantGeneration: Int?
    private var hasObservedActivation = false
    private var activationPending: Bool { pendingGrantGeneration != nil }
    private var providerInvalidated = false
    private var waitingForHoldRelease = false
    private var setup: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var mediaStarting = false
    private var mediaRevision = 0
    private var reportedConnected = false
    private var routeMediaPaused = false
    public private(set) var hasEverBeenMediaReady = false
    public private(set) var mediaAttempt: CallMediaAttempt = .initial
    public var mediaIsPaused: Bool { routeMediaPaused }
    public var mayChangeLiveRoute: Bool { hasCall && sessionActive && lifecycle.mayRunMedia }
    private var incoming: PushInvitation?
    private var seenIncoming: Set<UUID> = []
    private static var nextInstance = 0
    public let diagnosticInstance: Int
    public private(set) var incomingReportedRinging = false
    public var detailedReceipt: ((PushInvitation, CallReceipt) -> Void)?
    public var resolveIncoming: ((PushInvitation) async throws -> TargetLease)?
    public var receipt: ((PushInvitation, String) -> Void)?
    public var incomingTimeout: UInt64 = 12_000_000_000
    public var readinessTimeout: UInt64 = 20_000_000_000
    public var beginMedia: ((Int) async -> Bool)?
    public var pauseMedia: (() -> Void)?
    public var endMedia: (() -> Void)?
    public var onTerminal: (() -> Void)?
    public var recoveryPaused: ((CallEndCause) -> Void)?
    public var mediaReady: (() -> Void)?
    public var setMuted: ((Bool) -> Void)?
    public var changed: (() -> Void)?
    public var failed: ((String) -> Void)?
    public var hasCall: Bool { lifecycle.hasCall }
    public var routeLabel: String { provider?.routeLabel ?? "Audio off" }
    public init(makeProvider: @escaping (CallLifecycle) -> CallProviderAdapter) {
        self.makeProvider = makeProvider
        Self.nextInstance += 1; diagnosticInstance = Self.nextInstance
        StageDiagnostics.shared.record(.call, .begin, audio: CaptureSnapshot([.coordinatorInstance: Double(diagnosticInstance), .processID: Double(ProcessInfo.processInfo.processIdentifier)]), callEvent: .coordinatorCreated)
    }
    private func emit(_ invitation: PushInvitation, _ value: CallReceipt) {
        detailedReceipt?(invitation, value)
        receipt?(invitation, value.event.rawValue)
    }
    public func toggleSpeaker() {
        guard mayChangeLiveRoute else { routeControlRejected(); return }
        provider?.toggleSpeaker()
    }

    /// No auth, lookup, permission or network may precede this report.
    public func receivePush(_ invitation: PushInvitation, allowed: Bool, now: Date = Date(), completion: @escaping () -> Void) {
        releaseInvalidatedIdleProvider() // Defensive recovery of an already-authorized, audio-idle terminal drain.
        let duplicate = lifecycle.id == invitation.id && hasCall
        let admitted = !draining && !hasCall && !seenIncoming.contains(invitation.id) && seenIncoming.count < 10_000 && invitation.valid && allowed &&
            (invitation.expiry ?? .distantPast) > now && (invitation.deadline ?? .distantPast) > now
        if seenIncoming.count < 10_000 { seenIncoming.insert(invitation.id) }
        let adapter: CallProviderAdapter
        if let provider { adapter = provider }
        else {
            adapter = makeProvider(lifecycle)
            if admitted {
                _ = lifecycle.incoming(id: invitation.id); incoming = invitation
                StageDiagnostics.shared.beginCall()
                incomingReportedRinging = false
                provider = adapter; cycle += 1
                sessionActive = false; waitingForHoldRelease = false; reportedConnected = false; routeMediaPaused = false
                resetActivationTracking(); providerInvalidated = false
                hasEverBeenMediaReady = false; mediaAttempt = .initial
                let owner = cycle
                adapter.onEvent = { [weak self] in self?.receive($0, cycle: owner) }
                setMuted?(false)
            }
        }
        adapter.reportIncoming(invitation.id) { [weak self, adapter] error in
            defer { completion() }
            guard let self else { return }
            // Duplicate reports must still happen, but cannot kill the original call.
            if duplicate { return }
            let reportCode = error.map { ($0 as? IncomingReportError)?.code ?? ($0 as NSError).code }
            let reportFailure = error.map { IncomingReportFailure.classify($0) }
            StageDiagnostics.shared.record(.call, error == nil ? .ready : .failed, status: reportCode,
                callEvent: error == nil ? .reportSucceeded : .reportFailed, reportedRinging: self.incomingReportedRinging, reportFailure: reportFailure)
            if error != nil { self.emit(invitation, CallReceipt(.reportFailed, reason: .reportRejected, initiator: .reportFailure, reportedRinging: false, reportFailure: reportFailure, reportErrorCode: reportCode)) }
            else { self.emit(invitation, CallReceipt(.reported, reportedRinging: false)) }
            guard admitted, self.owns(invitation.id) else {
                self.endDecision(self.lifecycle.epoch, cause: .admissionRejected, reason: .ended,
                    termination: .admissionRejected, rejection: (adapter, invitation))
                return
            }
            guard error == nil else { self.endDecision(self.lifecycle.epoch, cause: .setupFailure, reason: .failed, initiator: .reportFailure, termination: .reportRejected, reportFailure: reportFailure, reportCode: reportCode); return }
            guard self.lifecycle.state == .ringing, self.setup == nil else { return }
            self.incomingReportedRinging = true
            self.emit(invitation, CallReceipt(.ringing, reportedRinging: true)); self.refresh()
            StageDiagnostics.shared.record(.call, .ready, callEvent: .ringing, reportedRinging: true)
            let epoch = self.lifecycle.epoch
            let delay = Self.ringDelay(invitation, now: Date())
            StageDiagnostics.shared.record(.call, .begin, audio: CaptureSnapshot([.deadlineDelayMs: delay * 1000]), callEvent: .deadlineArmed, callEndInitiator: .ringDeadline, reportedRinging: true)
            self.deadline = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.endDecision(epoch, cause: .ringDeadline, reason: .ended, initiator: .ringDeadline, termination: .ringExpired)
            }
        }
        StageDiagnostics.shared.record(.call, .begin, callEvent: .reportRequested)
    }
    public static func ringDelay(_ invitation: PushInvitation, now: Date) -> TimeInterval {
        guard let deadline = invitation.deadline, let expiry = invitation.expiry else { return 0 }
        return max(0, min(30, min(deadline, expiry).timeIntervalSince(now)))
    }

    public func start(target: TargetLease) {
        releaseInvalidatedIdleProvider()
        guard !draining else { failed?("Previous call is releasing audio; try Start again"); return }
        guard let epoch = lifecycle.begin(target: target), let id = lifecycle.id else { return }
        StageDiagnostics.shared.beginCall()
        cycle += 1
        let owner = cycle
        let adapter = makeProvider(lifecycle)
        provider = adapter
        sessionActive = false; waitingForHoldRelease = false; reportedConnected = false; routeMediaPaused = false
        resetActivationTracking(); providerInvalidated = false
        hasEverBeenMediaReady = false; mediaAttempt = .initial
        adapter.onEvent = { [weak self] event in self?.receive(event, cycle: owner) }
        setMuted?(false); refresh(); armDeadline(epoch)
        adapter.requestStart(id) { [weak self] error in
            guard let self, self.cycle == owner, let error else { return }
            self.endDecision(epoch, cause: .setupFailure, reason: .failed, error: error.localizedDescription, termination: .mediaFailed)
        }
    }
    /// Explicit user End only. Automatic errors must use mediaFailed/restrictPolicy.
    public func end() {
        endDecision(lifecycle.epoch, cause: .userEnd, reason: .ended, requestSystemEnd: true)
    }
    public func restrictPolicy() {
        endDecision(lifecycle.epoch, cause: .policyRestricted, reason: .ended, initiator: .policyChange, termination: .policyRestricted)
    }
    public func mediaFailed(_ cause: CallEndCause = .mediaFailure) {
        // Public media callers cannot impersonate terminal user/system authority.
        let allowed: Set<CallEndCause> = [.mediaFailure, .captureFailure, .conversionFailure, .repairFailure, .backendFailure, .leaseFailure, .mediaReset]
        endDecision(lifecycle.epoch, cause: allowed.contains(cause) ? cause : .mediaFailure, reason: .failed,
            initiator: cause == .leaseFailure ? .targetChange : .mediaFailure,
            termination: cause == .leaseFailure ? .targetChanged : .mediaFailed)
    }
    public func mute(_ muted: Bool) { if hasCall, let id = lifecycle.id { provider?.requestMute(id, muted: muted) } }
    public func hold(_ held: Bool) { if hasCall, let id = lifecycle.id { provider?.requestHold(id, held: held) } }
    /// Refused CONTROL is not admitted MEDIA. In particular it must not cancel
    /// ringing, answer setup or the initial readiness/activation deadline.
    public func routeControlRejected() {
        StageDiagnostics.shared.record(.route, .policyGate, callEvent: .controlRejected)
        failed?(RouteSwitchError.unavailable.localizedDescription)
    }

    /// Audio instability is not a hang-up or a CallKit deactivation. Fence even
    /// an in-flight initial beginMedia completion without finishing the call.
    public func pauseMediaForRouteRecovery() {
        endDecision(lifecycle.epoch, cause: .routePause, reason: .failed, initiator: .mediaFailure, termination: .mediaFailed)
    }
    public func resumeMediaAfterRouteRecovery() {
        guard routeMediaPaused, hasCall, !draining, lifecycle.mayRunMedia else { return }
        routeMediaPaused = false
        mediaAttempt = .recovery // Retained until verified success; timeout/false are still recovery.
        startMedia()
    }

    private func receive(_ event: CallProviderEvent, cycle owner: Int) {
        guard owner == cycle else {
            switch event {
            case .start(_, let complete), .answer(_, let complete), .end(_, let complete), .mute(_, _, let complete), .hold(_, _, let complete): complete(false)
            default: break
            }
            return // old provider callbacks can never reach a replacement call
        }
        switch event {
        case .answer(let id, let complete):
            guard owns(id), let invitation = incoming, lifecycle.state == .ringing, setup == nil else { complete(false); return }
            deadline?.cancel()
            let epoch = lifecycle.epoch
            StageDiagnostics.shared.record(.call, .begin, audio: CaptureSnapshot([.deadlineDelayMs: Double(incomingTimeout)/1_000_000]), callEvent: .deadlineArmed, callEndInitiator: .answerDeadline, reportedRinging: incomingReportedRinging)
            deadline = Task { [weak self] in
                try? await Task.sleep(nanoseconds: self?.incomingTimeout ?? 12_000_000_000)
                guard !Task.isCancelled else { return }
                complete(false); self?.endDecision(epoch, cause: .answerDeadline, reason: .failed, initiator: .answerDeadline, termination: .answerTimeout)
            }
            setup = Task { [weak self] in
                guard let self else { return }
                do {
                    guard let target = try await self.resolveIncoming?(invitation), !Task.isCancelled,
                          self.lifecycle.bindIncoming(target, owner: epoch) else { throw ClientError("Call context unavailable") }
                    try self.provider?.configure()
                    self.deadline?.cancel(); self.armDeadline(epoch)
                    self.requestActivationGrant()
                    self.emit(invitation, CallReceipt(.answered, reportedRinging: self.incomingReportedRinging))
                    complete(true); self.refresh(); self.startMedia()
                } catch {
                    guard self.lifecycle.admits(epoch) else { return }
                    complete(false); self.endDecision(epoch, cause: .setupFailure, reason: .failed, error: "Incoming call could not connect", initiator: .mediaFailure, termination: .answerFailed)
                }
            }
        case .reset:
            sessionActive = false
            releasedGrantGeneration = grantGeneration
            activeGrantGeneration = nil; pendingGrantGeneration = nil
            StageDiagnostics.shared.record(.call, .cancelled, callEvent: .providerReset, reportedRinging: incomingReportedRinging)
            endDecision(lifecycle.epoch, cause: .providerReset, reason: .failed, initiator: .providerReset, termination: .providerReset)
            releaseProvider()
        case .deactivated:
            StageDiagnostics.shared.record(.call, .suspended, callEvent: .deactivated, reportedRinging: incomingReportedRinging)
            let wasActive = sessionActive
            sessionActive = false; waitingForHoldRelease = false
            if let active = activeGrantGeneration {
                releasedGrantGeneration = max(releasedGrantGeneration, active)
                activeGrantGeneration = nil // A queued fresh Unhold grant is NOT this old release.
            }
            // A release with no observed active grant cannot prove cancellation
            // of a future Unhold grant. Only its activation+release or reset can.
            recordGrantState(.activationReleased)
            lifecycle.deactivate(); provider?.observeActivation(false)
            if draining {
                if !activationPending { releaseProvider() }
            } else if hasCall {
                if [.connecting, .active].contains(lifecycle.state), pendingGrantGeneration == nil {
                    requestActivationGrant(fresh: true) // System reactivation after interruption/deactivation.
                }
                if wasActive || mediaStarting { pause() }
            }
            refresh()
        case .activated:
            if draining { observeActivationGrant(); return } // Late grant still owns the shared session.
            guard hasCall, !draining else { return }
            // Even an activation delivered while held belongs to the held ownership cycle.
            // It cannot be saved for Unhold; require its release followed by a fresh activation.
            if lifecycle.state == .held { observeActivationGrant(); waitingForHoldRelease = true; return }
            guard !waitingForHoldRelease, !sessionActive else { return }
            observeActivationGrant()
            lifecycle.activate(lifecycle.epoch); provider?.observeActivation(true)
            startMedia()
        case .start(let id, let complete):
            guard owns(id), lifecycle.connecting(lifecycle.epoch) else { complete(false); return }
            do {
                try provider?.configure()
                provider?.connecting(id)
                requestActivationGrant()
                complete(true) // never await activation
                refresh(); startMedia()
            } catch { complete(false); endDecision(lifecycle.epoch, cause: .setupFailure, reason: .failed, error: error.localizedDescription, termination: .mediaFailed) }
        case .hold(let id, let held, let complete):
            guard owns(id) else { complete(false); return }
            if lifecycle.hold(held, owner: lifecycle.epoch) {
                if held {
                    waitingForHoldRelease = sessionActive
                    pause(); provider?.observeActivation(false); deadline?.cancel()
                } else {
                    requestActivationGrant(fresh: true) // BEFORE fulfilling Unhold, even while an older grant drains.
                    if !routeMediaPaused { armDeadline(lifecycle.epoch) }
                } // Unhold never starts media without its new didActivate.
            }
            complete(true); refresh()
        case .mute(let id, let muted, let complete):
            guard owns(id) else { complete(false); return }
            if lifecycle.mute(muted, owner: lifecycle.epoch) { setMuted?(muted) }
            complete(true); refresh()
        case .end(let id, let complete):
            guard lifecycle.id == id else { complete(false); return }
            let termination: CallTerminationReason = lifecycle.state == .ringing ? .declined : .requested
            StageDiagnostics.shared.record(.call, .cancelled, callEvent: .systemEndAction, callEndInitiator: .systemEndAction, callEndReason: termination, reportedRinging: incomingReportedRinging)
            if lifecycle.state == .ringing, let incoming { emit(incoming, CallReceipt(.declined, reason: .declined, initiator: .systemEndAction, reportedRinging: incomingReportedRinging)) }
            endDecision(lifecycle.epoch, cause: .systemEnd, reason: .ended, initiator: .systemEndAction, termination: termination); complete(true)
        case .timedOut(let id):
            if owns(id) { endDecision(lifecycle.epoch, cause: .systemFailure, reason: .failed, error: "System call action timed out", initiator: .actionTimeout, termination: .actionTimeout) }
        case .systemFailure(let id):
            if owns(id) { endDecision(lifecycle.epoch, cause: .systemFailure, reason: .failed, initiator: .actionTimeout, termination: .actionTimeout) }
        case .routeChanged: refresh()
        case .controlRejected: routeControlRejected()
        case .failed(let message):
            // A local route/mute/transaction error is not a CallKit call failure.
            endDecision(lifecycle.epoch, cause: .routePause, reason: .failed, error: message,
                initiator: .mediaFailure, termination: .mediaFailed)
        }
    }
    private func owns(_ id: UUID) -> Bool { hasCall && id == lifecycle.id }
    private func startMedia() {
        guard lifecycle.mayRunMedia, !mediaStarting, !routeMediaPaused else { return }
        let epoch = lifecycle.epoch, revision = mediaRevision
        mediaStarting = true; armDeadline(epoch)
        setup = Task { [weak self] in
            guard let self else { return }
            let ready = await self.beginMedia?(epoch) == true
            guard !Task.isCancelled, self.mediaRevision == revision,
                  self.lifecycle.admits(epoch), self.lifecycle.mayRunMedia else { return }
            self.mediaStarting = false
            if ready, self.lifecycle.ready(epoch), let id = self.lifecycle.id {
                self.hasEverBeenMediaReady = true
                self.mediaAttempt = .initial
                self.deadline?.cancel(); self.deadline = nil
                if !self.reportedConnected { self.reportedConnected = true; if self.incoming == nil { self.provider?.connected(id) } }
                self.mediaReady?(); self.refresh()
            } else { self.endDecision(epoch, cause: .mediaFailure, reason: .failed, error: "Voice could not become ready", initiator: .mediaFailure, termination: .mediaFailed) }
        }
    }
    private func pause() {
        mediaRevision += 1; setup?.cancel(); setup = nil; mediaStarting = false
        pauseMedia?()
    }
    public func interrupted() {
        guard hasCall else { return }
        if pendingGrantGeneration == nil, grantGeneration > 0 || hasObservedActivation { requestActivationGrant(fresh: true) }
        lifecycle.deactivate(); provider?.observeActivation(false); pause(); refresh()
        // Only a release + didActivate grants a new media cycle, not .shouldResume.
        waitingForHoldRelease = sessionActive
    }
    public func mediaReset() { endDecision(lifecycle.epoch, cause: .mediaReset, reason: .failed, initiator: .mediaReset, termination: .mediaReset) }
    private func armDeadline(_ epoch: Int) {
        deadline?.cancel(); deadline = nil
        guard !routeMediaPaused else { return }
        let delay = readinessTimeout
        StageDiagnostics.shared.record(.call, .begin, audio: CaptureSnapshot([.deadlineDelayMs: Double(delay) / 1_000_000]), callEvent: .deadlineArmed, callEndInitiator: .readinessDeadline, reportedRinging: incomingReportedRinging)
        deadline = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard let self, !Task.isCancelled, !self.routeMediaPaused else { return }
            self.endDecision(epoch, cause: .readinessDeadline, reason: .failed, error: "Call readiness timed out", initiator: .readinessDeadline, termination: .readinessTimeout)
        }
    }
    /// SINGLE end authority: every terminal cleanup and every rejected report
    /// passes here. No timeout, false result or native media callback calls finish.
    private func endDecision(_ epoch: Int, cause: CallEndCause, reason: CallEndReason, error: String? = nil,
        initiator: CallEndInitiator = .app, termination: CallTerminationReason = .requested,
        reportFailure: IncomingReportFailure? = nil, reportCode: Int? = nil,
        requestSystemEnd: Bool = false, rejection: (CallProviderAdapter, PushInvitation)? = nil) {
        guard rejection != nil || (lifecycle.admits(epoch) && !draining) else { return }
        if cause == .routePause && !mayChangeLiveRoute { routeControlRejected(); return }
        let everReady = rejection == nil && hasEverBeenMediaReady
        let attempt: CallMediaAttempt = rejection == nil ? mediaAttempt : .initial
        let decision = CallEndAuthority.decide(cause, everReady: everReady, attempt: attempt)
        StageDiagnostics.shared.record(.call, decision == .terminal ? .complete : .suspended,
            callAuthority: CallAuthorityDiagnostic(cause: cause, decision: decision, everReady: everReady,
                attempt: attempt, rejectedReport: rejection != nil))
        if decision == .pause {
            guard !routeMediaPaused else { return } // Fence reentrant status/lease failures before callbacks.
            routeMediaPaused = true
            deadline?.cancel(); deadline = nil
            pause()
            recoveryPaused?(cause)
            refresh()
            return
        }
        if let (adapter, invitation) = rejection {
            finishRejectedReport(adapter, invitation)
            return
        }
        if requestSystemEnd, let id = lifecycle.id {
            StageDiagnostics.shared.record(.call, .cancelled, callEvent: .endRequested, callEndInitiator: initiator, callEndReason: termination)
            provider?.requestEnd(id)
        }
        finish(epoch, reason: reason, error: error, initiator: initiator, termination: termination, reportFailure: reportFailure, reportCode: reportCode)
    }
    private func finishRejectedReport(_ adapter: CallProviderAdapter, _ invitation: PushInvitation) {
        adapter.ended(invitation.id, reason: .ended)
        emit(invitation, CallReceipt(.ended, reason: .admissionRejected, initiator: .app, reportedRinging: false))
        if provider !== adapter { adapter.invalidate() } // Never invalidate a live shared provider.
    }
    private func finish(_ epoch: Int, reason: CallEndReason, error: String? = nil, initiator: CallEndInitiator = .app, termination: CallTerminationReason = .requested, reportFailure: IncomingReportFailure? = nil, reportCode: Int? = nil) {
        let id = lifecycle.id
        guard lifecycle.end(epoch) else { return }
        if let incoming {
            emit(incoming, CallReceipt(.ended, reason: termination, initiator: initiator, reportedRinging: incomingReportedRinging, reportFailure: reportFailure, reportErrorCode: reportCode))
            self.incoming = nil
        }
        StageDiagnostics.shared.record(.call, reason == .failed ? .failed : .complete, status: reportCode,
            callEvent: .ended, callEndInitiator: initiator, callEndReason: termination, reportedRinging: incomingReportedRinging, reportFailure: reportFailure)
        draining = true // fence Start before user cleanup can reenter
        provider?.observeActivation(false)
        mediaRevision += 1; setup?.cancel(); setup = nil; mediaStarting = false
        deadline?.cancel(); deadline = nil
        endMedia?()
        if let id { provider?.ended(id, reason: reason) }
        providerInvalidated = true
        provider?.invalidate()
        onTerminal?()
        if let error { failed?(error) }
        releaseInvalidatedIdleProvider() // Unanswered/declined/report-failed calls never receive didDeactivate.
        refresh()
    }
    private func releaseInvalidatedIdleProvider() {
        guard draining, providerInvalidated, !sessionActive, !activationPending,
              grantGeneration == 0, !hasObservedActivation else { return }
        releaseProvider() // Terminal authority already ended the lifecycle; never releases a live call.
    }
    private func resetActivationTracking() {
        grantGeneration = 0; releasedGrantGeneration = 0
        activeGrantGeneration = nil; pendingGrantGeneration = nil; hasObservedActivation = false
    }
    private func requestActivationGrant(fresh: Bool = false) {
        guard fresh || !sessionActive else { return }
        grantGeneration += 1
        pendingGrantGeneration = grantGeneration
        recordGrantState(.activationRequested)
    }
    private func observeActivationGrant() {
        hasObservedActivation = true
        if activeGrantGeneration == nil {
            if let pending = pendingGrantGeneration { activeGrantGeneration = pending; pendingGrantGeneration = nil }
            else { grantGeneration += 1; activeGrantGeneration = grantGeneration }
        }
        sessionActive = true
        recordGrantState(.activationGranted)
    }
    private func recordGrantState(_ event: CallDiagnosticEvent) {
        StageDiagnostics.shared.record(.call, .complete, audio: CaptureSnapshot([
            .activation: sessionActive ? 1 : 0, .activationPending: activationPending ? 1 : 0,
            .grantGeneration: Double(grantGeneration), .activeGrantGeneration: Double(activeGrantGeneration ?? 0),
            .pendingGrantGeneration: Double(pendingGrantGeneration ?? 0), .releasedGrantGeneration: Double(releasedGrantGeneration)
        ]), callEvent: event)
    }
    private func releaseProvider() {
        guard !hasCall else { return } // Only release a provider whose terminal decision already fenced its call.
        guard provider != nil else { return }
        StageDiagnostics.shared.record(.call, .complete,
            audio: CaptureSnapshot([.activation: sessionActive ? 1 : 0, .activationPending: activationPending ? 1 : 0]),
            callEvent: .providerReleased)
        provider?.observeActivation(false)
        provider = nil; draining = false; sessionActive = false; waitingForHoldRelease = false
        resetActivationTracking(); providerInvalidated = false
        cycle += 1 // fence every callback, including duplicates after reset/deactivation
    }
    private func refresh() {
        provider?.refresh(proximity: lifecycle.state == .active && lifecycle.mayRunMedia)
        changed?()
    }
}
