import Foundation
import Testing
@testable import FloatingVoiceCore

@Suite @MainActor struct MainLogMarkdownWorkTests {
    func record(_ raw: String, id: String = "work") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["id":id, "type":"assistant", "content":[["type":"text", "text":raw]]])
    }

    @Test func sixHundredLinePlainRevealIsCachedAndUnchangedInputsDoZeroWork() throws {
        let list = (0..<600).map { "- Item \($0)" }.joined(separator: "\n")
        let raw = list + "\n\nFinal sentence not started.", data = try record(raw)
        var renders = 0, log = ConversationVoiceLog()
        let render = log.renderDisplay
        log.renderDisplay = { text, sources in renders += 1; return render(text, sources) }
        log.setVoice(running: true, muted: false); log.update(records: [data])
        log.handle(.chiefStarted(label: "work:0", text: cleanSpeech(list)), userText: "")
        #expect(renders == 1)
        #expect(log.turns.last?.spokenBlocks.count == 600)
        #expect(log.turns.last?.spokenBlocks.last == .paragraph("Item 599"))

        let cached = log.turns
        for _ in 0..<1000 { #expect(log.turns == cached); #expect(log.turns.last?.spokenBlocks.count == 600) }
        log.update(records: [data]); log.setVoice(running: true, muted: false)
        log.handle(.chiefQueued(label: "work:0", text: "Final sentence not started."), userText: "")
        #expect(renders == 1, "Re-render and identical display inputs must perform zero projection work")

        log.handle(.chiefStarted(label: "work:0", text: "Final sentence not started."), userText: "")
        #expect(renders == 2 && log.turns.last?.spokenBlocks.last == .paragraph("Final sentence not started."))
        log.update(records: [try record(raw.replacingOccurrences(of: "Item 0", with: "Revised 0"))])
        #expect(log.turns.last?.spokenBlocks == BlockMarkdown.renderBlocks(log.turns.last!.spoken))
        #expect(log.turns.last?.spoken.contains("Revised") == false, "Live plain rendering never substitutes revised source words")
        log.setVoice(running: false, muted: false)
        #expect(log.turns.last?.spokenBlocks.first == .list("- Revised 0"))
        let beforeRevision = renders
        log.update(records: [try record(raw.replacingOccurrences(of: "Item 0", with: "More revised 0"))])
        #expect(renders > beforeRevision && log.turns.last?.spokenBlocks.first == .list("- More revised 0"))
    }

    @Test func mergedRecordsCachePlainWhileUnmutedAndRichOnlyOnMute() throws {
        let old = try record("## Old", id: "old"), current = try record("## Current\nNext.")
        var renders = 0, log = ConversationVoiceLog()
        let render = log.renderDisplay
        log.renderDisplay = { text, sources in renders += 1; return render(text, sources) }
        log.update(records: [old]); log.setVoice(running: true, muted: false)
        log.update(records: [old, current])
        log.handle(.chiefStarted(label: "work:0", text: "Current"), userText: "")
        #expect(log.turns.count == 1)
        #expect(log.turns[0].spokenBlocks == [.paragraph("Old"), .paragraph("Current")])
        let cached = renders
        log.update(records: [old, current])
        log.handle(.chiefEnded(label: "work:0", text: "Current", outcome: "played"), userText: "")
        #expect(renders == cached)
        log.handle(.youStarted, userText: "")
        #expect(renders == cached)
        log.setVoice(running: true, muted: true)
        #expect(renders == cached + 2)
        #expect(log.turns[0].spokenBlocks == [.heading(2, "Old"), .heading(2, "Current"), .paragraph("Next.")])
        log.setVoice(running: true, muted: false)
        #expect(log.turns[0].spokenBlocks == [.paragraph("Old"), .paragraph("Current"), .paragraph("Next.")])
    }
}
