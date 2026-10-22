import Foundation
import Testing
@testable import FloatingVoiceCore

/// Offline policy tests: the rule evaluator checks emitted JSON, not WebKit behavior.
@Suite struct LinkPolicyTests {
    let manifest = "https://example-host.example-tailnet.invalid/floating-voice-ios/manifest.plist"
    let canonical = "itms-services://?action=download-manifest&url=https%3A%2F%2Fexample-host.example-tailnet.invalid%2Ffloating-voice-ios%2Fmanifest.plist"

    @Test func exactInstallIsOptIn() {
        let url = URL(string: canonical)!
        #expect(LinkPolicy.installManifest == manifest)
        #expect(LinkPolicy().install(url) == nil)
        #expect(LinkPolicy(approvedManifests: []).install(url) == nil)
        #expect(LinkPolicy(approvedManifests: [manifest]).install(url)?.absoluteString == manifest)
        #expect(LinkPolicy(approvedManifests: [manifest + "?v=1"]).install(url) == nil)
    }

    @Test func installRejectsEveryManifestVariationEvenIfConfigured() {
        let variants = [manifest + "?v=1", manifest + "#x", manifest + "/", manifest.replacingOccurrences(of: ".invalid/", with: ".invalid:443/"), manifest.replacingOccurrences(of: ".invalid/", with: ".invalid:9443/"), manifest.replacingOccurrences(of: "https://", with: "https://user:pass@"), manifest.replacingOccurrences(of: "https://", with: "http://"), manifest.replacingOccurrences(of: "example-host", with: "other"), manifest.replacingOccurrences(of: "manifest.plist", with: "%6Danifest.plist"), manifest.replacingOccurrences(of: ".invalid/", with: ".invalid./"), "https://example-host.example-tailnet.invalid/other.plist"]
        for raw in variants {
            let encoded = raw.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
            #expect(LinkPolicy(approvedManifests: [manifest, raw]).install(URL(string: "itms-services://?action=download-manifest&url=" + encoded)!) == nil, "\(raw)")
        }
    }

    @Test func installRejectsAmbiguousWrappers() {
        let policy = LinkPolicy(approvedManifests: [manifest])
        let encoded = canonical.components(separatedBy: "&url=")[1]
        for raw in [canonical + "&url=" + encoded, canonical + "&action=download-manifest", canonical + "&extra=1", canonical + "#x", canonical.replacingOccurrences(of: "action=", with: "%61ction="), canonical.replacingOccurrences(of: "&url=", with: "&%75rl="), canonical.replacingOccurrences(of: "%", with: "%25"), canonical.replacingOccurrences(of: "//?", with: "///?"), canonical.replacingOccurrences(of: "//?", with: "//evil?"), canonical.replacingOccurrences(of: "&url=" + encoded, with: "&url=" + manifest), "itms-services://?url=" + encoded + "&action=download-manifest"] {
            #expect(policy.install(URL(string: raw)!) == nil, "\(raw)")
        }
    }

    @Test func documentationRemainsUseful() throws {
        let policy = LinkPolicy()
        for path in ["/", "/guide", "/docs/guide.html", "/assets/style-v2.css", "/guide#overview", "/guide~v2"] {
            let url = URL(string: "https://example.org:8443" + path)!
            #expect(policy.web(url))
            for type in ["document", "image", "style-sheet", "font"] {
                #expect(try networkAllows(url, type: type, policy: policy))
            }
        }
    }

    @Test func navigationAndNetworkDenyAmbiguityAndPrivatePaths() throws {
        let policy = LinkPolicy()
        for path in ["/%61pi/secret", "/%66loating-voice/v1", "/%2561pi/secret", "/guide?key=SYNTHETIC", "/guide?view=x", "/guide?x=1", "/guide?", "/guide#key=x", "/guide#%76iew=x", "/api/secret", "/API/secret", "/docs/api/secret", "/floating-voice/v1", "/private/data", "/docs/auth/token", "/admin", "/.private", "/docs/../api/secret", "/docs/./guide", "//api/secret", "/docs//guide", "/docs/%2fapi", "/guide;key=x", "/guide%5csecret", "/guide%00", "/guide%0a"] {
            let url = URL(string: "https://example.org" + path)!
            #expect(!policy.web(url), "\(path)")
            for type in ["document", "image", "style-sheet", "font", "raw"] {
                #expect(try !networkAllows(url, type: type, policy: policy), "\(path) \(type)")
            }
        }
    }

    @Test func networkDeniesOtherOriginsContextsAndResourceTypes() throws {
        let policy = LinkPolicy()
        let json = try #require(policy.contentRules(for: URL(string: "https://example.org/guide")!))
        let rules = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
        #expect(rules.contains { ($0["action"] as? [String: String])?["type"] == "block-cookies" })
        #expect(rules.contains { ($0["action"] as? [String: String])?["selector"] == "iframe, frame, object, embed" })
        for raw in ["https://other.org/guide", "https://example.org.evil.org/guide", "https://example.org:443/guide", "https://user@example.org/guide", "http://example.org/guide", "data:text/html,test", "file:///guide", "custom://example.org/guide"] {
            #expect(try !networkAllows(URL(string: raw)!, type: "image", policy: policy))
        }
        let url = URL(string: "https://example.org/guide")!
        #expect(try !networkAllows(url, type: "document", context: "child-frame", policy: policy))
        for type in ["raw", "svg-document", "script", "media", "popup", "ping", "fetch", "websocket"] {
            #expect(try !networkAllows(url, type: type, policy: policy))
        }
    }

    @Test func nativeSourceKeepsConfirmationAndProductionBoundary() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let view = try String(contentsOf: root.appendingPathComponent("native/PrivateLinkView.swift"))
        #expect(view.contains("Button(\"Install\") { UIApplication.shared.open(url) }"))
        #expect(view.contains(".confirmationDialog("))
        #expect(view.contains(".nonPersistent()") && view.contains("allowsContentJavaScript = false"))
        let production = try #require(view.components(separatedBy: "guard let encoded = phoneLinkPolicy.contentRules").last)
        #expect(production.range(of: "userContentController.add(list)")!.lowerBound < production.range(of: "view.load(URLRequest(url: url))")!.lowerBound)
        #expect(view.contains("action.targetFrame?.isMainFrame == true && action.request.httpMethod == \"GET\""))
        let newWindow = try #require(view.components(separatedBy: "createWebViewWith configuration:").last?.components(separatedBy: "func webView").first)
        #expect(newWindow.contains("return nil") && !newWindow.contains("view.load("))
        #expect(view.contains(".cancelAuthenticationChallenge, nil"))
        #expect(view.contains("[\"text/html\", \"text/plain\"]"))
    }

    private func networkAllows(_ url: URL, type: String, context: String = "top-frame", policy: LinkPolicy) throws -> Bool {
        let json = try #require(policy.contentRules(for: URL(string: "https://example.org" + (url.port == 8443 ? ":8443" : "") + "/guide")!))
        let rules = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
        var blocked = false
        for rule in rules {
            let trigger = rule["trigger"] as! [String: Any], action = rule["action"] as! [String: Any]
            if let types = trigger["resource-type"] as? [String], !types.contains(type) { continue }
            if let contexts = trigger["load-context"] as? [String], !contexts.contains(context) { continue }
            let options: String.CompareOptions = trigger["url-filter-is-case-sensitive"] as? Bool == true ? [.regularExpression] : [.regularExpression, .caseInsensitive]
            guard url.absoluteString.range(of: trigger["url-filter"] as! String, options: options) != nil else { continue }
            if action["type"] as? String == "block" { blocked = true }
            if action["type"] as? String == "ignore-previous-rules" { blocked = false }
        }
        return !blocked
    }
}
