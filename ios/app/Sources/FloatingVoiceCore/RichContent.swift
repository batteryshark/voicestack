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
    public static let installManifest = "https://example-host.example-tailnet.invalid/floating-voice-ios/manifest.plist"
    // Shared by navigation and the network rules. No encoded separators, queries, or
    // selector syntax: documentation needing these features is deliberately unavailable.
    private static let documentPath = "/[a-zA-Z0-9._~/-]*([#][a-zA-Z0-9_~-]+)?$"
    // WebKit content-rule filters do not support alternation. Keep one filter per
    // denied prefix, shared with navigation so the two policies cannot drift.
    private static let deniedPaths = ["api", "floating-voice", "private", "auth", "admin", "login", "logout", "oauth", "session", "token", "credentials", "[.]", "/"]
        .map { "/([a-zA-Z0-9._~-]+/)*" + $0 }
    public var privilegedHosts: Set<String>
    public var approvedManifests: Set<String>
    public init(privilegedHosts: Set<String> = [], approvedManifests: Set<String> = []) {
        self.privilegedHosts = privilegedHosts; self.approvedManifests = approvedManifests
    }
    public func web(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil, let host = url.host?.lowercased(),
               !privilegedHosts.contains(host), host.contains("."), !host.hasSuffix("."), !host.hasPrefix("0x"), host != "localhost", host != "::1", !host.hasSuffix(".localhost"),
               !host.contains("canvas"),
              !host.hasSuffix(".ts.net"), !host.hasSuffix(".local"), !host.contains(":"),
               host.range(of: "^[0-9.]+$", options: .regularExpression) == nil,
               host.range(of: "^[a-z0-9-]+([.][a-z0-9-]+)+$", options: .regularExpression) != nil,
               url.port == nil || (1...65535).contains(url.port!) else { return false }
        let prefix = Self.originPrefix(url)
        let raw = url.absoluteString
        guard raw.hasPrefix(prefix) else { return false }
        let path = String(raw.dropFirst(prefix.count - 1))
        return path.range(of: "^" + Self.documentPath, options: .regularExpression) != nil
            && !Self.deniedPaths.contains { path.range(of: "^" + $0, options: [.regularExpression, .caseInsensitive]) != nil }
    }
    public func install(_ url: URL) -> URL? {
        // Configuration may only narrow this single initial URL. Require one canonical
        // wrapper spelling, not queryItems' decoded interpretation of ambiguous input.
        let encoded = Self.installManifest.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"))!
        guard approvedManifests.contains(Self.installManifest),
              url.absoluteString == "itms-services://?action=download-manifest&url=" + encoded else { return nil }
        // No fetch here. Confirmation precedes Apple's handler; its redirect chain is not ours.
        return URL(string: Self.installManifest)
    }
    public static func normalizedHost(_ url: URL) -> String? {
        guard var host = url.host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasSuffix(".") { host.removeLast() }
        guard !host.hasSuffix("."), !host.hasPrefix("."), !host.contains("..") else { return nil }
        return host
    }
    public func contentRules(for url: URL) -> String? {
        guard web(url) else { return nil }
        let prefix = NSRegularExpression.escapedPattern(for: String(Self.originPrefix(url).dropLast()))
        var rules: [[String: Any]] = [
            ["trigger": ["url-filter": ".*"], "action": ["type": "block"]],
            ["trigger": ["url-filter": "^" + prefix + Self.documentPath,
                         "url-filter-is-case-sensitive": true,
                         "resource-type": ["document", "image", "style-sheet", "font"],
                         "load-context": ["top-frame"]], "action": ["type": "ignore-previous-rules"]]
        ]
        rules += Self.deniedPaths.map { ["trigger": ["url-filter": "^" + prefix + $0 + ".*"], "action": ["type": "block"]] }
        rules += [
            // No embedded browsing contexts, object/embed elements, or cookie authentication.
            ["trigger": ["url-filter": ".*", "load-context": ["child-frame"]], "action": ["type": "block"]],
            ["trigger": ["url-filter": ".*"], "action": ["type": "css-display-none", "selector": "iframe, frame, object, embed"]],
            ["trigger": ["url-filter": ".*"], "action": ["type": "block-cookies"]]
        ]
        return (try? JSONSerialization.data(withJSONObject: rules)).flatMap { String(data: $0, encoding: .utf8) }
    }
    private static func originPrefix(_ url: URL) -> String {
        "https://" + (url.host?.lowercased() ?? "") + (url.port.map { ":\($0)" } ?? "") + "/"
    }
}
