#if os(macOS)
import Foundation
import Testing

/// Keep the read-only region gate in the normal swift-test path, not just a
/// manually remembered device-suite command. Python uses only its standard library.
@Suite struct MacVoiceParityTests {
    @Test
    func acceptedMacRegionsRemainInParity() throws {
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../native/test_mac_voice_parity.py").standardizedFileURL
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", script.path]
        let output = Pipe()
        process.standardOutput = output; process.standardError = output
        try process.run()
        let evidence = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "Mac voice-core parity failed: \(String(decoding: evidence, as: UTF8.self))")
    }
}
#endif
