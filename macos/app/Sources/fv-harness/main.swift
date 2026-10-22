import Foundation
import FloatingVoiceCore
import FloatingVoiceAudio
import FloatingVoiceUI

// fv-harness: headless integration tests for the conversation controller against throwaway OpenChamber sessions.
// Audio never touches hardware: the "mic" is synthesized speech fed from memory and playback is recorded to a WAV.
//
//   fv-harness run [--log-dir DIR] [--only a,b,c,d,e,h,i,p,w,n,u,m,f,g] [--timeout SECONDS]
//   fv-harness vad-compare [--out DIR]     our voice-activity detection on synthesized recordings (see VadCompare.swift)
//   fv-harness render-stills [--out DIR]   PNG stills of the pill's states, both looks (SwiftUI ImageRenderer; no window)
//   fv-harness render-name-stills [--out DIR]   the settings and assistant-speaking stills, both looks
//   fv-harness render-error-stills [--out DIR]   the resting and card error stills (a speech service not running), both looks
//   fv-harness render-motion [--out DIR]   frames, GIF and MP4 of the pill growing and shrinking (offscreen)
//   fv-harness render-icons [--out DIR] [--app-icon N]   the icon options (Icon Composer documents and flat PNGs) into
//                                          app/Icon/options/, previews into DIR; --app-icon N also runs scripts/set-icon.sh N
//   fv-harness mic-holders        read-only list of processes capturing the microphone now
//
// Safety: every prompt, steer, interrupt and model change goes through a guard that refuses the chief and lead
// sessions, any session this run did not create, and any session whose directory is not under /scratchpad/.

let projectDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
let forbidden: Set<String> = [
    "ses_SYNTHETIC0022c76RThXACt6GCT", // chief
    "ses_SYNTHETIC0019", // lead
    "ses_SYNTHETIC0026", "ses_SYNTHETIC0021", "ses_SYNTHETIC0024",
]

func arg(_ name: String) -> String? {
    guard let i = CommandLine.arguments.firstIndex(of: name), i + 1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[i + 1]
}

// MARK: Logging

@MainActor
final class RunLog {
    let dir: String
    let t0 = Date()
    private let handle: FileHandle
    private let formatter: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f }()

    init(dir: String) {
        self.dir = dir
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir + "/run.log", contents: nil)
        handle = FileHandle(forWritingAtPath: dir + "/run.log")!
    }

    var ms: Double { Date().timeIntervalSince(t0) * 1000 }

    func line(_ tag: String, _ message: String) {
        let s = String(format: "+%8.3fs %@ [%@] %@\n", Date().timeIntervalSince(t0), formatter.string(from: Date()), tag, message)
        FileHandle.standardOutput.write(Data(s.utf8))
        handle.write(Data(s.utf8))
    }

    func append(_ file: String, _ text: String) {
        let path = dir + "/" + file
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
        if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(Data(text.utf8)); h.closeFile() }
    }
}

// MARK: Observer (an independent subscription that records the throwaway sessions' events)

@MainActor
final class Observer {
    struct Entry { let at: Double; let event: ServerEvent }
    private(set) var entries: [Entry] = []
    private let client: OpenChamberClient
    private let log: RunLog
    var sessions: Set<String> = []
    private var task: Task<Void, Never>?

    init(client: OpenChamberClient, log: RunLog) { self.client = client; self.log = log }

    func start() {
        task = Task { [weak self] in
            while let self, !Task.isCancelled {
                do {
                    for try await event in self.client.events() {
                        guard let sid = event.sessionID, self.sessions.contains(sid) else { continue }
                        let at = self.log.ms
                        self.entries.append(Entry(at: at, event: event))
                        if event.type != "session.text.delta" && event.type != "session.reasoning.delta" {
                            var extra = ""
                            if event.type == "session.inbox.enqueued", let item = event.data["item"] as? [String: Any] {
                                extra = " delivery=\(item["delivery"] as? String ?? "?") text=\(((item["payload"] as? [String: Any])?["text"] as? String ?? "").prefix(70))"
                            }
                            if event.type == "session.text.ended" { extra = " [\(event.blockKey)] \((event.text ?? "").prefix(70))" }
                            if event.type.hasPrefix("session.execution") || event.type.hasPrefix("session.inbox") || event.type.hasPrefix("session.text") || event.type == "session.tool.called" {
                                self.log.line("observer", "\(sid.suffix(6)) \(event.type.replacingOccurrences(of: "session.", with: ""))\(extra)")
                            }
                        }
                        let obj: [String: Any] = ["at_ms": at, "type": event.type, "data": event.data]
                        if let data = try? JSONSerialization.data(withJSONObject: obj), let s = String(data: data, encoding: .utf8) { self.log.append("observed-events.jsonl", s + "\n") }
                    }
                } catch {}
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    func stop() { task?.cancel() }

    func events(_ session: String, _ type: String, after: Double = 0) -> [Entry] {
        entries.filter { $0.at >= after && $0.event.sessionID == session && $0.event.type == type }
    }
}

// MARK: Harness

@MainActor
final class Harness {
    let log: RunLog
    let only: Set<String>
    let client = OpenChamberClient()          // the harness's own "other client" (setup, simulated lead)
    let appClient = OpenChamberClient()       // the controller's client
    var created: [String] = []
    var sessionDirs: [String: String] = [:]
    var observer: Observer!
    var controller: ConversationController!
    /// The window's view model, attached to the controller as the app does (headless).
    let pill = PillModel()
    var pillTicker: Task<Void, Never>?
    var output: FileAudioOutput!
    var input: FileAudioInput!
    var chiefFile = ""
    var settings: LoadedSettings!
    var utterances: [String: Data] = [:]
    var results: [(String, Bool, String)] = []

    init(log: RunLog, only: Set<String>) { self.log = log; self.only = only }

    func guardSession(_ id: String) async throws {
        guard !forbidden.contains(id) else { throw ClientError("REFUSED: \(id) is a protected session") }
        guard created.contains(id) else { throw ClientError("REFUSED: \(id) was not created by this harness run") }
        let info = try await client.sessionInfo(id)
        guard info.directory.contains("/scratchpad/") else { throw ClientError("REFUSED: \(id) directory is not a scratchpad: \(info.directory)") }
    }

    func check(_ name: String, _ ok: Bool, _ detail: String) {
        results.append((name, ok, detail))
        log.line(ok ? "PASS" : "FAIL", "\(name): \(detail)")
    }

    func waitFor(_ what: String, timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let ok = condition()
        if !ok { log.line("wait", "timed out after \(Int(timeout))s waiting for: \(what)") }
        return ok
    }

    // MARK: Setup

    func setup() async throws {
        let desc = try await client.connect()
        _ = try await appClient.connect()
        log.line("setup", "OpenChamber: \(desc)")
        client.sendPolicy = { [weak self] id in try await self?.guardSession(id) }
        appClient.sendPolicy = { [weak self] id in try await self?.guardSession(id) }

        let stamp = Int(Date().timeIntervalSince1970)
        for name in ["a", "b"] {
            let dir = projectDir + "/scratchpad/fv-run-\(stamp)-\(name)"
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            for (i, f) in ["a", "b", "c", "d", "e"].enumerated() {
                try "File \(f) holds \(i + 3) apples and \(i + 1) pears for the harness.\n".write(toFile: dir + "/\(f).txt", atomically: true, encoding: .utf8)
            }
            let id = try await client.createSession(directory: dir, title: "floating-voice harness \(name) (throwaway)")
            created.append(id)
            sessionDirs[id] = dir
            try await guardSession(id)
            try await client.setModel(sessionID: id, providerID: "claude-code", modelID: "claude-haiku-5-5")
            let info = try await client.sessionInfo(id)
            log.line("setup", "created session \(name.uppercased()) \(id) in \(info.directory), model claude-code/claude-haiku-5-5")
        }
        log.append("sessions.txt", created.joined(separator: "\n") + "\n")

        // Scratch chief.json naming session A; the app's own settings point at a file that does not exist.
        chiefFile = log.dir + "/chief.json"
        try #"{"session": "\#(created[0])", "directory": "\#(sessionDirs[created[0]]!)"}"#.write(toFile: chiefFile, atomically: true, encoding: .utf8)
        var env = ProcessInfo.processInfo.environment
        env["FV_SETTINGS"] = log.dir + "/no-app-settings.json"
        env["FV_CHIEF_FILE"] = chiefFile
        settings = SettingsStore.load(env: env)
        precondition(settings.chiefFile == chiefFile && !settings.chiefFile.hasPrefix(NSHomeDirectory() + "/.chief-of-staff"))
        log.line("setup", "voice settings from \(settings.voiceFile ?? "defaults"): asr=\(settings.voice.asrUrl) tts=\(settings.voice.ttsUrl) model=\(settings.voice.ttsModel) voice=\(settings.voice.voice) stream=\(settings.voice.ttsStream)")
        log.line("setup", "app settings: target=\(settings.app.target) chiefFile=\(settings.chiefFile) busyDelivery=\(settings.app.busyDelivery.rawValue)")

        observer = Observer(client: client, log: log)
        observer.sessions = Set(created)
        observer.start()

        // Pre-synthesize the principal's utterances with the speech server (a different voice from the agent's).
        let lines: [String: String] = [
            "a": "Hello there. In two short sentences, tell me why the sky looks blue.",
            "queue": "When you are finished, please also say the word mango.",
            "steer": "Please also end your reply with the word papaya.",
            "barge": "Okay, thanks, that sounds good to me.",
            "f": "Please say hello to me in one short sentence.",
            "p": "Please check on the build server and tell me in two short sentences whether it looks healthy.",
            "w": "Please say hello to me in one short sentence, and then",
            "u": "When you are finished with that, please also say the word mango, and then tell me one fun fact about lighthouses.",
        ]
        var principal = settings.voice
        principal.voice = "female_a"
        let synth = HTTPSpeechSynthesizer(config: { principal })
        for (key, text) in lines {
            let audio = try await synth.prepare(text).audio()
            var pcm = Data()
            for try await chunk in audio.chunks { pcm.append(chunk) }
            utterances[key] = resampleS16(pcm, from: audio.sampleRate, to: 16000)
            log.line("setup", String(format: "utterance '%@' synthesized: %.2fs \"%@\"", key, Double(utterances[key]!.count) / 32000, text))
        }

        // Fragmented speech: synthesized pieces joined by silences, like a principal pausing on "uh". The silences
        // are longer than pauseMs (3.2 s), so each piece is its own utterance, and short enough to land within the
        // 1.5 s mid-sentence hold, so the hold and merge logic has to join them.
        let pieces: [String: [(String, Double)]] = [
            // i-idle and i-hold-short run with a 1.5 s pause (the mid-sentence hold only applies below 2.5 s); i-hold runs
            // in manual mode (m) at the default pause.
            "i-idle": [("Although I don't see the mock-up that we wanted with", 1.8), ("uh", 1.8), ("all of the different voice controls in the window.", 0)],
            "i-hold-short": [("Although I don't see the mock-up that we wanted with", 1.8), ("all of the different voice controls in the window.", 0)],
            "i-hold": [("Although I don't see the mock-up that we wanted with", 4.1), ("all of the different voice controls in the window.", 0)],
            "i-busy": [("When you finish, please look at the mock-up that we wanted with", 3.8), ("uh", 3.8), ("all of the voice controls.", 3.8), ("And also say the word mango.", 0)],
            // (n): a thinking pause inside one thought; played over a steady noise bed. Edges trimmed so the pause is exact.
            "n": [("Please say hello to me in one short sentence.", 2.8), ("And then tell me one fact about lighthouses, in a single sentence.", 0)],
        ]
        for (key, parts) in pieces {
            var pcm = Data()
            for (text, pause) in parts {
                let audio = try await synth.prepare(text).audio()
                var raw = Data()
                for try await chunk in audio.chunks { raw.append(chunk) }
                let piece = resampleS16(raw, from: audio.sampleRate, to: 16000)
                pcm.append(key == "n" ? trimSilence(piece) : piece)
                pcm.append(Data(count: Int(pause * 16000) * 2))
            }
            utterances[key] = pcm
            log.line("setup", String(format: "utterance '%@' synthesized: %.2fs %@", key, Double(pcm.count) / 32000, parts.map { "\"\($0.0)\" +\($0.1)s" }.joined(separator: " ")))
        }

        let holders = CoreAudioMicHolders().otherCapturers()
        log.line("setup", "mic holders now (read-only CoreAudio check): \(holders.isEmpty ? "none" : holders.map { "\($0.pid) \($0.path)\($0.isAgentVoice ? " [agent-voice]" : "")" }.joined(separator: "; "))")

        output = FileAudioOutput(wavPath: log.dir + "/playback.wav", clock: { [log] in log.ms }, log: { [log] in log.line("playback", $0) })
        input = FileAudioInput(log: { [log] in log.line("mic", $0) })
        let voiceConfig = settings.voice
        controller = ConversationController(settings: settings, backend: appClient, synth: HTTPSpeechSynthesizer(config: { [settings] in settings!.voice }),
                                            output: output, input: input, micCheck: nil, chiefPollInterval: 2,
                                            preflight: [ServiceChecks.speech(settings.voice), ServiceChecks.recognition(settings.voice)],
                                            partialsProbe: { await ServiceChecks.partialsAdvertised(voiceConfig) },
                                            log: { [weak self, log] line in log.line("app", line); self?.appLines.append((log.ms, line)) })
        pill.attach(controller)
        pill.onHistory = { [log] line in log.append("pill.log", String(format: "+%.3fs %@\n", log.ms / 1000, line)) }
        controller.onStatus = { [log, pill] s in
            log.append("status.log", String(format: "+%.3fs %@\n", log.ms / 1000, s.line))
            pill.update(status: s)
        }
        pillTicker = Task { [pill] in
            while !Task.isCancelled { pill.tick(); try? await Task.sleep(nanoseconds: 50_000_000) }
        }
        await controller.start()
        log.line("setup", "controller phase=\(controller.status.phase) running=\(controller.status.running) error=\(controller.status.lastError ?? "none")")
        guard controller.status.running && controller.status.phase == "ready" else { throw ClientError("controller did not become ready") }
        _ = await waitFor("controller connected", timeout: 15) { controller.status.connection == "connected" }
        _ = await waitFor("session title", timeout: 5) { controller.status.targetTitle != nil }
        log.line("setup", "window would show: Session: \(controller.status.targetName ?? "-") | \(controller.status.line)")
        // Let the onset grace period after the mic goes live pass.
        try? await Task.sleep(nanoseconds: 1_500_000_000)
    }

    // MARK: Helpers

    var target: String { controller.status.target ?? "" }

    /// Wait until the session is idle and all speech has played.
    func settle(_ session: String, timeout: TimeInterval = 120) async {
        _ = await waitFor("session idle and playback finished", timeout: timeout) {
            !controller.status.busy && !controller.speaker.active && !input.injecting
        }
        // Idle according to the server too (a queued message can start another turn).
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if let active = try? await client.activeSessions(), !active.contains(session), !controller.speaker.active { break }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        if controller.speaker.active { _ = await waitFor("playback finished", timeout: 60) { !controller.speaker.active } }
    }

    func say(_ key: String) { input.inject(utterances[key]!, label: key) }

    func otherClientPrompt(_ session: String, _ text: String, delivery: BusyDelivery? = nil) async throws {
        try await client.prompt(sessionID: session, text: text, delivery: delivery)
        log.line("other-client", "posted into \(session.suffix(6))\(delivery.map { " delivery=\($0.rawValue)" } ?? ""): \(text.prefix(90))")
    }

    func blocks(_ session: String, after: Double) -> [String] {
        observer.events(session, "session.text.ended", after: after).map(\.event.blockKey)
    }

    func records(_ blocks: [String]) -> [FileAudioOutput.Record] { output.records.filter { blocks.contains($0.label) } }

    func appLogLines(after: Double) -> [String] { appLines.filter { $0.0 >= after }.map(\.1) }
    var appLines: [(Double, String)] = []

    let toolTask = "Read the files a.txt, b.txt, c.txt, d.txt and e.txt in the current directory, ONE file per tool call, one at a time, in that order. Then read all five again the same way. Finally reply in one sentence with the total number of apples."
    let toolTaskLong = "Read the files a.txt, b.txt, c.txt, d.txt and e.txt in the current directory, ONE file per tool call, one at a time, in that order. Then read all five again the same way, and then a third time. Finally reply in one sentence with the total number of apples."
    let earlyTextTask = "Before you use any tool, first write this exact sentence as your opening text: \"I am going to read five small files for you now, one at a time, and then I will report back with a short and careful summary.\" Then read a.txt, b.txt, c.txt, d.txt and e.txt in the current directory, ONE file per tool call, one at a time. Then read them all again the same way. Finally write three plain sentences summarizing the fruit counts."

    // MARK: Scenarios

    func scenarioA() async throws {
        log.line("scenario", "=== (a) idle utterance becomes a normal message and the reply is spoken")
        let s = created[0]
        let t = log.ms
        say("a")
        let posted = await waitFor("utterance posted", timeout: 30) { appLogLines(after: t).contains { $0.contains("post -> \(s) delivery=none") } }
        _ = await waitFor("turn finished", timeout: 90) { !observer.events(s, "session.execution.succeeded", after: t).isEmpty }
        await settle(s)
        let enq = observer.events(s, "session.inbox.enqueued", after: t).first
        let enqText = ((enq?.event.data["item"] as? [String: Any])?["payload"] as? [String: Any])?["text"] as? String ?? ""
        let recs = records(blocks(s, after: t))
        check("a", posted && enqText.lowercased().contains("sky") && !recs.isEmpty && recs.allSatisfy { $0.outcome == "played" },
              "posted with no delivery=\(posted); server received \"\(enqText)\"; \(recs.count) sentence(s) played, outcomes \(recs.map(\.outcome)), \(String(format: "%.1f", recs.reduce(0) { $0 + $1.seconds }))s of audio")
    }

    func scenarioB() async throws {
        log.line("scenario", "=== (b) utterance while busy goes in with the configured delivery (queue, then steer)")
        let s = created[0]
        for (delivery, key) in [(BusyDelivery.queue, "queue"), (.steer, "steer")] {
            controller.setBusyDelivery(delivery)
            let t = log.ms
            try await otherClientPrompt(s, toolTaskLong)
            _ = await waitFor("first tool call", timeout: 60) { !observer.events(s, "session.tool.called", after: t).isEmpty }
            let busyAtSay = controller.status.busy
            say(key)
            let posted = await waitFor("utterance posted", timeout: 30) { appLogLines(after: t).contains { $0.contains("post -> \(s) delivery=\(delivery.rawValue)") } }
            _ = await waitFor("inbox enqueued with delivery", timeout: 10) {
                observer.events(s, "session.inbox.enqueued", after: t).contains { ($0.event.data["item"] as? [String: Any])?["delivery"] as? String == delivery.rawValue }
            }
            let enq = observer.events(s, "session.inbox.enqueued", after: t).filter { ($0.event.data["item"] as? [String: Any])?["delivery"] as? String == delivery.rawValue }
            let succeededBefore = observer.events(s, "session.execution.succeeded", after: t).first?.at
            let stillBusy = enq.first.map { e in succeededBefore.map { e.at < $0 } ?? true } ?? false
            await settle(s)
            let delivered = observer.events(s, "session.inbox.delivered", after: t).count
            check("b-\(delivery.rawValue)", busyAtSay && posted && !enq.isEmpty && stillBusy,
                  "busy when spoken=\(busyAtSay); posted delivery=\(delivery.rawValue): \(posted); server enqueued \(enq.count) item(s) with delivery=\(delivery.rawValue) while the turn was running=\(stillBusy); inbox.delivered events in this phase: \(delivered)")
        }
        controller.setBusyDelivery(.queue)
    }

    func scenarioC() async throws {
        log.line("scenario", "=== (c) another client's message while a reply plays neither stops nor skips it; its reply plays after")
        let s = created[0]
        let t = log.ms
        try await otherClientPrompt(s, "Write eight plain sentences about lighthouses, one paragraph, no markdown, no lists.")
        let firstBlocks = await waitForPlayback(s, after: t)
        guard let b1 = firstBlocks else { check("c", false, "reply 1 never started playing"); return }
        _ = await waitFor("two sentences into reply 1", timeout: 60) { output.records.filter { $0.label == b1 }.count >= 2 }
        let tLead = log.ms
        let queuedAtLead = controller.speaker.queuedCount
        try await otherClientPrompt(s, "Lead update for the chief: reply with exactly two short sentences about harbors.")
        await settle(s)
        let lateBlocks = blocks(s, after: tLead)
        let r1 = output.records.filter { $0.label == b1 }
        let r2 = records(lateBlocks)
        let silenced = appLogLines(after: t).filter { $0.contains("playback silenced") }
        let r1End = r1.compactMap(\.ended).max() ?? 0
        let r2Start = r2.map(\.started).min() ?? 0
        let r2DuringR1 = !r2.isEmpty && observer.events(s, "session.text.ended", after: tLead).first.map { $0.at < r1End } ?? false
        check("c", r1.count >= 3 && r1.allSatisfy { $0.outcome == "played" } && silenced.isEmpty && !r2.isEmpty && r2.allSatisfy { $0.outcome == "played" } && r2Start >= r1End - 1,
              "reply 1 [\(b1)]: \(r1.count) sentences, outcomes \(r1.map(\.outcome)), \(queuedAtLead) still queued when the lead posted at +\(String(format: "%.1f", tLead / 1000))s; lead reply \(lateBlocks): \(r2.count) sentences, outcomes \(r2.map(\.outcome)), first started +\(String(format: "%.1f", r2Start / 1000))s, reply 1 ended +\(String(format: "%.1f", r1End / 1000))s; lead reply text arrived while reply 1 was still playing=\(r2DuringR1); playback-silenced lines=\(silenced.count)")
    }

    /// The first text block of the session after `after` that starts playing; returns its block key.
    func waitForPlayback(_ s: String, after: Double, timeout: TimeInterval = 90) async -> String? {
        var key: String?
        _ = await waitFor("reply playback", timeout: timeout) {
            let bs = blocks(s, after: after)
            key = output.records.first { bs.contains($0.label) && $0.started >= after }?.label
            return key != nil
        }
        return key
    }

    func scenarioD() async throws {
        log.line("scenario", "=== (d) barge-in mid-playback stops playback and the turn still finishes")
        let s = created[0]
        let t = log.ms
        try await otherClientPrompt(s, earlyTextTask)
        let b = await waitForPlayback(s, after: t)
        let busyAtBarge = controller.status.busy && observer.events(s, "session.execution.succeeded", after: t).isEmpty
        guard let b else { check("d", false, "no playback during the turn"); return }
        let tSay = log.ms
        say("barge")
        _ = await waitFor("barge-in", timeout: 10) { appLogLines(after: tSay).contains { $0.contains("barge-in") } }
        let stopped = await waitFor("playback stopped", timeout: 5) { output.records.contains { $0.label == b && $0.outcome == "stopped" } }
        _ = await waitFor("turn ended", timeout: 120) {
            !observer.events(s, "session.execution.succeeded", after: t).isEmpty || !observer.events(s, "session.execution.interrupted", after: t).isEmpty
        }
        let succeeded = observer.events(s, "session.execution.succeeded", after: t).first
        let interrupted = observer.events(s, "session.execution.interrupted", after: t)
        let tBarge = appLines.first { $0.0 >= tSay && $0.1.contains("barge-in") }?.0 ?? 0
        await settle(s)
        let interruptCalls = appLogLines(after: t).filter { $0.contains("interrupt ") }
        let after = output.records.filter { $0.started > tBarge }
        check("d", busyAtBarge && stopped && succeeded != nil && interrupted.isEmpty && interruptCalls.isEmpty,
              "turn running when barge-in spoken=\(busyAtBarge); barge-in at +\(String(format: "%.2f", tBarge / 1000))s; block [\(b)] stopped=\(stopped); execution.succeeded at +\(String(format: "%.2f", (succeeded?.at ?? 0) / 1000))s, interrupted events=\(interrupted.count), interrupt calls=\(interruptCalls.count); sentences played after barge-in (later text): \(after.count) \(after.map(\.outcome))")
    }

    func scenarioE() async throws {
        log.line("scenario", "=== (e) Stop interrupts the turn and clears playback")
        let s = created[0]
        let t = log.ms
        try await otherClientPrompt(s, earlyTextTask)
        let b = await waitForPlayback(s, after: t)
        let busy = controller.status.busy
        let tStop = log.ms
        await controller.stopReply()
        let interrupted = await waitFor("execution.interrupted", timeout: 15) { !observer.events(s, "session.execution.interrupted", after: t).isEmpty }
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        let stopped = output.records.contains { $0.label == b && $0.outcome == "stopped" }
        let afterStop = output.records.filter { $0.started > tStop }
        let line = appLogLines(after: tStop).first { $0.contains("interrupt ") } ?? "(none)"
        check("e", busy && interrupted && stopped && afterStop.isEmpty && !controller.speaker.active,
              "busy at Stop=\(busy); \(line); execution.interrupted seen=\(interrupted); playing block [\(b ?? "-")] stopped=\(stopped); sentences started after Stop: \(afterStop.count); speaker idle=\(!controller.speaker.active)")
        await settle(s)
    }

    func scenarioH() async throws {
        log.line("scenario", "=== (h) an interrupt from another client (like OpenChamber's stop button) stops playback and clears the queue")
        let s = created[0]
        let t = log.ms
        try await otherClientPrompt(s, earlyTextTask)
        let b = await waitForPlayback(s, after: t)
        let busy = controller.status.busy
        let tInt = log.ms
        let interruptedByOther = try await client.interrupt(sessionID: s)
        log.line("other-client", "POST interrupt \(s.suffix(6)) -> interrupted=\(interruptedByOther)")
        let seen = await waitFor("execution.interrupted", timeout: 15) { !observer.events(s, "session.execution.interrupted", after: t).isEmpty }
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        let stopped = output.records.contains { $0.label == b && $0.outcome == "stopped" }
        let afterInt = output.records.filter { $0.started > tInt }
        let silenced = appLogLines(after: tInt).contains { $0.contains("playback silenced (turn interrupted)") }
        let appCalls = appLogLines(after: t).filter { $0.hasPrefix("interrupt ") }
        check("h", busy && interruptedByOther && seen && stopped && silenced && afterInt.isEmpty && appCalls.isEmpty && !controller.speaker.active,
              "busy=\(busy); other client interrupted=\(interruptedByOther); execution.interrupted seen=\(seen); app logged 'playback silenced (turn interrupted)'=\(silenced); playing block [\(b ?? "-")] stopped=\(stopped); sentences started after the interrupt: \(afterInt.count); interrupt calls by the app: \(appCalls.count); speaker idle=\(!controller.speaker.active)")
        await settle(s)
    }

    /// User messages the server admitted into `s` after `t`.
    func userMessages(_ s: String, after t: Double) -> [(text: String, delivery: String)] {
        observer.events(s, "session.inbox.enqueued", after: t).compactMap { e in
            guard let item = e.event.data["item"] as? [String: Any], item["type"] as? String == "user" else { return nil }
            return (((item["payload"] as? [String: Any])?["text"] as? String) ?? "", item["delivery"] as? String ?? "?")
        }
    }

    func scenarioI() async throws {
        log.line("scenario", "=== (i) fragmented speech (pauses, \"uh\") arrives as one message, idle and busy")
        let s = created[0]
        // A 1.5 s pause for the two fragment checks: the mid-sentence hold (1.5 s) only applies below a 2.5 s pause.
        var shortPause = controller.voice
        shortPause.pauseMs = 1500
        controller.setVoiceConfig(shortPause)
        defer { var v = controller.voice; v.pauseMs = settings.voice.pauseMs; controller.setVoiceConfig(v) }
        for key in ["i-idle", "i-hold-short"] {
            let t = log.ms
            say(key)
            _ = await waitFor("utterance injected and sent", timeout: 40) { !input.injecting && !appLogLines(after: t).filter { $0.hasPrefix("post -> \(s)") }.isEmpty }
            await settle(s)
            let msgs = userMessages(s, after: t)
            let holds = appLogLines(after: t).filter { $0.hasPrefix("hold (") }
            let heard = appLogLines(after: t).filter { $0.hasPrefix("heard: ") }
            let text = msgs.first?.text.lowercased() ?? ""
            check(key.replacingOccurrences(of: "-short", with: ""), msgs.count == 1 && text.contains("mock") && text.contains("window"),
                  "\(heard.count) utterance(s) recognized \(heard.map { $0.replacingOccurrences(of: "heard: ", with: "") }); \(holds.count) hold(s); server received \(msgs.count) message(s): \(msgs.map { "[\($0.delivery)] \($0.text)" })")
        }
        var v = controller.voice; v.pauseMs = settings.voice.pauseMs; controller.setVoiceConfig(v) // the default pause again
        let t = log.ms
        try await otherClientPrompt(s, toolTaskLong)
        _ = await waitFor("first tool call", timeout: 60) { !observer.events(s, "session.tool.called", after: t).isEmpty }
        let tSay = log.ms
        let busy = controller.status.busy
        say("i-busy")
        _ = await waitFor("utterance injected and sent", timeout: 60) { !input.injecting && !appLogLines(after: tSay).filter { $0.hasPrefix("post -> \(s)") }.isEmpty }
        await settle(s)
        let msgs = userMessages(s, after: tSay)
        let heard = appLogLines(after: tSay).filter { $0.hasPrefix("heard: ") }
        let posts = appLogLines(after: tSay).filter { $0.hasPrefix("post -> ") }
        let text = msgs.first?.text.lowercased() ?? ""
        // Posting (at turn end or after the merge quiet) never cuts the principal off: it comes at least
        // turnEndQuietMs (2 s) after their last utterance ended, and not while they are speaking.
        let postAt = appLines.first { $0.0 >= tSay && $0.1.hasPrefix("post -> \(s)") }?.0 ?? 0
        let lastHeardAt = appLines.last { $0.0 >= tSay && $0.0 <= postAt && $0.1.hasPrefix("heard: ") }?.0 ?? 0
        let lastOnset = appLines.last { $0.0 >= tSay && $0.0 <= postAt && $0.1.hasPrefix("speech onset") }?.0 ?? 0
        let quietBeforePost = postAt - lastHeardAt
        let notCutOff = postAt > 0 && lastOnset < lastHeardAt && quietBeforePost >= controller.app.turnEndQuietMs - 30
        check("i-busy", busy && msgs.count == 1 && text.contains("mock") && text.contains("mango") && notCutOff,
              "busy when spoken=\(busy); \(heard.count) utterance(s) recognized; posts: \(posts); quiet before the post \(Int(quietBeforePost)) ms (needs >= \(Int(controller.app.turnEndQuietMs)), not mid-utterance=\(lastOnset < lastHeardAt)); server received \(msgs.count) message(s): \(msgs.map { "[\($0.delivery)] \($0.text)" })")
    }

    func scenarioP() async throws {
        log.line("scenario", "=== (p) live words: ?partials=1 against the live recognition server; the pill sees partials before the final, the final text is what is sent, the card grows and shrinks")
        let s = created[0]
        let advertised = await ServiceChecks.partialsAdvertised(settings.voice)
        // Start from the resting pill (the card from the previous scenario may still be open), so growing is observable.
        _ = await waitFor("card shrinks", timeout: 20) { !pill.expanded }
        let t = log.ms
        // The pill's clock is wall time; history timestamps are in its own clock, so mark by index too.
        let h0 = pill.history.count
        say("p")
        let posted = await waitFor("utterance posted", timeout: 40) { appLogLines(after: t).contains { $0.hasPrefix("post -> \(s)") } }
        _ = await waitFor("turn finished", timeout: 90) { !observer.events(s, "session.execution.succeeded", after: t).isEmpty }
        await settle(s)
        // Quiet after the reply: the card shrinks back.
        let shrank = await waitFor("card shrinks after quiet", timeout: pill.shrinkAfterMs / 1000 + 5) { !pill.expanded }
        let hist = Array(pill.history.dropFirst(h0)).map(\.1)
        let live = hist.enumerated().filter { $0.element.hasPrefix("you live: ") }
        let finals = hist.enumerated().filter { $0.element.hasPrefix("you final: ") }
        let greyTail = live.contains { !($0.element.components(separatedBy: " | ").last ?? "").isEmpty }
        let whiteGrew = live.contains { !(($0.element.dropFirst("you live: ".count).components(separatedBy: " | ").first ?? "").isEmpty) }
        let firstLive = live.first?.offset, firstFinal = finals.first?.offset
        let heard = appLogLines(after: t).filter { $0.hasPrefix("heard: ") }.map { String($0.dropFirst("heard: ".count)) }
        let msgs = userMessages(s, after: t)
        let partialTexts = Set(live.map { $0.element })
        let sentIsFinal = msgs.count == 1 && heard.count >= 1 && msgs[0].text == VoicePost.transportText(heard.joined(separator: " "))
        let liveOn = appLogLines(after: 0).contains { $0.contains("live words on (?partials=1)") }
        // Caption in step with playback: the pill's "chief speaking" entries match the speaker's sentence starts, in order.
        let starts = appLogLines(after: t).filter { $0.hasPrefix("speak start [") }.map { String($0.split(separator: "]", maxSplits: 1).last ?? "").trimmingCharacters(in: .whitespaces) }
        let shown = hist.filter { $0.hasPrefix("chief speaking: ") }.map { String($0.dropFirst("chief speaking: ".count)) }
        let inStep = !starts.isEmpty && starts.count == shown.count && zip(starts, shown).allSatisfy { $0.hasPrefix(String($1.prefix(60))) || $1.hasPrefix(String($0.prefix(60))) }
        let grew = hist.contains { $0.hasPrefix("grow (") }
        check("p", advertised && liveOn && posted && firstLive != nil && firstFinal != nil && firstLive! < firstFinal! && greyTail && whiteGrew && sentIsFinal && inStep && grew && shrank,
              "/health advertises partials=\(advertised); app requested ?partials=1=\(liveOn); \(live.count) live update(s) before the final=\(firstLive.map { f in firstFinal.map { f < $0 } ?? false } ?? false) (first: \"\(live.first?.element ?? "-")\", last: \"\(live.last?.element ?? "-")\"); grey tail seen=\(greyTail), white part seen=\(whiteGrew); final heard \(heard); server received \(msgs.map { "[\($0.delivery)] \($0.text)" }) == final=\(sentIsFinal) (distinct partial snapshots \(partialTexts.count)); chief captions in step with playback=\(inStep) (\(shown.count) shown / \(starts.count) started); grew=\(grew), shrank after quiet=\(shrank)")
    }

    func scenarioM() async throws {
        log.line("scenario", "=== (m) manual send: nothing is posted at pauses or complete sentences until Send (simulated button press)")
        let s = created[0]
        controller.setSendMode(.manual)
        defer { controller.setSendMode(.auto) }
        let t = log.ms
        let h0 = pill.history.count
        say("i-hold")
        _ = await waitFor("first piece heard", timeout: 40) { appLogLines(after: t).filter { $0.hasPrefix("heard: ") }.count >= 2 && !input.injecting }
        say("f")
        _ = await waitFor("second piece heard", timeout: 40) { appLogLines(after: t).filter { $0.hasPrefix("heard: ") }.count >= 3 && !input.injecting }
        // Longer than pause + hold + merge + turn-end quiet together: auto mode would have posted by now.
        try? await Task.sleep(nanoseconds: 7_000_000_000)
        let postsBeforeSend = appLogLines(after: t).filter { $0.hasPrefix("post -> ") }
        let holding = controller.status.holding ?? ""
        let pillHolding = pill.you.holding && pill.status.manualSend
        let tSend = log.ms
        controller.send() // what the Send button and the hotkey call
        let posted = await waitFor("posted after Send", timeout: 10) { appLogLines(after: tSend).contains { $0.hasPrefix("post -> \(s)") } }
        _ = await waitFor("turn finished", timeout: 90) { !observer.events(s, "session.execution.succeeded", after: tSend).isEmpty }
        await settle(s)
        let msgs = userMessages(s, after: t)
        let text = msgs.first?.text.lowercased() ?? ""
        let holds = pill.history.dropFirst(h0).filter { $0.1.hasPrefix("holding: ") }.count
        let played = output.records.filter { $0.started > tSend }.count
        check("m", postsBeforeSend.isEmpty && holding.lowercased().contains("mock") && holding.lowercased().contains("hello") && pillHolding && posted
              && msgs.count == 1 && text.contains("mock") && text.contains("hello") && played > 0,
              "posts before Send: \(postsBeforeSend.count); holding before Send: \"\(holding)\" (pill showed Holding with Send=\(pillHolding), \(holds) holding update(s)); after Send posted=\(posted); server received \(msgs.map { "[\($0.delivery)] \($0.text)" }); reply sentences played: \(played)")
    }

    func scenarioW() async throws {
        log.line("scenario", "=== (w) the wait: a mid-sentence thought with the default pause goes in with no extra hold, with a countdown, then Sent and the chief thinking")
        let s = created[0]
        let pauseMs = controller.voice.pauseMs
        let t = log.ms
        let h0 = pill.history.count
        say("w")
        let posted = await waitFor("utterance posted", timeout: 60) { appLogLines(after: t).contains { $0.hasPrefix("post -> \(s)") } }
        _ = await waitFor("turn finished", timeout: 90) { !observer.events(s, "session.execution.succeeded", after: t).isEmpty }
        await settle(s)
        let lines = appLines.filter { $0.0 >= t }
        let ended = lines.first { $0.1.hasPrefix("utterance ended") }?.0 ?? 0
        let postAt = lines.first { $0.1.hasPrefix("post -> \(s)") }?.0 ?? 0
        let held = lines.contains { $0.1.hasPrefix("hold (mid-sentence)") }
        let hist = Array(pill.history.dropFirst(h0)).map(\.1)
        let countdowns = hist.filter { $0.hasPrefix("countdown ") }
        let sent = hist.contains("sent")
        let thinking = hist.contains("thinking")
        let firstChief = hist.firstIndex { $0.hasPrefix("chief speaking") }
        let thinkingIdx = hist.firstIndex(of: "thinking")
        let order = (thinkingIdx == nil || firstChief == nil || thinkingIdx! < firstChief!)
        let gap = postAt - ended
        // The end of the utterance to the send: just the final transcript (no 1.5 s hold on top of the pause).
        check("w", pauseMs >= AppSettings.holdBelowPauseMs && posted && !held && ended > 0 && gap >= 0 && gap < 600
              && countdowns.contains("countdown 3") && countdowns.contains("countdown 1") && sent && order,
              "pause \(Int(pauseMs)) ms; no mid-sentence hold=\(!held); utterance end to post \(Int(gap)) ms; countdown cue \(countdowns); Sent=\(sent); thinking=\(thinking) before the first spoken sentence=\(order); server received \(userMessages(s, after: t).map(\.text))")
    }

    /// Drop near-silent 20 ms frames (RMS under 0.02) from both ends.
    func trimSilence(_ pcm: Data) -> Data {
        let frame = 640
        var first = 0, last = pcm.count / frame
        func loud(_ i: Int) -> Bool { TurnTaker.rms(pcm.subdata(in: i * frame..<(i + 1) * frame)) > 0.02 }
        while first < last && !loud(first) { first += 1 }
        while last > first && !loud(last - 1) { last -= 1 }
        return pcm.subdata(in: first * frame..<last * frame)
    }

    func scenarioN() async throws {
        log.line("scenario", "=== (n) background noise cannot hold an utterance open: speech over a steady noise bed (above the old fixed threshold) with a thinking pause, with live words and without; ends and sends as one message within about pauseMs + 0.5 s of the last word")
        let s = created[0]
        let noise = 0.017
        var results: [String] = []
        var allOK = true
        for live in [true, false] {
            // Voice restarts with the noise on, so the floor is calibrated in its first second, as in real use.
            controller.app.livePartials = live
            controller.stop()
            input.noiseRMS = noise
            await controller.start()
            _ = await waitFor("controller ready", timeout: 30) { controller.status.running && controller.status.phase == "ready" && controller.status.connection == "connected" }
            try? await Task.sleep(nanoseconds: 2_500_000_000) // calibration (about 1 s) and the onset grace
            let floor = controller.noiseFloorForLog
            let pauseMs = controller.voice.pauseMs
            let speechMs = Double(utterances["n"]!.count) / 32.0
            let t = log.ms
            let h0 = pill.history.count
            say("n")
            let tStart = log.ms
            let posted = await waitFor("utterance posted", timeout: 60) { appLogLines(after: t).contains { $0.hasPrefix("post -> \(s)") } }
            _ = await waitFor("turn finished", timeout: 90) { !observer.events(s, "session.execution.succeeded", after: t).isEmpty }
            await settle(s)
            let lines = appLines.filter { $0.0 >= t }
            let postAt = lines.first { $0.1.hasPrefix("post -> \(s)") }?.0 ?? 0
            let lastWordAt = tStart + speechMs
            let latency = postAt - lastWordAt
            let msgs = userMessages(s, after: t)
            let text = msgs.first?.text.lowercased() ?? ""
            let heard = lines.filter { $0.1.hasPrefix("heard: ") }.count
            let liveUpdates = pill.history.dropFirst(h0).filter { $0.1.hasPrefix("you live") }.count
            let level = lines.last { $0.1.hasPrefix("mic: rms") && $0.1.contains("noise floor") }?.1 ?? "(no mic line)"
            let ok = posted && floor > 0.012 && msgs.count == 1 && heard == 1 && text.contains("hello") && text.contains("lighthouse")
                && latency >= 0 && latency <= pauseMs + 700 && (live ? liveUpdates > 0 : liveUpdates == 0 && !controller.livePartials)
            allOK = allOK && ok
            results.append("live words \(live ? "on" : "off"): floor \(String(format: "%.4f", floor)) (noise bed \(noise)); last word to post \(Int(latency)) ms (pauseMs \(Int(pauseMs)), limit \(Int(pauseMs + 700))); \(heard) utterance(s) heard, \(msgs.count) message(s) \(msgs.map(\.text)); live updates \(liveUpdates); last mic line: \(level)")
        }
        input.noiseRMS = 0
        controller.app.livePartials = true
        controller.stop()
        await controller.start()
        _ = await waitFor("controller ready", timeout: 30) { controller.status.running && controller.status.phase == "ready" && controller.status.connection == "connected" }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        check("n", allOK, results.joined(separator: " | "))
    }

    func scenarioU() async throws {
        log.line("scenario", "=== (u) Mute mic mid-utterance sends the words already in motion as one message: idle chief (normal message at once), busy chief (queued at once, delivered at turn end)")
        let s = created[0]
        var results: [String] = []
        var allOK = true
        for busy in [false, true] {
            let t = log.ms
            if busy {
                try await otherClientPrompt(s, toolTaskLong)
                _ = await waitFor("first tool call", timeout: 60) { !observer.events(s, "session.tool.called", after: t).isEmpty }
            }
            let busyAtMute = controller.status.busy
            let tSay = log.ms
            say("u")
            // Mute in the middle of the sentence: after the utterance opened and some seconds of it have been spoken.
            _ = await waitFor("utterance in progress", timeout: 20) { controller.utteranceInProgress }
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            let inProgress = controller.utteranceInProgress
            let tMute = log.ms
            controller.setMicMuted(true)
            let posted = await waitFor("posted after mute", timeout: 15) { appLogLines(after: tMute).contains { $0.hasPrefix("post -> \(s)") } }
            let postAt = appLines.first { $0.0 >= tMute && $0.1.hasPrefix("post -> \(s)") }
            let heard = appLines.first { $0.0 >= tMute && $0.1.hasPrefix("heard: ") }?.1.dropFirst("heard: ".count).description ?? ""
            // Nothing more is taken while muted: the rest of the recording is ignored; no second message follows.
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            let stillMuted = controller.status.micMuted
            if busy { _ = await waitFor("turn finished", timeout: 150) { !observer.events(s, "session.execution.succeeded", after: t).isEmpty } }
            controller.setMicMuted(false)
            await settle(s)
            let msgs = userMessages(s, after: tSay)
            let delivery = busy ? "queue" : "?"
            let enq = observer.events(s, "session.inbox.enqueued", after: tSay).filter { ($0.event.data["item"] as? [String: Any])?["type"] as? String == "user" }
            let enqDelivery = (enq.first?.event.data["item"] as? [String: Any])?["delivery"] as? String ?? "none"
            let text = msgs.first?.text ?? ""
            let promptly = postAt.map { $0.0 - tMute < 2500 } ?? false
            let reason = postAt.map { $0.1.contains("(mic muted)") } ?? false
            let kindOK = busy ? (postAt?.1.contains("delivery=queue") == true && enqDelivery == "queue") : (postAt?.1.contains("delivery=none") == true)
            let ok = inProgress && posted && promptly && reason && kindOK && stillMuted && msgs.count == 1 && !text.isEmpty
                && text.lowercased().contains("finished") && text == heard.trimmingCharacters(in: .whitespaces) && !(text.lowercased().contains("lighthouse"))
            allOK = allOK && ok
            results.append("\(busy ? "busy chief" : "idle chief"): busy at mute=\(busyAtMute), utterance in progress at mute=\(inProgress); posted \(postAt.map { Int($0.0 - tMute) } ?? -1) ms after the mute (\(postAt.map { String($0.1.prefix(80)) } ?? "none")); the final heard == the message=\(text == heard.trimmingCharacters(in: .whitespaces)); server received \(msgs.map { "[\($0.delivery)] \($0.text)" }); stayed muted=\(stillMuted); delivery seen by the server=\(busy ? enqDelivery : delivery)")
        }
        check("u", allOK, results.joined(separator: " | "))
    }

    func scenarioF() async throws {
        log.line("scenario", "=== (f) changing chief.json to another session makes the app follow it")
        let b = created[1]
        let t = log.ms
        try #"{"session": "\#(b)", "directory": "\#(sessionDirs[b]!)"}"#.write(toFile: chiefFile, atomically: true, encoding: .utf8)
        log.line("harness", "rewrote scratch chief.json -> \(b)")
        let switched = await waitFor("target switch", timeout: 10) { controller.status.target == b }
        let tSwitch = log.ms
        try? await Task.sleep(nanoseconds: 500_000_000)
        say("f")
        let posted = await waitFor("utterance posted to B", timeout: 30) { appLogLines(after: t).contains { $0.contains("post -> \(b)") } }
        let block = await waitForPlayback(b, after: t)
        await settle(b)
        let recs = output.records.filter { $0.label == block }
        check("f", switched && posted && !recs.isEmpty && recs.allSatisfy { $0.outcome == "played" },
              "followed chief.json to \(b) after \(String(format: "%.1f", (tSwitch - t) / 1000))s=\(switched); utterance posted to B=\(posted); B's reply [\(block ?? "-")] played: \(recs.count) sentence(s) \(recs.map(\.outcome))")
    }

    func scenarioG() async throws {
        log.line("scenario", "=== (g) event stream drop and reconnect resyncs busy state")
        let s = controller.status.target ?? created[1]
        let t = log.ms
        controller.dropConnection(holdOff: 6)
        _ = await waitFor("disconnected", timeout: 5) { controller.status.connection == "reconnecting" }
        try? await Task.sleep(nanoseconds: 500_000_000)
        let busyBefore = controller.status.busy
        try await otherClientPrompt(s, toolTask)
        _ = await waitFor("turn started (observer)", timeout: 20) { !observer.events(s, "session.execution.started", after: t).isEmpty }
        let busyWhileDown = controller.status.busy
        let resynced = await waitFor("resync busy=true", timeout: 20) { appLogLines(after: t).contains { $0.contains("resync (connected): \(s) busy=true") } }
        let busyAfter = controller.status.busy
        _ = await waitFor("turn ends", timeout: 120) { !observer.events(s, "session.execution.succeeded", after: t).isEmpty }
        let idleAfter = await waitFor("busy cleared", timeout: 5) { !controller.status.busy }
        check("g", !busyBefore && !busyWhileDown && resynced && busyAfter && idleAfter,
              "busy before drop=\(busyBefore); turn started while disconnected, app busy then=\(busyWhileDown); after reconnect resync busy=true logged=\(resynced), status busy=\(busyAfter); after execution.succeeded busy cleared=\(idleAfter)")
        await settle(s)
    }

    func run() async {
        do {
            try await setup()
            let scenarios: [(String, () async throws -> Void)] = [("a", scenarioA), ("b", scenarioB), ("c", scenarioC), ("d", scenarioD), ("e", scenarioE), ("h", scenarioH), ("i", scenarioI), ("p", scenarioP), ("w", scenarioW), ("n", scenarioN), ("u", scenarioU), ("m", scenarioM), ("f", scenarioF), ("g", scenarioG)]
            for (name, body) in scenarios where only.isEmpty || only.contains(name) {
                do { try await body() } catch { check(name, false, "error: \(error.localizedDescription)") }
            }
        } catch { log.line("FAIL", "setup: \(error.localizedDescription)") }
        await teardown()
    }

    func teardown() async {
        pillTicker?.cancel()
        controller?.stop()
        output?.writeWAV()
        observer?.stop()
        if let output {
            for r in output.records {
                log.append("playback.jsonl", String(format: "{\"label\":\"%@\",\"started_ms\":%.0f,\"ended_ms\":%.0f,\"audio_s\":%.2f,\"outcome\":\"%@\"}\n", r.label, r.started, r.ended ?? -1, r.seconds, r.outcome))
            }
        }
        await archive()
        var summary = "# fv-harness run \(log.dir)\n\nSessions: \(created.joined(separator: ", ")) (archived)\n\n"
        for (name, ok, detail) in results { summary += "- (\(name)) \(ok ? "PASS" : "FAIL"): \(detail)\n" }
        log.append("summary.md", summary)
        log.line("done", "\(results.filter { $0.1 }.count)/\(results.count) checks passed; logs in \(log.dir)")
    }

    func archive() async {
        guard !created.isEmpty else { return }
        do { let r = try await client.archive(created); log.line("teardown", "archived \(created): \(r.map { "\($0)" }?.prefix(200) ?? "")") }
        catch { log.line("teardown", "ARCHIVE FAILED for \(created): \(error.localizedDescription)") }
    }
}

// MARK: Entry

@MainActor
func main() async -> Int32 {
    let command = CommandLine.arguments.dropFirst().first ?? "help"
    switch command {
    case "mic-holders":
        let holders = CoreAudioMicHolders().otherCapturers()
        print(holders.isEmpty ? "No other process is capturing microphone input." : holders.map { "\($0.pid)\t\($0.isAgentVoice ? "agent-voice" : "other")\t\($0.path)" }.joined(separator: "\n"))
        return 0
    case "vad-compare":
        return await vadCompare(out: arg("--out") ?? projectDir + "/logs/vad-compare")
    case "render-stills":
        let out = arg("--out") ?? projectDir + "/logs/polish-stills"
        return renderStills(to: out)
    case "render-name-stills":
        return renderNameStills(to: arg("--out") ?? projectDir + "/logs/name-stills")
    case "render-error-stills":
        return renderErrorStills(to: arg("--out") ?? projectDir + "/logs/error-stills")
    case "render-cutin-stills":
        return renderCutInStills(to: arg("--out") ?? projectDir + "/logs/cutin-stills")
    case "render-motion":
        return renderMotion(to: arg("--out") ?? projectDir + "/logs/polish-stills/motion")
    case "render-icons":
        return renderIcons(to: arg("--out") ?? projectDir + "/logs/icon-options", appIcon: arg("--app-icon").flatMap(Int.init),
                           appIconDir: projectDir + "/app/Icon")
    case "run":
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let dir = arg("--log-dir") ?? projectDir + "/logs/harness-\(stamp)"
        let log = RunLog(dir: dir)
        let only = Set((arg("--only") ?? "").split(separator: ",").map(String.init))
        let harness = Harness(log: log, only: only)
        // Collect the controller's log lines for checks (in addition to run.log).
        let timeout = Double(arg("--timeout") ?? "1500") ?? 1500
        // Watchdog: a hard exit on a plain thread even if the main actor is stuck, after trying to archive.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            log.line("WATCHDOG", "run exceeded \(Int(timeout))s; archiving and exiting")
            await harness.archive()
            exit(2)
        }
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: timeout + 30)
            FileHandle.standardError.write(Data("WATCHDOG: hard exit\n".utf8))
            exit(3)
        }
        await harness.run()
        return harness.results.allSatisfy { $0.1 } && !harness.results.isEmpty ? 0 : 1
    default:
        print("usage: fv-harness run [--log-dir DIR] [--only a,b,c,d,e,h,i,p,w,n,u,m,f,g] [--timeout SECONDS] | fv-harness render-stills [--out DIR] | fv-harness render-name-stills [--out DIR] | fv-harness render-error-stills [--out DIR] | fv-harness render-motion [--out DIR] | fv-harness render-icons [--out DIR] [--app-icon N] | fv-harness mic-holders")
        return command == "help" ? 0 : 64
    }
}

Task { @MainActor in exit(await main()) }
dispatchMain()
