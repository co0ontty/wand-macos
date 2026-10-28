import AppKit
import SwiftUI
import WebKit
import Quartz

private struct MessageAPIKey: EnvironmentKey { static let defaultValue: WandAPI? = nil }
private struct MessageSourceKey: EnvironmentKey { static let defaultValue = WandMessageFileContext() }
extension EnvironmentValues {
    var messageLinkAPI: WandAPI? {
        get { self[MessageAPIKey.self] }
        set { self[MessageAPIKey.self] = newValue }
    }
    var messageFileContext: WandMessageFileContext {
        get { self[MessageSourceKey.self] }
        set { self[MessageSourceKey.self] = newValue }
    }
}

func messageLinkedText(_ text: String) -> AttributedString {
    (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
}

/// Uploaded attachment paths are filesystem bytes, not URI navigation syntax.
func messageAttachmentURL(_ path: String) -> URL? {
    var components = URLComponents()
    components.path = path
    return components.url
}

private struct MessageLinkHandling: ViewModifier {
    @Environment(\.messageLinkAPI) private var api
    @Environment(\.messageFileContext) private var source
    let baseURL: URL?
    func body(content: Content) -> some View {
        content.environment(\.openURL, OpenURLAction { url in
            guard let baseURL else { return .discarded }
            let destination = WandMessageLink.resolve(url.absoluteString, baseURL: baseURL, context: source)
            switch destination {
            case .external(let target): return .systemAction(target)
            case .unavailable(let reason): MessageLinkPresenter.shared.showError(reason)
            default:
                guard let api, MessageLinkBoundary.sameOrigin(api.baseURL, baseURL) else {
                    MessageLinkPresenter.shared.showError("请连接文件所属的 Wand 服务后重试。")
                    return .handled
                }
                MessageLinkPresenter.shared.open(destination, api: api)
            }
            return .handled
        })
    }
}
extension View {
    func messageLinkHandling(baseURL: URL?) -> some View { modifier(MessageLinkHandling(baseURL: baseURL)) }
}

/// No native script bridge, shared browser cookie jar, or arbitrary authenticated URL loading.
final class MessageLinkBoundary: NSObject, URLSessionTaskDelegate, URLSessionDownloadDelegate, @unchecked Sendable {
    let origin: URL
    init(origin: URL) { self.origin = origin }
    static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.user == nil && lhs.password == nil && rhs.user == nil && rhs.password == nil &&
        lhs.scheme?.lowercased() == rhs.scheme?.lowercased() && lhs.host?.lowercased() == rhs.host?.lowercased() &&
        (lhs.port ?? (lhs.scheme == "https" ? 443 : 80)) == (rhs.port ?? (rhs.scheme == "https" ? 443 : 80))
    }
    func allows(_ url: URL) -> Bool {
        guard Self.sameOrigin(origin, url), WandEndpointScope(origin)?.contains(url) == true else { return false }
        let base = origin.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let prefix = base.isEmpty ? "" : "/" + base
        guard url.path.hasPrefix(prefix + "/api/") else { return false }
        let route = String(url.path.dropFirst(prefix.count))
        return route == "/api/file-raw" || route == "/api/file-preview" ||
            route.hasPrefix("/api/session-file/") || route.hasPrefix("/api/local-file/") || route.hasPrefix("/api/local-preview/")
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.map(allows) == true ? request : nil)
    }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.host.lowercased() == origin.host?.lowercased(),
              challenge.protectionSpace.port == (origin.port ?? (origin.scheme == "https" ? 443 : 80)),
              let trust = challenge.protectionSpace.serverTrust else { completionHandler(.performDefaultHandling, nil); return }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        // URLSession streams downloads to disk; never buffer the artifact in memory.
    }
    static func previewScope(_ url: URL, origin: URL) -> String? {
        let boundary = MessageLinkBoundary(origin: origin)
        guard boundary.allows(url) else { return nil }
        let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path
        for marker in ["/api/local-file/", "/api/local-preview/"] {
            guard let range = path.range(of: marker) else { continue }
            let segments = path[range.upperBound...].split(separator: "/", omittingEmptySubsequences: true)
            let count = marker.contains("local-file") ? 1 : 2
            guard segments.count >= count else { return nil }
            return String(path[..<range.upperBound]) + segments.prefix(count).joined(separator: "/") + "/"
        }
        return nil
    }
    static func nonHTMLFileDownload(_ response: HTTPURLResponse, origin: URL) -> URL? {
        guard (200..<300).contains(response.statusCode), response.mimeType?.lowercased() != "text/html",
              let target = response.url, let route = WandMessageLink.endpointRoute(target, baseURL: origin) else { return nil }
        if route.percentEncodedPath.hasPrefix("/api/local-preview/") { return target }
        guard route.percentEncodedPath.hasPrefix("/api/local-file/") else { return nil }
        return WandMessageLink.withFileAction(target, action: "download")
    }
    static func isolatedHTML(_ response: HTTPURLResponse) -> Bool {
        let directives = (response.value(forHTTPHeaderField: "Content-Security-Policy") ?? "")
            .lowercased().split(separator: ";").map { $0.split(whereSeparator: { $0.isWhitespace }).map(String.init) }
        guard response.mimeType?.lowercased() == "text/html",
              let sandbox = directives.first(where: { $0.first == "sandbox" }),
              Set(sandbox.dropFirst()).isSubset(of: ["allow-scripts", "allow-forms"]),
              directives.contains(["form-action", "'none'"]), directives.contains(["connect-src", "'none'"]) else { return false }
        return true
    }
}

@MainActor
final class MessageLinkPreviewModel: NSObject, ObservableObject, WKNavigationDelegate {
    @Published var loading = false
    @Published var error: String?
    @Published var browser: WKWebView?
    @Published var localFile: URL?
    private var task: Task<Void, Never>?
    private var revision = 0
    private var session: URLSession?
    private var boundary: MessageLinkBoundary?
    private var scope: String?
    private var ruleID: String?
    private var destination: WandMessageLinkDestination?
    private var api: WandAPI?

    func load(_ destination: WandMessageLinkDestination, api: WandAPI) {
        close(); self.destination = destination; self.api = api
        let generation = revision
        loading = true; error = nil
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let url: URL
                let preview: Bool
                let name: String
                switch destination {
                case .preview(let target, let title): url = target; preview = true; name = title
                case .download(let target, let title): url = target; preview = false; name = title
                default: throw WandAPI.APIError.invalidURL
                }
                let boundary = MessageLinkBoundary(origin: api.baseURL)
                guard boundary.allows(url) else { throw WandAPI.APIError.invalidURL }
                self.boundary = boundary
                var cookies = (SelfSignedSession.shared.cookieStorage?.cookies(for: api.baseURL) ?? []).filter { WandAuth.sessionCookieNames.contains($0.name) }
                if cookies.isEmpty, let token = api.token, !token.isEmpty {
                    let loginConfiguration = URLSessionConfiguration.ephemeral
                    loginConfiguration.httpCookieStorage = nil; loginConfiguration.httpShouldSetCookies = false
                    let loginSession = URLSession(configuration: loginConfiguration, delegate: boundary, delegateQueue: nil)
                    defer { loginSession.invalidateAndCancel() }
                    let loginURL = api.baseURL.appendingPathComponent("api/login")
                    var login = URLRequest(url: loginURL)
                    login.httpMethod = "POST"; login.timeoutInterval = 15
                    login.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    login.httpBody = try JSONSerialization.data(withJSONObject: ["appToken": token])
                    let (_, response) = try await loginSession.data(for: login)
                    guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                          http.url == loginURL else { throw WandAPI.APIError.unauthorized }
                    let headers = http.allHeaderFields.reduce(into: [String: String]()) { result, pair in
                        if let key = pair.key as? String, let value = pair.value as? String { result[key] = value }
                    }
                    cookies = HTTPCookie.cookies(withResponseHeaderFields: headers, for: loginURL)
                        .filter { WandAuth.sessionCookieNames.contains($0.name) }
                    guard !cookies.isEmpty else { throw WandAPI.APIError.unauthorized }
                }
                guard !Task.isCancelled, revision == generation else { return }
                let configuration = URLSessionConfiguration.ephemeral
                configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
                configuration.timeoutIntervalForRequest = 20; configuration.timeoutIntervalForResource = 600
                let session = URLSession(configuration: configuration, delegate: boundary, delegateQueue: nil)
                self.session = session
                var request = URLRequest(url: url)
                request.setValue(HTTPCookie.requestHeaderFields(with: cookies)["Cookie"], forHTTPHeaderField: "Cookie")
                request.cachePolicy = .reloadIgnoringLocalCacheData
                if preview {
                    request.httpMethod = "HEAD"
                    let (_, headResponse) = try await session.data(for: request)
                    var response = headResponse
                    if let status = (headResponse as? HTTPURLResponse)?.statusCode, [405, 501].contains(status) {
                        request.httpMethod = "GET"
                        let (bytes, getResponse) = try await session.bytes(for: request)
                        bytes.task.cancel() // Readiness needs headers only; never buffer the document.
                        response = getResponse
                    }
                    guard let http = response as? HTTPURLResponse else { throw WandAPI.APIError.network("文件响应无效。") }
                    try checkResponse(http)
                    if let download = MessageLinkBoundary.nonHTMLFileDownload(http, origin: api.baseURL) {
                        // Existing local-file URLs may address a PDF or other artifact.
                        // Let the server MIME choose, without guessing from extensions.
                        load(.download(download, name: name), api: api)
                        return
                    }
                    guard let finalURL = http.url, MessageLinkBoundary.isolatedHTML(http),
                          let scope = MessageLinkBoundary.previewScope(finalURL, origin: api.baseURL) else {
                        throw WandAPI.APIError.network("此页面未提供隔离的 HTML 预览，请更新 Wand 服务或下载文件后查看。")
                    }
                    let web = WKWebViewConfiguration(); web.websiteDataStore = .nonPersistent()
                    let allowedURL = URL(string: scope, relativeTo: api.baseURL)!.absoluteURL.absoluteString
                    let rules: [[String: Any]] = [
                        ["trigger": ["url-filter": ".*"], "action": ["type": "block"]],
                        ["trigger": ["url-filter": "^" + NSRegularExpression.escapedPattern(for: allowedURL)], "action": ["type": "ignore-previous-rules"]],
                        ["trigger": ["url-filter": "^data:"], "action": ["type": "ignore-previous-rules"]],
                        ["trigger": ["url-filter": "^blob:"], "action": ["type": "ignore-previous-rules"]]
                    ]
                    let json = String(data: try JSONSerialization.data(withJSONObject: rules), encoding: .utf8)!
                    let ruleID = "wand-message-preview-" + UUID().uuidString
                    guard let rule = try await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: ruleID, encodedContentRuleList: json) else { throw WandAPI.APIError.network("无法初始化文件隔离规则。") }
                    guard !Task.isCancelled, revision == generation else {
                        WKContentRuleListStore.default().removeContentRuleList(forIdentifier: ruleID) { _ in }
                        return
                    }
                    self.ruleID = ruleID
                    web.userContentController.add(rule)
                    for cookie in cookies { await web.websiteDataStore.httpCookieStore.setCookie(cookie) }
                    guard !Task.isCancelled, revision == generation else { return }
                    self.scope = scope
                    var final = URLComponents(url: finalURL, resolvingAgainstBaseURL: false)!
                    if final.fragment == nil { final.percentEncodedFragment = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedFragment }
                    let view = WKWebView(frame: .zero, configuration: web)
                    view.navigationDelegate = self
                    self.browser = view
                    view.load(URLRequest(url: final.url!))
                } else {
                    let (temporary, response) = try await session.download(for: request)
                    defer { try? FileManager.default.removeItem(at: temporary) }
                    guard let http = response as? HTTPURLResponse else { throw WandAPI.APIError.network("文件响应无效。") }
                    try checkResponse(http)
                    guard !Task.isCancelled, revision == generation else { return }
                    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wand-message-" + UUID().uuidString)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let receivedName = http.suggestedFilename ?? name
                    let safe = Self.safeName(receivedName)
                    let saved = directory.appendingPathComponent(safe)
                    try FileManager.default.moveItem(at: temporary, to: saved)
                    localFile = saved; loading = false
                }
            } catch {
                guard !Task.isCancelled, revision == generation else { return }
                self.error = error.localizedDescription; loading = false
            }
        }
    }
    private func checkResponse(_ response: HTTPURLResponse) throws {
        guard (200..<300).contains(response.statusCode) else {
            let message = response.statusCode == 401 || response.statusCode == 403 ? "没有文件访问权限或登录已失效，请重新连接。" : response.statusCode == 404 ? "文件或页面不存在，可能已移动。" : response.statusCode == 502 ? "本地预览服务未启动，请启动后重试。" : "读取文件失败（HTTP \(response.statusCode)）。"
            throw WandAPI.APIError.server(status: response.statusCode, message: message)
        }
    }
    static func safeName(_ value: String) -> String {
        let result = value.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) || "/\\".unicodeScalars.contains($0) ? "_" : String($0) }.joined()
        return result.isEmpty || result == "." || result == ".." ? "wand-file" : String(result.prefix(180))
    }
    func retry() { if let destination, let api { load(destination, api: api) } }
    func close() {
        revision += 1; task?.cancel(); task = nil; session?.invalidateAndCancel(); session = nil
        browser?.stopLoading(); browser?.navigationDelegate = nil; browser = nil; loading = false
        if let localFile { try? FileManager.default.removeItem(at: localFile.deletingLastPathComponent()) }
        localFile = nil; boundary = nil; scope = nil
        if let ruleID { WKContentRuleListStore.default().removeContentRuleList(forIdentifier: ruleID) { _ in } }
        ruleID = nil
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url, boundary?.allows(url) == true, let scope, (URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath.hasPrefix(scope) == true) else {
            decisionHandler(.cancel)
            if action.navigationType == .linkActivated, let url = action.request.url,
               url.user == nil, url.password == nil, ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(url) }
            return
        }
        guard action.targetFrame?.isMainFrame == true else { decisionHandler(.cancel); return }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard let origin = boundary?.origin, challenge.protectionSpace.host.lowercased() == origin.host?.lowercased(),
              challenge.protectionSpace.port == (origin.port ?? (origin.scheme == "https" ? 443 : 80)),
              challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else { completionHandler(.performDefaultHandling, nil); return }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        guard response.isForMainFrame, let http = response.response as? HTTPURLResponse,
              let url = http.url, boundary?.allows(url) == true, let scope, (URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath.hasPrefix(scope) == true),
              (200..<300).contains(http.statusCode), MessageLinkBoundary.isolatedHTML(http) else {
            loading = false; error = "页面没有提供隔离的 HTML 预览，已停止加载。"
            decisionHandler(.cancel); return
        }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loading = false }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { if (error as NSError).code != NSURLErrorCancelled { loading = false; self.error = error.localizedDescription } }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { if (error as NSError).code != NSURLErrorCancelled { loading = false; self.error = error.localizedDescription } }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { loading = false; error = "预览进程已结束，请重试。" }
}

@MainActor
final class MessageLinkPresenter: NSObject, NSWindowDelegate {
    static let shared = MessageLinkPresenter()
    private var window: NSWindow?
    private var model: MessageLinkPreviewModel?
    func open(_ destination: WandMessageLinkDestination, api: WandAPI) {
        close()
        let model = MessageLinkPreviewModel(); self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 680), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "文件预览"; window.isReleasedWhenClosed = false; window.delegate = self
        window.contentView = NSHostingView(rootView: MessageLinkPreviewSurface(model: model, close: { [weak self] in self?.close() }))
        window.center(); self.window = window; window.makeKeyAndOrderFront(nil)
        model.load(destination, api: api)
    }
    func showError(_ message: String) { let alert = NSAlert(); alert.messageText = "无法打开链接"; alert.informativeText = message; alert.addButton(withTitle: "好"); alert.runModal() }
    func close() { model?.close(); model = nil; window?.delegate = nil; window?.close(); window = nil }
    func windowWillClose(_ notification: Notification) { close() }
}
private struct MessageLinkPreviewSurface: View {
    @ObservedObject var model: MessageLinkPreviewModel
    let close: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("文件预览").font(.headline)
                Spacer()
                if let local = model.localFile {
                    Button("保存副本…") {
                        let panel = NSSavePanel(); panel.nameFieldStringValue = local.lastPathComponent
                        if panel.runModal() == .OK, let destination = panel.url {
                            do {
                                let manager = FileManager.default
                                let staged = destination.deletingLastPathComponent().appendingPathComponent(".wand-save-" + UUID().uuidString)
                                defer { try? manager.removeItem(at: staged) }
                                try manager.copyItem(at: local, to: staged)
                                if manager.fileExists(atPath: destination.path) { _ = try manager.replaceItemAt(destination, withItemAt: staged) }
                                else { try manager.moveItem(at: staged, to: destination) }
                            }
                            catch { model.error = error.localizedDescription }
                        }
                    }
                }
                Button("关闭", action: close).keyboardShortcut(.cancelAction)
            }.padding(12)
            Divider()
            if model.loading { ProgressView("正在加载预览…").padding(16) }
            if let error = model.error {
                VStack(spacing: 12) { Text(error).foregroundColor(Theme.warning).textSelection(.enabled); Button("重试") { model.retry() } }.padding(20)
            }
            if let browser = model.browser { MessageWebSurface(view: browser) }
            else if let file = model.localFile { MessageQuickLookSurface(file: file) }
            else { Spacer() }
        }.frame(minWidth: 560, minHeight: 400).background(Theme.background)
    }
}
private struct MessageWebSurface: NSViewRepresentable {
    let view: WKWebView
    func makeNSView(context: Context) -> WKWebView { view }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
private struct MessageQuickLookSurface: NSViewRepresentable {
    let file: URL
    func makeNSView(context: Context) -> QLPreviewView { QLPreviewView(frame: .zero, style: .normal)! }
    func updateNSView(_ view: QLPreviewView, context: Context) { view.previewItem = file as NSURL }
}
