import Foundation
import Testing
@testable import FloatingVoiceCore

@Suite @MainActor struct ChiefCaptionTests {
    let first = "The received first sentence is playing now."
    let second = "The second sentence should be revealed later."
    func record(_ text: String, id: String = "a") throws -> [Data] {
        [try JSONSerialization.data(withJSONObject: ["id":id, "type":"assistant", "content":[["type":"text", "text":text]]])]
    }
    func surface(muted: Bool = false) -> VoiceSurface {
        let s = VoiceSurface()
        var status = ConversationController.Status(); status.running = true; status.phase = "ready"; status.connection = "connected"; status.outputMuted = muted
        s.update(status: status, owner: s.binding); return s
    }
    @Test func fasterStreamCannotDumpThenTruncateAndFullSpokenReplyRemains() throws {
        let s = surface(), owner = s.binding
        s.update(records: try record(first + " " + second), connection: "connected", active: true)
        #expect(s.chiefCaption.isEmpty)
        s.handle(.chiefQueued(label: "a:0", text: first), owner: owner)
        s.handle(.chiefQueued(label: "a:0", text: second), owner: owner)
        #expect(s.chiefCaption.isEmpty)
        s.handle(.chiefStarted(label: "a:0", text: first), owner: owner)
        #expect(s.chiefCaption == first)
        s.handle(.chiefEnded(label: "a:0", text: first, outcome: "played"), owner: owner)
        #expect(s.chiefCaption == first) // Between sentences, never the whole queued reply.
        s.handle(.chiefStarted(label: "a:0", text: second), owner: owner)
        s.handle(.chiefEnded(label: "a:0", text: second, outcome: "played"), owner: owner)
        var status = s.pill.status; status.speaking = false; status.busy = false
        s.update(status: status, owner: owner)
        #expect(s.chiefCaption == first + " " + second)
        s.handle(.youStarted, owner: owner)
        s.handle(.youLive("Here is my next thought"), owner: owner)
        #expect(s.chiefCaption == first + " " + second && s.userCaption == "Here is my next thought")
        #expect(s.log.turns.last?.role == .you, "The next turn appends; it never removes the prior chief reply")
    }
    @Test func detailBlockIsRenderedSeparatelyAndNeverQueuedForSpeech() throws {
        let raw = first + " " + second + "\n```md\n## Details\n- Review the install\n```"
        let s = surface(); s.update(records: try record(raw), connection: "connected", active: true)
        #expect(s.chiefCaption.isEmpty && s.chiefDetails == "## Details\n- Review the install")
        var queued: [String] = []
        let segments = SpeechSegments { queued.append($0) }; segments.update(raw); segments.flush(final: true)
        #expect(queued.joined(separator: " ") == first + " " + second)
        #expect(!queued.joined().contains("Details"))
        s.handle(.chiefQueued(label: "a:0", text: first), owner: s.binding)
        s.handle(.chiefStarted(label: "a:0", text: first), owner: s.binding)
        #expect(s.chiefCaption == first && s.chiefDetails.contains("Review the install"))
    }
    @Test func nestedCodeAndUnfinishedDetailStayOutOfSpeech() {
        let raw = first + "\n````md\n## Detail\n```swift\nlet privateExample = 1\n```\nA detail footer\n````\n" + second
        #expect(ChiefReplyContent(raw).spoken == first + "\n\n" + second)
        #expect(ChiefReplyContent(raw).details.contains("```swift"))
        #expect(cleanSpeech(raw) == first + " " + second)
        #expect(cleanSpeech(first + "\n```md\nNever speak this incomplete detail") == first)
        #expect(cleanSpeech(first + "\n```md\nHidden\n```~\nStill inside the invalidly closed detail") == first)
    }
    @Test func mutedVoiceRevealsStreamingTextAndUnmutingCannotRetractIt() throws {
        let s = surface(muted: true)
        s.update(records: try record(first), connection: "connected", active: true)
        #expect(s.chiefCaption == first)
        s.update(records: try record(first + " " + second + "\n```md\n**Detail only**\n```"), connection: "connected", active: true)
        #expect(s.chiefCaption == first + " " + second && s.chiefDetails == "**Detail only**")
        var status = s.pill.status; status.outputMuted = false; s.update(status: status, owner: s.binding)
        s.handle(.chiefQueued(label: "a:0", text: second), owner: s.binding)
        s.handle(.chiefStarted(label: "a:0", text: second), owner: s.binding)
        #expect(s.chiefCaption == first + " " + second)
    }
    @Test func reconnectAndSentenceReplayContinueOneCaptionWithoutDuplication() throws {
        let s = surface(), owner = s.binding
        s.update(records: try record(first), connection: "connected", active: true)
        s.handle(.chiefQueued(label: "a:0", text: first), owner: owner)
        s.handle(.chiefStarted(label: "a:0", text: first), owner: owner)
        s.handle(.chiefEnded(label: "a:0", text: first, outcome: "interrupted"), owner: owner)
        s.handle(.chiefStarted(label: "a:0", text: first), owner: owner)
        s.handle(.chiefEnded(label: "a:0", text: first, outcome: "played"), owner: owner)
        s.update(records: try record(first + " " + second), connection: "reconnecting", active: false)
        #expect(s.chiefCaption == first)
        s.handle(.chiefQueued(label: "a:0", text: second), owner: owner)
        s.handle(.chiefStarted(label: "a:0", text: second), owner: owner)
        s.update(records: try record(first + " " + second), connection: "connected", active: false)
        #expect(s.chiefCaption == first + " " + second)
    }
    @Test func identicalGenuineSentencesAreNotMistakenForReplay() {
        var caption = ChiefCaptionState()
        for _ in 0..<2 { caption.queued(label: "a:0", text: first) }
        for _ in 0..<2 { caption.started(label: "a:0", text: first); caption.ended(label: "a:0", text: first, outcome: "played") }
        #expect(caption.spoken == first + " " + first)
    }
    @Test func nextTurnCannotBeReplacedByLateTextFromThePriorReply() throws {
        let s = surface(), owner = s.binding
        s.update(records: try record(first), connection: "connected", active: true)
        s.handle(.chiefQueued(label: "a:0", text: first), owner: owner)
        s.handle(.chiefStarted(label: "a:0", text: first), owner: owner)
        s.handle(.youStarted, owner: owner); s.handle(.youLive("My next turn"), owner: owner)
        s.handle(.chiefQueued(label: "a:0", text: second), owner: owner)
        s.update(records: try record(first + " " + second), connection: "connected", active: true)
        s.handle(.chiefStarted(label: "a:0", text: second), owner: owner)
        #expect(s.chiefCaption == first + " " + second && s.userCaption == "My next turn")
        #expect(s.log.turns.last?.spoken == "My next turn")
        s.update(records: try record(second, id: "b"), connection: "connected", active: true)
        s.handle(.chiefQueued(label: "b:0", text: second), owner: owner)
        s.handle(.chiefStarted(label: "b:0", text: second), owner: owner)
        #expect(s.chiefCaption == second)
    }
    @Test func speechNetworkFailureIsVisibleAndKeepsTheFullReplyReadable() throws {
        let s = surface()
        s.update(records: try record(first + " " + second), connection: "connected", active: true)
        s.handle(.chiefQueued(label: "a:0", text: first), owner: s.binding)
        s.handle(.chiefStarted(label: "a:0", text: first), owner: s.binding)
        s.handle(.chiefUnavailable, owner: s.binding)
        #expect(s.chiefCaption == first + " " + second)
        #expect(PrincipalError.message("Speech: Network connection lost -1005", captureRunning: true) != nil)
        #expect(PrincipalError.message("Recognition: Network connection lost", captureRunning: true) != nil)
        s.update(records: try record(second, id: "b"), connection: "connected", active: true)
        #expect(s.chiefCaption.isEmpty, "A new successful reply must not inherit text-only failure mode")
    }
    @Test func newReplyCannotKeepThePreviousReplyAheadOfItsSpeech() throws {
        let s = VoiceSurface()
        s.update(records: try record("Prior reply.", id: "old"), connection: "connected", active: false)
        var status = ConversationController.Status(); status.running = true; status.phase = "ready"; s.update(status: status, owner: s.binding)
        s.handle(.chiefQueued(label: "a:0", text: first), owner: s.binding)
        s.update(records: try record(first + " " + second), connection: "connected", active: true)
        #expect(s.chiefCaption.isEmpty)
        s.handle(.chiefStarted(label: "a:0", text: first), owner: s.binding)
        #expect(s.chiefCaption == first)
    }
}
