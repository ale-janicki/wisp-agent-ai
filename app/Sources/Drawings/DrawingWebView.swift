import AppKit
import SwiftUI
import WebKit
import WispCore

@MainActor
final class DrawingSchemeHandler: NSObject, WKURLSchemeHandler {
    private let root: URL

    init(root: URL) {
        self.root = root
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url,
              let file = DrawingContentSecurity.resolve(urlPath: url.path, inside: root),
              let data = try? Data(contentsOf: file) else {
            respond(urlSchemeTask, status: 404, mime: "text/plain", body: Data())
            return
        }
        respond(urlSchemeTask, status: 200, mime: DrawingContentSecurity.mimeType(forPath: file.path), body: data)
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}

    private func respond(_ task: any WKURLSchemeTask, status: Int, mime: String, body: Data) {
        guard let url = task.request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [
                  "Content-Type": mime,
                  "Content-Length": String(body.count),
                  "Content-Security-Policy": DrawingContentSecurity.policy,
                  "Access-Control-Allow-Origin": "*",
                  "Cache-Control": "no-store",
              ]) else {
            task.didFailWithError(URLError(.badURL))
            return
        }
        task.didReceive(response)
        task.didReceive(body)
        task.didFinish()
    }
}

private final class ScriptMessageProxy: NSObject, WKScriptMessageHandler {
    private let deliver: @MainActor (Any) -> Void

    init(deliver: @escaping @MainActor (Any) -> Void) {
        self.deliver = deliver
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body
        MainActor.assumeIsolated { deliver(body) }
    }
}

@MainActor
final class DrawingWebHost: NSObject, WKNavigationDelegate, WKUIDelegate {
    static let resourceFolder = "Excalidraw"

    let webView: WKWebView
    var onEvent: (DrawingBridgeEvent) -> Void = { _ in }
    private(set) var resourcesPresent = false
    private var proxy: ScriptMessageProxy?

    override init() {
        let root = Bundle.main.resourceURL?.appendingPathComponent(Self.resourceFolder, isDirectory: true)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        if let root {
            configuration.setURLSchemeHandler(DrawingSchemeHandler(root: root), forURLScheme: DrawingContentSecurity.scheme)
        }
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        resourcesPresent = root.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("index.html").path) } ?? false
        let proxy = ScriptMessageProxy { [weak self] body in
            guard let event = DrawingBridgeEvent.decode(body) else { return }
            self?.onEvent(event)
        }
        self.proxy = proxy
        configuration.userContentController.add(proxy, name: DrawingBridgeEvent.handlerName)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
    }

    func loadPage() {
        guard resourcesPresent, let url = URL(string: "\(DrawingContentSecurity.scheme)://\(DrawingContentSecurity.host)/") else { return }
        webView.load(URLRequest(url: url))
    }

    func send(_ command: DrawingBridgeCommand) {
        webView.evaluateJavaScript(command.script, completionHandler: nil)
    }

    func tearDown() {
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: DrawingBridgeEvent.handlerName)
        proxy = nil
        onEvent = { _ in }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.request.url?.scheme == DrawingContentSecurity.scheme ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        nil
    }
}

struct DrawingWebHostView: NSViewRepresentable {
    let host: DrawingWebHost

    func makeNSView(context: Context) -> WKWebView { host.webView }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
