import Foundation
import FloatingVoiceCore

// fv-harness vad-compare [--out DIR]: the same recordings through our voice-activity detection (TurnTaker) at several
// pause lengths, for comparison with agent-voice's VoiceInput (scripts/vad-compare-agent-voice.mjs runs that one on
// the same files). Recordings are synthesized speech with thinking pauses and fillers (no microphone), in two
// variants: as synthesized, and soft with a noise floor (a quiet, distant microphone). Nothing is played.

private final class EndpointRecognition: RecognitionSession {
    let callbacks: RecognitionCallbacks
    var written = 0
    init(_ c: RecognitionCallbacks) { callbacks = c }
    func start() {}
    func write(_ pcm: Data) { written += 1 }
    func end() { callbacks.done("utterance") }
    func cancel() { callbacks.done("") }
}

struct VadUtterance: Codable { let onset_s: Double; let end_s: Double }

@MainActor
func runOurVAD(_ pcm: Data, pauseMs: Double, threshold: Double = 0.012) -> [VadUtterance] {
    var config = VoiceConfig()
    config.pauseMs = pauseMs
    config.threshold = threshold
    var frame = 0
    var out: [VadUtterance] = []
    var onset = 0.0
    var cb = TurnCallbacks()
    cb.start = { onset = Double(frame) * 0.02 }
    let t = TurnTaker(config: config, callbacks: cb) { EndpointRecognition($0) }
    var i = 0
    while i + 640 <= pcm.count {
        frame += 1
        let wasOpen = t.inUtterance
        t.push(pcm.subdata(in: i..<i + 640))
        if wasOpen && !t.inUtterance {
            out.append(VadUtterance(onset_s: onset, end_s: Double(frame) * 0.02))
        }
        i += 640
    }
    return out
}

@MainActor
func vadCompare(out dir: String) async -> Int32 {
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let recordings: [String: [(String, Double)]] = [
        "thinking": [("So I was looking at the build this morning,", 0.9), ("um", 1.4), ("and I think the problem is", 2.2), ("uh", 1.8),
                     ("the cache isn't being cleared between runs.", 3.0), ("Can you check that for me?", 4.0)],
        "long-pauses": [("Okay, so the next thing I want to talk about is", 2.6), ("the pill window, and how it", 3.5),
                        ("how it handles long pauses when I'm thinking.", 4.5), ("Does that make sense?", 4.0)],
    ]
    let settings = SettingsStore.load()
    var principal = settings.voice
    principal.voice = "female_a"
    let synth = HTTPSpeechSynthesizer(config: { principal })
    var report = "# VAD comparison (ours)\n\n"
    for (name, parts) in recordings.sorted(by: { $0.key < $1.key }) {
        var clean = Data(count: 16000) // 0.5 s lead-in
        var marks: [String] = []
        for (text, pause) in parts {
            do {
                let audio = try await synth.prepare(text).audio()
                var raw = Data()
                for try await chunk in audio.chunks { raw.append(chunk) }
                let start = Double(clean.count) / 32000
                clean.append(resampleS16(raw, from: audio.sampleRate, to: 16000))
                marks.append(String(format: "%.2f-%.2f \"%@\" then %.1f s pause", start, Double(clean.count) / 32000, text, pause))
                clean.append(Data(count: Int(pause * 16000) * 2))
            } catch { print("synthesis failed: \(error.localizedDescription)"); return 1 }
        }
        // Soft and noisy: speech at 15% with a white-noise floor at RMS 0.004 (fixed seed).
        var soft = Data(count: clean.count)
        var seed: UInt64 = 42
        clean.withUnsafeBytes { src in
            soft.withUnsafeMutableBytes { dst in
                let s = src.bindMemory(to: Int16.self), d = dst.bindMemory(to: Int16.self)
                for k in 0..<s.count {
                    seed = seed &* 6364136223846793005 &+ 1442695040888963407
                    let u = Double(seed >> 11) / Double(1 << 53) * 2 - 1 // uniform -1...1, RMS 0.577
                    let v = Double(s[k]) * 0.15 + u / 0.577 * 0.004 * 32768
                    d[k] = Int16(clamping: Int(v.rounded()))
                }
            }
        }
        for (variant, pcm) in [("clean", clean), ("soft", soft)] {
            let file = "\(dir)/\(name)-\(variant).pcm"
            try? pcm.write(to: URL(fileURLWithPath: file))
            // Speech level of this variant: RMS of the voiced frames and the share of frames over the threshold.
            var stats = MicStats()
            stats.add(pcm, threshold: 0.012, playing: false, ignored: false)
            report += "## \(name) (\(variant)): \(String(format: "%.1f", Double(pcm.count) / 32000)) s, \(stats.voiced)/\(stats.frames) frames over 0.012, peak frame RMS \(String(format: "%.3f", stats.peak))\n"
            if variant == "clean" { report += marks.map { "- \($0)\n" }.joined() }
            for pause in [1100.0, 1500.0, 3200.0] {
                let us = runOurVAD(pcm, pauseMs: pause)
                let json = (try? JSONEncoder().encode(us)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
                try? json.write(toFile: "\(dir)/ours-\(name)-\(variant)-\(Int(pause)).json", atomically: true, encoding: .utf8)
                report += "- ours pauseMs \(Int(pause)): \(us.count) utterance(s): " + us.map { String(format: "%.2f-%.2f", $0.onset_s, $0.end_s) }.joined(separator: ", ") + "\n"
            }
            report += "\n"
        }
    }
    try? report.write(toFile: dir + "/ours.md", atomically: true, encoding: .utf8)
    print(report)
    return 0
}
