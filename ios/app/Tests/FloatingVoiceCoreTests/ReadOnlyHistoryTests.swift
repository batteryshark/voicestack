import Foundation
import Testing
@testable import FloatingVoiceCore

/// Opt-in read-only installed-backend validation. Never selects/grants a lease, prompts,
/// interrupts, exports text or writes backend state. Real records stay in process memory.
@MainActor struct ReadOnlyHistoryTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FV_READ_ONLY_HISTORY"] == "1"))
    func installedLatestPageAndLazyStoreProjection() async throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let settings = try JSONSerialization.jsonObject(with: Data(contentsOf: home.appendingPathComponent(".config/openchamber/settings.json"))) as! [String: Any]
        let chief = try JSONSerialization.jsonObject(with: Data(contentsOf: home.appendingPathComponent(".chief-of-staff/chief.json"))) as! [String: Any]
        let port = try #require(settings["desktopLocalPort"] as? Int)
        let sid = try #require(chief["session"] as? String)
        guard sid.range(of: "^ses_[A-Za-z0-9]+$", options: .regularExpression) != nil else { throw ClientError("Discovery classification invalid") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8; configuration.timeoutIntervalForResource = 8
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let lease = TargetLease(sessionID: sid, generation: "read-only-local-test")
        let store = ConversationStore(target: lease), snapshot = store.beginHistorySnapshot()
        var cursor: String?, seen = Set<String>(), pages = 0, totalBytes = 0
        let began = Date()
        repeat {
            let query = cursor.map { "limit=40&cursor=\($0)" } ?? "limit=40&order=desc"
            let url = URL(string: "http://127.0.0.1:\(port)/api/session/\(sid)/message?\(query)")!
            let (data, response) = try await session.data(from: url)
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
            totalBytes += data.count; pages += 1
            try store.reconcile(history: data, active: false, for: lease, snapshot: snapshot)
            if pages == 1 {
                let rows = store.records.compactMap(MessageRow.init)
                // Same projector and block parser as native. Numeric evidence only.
                let blocks = rows.flatMap { BlockMarkdown.parse($0.text) }.count
                print("read-only-native latest records=\(store.records.count) rows=\(rows.count) blocks=\(blocks) bytes=\(data.count) elapsedMs=\(Int(Date().timeIntervalSince(began)*1000))")
                #expect(store.records.count <= 40)
            }
            let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            cursor = (obj["cursor"] as? [String: Any])?["next"] as? String
            if let next = cursor {
                guard next.range(of: "^[A-Za-z0-9_-]{1,1024}$", options: .regularExpression) != nil, seen.insert(next).inserted, pages < 100 else { throw ClientError("Cursor classification invalid") }
            }
        } while cursor != nil
        let rows = store.records.compactMap(MessageRow.init)
        let work = rows.flatMap(\.body).filter { $0.label != nil }
        let blocks = work.flatMap { BlockMarkdown.parse($0.markdown) }
        print("read-only-native workItems=\(work.count) toolTextInputs=\(work.filter { !$0.markdown.isEmpty }.count) toolMarkdownBlocks=\(blocks.count) fenced=\(blocks.filter { if case .code = $0 { return true }; if case .markdown = $0 { return true }; return false }.count) commands=\(work.filter { $0.command != nil }.count)")
        #expect(store.records.count > 600)
        print("read-only-native total records=\(store.records.count) pages=\(pages) rows=\(rows.count) tools=\(rows.filter { $0.steps > 0 && $0.text.isEmpty }.count) bytes=\(totalBytes) elapsedMs=\(Int(Date().timeIntervalSince(began)*1000))")
    }
}
