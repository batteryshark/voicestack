import SwiftUI
import WebKit
#if DEBUG && targetEnvironment(simulator)
import Network

/// Injected only by native tests; no environment/launch switches or device build surface.
struct RestrictedWebRuntimeFixture {
    let proxyPort: UInt16
    let leafDER: Data
    let origins: Set<String>
}
#endif

var phoneLinkPolicy: LinkPolicy {
    LinkPolicy(privilegedHosts: Set((Bundle.main.object(forInfoDictionaryKey: "PrivilegedLinkHosts") as? [String] ?? []) + [URL(string: Bundle.main.object(forInfoDictionaryKey: "BridgeURL") as? String ?? "")?.host ?? ""]),
               approvedManifests: Set(Bundle.main.object(forInfoDictionaryKey: "ApprovedInstallManifests") as? [String] ?? []))
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
#if DEBUG && targetEnvironment(simulator)
    var runtimeFixture: RestrictedWebRuntimeFixture? = nil
#endif
    func makeCoordinator() -> Delegate {
        let delegate = Delegate(origin: url, fixture: fixtureHTML != nil)
#if DEBUG && targetEnvironment(simulator)
        delegate.runtimeFixture = runtimeFixture
#endif
        return delegate
    }
    func makeUIView(context: Context) -> WKWebView {
        makeWebView(delegate: context.coordinator)
    }
    // Shared by UIViewRepresentable and native XCTest; same configuration and load path.
    func makeWebView(delegate: Delegate) -> WKWebView {
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
#if DEBUG && targetEnvironment(simulator)
        if let runtimeFixture {
            var proxy = ProxyConfiguration(httpCONNECTProxy: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: runtimeFixture.proxyPort)!))
            proxy.allowFailover = false
            config.websiteDataStore.proxyConfigurations = [proxy]
        }
#endif
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = delegate; view.uiDelegate = delegate
#if DEBUG && targetEnvironment(simulator)
        if let fixtureHTML { view.loadHTMLString(fixtureHTML, baseURL: url); return view }
#endif
        guard let encoded = phoneLinkPolicy.contentRules(for: url) else { delegate.blocked(view); return view }
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: UUID().uuidString, encodedContentRuleList: encoded) { list, _ in
            guard let list else { delegate.blocked(view); return } // Fail closed: never load before network rules exist.
            view.configuration.userContentController.add(list)
            view.load(URLRequest(url: url))
        }
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {}
    final class Delegate: NSObject, WKNavigationDelegate, WKUIDelegate {
        let origin: URL
        let fixture: Bool
#if DEBUG && targetEnvironment(simulator)
        var runtimeFixture: RestrictedWebRuntimeFixture?
        var runtimeEvent: ((String) -> Void)?
#endif
        init(origin: URL, fixture: Bool) { self.origin = origin; self.fixture = fixture }
        func blocked(_ view: WKWebView) {
#if DEBUG && targetEnvironment(simulator)
            runtimeEvent?("blocked")
#endif
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
            // A nil target is a new window (including target=_blank), never retarget it.
            let permit = allowed(action.request.url) && action.targetFrame?.isMainFrame == true && action.request.httpMethod == "GET" && !action.shouldPerformDownload
            if !permit && action.targetFrame?.isMainFrame == true { blocked(view) }
#if DEBUG && targetEnvironment(simulator)
            if !permit { runtimeEvent?("actionDenied") }
#endif
            decisionHandler(permit ? .allow : .cancel)
        }
        func webView(_ view: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            let download = (response.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")?.lowercased().contains("attachment") == true
            let document = ["text/html", "text/plain"].contains(response.response.mimeType?.lowercased() ?? "")
            let permit = allowed(response.response.url) && response.isForMainFrame && document && response.canShowMIMEType && !download
#if DEBUG && targetEnvironment(simulator)
            if !permit { runtimeEvent?("responseDenied") }
#endif
            decisionHandler(permit ? .allow : .cancel)
        }
        func webView(_ view: WKWebView, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
#if DEBUG && targetEnvironment(simulator)
            if let runtimeFixture, challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
               runtimeFixture.origins.contains("\(challenge.protectionSpace.host):\(challenge.protectionSpace.port)"),
               let trust = challenge.protectionSpace.serverTrust,
               let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first,
               SecCertificateCopyData(leaf) as Data == runtimeFixture.leafDER {
                completionHandler(.useCredential, URLCredential(trust: trust)); return
            }
#endif
            // Normal system TLS validation only; never supply HTTP/client credentials.
#if DEBUG && targetEnvironment(simulator)
            if challenge.protectionSpace.authenticationMethod != NSURLAuthenticationMethodServerTrust { runtimeEvent?("credentialDenied") }
#endif
            completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
        }
        func webView(_ view: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            return nil // New windows are consistently cancelled, without new visible UI.
        }
        func webView(_ view: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { blocked(view) }
        func webView(_ view: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { blocked(view) }
#if DEBUG && targetEnvironment(simulator)
        func webView(_ view: WKWebView, didFinish navigation: WKNavigation!) { runtimeEvent?("finished") }
#endif
    }
}
