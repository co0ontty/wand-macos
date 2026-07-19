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

    var body: some View {
        Group {
            if showWebFallback {
                WebFallbackContainer(serverURL: serverURL, token: token)
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
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(Color(nsColor: Theme.borderSubtle), lineWidth: 0.5)
                        )
                        .padding(.bottom, 8)
                }
            }
            .onChange(of: geo.size.width) { newWidth in
                // < 1100 自动折叠右栏,避免中栏被压扁
                if newWidth < 1100 && filePanelOpen {
                    withAnimation(.easeInOut(duration: 0.2)) {
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
                    Label("返回原生界面", systemImage: "chevron.left")
                }
            } else {
                HStack(spacing: 7) {
                    WandBrandMark(size: 20)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Wand")
                            .font(.system(size: 12, weight: .semibold))
                        Text(displayHost)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(Theme.textSecondary)
                    }
                }
            }
        }
        ToolbarItem(placement: .principal) {
            if showWebFallback {
                Text("网页版")
                    .font(.system(size: 13, weight: .medium))
            } else {
                HStack(spacing: 6) {
                    toolbarConnectionDot
                    Text(selectedSessionTitle ?? "未选择会话")
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                }
                .help(connectionHelp)
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    filePanelOpen.toggle()
                }
            } label: {
                Image(systemName: filePanelOpen ? "sidebar.right" : "sidebar.squares.right")
            }
            .help(filePanelOpen ? "折叠文件面板" : "展开文件面板")
            .opacity(showWebFallback ? 0 : 1)
            .disabled(showWebFallback)

            Menu {
                Button("设置", systemImage: "gearshape") {
                    presentSettings = true
                }
                if case .disconnected = connectionState {
                    Button("故障排查", systemImage: "stethoscope") {
                        showTroubleshooting = true
                    }
                }
                Button("打开网页版", systemImage: "safari") {
                    showWebFallback = true
                }
                Divider()
                Button("切换服务器", systemImage: "server.rack") {
                    NotificationCenter.default.post(name: .wandRequestSwitchServer, object: nil)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .help("更多")
            .opacity(showWebFallback ? 0 : 1)
            .disabled(showWebFallback)
        }
    }

    @ViewBuilder
    private var toolbarConnectionDot: some View {
        switch connectionState {
        case .connecting:
            ProgressView()
                .controlSize(.small)
        case .connected:
            Circle()
                .fill(Theme.success)
                .frame(width: 7, height: 7)
        case .disconnected:
            Circle()
                .fill(Theme.danger)
                .frame(width: 7, height: 7)
        }
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
        HStack(spacing: 0) {
            sidebarColumn
                .frame(width: Theme.LayoutMetrics.sidebarWidth)
            Divider()
                .opacity(0.3)
            mainColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if filePanelOpen {
                Divider()
                    .opacity(0.3)
                rightColumn
                    .frame(width: Theme.LayoutMetrics.filePanelWidth)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
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
        .background(Theme.surface)
        .overlay(alignment: .topTrailing) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    filePanelOpen = false
                }
            } label: {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
                    .padding(8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("折叠文件面板")
        }
    }

    private var rightColumnTabs: some View {
        HStack(spacing: 0) {
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
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        Rectangle()
                            .fill(rightPanelTab == tab ? Theme.background : Color.clear)
                    )
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(rightPanelTab == tab ? Theme.wandAccent : Color.clear)
                            .frame(height: 2)
                    }
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
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

    // MARK: - 顶栏数据

    private var selectedSessionTitle: String? {
        guard selectedSessionId != nil else { return nil }
        // 优先展示真实标题(摘要 > 当前任务 > cwd 末段),回退到会话 id 前缀。
        if let title = selectedSession?.displayTitle, !title.isEmpty {
            return title
        }
        return "会话 \(selectedSessionId?.prefix(6) ?? "")"
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
    private let refreshTimer = Timer.publish(every: 10, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.3)
            list
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.background)
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
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 8) {
            if isSelecting {
                Text("已选择 \(selectedSessionIds.count) 项")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                Spacer()
                Button(role: .destructive) {
                    deleteSelectedSessions()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(selectedSessionIds.isEmpty ? Theme.textMuted : Theme.danger)
                }
                .buttonStyle(.plain)
                .disabled(selectedSessionIds.isEmpty)
                .help("删除所选会话")
                Button {
                    isSelecting = false
                    selectedSessionIds.removeAll()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(Theme.textSecondary)
                }
                .buttonStyle(.plain)
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
                .buttonStyle(.plain)
                .help("多选")
                Button {
                    showNewSession = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(Theme.wandAccent)
                }
                .buttonStyle(.plain)
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
        SessionTile(
            session: session,
            isSelected: selectedSessionId == session.id,
            isSelecting: isSelecting,
            checked: selectedSessionIds.contains(session.id)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if isSelecting {
                toggleSelection(session.id)
            } else {
                onSessionSelected(session)
            }
        }
        .contextMenu {
            Button {
                isSelecting = true
                selectedSessionIds.insert(session.id)
            } label: {
                Label("多选", systemImage: "checkmark.circle")
            }
            Button(role: .destructive) {
                deleteSession(session)
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    private func recoverableSessionTile(_ session: HistorySession) -> some View {
        HistoryTile(history: session)
            .contentShape(Rectangle())
            .onTapGesture {
                if !isSelecting { resume(session) }
            }
            .disabled(historyActionInProgress)
            .contextMenu {
                Button(role: .destructive) {
                    deleteHistory(session)
                } label: {
                    Label("删除", systemImage: "trash")
                }
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

    private func load(silent: Bool = false) async {
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
        } catch {
            if !silent { loadError = error.localizedDescription }
        }
        loading = false
    }

    private func toggleSelection(_ id: String) {
        if selectedSessionIds.contains(id) {
            selectedSessionIds.remove(id)
        } else {
            selectedSessionIds.insert(id)
        }
    }

    private func deleteSelectedSessions() {
        let ids = selectedSessionIds
        guard !ids.isEmpty else { return }
        sessions.removeAll { ids.contains($0.id) }
        if let selectedSessionId, ids.contains(selectedSessionId) {
            self.selectedSessionId = nil
        }
        selectedSessionIds.removeAll()
        isSelecting = false
        Task {
            for id in ids {
                try? await api.deleteSession(id: id)
            }
        }
    }

    private func deleteSession(_ session: SessionSnapshot) {
        Task {
            try? await api.deleteSession(id: session.id)
            sessions.removeAll { $0.id == session.id }
            if selectedSessionId == session.id {
                selectedSessionId = nil
            }
        }
    }

    private func deleteHistory(_ history: HistorySession) {
        Task {
            try? await api.deleteHistory(history)
            historySessions.removeAll { $0.id == history.id }
        }
    }

    private func resume(_ history: HistorySession) {
        guard !historyActionInProgress else { return }
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
                                .fill(provider == "codex" ? Theme.codex : Theme.wandAccent)
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
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(hovering ? Theme.surfaceElevated.opacity(0.62) : Color.clear)
        )
        .overlay(alignment: .leading) {
            if isSelected && !isSelecting {
                Capsule()
                    .fill(Theme.wandAccent)
                    .frame(width: 3)
                    .padding(.vertical, 9)
            }
        }
        .wandGlassCard(cornerRadius: 12)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityValue("\(session.isStructured ? "聊天模式" : "终端模式")，\(statusLabel)")
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
                    .fill(history.provider == "codex" ? Theme.codex : Theme.wandAccent)
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
                    .foregroundColor(history.provider == "codex" ? Theme.codex : Theme.wandAccent)
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
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(hovering ? Theme.surfaceElevated.opacity(0.62) : Color.clear)
        )
        .wandGlassCard(cornerRadius: 12)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityValue("聊天模式，可恢复")
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
        // 阶段 4 临时方案:直接嵌入现有 ChatView(消息 + 输入栏整体)。
        // 现有 macOS ChatView 自带 navigationTitle/toolbar 渲染依赖 NavigationView
        // 容器,在中栏裸放时 toolbar 不渲染,只剩消息流 + safeAreaInset 输入栏,
        // 视觉上等价于「header(我们自己加) / list(ChatView) / input(ChatView)」三段。
        VStack(spacing: 0) {
            SessionHeaderView(
                sessionId: sessionId,
                provider: provider,
                title: session?.displayTitle
            )
            Divider().opacity(0.3)
            // 必须按 sessionId 绑定身份:MainShellView 在 if let selectedSessionId 分支内
            // 复用 MainColumn 节点,只换参数。SwiftUI 默认保留子视图的 @StateObject,
            // 切换会话时 ChatStore 仍指向上一个会话(socket 不重连、快照不重拉),
            // 表现为「切了会话,内容不变」。.id(sessionId) 强制整个子树按新身份重建。
            ChatView(sessionId: sessionId, api: api)
                .id(sessionId)
        }
    }
}

struct SessionHeaderView: View {
    let sessionId: String
    let provider: String
    let title: String?

    private var isCodex: Bool { provider == "codex" }
    private var providerLabel: String {
        switch provider {
        case "codex": return "Codex"
        case "grok": return "Grok"
        default: return "Claude"
        }
    }
    private var providerColor: Color { isCodex ? Theme.codex : Theme.wandAccent }
    private var providerMuted: NSColor { isCodex ? Theme.infoMuted : Theme.wandAccentMuted }

    var body: some View {
        HStack(spacing: 8) {
            BrandLogoShape(provider: provider)
                .fill(providerColor)
                .frame(width: 14, height: 14)
            Text(providerLabel)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color(nsColor: providerMuted))
                )
            if let title, !title.isEmpty {
                Text("·")
                    .foregroundColor(Theme.textMuted)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer()
            Text(sessionId.prefix(8).description + "…")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Theme.textMuted)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .wandGlass(.chrome)
    }
}

// MARK: - 网页版兜底容器(从 NativeRootView 提到 MainShellView 共用)

struct WebFallbackContainer: View {
    let serverURL: URL
    let token: String?

    var body: some View {
        WebContainerView(serverURL: serverURL, token: token)
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
