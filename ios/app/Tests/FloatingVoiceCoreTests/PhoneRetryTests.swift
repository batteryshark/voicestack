import Foundation
import Testing
@testable import FloatingVoiceCore

private final class FakeSecureItem: SecureItemAdapter {
    var status: Int32 = 0
    var bytes: Data? = Data("existing".utf8)
    var writeStatus: Int32 = 0
    var corruptWrite = false
    var reads = 0, writes = 0, deletes = 0
    var migrationStatus: Int32 = 0
    var migrations = 0
    func migrateAccessibility() -> Int32 { migrations += 1; return migrationStatus }
    func read() -> (Int32, Data?) { reads += 1; return (status, bytes) }
    func update(_ data: Data) -> Int32 {
        writes += 1
        if writeStatus == 0 { status = 0; bytes = corruptWrite ? nil : data }
        return writeStatus
    }
    func add(_ data: Data) -> Int32 { update(data) }
    func delete() -> Int32 { deletes += 1; bytes = nil; return 0 }
}

struct PhoneRetryTests {
    @Test func backgroundReadReturnsRealSecItemStatusWithoutSyntheticGateOrMutation() throws {
        let adapter = FakeSecureItem()
        let store = PreservingCredentialStore(adapter: adapter, available: { false })
        #expect(try store.load() == "existing")
        adapter.status = -25308
        do { _ = try store.load(); Issue.record("expected real SecItem failure") }
        catch let error as CredentialFailure { #expect(!error.syntheticGate && error.status == -25308) }
        for operation in [{ try store.save("replacement") }, { try store.clear() }, { try store.authorizePairing() }] {
            do { try operation(); Issue.record("expected foreground-only gate") }
            catch let error as CredentialFailure { #expect(error.syntheticGate) }
        }
        #expect(adapter.reads == 2 && adapter.writes == 0 && adapter.deletes == 0 && adapter.migrations == 0)
    }
    @Test func accessibilityMigrationAndOneDeferredRetryPreserveCurrentItem() throws {
        let adapter = FakeSecureItem()
        let original = adapter.bytes
        let actual = PreservingCredentialStore(adapter: adapter)
        adapter.status = -25308
        #expect(throws: CredentialFailure.self) { try actual.load() }
        #expect(adapter.migrations == 0 && adapter.deletes == 0)
        adapter.status = 0; adapter.migrationStatus = -25308
        #expect(try actual.load() == "existing") // maintenance cannot veto a real read
        #expect(adapter.bytes == original && adapter.writes == 0 && adapter.deletes == 0)
        adapter.migrationStatus = 0
        #expect(try actual.load() == "existing")
        #expect(adapter.bytes == original && adapter.deletes == 0)
        let gate = CredentialRecoveryGate()
        gate.failed(status: -25308)
        #expect(!gate.permit(available: false))
        #expect(gate.permit(available: true))
        gate.failed(status: -25308)
        #expect(!gate.permit(available: true))
        gate.succeeded(); #expect(gate.permit(available: true))
    }
    @Test func routineReadSuccessCannotEvictOneShotStartAndFailure() {
        let log = StageDiagnostics()
        log.record(.startUI, .begin); log.record(.credentialRead, .failed, status: -25308)
        for _ in 0..<400 { log.record(.state, .complete, status: 200) }
        #expect(log.export().contains("startUI") && log.export().contains("-25308"))
    }
    @Test(arguments: [Int32(-25308), -25291, -34018]) func statusErrorsPreserveIdentity(_ status: Int32) throws {
        let adapter = FakeSecureItem(); adapter.status = status
        let store = PreservingCredentialStore(adapter: adapter)
        #expect(throws: CredentialFailure.self) { try store.load() }
        #expect(throws: CredentialFailure.self) { try store.save("replacement") }
        #expect(adapter.bytes == Data("existing".utf8))
        #expect(adapter.writes == 0 && adapter.deletes == 0)
    }
    @Test func missingMalformedAndReadbackAreDistinct() throws {
        let adapter = FakeSecureItem()
        let actual = PreservingCredentialStore(adapter: adapter)
        adapter.status = -25300; adapter.bytes = nil
        #expect(try actual.load() == nil)
        try actual.save("new")
        #expect(try actual.load() == "new")
        adapter.bytes = Data([0xff]); adapter.status = 0
        #expect(throws: CredentialFailure.self) { try actual.load() }
        adapter.bytes = nil
        #expect(throws: CredentialFailure.self) { try actual.load() }
        adapter.bytes = Data("old".utf8); adapter.corruptWrite = true
        #expect(throws: CredentialFailure.self) { try actual.save("new") }
        #expect(adapter.deletes == 0)
    }
    @Test func failedWriteAndProtectedDataRelaunch() throws {
        let adapter = FakeSecureItem(); adapter.writeStatus = -25291
        var unlocked = false
        let store = PreservingCredentialStore(adapter: adapter, available: { unlocked })
        #expect(try store.load() == "existing")
        #expect(adapter.reads == 1 && adapter.migrations == 0)
        do { try store.save("new"); Issue.record("background write admitted") }
        catch let error as CredentialFailure { #expect(error.syntheticGate) }
        unlocked = true
        #expect(throws: CredentialFailure.self) { try store.save("new") }
        #expect(try PreservingCredentialStore(adapter: adapter).load() == "existing")
        #expect(adapter.deletes == 0)
    }
    @Test func rolesToolsAndStructuralRecords() throws {
        func row(_ obj: [String: Any]) throws -> MessageRow? { MessageRow(try JSONSerialization.data(withJSONObject: obj)) }
        #expect(try row(["id":"idle", "type":"idle"]) == nil)
        let candidate = try row(["id":"work", "type":"assistant", "content":[["type":"tool", "state":["content":[]]], ["type":"tool"]]])
        let tools = try #require(candidate)
        #expect(tools.role == "Chief" && tools.steps == 2 && tools.text.isEmpty)
        #expect(!tools.detail.isEmpty)
        #expect(try row(["id":"error", "type":"error"])?.role == "Error")
        #expect(try row(["id":"future", "type":"new"])?.role == "Other record")
    }
    @Test func markdownDetailsCodeTablesAndFallback() {
        let blocks = BlockMarkdown.parse("# Title\n- list\n> quote\n[link](https://example.test)\n| A | B |\n| --- | --- |\n| x\\|y | `a|b` |\n```md\n**Details**\n```\n```swift\nprint(1)\n```")
        #expect(blocks.contains(.heading(1, "Title")))
        #expect(blocks.contains(.list("- list")))
        #expect(blocks.contains(.quote("quote")))
        #expect(blocks.contains(.table([["A", "B"], ["x|y", "`a|b`"]])))
        #expect(blocks.contains(.markdown("**Details**")))
        #expect(blocks.contains(.code("swift", "print(1)")))
        #expect(BlockMarkdown.parse("| incomplete |").count == 1)
    }
    @Test func bottomFollowAndCompactSearch() {
        var follow = BottomFollow()
        #expect(follow.following)
        follow.userScrolled(bottomVisible: false); #expect(!follow.following)
        follow.userScrolled(bottomVisible: true); #expect(follow.following)
        let sessions = [SessionSummary(id: "ses_A", title: "Chief", updated: 1, parentID: nil), SessionSummary(id: "ses_B", title: "Other", updated: 2, parentID: nil)]
        #expect(CompactPicker.sessions(sessions, search: "chief").map(\.id) == ["ses_A"])
    }
    @Test func diagnosticSchemaCannotContainSecrets() {
        let log = StageDiagnostics(); log.availability(false)
        log.record(.credential, .failed, status: -25308)
        let value = log.export()
        #expect(value.contains("-25308") && value.contains("protectedData"))
        #expect(!value.contains("Authorization") && !value.contains("http"))
    }
}
