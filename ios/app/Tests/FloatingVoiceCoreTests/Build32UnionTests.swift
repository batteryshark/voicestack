import Foundation
import Testing
@testable import FloatingVoiceCore

@MainActor struct Build32UnionTests {
    @Test func bothOutcomeSchemasSurviveTheAdditiveDiagnosticsMerge() throws {
        let stages = StageDiagnostics()
        let utterance = UtteranceOutcomeDiagnostic(ordinal: 1, sequence: 1, finalWordCount: 1,
            finalEmpty: false, finalReceived: true, cutInStoppedPlayback: false,
            outcome: .backchannel, delivery: .notPosted, mergedIntoOrdinal: nil)
        stages.record(.utterance, .complete, utteranceOutcome: utterance)
        stages.record(.voiceEnded, .complete, voiceEnded: .init(kind: .call, outcome: .posted))
        let entries = try JSONDecoder().decode([DiagnosticEntry].self, from: Data(stages.export().utf8))
        #expect(entries.filter { $0.utteranceOutcome?.outcome == .backchannel }.count == 1)
        #expect(entries.filter { $0.voiceEnded?.outcome == .posted && $0.voiceEnded?.kind == .call }.count == 1)
        #expect(entries.count == 2)
    }
}
