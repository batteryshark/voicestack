import Foundation
import Testing
@testable import FloatingVoiceCore

@Suite @MainActor struct ConversationVoiceLogTests {
    func user(_ id: String, _ text: String) throws -> Data { try JSONSerialization.data(withJSONObject: ["id":id, "type":"user", "text":text, "sender":["kind":"principal", "label":"You"]]) }
    func chief(_ id: String, _ text: String) throws -> Data { try JSONSerialization.data(withJSONObject: ["id":id, "type":"assistant", "content":[["type":"text", "text":text]]]) }
    @Test func historicalConversationAlternatesAndNoToolsOrBlankChiefBubblesAppear() throws {
        var log = ConversationVoiceLog()
        let tool = try JSONSerialization.data(withJSONObject: ["id":"tool", "type":"assistant", "content":[["type":"tool", "name":"read", "state":["status":"completed"]]]])
        log.update(records: [try user("u1", "First question"), try chief("a1", "First reply"), tool, try user("u2", "Next question"), try chief("a2", "Next reply\n```md\n## Detail\n- Ready\n```"), try chief("empty", " ")])
        #expect(log.turns.map(\.role) == [.you, .chief, .you, .chief])
        #expect(log.turns.last?.spoken == "Next reply" && log.turns.last?.details == "## Detail\n- Ready")
        #expect(log.turns.allSatisfy { !$0.spoken.isEmpty || !$0.details.isEmpty })
    }
    @Test func liveUserGrowsInPlaceAndAcknowledgedHistoryReplacesItWithoutDuplication() throws {
        var log = ConversationVoiceLog()
        log.update(records: [try user("u1", "Old question"), try chief("a1", "Old reply")])
        log.handle(.youStarted, userText: "")
        log.handle(.youLive("New"), userText: "New")
        let liveID = log.turns.last?.id
        log.handle(.youLive("New words growing"), userText: "New words growing")
        #expect(log.turns.count == 3 && log.turns.last?.id == liveID && log.turns.last?.spoken == "New words growing")
        log.handle(.posted("New words growing"), userText: "New words growing")
        log.update(records: [try user("u1", "Old question"), try chief("a1", "Old reply"), try user("u2", "New words growing")])
        #expect(log.turns.count == 3 && log.turns.last?.spoken == "New words growing" && log.turns.last?.pending == false)
    }
    @Test func speechGrowsTheCorrectChiefBubbleWithoutDumpingAndPriorTurnsStay() throws {
        var log = ConversationVoiceLog()
        let history = [try user("u1", "Earlier question"), try chief("a1", "Earlier answer"), try user("u2", "Current question")]
        log.update(records: history)
        log.setVoice(running: true, muted: false)
        log.update(records: history + [try chief("a2", "First sentence. Second sentence.\n```md\n**Detail**\n```")])
        #expect(log.turns.last?.spoken == "" && log.turns.last?.details == "**Detail**")
        log.handle(.chiefQueued(label: "a2:0", text: "First sentence."), userText: "")
        log.handle(.chiefQueued(label: "a2:0", text: "Second sentence."), userText: "")
        log.handle(.chiefStarted(label: "a2:0", text: "First sentence."), userText: "")
        #expect(log.turns.last?.spoken == "First sentence." && log.turns[1].spoken == "Earlier answer")
        log.handle(.chiefEnded(label: "a2:0", text: "First sentence.", outcome: "played"), userText: "")
        log.handle(.chiefStarted(label: "a2:0", text: "Second sentence."), userText: "")
        log.handle(.chiefEnded(label: "a2:0", text: "Second sentence.", outcome: "played"), userText: "")
        log.handle(.youStarted, userText: ""); log.handle(.youLive("Another thought"), userText: "Another thought")
        #expect(log.turns.count == 5 && log.turns[3].spoken == "First sentence. Second sentence." && log.turns.last?.role == .you)
    }
    @Test func mutedReplyStreamsInPlaceAndSpeechReplayCannotDuplicateIt() throws {
        var log = ConversationVoiceLog(); log.setVoice(running: true, muted: true)
        log.update(records: [try user("u", "Question"), try chief("a", "First part")])
        log.update(records: [try user("u", "Question"), try chief("a", "First part finishes. Next part.")])
        #expect(log.turns.count == 2 && log.turns.last?.spoken == "First part finishes. Next part.")
        log.setVoice(running: true, muted: false)
        log.handle(.chiefQueued(label: "a:0", text: "First part finishes."), userText: "")
        log.handle(.chiefStarted(label: "a:0", text: "First part finishes."), userText: "")
        log.handle(.chiefEnded(label: "a:0", text: "First part finishes.", outcome: "interrupted"), userText: "")
        log.handle(.chiefStarted(label: "a:0", text: "First part finishes."), userText: "")
        #expect(log.turns.last?.spoken == "First part finishes. Next part.")
    }
    @Test func latestPageIsEnoughAndEmptyPendingSpeechDoesNotMakeABubble() throws {
        var log = ConversationVoiceLog(); log.setVoice(running: true, muted: false)
        log.handle(.chiefQueued(label: "pending:0", text: "Not yet heard"), userText: "")
        #expect(log.turns.isEmpty)
        var rows: [Data] = []
        for i in 0..<60 { rows.append(try user("u\(i)", "Question \(i)")); rows.append(try chief("a\(i)", "Reply \(i)")) }
        log.setVoice(running: false, muted: false); log.update(records: rows)
        #expect(log.turns.count == 40 && log.turns.first?.spoken == "Question 40")
    }
    @Test func scrolledUpDoesNotFollowLiveGrowthAndJumpRestoresFollowing() {
        var follow = BottomFollow(); follow.userScrolled(bottomVisible: false)
        #expect(!follow.following)
        follow.selected(); #expect(follow.following)
    }
}
