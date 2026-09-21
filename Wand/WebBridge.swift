import AppKit
import WebKit

/// JS → 原生消息处理 + 自签名证书 + WKWebView 委托。导航状态通过 `WebViewModel`
/// 驱动 SwiftUI 覆盖层（加载中 / 出错），不再用 NSAlert 打断用户。
final class WebBridge: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    private let model: WebViewModel
    private weak var webView: WKWebView?
    private var serverURL: URL?
    private var hasLoadedOnce = false

    init(model: WebViewModel) {
        self.model = model
    }

    func attach(webView: WKWebView, serverURL: URL) {
        self.webView = webView
        self.serverURL = serverURL
        self.model.webView = webView
    }

    /// 切换到错误覆盖层（主线程）。token 登录失败时由 WebViewRepresentable 调用。
    func fail(title: String, message: String, canRetry: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.model.phase = .failed(title: title, message: message, canRetry: canRetry)
        }
    }

    // MARK: - JS → Native

    func userContentController(_ uc: WKUserContentController, didReceive msg: WKScriptMessage) {
        let origin = msg.frameInfo.securityOrigin
        guard msg.frameInfo.isMainFrame,
              isServerOrigin(scheme: origin.protocol, host: origin.host, port: origin.port) else { return }
        guard let dict = msg.body as? [String: Any], let type = dict["type"] as? String else { return }
        switch type {
        case "downloadUpdate", "checkAppUpdate":
            // 兼容旧 Web UI 的 downloadUpdate 消息，但不再接受连接服务器提供的
            // 任意 DMG URL。macOS 客户端始终通过官方 GitHub Release 更新。
            Task { @MainActor in
                await UpdateFlowController.shared.checkManually()
            }
        case "backToNative":
            DispatchQueue.main.async { [weak self] in
                self?.model.requestClose?()
            }
        default:
            break
        }
    }

    private func isServerOrigin(scheme: String, host: String, port: Int?) -> Bool {
        guard let serverURL,
              scheme.lowercased() == serverURL.scheme?.lowercased(),
              host.lowercased() == serverURL.host?.lowercased() else { return false }
        let defaultPort = scheme.lowercased() == "https" ? 443 : 80
        let actualPort = (port ?? 0) == 0 ? defaultPort : port!
        return actualPort == (serverURL.port ?? defaultPort)
    }

    /// External pages belong in the browser, where they cannot inherit the
    /// native message handler or masquerade as the connected server's tools.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard navigationAction.targetFrame?.isMainFrame != false,
              let url = navigationAction.request.url,
              let scheme = url.scheme?.lowercased() else {
            decisionHandler(.allow)
            return
        }
        if ["http", "https"].contains(scheme),
           !isServerOrigin(scheme: scheme, host: url.host ?? "", port: url.port) {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        if scheme == "mailto" {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(["http", "https", "about", "blob", "data"].contains(scheme) ? .allow : .cancel)
    }

    // MARK: - Self-signed HTTPS / Auth challenge

    /// 对自签名证书一律放行：只要是 HTTPS 的 server trust 类型，就用拿到的 trust 构造
    /// URLCredential 喂回去；否则走默认处理（http basic / digest 等服务端用不到的场景）。
    func webView(_ webView: WKWebView,
                 didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping @MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        let method = space.authenticationMethod
        let host = space.host
        let port = space.port
        let proto = space.protocol ?? "?"

        if method == NSURLAuthenticationMethodServerTrust {
            if let trust = space.serverTrust {
                NSLog("[Wand] auth challenge: trust granted host=%@ port=%ld proto=%@", host, port, proto)
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                NSLog("[Wand] auth challenge: serverTrust nil host=%@ — falling back to default", host)
                completionHandler(.performDefaultHandling, nil)
            }
            return
        }

        NSLog("[Wand] auth challenge: non-ServerTrust method=%@ host=%@ — default handling", method, host)
        completionHandler(.performDefaultHandling, nil)
    }

    // MARK: - Navigation lifecycle / diagnostics

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        NSLog("[Wand] navigation start: %@", webView.url?.absoluteString ?? "?")
        // 仅首屏加载（或显式重试）显示加载层；会话中途的局部跳转不打扰用户。
        if !hasLoadedOnce {
            model.phase = .loading
        }
        model.cancelDesktopToolNavigation()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let ns = error as NSError
        if ns.code == NSURLErrorCancelled { return } // 被新导航/reload 打断，不算错误
        let url = webView.url?.absoluteString ?? serverURL?.absoluteString ?? "?"
        NSLog("[Wand] provisional navigation FAILED url=%@ domain=%@ code=%ld reason=%@",
              url, ns.domain, ns.code, ns.localizedDescription)
        showLoadError(error: ns, url: url)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let ns = error as NSError
        if ns.code == NSURLErrorCancelled { return }
        NSLog("[Wand] navigation FAILED domain=%@ code=%ld reason=%@", ns.domain, ns.code, ns.localizedDescription)
        showLoadError(error: ns, url: webView.url?.absoluteString ?? serverURL?.absoluteString ?? "?")
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        NSLog("[Wand] navigation committed: %@", webView.url?.absoluteString ?? "?")
    }

    private func showLoadError(error: NSError, url: String) {
        let message = """
        \(url)
        \(error.localizedDescription)（\(error.domain) #\(error.code)）

        请确认 wand 服务正在运行，并检查地址是否正确。
        """
        model.phase = .failed(title: "无法加载 wand 服务器", message: message, canRetry: true)
    }

    // MARK: - Lifecycle

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        NSLog("[Wand] navigation finished: %@", webView.url?.absoluteString ?? "?")
        hasLoadedOnce = true
        model.finishNavigation()
    }

    // File inputs back attachments and certificate uploads in server tools.
    // Keep selection in the standard macOS picker, including cancellation.
    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping ([URL]?) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        panel.begin { response in
            completionHandler(response == .OK ? panel.urls : nil)
        }
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard navigationAction.targetFrame == nil, let url = navigationAction.request.url,
              ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        NSWorkspace.shared.open(url)
        return nil
    }
}
