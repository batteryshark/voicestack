import SwiftUI

struct MessageContentView: View {
    @ObservedObject var model: PhoneModel
    let row: MessageRow
    let part: MessageBody
    var ordinal: Int = 0
    var body: some View {
        if let reference = part.reference, let backend = model.backend, let lease = backend.lease {
            if reference.format == "canvas_show" {
                CanvasShowPanel(backend: backend, lease: lease, messageID: row.id, reference: reference)
                    .id("\(lease.sessionID):\(lease.generation):\(row.id):\(reference)")
            } else {
                BoundContentView(backend: backend, lease: lease, messageID: row.id, reference: reference, label: part.markdown)
                    .id("\(lease.sessionID):\(lease.generation):\(row.id):\(reference)")
            }
        } else if part.rawDetail != nil {
            Text("Additional content isn't available in this view.").font(.caption).foregroundStyle(.secondary)
        } else if part.markdown.hasPrefix("See raw record") {
            Text("This content isn't available in this view.").font(.caption).foregroundStyle(.secondary)
        } else if let label = part.label {
            DisclosureGroup("Worked · " + label) {
                if let command = part.command { MarkdownView(blocks: [.code("Shell command · display only", command)]) }
                MarkdownView(blocks: part.blocks)
            }.font(.caption).accessibilityIdentifier("history.work." + row.id + "." + String(ordinal))
        } else { MarkdownView(blocks: part.blocks) }
    }
}

struct BoundContentView: View {
    let backend: RemoteSessionBackend
    let lease: TargetLease
    let messageID: String
    let reference: ContentReference
    let label: String
    @State private var image: UIImage?
    @State private var fileCard: FileCardMetadata?
    @State private var panel: CanvasDocument?
    @State private var panelID: String?
    @State private var revision = 0
    @State private var latest = 0
    @State private var error: String?
    @State private var status: String?
    @State private var submissionID = UUID().uuidString
    @State private var sending = false
    @State private var submitted = false
    @State private var selectedChoice: String?
    @State private var deliveryStatus: String?
    private var fixture = false
    init(backend: RemoteSessionBackend, lease: TargetLease, messageID: String, reference: ContentReference, label: String) {
        self.backend = backend; self.lease = lease; self.messageID = messageID; self.reference = reference; self.label = label
    }
#if DEBUG && targetEnvironment(simulator)
    init(fixtureDocument: CanvasDocument? = nil, fixtureImage: UIImage? = nil) {
        let transport = try! BridgeTransport(base: URL(string: "https://fixture.invalid/floating-voice")!, credentials: FixtureCredential())
        backend = RemoteSessionBackend(transport: transport); lease = TargetLease(sessionID: "ses_fixture", generation: "fixture")
        messageID = "msg_fixture"; reference = ContentReference(kind: "canvas", blockOrdinal: 0); label = "Conversation image"
        _panel = State(initialValue: fixtureDocument); _image = State(initialValue: fixtureImage)
        _revision = State(initialValue: 1); _latest = State(initialValue: 1); fixture = true
    }
#endif
    private var route: String { "/v1/sessions/\(lease.sessionID)" }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let panel {
                Label(panel.title, systemImage: "rectangle.3.group").font(.headline)
                if let summary = panel.summary, !summary.isEmpty { MarkdownView(text: summary) }
                if let graph = panel.diagram {
                    ForEach(graph.nodes) { node in
                        VStack(alignment: .leading) {
                            Text(node.label).bold(); MarkdownView(text: node.detail)
                            ForEach(Array(graph.edges.filter { $0.from == node.id }.enumerated()), id: \.offset) { _, edge in
                                Text("→ \(graph.nodes.first { $0.id == edge.to }?.label ?? "Related item")\(edge.label.map { " · " + $0 } ?? "")").font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
                ForEach(Array(panel.sections.enumerated()), id: \.offset) { _, section in
                    Text(section.title).font(.headline); MarkdownView(text: section.body)
                }
                ForEach(panel.choices) { choice in
                    Button { Task { await submit(choice.id) } } label: {
                        VStack(alignment: .leading) { Text(choice.label).bold(); Text(choice.description).font(.caption) }.frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.bordered).disabled(sending || submitted || revision != latest || backend.lease != lease)
                }
                if revision != latest { Text("Newer revision available. Review its message before choosing.").font(.caption).foregroundStyle(.orange) }
            } else if let image { Image(uiImage: image).resizable().scaledToFit().accessibilityLabel(label.isEmpty ? "Conversation image" : label) }
            else if let fileCard { FileCardView(metadata: fileCard) }
            else if error == nil { ProgressView(label.isEmpty ? "Loading content" : label) }
            if error != nil { Text("Preview unavailable. Try again when connected.").font(.caption).foregroundStyle(.secondary) }
            if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
            if deliveryStatus == "unsent", let selectedChoice { Button("Retry confirmed unsent choice") { Task { await submit(selectedChoice, retry: true) } }.disabled(sending || backend.lease != lease) }
        }.task { await load() }
    }
    @MainActor private func load() async {
        guard !fixture else { return }
        do {
            guard backend.lease == lease else { throw CancellationError() }
            if reference.kind == "canvas" {
                let value = try await backend.transport.json(route + "/canvas/resolve", method: "POST", body: ["messageID": messageID, "blockOrdinal": reference.blockOrdinal], lease: lease)
                try Task.checkCancellation(); guard backend.lease == lease else { return }
                panel = try JSONDecoder().decode(CanvasDocument.self, from: JSONSerialization.data(withJSONObject: value["document"] as Any))
                panelID = value["panelID"] as? String; revision = value["revision"] as? Int ?? 0; latest = value["latest"] as? Int ?? 0
            } else {
                let value = try await backend.transport.json(route + "/assets/resolve", method: "POST", body: ["messageID": messageID, "reference": reference.json], lease: lease)
                try Task.checkCancellation(); guard backend.lease == lease else { return }
                if value["mime"] as? String == "application/pdf" {
                    fileCard = try FileCardMetadata(value)
                    return // Metadata only. Never fetch PDF bytes, even if a server supplies an assetID.
                }
                guard value["preview"] as? Bool == true, let id = value["assetID"] as? String,
                      ["image/png", "image/jpeg"].contains(value["mime"] as? String ?? "") else { throw ClientError("Unsupported preview") }
                let bytes = try await backend.transport.data(route + "/assets/" + id, lease: lease)
                try Task.checkCancellation(); guard backend.lease == lease else { return }
                guard let decoded = UIImage(data: bytes) else { throw ClientError("Invalid image bytes") }; image = decoded
            }
        } catch is CancellationError {} catch {
            if backend.lease == lease {
                StageDiagnostics.shared.record(.history, .failed, status: StageDiagnostics.code(error))
                self.error = "Preview unavailable"
            }
        }
    }
    @MainActor private func submit(_ choice: String, retry: Bool = false) async {
        guard backend.lease == lease, let panelID, !sending, (!submitted || (retry && deliveryStatus == "unsent")) else { return }
        selectedChoice = choice
        sending = true; submitted = true; defer { sending = false }
        do {
            let body: [String: Any] = ["panelID": panelID, "id": submissionID, "choiceID": choice]
            var result = try await backend.transport.json(route + (retry ? "/canvas/retry" : "/canvas/submit"), method: "POST", body: body, lease: lease)
            for _ in 0..<20 {
                try Task.checkCancellation(); guard backend.lease == lease else { return }
                deliveryStatus = result["status"] as? String ?? "uncertain"
                switch deliveryStatus {
                case "queued", "sending": status = "Sending your choice…"
                case "sent", "delivered", "acknowledged": status = "Choice sent"
                case "unsent": status = "Not sent. You can try again."
                default: status = "Couldn't confirm delivery. Check History before trying again."
                }
                guard ["queued", "sending"].contains(deliveryStatus ?? "") else { return }
                try await Task.sleep(nanoseconds: 1_500_000_000)
                guard backend.lease == lease else { return }
                result = try await backend.transport.json(route + "/canvas/status", method: "POST", body: body, lease: lease)
            }
        } catch { status = "Delivery unknown · check History; not retried" }
    }
}

struct FileCardView: View {
    let metadata: FileCardMetadata
    var body: some View {
        HStack {
            Image(systemName: "doc")
            VStack(alignment: .leading) {
                Text(metadata.name)
                Text("PDF · " + ByteCountFormatter.string(fromByteCount: Int64(metadata.length), countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                Text("Inline preview disabled").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }
}
