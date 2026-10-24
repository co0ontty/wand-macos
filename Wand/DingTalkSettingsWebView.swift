import SwiftUI
import WebKit

/// The canonical connector flow is shared with Web. Only this isolated browser receives
/// the existing settings-only grant; native API cookies are not elevated or exported to JS.
@MainActor
struct DingTalkSettingsWebView: View {
    let api: WandAPI
    @StateObject private var browser = DingTalkSettingsBrowser()
    var body: some View {
        VStack(spacing: 12) {
            if browser.loading { ProgressView("正在读取钉钉接入…") }
            if let error = browser.error {
                Text(error).font(.callout).foregroundColor(Theme.warning)
                Button("重新读取") { browser.load(api) }.buttonStyle(WandSecondaryButtonStyle())
            }
            if let view = browser.view { DingTalkBrowserSurface(view: view) }
        }
        .frame(maxWidth: .infinity, minHeight: 520, maxHeight: .infinity)
        .task { browser.load(api) }
        .onDisappear { browser.close() }
    }
}

@MainActor
private final class DingTalkSettingsBrowser: NSObject, ObservableObject, WKNavigationDelegate {
    @Published var view: WKWebView?
    @Published var loading = false
    @Published var error: String?
    private var task: Task<Void, Never>?
    private var revision = 0
    private var baseURL: URL?
    func load(_ api: WandAPI) {
        close(); let generation = revision; baseURL = api.baseURL; loading = true; error = nil
        task = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await api.serverConfig()
                let endpoint = api.baseURL.appendingPathComponent("api/settings/webview-session")
                let native = (SelfSignedSession.shared.cookieStorage?.cookies(for: endpoint) ?? [])
                    .filter { WandAuth.sessionCookieNames.contains($0.name) }
                let configuration = URLSessionConfiguration.ephemeral
                configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
                let session = URLSession(configuration: configuration, delegate: DingTalkSettingsBoundary(baseURL: api.baseURL), delegateQueue: nil)
                defer { session.invalidateAndCancel() }
                var request = URLRequest(url: endpoint)
                request.httpMethod = "POST"; request.httpBody = Data("{}".utf8)
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue(HTTPCookie.requestHeaderFields(with: native)["Cookie"], forHTTPHeaderField: "Cookie")
                let (_, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse, http.url == endpoint,
                      (200..<300).contains(http.statusCode) else { throw WandAPI.APIError.network("服务器未授予设置页面访问权限，请重新连接或更新服务。") }
                let headers = http.allHeaderFields.reduce(into: [String: String]()) { result, entry in
                    if let name = entry.key as? String, let value = entry.value as? String { result[name] = value }
                }
                let proof = HTTPCookie.cookies(withResponseHeaderFields: headers, for: endpoint)
                    .filter { $0.name == "wand_settings_access" && !$0.value.isEmpty }
                guard !proof.isEmpty else { throw WandAPI.APIError.network("服务器没有返回设置专用登录态。") }
                guard !Task.isCancelled, revision == generation else { return }
                let web = WKWebViewConfiguration(); web.websiteDataStore = .nonPersistent()
                web.applicationNameForUserAgent = "WandApp/macOS WandPlatform/macOS"
                let prefix = api.baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/"
                let allowed = "^" + NSRegularExpression.escapedPattern(for: prefix)
                let rules: [[String: Any]] = [
                    ["trigger": ["url-filter": ".*"], "action": ["type": "block"]],
                    ["trigger": ["url-filter": allowed], "action": ["type": "ignore-previous-rules"]],
                    ["trigger": ["url-filter": "^(data:|blob:)"], "action": ["type": "ignore-previous-rules"]]
                ]
                let json = String(data: try JSONSerialization.data(withJSONObject: rules), encoding: .utf8)!
                guard let ruleList = try await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "wand-dingtalk-settings-boundary", encodedContentRuleList: json) else { throw WandAPI.APIError.network("无法安装设置页面端点隔离规则。") }
                web.userContentController.add(ruleList)
                for cookie in native + proof { await web.websiteDataStore.httpCookieStore.setCookie(cookie) }
                guard !Task.isCancelled, revision == generation else { return }
                var target = URLComponents(url: api.baseURL.appendingPathComponent("settings"), resolvingAgainstBaseURL: false)!
                target.queryItems = [URLQueryItem(name: "client", value: "app"), URLQueryItem(name: "section", value: "connectors")]
                let view = WKWebView(frame: .zero, configuration: web); view.navigationDelegate = self
                self.view = view; view.load(URLRequest(url: target.url!))
            } catch {
                guard !Task.isCancelled, revision == generation else { return }
                self.error = error.localizedDescription; loading = false
            }
        }
    }
    func close() { revision += 1; task?.cancel(); task = nil; view?.stopLoading(); view?.navigationDelegate = nil; view = nil; loading = false }
    private func contains(_ url: URL) -> Bool {
        guard let baseURL, url.user == nil, url.password == nil,
              url.scheme?.lowercased() == baseURL.scheme?.lowercased(), url.host?.lowercased() == baseURL.host?.lowercased(),
              (url.port ?? (url.scheme == "https" ? 443 : 80)) == (baseURL.port ?? (baseURL.scheme == "https" ? 443 : 80)) else { return false }
        let prefix = baseURL.path.hasSuffix("/") ? baseURL.path : baseURL.path + "/"
        return url.path == baseURL.path || url.path.hasPrefix(prefix)
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url, contains(url) else {
            decisionHandler(.cancel)
            if action.navigationType == .linkActivated, let url = action.request.url, url.user == nil, url.password == nil, url.scheme == "https" { NSWorkspace.shared.open(url) }
            return
        }
        if action.targetFrame == nil { decisionHandler(.cancel); webView.load(action.request) } else { decisionHandler(.allow) }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { if view === webView { loading = false; error = nil } }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { if view === webView { loading = false; self.error = "钉钉设置未能载入，请检查连接后重试。" } }
}

private final class DingTalkSettingsBoundary: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    let baseURL: URL
    init(baseURL: URL) { self.baseURL = baseURL }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.host.lowercased() == baseURL.host?.lowercased(),
              challenge.protectionSpace.port == (baseURL.port ?? (baseURL.scheme == "https" ? 443 : 80)),
              let trust = challenge.protectionSpace.serverTrust else { completionHandler(.performDefaultHandling, nil); return }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
private struct DingTalkBrowserSurface: NSViewRepresentable {
    let view: WKWebView
    func makeNSView(context: Context) -> WKWebView { view }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
