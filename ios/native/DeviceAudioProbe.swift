import AVFoundation
import SwiftUI
import OSLog

/// Launch-only, no transport/controller/credential construction and no audio persistence.
@MainActor enum DeviceAudioProbe {
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("-FVDeviceProbe") }
    static func run() async {
        let coordinator = AudioSessionCoordinator()
        let audio = IOSAudio(coordinator: coordinator)
        let began = Date()
        var cycle = 0
        func emit(_ event: String) {
            var row = audio.probeMetrics()
            row["event"] = event; row["cycle"] = cycle
            row["elapsedMs"] = Int(Date().timeIntervalSince(began) * 1000)
            if let data = try? JSONSerialization.data(withJSONObject: row, options: .sortedKeys),
               let line = String(data: data, encoding: .utf8) {
                print(line); fflush(stdout)
                Logger(subsystem: "org.example.voicestack", category: "DeviceProbe").notice("\(line, privacy: .public)")
            }
        }
        audio.onProbeEvent = { emit($0) }
        audio.onFailure = { _ in emit("captureFailure") }
        let ticks = Task { @MainActor in
            while !Task.isCancelled {
                emit("tick")
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        let cycles = ProcessInfo.processInfo.arguments.contains("-FVCycles") ? 3 : 1
        for index in 1...cycles {
            cycle = index
            emit("start")
            do {
                try await audio.start(); emit("ready")
                for second in 0..<16 {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    if second == 4 && ProcessInfo.processInfo.arguments.contains("-FVRecovery") {
                        audio.probeConfigurationChange()
                    }
                    if cycles == 1 && ProcessInfo.processInfo.arguments.contains("-FVSwitches") && [4, 9].contains(second) {
                        try coordinator.toggleLiveRoute(); emit("switch")
                    }
                }
            } catch { emit("startFailed") }
            emit("beforeStop"); audio.stop(); emit("stopped")
        }
        ticks.cancel(); emit("summary")
        audio.onProbeEvent = nil; audio.onFailure = nil
    }
}

struct DeviceAudioProbeView: View {
    var body: some View {
        Text("Local microphone diagnostic — no audio saved or sent")
            .padding().task { await DeviceAudioProbe.run() }
    }
}
