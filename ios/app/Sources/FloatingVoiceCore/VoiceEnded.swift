import Foundation

public enum VoiceEndedNote {
    public static let text = "[voice] ended"
    public static let label = "Voicestack"
    public static let displayText = "Voice ended"
}

public enum VoiceEndedKind: String, Codable, Sendable { case call, app }
public enum VoiceEndedOutcome: String, Codable, Sendable { case posted, skippedStaleLease, failed }
public struct VoiceEndedDiagnostic: Codable, Sendable {
    public let kind: VoiceEndedKind
    public let outcome: VoiceEndedOutcome
}

/// Coalesces one bounded scene reconciliation behind an already handed-off
/// admission. It never cancels that admission and never replays a captured
/// background decision. Resume/Start/selection invalidate the observer's owner.
@MainActor public final class VoiceEndedSceneDeferral {
    private var generation = 0
    private var key: UUID?
    private var waiter: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    public init() {}
    public func invalidate() {
        generation += 1; key = nil
        waiter?.cancel(); waiter = nil
        deadline?.cancel(); deadline = nil
    }
    public func sceneResumed(foreground: Bool, protectedDataAvailable: Bool) {
        // Unlock while inactive is not a foreground owner of scene cleanup.
        if foreground && protectedDataAvailable { invalidate() }
    }
    public func reconcileAfter(_ admission: Task<Void, Never>, key: UUID,
                               maximumDelay: UInt64 = 2_000_000_000,
                               reconcileCurrent: @escaping @MainActor () -> Void) {
        guard self.key != key else { return } // Repeated inactive notifications coalesce.
        invalidate()
        self.key = key
        let owner = generation
        waiter = Task { [weak self] in
            await admission.value
            self?.finish(key: key, owner: owner, reconcileCurrent: reconcileCurrent)
        }
        deadline = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: maximumDelay) } catch { return }
            self?.finish(key: key, owner: owner, reconcileCurrent: reconcileCurrent)
        }
    }
    private func finish(key: UUID, owner: Int, reconcileCurrent: () -> Void) {
        guard self.key == key, generation == owner else { return }
        invalidate() // Fence the other completion BEFORE any reentrant scene callback.
        reconcileCurrent()
    }
}

/// One actual voice session, not a capture graph/recognizer/recovery generation.
/// Never persisted: relaunch cannot reconstruct authority to admit an end note.
@MainActor public final class VoiceEndedSession {
    public static let text = VoiceEndedNote.text
    public let generation = UUID()
    public let kind: VoiceEndedKind
    public let target: TargetLease
    public let callEpoch: Int?
    private var valid = true
    private var consumed = false
    public init(kind: VoiceEndedKind, target: TargetLease, callEpoch: Int? = nil) {
        self.kind = kind; self.target = target; self.callEpoch = callEpoch
    }
    /// Failure/selection is irreversible even if a caller later restores the same lease.
    public func invalidate() { valid = false }
    public func end(currentLease: @MainActor () -> TargetLease?,
                    admit: @MainActor (TargetLease, String) async throws -> Void,
                    diagnostic: (VoiceEndedDiagnostic) -> Void = { StageDiagnostics.shared.record(.voiceEnded, $0.outcome == .failed ? .failed : .complete, voiceEnded: $0) }) async {
        guard !consumed else { return }
        consumed = true // Fence duplicate End/reentrant provider callbacks BEFORE suspension.
        guard valid, currentLease() == target else {
            diagnostic(.init(kind: kind, outcome: .skippedStaleLease)); return
        }
        do {
            // Admission handoff: a later change cannot undo this one attempt.
            try await admit(target, Self.text)
            diagnostic(.init(kind: kind, outcome: .posted))
        } catch { diagnostic(.init(kind: kind, outcome: .failed)) }
    }
}
