import Foundation
import Testing
@testable import FloatingVoiceCore

@Suite @MainActor struct ReplyParagraphTests {
    @Test func separateTextPartsStaySeparateInHistoryAndLiveLog() throws {
        let raw = try JSONSerialization.data(withJSONObject: ["id":"a", "type":"assistant", "content":[
            ["type":"text", "text":"Ready when you are"],
            ["type":"text", "text":"The iPhone update is ready to review."]]])
        let expected = "Ready when you are\n\nThe iPhone update is ready to review."
        let row = try #require(MessageRow(raw))
        #expect(row.text == expected)
        #expect(row.body.count == 1 && row.body[0].markdown == expected)
        #expect(row.body[0].blocks == [.paragraph("Ready when you are"), .paragraph("The iPhone update is ready to review.")])
        var log = ConversationVoiceLog(); log.update(records: [raw])
        #expect(log.turns.last?.spoken == expected)
        var live = ConversationVoiceLog(); live.setVoice(running: true, muted: false); live.update(records: [raw])
        live.handle(.chiefQueued(label: "a:0", text: "Ready when you are"), userText: "")
        live.handle(.chiefStarted(label: "a:0", text: "Ready when you are"), userText: "")
        #expect(live.turns.last?.spoken == "Ready when you are")
        live.handle(.chiefQueued(label: "a:1", text: "The iPhone update is ready to review."), userText: "")
        live.handle(.chiefStarted(label: "a:1", text: "The iPhone update is ready to review."), userText: "")
        #expect(live.turns.last?.spoken == expected)
    }
    @Test func headingParagraphBoundarySurvivesSpeechCleaningForDisplay() {
        let content = ChiefReplyContent("## Ready when you are\nThe iPhone update is ready to review.")
        #expect(content.spoken == "Ready when you are\n\nThe iPhone update is ready to review.")
        #expect(content.displayPrefix(for: "Ready when you are The iPhone update is ready to review.") == content.spoken)
    }
    @Test func joiningTextDoesNotRebindAnImageReference() throws {
        let raw = try JSONSerialization.data(withJSONObject: ["id":"a", "type":"assistant", "content":[
            ["type":"text", "text":"First paragraph"], ["type":"text", "text":"Second paragraph"],
            ["type":"text", "text":"![Diagram](asset.png)"]]])
        let row = try #require(MessageRow(raw))
        #expect(row.body[0].markdown == "First paragraph\n\nSecond paragraph")
        #expect(row.body.last?.reference?.blockOrdinal == 2)
    }
}
