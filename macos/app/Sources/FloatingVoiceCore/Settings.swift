import Foundation

/// Voice settings, with the same keys and defaults as agent-voice (voice.mjs `defaults`, engine.mjs `loadConfig`).
/// ffmpeg/ffplay are not used: audio is native.
public struct VoiceConfig: Equatable, Sendable {
    public var asrUrl = ""
    public var ttsUrl = ""
    public var ttsModel = "tts-1"
    public var voice = "alloy"
    public var ttsStream = false
    public var asrApiKey: String?
    public var ttsApiKey: String?
    public var pauseMs = 1100.0
    public var threshold = 0.012
    public var duplex = true
    public var inputDevice = "default"
    public var outputDevice = "default"
    public var bargeInMs = 320.0
    public var onsetGraceMs = 1200.0
    public var bargeInAborts = false
    /// "auto" | "on" | "off"
    public var echoCancellation = "auto"
    /// "low" | "normal" | "high": how far above the room's noise floor speech must be to count as voice.
    public var sensitivity = "normal"
    public var sensitivityLevel: Sensitivity { Sensitivity(rawValue: sensitivity) ?? .normal }

    public init() {}

    /// echoCancellation: "auto" | "on" | "off" (booleans accepted). Unknown values fall back to auto.
    public static func echoSetting(_ value: Any?) -> String {
        if let b = value as? Bool { return b ? "on" : "off" }
        if let s = value as? String, s == "on" || s == "off" { return s }
        return "auto"
    }

    /// Apply a JSON object's keys over the current values. Unknown keys and wrong types are ignored.
    public mutating func apply(_ stored: [String: Any]) {
        func str(_ k: String) -> String? { stored[k] as? String }
        func num(_ k: String) -> Double? { (stored[k] as? NSNumber).flatMap { CFGetTypeID($0) == CFBooleanGetTypeID() ? nil : $0.doubleValue } }
        func bool(_ k: String) -> Bool? { (stored[k] as? NSNumber).flatMap { CFGetTypeID($0) == CFBooleanGetTypeID() ? $0.boolValue : nil } }
        if let v = str("asrUrl") { asrUrl = v }
        if let v = str("ttsUrl") { ttsUrl = v }
        if let v = str("ttsModel") { ttsModel = v }
        if let v = str("voice") { voice = v }
        if let v = bool("ttsStream") { ttsStream = v }
        if let v = str("asrApiKey") { asrApiKey = v }
        if let v = str("ttsApiKey") { ttsApiKey = v }
        if let v = num("pauseMs") { pauseMs = v }
        if let v = num("threshold") { threshold = v }
        if let v = bool("duplex") { duplex = v }
        if let v = str("inputDevice") { inputDevice = v } else if let v = str("device") { inputDevice = v }
        if let v = str("outputDevice") { outputDevice = v }
        if let v = num("bargeInMs") { bargeInMs = v }
        if let v = num("onsetGraceMs") { onsetGraceMs = v }
        if let v = bool("bargeInAborts") { bargeInAborts = v }
        if stored["echoCancellation"] != nil { echoCancellation = VoiceConfig.echoSetting(stored["echoCancellation"]) }
        if let v = str("sensitivity"), Sensitivity(rawValue: v) != nil { sensitivity = v }
    }
}

public enum BusyDelivery: String, Sendable { case steer, queue }

/// How held words are sent: after a natural pause ("auto"), or only when the principal presses Send ("manual").
public enum SendMode: String, Sendable { case auto, manual }

/// The app's own settings (~/.config/floating-voice/settings.json). Voice keys placed at the top level of that
/// file (same names as agent-voice's) override agent-voice's values for this app only.
public struct AppSettings: Sendable {
    /// "chief" follows ~/.chief-of-staff/chief.json; anything else is an explicit session id.
    public var target = "chief"
    public var chiefFile: String?
    public var busyDelivery: BusyDelivery = .queue
    public var sendMode: SendMode = .auto
    /// Global hotkey for Send in manual mode, e.g. "ctrl+option+space".
    public var sendHotkey = Hotkey.defaultSpec
    /// An utterance ending mid-sentence (no final punctuation, or a filler like "uh") waits this long for more speech.
    public var holdMidSentenceMs = 1500.0
    /// While the chief is busy (queue mode), utterances merge into one message posted after this much quiet.
    public var busyMergeQuietMs = 3000.0
    /// The mid-sentence hold (`holdMidSentenceMs`) only applies when the pause length is below this: with a patient
    /// pause (the default 3.2 s) the pause itself is the wait, and holding on top of it only stacks delays.
    public static let holdBelowPauseMs = 2500.0
    /// When the chief's turn ends with words merged, they post once the principal has been quiet this long.
    public var turnEndQuietMs = 2000.0
    /// Ask the recognition server for live words (`?partials=1`) when its /health advertises them.
    public var livePartials = true
    /// This app's end-of-utterance pause, used instead of agent-voice's unless the app's settings set `pauseMs`.
    public static let defaultPauseMs = 3200.0
    public init() {}
    public var followsChief: Bool { target == "chief" }
}

public struct LoadedSettings {
    public var app: AppSettings
    public var voice: VoiceConfig
    /// agent-voice file the voice settings came from (nil if none exists).
    public var voiceFile: String?
    public var appFile: String
    public var chiefFile: String
    /// The app's settings file exists but is not a JSON object (its keys were not applied).
    public var appFileUnreadable = false
}

public enum SettingsPaths {
    static func home(_ env: [String: String]) -> String { env["HOME"] ?? NSHomeDirectory() }
    static func configHome(_ env: [String: String]) -> String { env["XDG_CONFIG_HOME"] ?? (home(env) + "/.config") }

    /// agent-voice's candidates, in its order: opencode's file first, then Pi's.
    public static func agentVoiceFiles(_ env: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        if let explicit = env["FV_AGENT_VOICE_SETTINGS"] { return [explicit] }
        let pi = (env["PI_CODING_AGENT_DIR"] ?? home(env) + "/.pi/agent") + "/agent-voice.json"
        return [configHome(env) + "/opencode/agent-voice.json", pi]
    }
    public static func appFile(_ env: [String: String] = ProcessInfo.processInfo.environment) -> String {
        env["FV_SETTINGS"] ?? configHome(env) + "/floating-voice/settings.json"
    }
    public static func defaultChiefFile(_ env: [String: String] = ProcessInfo.processInfo.environment) -> String {
        home(env) + "/.chief-of-staff/chief.json"
    }
}

public enum SettingsStore {
    static func readJSON(_ path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        var bytes = data
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        return (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
    }

    /// Reads agent-voice's settings (read-only) and this app's settings. Never writes anything.
    /// Chief file precedence: FV_CHIEF_FILE env, then `chiefFile` setting, then ~/.chief-of-staff/chief.json.
    public static func load(env: [String: String] = ProcessInfo.processInfo.environment) -> LoadedSettings {
        var voice = VoiceConfig()
        let candidates = SettingsPaths.agentVoiceFiles(env)
        let voiceFile = candidates.first { FileManager.default.fileExists(atPath: $0) }
        if let voiceFile, let stored = readJSON(voiceFile) { voice.apply(stored) }
        voice.pauseMs = AppSettings.defaultPauseMs
        let appFile = SettingsPaths.appFile(env)
        var app = AppSettings()
        var unreadable = false
        if let stored = readJSON(appFile) {
            app = parseApp(stored)
            voice.apply(stored)
        } else if FileManager.default.fileExists(atPath: appFile) {
            unreadable = true
        }
        if let t = env["FV_TARGET"], !t.isEmpty { app.target = t }
        if let d = env["FV_BUSY_DELIVERY"], let v = BusyDelivery(rawValue: d) { app.busyDelivery = v }
        let chiefFile = env["FV_CHIEF_FILE"] ?? app.chiefFile ?? SettingsPaths.defaultChiefFile(env)
        return LoadedSettings(app: app, voice: voice, voiceFile: voiceFile, appFile: appFile, chiefFile: chiefFile, appFileUnreadable: unreadable)
    }

    public static func parseApp(_ stored: [String: Any]) -> AppSettings {
        var app = AppSettings()
        if let t = stored["target"] as? String, !t.isEmpty { app.target = t }
        if let c = stored["chiefFile"] as? String, !c.isEmpty { app.chiefFile = (c as NSString).expandingTildeInPath }
        if let d = stored["busyDelivery"] as? String, let v = BusyDelivery(rawValue: d) { app.busyDelivery = v }
        if let v = (stored["holdMidSentenceMs"] as? NSNumber)?.doubleValue { app.holdMidSentenceMs = v }
        if let v = (stored["busyMergeQuietMs"] as? NSNumber)?.doubleValue { app.busyMergeQuietMs = v }
        if let v = (stored["turnEndQuietMs"] as? NSNumber)?.doubleValue { app.turnEndQuietMs = v }
        if let v = stored["livePartials"] as? Bool { app.livePartials = v }
        if let v = stored["sendMode"] as? String, let m = SendMode(rawValue: v) { app.sendMode = m }
        if let v = stored["sendHotkey"] as? String, Hotkey.parse(v) != nil { app.sendHotkey = v }
        return app
    }

    /// Write settings changed in the window to the app's own file. Refuses to write agent-voice's settings files
    /// (the one in use or any candidate): those belong to agent-voice and are only ever read.
    /// Returns a warning when the existing file was unreadable (a copy was saved beside it before writing).
    @discardableResult
    public static func saveAppSetting(_ patch: [String: Any], appFile: String, voiceFile: String?,
                                      env: [String: String] = ProcessInfo.processInfo.environment) throws -> String? {
        let target = URL(fileURLWithPath: appFile).standardizedFileURL.resolvingSymlinksInPath().path
        let protected = (SettingsPaths.agentVoiceFiles(env) + [voiceFile].compactMap { $0 })
            .map { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path }
        guard !protected.contains(target) else { throw ClientError("Refusing to write agent-voice's settings file \(appFile)") }
        return try save(patch, to: appFile)
    }

    /// Persist only keys the user changed, merged into what is stored (like agent-voice's save).
    /// An unreadable existing file is copied to `<file>.bad` first and a warning returned, so no keys vanish silently.
    @discardableResult
    public static func save(_ patch: [String: Any], to path: String) throws -> String? {
        var warning: String?
        var stored = readJSON(path) ?? [:]
        if stored.isEmpty, FileManager.default.fileExists(atPath: path), readJSON(path) == nil {
            let bad = path + ".bad"
            try? FileManager.default.removeItem(atPath: bad)
            try FileManager.default.copyItem(atPath: path, toPath: bad)
            let name = (path as NSString).lastPathComponent
            warning = "\(name) was unreadable; saved a copy as \(name).bad and wrote a new one"
        }
        for (k, v) in patch { stored[k] = v }
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: stored, options: [.prettyPrinted, .sortedKeys])
        try (data + Data([10])).write(to: URL(fileURLWithPath: path), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        return warning
    }
}

/// Reads the current chief's session id from chief.json (`session` field).
public enum ChiefFile {
    public static func session(at path: String) -> String? {
        guard let json = SettingsStore.readJSON(path), let s = json["session"] as? String, s.hasPrefix("ses") else { return nil }
        return s
    }
}
