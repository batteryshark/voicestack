#if DEBUG && targetEnvironment(simulator)
import SwiftUI

final class FixtureCredential: DeviceCredentialStore {
    func load() throws -> String? { nil }
    func save(_ credential: String) throws {}
    func clear() throws {}
}

/// Simulator-only fixture lane. Never prepares PhoneModel, pairs, or contacts a live service.
struct RichContentFixtureScreen: View {
    private let mode = ProcessInfo.processInfo.arguments.last ?? "markdown"
    private let png = "iVBORw0KGgoAAAANSUhEUgAAACAAAAAQCAIAAAD4YuoOAAAAK0lEQVR4nGOQUDOjKWIYtYCgBR4rPpCE/uzwIQmNWjBqwVCwYOjn5CFvAQD4o2QfSD4fZwAAAABJRU5ErkJggg=="
    private var document: CanvasDocument {
        try! JSONDecoder().decode(CanvasDocument.self, from: Data(#"{"title":"Release readiness","summary":"Review the **source-stage** gates before any phone deployment.","diagram":{"nodes":[{"id":"source","label":"Source + fixtures","detail":"Isolated M2 worktree","kind":"store"},{"id":"review","label":"Independent review","detail":"Required before deployment","kind":"process"}],"edges":[{"from":"source","to":"review","label":"verified tests"}]},"sections":[{"title":"Current boundary","body":"- No real conversation writes\n- No phone installation"}],"choices":[{"id":"review","label":"Review the implementation","description":"Inspect the source and test evidence.","prompt":"Review M2 implementation."},{"id":"revise","label":"Revise the panel","description":"Discuss the presentation first.","prompt":"Revise the presentation."}]}"#.utf8))
    }
    var body: some View {
        NavigationStack {
            if mode == "link" {
                RestrictedWebView(url: URL(string: "https://example.org/fixture")!, fixtureHTML: "<meta name='viewport' content='width=device-width'><style>body{background:#181818;color:#eee;font:18px -apple-system;padding:24px}a{color:#7cc5ff}</style><h1>In-app link</h1><p>This is a local fixture page, not a live website.</p><p>The viewer has no bridge credential, scripts, shared cookies, or external-app handoff.</p><a href='https://example.org/fixture'>Same-origin navigation</a>")
                    .navigationTitle("example.org").navigationBarTitleDisplayMode(.inline).toolbar { Button("Done") {} }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(AgentPresentation.name.uppercased()).font(.caption).foregroundStyle(.secondary)
                        if mode == "canvas" { BoundContentView(fixtureDocument: document) }
                        else if mode == "image" {
                            MarkdownView(text: "## A conversation image\nA valid PNG fixture in the native image renderer.")
                            BoundContentView(fixtureImage: UIImage(data: Data(base64Encoded: png)!)!).frame(height: 180).background(.blue.opacity(0.12))
                            Text("32 × 16 PNG · enlarged for proof").font(.caption).foregroundStyle(.secondary)
                            MarkdownView(text: "[Read the fixture guide](https://example.org/fixture)")
                        } else {
                            MarkdownView(text: "## Source-stage gates\n| Gate | Result |\n| --- | --- |\n| Ordered history | Preserved |\n| Native tables | Rendered |\n| Message assets | Bound to lease |\n\n> No phone deployment in this lane.\n\n```swift\nlet lease = TargetLease(\n    sessionID: \"ses_fixture\",\n    generation: \"fixture\"\n)\n```\n\n```md\n### Formatted Markdown details\n- Native blocks, not literal md\n- Links stay in the app\n```\n\n[Read the fixture guide](https://example.org/fixture)")
                        }
                    }.padding().background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14)).padding()
                }.navigationTitle("History").navigationBarTitleDisplayMode(.inline).toolbar { Button("Done") {} }
            }
        }
    }
}
#endif
