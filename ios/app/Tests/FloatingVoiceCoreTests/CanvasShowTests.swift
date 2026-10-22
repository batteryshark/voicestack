import Foundation
import Testing
#if os(macOS)
import WebKit
#endif
@testable import FloatingVoiceCore

@Suite struct CanvasShowTests {
    @Test func showIsASeparateCanvasReferenceNotADocument() throws {
        let row = try #require(MessageRow(Data(#"{"id":"msg_fixture","type":"assistant","content":[{"type":"tool","name":"canvas_show","executed":false,"state":{"status":"completed","input":{"format":"html","source":"<h1>Fixture</h1>"},"metadata":{"viewId":"11111111-1111-4111-8111-111111111111","revision":1},"content":[{"type":"text","text":"Do not display tool-result prose"}]}}]}"#.utf8)))
        #expect(row.body.count == 1)
        #expect(row.body.first?.reference?.kind == "canvas")
        #expect(row.body.first?.reference?.format == "canvas_show")
        #expect(row.body.first?.markdown == "Canvas panel")
    }
    @Test func canvasLinksAreNotWebDestinations() throws {
        for url in ["https://canvas.fixture.invalid/#key=[redacted]&view=111", "https://canvas.fixture.invalid/?key=fake", "https://canvas.fixture.invalid/#view=111", "https://canvas.fixture.ts.net/", "https://opaque.fixture.invalid/#%6bey=fake", "https://canvas.fixture.invalid:9444/no-key"] {
            #expect(!LinkPolicy().web(try #require(URL(string: url))))
        }
    }
    @Test func webPolicyIsScriptEnabledNonpersistentAndNetworkDenied() throws {
        #expect(!CanvasWebPolicy.persistent && CanvasWebPolicy.scripts)
        let rules = try #require(JSONSerialization.jsonObject(with: Data(CanvasWebPolicy.networkRules.utf8)) as? [[String: Any]])
        #expect(rules.compactMap { ($0["trigger"] as? [String: String])?["url-filter"] } == ["^https?://", "^wss?://"])
        #expect((rules[0]["action"] as? [String: String])?["type"] == "block")
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let native = try String(contentsOf: root.appendingPathComponent("native/CanvasShowView.swift"))
        #expect(native.contains("websiteDataStore = .nonPersistent()"))
        #expect(native.contains("allowsContentJavaScript = true"))
        #expect(native.contains("encodedContentRuleList: CanvasWebPolicy.networkRules"))
        #expect(native.contains("guard let list else { return }"))
        #expect(native.contains("message.frameInfo.isMainFrame"))
        #expect(native.contains("decidePolicyFor response: WKNavigationResponse"))
        #expect(!native.contains("max(240, value)"))
        #expect(!native.contains("URLRequest("))
    }
    @Test func reviewRegressionRejectionsStalenessAndTitlePolishAreExplicit() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let native = try String(contentsOf: root.appendingPathComponent("native/CanvasShowPanel.swift"))
        #expect(native.contains("CanvasSubmissionPolicy.failure"))
        #expect(native.contains("case .invalid"))
        #expect(native.contains("case .stale"))
        let invalid = try #require(native.components(separatedBy: "case .invalid:").last?.components(separatedBy: "case .stale:").first)
        #expect(invalid.contains("submitted = nil; delivery = nil"))
        #expect(!invalid.contains("submissionID ="))
        let stale = try #require(native.components(separatedBy: "case .stale:").last?.components(separatedBy: "case .unknown:").first)
        #expect(stale.contains("submitted = nil; delivery = nil; stale = true"))
        #expect(!stale.contains("submissionID ="))
        #expect(native.contains("Reload latest revision"))
        #expect(!native.contains("Label(title,"))
        #expect(native.contains("loadOwner == owner"))
        #expect(native.contains("self.panelID == panelID"))
        #expect(native.contains("panelID == expectedPanelID"))
    }
    @Test func definiteRejectionsDoNotLockInputButLostOrAdmittedRepliesDo() {
        #expect(CanvasSubmissionPolicy.failure(status: 400, admitted: false) == .invalid)
        #expect(CanvasSubmissionPolicy.failure(status: 413, admitted: false) == .invalid)
        #expect(CanvasSubmissionPolicy.failure(status: 409, admitted: false) == .stale)
        #expect(CanvasSubmissionPolicy.failure(status: nil, admitted: false) == .unknown)
        #expect(CanvasSubmissionPolicy.failure(status: 503, admitted: false) == .unknown)
        for code in [400, 413, 409] { #expect(CanvasSubmissionPolicy.failure(status: code, admitted: true) == .unknown) }
    }
#if os(macOS)
    @MainActor @Test func webKitCompilesCanvasNetworkDenyRules() async {
        let success = await withCheckedContinuation { continuation in
            WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "canvas24-test-" + UUID().uuidString, encodedContentRuleList: CanvasWebPolicy.networkRules) { list, error in continuation.resume(returning: list != nil && error == nil) }
        }
        #expect(success)
    }
#endif
    @Test func mainLogKeepsToolOnlyPanelsAndGroupedMessageAssociations() throws {
        func record(_ id: String, _ text: String) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["id": id, "type": "assistant", "content": [["type": "text", "text": text], ["type": "tool", "name": "canvas_show"]]])
        }
        var log = ConversationVoiceLog()
        log.update(records: try [record("msg_a", "First"), record("msg_b", "")])
        #expect(log.turns.count == 1)
        #expect(log.turns.first?.panelMessageIDs == ["msg_a", "msg_b"])
        #expect(log.turns.first?.spoken == "First")
    }
}
