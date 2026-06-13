import SwiftUI

/// 横屏 native 应用主壳:顶栏 + 三栏(左会话 / 中聊天 / 右文件)。
/// 窗口 < 1100 时自动折叠右栏,只留左 + 中;窗口 < 800 时建议横屏。
///
/// 三栏宽度常量对齐 web 端 token(`.sidebar-width: 300px`, `.file-panel-width: 320px`),
/// 顶栏 44pt 高。会话列表复用现有 `SessionListView`(胶囊 tile 重排在阶段 3 做),
/// 中栏和右栏在阶段 4-5 接入。
struct MainShellView: View {
    let serverURL: URL
    let token: String?

    @State private var filePanelOpen: Bool = true
    @State private var rightPanelTab: RightPanelTab = .files
    /// 当前选中的会话 id(从 SessionListView 回调进来)。
    @State private var selectedSessionId: String?
    @State private var selectedSessionProvider: String = "claude"
    @State private var selectedSession: SessionSnapshot?
    /// 连接状态(给顶栏的 connection dot 用)。
    @State private var connectionState: TopBarView.ConnectionState = .connecting

    private var api: WandAPI { WandAPI(baseURL: serverURL, token: token) }

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
        GeometryReader { geo in
            VStack(spacing: 0) {
                TopBarView(
                    serverURL: serverURL,
                    connectionState: connectionState,
                    sessionTitle: selectedSessionTitle,
                    sessionSubtitle: selectedSessionSubtitle,
                    onSettings: { presentSettings = true },
                    onOpenWeb: { showWebFallback = true },
                    onSwitchServer: {
                        NotificationCenter.default.post(name: .wandRequestSwitchServer, object: nil)
                    },
                    filePanelOpen: filePanelOpen,
                    onToggleFilePanel: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            filePanelOpen.toggle()
                        }
                    }
                )
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Theme.windowGradient)
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
        }
        .sheet(isPresented: $showWebFallback) {
            WebFallbackContainer(serverURL: serverURL, token: token) {
                showWebFallback = false
            }
            .frame(minWidth: 900, minHeight: 650)
        }
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
        .task {
            // 进入主壳时跑一次连通性检查,失败显示重连 banner
            connectionState = .connecting
            do {
                _ = try await api.listSessions()
                connectionState = .connected
            } catch {
                connectionState = .disconnected(error.localizedDescription)
            }
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
        if let sessionId = selectedSessionId {
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

    private var selectedSessionSubtitle: String? {
        guard let cwd = selectedSession?.cwd, !cwd.isEmpty else { return nil }
        return cwd
    }
}

// MARK: - 侧栏容器(暂时套用现有 SessionListView,阶段 3 替换为 web 风格)

struct SidebarColumn: View {
    let api: WandAPI
    @Binding var selectedSessionId: String?
    let onSessionSelected: (SessionSnapshot) -> Void

    var body: some View {
        // 现阶段直接调 SessionListView,通过 NavigationLink 把 quickOpenSession 传出来
        SidebarColumnInner(
            api: api,
            selectedSessionId: selectedSessionId,
            onSessionSelected: onSessionSelected
        )
    }
}

/// 内层:沿用现有 SessionListView,但渲染为不带 NavigationView 标题栏的版本。
/// 把顶部 toolbar 隐藏(SessionListView 内部已经用 .principal 渲染 scope Picker),
/// 列表区改为「点击 → 回调 onSessionSelected」而不是 NavigationLink 推入。
private struct SidebarColumnInner: View {
    let api: WandAPI
    /// 当前选中的会话 id(由 MainShellView 传入),用于 SessionTile 高亮。
    let selectedSessionId: String?
    let onSessionSelected: (SessionSnapshot) -> Void

    @State private var sessions: [SessionSnapshot] = []
    @State private var historySessions: [HistorySession] = []
    @State private var loading = true
    @State private var loadError: String?
    @State private var scope: Scope = .active
    @State private var isSelecting = false
    @State private var selectedSessionIds: Set<String> = []
    @State private var pendingDelete: PendingDelete?
    @State private var showClearHistoryConfirmation = false
    @State private var showNewSession = false
    @ObservedObject private var quickActions = QuickActionCoordinator.shared

    private let refreshTimer = Timer.publish(every: 10, on: .main, in: .common).autoconnect()

    enum Scope: String { case active, history }

    enum PendingDelete: Identifiable {
        case session(SessionSnapshot)
        case history(HistorySession)
        var id: String {
            switch self {
            case .session(let s): return "s-\(s.id)"
            case .history(let h): return "h-\(h.id)"
            }
        }
    }

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
        .onReceive(quickActions.$pending) { _ in
            // 侧栏只消费 newSession / openSession;openWeb 由主壳处理
            guard let action = quickActions.consume(where: { a in
                switch a { case .newSession, .openSession: return true; case .openWeb: return false }
            }) else { return }
            switch action {
            case .newSession: showNewSession = true
            case .openSession(let id):
                if let s = sessions.first(where: { $0.id == id }) {
                    onSessionSelected(s)
                } else {
                    Task {
                        if let s = try? await api.getSession(id: id) {
                            onSessionSelected(s)
                        }
                    }
                }
            case .openWeb: break
            }
        }
        .onChange(of: scope) { _ in
            isSelecting = false
            selectedSessionIds.removeAll()
            Task { await load(silent: true) }
        }
        .confirmationDialog(
            "确认清空全部历史会话?",
            isPresented: $showClearHistoryConfirmation,
            titleVisibility: .visible
        ) {
            Button("清空全部", role: .destructive) { clearAllHistory() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这会删除本机 Claude 和 Codex 的历史会话文件,无法撤销。")
        }
        .alert("删除会话", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("删除", role: .destructive) { performDelete() }
            Button("取消", role: .cancel) {}
        } message: {
            Text(pendingDeleteDialogMessage)
        }
    }

    private var pendingDeleteDialogMessage: String {
        switch pendingDelete {
        case .session: return "此操作无法撤销,确定要删除这个会话吗?"
        case .history: return "此操作无法撤销,确定要删除这条历史会话吗?"
        case .none: return ""
        }
    }

    // MARK: - 头部(scope Picker + 右上角按钮)

    private var header: some View {
        HStack(spacing: 8) {
            if isSelecting {
                Text("已选择 \(selectedSessionIds.count) 项")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                Spacer()
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
                Picker("会话范围", selection: $scope) {
                    Text("进行中").tag(Scope.active)
                    Text("历史会话").tag(Scope.history)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 200)
                Spacer()
                Button {
                    if scope == .history {
                        showClearHistoryConfirmation = true
                    } else {
                        isSelecting = true
                    }
                } label: {
                    Image(systemName: scope == .history ? "trash" : "checkmark.circle")
                        .font(.system(size: 16))
                        .foregroundColor(scope == .history ? Theme.danger : Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .help(scope == .history ? "清空历史" : "多选")
                Button {
                    showNewSession = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(Theme.wandAccent)
                }
                .buttonStyle(.plain)
                .help("新建会话")
                .disabled(scope == .history)
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
        } else if scope == .history {
            historyList
        } else if visibleSessions.isEmpty {
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
                    ForEach(visibleSessions) { session in
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
                                pendingDelete = .session(session)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
        }
    }

    @ViewBuilder
    private var historyList: some View {
        let items = visibleHistorySessions
        if items.isEmpty {
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 28))
                    .foregroundColor(Theme.textSecondary)
                Text("没有可恢复的历史会话")
                    .font(.footnote)
                    .foregroundColor(Theme.textSecondary)
                Spacer()
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(items) { h in
                        HistoryTile(history: h)
                            .contentShape(Rectangle())
                            .contextMenu {
                                Button(role: .destructive) {
                                    pendingDelete = .history(h)
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
        }
    }

    // MARK: - 数据

    private var visibleSessions: [SessionSnapshot] {
        sessions.filter { !($0.archived ?? false) }
    }

    private var visibleHistorySessions: [HistorySession] {
        let managedIds = Set(sessions.compactMap(\.claudeSessionId))
        return historySessions
            .filter {
                ($0.hasConversation ?? true)
                    && !($0.managedByWand ?? false)
                    && !managedIds.contains($0.claudeSessionId)
            }
            .sorted { ($0.mtimeMs ?? 0) > ($1.mtimeMs ?? 0) }
    }

    private func load(silent: Bool = false) async {
        if !silent { loading = true }
        do {
            let s = try await api.listSessions()
            sessions = s
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

    private func performDelete() {
        guard let pendingDelete else { return }
        Task {
            switch pendingDelete {
            case .session(let s):
                try? await api.deleteSession(id: s.id)
                sessions.removeAll { $0.id == s.id }
            case .history(let h):
                try? await api.deleteHistory(h)
                historySessions.removeAll { $0.id == h.id }
            }
        }
    }

    private func clearAllHistory() {
        Task {
            // clearAllHistory 是批量接口,这里按 provider 拆两次调,失败不致命。
            let claudeIds = historySessions.filter { $0.provider != "codex" }.map { $0.id }
            let codexIds = historySessions.filter { $0.provider == "codex" }.map { $0.id }
            if !claudeIds.isEmpty { try? await api.deleteHistoryBatch(provider: "claude", ids: claudeIds) }
            if !codexIds.isEmpty { try? await api.deleteHistoryBatch(provider: "codex", ids: codexIds) }
            historySessions.removeAll()
        }
    }
}

// MARK: - 会话 tile(web 风格:圆角胶囊,active 时品牌色描边 + 左侧 3px 指示条)

struct SessionTile: View {
    let session: SessionSnapshot
    let isSelected: Bool
    let isSelecting: Bool
    let checked: Bool

    private var provider: String { session.provider ?? "claude" }
    private var status: String { session.status ?? "idle" }
    private var statusColor: Color {
        switch status {
        case "running", "thinking": return Theme.success
        case "waiting": return Theme.warning
        case "failed": return Theme.danger
        default: return Theme.textMuted
        }
    }

    private var title: String {
        // SessionSnapshot 用 displayTitle 兜底(摘要 > 当前任务 > cwd 末段 > "会话")。
        session.displayTitle
    }

    private var subtitle: String {
        if let cwd = session.cwd, !cwd.isEmpty { return cwd }
        return provider == "codex" ? "Codex" : "Claude"
    }

    var body: some View {
        HStack(spacing: 0) {
            // 左侧 3px 指示条:active / 多选勾选时亮品牌色
            Rectangle()
                .fill(isSelected || checked ? Theme.wandAccent : Color.clear)
                .frame(width: 3)
            HStack(spacing: 10) {
                if isSelecting {
                    Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16))
                        .foregroundColor(checked ? Theme.wandAccent : Theme.textSecondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 5, height: 5)
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundColor(Theme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isSelected
                      ? Color(nsColor: Theme.wandAccentMuted)
                      : Theme.surfaceElevated.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(
                    isSelected
                        ? Color(nsColor: Theme.borderFocus)
                        : Color(nsColor: Theme.borderSubtle),
                    lineWidth: isSelected ? 1.5 : 0.5
                )
        )
    }
}

struct HistoryTile: View {
    let history: HistorySession

    private var displayTitle: String {
        // 优先 firstUserMessage(用户第一句),降级到 cwd 末段,都没有就 "历史会话"。
        if !history.firstUserMessage.isEmpty { return history.firstUserMessage }
        let last = (history.cwd as NSString).lastPathComponent
        return last.isEmpty ? "历史会话" : last
    }

    private var dateText: String {
        let ms = history.mtimeMs ?? 0
        let date = Date(timeIntervalSince1970: ms / 1000)
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock")
                .font(.system(size: 12))
                .foregroundColor(Theme.textMuted)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(displayTitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                Text(dateText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Theme.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.surfaceElevated.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(nsColor: Theme.borderSubtle), lineWidth: 0.5)
        )
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
            ChatView(sessionId: sessionId, api: api)
        }
    }
}

struct SessionHeaderView: View {
    let sessionId: String
    let provider: String
    let title: String?

    private var isCodex: Bool { provider == "codex" }
    private var providerLabel: String { isCodex ? "Codex" : "Claude" }
    private var providerColor: Color { isCodex ? Theme.codex : Theme.wandAccent }
    private var providerMuted: NSColor { isCodex ? Theme.infoMuted : Theme.wandAccentMuted }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(providerColor)
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
        .background(Theme.surface)
    }
}

// MARK: - 网页版兜底容器(从 NativeRootView 提到 MainShellView 共用)

struct WebFallbackContainer: View {
    let serverURL: URL
    let token: String?
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: onClose) {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 14, weight: .semibold))
                        Text("返回原生界面")
                            .font(.system(size: 14, weight: .medium))
                    }
                    .foregroundColor(Theme.wandAccent)
                }
                .buttonStyle(.plain)
                Spacer()
                Text("网页版")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.textSecondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Theme.background)
            Divider().opacity(0.3)
            WebContainerView(serverURL: serverURL, token: token)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.background)
    }
}

// MARK: - 布局尺寸

extension Theme {
    enum LayoutMetrics {
        static let sidebarWidth: CGFloat = 300
        static let filePanelWidth: CGFloat = 320
        static let topBarHeight: CGFloat = 44
        static let minWindowWidth: CGFloat = 900
        static let minWindowHeight: CGFloat = 600
    }
}
