import SwiftUI

struct CanvasShowPanel: View {
    let backend: RemoteSessionBackend
    let lease: TargetLease
    let messageID: String
    let reference: ContentReference
    @State private var panelID: String?
    @State private var page: String?
    @State private var title = "Canvas panel"
    @State private var summary = ""
    @State private var stale = false
    @State private var viewIdentity = ""
    @State private var revision = 0
    @State private var notes = ""
    @FocusState private var notesFocused: Bool
    @State private var status: String?
    @State private var delivery: String?
    @State private var submissionID = UUID().uuidString
    @State private var submitted: [String: Any]?
    @State private var sending = false
    @State private var pendingLink: URL?
    @State private var link: LinkDestination?
    @State private var confirmLink = false
    @State private var panelHeight = 300.0
    @State private var loadOwner = UUID()
    private var route: String { "/v1/sessions/\(lease.sessionID)/canvas-show/" }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Canvas", systemImage: "rectangle.3.group").font(.caption).foregroundStyle(.secondary).accessibilityLabel(title)
            if !summary.isEmpty { Text(summary).font(.caption) }
            if revision > 0 { Text("Revision \(revision)").font(.caption2).foregroundStyle(.secondary).accessibilityIdentifier("canvas.revision." + messageID).accessibilityValue(viewIdentity + ":" + String(revision)) }
            if stale {
                Text("This panel changed. Reload the latest revision before choosing.").foregroundStyle(.orange).font(.caption)
                Button("Reload latest revision") { Task { await load(latest: true) } }.disabled(sending || backend.lease != lease)
            }
            if let page, let displayedPanelID = panelID {
                CanvasShowWebView(page: page, disabled: stale || submitted != nil || backend.lease != lease, send: { action, data in
                    Task { await submit(action: action, data: data, expectedPanelID: displayedPanelID) }
                }, open: { url in if panelID == displayedPanelID { pendingLink = url; confirmLink = true } }, height: { value in if panelID == displayedPanelID && abs(value - panelHeight) > 2 { panelHeight = value } }, library: { name in try await loadLibrary(name, expectedPanelID: displayedPanelID) })
                .frame(height: panelHeight)
                .accessibilityIdentifier("canvas.show." + messageID)
                .id(panelID) // Explicit reload creates a new credential-free page; old callbacks stay lease-bound.
                TextField("Optional note", text: $notes).textFieldStyle(.roundedBorder).disabled(submitted != nil || stale)
                    .focused($notesFocused).onSubmit { notesFocused = false }
            } else if status == nil { ProgressView("Loading panel") }
            if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
            if delivery == "unsent" { Button("Retry confirmed unsent input") { Task { await deliver(retry: true) } }.disabled(sending || stale || backend.lease != lease) }
        }.task { await load() }
            .confirmationDialog("Open this link in the app?", isPresented: $confirmLink, titleVisibility: .visible) {
                Button("Open link") { if backend.lease == lease, let pendingLink, phoneLinkPolicy.web(pendingLink) { link = LinkDestination(url: pendingLink) } }
                Button("Cancel", role: .cancel) {}
            } message: { Text(pendingLink?.host ?? "") }
            .sheet(item: $link) { destination in NavigationStack { PrivateLinkView(url: destination.url).toolbar { Button("Done") { link = nil } } } }
    }
    @MainActor private func load(latest: Bool = false) async {
        let owner = UUID(); loadOwner = owner
        do {
            guard backend.lease == lease else { return }
            page = nil; panelID = nil; status = nil
            let value = try await backend.transport.json(route + "resolve", method: "POST", body: ["messageID": messageID, "blockOrdinal": reference.blockOrdinal, "latest": latest], lease: lease)
            try Task.checkCancellation(); guard backend.lease == lease, loadOwner == owner, let id = value["panelID"] as? String else { return }
            panelID = id; title = value["title"] as? String ?? "Canvas panel"; summary = value["summary"] as? String ?? ""
            viewIdentity = value["viewId"] as? String ?? ""; revision = value["revision"] as? Int ?? 0
            stale = (value["latest"] as? Int) != (value["revision"] as? Int)
            let source = try await resource("page", panelID: id)
            try Task.checkCancellation(); guard backend.lease == lease, loadOwner == owner, panelID == id else { return }
            page = source
        } catch is CancellationError {} catch { if loadOwner == owner && backend.lease == lease { status = "Panel unavailable. Reopen when connected." } }
    }
    @MainActor private func loadLibrary(_ name: String, expectedPanelID: String) async throws -> String {
        guard backend.lease == lease, let panelID, panelID == expectedPanelID else { throw CancellationError() }
        return try await resource("library", panelID: panelID, name: name)
    }
    @MainActor private func resource(_ operation: String, panelID: String, name: String? = nil) async throws -> String {
        var bytes = Data(), offset = 0, expectedTotal: Int?
        repeat {
            try Task.checkCancellation(); guard backend.lease == lease, self.panelID == panelID else { throw CancellationError() }
            var body: [String: Any] = ["panelID": panelID, "offset": offset]
            if let name { body["name"] = name }
            let result = try await backend.transport.json(route + operation, method: "POST", body: body, lease: lease)
            guard backend.lease == lease, self.panelID == panelID else { throw CancellationError() }
            if operation == "page", let latest = result["latest"] as? Int { stale = latest != revision }
            guard backend.lease == lease, let encoded = result["chunk"] as? String, let chunk = Data(base64Encoded: encoded), !chunk.isEmpty, chunk.count <= 96 * 1024,
                  let total = result["total"] as? Int, total > 0, total <= 8 * 1024 * 1024, expectedTotal == nil || expectedTotal == total else { throw ClientError("Invalid renderer chunk") }
            expectedTotal = total; bytes.append(chunk)
            guard bytes.count <= total else { throw ClientError("Invalid renderer length") }
            if let next = result["nextOffset"] as? Int {
                guard next == bytes.count, next > offset, next < total else { throw ClientError("Invalid renderer offset") }; offset = next
            } else {
                guard bytes.count == total, let source = String(data: bytes, encoding: .utf8) else { throw ClientError("Incomplete renderer") }
                return source
            }
        } while true
    }
    @MainActor private func submit(action: String, data: Any, expectedPanelID: String) async {
        notesFocused = false
        guard backend.lease == lease, !stale, submitted == nil, let panelID, panelID == expectedPanelID else { return }
        submitted = ["panelID": panelID, "id": submissionID, "action": action, "data": data, "notes": notes]
        await deliver()
    }
    @MainActor private func deliver(retry: Bool = false) async {
        guard backend.lease == lease, !stale, !sending, let body = submitted else { return }
        sending = true; defer { sending = false }
        var admitted = false
        do {
            let result = try await backend.transport.json(route + (retry ? "retry" : "submit"), method: "POST", body: body, lease: lease)
            admitted = true
            try await CanvasDeliveryPolling.run(initial: result["status"] as? String, check: {
                guard backend.lease == lease, panelID == body["panelID"] as? String else { throw CancellationError() }
            }, fetchStatus: {
                let value = try await backend.transport.json(route + "status", method: "POST", body: body, lease: lease)
                return value["status"] as? String
            }) { state in
                delivery = state.rawValue; status = state.message
            }
        } catch {
            let code: Int? = { if case let HTTPError.status(code, _) = error { return code }; return nil }()
            switch CanvasSubmissionPolicy.failure(status: code, admitted: admitted) {
            case .invalid:
                submitted = nil; delivery = nil
                status = "Input was not sent. Shorten or correct the form/note, then submit again."
            case .stale:
                submitted = nil; delivery = nil; stale = true
                status = "Panel changed; this input was not sent. Reload the latest revision."
            case .unknown:
                delivery = CanvasDeliveryStatus.uncertain.rawValue
                status = CanvasDeliveryStatus.uncertain.message
            }
        }
    }
}
