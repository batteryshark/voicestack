import Foundation

/// PDF metadata has no byte payload, URL, or action. Never hand PDF data to a decoder.
public struct FileCardMetadata: Equatable {
    public let name: String
    public let length: Int
    public init(_ value: [String: Any]) throws {
        guard value["mime"] as? String == "application/pdf", value["preview"] as? Bool == false,
              let name = value["name"] as? String, !name.isEmpty,
              let length = value["length"] as? Int, length > 0, length <= 8 * 1024 * 1024 else { throw ClientError("Invalid file metadata") }
        self.name = name; self.length = length
    }
}

/// Ordinals are selectors only. The bridge re-derives bytes from authoritative records.
public struct ContentReference: Equatable, Sendable {
    public let kind: String
    public let blockOrdinal: Int
    public var itemOrdinal: Int? = nil
    public var source: String? = nil
    public var format: String? = nil
    public var json: [String: Any] {
        var value: [String: Any] = ["kind": kind, "blockOrdinal": blockOrdinal]
        if let itemOrdinal { value["itemOrdinal"] = itemOrdinal }
        if let source { value["source"] = source }
        return value
    }
    public static func markdownParts(_ text: String, ordinal: Int) -> [MessageBody] {
        // Images in code fences are examples, not resource requests.
        var result: [MessageBody] = [], pending = "", fenced = false
        let regex = try! NSRegularExpression(pattern: "!\\[([^\\]]*)\\]\\(([^\\s)]+)\\)")
        let lines = text.components(separatedBy: "\n")
        for (lineIndex, line) in lines.enumerated() {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") || line.trimmingCharacters(in: .whitespaces).hasPrefix("~~~") { fenced.toggle() }
            let matches = fenced ? [] : regex.matches(in: line, range: NSRange(line.startIndex..., in: line))
            var start = line.startIndex
            for match in matches {
                guard let range = Range(match.range, in: line), let sourceRange = Range(match.range(at: 2), in: line) else { continue }
                pending += line[start..<range.lowerBound]
                if !pending.isEmpty { result.append(.init(label: nil, markdown: pending, command: nil)); pending = "" }
                result.append(.init(label: nil, markdown: String(line[Range(match.range(at: 1), in: line)!]), command: nil, reference: .init(kind: "markdownImage", blockOrdinal: ordinal, source: String(line[sourceRange]))))
                start = range.upperBound
            }
            pending += line[start...]
            if lineIndex < lines.count - 1 { pending += "\n" }
        }
        if !pending.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result.append(.init(label: nil, markdown: pending, command: nil)) }
        return result
    }
}

public struct CanvasDocument: Codable, Equatable {
    public struct Node: Codable, Equatable, Identifiable { public let id: String; public let label: String; public let detail: String; public let kind: String? }
    public struct Edge: Codable, Equatable { public let from: String; public let to: String; public let label: String? }
    public struct Diagram: Codable, Equatable { public let nodes: [Node]; public let edges: [Edge] }
    public struct Section: Codable, Equatable { public let title: String; public let body: String }
    public struct Choice: Codable, Equatable, Identifiable { public let id: String; public let label: String; public let description: String; public let prompt: String }
    public let title: String
    public let summary: String?
    public let diagram: Diagram?
    public let sections: [Section]
    public let choices: [Choice]
}

/// Fail-closed policy used by native navigation and tests. Privileged origins are never web content.
public struct LinkPolicy {
    public var privilegedHosts: Set<String>
    public var approvedManifests: Set<String>
    public var deploymentSuffix: String
    public init(privilegedHosts: Set<String> = [], approvedManifests: Set<String> = [], deploymentSuffix: String = "") {
        self.privilegedHosts = privilegedHosts; self.approvedManifests = approvedManifests
        self.deploymentSuffix = deploymentSuffix
    }
    public func web(_ url: URL) -> Bool {
        // Canvas links are panel selectors, never web destinations (including already-redacted keys).
        let rawSelector = (url.query ?? "") + "&" + (url.fragment ?? "")
        let selector = rawSelector.removingPercentEncoding ?? rawSelector
        guard selector.range(of: "(?:^|[&#?])(?:key|view)=", options: [.regularExpression, .caseInsensitive]) == nil else { return false }
        guard url.scheme == "https", url.user == nil, url.password == nil, let host = url.host?.lowercased(),
               !privilegedHosts.contains(host), host.contains("."), !host.hasSuffix("."), !host.hasPrefix("0x"), host != "localhost", host != "::1", !host.hasSuffix(".localhost"),
               !host.contains("canvas"),
              !host.hasSuffix(".ts.net"), !host.hasSuffix(".local"), !host.contains(":"),
              host.range(of: "^[0-9.]+$", options: .regularExpression) == nil else { return false }
        return !url.path.lowercased().hasPrefix("/api") && !url.path.lowercased().hasPrefix("/floating-voice")
    }
    public func install(_ url: URL) -> URL? {
        install(url.absoluteString)
    }
    private static func strictURI(_ raw: String) -> Bool {
        !raw.isEmpty && raw.range(of: "[^A-Za-z0-9._~:/?@!$&'()*+,;=%-]", options: .regularExpression) == nil &&
            raw.range(of: "%(?![0-9a-fA-F]{2})", options: .regularExpression) == nil
    }
    /// String entry point validates raw spelling before Foundation can normalize it.
    public func install(_ value: String) -> URL? {
        let prefix = "itms-services://?"
        guard Self.strictURI(value), value.hasPrefix(prefix) else { return nil }
        let fields = value.dropFirst(prefix.count).components(separatedBy: "&")
        var items: [(String, String)] = []
        for field in fields {
            guard let at = field.firstIndex(of: "="),
                  let key = String(field[..<at]).removingPercentEncoding,
                  let val = String(field[field.index(after: at)...]).removingPercentEncoding else { return nil }
            items.append((key, val))
        }
        guard items.count == 2, items.filter({ $0.0 == "action" && $0.1 == "download-manifest" }).count == 1,
                let raw = items.first(where: { $0.0 == "url" })?.1, Self.strictURI(raw),
                let authorityEnd = raw.range(of: "^https://[A-Za-z0-9.-]+(?::[0-9]{1,5})?(?=[/?]|$)", options: .regularExpression) else { return nil }
        let authority = String(raw[authorityEnd]).dropFirst("https://".count)
        if let colon = authority.firstIndex(of: ":") {
            guard let port = Int(authority[authority.index(after: colon)...]), port <= 65535 else { return nil }
        }
        guard
                let manifest = URL(string: raw), manifest.scheme == "https", manifest.user == nil, manifest.password == nil,
                manifest.fragment == nil,
               let host = Self.normalizedHost(manifest), Self.installHost(host) else { return nil }
        if !deploymentSuffix.isEmpty {
            guard deploymentSuffix.hasPrefix("."), deploymentSuffix.count <= 254,
                  Self.installHost(String(deploymentSuffix.dropFirst())), host.hasSuffix(deploymentSuffix),
                  approvedManifests.isEmpty || approvedManifests.contains(raw) else { return nil }
        } else {
            guard !approvedManifests.isEmpty, approvedManifests.contains(raw) else { return nil }
        }
        return manifest
    }
    private static func installHost(_ host: String) -> Bool {
        host.count <= 253 && host.range(of: "^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\\.)+ts\\.net$", options: .regularExpression) != nil
    }
    public static func normalizedHost(_ url: URL) -> String? {
        guard var host = url.host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasSuffix(".") { host.removeLast() }
        guard !host.hasSuffix("."), !host.hasPrefix("."), !host.contains("..") else { return nil }
        return host
    }
    public func contentRules(for url: URL) -> String? {
        guard web(url), let host = url.host else { return nil }
        let prefix = "https://" + host + (url.port.map { ":\($0)" } ?? "") + "/"
        let rules: [[String: Any]] = [
            ["trigger": ["url-filter": ".*"], "action": ["type": "block"]],
            ["trigger": ["url-filter": "^" + NSRegularExpression.escapedPattern(for: prefix)], "action": ["type": "ignore-previous-rules"]],
            ["trigger": ["url-filter": ".*/api.*"], "action": ["type": "block"]],
            ["trigger": ["url-filter": ".*/floating-voice.*"], "action": ["type": "block"]]
        ]
        return (try? JSONSerialization.data(withJSONObject: rules)).flatMap { String(data: $0, encoding: .utf8) }
    }
}
