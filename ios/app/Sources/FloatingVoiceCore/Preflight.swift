import Foundation

/// A check run on Start before voice reports ready. Throws a message the window can show as is.
public struct PreflightCheck {
    public let name: String
    public let run: () async throws -> Void
    public init(name: String, run: @escaping () async throws -> Void) { self.name = name; self.run = run }
}

public func withTimeout<T>(_ seconds: Double, _ message: String, _ body: @escaping () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw ClientError(message)
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

public enum ServiceChecks {
    /// Read-only health; never synthesize a dummy utterance or warm a model.
    public static func speech(_ config: VoiceConfig, timeout: Double = 8) -> PreflightCheck {
        PreflightCheck(name: "speech server") {
            _ = try await SpeechHealth.probe(config.ttsUrl, config.ttsApiKey)
        }
    }

    /// Read-only listener/model inventory; the next real utterance opens recognition.
    public static func recognition(_ config: VoiceConfig, timeout: Double = 5) -> PreflightCheck {
        PreflightCheck(name: "recognition server") {
            _ = try await SpeechHealth.probe(config.asrUrl, config.asrApiKey)
        }
    }
}

extension ServiceChecks {
    /// The recognition server's /health, beside the websocket route (ws://host:port/v1/transcribe -> http://host:port/health).
    public static func healthURL(_ asrUrl: String) -> URL? {
        guard var c = URLComponents(string: asrUrl), let scheme = c.scheme, ["ws", "wss", "http", "https"].contains(scheme) else { return nil }
        c.scheme = ["wss", "https"].contains(scheme) ? "https" : "http"
        guard let suffix = ["/v1/transcribe", "/v1/audio/speech"].first(where: { c.path.hasSuffix($0) }) else { return nil }
        c.path = String(c.path.dropLast(suffix.count)) + "/health"
        c.query = nil
        return c.url
    }

    /// True when /health advertises live partial words (`"streaming_partials": true`, and `partials.enabled` is not
    /// false). Any failure means no: the app then works without live words, as before.
    public static func partialsAdvertised(_ config: VoiceConfig, timeout: Double = 2) async -> Bool {
        guard let url = healthURL(config.asrUrl) else { return false }
        var r = URLRequest(url: url)
        r.timeoutInterval = timeout
        if let key = config.asrApiKey { r.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
        guard let (data, response) = try? await URLSession.shared.data(for: r), (response as? HTTPURLResponse)?.statusCode == 200,
              let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        return advertisesPartials(body)
    }

    public static func advertisesPartials(_ health: [String: Any]) -> Bool {
        guard health["streaming_partials"] as? Bool == true else { return false }
        if let p = health["partials"] as? [String: Any], p["enabled"] as? Bool == false { return false }
        return true
    }
}

final class WebSocketProbe: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?

    func open(_ url: URL, apiKey: String?) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            lock.lock(); continuation = c; lock.unlock()
            var r = URLRequest(url: url)
            r.timeoutInterval = 5
            if let apiKey { r.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization") }
            let s = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
            session = s
            let t = s.webSocketTask(with: r)
            task = t
            t.resume()
        }
    }

    private func finish(_ error: Error?) {
        lock.lock(); let c = continuation; continuation = nil; lock.unlock()
        if let error { c?.resume(throwing: error) } else { c?.resume() }
    }

    func close() {
        task?.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) { finish(nil) }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish(error ?? ClientError("connection closed"))
    }
}

/// Appends timestamped lines to a log file (the app writes one per run under ~/Library/Logs/FloatingVoice/).
public final class FileLog: @unchecked Sendable {
    public let path: String
    private let handle: FileHandle?
    private let lock = NSLock()
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    public init(path: String) {
        self.path = path
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path, contents: nil)
        handle = FileHandle(forWritingAtPath: path)
    }

    /// ~/Library/Logs/FloatingVoice/<timestamp>.log
    public static func forThisRun(home: String = NSHomeDirectory()) -> FileLog {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HHmmss"
        return FileLog(path: "\(home)/Library/Logs/FloatingVoice/\(f.string(from: Date())).log")
    }

    public func write(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        handle?.write(Data("\(formatter.string(from: Date())) \(line)\n".utf8))
    }
}
