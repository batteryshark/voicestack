import Foundation
import Testing
#if os(macOS)
import WebKit
#endif
@testable import FloatingVoiceCore

@Suite struct RichContentTests {
    @Test func mergedNativeEntryPointPreservesMainAndM2Paths() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let app = try String(contentsOf: root.appendingPathComponent("native/FloatingVoiceApp.swift"))
        #expect(!app.contains("<<<<<<<") && !app.contains(">>>>>>>"))
        #expect(app.contains("if DeviceAudioProbe.enabled { DeviceAudioProbeView() }"))
        #expect(app.contains("ProcessInfo.processInfo.arguments.contains(\"-FVRichFixture\")") && app.contains("RichContentFixtureScreen()"))
        #expect(app.contains("PhoneLoopProbe.install()") && app.contains("selection = PhoneLoopProbe.target"))
        #expect(app.contains("Text(InstalledBuild.label)") && app.contains("accessibilityIdentifier(\"voice.build\")") && app.contains("accessibilityIdentifier(\"settings.build\")"))
        #expect(app.contains("build: InstalledBuild.number"))
        let project = try String(contentsOf: root.appendingPathComponent("native/FloatingVoice.xcodeproj/project.pbxproj"))
        #expect(!project.contains("<<<<<<<") && !project.contains(">>>>>>>"))
        for file in ["DeviceAudioProbe.swift", "PhoneLoopProbe.swift", "RichContentFixtures.swift", "RichContentViews.swift", "PrivateLinkView.swift", "RichContent.swift", "VoiceTrace.swift"] { #expect(project.contains(file)) }
    }
#if os(macOS)
    @MainActor @Test func webKitCompilesTheProductionNetworkBoundary() async throws {
        let policy = LinkPolicy(privilegedHosts: ["canvas.example"])
        #expect(policy.contentRules(for: URL(string: "https://canvas.example/")!) == nil)
        let rules = try #require(policy.contentRules(for: URL(string: "https://example.org/fixture")!))
        let success = await withCheckedContinuation { continuation in
            WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "m2-headless-" + UUID().uuidString, encodedContentRuleList: rules) { list, error in
                continuation.resume(returning: list != nil && error == nil)
            }
        }
        #expect(success)
    }
#endif
    @Test func orderedProjectionKeepsUnknownsReasoningFilesAndRawFields() throws {
        let record: [String: Any] = ["id": "m", "type": "assistant", "future": "retained", "content": [
            ["type": "text", "text": "Before ![plot](plot.png) after"],
            ["type": "reasoning", "text": "Reason"],
            ["type": "tool", "name": "probe", "state": ["status": "completed", "content": [["type": "file", "mime": "image/png", "uri": "plot.png"]]]],
            ["type": "future", "nested": ["keep": true]], ["type": "text", "text": "Last"]
        ]]
        let row = try #require(MessageRow(JSONSerialization.data(withJSONObject: record)))
        #expect(row.body.first?.markdown == "Before ")
        #expect(row.body[1].reference?.source == "plot.png")
        #expect(row.body.last?.markdown == "Last")
        #expect(row.body.contains { $0.label == "reasoning" && $0.markdown == "Reason" })
        #expect(row.body.contains { $0.reference?.kind == "toolFile" })
        #expect(row.body.contains { $0.label == "future" })
        #expect(row.detail.contains("retained") && row.detail.contains("keep"))
    }
    @Test func blankChiefAndFencedImages() throws {
        #expect(MessageRow(Data(#"{"id":"m","type":"assistant","content":[{"type":"text","text":"  "}]}"#.utf8)) == nil)
        let parts = ContentReference.markdownParts("```swift\n![x](secret.png)\n```\n![yes](yes.png)", ordinal: 3)
        #expect(parts.compactMap(\.reference).map(\.source) == ["yes.png"])
    }
    @Test func tablesEscapesCodeSpansAndIncompleteStreams() {
        #expect(BlockMarkdown.cells("| a\\|b | ``code `|` span`` |") == ["a|b", "``code `|` span``"])
        #expect(BlockMarkdown.cells("a | escaped\\|") == ["a", "escaped|"])
        #expect(BlockMarkdown.parse("| A | B |\n| --") == [.paragraph("| A | B |"), .paragraph("| --")])
        #expect(BlockMarkdown.parse("| A | B |\n| --- | --- |\n| streamed") == [.table([["A", "B"], ["streamed"]])])
    }
    @Test func linkAndInstallPolicyNeverInvokesSystem() throws {
        let manifest = "https://build.ts.net/app.plist"
        let policy = LinkPolicy(privilegedHosts: ["canvas.example"], approvedManifests: [manifest])
        for raw in ["http://example.com", "https://127.0.0.1", "https://localhost", "https://192.0.2.10", "https://host-07.example.ts.net", "https://canvas.example", "https://user:pass@example.com", "file:///etc/hosts", "https://example.com/api/fs/raw"] {
            #expect(!policy.web(URL(string: raw)!))
        }
        #expect(policy.web(URL(string: "https://example.com/guide")!))
        #expect(policy.install(URL(string: "itms-services://?action=download-manifest&url=https%3A%2F%2Fbuild.ts.net%2Fapp.plist")!) != nil)
        for raw in ["itms-services://?action=other&url=\(manifest)", "itms-services://?action=download-manifest&url=https://evil.example/x", "itms-services://?action=download-manifest&action=download-manifest&url=\(manifest)"] { #expect(policy.install(URL(string: raw)!) == nil) }
    }
    @Test func reviewRegressionInstallDomainIsMandatoryAndConfigurationOnlyNarrows() throws {
        func link(_ manifest: String) -> URL {
            var value = URLComponents(string: "itms-services://")!
            value.queryItems = [.init(name: "action", value: "download-manifest"), .init(name: "url", value: manifest)]
            return value.url!
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let rows = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("shared/install-policy-fixtures.json"))) as! [[String: Any]]
        for row in rows {
            let policy = LinkPolicy(approvedManifests: Set(row["approvedManifests"] as! [String]), deploymentSuffix: row["deploymentSuffix"] as! String)
            let allowed = (row["url"] as? String).flatMap(URL.init(string:)).flatMap { policy.install($0) } != nil
            #expect(allowed == (row["expected"] as! Bool), "\(row["name"]!)")
        }
        let view = try String(contentsOf: root.appendingPathComponent("native/PrivateLinkView.swift"))
        let dialog = try #require(view.components(separatedBy: ".confirmationDialog(").last)
        #expect(dialog.contains("Host:") && dialog.contains("Manifest:") && dialog.contains("manifest.path"))
    }
    @Test func reviewRegressionUnknownToolResultsStayOrderedAndKeepTheRow() throws {
        let original = Data(#"{"id":"msg_unknown","type":"assistant","content":[{"type":"tool","name":"future_tool","state":{"status":"completed","content":[{"type":"future_result","nested":{"keep":"important"}}]}}]}"#.utf8)
        let row = try #require(MessageRow(original))
        #expect(row.body.count == 1 && row.body[0].rawDetail?.contains("important") == true)
        let mixed = Data(#"{"id":"mixed","type":"assistant","content":[{"type":"text","text":"Before"},{"type":"tool","name":"future_tool","state":{"status":"completed","content":[{"type":"text","text":"first"},{"type":"future_result","nested":{"keep":"middle"}},{"type":"text","text":"last"}]}},{"type":"text","text":"After"}]}"#.utf8)
        let ordered = try #require(MessageRow(mixed))
        #expect(ordered.body.count == 5)
        #expect(ordered.body[0].markdown == "Before" && ordered.body[1].markdown == "first")
        #expect(ordered.body[2].rawDetail?.contains("middle") == true)
        #expect(ordered.body[3].markdown == "last" && ordered.body[4].markdown == "After")
        #expect(MessageRow(Data(#"{"id":"blank","type":"assistant","content":[{"type":"text","text":"  "}]}"#.utf8)) == nil)
        #expect(MessageRow(Data(#"{"id":"empty","type":"assistant","content":[],"future":"keep"}"#.utf8)) != nil)
    }
    @Test func reviewRegressionPDFMetadataOnlyAndNoNativeDecoder() throws {
        let card = try FileCardMetadata(["mime": "application/pdf", "name": "untrusted.pdf", "length": 130927, "preview": false])
        #expect(card.name == "untrusted.pdf" && card.length == 130927)
        #expect(throws: ClientError.self) { try FileCardMetadata(["mime": "application/pdf", "name": "x", "length": 1, "preview": true]) }
        #expect(throws: ClientError.self) { try FileCardMetadata(["mime": "application/pdf", "name": "x", "length": 9 * 1024 * 1024, "preview": false]) }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let view = try String(contentsOf: root.appendingPathComponent("native/RichContentViews.swift"))
        #expect(!view.contains("PDFKit") && !view.contains("PDFDocument(") && !view.contains("SafePDFView"))
        let metadataBranch = try #require(view.components(separatedBy: "if value[\"mime\"] as? String == \"application/pdf\" {").last?.components(separatedBy: "guard value[\"preview\"]").first)
        #expect(metadataBranch.contains("return") && !metadataBranch.contains("transport.data("))
    }
}
