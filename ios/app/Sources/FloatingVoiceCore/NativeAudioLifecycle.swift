import Foundation

/// The native capture's ownership boundary. Permission may outlive Stop (and a later Start).
/// All resource operations after permission are synchronous on the main actor.
@MainActor public final class CaptureLifecycle {
    public private(set) var generation = 0
    public private(set) var capturing = false
    private var ownsResources = false
    public init() {}
    public func admits(_ owner: Int) -> Bool { capturing && generation == owner }
    public func start(permission: () async throws -> Void, activate: () throws -> Void,
                      open: (Int) throws -> Void, close: () -> Void, deactivate: () -> Void,
                      ready: (Int) async throws -> Void = { _ in }) async throws {
        guard !capturing else { return }
        generation += 1
        let owner = generation
        try await permission()
        guard owner == generation, !Task.isCancelled else { throw CancellationError() }
        // Activation can partially succeed before throwing (e.g. routing failure).
        ownsResources = true
        do {
            try activate()
            try open(owner)
            capturing = true
            try await ready(owner)
            guard admits(owner), !Task.isCancelled else { throw CancellationError() }
        } catch {
            // Stop/new Start may run while readiness is waiting. Never close its replacement.
            if generation == owner {
                capturing = false; close(); deactivate(); ownsResources = false
            }
            throw error
        }
    }
    public func stop(close: () -> Void, deactivate: () -> Void) {
        generation += 1
        capturing = false
        if ownsResources { close(); deactivate(); ownsResources = false }
    }
}

public enum NativeAudioEvent { case interruptionBegan, interruptionEnded(resume: Bool), routeChanged, mediaReset }

/// Actual native notification/control handler, shared with headless tests. Desired controls are
/// independent of Controller.Status, which deliberately resets when a run stops.
@MainActor public final class NativeVoiceLifecycle {
    public private(set) var requested = false
    public private(set) var generation = 0
    public private(set) var micMuted = false
    public private(set) var outputMuted = false
    public private(set) var interrupted = false
    public var controller: ConversationController?
    private var recovery: Task<Void, Never>?
    public init() {}
    public func requestStart() -> Int { requested = true; generation += 1; return generation }
    public func isCurrent(_ owner: Int) -> Bool { requested && !interrupted && generation == owner }
    public func invalidate() {
        requested = false; generation += 1; interrupted = false
        recovery?.cancel(); recovery = nil
    }
    /// Production phone inactive/protected-data seam. No credential access or prompt admission here.
    /// Retain typed/held/ASR ownership before disconnect invalidates the backend lease.
    public func suspend(typed: inout String, target: TargetLease?, finalTimeout: TimeInterval = 2,
                        retain: @escaping (BoundDraft) -> Void, disconnect: () -> Void) {
        invalidate()
        controller?.onReviewDraft = retain
        controller?.suspendForReview(finalTimeout: finalTimeout)
        if !typed.isEmpty, let target { retain(BoundDraft(target: target, text: typed)); typed = "" }
        disconnect()
    }
    public func setMicMuted(_ value: Bool) { guard micMuted != value else { return }; micMuted = value; controller?.setMicMuted(value) }
    public func setOutputMuted(_ value: Bool) { outputMuted = value; controller?.setOutputMuted(value) }
    public func start(_ owner: Int) async {
        guard isCurrent(owner), let controller else { return }
        await controller.start(micMuted: micMuted, outputMuted: outputMuted)
    }
    public func handle(_ event: NativeAudioEvent) {
        guard requested else { return }
        switch event {
        case .interruptionBegan:
            guard !interrupted else { return }
            interrupted = true; generation += 1
            recovery?.cancel(); recovery = nil
            controller?.pauseForCall()
        case .interruptionEnded(let resume):
            guard interrupted else { return }
            interrupted = false
            guard resume else { invalidate(); return }
            scheduleResume()
        case .routeChanged, .mediaReset:
            // Ignore notifications while interrupted/starting/stopped, including our own activation.
            guard !interrupted, recovery == nil, controller?.status.phase == "ready",
                  controller?.status.running == true else { return }
            generation += 1
            controller?.pauseForCall()
            scheduleResume()
        }
    }
    private func scheduleResume() {
        guard recovery == nil else { return }
        let owner = generation
        recovery = Task { [weak self] in
            guard let self else { return }
            await self.start(owner)
            if self.generation == owner { self.recovery = nil }
        }
    }
}
