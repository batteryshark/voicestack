import Foundation

/// One event from OpenChamber's `/api/event` stream: `{id, type, created, location, data:{sessionID, ...}}`.
public struct ServerEvent {
    public let type: String
    public let data: [String: Any]
    public let created: Double?

    public init(type: String, data: [String: Any] = [:], created: Double? = nil) {
        self.type = type; self.data = data; self.created = created
    }

    public init?(json: String) {
        guard let bytes = json.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any],
              let type = obj["type"] as? String else { return nil }
        self.type = type
        self.data = obj["data"] as? [String: Any] ?? [:]
        self.created = (obj["created"] as? NSNumber)?.doubleValue
    }

    public var sessionID: String? { data["sessionID"] as? String }
    public var delta: String? { data["delta"] as? String }
    public var text: String? { data["text"] as? String }
    /// Identifies one text block: assistant message plus ordinal.
    public var blockKey: String {
        "\(data["assistantMessageID"] as? String ?? "?"):\((data["ordinal"] as? NSNumber)?.intValue ?? 0)"
    }
}

/// What the conversation controller needs from the server; a fake implements it in unit tests.
public protocol SessionBackend: AnyObject {
    /// (Re)discover the server. Called on every connect and reconnect. Returns a description for logs.
    func connect() async throws -> String
    /// The shared event stream (all sessions). Ends or throws when the connection drops.
    func events() -> AsyncThrowingStream<ServerEvent, Error>
    /// Ids of sessions currently running a turn.
    func activeSessions() async throws -> Set<String>
    func prompt(sessionID: String, text: String, delivery: BusyDelivery?) async throws
    /// true if a running turn was interrupted.
    func interrupt(sessionID: String) async throws -> Bool
    /// Display title of a session, if any.
    func sessionTitle(_ id: String) async -> String?
    /// Resolve only addresses proven to refer to this server; never query a remote ID locally.
    func senderSessionTitle(_ address: String) async -> String?
    /// Add a user message to the thread without starting a turn (`resume: false`).
    func admit(sessionID: String, text: String) async throws
    /// The server's sessions (any order).
    func listSessions() async throws -> [SessionSummary]
    /// Receipt identity is used solely to recognize our own SSE echo, never by matching text.
    func postWithReceipt(sessionID: String, text: String, delivery: BusyDelivery?, admit: Bool) async throws -> String?
}

/// One session in the server's list.
public struct SessionSummary: Equatable, Sendable {
    public let id: String
    public let title: String
    /// Last update, ms since the epoch.
    public let updated: Double
    public let directory: String
    public let parentID: String?
    public init(id: String, title: String, updated: Double, directory: String = "", parentID: String? = nil) {
        self.id = id; self.title = title; self.updated = updated; self.directory = directory; self.parentID = parentID
    }

    /// "a10001" for ses_a10001fixture0000000000…: short enough to tell sessions with the same title apart.
    public static func shortID(_ id: String) -> String {
        String((id.hasPrefix("ses_") ? id.dropFirst(4) : Substring(id)).prefix(6))
    }
    public var shortID: String { SessionSummary.shortID(id) }
    /// "Chief of staff · a10001"
    public var label: String { "\(title.isEmpty ? "Untitled" : title) · \(shortID)" }
}

/// Finds the chief on a machine with no chief file: the most recently updated session titled "Chief of staff".
public enum ChiefDiscovery {
    public static let title = "Chief of staff"

    public static func pick(from sessions: [SessionSummary]) -> String? {
        sessions
            .filter { $0.title.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(title) == .orderedSame }
            .max { $0.updated < $1.updated }?.id
    }
}

public extension SessionBackend {
    func senderSessionTitle(_ address: String) async -> String? {
        guard address.hasPrefix("local/") else { return nil }
        return await sessionTitle(String(address.dropFirst(6)))
    }
    func postWithReceipt(sessionID: String, text: String, delivery: BusyDelivery?, admit: Bool) async throws -> String? {
        if admit { try await self.admit(sessionID: sessionID, text: text) }
        else { try await prompt(sessionID: sessionID, text: text, delivery: delivery) }
        return nil
    }
    func listSessions() async throws -> [SessionSummary] { [] }
    func sessionTitle(_ id: String) async -> String? { nil }
    func admit(sessionID: String, text: String) async throws { try await prompt(sessionID: sessionID, text: text, delivery: nil) }
}

public struct SessionInfo {
    public let id: String
    public let directory: String
    public let title: String?
}

/// OpenChamber's own server (the desktop instance), which proxies OpenCode's API and injects its credential
/// (spikes/S1.md). No credentials are needed while OpenChamber's UI auth is off.
public final class OpenChamberClient: SessionBackend, @unchecked Sendable {
    public private(set) var base: URL?
    /// Called before every prompt or interrupt with the session id; throw to refuse (the harness's guard).
    public var sendPolicy: ((String) async throws -> Void)?
    private let env: [String: String]
    private let session: URLSession
    private let localSenderServer: String?

    public init(env: [String: String] = ProcessInfo.processInfo.environment) {
        self.env = env
        // Resolve once during initialization, not in a potentially concurrent lazy title lookup.
        // Read only the self name; no peer URLs, tokens or credentials are used.
        let path = (env["HOME"] ?? NSHomeDirectory()) + "/.config/opencode/a2a-peers.json"
        self.localSenderServer = (SettingsStore.readJSON(path)?["self"] as? [String: Any])?["name"] as? String
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        session = URLSession(configuration: config)
    }

    var dataDir: String { env["OPENCHAMBER_DATA_DIR"] ?? (env["HOME"] ?? NSHomeDirectory()) + "/.config/openchamber" }

    /// Same as OpenChamber's CLI (discoverDesktopInstance): `desktopLocalPort` from settings.json, confirmed by
    /// GET /api/system/info returning runtime "desktop". Only that key is read.
    public func connect() async throws -> String {
        let url: URL
        if let explicit = env["FV_OPENCHAMBER_URL"], let u = URL(string: explicit) { url = u }
        else if let p = env["OPENCHAMBER_PORT"], let port = Int(p) { url = URL(string: "http://127.0.0.1:\(port)")! }
        else {
            let file = dataDir + "/settings.json"
            guard let json = SettingsStore.readJSON(file) else { throw ClientError("OpenChamber settings not found (\(file)); is OpenChamber installed?") }
            guard let port = (json["desktopLocalPort"] as? NSNumber)?.intValue else { throw ClientError("OpenChamber has no desktopLocalPort; is it running?") }
            url = URL(string: "http://127.0.0.1:\(port)")!
        }
        var request = URLRequest(url: url.appendingPathComponent("api/system/info"))
        request.timeoutInterval = 3
        let info: [String: Any]
        do { info = try await json(request) as? [String: Any] ?? [:] }
        catch { throw ClientError("OpenChamber is not answering at \(url.absoluteString): \(error.localizedDescription)") }
        guard info["runtime"] as? String == "desktop" else { throw ClientError("\(url.absoluteString) is not OpenChamber's desktop server") }
        base = url
        return "\(url.absoluteString) (OpenChamber \(info["openchamberVersion"] as? String ?? "?"))"
    }

    func requireBase() throws -> URL {
        guard let base else { throw ClientError("Not connected to OpenChamber") }
        return base
    }

    func request(_ method: String, _ path: String, body: Any? = nil, query: String? = nil) throws -> URLRequest {
        var s = try requireBase().absoluteString + path
        if let query { s += "?" + query }
        var r = URLRequest(url: URL(string: s)!)
        r.httpMethod = method
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token = env["OPENCHAMBER_BEARER"] { r.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        if let body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return r
    }

    @discardableResult
    func json(_ request: URLRequest) async throws -> Any? {
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw HTTPError.status(code, String(data: data, encoding: .utf8) ?? "") }
        return data.isEmpty ? nil : try? JSONSerialization.jsonObject(with: data)
    }

    public func events() -> AsyncThrowingStream<ServerEvent, Error> {
        AsyncThrowingStream { continuation in
            let request: URLRequest
            do {
                var r = try self.request("GET", "/api/event")
                r.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                request = r
            } catch { continuation.finish(throwing: error); return }
            // The server may be quiet for long stretches; a minute of silence is treated as a drop.
            let stream = HTTPChunkStream(request, idleTimeout: 75)
            let task = Task {
                do {
                    let head = try await stream.headers()
                    guard (200..<300).contains(head.statusCode) else { throw HTTPError.status(head.statusCode, "event stream") }
                    var parser = SSEParser()
                    for try await chunk in stream.chunks {
                        for payload in parser.push(chunk) {
                            if let event = ServerEvent(json: payload) { continuation.yield(event) }
                        }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel(); stream.cancel() }
        }
    }

    public func activeSessions() async throws -> Set<String> {
        let obj = try await json(request("GET", "/api/session/active")) as? [String: Any]
        let map = obj?["data"] as? [String: Any] ?? [:]
        return Set(map.keys)
    }

    public func sessionInfo(_ id: String) async throws -> SessionInfo {
        let obj = try await json(request("GET", "/api/session/\(id)")) as? [String: Any]
        guard let data = obj?["data"] as? [String: Any] else { throw ClientError("Session \(id) not found") }
        let dir = (data["location"] as? [String: Any])?["directory"] as? String ?? ""
        return SessionInfo(id: id, directory: dir, title: data["title"] as? String)
    }

    public func sessionTitle(_ id: String) async -> String? { try? await sessionInfo(id).title }
    public func senderSessionTitle(_ address: String) async -> String? {
        let pieces = address.split(separator: "/", omittingEmptySubsequences: false)
        guard pieces.count == 2, pieces[0] == "local" || String(pieces[0]) == localSenderServer,
              SenderAttribution.validAddress(address) else { return nil }
        return await sessionTitle(String(pieces[1]))
    }

    /// GET /api/session: `{data: [{id, title, time: {updated}, location: {directory}, parentID?}], cursor}`.
    public func listSessions() async throws -> [SessionSummary] {
        let obj = try await json(request("GET", "/api/session", query: "limit=200")) as? [String: Any]
        let list = obj?["data"] as? [[String: Any]] ?? []
        return list.compactMap { s in
            guard let id = s["id"] as? String else { return nil }
            let time = s["time"] as? [String: Any]
            return SessionSummary(id: id, title: s["title"] as? String ?? "", updated: (time?["updated"] as? NSNumber)?.doubleValue ?? 0,
                                  directory: (s["location"] as? [String: Any])?["directory"] as? String ?? "",
                                  parentID: s["parentID"] as? String)
        }
    }

    public func prompt(sessionID: String, text: String, delivery: BusyDelivery?) async throws {
        _ = try await postWithReceipt(sessionID: sessionID, text: text, delivery: delivery, admit: false)
    }

    public func postWithReceipt(sessionID: String, text: String, delivery: BusyDelivery?, admit: Bool) async throws -> String? {
        try await sendPolicy?(sessionID)
        var body: [String: Any] = ["text": text]
        if let delivery { body["delivery"] = delivery.rawValue }
        if admit { body["resume"] = false }
        let result = try await json(request("POST", "/api/session/\(sessionID)/prompt", body: body)) as? [String: Any]
        return (result?["data"] as? [String: Any])?["id"] as? String
    }

    public func admit(sessionID: String, text: String) async throws {
        _ = try await postWithReceipt(sessionID: sessionID, text: text, delivery: nil, admit: true)
    }

    public func interrupt(sessionID: String) async throws -> Bool {
        try await sendPolicy?(sessionID)
        let obj = try await json(request("POST", "/api/session/\(sessionID)/interrupt", query: "resume=false")) as? [String: Any]
        return obj?["interrupted"] as? Bool ?? false
    }

    // Used by the harness only (throwaway sessions).

    public func createSession(directory: String, title: String) async throws -> String {
        let obj = try await json(request("POST", "/api/openchamber/control", body: ["action": "session.create", "input": ["directory": directory, "title": title]])) as? [String: Any]
        guard let id = obj?["sessionId"] as? String else { throw ClientError("session.create returned no id") }
        return id
    }

    public func setModel(sessionID: String, providerID: String, modelID: String) async throws {
        try await sendPolicy?(sessionID)
        try await json(request("POST", "/api/session/\(sessionID)/model", body: ["model": ["providerID": providerID, "id": modelID]]))
    }

    public func archive(_ ids: [String]) async throws -> Any? {
        try await json(request("POST", "/api/openchamber/sessions/archive", body: ["ids": ids]))
    }
}

public struct ClientError: Error, LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
