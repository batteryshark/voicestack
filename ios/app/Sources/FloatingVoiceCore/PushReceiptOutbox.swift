import Foundation

/// Identifiers and closed codes only. No credentials, tokens, audio or message text.
public struct PendingPushReceipt: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let reachoutID: String
    public let callUUID: String?
    public let receipt: CallReceipt
    public let createdAt: Date
    public init(reachoutID: String, call: UUID?, receipt: CallReceipt, now: Date = Date()) {
        id = UUID(); self.reachoutID = reachoutID; callUUID = call?.uuidString.lowercased()
        self.receipt = receipt; createdAt = now
    }
    public var terminal: Bool { [.ended, .declined, .reportFailed].contains(receipt.event) }
    public func body() throws -> [String: Any] {
        var value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(receipt)) as! [String: Any]
        value["reachoutID"] = reachoutID
        if let callUUID { value["callUUID"] = callUUID }
        return value
    }
}

/// Durable-before-dispatch; removal is durable only AFTER the server acknowledges.
/// Replaying a receipt is idempotent and can never dispatch another call.
@MainActor public final class PushReceiptOutbox {
    public private(set) var entries: [PendingPushReceipt] = []
    public private(set) var loadFailed = false
    private let file: URL
    private let save: (Data) throws -> Void
    public init(file: URL, now: Date = Date(), save: ((Data) throws -> Void)? = nil) {
        self.file = file
        self.save = save ?? { bytes in
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try bytes.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
#if os(iOS)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: file.path)
#endif
        }
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            let bytes = try Data(contentsOf: file)
            guard bytes.count <= 131072 else { throw ClientError("Receipt storage limit") }
            let decoded = try JSONDecoder().decode([PendingPushReceipt].self, from: bytes)
            guard decoded.count <= 64, decoded.allSatisfy({ PushInvitation.validID($0.reachoutID) && ($0.callUUID == nil || UUID(uuidString: $0.callUUID!) != nil) }) else { throw ClientError("Invalid receipt storage") }
            entries = decoded.filter { now.timeIntervalSince($0.createdAt) < 86400 && now.timeIntervalSince($0.createdAt) >= 0 }
        } catch { loadFailed = true }
    }
    public func enqueue(_ entry: PendingPushReceipt) throws {
        guard PushInvitation.validID(entry.reachoutID) else { throw ClientError("Invalid receipt identity") }
        if entries.contains(where: { $0.reachoutID == entry.reachoutID && $0.callUUID == entry.callUUID && $0.receipt == entry.receipt }) { return }
        if entry.terminal {
            // Terminal truth takes precedence over obsolete, unacknowledged progress.
            entries.removeAll { $0.reachoutID == entry.reachoutID && $0.callUUID == entry.callUUID && !$0.terminal }
        }
        if entries.count >= 64, entry.terminal, let index = entries.firstIndex(where: { !$0.terminal }) { entries.remove(at:index) }
        guard entries.count < 64 else { throw ClientError("Receipt queue full") }
        entries.append(entry)
        try save(JSONEncoder().encode(entries)) // A failed disk write still leaves the in-memory terminal item for delivery.
    }
    public func acknowledge(_ id: UUID) throws {
        let remaining = entries.filter { $0.id != id }
        try save(JSONEncoder().encode(remaining))
        entries = remaining
    }
}
