import Foundation
import Testing
@testable import FloatingVoiceCore

@Suite @MainActor struct MessageSenderTests {
    func record(_ id: String, _ text: String, sender: [String: String]? = nil, display: String? = nil) throws -> Data {
        var obj: [String: Any] = ["id": id, "type": "user", "text": text]
        obj["sender"] = sender; obj["displayText"] = display
        return try JSONSerialization.data(withJSONObject: obj)
    }
    @Test func sharedFixtureProjectionRendersBothHistoryAndLog() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("shared/sender-fixtures.json"))
        let fixtures = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        for (i, f) in fixtures.enumerated() {
            let raw = try record("msg_\(i)", f["text"] as! String, sender: ["kind": f["kind"] as! String, "label": f["label"] as! String], display: f["displayText"] as? String)
            let row = try #require(MessageRow(raw))
            #expect(row.displayLabel == f["label"] as? String)
            #expect(row.text == f["displayText"] as? String)
            #expect(row.body.first?.markdown == row.text)
            #expect(row.detail.contains("text"))
            var log = ConversationVoiceLog(); log.update(records: [raw])
            #expect(log.turns.first?.displayLabel == row.displayLabel)
            #expect(log.turns.first?.spoken == row.text)
            #expect(row.accessibilityLabel == (row.isPrincipal ? "You" : "From " + row.displayLabel))
        }
    }
    @Test func onlyExactClientReceiptIsYouAndLocalQuoteRetainsPrefix() throws {
        let local = try record("msg_local", "[chief]\nMy quote.", sender: ["kind": "chief", "label": "Chief"], display: "My quote.")
        let external = try record("msg_external", "[chief]\nMy quote.", sender: ["kind": "chief", "label": "Chief"], display: "My quote.")
        var receipts = LocalSenderReceipts()
        receipts.record(Data(#"{"data":{"id":"msg_local"}}"#.utf8), sessionID: "ses_one")
        let rows = receipts.project([local, external], sessionID: "ses_one").compactMap(MessageRow.init)
        #expect(rows[0].isPrincipal && rows[0].text == "[chief]\nMy quote.")
        #expect(!rows[1].isPrincipal && rows[1].displayLabel == "Chief")
        #expect(MessageRow(receipts.project([local], sessionID: "ses_two")[0])?.isPrincipal == false)
    }
    @Test func unknownAndInvalidSenderAreMessageNeverYou() throws {
        let raw = try record("msg_unknown", "Ordinary external text")
        #expect(MessageRow(raw)?.displayLabel == MessageSender.unknownLabel)
        #expect(MessageRow(raw)?.isPrincipal == false)
        #expect(MessageSender(projected: ["kind": "madeup", "label": "You"]) == .unknown)
        #expect(MessageSender(projected: ["kind": "lead", "label": "Bad\nLabel"]) == .unknown)
        #expect(MessageRow(try record("msg_blank", "Never hide this body", sender: ["kind":"system", "label":"Message"], display: "  "))?.text == "Never hide this body")
    }
    @Test func syntheticRepliesAppearInBothViewsButNeverAsPrincipal() throws {
        let raw = try JSONSerialization.data(withJSONObject: ["id":"msg_reply", "type":"synthetic", "text":"Original envelope", "displayText":"Reply body.", "sender":["kind":"agent", "label":"Agent · Dream Studio"]])
        let row = try #require(MessageRow(raw)); var log = ConversationVoiceLog(); log.update(records: [raw])
        #expect(row.displayLabel == "Agent · Dream Studio" && !row.isPrincipal && row.text == "Reply body.")
        #expect(log.turns.first?.displayLabel == row.displayLabel && log.turns.first?.spoken == row.text)
    }
    @Test func externalUpdateDoesNotReplaceOrAcknowledgePrincipalActiveCaption() throws {
        let surface = VoiceSurface(); let owner = surface.replaceBinding(target: .init(sessionID: "ses_one", generation: "g"))
        surface.handle(.youStarted, owner: owner); surface.handle(.youLive("My active words"), owner: owner)
        let external = try record("msg_other", "My active words", sender: ["kind": "lead", "label": "Lead · Dream Studio"])
        surface.update(records: [external], connection: "connected", active: true)
        #expect(surface.userCaption == "My active words")
        #expect(surface.log.turns.count == 2)
        #expect(surface.log.turns.first?.displayLabel == "Lead · Dream Studio")
        #expect(surface.log.turns.last?.displayLabel == "You" && surface.log.turns.last?.pending == true)
        surface.handle(.posted("My active words"), owner: owner)
        surface.update(records: [external], connection: "connected", active: false)
        #expect(surface.log.turns.count == 2) // Text equality is NOT an acknowledgement.
    }
    @Test func differentSendersNeverCoalesceAndUserHeadersNeverBecomeSpeech() throws {
        let target = TargetLease(sessionID: "ses_one", generation: "g")
        let records = [try record("msg_1", "Principal", sender: ["kind": "principal", "label": "You"]),
                       try record("msg_2", "[Docket]\nReminder", sender: ["kind": "docket", "label": "Docket"], display: "Reminder"),
                       try record("msg_3", "Choice", sender: ["kind": "canvas", "label": "Agent Canvas"])]
        var log = ConversationVoiceLog(); log.update(records: records)
        #expect(log.turns.map(\.displayLabel) == ["You", "Docket", "Agent Canvas"])
        let store = ConversationStore(target: target)
        let objects = try records.map { try JSONSerialization.jsonObject(with: $0) }
        #expect(try store.reconcile(history: JSONSerialization.data(withJSONObject: ["data": objects]), active: false, for: target).isEmpty)
        let assistant = Data(#"{"id":"msg_a","type":"assistant","content":[{"type":"text","text":"Reply"}]}"#.utf8)
        #expect(MessageRow(assistant)?.displayLabel == "Agent")
    }
}
