import Foundation
import Testing
@testable import FloatingVoiceCore

@Suite struct CallDiagnosticRetentionTests {
    private func rows(_ log: StageDiagnostics) throws -> [DiagnosticEntry] {
        try JSONDecoder().decode([DiagnosticEntry].self, from: Data(log.export().utf8))
    }
    private func noise(_ log: StageDiagnostics) {
        for _ in 0..<1200 {
            log.record(.events, .complete); log.record(.state, .complete); log.record(.credentialRead, .complete)
        }
    }
    @Test func wholeLongCurrentAndPreviousCallSurviveHeavyNoisyEventsRing() throws {
        let log = StageDiagnostics()
        log.beginCall()
        log.record(.call, .begin, callEvent: .reportRequested)
        for i in 0..<350 { // More protected events than the entire old FIFO.
            log.record(.route, .complete, status: i,
                audioRoute: RouteDiagnostic(event: .toggle, before: .phone, after: .speaker, action: .speaker, result: .applied))
        }
        noise(log)
        log.record(.call, .complete, callEvent: .ended)
        log.beginCall()
        log.record(.call, .begin, callEvent: .reportRequested)
        log.record(.route, .complete, audioRoute: RouteDiagnostic(event: .recovery, before: .speaker, after: .phone, result: .recovered))
        log.record(.other, .suspended, callAuthority: CallAuthorityDiagnostic(cause: .backendFailure, decision: .pause,
            everReady: true, attempt: .recovery, rejectedReport: false))
        noise(log)
        let retained = try rows(log)
        #expect(retained.filter { $0.stage == .route && $0.diagnosticCall == 1 }.count == 350)
        #expect(retained.contains { $0.diagnosticCall == 1 && $0.callEvent == .reportRequested })
        #expect(retained.contains { $0.diagnosticCall == 1 && $0.callEvent == .ended })
        #expect(retained.contains { $0.diagnosticCall == 2 && $0.callEvent == .reportRequested })
        #expect(retained.contains { $0.diagnosticCall == 2 && $0.callAuthority?.cause == .backendFailure })
        #expect(retained.contains { $0.diagnosticCall == 2 && $0.audioRoute?.result == .recovered })
        #expect(retained.filter { $0.diagnosticCall == nil }.count <= 256)
    }
    @Test func onlyActualThirdAdmissionRotatesOldestCallNotNoiseOrTerminalEvent() throws {
        let log = StageDiagnostics()
        log.beginCall(); log.record(.call, .complete, callEvent: .ended)
        log.beginCall(); log.record(.route, .complete, status: 222)
        noise(log)
        #expect(Set(try rows(log).compactMap(\.diagnosticCall)) == [1, 2])
        log.beginCall(); noise(log)
        let retained = try rows(log)
        #expect(Set(retained.compactMap(\.diagnosticCall)) == [2, 3])
        #expect(retained.contains { $0.diagnosticCall == 2 && $0.status == 222 })
    }
    @Test func protectedCallHistoryLargerThanOldFileLimitRestoresAcrossConfigure() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("stages.json"), source = StageDiagnostics()
        source.beginCall()
        for i in 0..<600 {
            source.record(.route, .complete, status: i,
                audioRoute: RouteDiagnostic(event: .toggle, before: .phone, after: .speaker, action: .speaker, result: .confirmed))
        }
        let data = Data(source.export().utf8)
        #expect(data.count > 131072)
        try data.write(to: file)
        let restored = StageDiagnostics(); restored.configure(file: file, build: 29)
        restored.beginCall()
        let retained = try rows(restored)
        #expect(retained.filter { $0.diagnosticCall == 1 && $0.stage == .route }.count == 600)
        #expect(retained.contains { $0.diagnosticCall == 2 && $0.callEvent == .callAdmitted })
        let persisted = try JSONDecoder().decode([DiagnosticEntry].self, from: Data(contentsOf: file))
        #expect(persisted.count == retained.count)
        #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }
    @Test func flappingOverCapKeepsFirst200NewestAndOneExactClosedElisionMarker() throws {
        let log = StageDiagnostics(); log.beginCall()
        for i in 0..<6500 {
            log.record(.route, .complete, status: i,
                audioRoute: RouteDiagnostic(event: .notification, before: .phone, after: .speaker))
        }
        noise(log)
        let bank = try rows(log).filter { $0.diagnosticCall == 1 }
        #expect(bank.count <= 5000)
        #expect(try JSONEncoder().encode(bank).count <= 1_048_576)
        #expect(bank.contains { $0.callEvent == .callAdmitted })
        #expect(Set(bank.compactMap(\.status)).isSuperset(of: Set(0..<199)))
        #expect(Set(bank.compactMap(\.status)).isSuperset(of: Set(6400..<6500)))
        let markers = bank.filter { $0.callEvent == .elided }
        #expect(markers.count == 1)
        #expect(markers[0].elidedCount == 6501 - (bank.count - 1))
        #expect(!log.export().contains("http") && !log.export().contains("UID"))
    }
    @Test func byteLimitBeforeRecordLimitAndElisionCountSurvivesReload() throws {
        let log = StageDiagnostics(); log.beginCall()
        let fields: [CaptureField] = [.inputRate, .inputCount, .inputCommon, .inputInterleaved, .outputRate, .outputCount,
            .outputCommon, .outputInterleaved, .requestedRate, .requestedCount, .requestedCommon, .requestedInterleaved,
            .actualRate, .actualCount, .actualCommon, .actualInterleaved, .sessionRate, .inputFrames, .convertedFrames,
            .callbacks, .hardwareCallbacks, .validBuffers, .conversionErrors, .formatChanges, .configurationChanges,
            .restarts, .rms, .failure, .categoryOptions, .graphGeneration]
        let snapshot = CaptureSnapshot(Dictionary(uniqueKeysWithValues: fields.map { ($0, Double.greatestFiniteMagnitude) }))
        for i in 0..<1800 { log.record(.route, .complete, status: i, audio: snapshot) }
        let bank = try rows(log).filter { $0.diagnosticCall == 1 }
        #expect(bank.count < 1800 && bank.count < 5000)
        #expect(try JSONEncoder().encode(bank).count <= 1_048_576)
        #expect(Set(bank.compactMap(\.status)).isSuperset(of: Set(0..<199)))
        #expect(bank.contains { $0.status == 1799 })
        let count = try #require(bank.first { $0.callEvent == .elided }?.elidedCount)
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("stages.json")
        try Data(log.export().utf8).write(to: file)
        let restored = StageDiagnostics(); restored.configure(file: file, build: 29)
        let loaded = try rows(restored)
        #expect(loaded.filter { $0.callEvent == .elided }.count == 1)
        #expect(loaded.first { $0.callEvent == .elided }?.elidedCount == count)
        #expect(loaded.contains { $0.status == 1799 })
    }
}
