import SwiftUI
import WebKit

/// A single credential-free revision. No URLRequest (and therefore no phone bearer) enters WebKit.
struct CanvasShowWebView: UIViewRepresentable {
    let page: String
    let disabled: Bool
    let send: (String, Any) -> Void
    let open: (URL) -> Void
    let height: (Double) -> Void
    let library: (String) async throws -> String
    func makeCoordinator() -> Delegate { Delegate(send: send, open: open, height: height, library: library) }
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.userContentController.add(context.coordinator, name: "canvasPanel")
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator; view.uiDelegate = context.coordinator
        context.coordinator.view = view
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "canvas-show-network-denied-v1", encodedContentRuleList: CanvasWebPolicy.networkRules) { list, _ in
            guard let list else { return } // A blank panel is safer than loading without the deny rules.
            config.userContentController.add(list)
            view.loadHTMLString(page, baseURL: nil)
        }
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.disabled = disabled
        view.evaluateJavaScript("window.canvasSetDisabled?.(\(disabled ? "true" : "false"))", completionHandler: nil)
    }
    static func dismantleUIView(_ view: WKWebView, coordinator: Delegate) {
        view.stopLoading(); view.configuration.userContentController.removeScriptMessageHandler(forName: "canvasPanel")
        coordinator.view = nil
    }
    final class Delegate: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        weak var view: WKWebView?
        var disabled = false
        let send: (String, Any) -> Void
        let open: (URL) -> Void
        let height: (Double) -> Void
        let library: (String) async throws -> String
        init(send: @escaping (String, Any) -> Void, open: @escaping (URL) -> Void, height: @escaping (Double) -> Void, library: @escaping (String) async throws -> String) { self.send = send; self.open = open; self.height = height; self.library = library }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            if type == "height", let value = body["height"] as? Double, value.isFinite, value > 0 {
                height(min(640, max(1, value)))
            } else if type == "send", !disabled, let action = body["action"] as? String, !action.isEmpty, action.count <= 120 {
                send(action, body["data"] ?? NSNull())
            } else if type == "link", let raw = body["url"] as? String, let url = URL(string: raw), phoneLinkPolicy.web(url) {
                open(url) // Native confirmation and the existing credential-free in-app viewer; never WebKit navigation.
            } else if type == "library", let name = body["name"] as? String, ["tailwind", "chart.js", "d3", "mermaid"].contains(name) {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    do {
                        let source = try await library(name)
                        let json = try JSONSerialization.data(withJSONObject: [name, source])
                        view?.evaluateJavaScript("window.canvasLibraryResult(...\(String(decoding: json, as: UTF8.self)))", completionHandler: nil)
                    } catch { view?.evaluateJavaScript("window.canvasLibraryFailed?.()", completionHandler: nil) }
                }
            }
        }
        func webView(_ view: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let url = action.request.url?.absoluteString ?? ""
            let internalPage = url == "about:blank" || url == "about:srcdoc"
            decisionHandler(internalPage && action.navigationType == .other && !action.shouldPerformDownload ? .allow : .cancel)
        }
        func webView(_ view: WKWebView, didFinish navigation: WKNavigation!) {
            view.evaluateJavaScript("window.canvasSetDisabled?.(\(disabled ? "true" : "false"))", completionHandler: nil)
        }
        func webView(_ view: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            let url = response.response.url?.absoluteString ?? ""
            let download = (response.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")?.lowercased().contains("attachment") == true
            decisionHandler((url == "about:blank" || url == "about:srcdoc") && response.canShowMIMEType && !download ? .allow : .cancel)
        }
        func webView(_ view: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
    }
}
