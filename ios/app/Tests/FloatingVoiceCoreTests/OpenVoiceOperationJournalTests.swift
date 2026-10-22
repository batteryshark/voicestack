import Foundation
import XCTest
@testable import FloatingVoiceCore

final class OpenVoiceOperationJournalTests: XCTestCase {
    private func owner() -> OpenVoiceRecipientOwner {
        OpenVoiceRecipientOwner(callID:UUID(),callUUID:UUID(),ownerEpoch:UUID(),targetID:UUID(),bindingRevision:1)
    }
    @MainActor func testAtomicIntentSurvivesRestartWithSameUUIDAndPrivatePermissions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("opencode/fv-operation-journal-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let file = directory.appendingPathComponent("intents.json"), owner = owner()
        let journal = OpenVoiceOperationJournal(file:file)
        let item = try OpenVoiceCanonicalItem(id:"reviewed",text:"Only the reviewed words.")
        let intent = try journal.prepare(owner:owner,kind:.exchange,item:item.json)
        try journal.update(intent.id,state:.dispatching)
        let restored = OpenVoiceOperationJournal(file:file)
        XCTAssertFalse(restored.failed); XCTAssertEqual(restored.records.count,1)
        XCTAssertEqual(restored.records[0].id,intent.id); XCTAssertEqual(restored.records[0].item,item.json)
        XCTAssertEqual(restored.records[0].state,.uncertain)
        XCTAssertThrowsError(try restored.prepare(owner:owner,kind:.exchange,item:item.json))
        XCTAssertNoThrow(try restored.prepare(owner:owner,kind:.deliberateEnd))
        let permissions = try FileManager.default.attributesOfItem(atPath:file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue,0o600)
        let dirPermissions = try FileManager.default.attributesOfItem(atPath:directory.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(dirPermissions?.intValue,0o700)
        let contents = try String(contentsOf:file,encoding:.utf8)
        XCTAssertFalse(contents.contains("Bearer")); XCTAssertFalse(contents.contains("audio"))
    }
    @MainActor func testPersistenceFailureAndCorruptionNeverAuthorizeRetry() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("opencode/fv-operation-corrupt-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:file) }
        let journal = OpenVoiceOperationJournal(file:file,save:{ _ in throw ClientError("fixture storage failure") })
        XCTAssertThrowsError(try journal.prepare(owner:owner(),kind:.deliberateEnd)); XCTAssertTrue(journal.failed)
        XCTAssertThrowsError(try journal.prepare(owner:owner(),kind:.deliberateEnd))
        try Data("not an operation journal".utf8).write(to:file)
        let corrupt = OpenVoiceOperationJournal(file:file)
        XCTAssertTrue(corrupt.failed)
        XCTAssertThrowsError(try corrupt.prepare(owner:owner(),kind:.deliberateEnd))
        XCTAssertEqual(try String(contentsOf:file,encoding:.utf8),"not an operation journal")
    }
}
