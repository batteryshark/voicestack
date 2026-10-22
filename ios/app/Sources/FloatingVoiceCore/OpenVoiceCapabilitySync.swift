import Foundation

/// Latest desired capability, not a mutation retry queue. One worker observes edits
/// after each upload and sends only a DIFFERENT latest desired value. Foreground
/// refresh is explicit; a failed upload never schedules its own retry.
@MainActor public final class OpenVoiceCapabilitySync {
    public struct State: Equatable {
        public var desiredEnabled: Bool
        /// Persisted BEFORE any enable may escape, cleared only by acknowledged false.
        public var mayBeEnabled: Bool
        /// Pending/uncertain true is not automatically re-enabled on foreground/restart.
        public var enableNeedsExplicitChoice: Bool
        public init(desiredEnabled: Bool, mayBeEnabled: Bool, enableNeedsExplicitChoice: Bool = false) {
            self.desiredEnabled = desiredEnabled; self.mayBeEnabled = mayBeEnabled
            self.enableNeedsExplicitChoice = enableNeedsExplicitChoice
        }
    }
    public private(set) var state: State
    public private(set) var expiresAt: Date = .distantPast
    public var running: Bool { worker != nil }
    private var worker: Task<Void,Never>?
    private var uploadingEnabled: Bool?
    private let persist: (State) throws -> Void
    private let upload: (Bool) async throws -> Date
    public init(state: State, persist: @escaping (State) throws -> Void, upload: @escaping (Bool) async throws -> Date) {
        self.state = state; self.persist = persist; self.upload = upload
    }
    public func setDesired(_ enabled: Bool) {
        state.desiredEnabled = enabled
        // An edit cannot erase the durable uncertainty of a true already in flight.
        if uploadingEnabled != true { state.enableNeedsExplicitChoice = false }
        expiresAt = .distantPast
        // Keep local opt-out immediate even if storage/network is unavailable.
        try? persist(state)
    }
    public func refresh() {
        guard worker == nil, state.desiredEnabled || state.mayBeEnabled else { return }
        guard !state.desiredEnabled || !state.enableNeedsExplicitChoice else { return }
        worker = Task { [weak self] in
            guard let self else { return }; defer { self.worker = nil }
            while !Task.isCancelled {
                let enabled = self.state.desiredEnabled
                guard enabled || self.state.mayBeEnabled else { return } // superseded before any enable escaped
                if enabled {
                    self.state.mayBeEnabled = true
                    self.state.enableNeedsExplicitChoice = true
                    do { try self.persist(self.state) }
                    catch { self.expiresAt = .distantPast; return } // No undurable enable.
                }
                self.uploadingEnabled = enabled
                do {
                    let expiry = try await self.upload(enabled)
                    var acknowledged = self.state; acknowledged.enableNeedsExplicitChoice = false
                    if !enabled {
                        acknowledged.mayBeEnabled = false
                    }
                    // A failed durable clear stays conservatively maybe-effective.
                    do { try self.persist(acknowledged); self.state = acknowledged } catch {}
                    self.expiresAt = enabled && self.state.desiredEnabled ? expiry : .distantPast
                } catch {
                    self.expiresAt = .distantPast
                    if enabled { self.state.enableNeedsExplicitChoice = true; try? self.persist(self.state) }
                }
                self.uploadingEnabled = nil
                // Edits during either success OR uncertainty must not forget false.
                // No same-value dirty flag, spin, parallel mutation or automatic retry.
                if self.state.desiredEnabled == enabled { return }
            }
        }
    }
}
