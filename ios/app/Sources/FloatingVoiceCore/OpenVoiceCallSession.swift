import Foundation

/// Explicit-answer assembly only. No capture, selected-thread access or ambient
/// caller grants. Every suspension is fenced to the original CallKit owner.
@MainActor public enum OpenVoiceCallSession {
    public static func accept(record: Data, push: PushInvitation, lifecycle: CallLifecycle,
                              control: OpenVoiceRecipientControl, journal: OpenVoiceOperationJournal,
                              allowed: () -> Bool) async throws -> OpenVoiceBackend {
        let owner = try IncomingCallOwner(lifecycle:lifecycle,invitation:push)
        guard allowed() else { throw ClientError("New conversation calls are disabled") }
        let resolved = try control.authenticatedInvitation(record,push:push)
        let current = try await control.invitation(callID:resolved.owner.callID)
        try owner.validate(lifecycle)
        guard allowed(), current.json == resolved.json else { throw ClientError("Invitation changed") }
        let accepted = try await control.accept(current)
        try owner.validate(lifecycle)
        guard allowed() else { throw ClientError("New conversation calls are disabled") }
        let lease = try await control.mediaLease(accepted)
        try owner.validate(lifecycle)
        guard allowed() else { throw ClientError("New conversation calls are disabled") }
        let socket = try OpenVoiceURLSessionSocket(origin:control.origin,lease:lease)
        let pump = try OpenVoiceMediaOwnerPump(socket:socket,lease:lease,localCallEpoch:UUID())
        return try OpenVoiceBackend(pump:pump,invitation:accepted,control:control,journal:journal)
    }
}
