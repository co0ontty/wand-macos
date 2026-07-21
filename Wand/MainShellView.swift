import Combine
import SwiftUI

/// 横屏 native 应用主壳:原生窗口工具栏 + 三栏(左会话 / 中聊天 / 右文件)。
/// 窗口 < 1100 时自动折叠右栏,只留左 + 中;窗口 < 800 时建议横屏。
///
/// 三栏宽度常量对齐 web 端 token(`.sidebar-width: 300px`, `.file-panel-width: 320px`),
/// 顶部操作统一放进 macOS 原生 toolbar，内容区不再额外绘制应用顶栏。
struct MainShellView: View {
    let serverURL: URL
    let token: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var filePanelOpen: Bool = true
    @State private var rightPanelTab: RightPanelTab = .files
    /// 当前选中的会话 id。
    @State private var selectedSessionId: String?
    @State private var selectedSessionProvider: String = "claude"
    @State private var selectedSession: SessionSnapshot?
    /// 连接状态(给顶栏的 connection dot 用)。
    @State private var connectionState: ConnectionState = .connecting
    @State private var showTroubleshooting = false

    private var api: WandAPI { WandAPI(baseURL: serverURL, token: token) }

    enum ConnectionState {
        case connecting
        case connected
        case disconnected(String)
    }

    enum RightPanelTab: String, CaseIterable, Identifiable {
        case files
        case git
        case details
        var id: String { rawValue }

        var label: String {
            switch self {
            case .files: return "文件"
            case .git: return "Git"
            case .details: return "详情"
            }
        }

        var systemImage: String {
            switch self {
            case .files: return "folder"
            case .git: return "arrow.triangle.branch"
            case .details: return "info.circle"
            }
        }
    }

    /// 面板属于偶发的空间变化，使用无过冲的短弹簧让打开/关闭有连续性。
    /// 会话切换、标签点击等高频路径不复用这个动画，保持即时。
    private var structuralAnimation: Animation? {
        reduceMotion
            ? nil
            : .interactiveSpring(response: 0.32, dampingFraction: 0.94, blendDuration: 0.08)
    }

    var body: some View {
        Group {
            if showWebFallback {
                WebFallbackContainer(
                    serverURL: serverURL,
                    token: token,
                    sessionId: selectedSessionId
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                nativeShell
            }
        }
        .toolbar { windowToolbar }
        .sheet(isPresented: $presentSettings) {
            SettingsView(
                serverURL: serverURL,
                token: token,
                onOpenWeb: {
                    presentSettings = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        showWebFallback = true
                    }
                }
            )
            .environmentObject(ServerStore.shared)
        }
        .sheet(isPresented: $showTroubleshooting) {
            TroubleshootingView(
                context: TroubleshootingContext(
                    serverURL: serverURL,
                    errorMessage: disconnectedMessage,
                    source: "主窗口连接状态"
                ),
                onRetry: checkConnection
            )
        }
        .task {
            await checkConnectionAsync()
        }
        .onChange(of: selectedSessionId) { id in
            if id == nil {
                selectedSession = nil
            }
        }
    }

    private var nativeShell: some View {
        GeometryReader { geo in
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(WandAmbientBackground())
            .frame(minWidth: 900, minHeight: 600)
            .overlay(alignment: .bottom) {
                if geo.size.width < 800 {
                    Text("建议横屏使用,体验更佳")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Theme.surface.opacity(0.9))
                        )
                        .wandGlassCard(cornerRadius: 999)
                        .padding(.bottom, 8)
                }
            }
            .onChange(of: geo.size.width) { newWidth in
                // < 1100 自动折叠右栏,避免中栏被压扁
                if newWidth < 1100 && filePanelOpen {
                    withAnimation(structuralAnimation) {
                        filePanelOpen = false
                    }
                }
            }
            .onAppear {
                if geo.size.width < 1100 {
                    filePanelOpen = false
                }
            }
        }
    }

    // MARK: - 原生窗口工具栏

    @ToolbarContentBuilder
    private var windowToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            if showWebFallback {
                Button {
                    showWebFallback = false
                } label: {
                    Label("返回原生界面", systemImage: "chevron.backward")
                }
                .help("返回原生界面")
            } else {
                toolbarIdentityMenu
            }
        }

        ToolbarItem(placement: .principal) {
            if showWebFallback {
                Label("网页版", systemImage: "safari")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
            }
        }

        // 会话标题与 Git 操作由 ChatView 提供；这里不再放一个竞争性的 principal
        // 项，避免窄窗口时标题、路径和全局操作彼此挤压。
        ToolbarItemGroup(placement: .primaryAction) {
            filePanelToolbarButton
                .opacity(showWebFallback ? 0 : 1)
                .disabled(showWebFallback)
            applicationToolbarMenu
                .opacity(showWebFallback ? 0 : 1)
                .disabled(showWebFallback)
        }
    }

    /// 左侧只承载全局身份和连接状态。把服务器信息做成可点击的菜单，而非一个
    /// 只能靠悬停理解的绿/红小点；既不抢会话标题的位置，也能直接抵达恢复动作。
    private var toolbarIdentityMenu: some View {
        Menu {
            Section("服务器") {
                Label(displayHost, systemImage: "server.rack")
                Label(connectionMenuStatus, systemImage: connectionSystemImage)
            }

            Divider()

            Button {
                checkConnection()
            } label: {
                Label("重新连接", systemImage: "arrow.clockwise")
            }

            if case .disconnected = connectionState {
                Button {
                    showTroubleshooting = true
                } label: {
                    Label("故障排查", systemImage: "stethoscope")
                }
            }

            Divider()

            Button {
                NotificationCenter.default.post(name: .wandRequestSwitchServer, object: nil)
            } label: {
                Label("切换服务器…", systemImage: "server.rack")
            }
        } label: {
            HStack(spacing: 7) {
                WandBrandMark(size: 18)
                Text("Wand")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                toolbarConnectionBadge
            }
            .fixedSize()
        }
        .menuStyle(.borderlessButton)
        .help("\(connectionHelp) · \(displayHost)")
        .accessibilityLabel("Wand，\(connectionAccessibilityValue)")
        .accessibilityHint("打开服务器状态与连接操作")
    }

    /// 文件栏是唯一的高频全局动作，保留在工具栏上并用文字明确它影响的区域。
    private var filePanelToolbarButton: some View {
        Button {
            withAnimation(structuralAnimation) {
                filePanelOpen.toggle()
            }
        } label: {
            Label(
                filePanelOpen ? "隐藏文件" : "显示文件",
                systemImage: filePanelOpen ? "sidebar.right" : "sidebar.squares.right"
            )
        }
        .buttonStyle(.borderless)
        .help(filePanelOpen ? "隐藏文件面板" : "显示文件面板")
        .accessibilityLabel(filePanelOpen ? "隐藏文件面板" : "显示文件面板")
    }

    /// 将低频应用级操作归入有语义的“设置与更多”，取代难以预测的省略号菜单。
    private var applicationToolbarMenu: some View {
        Menu {
            Button {
                presentSettings = true
            } label: {
                Label("设置…", systemImage: "gearshape")
            }

            Button {
                showWebFallback = true
            } label: {
                Label("打开网页版", systemImage: "safari")
            }
        } label: {
            Label("设置与更多", systemImage: "gearshape")
        }
        .menuStyle(.borderlessButton)
        .help("设置与更多")
        .accessibilityLabel("设置与更多")
    }

    private var toolbarConnectionBadge: some View {
        HStack(spacing: 4) {
            toolbarConnectionIndicator
            Text(connectionShortLabel)
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundColor(connectionTint)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            Capsule(style: .continuous)
                .fill(connectionTint.opacity(0.12))
        )
        // Menu 已提供完整的、可朗读的状态；避免 VoiceOver 在同一控件里重复。
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var toolbarConnectionIndicator: some View {
        switch connectionState {
        case .connecting:
            ProgressView()
                .controlSize(.mini)
                .tint(connectionTint)
        case .connected, .disconnected:
            Image(systemName: connectionSystemImage)
                .font(.system(size: 10, weight: .semibold))
        }
    }

    private var connectionTint: Color {
        switch connectionState {
        case .connecting: return Theme.warning
        case .connected: return Theme.success
        case .disconnected: return Theme.danger
        }
    }

    private var connectionSystemImage: String {
        switch connectionState {
        case .connecting: return "arrow.triangle.2.circlepath"
        case .connected: return "checkmark.circle.fill"
        case .disconnected: return "exclamationmark.triangle.fill"
        }
    }

    private var connectionShortLabel: String {
        switch connectionState {
        case .connecting: return "连接中"
        case .connected: return "已连接"
        case .disconnected: return "未连接"
        }
    }

    private var connectionMenuStatus: String {
        switch connectionState {
        case .connecting: return "正在连接"
        case .connected: return "已连接"
        case .disconnected(let message): return "连接失败：\(message)"
        }
    }

    private var connectionAccessibilityValue: String {
        "\(connectionMenuStatus)，服务器 \(displayHost)"
    }

    private var displayHost: String {
        guard let host = serverURL.host else { return serverURL.absoluteString }
        if let port = serverURL.port { return "\(host):\(port)" }
        return host
    }

    private var connectionHelp: String {
        switch connectionState {
        case .connecting: return "正在连接服务器"
        case .connected: return "服务器已连接"
        case .disconnected(let message): return "服务器连接失败：\(message)"
        }
    }

    private var disconnectedMessage: String? {
        if case .disconnected(let message) = connectionState { return message }
        return nil
    }

    private func checkConnection() {
        Task { await checkConnectionAsync() }
    }

    private func checkConnectionAsync() async {
        connectionState = .connecting
        do {
            _ = try await api.listSessions()
            connectionState = .connected
        } catch {
            connectionState = .disconnected(error.localizedDescription)
        }
    }

    // MARK: - 状态

    @State private var showWebFallback: Bool = false
    @State private var presentSettings: Bool = false

    // MARK: - 三栏

    @ViewBuilder
    private var content: some View {
        HStack(spacing: 10) {
            sidebarColumn
                .frame(width: Theme.LayoutMetrics.sidebarWidth)
                .wandGlass(.panel)
            mainColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                        .fill(Theme.surfaceElevated.opacity(0.72))
                )
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
            if filePanelOpen {
                rightColumn
                    .frame(width: Theme.LayoutMetrics.filePanelWidth)
                    .wandGlass(.panel)
                    .transition(
                        .asymmetric(
                            insertion: .offset(x: 24).combined(with: .opacity),
                            removal: .opacity
                        )
                    )
            }
        }
        .padding(10)
        .animation(structuralAnimation, value: filePanelOpen)
    }

    private var sidebarColumn: some View {
        SidebarColumn(
            api: api,
            selectedSessionId: $selectedSessionId,
            onSessionSelected: { session in
                selectedSessionId = session.id
                selectedSessionProvider = session.provider ?? "claude"
                selectedSession = session
            }
        )
    }

    @ViewBuilder
    private var mainColumn: some View {
        if case .disconnected(let message) = connectionState {
            ConnectionFailureView(
                message: message,
                onRetry: checkConnection,
                onTroubleshoot: { showTroubleshooting = true }
            )
        } else if let sessionId = selectedSessionId {
            MainColumn(
                api: api,
                sessionId: sessionId,
                provider: selectedSessionProvider,
                session: selectedSession
            )
        } else {
            EmptyMainColumn(api: api)
        }
    }

    @ViewBuilder
    private var rightColumn: some View {
        VStack(spacing: 0) {
            rightColumnTabs
            Divider()
                .opacity(0.3)
            rightColumnBody
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay(alignment: .topTrailing) {
            Button {
                withAnimation(structuralAnimation) {
                    filePanelOpen = false
                }
            } label: {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
                    .padding(8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(WandIconButtonStyle())
            .help("折叠文件面板")
        }
    }

    private var rightColumnTabs: some View {
        HStack(spacing: 4) {
            ForEach(RightPanelTab.allCases) { tab in
                Button {
                    rightPanelTab = tab
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: tab.systemImage)
                            .font(.system(size: 11, weight: .medium))
                        Text(tab.label)
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(rightPanelTab == tab ? Theme.textPrimary : Theme.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        Capsule(style: .continuous)
                            .fill(rightPanelTab == tab ? Theme.wandAccent.opacity(0.11) : Color.clear)
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(
                                rightPanelTab == tab ? Theme.wandAccent.opacity(0.30) : .clear,
                                lineWidth: 0.7
                            )
                    )
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var rightColumnBody: some View {
        FilePanelView(
            sessionId: selectedSessionId,
            api: api,
            session: selectedSession,
            tab: $rightPanelTab
        )
    }

}

private struct ConnectionFailureView: View {
    let message: String
    let onRetry: () -> Void
    let onTroubleshoot: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 34, weight: .medium))
                .foregroundColor(Theme.danger)
            Text("无法连接服务器")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
            Text(message)
                .font(.system(size: 12))
                .foregroundColor(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
                .textSelection(.enabled)
            HStack(spacing: 10) {
                Button("重试", action: onRetry)
                    .buttonStyle(.borderedProminent).tint(Theme.brand)
                Button(action: onTroubleshoot) {
                    Label("故障排查", systemImage: "stethoscope")
                }
                .buttonStyle(.bordered)
            }
            Spacer()
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - 侧栏容器

struct SidebarColumn: View {
    private enum ListEntry: Identifiable {
        case session(SessionSnapshot)
        case recoverable(HistorySession)

        var id: String {
            switch self {
            case .session(let session): return "session-\(session.id)"
            case .recoverable(let session): return "recoverable-\(session.id)"
            }
        }

        var sortTimestamp: Double {
            switch self {
            case .session(let session):
                return Self.parseISO8601(session.startedAt)?.timeIntervalSince1970 ?? 0
            case .recoverable(let session):
                if let mtimeMs = session.mtimeMs { return mtimeMs / 1000 }
                return Self.parseISO8601(session.timestamp)?.timeIntervalSince1970 ?? 0
            }
        }

        private static func parseISO8601(_ value: String?) -> Date? {
            guard let value, !value.isEmpty else { return nil }
            return fractionalFormatter.date(from: value) ?? isoFormatter.date(from: value)
        }

        private static let fractionalFormatter: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter
        }()
        private static let isoFormatter = ISO8601DateFormatter()
    }

    /// 删除先进入待确认状态，避免菜单项或多选模式中的误触直接破坏会话记录。
    private enum PendingDeletion: Identifiable {
        case sessions([SessionSnapshot])
        case history(HistorySession)

        var id: String {
            switch self {
            case .sessions(let sessions):
                return "sessions-\(sessions.map(\.id).sorted().joined(separator: ","))"
            case .history(let history):
                return "history-\(history.id)"
            }
        }

        var title: String {
            switch self {
            case .sessions(let sessions):
                return sessions.count > 1 ? "删除 \(sessions.count) 个会话？" : "删除此会话？"
            case .history:
                return "删除此历史会话？"
            }
        }

        var message: String {
            switch self {
            case .sessions(let sessions):
                if let session = sessions.first, sessions.count == 1 {
                    return "将永久删除“\(session.displayTitle)”。此操作无法撤销。"
                }
                return "将永久删除 \(sessions.count) 个会话。此操作无法撤销。"
            case .history(let history):
                let title = history.firstUserMessage.isEmpty
                    ? (history.cwd as NSString).lastPathComponent
                    : history.firstUserMessage
                return "将永久删除可恢复的历史会话“\(title.isEmpty ? "会话" : title)”。此操作无法撤销。"
            }
        }

        var actionTitle: String {
            switch self {
            case .sessions(let sessions):
                return sessions.count > 1 ? "删除 \(sessions.count) 个会话" : "删除会话"
            case .history:
                return "删除历史会话"
            }
        }
    }

    let api: WandAPI
    @Binding var selectedSessionId: String?
    let onSessionSelected: (SessionSnapshot) -> Void

    @State private var sessions: [SessionSnapshot] = []
    @State private var historySessions: [HistorySession] = []
    @State private var loading = true
    @State private var loadError: String?
    @State private var isSelecting = false
    @State private var selectedSessionIds: Set<String> = []
    @State private var showNewSession = false
    @State private var historyActionInProgress = false
    @State private var pendingDeletion: PendingDeletion?
    @State private var deleteInProgress = false
    @State private var deletionError: String?
    private let refreshTimer = Timer.publish(every: 10, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.3)
            list
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.clear)
        .sheet(isPresented: $showNewSession) {
            NewSessionView(api: api) { newSession in
                showNewSession = false
                sessions.insert(newSession, at: 0)
                onSessionSelected(newSession)
            }
        }
        .task { await load() }
        .onReceive(refreshTimer) { _ in
            Task { await load(silent: true) }
        }
        .confirmationDialog(
            pendingDeletion?.title ?? "确认删除",
            isPresented: deletionConfirmationPresented,
            titleVisibility: .visible
        ) {
            if let pendingDeletion {
                Button(pendingDeletion.actionTitle, role: .destructive) {
                    confirmPendingDeletion()
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(pendingDeletion?.message ?? "")
        }
        .alert("删除未完成", isPresented: deletionErrorPresented) {
            Button("好", role: .cancel) {
                deletionError = nil
            }
        } message: {
            Text(deletionError ?? "")
        }
    }

    private var deletionConfirmationPresented: Binding<Bool> {
        Binding(
            get: { pendingDeletion != nil },
            set: { isPresented in
                if !isPresented { pendingDeletion = nil }
            }
        )
    }

    private var deletionErrorPresented: Binding<Bool> {
        Binding(
            get: { deletionError != nil },
            set: { isPresented in
                if !isPresented { deletionError = nil }
            }
        )
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 8) {
            if isSelecting {
                Text(deleteInProgress ? "正在删除…" : "已选择 \(selectedSessionIds.count) 项")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                Spacer()
                Button(role: .destructive) {
                    requestSelectedSessionsDeletion()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(selectedSessionIds.isEmpty ? Theme.textMuted : Theme.danger)
                }
                .buttonStyle(WandIconButtonStyle())
                .disabled(selectedSessionIds.isEmpty || deleteInProgress)
                .help("删除所选会话…")
                .accessibilityLabel("删除所选会话")
                Button {
                    isSelecting = false
                    selectedSessionIds.removeAll()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                    .foregroundColor(Theme.textSecondary)
                }
                .buttonStyle(WandIconButtonStyle())
                .disabled(deleteInProgress)
                .help("退出多选")
            } else {
                Text("会话")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                Spacer()
                Button {
                    isSelecting = true
                } label: {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 16))
                        .foregroundColor(Theme.textSecondary)
                }
                .buttonStyle(WandIconButtonStyle())
                .disabled(deleteInProgress)
                .help("多选")
                Button {
                    showNewSession = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(Theme.wandAccent)
                }
                .buttonStyle(WandIconButtonStyle())
                .disabled(deleteInProgress)
                .help("新建会话")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - 列表

    @ViewBuilder
    private var list: some View {
        if loading && sessions.isEmpty && historySessions.isEmpty {
            VStack {
                Spacer()
                ProgressView().tint(Theme.wandAccent)
                Spacer()
            }
        } else if let error = loadError, sessions.isEmpty, historySessions.isEmpty {
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 28))
                    .foregroundColor(Theme.textSecondary)
                Text(error)
                    .font(.footnote)
                    .foregroundColor(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                Button("重试") { Task { await load() } }
                    .buttonStyle(WandSecondaryButtonStyle())
                Spacer()
            }
            .padding(20)
        } else if listEntries.isEmpty {
            VStack(spacing: 14) {
                Spacer()
                WandBrandMark(size: 52)
                Text("还没有会话")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                Button { showNewSession = true } label: {
                    Text("新建会话")
                        .frame(maxWidth: 200)
                }
                .buttonStyle(WandPrimaryButtonStyle())
                Spacer()
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(listEntries) { entry in
                        switch entry {
                        case .session(let session):
                            managedSessionTile(session)
                        case .recoverable(let session):
                            recoverableSessionTile(session)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
        }
    }

    private func managedSessionTile(_ session: SessionSnapshot) -> some View {
        Button {
            if isSelecting {
                toggleSelection(session.id)
            } else {
                onSessionSelected(session)
            }
        } label: {
            SessionTile(
                session: session,
                isSelected: selectedSessionId == session.id,
                isSelecting: isSelecting,
                checked: selectedSessionIds.contains(session.id)
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .disabled(deleteInProgress)
        .accessibilityLabel(session.displayTitle)
        .accessibilityValue(managedSessionAccessibilityValue(session))
        .accessibilityHint(
            isSelecting
                ? (selectedSessionIds.contains(session.id) ? "取消选择会话" : "选择会话")
                : "打开会话"
        )
        .contextMenu {
            Button {
                isSelecting = true
                selectedSessionIds.insert(session.id)
            } label: {
                Label("多选", systemImage: "checkmark.circle")
            }
            Button(role: .destructive) {
                requestSessionDeletion(session)
            } label: {
                Label("删除", systemImage: "trash")
            }
            .disabled(deleteInProgress)
        }
    }

    private func recoverableSessionTile(_ session: HistorySession) -> some View {
        Button {
            resume(session)
        } label: {
            HistoryTile(history: session)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(historyAccessibilityLabel(session))
        .accessibilityValue("可恢复历史会话")
        .accessibilityHint("恢复为新会话")
        .disabled(isSelecting || historyActionInProgress || deleteInProgress)
        .contextMenu {
            Button(role: .destructive) {
                requestHistoryDeletion(session)
            } label: {
                Label("删除", systemImage: "trash")
            }
            .disabled(deleteInProgress)
        }
    }

    // MARK: - 数据

    private var visibleSessions: [SessionSnapshot] {
        sessions
    }

    private var recoverableSessions: [HistorySession] {
        let managedIds = Set(sessions.compactMap(\.claudeSessionId))
        return historySessions
            .filter {
                ($0.hasConversation ?? true)
                    && !($0.managedByWand ?? false)
                    && !managedIds.contains($0.claudeSessionId)
            }
            .sorted { ($0.mtimeMs ?? 0) > ($1.mtimeMs ?? 0) }
    }

    private var listEntries: [ListEntry] {
        (visibleSessions.map(ListEntry.session) + recoverableSessions.map(ListEntry.recoverable))
            .sorted { $0.sortTimestamp > $1.sortTimestamp }
    }

    @discardableResult
    private func load(silent: Bool = false) async -> Bool {
        if !silent { loading = true }
        do {
            let s = try await api.listSessions()
            sessions = s
            if let selectedSessionId,
               let refreshed = s.first(where: { $0.id == selectedSessionId }) {
                onSessionSelected(refreshed)
            } else if selectedSessionId != nil {
                self.selectedSessionId = nil
            }
            // HistorySession 来源:Claude + Codex 各自的历史文件扫描,并发拉取合并。
            async let claudeHistory = api.listClaudeHistory()
            async let codexHistory = api.listCodexHistory()
            let (c, x) = try await (claudeHistory, codexHistory)
            historySessions = c + x
            loadError = nil
            loading = false
            return true
        } catch {
            if !silent { loadError = error.localizedDescription }
            loading = false
            return false
        }
    }

    private func toggleSelection(_ id: String) {
        if selectedSessionIds.contains(id) {
            selectedSessionIds.remove(id)
        } else {
            selectedSessionIds.insert(id)
        }
    }

    // MARK: - 删除

    private func requestSelectedSessionsDeletion() {
        let selected = sessions.filter { selectedSessionIds.contains($0.id) }
        guard !selected.isEmpty, !deleteInProgress else { return }
        pendingDeletion = .sessions(selected)
    }

    private func requestSessionDeletion(_ session: SessionSnapshot) {
        guard !deleteInProgress else { return }
        pendingDeletion = .sessions([session])
    }

    private func requestHistoryDeletion(_ history: HistorySession) {
        guard !deleteInProgress else { return }
        pendingDeletion = .history(history)
    }

    private func confirmPendingDeletion() {
        guard let pendingDeletion, !deleteInProgress else { return }
        self.pendingDeletion = nil

        switch pendingDeletion {
        case .sessions(let sessions):
            deleteSessions(sessions)
        case .history(let history):
            deleteHistory(history)
        }
    }

    /// 不做乐观删除：仅在请求成功后移除本地项目。批量请求逐个执行并收集失败项，
    /// 这样局部失败不会让用户误以为所有会话都已删除。
    private func deleteSessions(_ targets: [SessionSnapshot]) {
        guard !targets.isEmpty, !deleteInProgress else { return }
        deleteInProgress = true

        Task {
            var deletedIds = Set<String>()
            var failures: [String] = []

            for session in targets {
                do {
                    try await api.deleteSession(id: session.id)
                    deletedIds.insert(session.id)
                } catch {
                    failures.append("\(session.displayTitle)：\(error.localizedDescription)")
                }
            }

            if !deletedIds.isEmpty {
                sessions.removeAll { deletedIds.contains($0.id) }
                if let selectedSessionId, deletedIds.contains(selectedSessionId) {
                    self.selectedSessionId = nil
                }
                selectedSessionIds.subtract(deletedIds)
            }

            let refreshed = await load(silent: true)
            if !failures.isEmpty {
                let successPrefix = deletedIds.isEmpty ? "" : "已删除 \(deletedIds.count) 个会话；"
                let failureSummary = failures.prefix(2).joined(separator: "\n")
                let extraCount = max(0, failures.count - 2)
                let extra = extraCount > 0 ? "\n另有 \(extraCount) 个会话未删除。" : ""
                let refreshSuffix = refreshed ? "" : "\n列表未能刷新，请稍后重试。"
                deletionError = "\(successPrefix)以下会话未删除：\n\(failureSummary)\(extra)\(refreshSuffix)"
            } else if !refreshed {
                deletionError = "会话已删除，但列表未能刷新。请稍后重试刷新。"
            }

            if selectedSessionIds.isEmpty {
                isSelecting = false
            }
            deleteInProgress = false
        }
    }

    private func deleteHistory(_ history: HistorySession) {
        guard !deleteInProgress else { return }
        deleteInProgress = true

        Task {
            var deleteFailure: String?
            do {
                try await api.deleteHistory(history)
                historySessions.removeAll { $0.id == history.id }
            } catch {
                deleteFailure = error.localizedDescription
            }

            let refreshed = await load(silent: true)
            if let deleteFailure {
                let refreshSuffix = refreshed ? "" : "\n列表也未能刷新，请稍后重试。"
                deletionError = "无法删除历史会话：\(deleteFailure)\(refreshSuffix)"
            } else if !refreshed {
                deletionError = "历史会话已删除，但列表未能刷新。请稍后重试刷新。"
            }
            deleteInProgress = false
        }
    }

    private func managedSessionAccessibilityValue(_ session: SessionSnapshot) -> String {
        let selection = isSelecting
            ? (selectedSessionIds.contains(session.id) ? "已选择，" : "未选择，")
            : ""
        return "\(selection)\(session.isStructured ? "聊天模式" : "终端模式")，\(session.status ?? "空闲")"
    }

    private func historyAccessibilityLabel(_ history: HistorySession) -> String {
        if !history.firstUserMessage.isEmpty { return history.firstUserMessage }
        let name = (history.cwd as NSString).lastPathComponent
        return name.isEmpty ? "可恢复历史会话" : name
    }

    private func resume(_ history: HistorySession) {
        guard !historyActionInProgress, !deleteInProgress else { return }
        historyActionInProgress = true
        Task {
            do {
                let resumed = try await api.resumeHistory(history)
                historySessions.removeAll { $0.id == history.id }
                sessions.insert(resumed, at: 0)
                onSessionSelected(resumed)
                loadError = nil
            } catch {
                loadError = error.localizedDescription
            }
            historyActionInProgress = false
        }
    }

}

// MARK: - 会话 tile

private enum SessionListDateLabel {
    private static let isoFormatter = ISO8601DateFormatter()
    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .short
        return formatter
    }()

    static func relative(iso value: String?) -> String {
        guard let value,
              let date = fractionalFormatter.date(from: value) ?? isoFormatter.date(from: value) else {
            return ""
        }
        return relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    static func relative(milliseconds: Double?) -> String {
        guard let milliseconds, milliseconds > 0 else { return "" }
        return relativeFormatter.localizedString(
            for: Date(timeIntervalSince1970: milliseconds / 1000),
            relativeTo: Date()
        )
    }
}

struct SessionTile: View {
    let session: SessionSnapshot
    let isSelected: Bool
    let isSelecting: Bool
    let checked: Bool
    @State private var hovering = false

    private var provider: String { session.provider ?? "claude" }
    private var status: String { session.status ?? "idle" }
    private var statusColor: Color {
        if session.hasPendingPermission { return Theme.warning }
        if session.isResponding { return Theme.success }
        switch status {
        case "running", "thinking": return Theme.success
        case "waiting", "waiting-input", "waiting_input", "reconnecting": return Theme.warning
        case "failed": return Theme.danger
        default: return Theme.textMuted
        }
    }

    private var prominentStatus: Bool {
        session.hasPendingPermission
            || session.isResponding
            || ["running", "thinking", "waiting", "waiting-input", "waiting_input", "reconnecting"]
                .contains(status)
    }

    private var statusLabel: String {
        if session.hasPendingPermission { return "等待授权" }
        if session.isResponding { return "思考中" }
        switch status {
        case "running": return "运行中"
        case "thinking": return "思考中"
        case "waiting", "waiting-input", "waiting_input": return "等待输入"
        case "reconnecting": return "重连中"
        case "failed": return "已失败"
        case "idle": return "空闲"
        case "exited": return "已退出"
        case "stopped": return "已停止"
        default: return status
        }
    }

    private var title: String {
        // SessionSnapshot 用 displayTitle 兜底(摘要 > 当前任务 > cwd 末段 > "会话")。
        session.displayTitle
    }

    private var subtitle: String {
        if let cwd = session.cwd, !cwd.isEmpty { return cwd }
        switch provider {
        case "codex": return "Codex"
        case "grok": return "Grok"
        case "opencode": return "OpenCode"
        case "qoder": return "Qoder"
        default: return "Claude"
        }
    }

    private var recentTime: String {
        SessionListDateLabel.relative(iso: session.endedAt ?? session.startedAt)
    }

    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: 3)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top, spacing: 8) {
                    Group {
                        if isSelecting {
                            Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 16))
                                .foregroundColor(checked ? Theme.wandAccent : Theme.textSecondary)
                        } else {
                            BrandLogoShape(provider: provider)
                                .fill(Theme.providerColor(provider))
                                .frame(width: 17, height: 17)
                        }
                    }
                    .frame(width: 42, height: 22)
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 6) {
                    Text(recentTime)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundColor(Theme.textMuted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                        .frame(width: 42)
                    if prominentStatus {
                        HStack(spacing: 4) {
                            Circle().fill(statusColor).frame(width: 5, height: 5)
                            Text(statusLabel)
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundColor(statusColor)
                                .lineLimit(1)
                        }
                    } else {
                        Circle().fill(statusColor).frame(width: 5, height: 5)
                    }
                    if let cwd = session.cwd, !cwd.isEmpty {
                        WandPathRevealText(path: cwd, fontSize: 9.5, color: Theme.textMuted)
                            .frame(maxWidth: .infinity)
                    } else {
                        Text(status)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundColor(Theme.textSecondary)
                    }
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
        }
        .overlay(alignment: .leading) {
            if isSelected && !isSelecting {
                Capsule()
                    .fill(Theme.wandAccent)
                    .frame(width: 3)
                    .padding(.vertical, 9)
            }
        }
        .wandSelectionSurface(isSelected: isSelected && !isSelecting, isHovered: hovering, cornerRadius: 12)
        .onHover { hovering = $0 }
    }
}

struct HistoryTile: View {
    let history: HistorySession
    @State private var hovering = false

    private var displayTitle: String {
        // 优先 firstUserMessage(用户第一句),降级到 cwd 末段。
        if !history.firstUserMessage.isEmpty { return history.firstUserMessage }
        let last = (history.cwd as NSString).lastPathComponent
        return last.isEmpty ? "会话" : last
    }

    private var dateText: String {
        SessionListDateLabel.relative(milliseconds: history.mtimeMs)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                BrandLogoShape(provider: history.provider)
                    .fill(Theme.providerColor(history.provider))
                    .frame(width: 17, height: 17)
                    .frame(width: 42, height: 22)
                Text(displayTitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 6) {
                Text(dateText)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundColor(Theme.textMuted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .frame(width: 42)
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundColor(Theme.providerColor(history.provider))
                Text("可恢复")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
                if !history.cwd.isEmpty {
                    Text("·").foregroundColor(Theme.textMuted.opacity(0.55))
                    WandPathRevealText(path: history.cwd, fontSize: 9.5, color: Theme.textMuted)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .wandSelectionSurface(isSelected: false, isHovered: hovering, cornerRadius: 12)
        .onHover { hovering = $0 }
    }
}

// MARK: - 中栏空态 + 中栏容器

struct EmptyMainColumn: View {
    let api: WandAPI

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            WandBrandMark(size: 72)
            Text("Wand")
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
            Text("从左侧选择会话,或新建一个会话开始")
                .font(.system(size: 13))
                .foregroundColor(Theme.textSecondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct MainColumn: View {
    let api: WandAPI
    let sessionId: String
    let provider: String
    let session: SessionSnapshot?

    var body: some View {
        if session?.isStructured == false {
            // PTY 是完整终端交互，不应被原生 ChatView 当作普通消息流模拟；直接深链
            // 到服务端已有的网页终端，保留键盘、光标和终端控制语义。
            WebContainerView(
                serverURL: api.baseURL,
                token: api.token,
                sessionId: sessionId
            )
            .id(sessionId)
        } else {
            // 结构化会话继续使用原生消息与输入体验。
            VStack(spacing: 0) {
                SessionHeaderView(
                    provider: provider,
                    title: session?.displayTitle,
                    workingDirectory: session?.cwd
                )
                // 必须按 sessionId 绑定身份:MainShellView 在 if let selectedSessionId 分支内
                // 复用 MainColumn 节点,只换参数。SwiftUI 默认保留子视图的 @StateObject,
                // 切换会话时 ChatStore 仍指向上一个会话(socket 不重连、快照不重拉),
                // 表现为「切了会话,内容不变」。.id(sessionId) 强制整个子树按新身份重建。
                ChatView(sessionId: sessionId, api: api)
                    .id(sessionId)
            }
        }
    }
}

struct SessionHeaderView: View {
    let provider: String
    let title: String?
    let workingDirectory: String?

    private var providerLabel: String {
        switch provider {
        case "codex": return "Codex"
        case "opencode": return "OpenCode"
        case "grok": return "Grok"
        case "qoder": return "Qoder"
        default: return "Claude"
        }
    }
    private var providerColor: Color { Theme.providerColor(provider) }
    private var displayTitle: String { title?.isEmpty == false ? title! : "新会话" }
    private var workingDirectoryName: String? {
        guard let workingDirectory, !workingDirectory.isEmpty else { return nil }
        let lastComponent = (workingDirectory as NSString).lastPathComponent
        return lastComponent.isEmpty ? workingDirectory : lastComponent
    }

    var body: some View {
        HStack(spacing: 10) {
            BrandLogoShape(provider: provider)
                .fill(providerColor)
                .frame(width: 15, height: 15)
                .frame(width: 30, height: 30)
                .background(
                    Circle()
                        .fill(providerColor.opacity(0.14))
                )
            VStack(alignment: .leading, spacing: 4) {
                Text(displayTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 6) {
                    HStack(spacing: 4) {
                        BrandLogoShape(provider: provider)
                            .fill(providerColor)
                            .frame(width: 9, height: 9)
                        Text(providerLabel)
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(providerColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        Capsule(style: .continuous)
                            .fill(providerColor.opacity(0.14))
                    )

                    if let workingDirectoryName {
                        HStack(spacing: 4) {
                            Image(systemName: "folder")
                                .font(.system(size: 9, weight: .medium))
                            Text(workingDirectoryName)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(Theme.textSecondary)
                        .help(workingDirectory ?? workingDirectoryName)
                    }
                }
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .wandGlass(.chrome)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: Theme.borderSubtle))
                .frame(height: 0.5)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(providerLabel) 会话：\(displayTitle)")
    }
}

// MARK: - 网页版兜底容器(从 NativeRootView 提到 MainShellView 共用)

struct WebFallbackContainer: View {
    let serverURL: URL
    let token: String?
    var sessionId: String? = nil

    var body: some View {
        WebContainerView(serverURL: serverURL, token: token, sessionId: sessionId)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }
}

// MARK: - 布局尺寸

extension Theme {
    enum LayoutMetrics {
        static let sidebarWidth: CGFloat = 300
        static let filePanelWidth: CGFloat = 320
    }
}
