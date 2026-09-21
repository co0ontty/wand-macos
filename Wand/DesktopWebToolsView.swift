import SwiftUI

/// Discoverable destinations for capabilities owned by the connected server.
/// One web view stays alive while moving between destinations, preserving login,
/// selected sessions, open files and the server's own validation/permission UI.
enum DesktopWebTool: String, CaseIterable, Identifiable {
    case completeWeb
    case files
    case githubIssues
    case connectors
    case general
    case ai
    case notifications
    case display
    case security
    case presets
    case serverUpdates

    var id: String { rawValue }

    var title: String {
        switch self {
        case .completeWeb: return "完整控制台"
        case .files: return "文件与编辑器"
        case .githubIssues: return "GitHub Issues"
        case .connectors: return "连接器"
        case .general: return "服务与工作环境"
        case .ai: return "AI 与模型"
        case .notifications: return "通知"
        case .display: return "内容显示"
        case .security: return "安全"
        case .presets: return "命令预设"
        case .serverUpdates: return "服务端与 CLI 更新"
        }
    }

    var subtitle: String {
        switch self {
        case .completeWeb: return "访问全部会话、技能、文件编辑与工作区功能。"
        case .files: return "浏览、编辑、新建、重命名和移动服务器上的文件。"
        case .githubIssues: return "查看和创建 Issue，将协作事项关联到会话。"
        case .connectors: return "管理 GitHub 与外部服务连接。"
        case .general: return "设置默认目录、Shell、执行模式与服务连接。"
        case .ai: return "管理六种开发工具的默认模型、API 线路与提交生成。"
        case .notifications: return "管理 Web 控制台的提示音与气泡；系统提醒以页面显示的支持状态为准。"
        case .display: return "设置代码、工具结果和思考过程的默认展开方式。"
        case .security: return "使用管理员权限管理密码和 HTTPS 证书。"
        case .presets: return "查看服务器保存的常用命令模板。"
        case .serverUpdates: return "管理服务端和开发 CLI 更新，查看客户端连接码。"
        }
    }

    var symbol: String {
        switch self {
        case .completeWeb: return "globe"
        case .files: return "folder"
        case .githubIssues: return "checklist"
        case .connectors: return "link"
        case .general: return "server.rack"
        case .ai: return "sparkles"
        case .notifications: return "bell"
        case .display: return "text.alignleft"
        case .security: return "lock.shield"
        case .presets: return "terminal"
        case .serverUpdates: return "arrow.down.circle"
        }
    }

    var settingsTab: String? {
        switch self {
        case .connectors, .general, .ai, .notifications, .display, .security, .presets:
            return rawValue
        case .serverUpdates: return "about"
        case .completeWeb, .files, .githubIssues: return nil
        }
    }

    static let workflowTools: [DesktopWebTool] = [.completeWeb, .files, .githubIssues]
    static let settingsTools: [DesktopWebTool] = allCases.filter { $0.settingsTab != nil }

    /// Calls the same public controllers as the browser UI. No DOM clicks, API
    /// mutations or administrator privilege are synthesized by the native shell.
    var navigationScript: String {
        let open: String
        if let tab = settingsTab {
            open = "settings.open(\"\(tab)\");"
        } else {
            switch self {
            case .files:
                open = """
                if (!window.__wandDesktopTools.openFiles()) return { status: "waiting" };
                """
            case .githubIssues:
                open = """
                let sessionId = "";
                if (window.__wandDesktopTools?.getSelectedSessionId) {
                  sessionId = window.__wandDesktopTools.getSelectedSessionId();
                } else {
                  try { sessionId = localStorage.getItem("wand-selected-session") || ""; } catch (_) {}
                }
                window.__wandReactGithubIssues.open(sessionId);
                """
            default:
                open = ""
            }
        }
        return """
        (() => {
          const settings = window.__wandReactSettings;
          if (!settings || !document.querySelector('#app[data-react-shell="enabled"]')) {
            return { status: "waiting" };
          }
          \(self == .files ? "if (!window.__wandDesktopTools) return { status: \"unsupported\" };" : "")
          \(self == .githubIssues ? "if (!window.__wandReactGithubIssues) return { status: \"unsupported\" };" : "")
          const missions = window.__wandReactMissions;
          if (missions && missions.isOpen() && !missions.closeIfOpen()) {
            return { status: "busy" };
          }
          \(settingsTab == nil ? "settings.close();" : "")
          if (window.__wandReactGithubIssues) window.__wandReactGithubIssues.close();
          \(open)
          return { status: "opened" };
        })();
        """
    }
}

struct DesktopWebToolsView: View {
    let serverURL: URL
    let token: String?
    let sessionId: String?
    let onDismiss: () -> Void

    @State private var selection: DesktopWebTool
    @State private var hoveredTool: DesktopWebTool?
    @State private var confirmDiscard = false
    @State private var checkingClose = false
    @State private var closeError: String?
    @StateObject private var webModel = WebViewModel()

    init(
        serverURL: URL,
        token: String?,
        initialTool: DesktopWebTool = .general,
        sessionId: String? = nil,
        onDismiss: @escaping () -> Void
    ) {
        self.serverURL = serverURL
        self.token = token
        self.sessionId = sessionId
        self.onDismiss = onDismiss
        _selection = State(initialValue: initialTool)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "square.stack.3d.up")
                    .foregroundColor(Theme.textSecondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text("工具与服务设置")
                        .font(.system(size: 15, weight: .semibold))
                    Text(serverURL.host ?? "当前服务器")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textSecondary)
                }
                Spacer()
                Button("完成", action: requestDismiss)
                    .keyboardShortcut(.cancelAction)
                    .disabled(checkingClose)
            }
            .padding(.horizontal, 20)
            .frame(height: 64)
            Divider()
            HStack(spacing: 0) {
                sidebar
                Divider()
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .center, spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(selection.title)
                                .font(.system(size: 18, weight: .semibold))
                            Text(selection.subtitle)
                                .font(.system(size: 12))
                                .foregroundColor(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        Button {
                            webModel.openDesktopTool(selection)
                        } label: {
                            Image(systemName: "arrow.up.forward.app")
                        }
                        .help("重新定位到\(selection.title)")
                        .accessibilityLabel("重新定位到\(selection.title)")
                    }
                    .padding(20)
                    if let closeError {
                        Text(closeError)
                            .font(.system(size: 12))
                            .foregroundColor(Theme.warning)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 10)
                    }
                    navigationStatus
                    WebContainerView(
                        serverURL: serverURL,
                        token: token,
                        sessionId: sessionId,
                        webViewModel: webModel,
                        onRequestClose: requestDismiss
                    )
                }
            }
        }
        .frame(minWidth: 880, idealWidth: 1_120, minHeight: 540, idealHeight: 760)
        .background(Theme.background)
        .interactiveDismissDisabled(true)
        .confirmationDialog(
            "放弃未保存的文件修改？",
            isPresented: $confirmDiscard,
            titleVisibility: .visible
        ) {
            Button("继续编辑", role: .cancel) {}
            Button("放弃修改并关闭", role: .destructive, action: onDismiss)
        } message: {
            Text("工具窗口关闭后，尚未保存到服务器的文件修改将丢失。")
        }
        .onAppear { webModel.openDesktopTool(selection) }
        .onChange(of: selection) { webModel.openDesktopTool($0) }
        .onDisappear { webModel.cancelDesktopToolNavigation() }
    }

    private func requestDismiss() {
        guard !checkingClose else { return }
        guard let webView = webModel.webView else { onDismiss(); return }
        checkingClose = true
        closeError = nil
        webView.evaluateJavaScript("window.__wandDesktopTools?.getCloseState?.() || 'ready'") { value, _ in
            checkingClose = false
            switch value as? String {
            case "unsaved": confirmDiscard = true
            case "busy": closeError = "文件正在保存，请等待保存完成后再关闭。"
            default: onDismiss()
            }
        }
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                toolGroup("工作", tools: DesktopWebTool.workflowTools)
                toolGroup("服务器设置", tools: DesktopWebTool.settingsTools)
            }
            .padding(12)
        }
        .frame(width: 208)
        .background(Theme.surface)
    }

    private func toolGroup(_ title: String, tools: [DesktopWebTool]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(Theme.textMuted)
                .padding(.horizontal, 10)
                .padding(.top, 14)
                .padding(.bottom, 5)
            ForEach(tools) { tool in
                Button {
                    if selection == tool { webModel.openDesktopTool(tool) }
                    else { selection = tool }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: tool.symbol).frame(width: 17)
                        Text(tool.title).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 12, weight: selection == tool ? .semibold : .regular))
                    .foregroundColor(selection == tool ? Theme.textPrimary : Theme.textSecondary)
                    .padding(.horizontal, 10)
                    .frame(height: 36)
                    .contentShape(Rectangle())
                    .background(RoundedRectangle(cornerRadius: 8).fill(
                        selection == tool ? Theme.textPrimary.opacity(0.07)
                            : hoveredTool == tool ? Theme.textPrimary.opacity(0.035) : Color.clear
                    ))
                }
                .buttonStyle(.plain)
                .onHover { hoveredTool = $0 ? tool : nil }
                .help(tool.subtitle)
                .accessibilityAddTraits(selection == tool ? .isSelected : [])
            }
        }
    }

    @ViewBuilder private var navigationStatus: some View {
        switch webModel.desktopToolNavigation {
        case .idle, .opened:
            EmptyView()
        case .opening:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在打开\(selection.title)…")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textSecondary)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        case .failed(let message):
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "info.circle").foregroundColor(Theme.warning)
                Text(message).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("重试") { webModel.openDesktopTool(selection) }
                Button("完整控制台") { selection = .completeWeb }
            }
            .padding(12)
            .background(Theme.warning.opacity(0.08))
        }
    }
}
