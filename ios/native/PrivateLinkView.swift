import SwiftUI
import WebKit

var phoneLinkPolicy: LinkPolicy {
    let suffix = Bundle.main.object(forInfoDictionaryKey: "InstallDeploymentSuffix")
    let manifests = Bundle.main.object(forInfoDictionaryKey: "ApprovedInstallManifests")
    let malformed = (suffix != nil && !(suffix is String)) || (manifests != nil && !(manifests is [String]))
    return LinkPolicy(privilegedHosts: Set((Bundle.main.object(forInfoDictionaryKey: "PrivilegedLinkHosts") as? [String] ?? []) + [URL(string: Bundle.main.object(forInfoDictionaryKey: "BridgeURL") as? String ?? "")?.host ?? ""]),
               approvedManifests: Set(Bundle.main.object(forInfoDictionaryKey: "ApprovedInstallManifests") as? [String] ?? []),
               deploymentSuffix: malformed ? "invalid" : (suffix as? String ?? ""))
}

struct PrivateLinkView: View {
    let url: URL
    @State private var confirm = false
    var body: some View {
        Group {
            if let manifest = phoneLinkPolicy.install(url) {
                VStack(spacing: 20) {
                    Text("Install iPhone app?").font(.headline)
                    Text(manifest.absoluteString).font(.caption).textSelection(.enabled)
                    Text("Only continue if you expected this build. iOS handles installation after confirmation.")
                    Button("Review installation") { confirm = true }.buttonStyle(.borderedProminent)
                }.padding().confirmationDialog("Allow iOS to install this app?", isPresented: $confirm, titleVisibility: .visible) {
                    Button("Install") { UIApplication.shared.open(url) }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Host: \(LinkPolicy.normalizedHost(manifest) ?? "")\nManifest: \(manifest.path.isEmpty ? "/" : manifest.path)")
                }
            } else if phoneLinkPolicy.web(url) { RestrictedWebView(url: url) }
            else { Text("This destination is not available in the unprivileged web viewer.").padding() }
        }.navigationTitle(url.host ?? "Installation").navigationBarTitleDisplayMode(.inline)
    }
}

/// Credential-free, script-free, single-origin browser. Block other origins at the network
/// layer as well as navigation: a page cannot smuggle privileged requests via subresources.
struct RestrictedWebView: UIViewRepresentable {
    let url: URL
    var fixtureHTML: String? = nil
    func makeCoordinator() -> Delegate { Delegate(origin: url, fixture: fixtureHTML != nil) }
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator; view.uiDelegate = context.coordinator
#if DEBUG && targetEnvironment(simulator)
        if let fixtureHTML { view.loadHTMLString(fixtureHTML, baseURL: url); return view }
#endif
        guard let encoded = phoneLinkPolicy.contentRules(for: url) else { context.coordinator.blocked(view); return view }
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: UUID().uuidString, encodedContentRuleList: encoded) { list, _ in
            guard let list else { context.coordinator.blocked(view); return } // Fail closed: never load before network rules exist.
            view.configuration.userContentController.add(list)
            view.load(URLRequest(url: url))
        }
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {}
    final class Delegate: NSObject, WKNavigationDelegate, WKUIDelegate {
        let origin: URL
        let fixture: Bool
        init(origin: URL, fixture: Bool) { self.origin = origin; self.fixture = fixture }
        func blocked(_ view: WKWebView) {
            let label = UILabel(frame: view.bounds.insetBy(dx: 24, dy: 24)); label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            label.text = "This page could not be opened safely. Redirects, downloads, and privileged destinations are blocked."
            label.numberOfLines = 0; label.textAlignment = .center; label.textColor = .secondaryLabel
            view.addSubview(label)
        }
        func allowed(_ url: URL?) -> Bool {
            guard let url else { return false }
#if DEBUG && targetEnvironment(simulator)
            if fixture && url.absoluteString == "about:blank" { return true }
#endif
            return phoneLinkPolicy.web(url) && url.host == origin.host && url.port == origin.port
        }
        func webView(_ view: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let permit = allowed(action.request.url) && action.targetFrame?.isMainFrame != false && !action.shouldPerformDownload
            if !permit && action.targetFrame?.isMainFrame != false { blocked(view) }
            decisionHandler(permit ? .allow : .cancel)
        }
        func webView(_ view: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            let download = (response.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")?.lowercased().contains("attachment") == true
            decisionHandler(allowed(response.response.url) && response.isForMainFrame && response.canShowMIMEType && !download ? .allow : .cancel)
        }
        func webView(_ view: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if allowed(action.request.url) { view.load(URLRequest(url: action.request.url!)) }; return nil
        }
        func webView(_ view: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { blocked(view) }
        func webView(_ view: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { blocked(view) }
    }
}
