import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Local intent/review, not a bridge admission ledger. Never stores PCM or credentials.
public struct OpenVoiceOperationIntent: Codable, Equatable {
    public enum Kind: String, Codable { case exchange, deliberateEnd }
    public enum State: String, Codable { case prepared, dispatching, uncertain, generationEnded, reconciled }
    public let id: UUID, callID: UUID, callUUID: UUID, ownerEpoch: UUID, targetID: UUID
    public let bindingRevision: Int
    public let kind: Kind
    public let item: OpenVoiceJSON?
    public fileprivate(set) var state: State
    public fileprivate(set) var snapshot: OpenVoiceJSON?
}

@MainActor public final class OpenVoiceOperationJournal {
    public private(set) var records: [OpenVoiceOperationIntent] = []
    public private(set) var failed = false
    private let save: (Data) throws -> Void
    public init(file: URL, save: ((Data) throws -> Void)? = nil) {
        self.save = save ?? { data in
            let directory = file.deletingLastPathComponent()
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:directory.path)
            try data.write(to:file,options:.atomic)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
#if os(iOS)
            try FileManager.default.setAttributes([.protectionKey:FileProtectionType.completeUntilFirstUserAuthentication],ofItemAtPath:file.path)
#endif
            let handle = try FileHandle(forWritingTo:file); defer { try? handle.close() }; try handle.synchronize()
#if canImport(Darwin)
            let fd = Darwin.open(directory.path,O_RDONLY | O_DIRECTORY)
            guard fd >= 0 else { throw ClientError("Voice intent storage unavailable") }
            defer { Darwin.close(fd) }
            guard Darwin.fsync(fd) == 0 else { throw ClientError("Voice intent storage unavailable") }
#endif
        }
        guard FileManager.default.fileExists(atPath:file.path) else { return }
        do {
            let handle = try FileHandle(forReadingFrom:file); defer { try? handle.close() }
            let data = try handle.read(upToCount:2_097_153) ?? Data()
            guard data.count <= 2_097_152 else { throw ClientError("Voice intent storage full") }
            records = try JSONDecoder().decode([OpenVoiceOperationIntent].self,from:data)
            guard records.count <= 128, Set(records.map(\.id)).count == records.count else { throw ClientError("Invalid voice intent storage") }
            for index in records.indices {
                let record = records[index]
                guard record.bindingRevision > 0, record.bindingRevision <= 9_007_199_254_740_991,
                      record.callID != record.callUUID, record.callID != record.ownerEpoch, record.callUUID != record.ownerEpoch,
                      (record.kind == .exchange) == (record.item != nil),
                      records.filter({ $0.callID == record.callID && $0.kind == record.kind }).count == 1 else { throw OpenVoiceFailure() }
                if let item = record.item { try OpenVoiceWire.userItem(item) }
                if records[index].state == .dispatching { records[index].state = .uncertain }
            }
            try persist()
        } catch { failed = true }
    }
    private func persist() throws {
        guard !failed else { throw ClientError("Voice intent storage unavailable") }
        do {
            let data = try JSONEncoder().encode(records)
            guard data.count <= 2_097_152 else { throw ClientError("Voice intent storage full") }
            try save(data)
        } catch { failed = true; throw ClientError("Voice intent storage unavailable; review required") }
    }
    public func prepare(owner: OpenVoiceRecipientOwner, kind: OpenVoiceOperationIntent.Kind, item: OpenVoiceJSON? = nil) throws -> OpenVoiceOperationIntent {
        guard !failed, records.count < 128, !records.contains(where:{ $0.callID == owner.callID && $0.kind == kind }) else {
            throw ClientError("Voice operation already planned or storage unavailable; reconcile before sending")
        }
        if kind == .exchange { guard let item else { throw OpenVoiceFailure() }; try OpenVoiceWire.userItem(item) }
        else { guard item == nil else { throw OpenVoiceFailure() } }
        let record = OpenVoiceOperationIntent(id:UUID(),callID:owner.callID,callUUID:owner.callUUID,ownerEpoch:owner.ownerEpoch,targetID:owner.targetID,bindingRevision:owner.bindingRevision,kind:kind,item:item,state:.prepared,snapshot:nil)
        records.append(record); try persist(); return record
    }
    public func update(_ id: UUID, state: OpenVoiceOperationIntent.State, snapshot: OpenVoiceJSON? = nil) throws {
        guard let index = records.firstIndex(where:{ $0.id == id }) else { throw OpenVoiceFailure() }
        records[index].state = state
        if let snapshot { records[index].snapshot = snapshot }
        try persist()
    }
    /// Explicit historical review, including after restart/end. GET only, with the
    /// original persisted call identity; never invents a new operation or re-POSTs it.
    public func reconcile(_ id: UUID, using control: OpenVoiceRecipientControl) async throws -> OpenVoiceJSON {
        guard !failed, let record = records.first(where:{ $0.id == id }) else { throw OpenVoiceFailure("local_failure") }
        let owner = OpenVoiceRecipientOwner(callID:record.callID,callUUID:record.callUUID,ownerEpoch:record.ownerEpoch,targetID:record.targetID,bindingRevision:record.bindingRevision)
        let snapshot = try await control.operation(owner:owner,operationID:record.id)
        guard snapshot["kind"] == .string(record.kind == .exchange ? "exchange" : "end") else { throw OpenVoiceFailure() }
        try update(id,state:.reconciled,snapshot:snapshot); return snapshot
    }
}
