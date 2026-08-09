import SwiftUI
import WebKit

enum EmbeddedTerminalStyle {
    static let background = Color(red: 0.090, green: 0.071, blue: 0.059)
    static let nsBackground = NSColor(background)
}

/// WebView 的加载状态，由 WebBridge（导航委托）更新，驱动 SwiftUI 覆盖层。
final class WebViewModel: ObservableObject {
    enum Phase: Equatable {
        case loading
        case ready
        case failed(title: String, message: String, canRetry: Bool)
    }

    @Published var phase: Phase = .loading
    /// 终端缩放百分比标签，由 JS 回填（"100%" 等）。
    @Published var terminalScaleLabel = "100%"
    /// 终端尺寸（列 × 行），由 JS 回填，驱动状态栏显示。
    @Published var terminalSizeLabel = ""
    /// WebBridge 收到 backToNative 消息时调用，由容器视图注入（关闭嵌套网页会话）。
    var requestClose: (() -> Void)?
    /// WebBridge attach 时回填，供"重试"调用 reload()。
    weak var webView: WKWebView?

    func retry() {
        phase = .loading
        webView?.reload()
    }

    // MARK: - 终端缩放（对称 iOS WebContainerView）

    /// 点击网页里隐藏的 scale 按钮（embed=terminal 模式下 CSS display:none，
    /// 但 JS click 仍可触发），delta > 0 放大、delta < 0 缩小。步进 0.25。
    func adjustEmbeddedTerminalScale(delta: Double) {
        runTerminalControlScript(clickElementId: delta < 0 ? "terminal-scale-down-top" : "terminal-scale-up-top")
    }

    /// 直接设缩放到 1.0（100%），不走 step button。
    func resetEmbeddedTerminalScale() {
        let script = """
        (function() {
          var t = window.__wandTerminal;
          if (!t || !t.options) return "100%";
          var base = 13;
          try {
            var b = window.__wandTerminalBaseFontSize;
            if (b) base = b;
          } catch (e) {}
          t.options.fontSize = Math.max(8, base);
          try { localStorage.setItem("wand-terminal-scale", "1"); } catch (e) {}
          var label = document.getElementById("terminal-scale-label-top");
          if (label) label.textContent = "100%";
          if (window.__wandApplyTerminalScale) window.__wandApplyTerminalScale();
          return "100%";
        })();
        """
        DispatchQueue.main.async { [weak self] in
            guard let self, let webView = self.webView else { return }
            webView.evaluateJavaScript(script) { [weak self] _, _ in
                DispatchQueue.main.async { self?.terminalScaleLabel = "100%" }
            }
        }
    }

    func refreshEmbeddedTerminal() {
        runTerminalControlScript(clickElementId: "page-refresh-btn")
    }

    func refreshEmbeddedTerminalScaleLabel() {
        runTerminalControlScript(clickElementId: nil)
    }

    // MARK: - 终端操作

    /// 向 PTY 发送 clear 序列（\x1b[3J + \x1b[H + \x1b[2J），清屏并回滚。
    /// 对齐 Terminal.app / iTerm2 的 Cmd+K 行为。通过 HTTP API 发送，
    /// 不依赖模块作用域里的 WebSocket 句柄。
    func clearTerminal() {
        let script = """
        (function() {
          var ws = null;
          try { ws = window.__wandWs; } catch (e) {}
          if (ws && ws.readyState === 1) {
            var sid = "";
            try { var u = new URL(window.location.href); sid = u.searchParams.get("session") || ""; } catch(e) {}
            var seq = "\\u001b[3J\\u001b[H\\u001b[2J";
            ws.send(JSON.stringify({
              type: "pty_input",
              sessionId: sid,
              data: seq,
              userInput: true
            }));
            return true;
          }
          return false;
        })();
        """
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript(script, completionHandler: nil)
        }
    }

    /// 拉取当前终端 cols/rows（xterm buffer）+ 缩放百分比，回填到 @Published。
    func refreshTerminalInfo() {
        let script = """
        (function() {
          var t = window.__wandTerminal;
          var cols = t ? t.cols : 0;
          var rows = t ? t.rows : 0;
          var label = document.getElementById("terminal-scale-label-top");
          var scale = label ? label.textContent.trim() : "100%";
          if (!scale.endsWith("%")) {
            try { scale = Math.round(Number(localStorage.getItem("wand-terminal-scale") || "1") * 100) + "%"; } catch(e) { scale = "100%"; }
          }
          return { size: cols + "×" + rows, scale: scale };
        })();
        """
        DispatchQueue.main.async { [weak self] in
            guard let self, let webView = self.webView else { return }
            webView.evaluateJavaScript(script) { [weak self] result, _ in
                guard let dict = result as? [String: Any] else { return }
                DispatchQueue.main.async {
                    if let size = dict["size"] as? String, size != "0×0" {
                        self?.terminalSizeLabel = size
                    }
                    if let scale = dict["scale"] as? String, !scale.isEmpty {
                        self?.terminalScaleLabel = scale
                    }
                }
            }
        }
    }

    private func runTerminalControlScript(clickElementId: String?) {
        let clickExpression = clickElementId.map { "'\($0)'" } ?? "null"
        let script = """
        (function() {
          var clickId = \(clickExpression);
          if (clickId) {
            var button = document.getElementById(clickId);
            if (button && typeof button.click === "function") button.click();
          }
          var label = document.getElementById("terminal-scale-label-top");
          if (label && label.textContent) return label.textContent.trim();
          var raw = "1";
          try { raw = localStorage.getItem("wand-terminal-scale") || "1"; } catch (e) {}
          var scale = Number(raw);
          if (!Number.isFinite(scale)) scale = 1;
          return Math.round(scale * 100) + "%";
        })();
        """
        DispatchQueue.main.async { [weak self] in
            guard let self, let webView = self.webView else { return }
            webView.evaluateJavaScript(script) { [weak self] result, _ in
                guard let label = result as? String, !label.isEmpty else { return }
                DispatchQueue.main.async {
                    self?.terminalScaleLabel = label
                }
            }
        }
    }
}

/// 对外的容器视图：底层是 WKWebView，加载中/出错时盖上不透明的主题覆盖层，
/// 彻底消除旧版"加载白屏 + 生硬 NSAlert"的体验问题。
struct WebContainerView: View {
    let serverURL: URL
    let token: String?
    /// 指定后直接深链到对应会话（`?session=<id>`）。
    var sessionId: String? = nil
    /// 嵌入终端模式：URL 带 `embed=terminal`，网页隐藏自己的应用壳，
    /// 会话侧栏和顶栏继续由 macOS 原生主壳呈现。
    var embedTerminal: Bool = false
    /// 原生 PTY 输入栏启用时追加 `nativeInput=1`，网页只负责终端画布。
    var embedNativeInput: Bool = false
    /// 终端直通模式：追加 `passthrough=1`，声明原生壳没有草稿输入层、
    /// xterm 是唯一输入目标。桌面端键盘事件直达 xterm helper-textarea →
    /// WebSocket pty_input，不再经过原生 composer / HTTP API。
    var embedPassthrough: Bool = false
    /// 「返回原生界面」回调；非 nil 时注入 `__wandBackToNative`，网页侧边栏显示「返回App」。
    var onRequestClose: (() -> Void)? = nil

    @EnvironmentObject private var store: ServerStore
    @StateObject private var model: WebViewModel

    init(
        serverURL: URL,
        token: String?,
        sessionId: String? = nil,
        embedTerminal: Bool = false,
        embedNativeInput: Bool = false,
        embedPassthrough: Bool = false,
        webViewModel: WebViewModel? = nil,
        onRequestClose: (() -> Void)? = nil
    ) {
        self.serverURL = serverURL
        self.token = token
        self.sessionId = sessionId
        self.embedTerminal = embedTerminal
        self.embedNativeInput = embedNativeInput
        self.embedPassthrough = embedPassthrough
        self.onRequestClose = onRequestClose
        _model = StateObject(wrappedValue: webViewModel ?? WebViewModel())
    }

    private var displayHost: String {
        if let host = serverURL.host {
            if let port = serverURL.port { return "\(host):\(port)" }
            return host
        }
        return serverURL.absoluteString
    }

    private var containerBackground: Color {
        embedTerminal ? EmbeddedTerminalStyle.background : Theme.background
    }

    var body: some View {
        ZStack {
            containerBackground.ignoresSafeArea()
            WebViewRepresentable(
                serverURL: serverURL,
                token: token,
                sessionId: sessionId,
                embedTerminal: embedTerminal,
                embedNativeInput: embedNativeInput,
                embedPassthrough: embedPassthrough,
                injectsBackToNative: onRequestClose != nil,
                model: model
            )
            overlay
        }
        .onAppear { model.requestClose = onRequestClose }
    }

    @ViewBuilder private var overlay: some View {
        switch model.phase {
        case .loading:
            LoadingOverlay(host: displayHost)
        case .failed(let title, let message, let canRetry):
            ErrorOverlay(
                title: title,
                message: message,
                canRetry: canRetry,
                onRetry: { model.retry() },
                onReconnect: { store.disconnect() }
            )
        case .ready:
            EmptyView()
        }
    }
}

// MARK: - 覆盖层

private struct LoadingOverlay: View {
    let host: String

    var body: some View {
        ZStack {
            Theme.background
            VStack(spacing: 18) {
                WandBrandMark(size: 56)
                ProgressView()
                    .controlSize(.large)
                    .tint(Theme.brand)
                VStack(spacing: 4) {
                    Text("正在连接")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                    Text(host)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(Theme.textSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ErrorOverlay: View {
    let title: String
    let message: String
    let canRetry: Bool
    let onRetry: () -> Void
    let onReconnect: () -> Void

    var body: some View {
        ZStack {
            Theme.background
            VStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(Theme.danger.opacity(0.12))
                        .frame(width: 62, height: 62)
                    Image(systemName: "wifi.exclamationmark")
                        .font(.system(size: 26, weight: .medium))
                        .foregroundColor(Theme.danger)
                }
                Text(title)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(Theme.textPrimary)
                Text(message)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    if canRetry {
                        Button(action: onRetry) {
                            Text("重试").frame(minWidth: 86)
                        }
                        .buttonStyle(WandPrimaryButtonStyle())
                    }
                    Button(action: onReconnect) {
                        Text("重新连接").frame(minWidth: 86)
                    }
                    .buttonStyle(WandSecondaryButtonStyle())
                }
                .padding(.top, 4)
            }
            .padding(40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - WKWebView 桥接

struct WebViewRepresentable: NSViewRepresentable {
    let serverURL: URL
    let token: String?
    var sessionId: String? = nil
    var embedTerminal: Bool = false
    var embedNativeInput: Bool = false
    var embedPassthrough: Bool = false
    /// 是否注入「返回原生界面」入口：注入后新版网页会在侧边栏渲染「返回App」按钮，
    /// 点击 → backToNative 消息 → model.requestClose。网页版主入口不注入（无处可返回）。
    var injectsBackToNative: Bool = false
    let model: WebViewModel

    func makeCoordinator() -> WebBridge {
        WebBridge(model: model)
    }

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        let userController = WKUserContentController()
        userController.add(context.coordinator, name: "wandNative")
        if injectsBackToNative {
            userController.addUserScript(WKUserScript(
                source: """
                window.__wandMacNative = true;
                window.__wandBackToNative = function() {
                  try { window.webkit.messageHandlers.wandNative.postMessage({ type: "backToNative" }); } catch (e) {}
                };
                """,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            ))
        }
        // PTY passthrough 模式注入终端增强：选中即复制、禁用右键菜单干扰、
        // 确保终端 viewport 满铺。这是让 macOS 客户端接近原生终端体验的关键。
        if embedPassthrough {
            userController.addUserScript(WKUserScript(
                source: """
                (function() {
                  window.__wandTerminalEnhance = function() {
                    var t = window.__wandTerminal || (window.state && window.state.terminal);
                    if (!t || t.__wandEnhanced) return;
                    t.__wandEnhanced = true;
                    // 选中即复制到剪贴板（对齐 Terminal.app / iTerm2 默认行为）
                    t.onSelectionChange = function() {
                      var sel = t.getSelection();
                      if (sel && sel.trim()) {
                        try { navigator.clipboard.writeText(sel); } catch (e) {}
                      }
                    };
                  };
                  // 终端初始化可能晚于脚本执行，轮询等待
                  var tries = 0;
                  var iv = setInterval(function() {
                    window.__wandTerminalEnhance();
                    var t = window.__wandTerminal || (window.state && window.state.terminal);
                    if (t || ++tries > 20) clearInterval(iv);
                  }, 250);
                  // 禁止右键菜单弹出（终端区域不需要浏览器上下文菜单）
                  document.addEventListener("contextmenu", function(e) {
                    if (e.target.closest && (e.target.closest(".xterm") || e.target.closest(".terminal-container"))) {
                      e.preventDefault();
                    }
                  }, true);
                })();
                """,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            ))
        }
        cfg.userContentController = userController
        cfg.websiteDataStore = .default()
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: cfg)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.underPageBackgroundColor = embedTerminal
            ? EmbeddedTerminalStyle.nsBackground
            : Theme.nsBackground

        // UA 标记：让前端识别这是 macOS 原生壳
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15 WandApp/\(version) WandPlatform/macOS"

        context.coordinator.attach(webView: webView, serverURL: serverURL)

        // 有 token：先调 /api/login 拿 session cookie 注入 WKHTTPCookieStore，再加载主页。
        // 服务端可能按 scheme 同时下发多份 cookie（__Host-wand_session / wand_session_local /
        // 兼容用的 wand_session），这里全部注入，浏览器请求时按 scheme 选合适的发送。
        // 没有 token：当成裸 URL（ConnectView 已探测过可达性），直接加载。
        let cookieStore = cfg.websiteDataStore.httpCookieStore
        let targetURL = sessionURL()
        if let token, !token.isEmpty {
            NSLog("[Wand] token-login before load: %@", serverURL.absoluteString)
            WandAuth.loginWithToken(serverURL: serverURL, appToken: token) { result in
                switch result {
                case .success(let cookies):
                    DispatchQueue.main.async {
                        let group = DispatchGroup()
                        for cookie in cookies {
                            group.enter()
                            cookieStore.setCookie(cookie) { group.leave() }
                        }
                        group.notify(queue: .main) {
                            NSLog("[Wand] %d cookie(s) injected, loading %@", cookies.count, targetURL.absoluteString)
                            webView.load(URLRequest(url: targetURL))
                        }
                    }
                case .failure(let err):
                    NSLog("[Wand] token-login FAILED: %@", err.userMessage)
                    context.coordinator.fail(
                        title: "无法登录 wand 服务器",
                        message: err.userMessage,
                        canRetry: false
                    )
                }
            }
        } else {
            NSLog("[Wand] no token; loading %@ directly", targetURL.absoluteString)
            webView.load(URLRequest(url: targetURL))
        }
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    /// 带 sessionId 时在主页 URL 上追加 `?session=<id>`；PTY 嵌入模式
    /// 额外追加 `embed=terminal`，让前端隐藏自己的应用壳。
    /// passthrough 模式追加 `passthrough=1`，声明 xterm 为唯一输入目标。
    private func sessionURL() -> URL {
        guard let sessionId, !sessionId.isEmpty,
              var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false) else {
            return serverURL
        }
        var items = components.queryItems ?? []
        items.removeAll { $0.name == "session" || $0.name == "embed" || $0.name == "nativeInput" || $0.name == "passthrough" }
        items.append(URLQueryItem(name: "session", value: sessionId))
        if embedTerminal {
            items.append(URLQueryItem(name: "embed", value: "terminal"))
            if embedPassthrough {
                items.append(URLQueryItem(name: "passthrough", value: "1"))
            }
            if embedNativeInput || embedPassthrough {
                items.append(URLQueryItem(name: "nativeInput", value: "1"))
            }
        }
        components.queryItems = items
        return components.url ?? serverURL
    }
}
