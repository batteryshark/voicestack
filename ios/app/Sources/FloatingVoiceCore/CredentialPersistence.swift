import Foundation

/// Adapter returns only status and bytes. Production binds these operations to SecItem,
/// tests exercise identical persistence policy without accessing a real Keychain.
public protocol SecureItemAdapter: AnyObject {
    func read() -> (Int32, Data?)
    func update(_ data: Data) -> Int32
    func add(_ data: Data) -> Int32
    func delete() -> Int32
    func migrateAccessibility() -> Int32
}
public extension SecureItemAdapter { func migrateAccessibility() -> Int32 { 0 } }

public struct CredentialFailure: LocalizedError {
    public let operation: String
    public let status: Int32
    public let malformed: Bool
    public var syntheticGate = false
    public var errorDescription: String? {
        if malformed { return "Credential \(operation): malformed item (status \(status)); preserved. Contact support; do not re-pair." }
        return "Credential \(operation) \(syntheticGate ? "policy gate" : "SecItem") failed (status \(status)); preserved. " +
            ([-25308, -25291].contains(status) ? "Unlock the phone and reconnect." : "Open diagnostics; do not reset or re-pair.")
    }
}

public final class PreservingCredentialStore: DeviceCredentialStore {
    private let adapter: SecureItemAdapter
    /// Mutation/pairing policy only. Reads deliberately have no synthetic gate.
    public var available: () -> Bool
    public init(adapter: SecureItemAdapter, available: @escaping () -> Bool = { true }) {
        self.adapter = adapter; self.available = available
    }
    private func check(_ operation: String) throws {
        guard available() else { throw CredentialFailure(operation: operation, status: -25308, malformed: false, syntheticGate: true) }
    }
    public func load() throws -> String? {
        // AfterFirstUnlock reads must consult SecItem even while locked/backgrounded.
        let (status, bytes) = adapter.read()
        if status == -25300 { return nil }
        guard status == 0 else { throw CredentialFailure(operation: "read", status: status, malformed: false) }
        guard let bytes, let value = String(data: bytes, encoding: .utf8), !value.isEmpty else {
            throw CredentialFailure(operation: "read", status: status, malformed: true)
        }
        // Attribute-only maintenance is best effort and foreground-only. A failed
        // migration must not hide a successfully read, already-paired bearer.
        if available() { _ = adapter.migrateAccessibility() }
        return value
    }
    public func authorizePairing() throws { try check("pair") }
    public func save(_ credential: String) throws {
        try check("write")
        guard !credential.isEmpty else { throw CredentialFailure(operation: "write", status: 0, malformed: true) }
        // A transient read must never lead to replacement or deletion.
        let existing = try load()
        if existing == credential { return }
        let bytes = Data(credential.utf8)
        var status = existing == nil ? adapter.add(bytes) : adapter.update(bytes)
        // Another owner may have inserted between lookup and add. Update, never delete.
        if status == -25299 { status = adapter.update(bytes) }
        guard status == 0 else { throw CredentialFailure(operation: "write", status: status, malformed: false) }
        guard try load() == credential else { throw CredentialFailure(operation: "readback", status: 0, malformed: true) }
    }
    public func clear() throws {
        try check("delete")
        let status = adapter.delete()
        guard status == 0 || status == -25300 else { throw CredentialFailure(operation: "delete", status: status, malformed: false) }
    }
}

/// One deferred retry on a later valid foreground/unlock callback, never a busy retry loop.
public final class CredentialRecoveryGate {
    public private(set) var blocked = false
    private var retried = false
    public init() {}
    public func failed(status: Int) { if status == -25308 { blocked = true } }
    public func permit(available: Bool) -> Bool {
        guard available else { return false }
        guard blocked else { return true }
        guard !retried else { return false }
        retried = true; blocked = false; return true
    }
    public func succeeded() { blocked = false; retried = false }
}
