import Foundation
import Testing
@testable import FloatingVoiceCore

@Suite @MainActor struct MainLogMarkdownTests {
    let fixture = """
    ## A gentle Saturday outdoors
    - Start early for cooler air.
    - Bring water and take a shady break.

    | Trail | Distance | Pace |
    | --- | --- | --- |
    | Pine Loop | 4 km | Easy |
    | Meadow Path | 2 km | Relaxed |

    ```text
    Pack: water, snack, light layer
    Check: forecast and trail signs
    ```
    """
    func record(_ text: String, id: String = "a") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["id":id, "type":"assistant", "content":[["type":"text", "text":text]]])
    }
    @Test(arguments: ["idle", "muted", "live"], [false, true])
    func mainUsesHistoryBlocksForHeadingListsTableAndCode(_ mode: String, _ compact: Bool) throws {
        let raw = compact ? fixture.replacingOccurrences(of: " | ", with: "|") : fixture
        let data = try record(raw), row = try #require(MessageRow(data))
        var log = ConversationVoiceLog(); log.setVoice(running: mode != "idle", muted: mode == "muted")
        log.update(records: [data])
        if mode == "live" {
            #expect(log.turns.last?.spokenBlocks.isEmpty == true)
            log.handle(.chiefQueued(label: "a:0", text: cleanSpeech(raw)), userText: "")
            log.handle(.chiefStarted(label: "a:0", text: cleanSpeech(raw)), userText: "")
            #expect(log.turns.last?.spokenBlocks == BlockMarkdown.renderBlocks(log.turns.last!.spoken))
            log.setVoice(running: false, muted: false)
        }
        let turn = try #require(log.turns.last)
        let displayed = turn.spokenBlocks + BlockMarkdown.renderBlocks(turn.details)
        #expect(displayed == row.body.flatMap(\.blocks))
        #expect(turn.spoken == ChiefReplyContent(raw).spoken && turn.details == ChiefReplyContent(raw).details)
        #expect(turn.displayLabel == AgentPresentation.name)
        #expect(displayed.contains(.heading(2, "A gentle Saturday outdoors")))
        #expect(displayed.contains(.list("- Start early for cooler air.")))
        #expect(displayed.contains(.table([["Trail", "Distance", "Pace"], ["Pine Loop", "4 km", "Easy"], ["Meadow Path", "2 km", "Relaxed"]])))
        #expect(displayed.contains(.code("text", "Pack: water, snack, light layer\nCheck: forecast and trail signs")))
        for block in turn.spokenBlocks {
            if case .paragraph(let value) = block { #expect(!value.contains("|"), "No raw table syntax in the main-card fixture") }
        }
        var speech: [String] = []
        let segments = SpeechSegments { speech.append($0) }; segments.update(raw); segments.flush(final: true)
        #expect(speech.joined(separator: " ") == cleanSpeech(raw))
        #expect(!speech.joined().contains("Pack:"))
    }
    @Test func liveSpeechStaysPlainThroughSentenceEndsAndUserOnsetUntilOff() throws {
        var log = ConversationVoiceLog(); log.setVoice(running: true, muted: false)
        log.update(records: [try record(fixture)])
        log.handle(.chiefStarted(label: "a:0", text: "A gentle Saturday outdoors Start early"), userText: "")
        let caption = try #require(log.turns.last)
        #expect(caption.spokenBlocks == BlockMarkdown.renderBlocks(caption.spoken))
        #expect(!caption.spoken.contains("Bring water"))
        log.handle(.chiefEnded(label: "a:0", text: "A gentle Saturday outdoors Start early", outcome: "played"), userText: "")
        #expect(log.turns.last?.spokenBlocks == caption.spokenBlocks, "Sentence end is not a record-end authority")
        log.handle(.youStarted, userText: "")
        #expect(log.turns.last?.spokenBlocks == caption.spokenBlocks)
        log.setVoice(running: false, muted: false)
        let promoted = try #require(log.turns.last)
        #expect(promoted.details == caption.details)
        #expect(promoted.spokenBlocks.contains(.heading(2, "A gentle Saturday outdoors")))
        #expect(promoted.spokenBlocks.contains(.list("- Bring water and take a shady break.")))
    }
    @Test func separateMergedRecordsDoNotReparseAnUnclosedFenceAcrossMessages() throws {
        var log = ConversationVoiceLog()
        log.update(records: [try record("First reply\n```text\nA code detail", id: "a"), try record("## Second reply\n- Still visible", id: "b")])
        #expect(log.turns.count == 1)
        #expect(log.turns[0].spokenBlocks == [.paragraph("First reply"), .heading(2, "Second reply"), .list("- Still visible")])
    }
    @Test func captionBeforeSourceUsesExactlyThePreBuild36CaptionRenderer() {
        var log = ConversationVoiceLog(); log.setVoice(running: true, muted: false)
        log.handle(.chiefStarted(label: "a:0", text: "| Trail | Distance | | --- | --- | | Pine | 4 km |"), userText: "")
        #expect(log.turns.last?.spokenBlocks == BlockMarkdown.renderBlocks(log.turns.last!.spoken))
    }
    @Test func sourceRevisionCannotReplaceAlreadyHeardWordsWithUnheardMarkup() throws {
        var log = ConversationVoiceLog(); log.setVoice(running: true, muted: false)
        log.update(records: [try record("## Original answer.")])
        log.handle(.chiefStarted(label: "a:0", text: "Original answer."), userText: "")
        log.update(records: [try record("## Corrected unseen answer.")])
        #expect(log.turns.last?.spoken == "Original answer.")
        #expect(log.turns.last?.spokenBlocks == [.paragraph("Original answer.")])
    }
    @Test func principalLiteralPipesAndLabelsRemainUnchanged() throws {
        let raw = try JSONSerialization.data(withJSONObject: ["id":"u", "type":"user", "text":"Use a | b in shell", "sender":["kind":"principal", "label":"You"]])
        var log = ConversationVoiceLog(); log.update(records: [raw])
        #expect(log.turns.last?.spokenBlocks == [.paragraph("Use a | b in shell")])
        #expect(log.turns.last?.displayLabel == "You")
    }
    let urlTable = "|Link|Status|\n|---|---|\n|https://example.invalid|Open|"
    @Test(arguments: ["idle", "muted", "live"], [false, true])
    func compactBareURLTableAndTrailingProseKeepAllSourceBlocks(_ mode: String, _ trailing: Bool) throws {
        let raw = urlTable + (trailing ? "\n\nAfter table." : "")
        var log = ConversationVoiceLog(); log.setVoice(running: mode != "idle", muted: mode == "muted")
        let data = try record(raw); log.update(records: [data])
        if mode == "live" {
            log.handle(.chiefStarted(label: "a:0", text: cleanSpeech(raw)), userText: "")
            log.setVoice(running: false, muted: false)
        }
        let turn = try #require(log.turns.last), row = try #require(MessageRow(data))
        #expect(turn.spokenBlocks == row.body.flatMap(\.blocks))
        #expect(turn.spokenBlocks.first == .table([["Link", "Status"], ["https://example.invalid", "Open"]]))
        if trailing { #expect(turn.spokenBlocks.last == .paragraph("After table.")) }
        #expect(turn.spoken == ChiefReplyContent(raw).spoken)
        var speech: [String] = []
        let segments = SpeechSegments { speech.append($0) }; segments.update(raw); segments.flush(final: true)
        #expect(speech.joined(separator: " ") == cleanSpeech(raw))
    }
    @Test(arguments: ["idle", "muted", "live"], ["👍", "✅", "→", "Ready 👍", "Ready ✅ next"])
    func symbolsAndMixedProseRemainVisibleWithoutChangingSpeech(_ mode: String, _ raw: String) throws {
        var log = ConversationVoiceLog(); log.setVoice(running: mode != "idle", muted: mode == "muted")
        log.update(records: [try record(raw)])
        if mode == "live" {
            #expect(log.turns.isEmpty)
            log.handle(.chiefStarted(label: "a:0", text: cleanSpeech(raw)), userText: "")
            log.setVoice(running: false, muted: false)
        }
        #expect(log.turns.last?.spokenBlocks == BlockMarkdown.renderBlocks(raw))
        #expect(log.turns.last?.spoken == ChiefReplyContent(raw).spoken)
    }
    @Test(arguments: [" ", "\n"]) func liveSymbolsAreNotRevealedBeforeTheirSpeech(_ separator: String) throws {
        let raw = ["Ready", "✅", "Later"].joined(separator: separator)
        var log = ConversationVoiceLog(); log.setVoice(running: true, muted: false)
        log.update(records: [try record(raw)])
        log.handle(.chiefStarted(label: "a:0", text: "Ready"), userText: "")
        #expect(log.turns.last?.spokenBlocks == [.paragraph("Ready")])
        log.handle(.chiefStarted(label: "a:0", text: "✅"), userText: "")
        #expect(log.turns.last?.spokenBlocks == BlockMarkdown.renderBlocks(log.turns.last!.spoken))
        #expect(log.turns.last?.spoken.contains("Later") == false)
        log.handle(.chiefStarted(label: "a:0", text: "Later"), userText: "")
        #expect(log.turns.last?.spokenBlocks == BlockMarkdown.renderBlocks(log.turns.last!.spoken))
        log.setVoice(running: false, muted: false)
        #expect(log.turns.last?.spokenBlocks == BlockMarkdown.renderBlocks(raw))
    }
    @Test(arguments: [
        "Ready\r\n```text\r\nHidden code\r\n```\r\nUNHEARD prose\r\n",
        "Ready\n```text\nHidden code\n``` suffix\nUNHEARD prose\n",
        "Ready\n```text\nHidden code\n``` suffix\n![contracting image\ncaption](asset.png)\nUNHEARD prose\n"
    ])
    func disagreeingFenceParsersCannotPromoteTheCurrentLiveReply(_ raw: String) throws {
        var log = ConversationVoiceLog(); log.setVoice(running: true, muted: false)
        log.update(records: [try record(raw)])
        log.handle(.chiefStarted(label: "a:0", text: "Ready"), userText: "")
        #expect(log.turns.last?.spoken == "Ready")
        #expect(log.turns.last?.spokenBlocks == [.paragraph("Ready")])
        log.handle(.chiefEnded(label: "a:0", text: "Ready", outcome: "played"), userText: "")
        #expect(log.turns.last?.spokenBlocks == [.paragraph("Ready")])
        log.setVoice(running: false, muted: false)
        #expect(log.turns.last?.spokenBlocks.contains(.paragraph("UNHEARD prose")) == true)
        #expect(log.turns.last?.details.contains("UNHEARD prose") == true) // Known, pre-existing idle duplicate.
    }
    @Test func richSnapshotDoesNotAuthorizeARevisedSourceWhileLive() throws {
        var log = ConversationVoiceLog(); log.update(records: [try record("## Original answer.")])
        #expect(log.turns.last?.spokenBlocks == [.heading(2, "Original answer.")])
        log.setVoice(running: true, muted: false)
        #expect(log.turns.last?.spokenBlocks == [.paragraph("Original answer.")])
        log.update(records: [try record("## Original answer.\nUNHEARD revision")])
        #expect(log.turns.last?.spoken == "Original answer.")
        #expect(log.turns.last?.spokenBlocks == [.paragraph("Original answer.")])
    }
    @Test(arguments: ["off", "mute"]) func onlyExplicitBoundariesPromoteTheKnownSnapshot(_ boundary: String) throws {
        let data = try record(fixture), row = try #require(MessageRow(data))
        var log = ConversationVoiceLog(); log.setVoice(running: true, muted: false)
        log.update(records: [data])
        log.handle(.chiefStarted(label: "a:0", text: "A gentle Saturday outdoors"), userText: "")
        log.handle(.chiefEnded(label: "a:0", text: "A gentle Saturday outdoors", outcome: "played"), userText: "")
        #expect(log.turns.last?.spokenBlocks == [.paragraph("A gentle Saturday outdoors")])
        switch boundary {
        case "off": log.setVoice(running: false, muted: false)
        case "mute": log.setVoice(running: true, muted: true)
        default: Issue.record("Unexpected display boundary")
        }
        let turn = try #require(log.turns.last)
        #expect(turn.spokenBlocks + BlockMarkdown.renderBlocks(turn.details) == row.body.flatMap(\.blocks))
    }
}
