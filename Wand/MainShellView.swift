import Combine
import SwiftUI

/// 横屏 native 应用主壳。布局取 Codex Desktop 的安静三栏，信息架构取 Orca：
/// 侧栏是「会话 / 项目」，工作区是一条阅读轴，右栏是按需 Inspector。
enum ShellConnectionState {
    case connecting
    case connected
    case disconnected(String)
}

enum SidebarSection: String {
    case sessions
    case workspaces
}

/// 三栏宽度常量对齐 web 端 token(`.sidebar-width: 300px`, `.file-panel-width: 320px`)。
/// 不设横贯窗口的顶栏：全局操作收进侧栏首行(sidebarTitleBar)，
/// 内容区也不使用系统原生工具栏。
struct MainShellView: View {
    let serverURL: URL
    let token: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var filePanelOpen: Bool = false
    @State private var rightPanelTab: RightPanelTab = .files
    /// 当前选中的会话 id。
    @State private var selectedSessionId: String?
    @State private var selectedSessionProvider: String = "claude"
    @State private var selectedSession: SessionSnapshot?
    @State private var selectedWorkspaceTask: WorkspaceTaskSelection?
    @AppStorage("wand.sidebar.section") private var sidebarSectionRaw = SidebarSection.sessions.rawValue
    @State private var sidebarQuery = ""
    @State private var showCreateWorkspace = false
    @State private var presentNewSession = false
    /// 连接状态(给顶栏的 connection dot 用)。
    @State private var connectionState: ShellConnectionState = .connecting
    @State private var showTroubleshooting = false
    @State private var showMissions = false
    @StateObject private var gitStatusStore = GitStatusStore()
    @StateObject private var workspaceStore: WorkspaceStore

    init(serverURL: URL, token: String?) {
        self.serverURL = serverURL
        self.token = token
        _workspaceStore = StateObject(wrappedValue: WorkspaceStore(
            api: WandAPI(baseURL: serverURL, token: token),
            serverID: serverURL.absoluteString
        ))
    }

    private var sidebarSection: SidebarSection {
        get { SidebarSection(rawValue: sidebarSectionRaw) ?? .sessions }
        nonmutating set { sidebarSectionRaw = newValue.rawValue }
    }

    /// 300 会话栏 + 560 可读聊天区 + 320 Inspector + 间距与边距。
    /// 低于该值时右栏覆盖在内容之上，保持主任务宽度稳定。
    private let persistentRightPanelMinimumWidth: CGFloat = 1_220

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

    }

    /// 面板属于偶发的空间变化，只保留短促、无回弹的空间提示。
    /// 会话切换、标签点击等高频路径不复用这个动画，保持即时。
    private var structuralAnimation: Animation? {
        reduceMotion
            ? nil
            : .easeOut(duration: 0.16)
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
                // 网页版兜底没有原生顶栏，返回入口做成悬浮胶囊，避开左上角红绿灯。
                .overlay(alignment: .topLeading) {
                    Button(action: { showWebFallback = false }) {
                        Label("返回原生界面", systemImage: "chevron.backward")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Theme.textPrimary)
                            .padding(.horizontal, 10)
                            .frame(height: 26)
                            .background(Capsule(style: .continuous).fill(Theme.surfaceElevated))
                            .overlay(
                                Capsule(style: .continuous)
                                    .stroke(Theme.border, lineWidth: 0.8)
                            )
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 80)
                    .padding(.top, 6)
                }
                .ignoresSafeArea(.container, edges: .top)
            } else {
                nativeShell
            }
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
        .sheet(isPresented: $showMissions) {
            MissionsView(
                api: api,
                onOpenSession: openSessionFromMissions,
                onDismiss: { showMissions = false }
            )
        }
        .sheet(isPresented: $showCreateWorkspace) {
            WorkspaceCreateView(api: api, store: workspaceStore) { created in
                showCreateWorkspace = false
                sidebarSection = .workspaces
                Task { await workspaceStore.loadWorkspaceSessions(workspaceId: created.id) }
            }
        }
        .task {
            await checkConnectionAsync()
        }
        .onChange(of: selectedSessionId) { id in
            if id == nil {
                selectedSession = nil
            }
        }
        .onChange(of: workspaceStore.visibleSnapshot?.id) { _ in
            guard sidebarSection == .workspaces,
                  let snapshot = workspaceStore.visibleSnapshot else { return }
            selectedSessionId = snapshot.id
            selectedSessionProvider = snapshot.provider ?? "claude"
            selectedSession = snapshot
        }
        .onReceive(NotificationCenter.default.publisher(for: .wandRequestOpenMissions)) { _ in
            showMissions = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .wandRequestSidebarSection)) { note in
            if let section = note.object as? SidebarSection {
                sidebarSectionBinding.wrappedValue = section
            }
        }
    }

    private var nativeShell: some View {
        // 主窗口不再有独立的全宽顶栏：品牌、连接状态和全局操作收进侧栏首行
        // (sidebarTitleBar，红绿灯浮在其左侧)，会话标题由主栏 SessionHeaderView 承载。
        GeometryReader { geo in
                content(width: geo.size.width)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .bottom) {
                        if geo.size.width < 800 {
                            Text("建议横屏使用,体验更佳")
                                .font(.system(size: 11))
                                .foregroundColor(Theme.textSecondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(Theme.surfaceElevated)
                                )
                                .overlay(
                                    Capsule(style: .continuous)
                                        .stroke(Theme.border, lineWidth: 0.8)
                                )
                                .padding(.bottom, 8)
                        }
                    }
                    .onChange(of: geo.size.width) { newWidth in
                        // 从常驻三栏进入紧凑布局时主动收起；用户随后仍可按需打开临时 Inspector。
                        if newWidth < persistentRightPanelMinimumWidth && filePanelOpen {
                            withAnimation(structuralAnimation) {
                                filePanelOpen = false
                            }
                        }
                    }
                    .onAppear {
                        if geo.size.width < persistentRightPanelMinimumWidth {
                            filePanelOpen = false
                        }
                    }
            }
        .background(WandAmbientBackground())
        .frame(minWidth: 900, minHeight: 600)
        // 主窗口标题栏已隐藏(fullSizeContentView)，内容顶到 y=0；
        // 显式忽略顶部安全区，避免 SwiftUI 在原标题栏位置留下一条空白。
        .ignoresSafeArea(.container, edges: .top)
    }

    private var displayHost: String {
        guard let host = serverURL.host else { return serverURL.absoluteString }
        if let port = serverURL.port { return "\(host):\(port)" }
        return host
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

    private func openSessionFromMissions(_ sessionId: String) {
        sidebarSection = .sessions
        selectedWorkspaceTask = nil
        Task {
            do {
                let session = try await api.getSession(id: sessionId)
                selectedSessionId = session.id
                selectedSessionProvider = session.provider ?? "claude"
                selectedSession = session
                connectionState = .connected
            } catch {
                connectionState = .disconnected(error.localizedDescription)
            }
        }
    }

    private func presentSession(_ session: SessionSnapshot, keepWorkspaceContext: Bool = false) {
        if !keepWorkspaceContext {
            sidebarSection = .sessions
            selectedWorkspaceTask = nil
        }
        selectedSessionId = session.id
        selectedSessionProvider = session.provider ?? "claude"
        selectedSession = session
        connectionState = .connected
    }

    // MARK: - 状态

    @State private var showWebFallback: Bool = false
    @State private var presentSettings: Bool = false

    // MARK: - 三栏

    private func content(width: CGFloat) -> some View {
        let usesPersistentRightPanel = width >= persistentRightPanelMinimumWidth
        let compactPanelWidth = min(380, max(320, width * 0.42))

        return ZStack(alignment: .trailing) {
            HStack(spacing: 0) {
                sidebarColumn
                    .frame(width: Theme.LayoutMetrics.sidebarWidth)
                    .background(Theme.sidebarBackground)
                Rectangle()
                    .fill(Color(nsColor: Theme.borderSubtle))
                    .frame(width: 0.5)
                mainColumn
                    .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.workspaceBackground)
                if filePanelOpen && usesPersistentRightPanel {
                    Rectangle()
                        .fill(Color(nsColor: Theme.borderSubtle))
                        .frame(width: 0.5)
                    rightColumn
                        .frame(width: Theme.LayoutMetrics.filePanelWidth)
                        .background(Theme.surfaceElevated)
                        .transition(rightPanelTransition)
                }
            }

            if filePanelOpen && !usesPersistentRightPanel {
                rightColumn
                    .frame(width: compactPanelWidth)
                    .background(Theme.surfaceElevated)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(Color(nsColor: Theme.borderSubtle))
                            .frame(width: 0.5)
                    }
                    .shadow(color: Color.black.opacity(0.12), radius: 18, x: -5, y: 0)
                    .transition(rightPanelTransition)
                    .zIndex(2)
            }
        }
    }

    private var rightPanelTransition: AnyTransition {
        .offset(x: 10).combined(with: .opacity)
    }

    private var sidebarColumn: some View {
        VStack(spacing: 0) {
            sidebarTitleBar
            sidebarChrome
            if sidebarSection == .workspaces {
                WorkspaceListView(
                    store: workspaceStore,
                    api: api,
                    selectedTaskId: selectedWorkspaceTask?.task.id,
                    query: sidebarQuery,
                    onOpenTask: { workspace, task in
                        selectedWorkspaceTask = WorkspaceTaskSelection(
                            workspace: workspace,
                            task: task
                        )
                    },
                    onTaskRenamed: { updated in
                        if var selection = selectedWorkspaceTask, selection.task.id == updated.id {
                            selectedWorkspaceTask = WorkspaceTaskSelection(
                                workspace: selection.workspace,
                                task: updated
                            )
                        }
                    },
                    onTaskDeleted: { taskId in
                        if selectedWorkspaceTask?.task.id == taskId {
                            selectedWorkspaceTask = nil
                        }
                    },
                    onOpenSession: { _, session in
                        Task {
                            do {
                                let snapshot = try await api.getSession(id: session.id)
                                presentSession(snapshot, keepWorkspaceContext: true)
                            } catch {
                                connectionState = .disconnected(error.localizedDescription)
                            }
                        }
                    },
                    onMergeAgentStarted: { _, started in
                        presentSession(started, keepWorkspaceContext: true)
                    },
                    onWorkspaceDeleted: { workspaceId in
                        if selectedWorkspaceTask?.workspace.id == workspaceId {
                            selectedWorkspaceTask = nil
                        }
                    },
                    onCreateWorkspace: { showCreateWorkspace = true }
                )
            } else {
                SidebarColumn(
                    api: api,
                    selectedSessionId: $selectedSessionId,
                    query: sidebarQuery,
                    presentNewSession: $presentNewSession,
                    onOpenMissions: { showMissions = true },
                    onSessionSelected: { session in
                        presentSession(session)
                    }
                )
            }
        }
    }

    // MARK: - 侧栏首行（原全宽顶栏的轻量化替代）

    /// 品牌与连接状态在左（红绿灯浮于其左侧，靠 leading 留白避开），
    /// 文件面板开关与设置菜单收在右侧；背景与侧栏连成一体，不再是横贯窗口的色带。
    private var sidebarTitleBar: some View {
        HStack(spacing: 2) {
            identityMenu
            Spacer(minLength: 0)
            filePanelToggleButton
            settingsMenu
        }
        .padding(.leading, 74)
        .padding(.trailing, 6)
        .frame(height: 40)
        .frame(maxWidth: .infinity)
    }

    private var filePanelToggleButton: some View {
        Button {
            withAnimation(structuralAnimation) { filePanelOpen.toggle() }
        } label: {
            Image(systemName: filePanelOpen ? "sidebar.right" : "sidebar.squares.right")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Theme.textSecondary)
                .frame(width: 26, height: 26)
                .contentShape(Circle())
        }
        .buttonStyle(WandIconButtonStyle(isActive: filePanelOpen))
        .help(filePanelOpen ? "隐藏文件面板" : "显示文件面板")
        .accessibilityLabel(filePanelOpen ? "隐藏文件面板" : "显示文件面板")
    }

    private var settingsMenu: some View {
        Menu {
            Button(action: { presentSettings = true }) {
                Label("设置…", systemImage: "gearshape")
            }
            Button(action: { showWebFallback = true }) {
                Label("打开网页版", systemImage: "safari")
            }
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Theme.textSecondary)
                .frame(width: 26, height: 26)
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .help("设置与更多")
        .accessibilityLabel("设置与更多")
    }

    /// 左侧只承载全局身份和连接状态。把服务器信息做成可点击的菜单，而非一个
    /// 只能靠悬停理解的绿/红小点；既不抢会话标题的位置，也能直接抵达恢复动作。
    private var identityMenu: some View {
        Menu {
            Section("服务器") {
                Label(displayHost, systemImage: "server.rack")
                Label(connectionMenuStatus, systemImage: connectionSystemImage)
            }

            Divider()

            Button(action: checkConnection) {
                Label("重新连接", systemImage: "arrow.clockwise")
            }

            if case .disconnected = connectionState {
                Button(action: { showTroubleshooting = true }) {
                    Label("故障排查", systemImage: "stethoscope")
                }
            }

            Divider()

            Button(action: {
                NotificationCenter.default.post(name: .wandRequestSwitchServer, object: nil)
            }) {
                Label("切换服务器…", systemImage: "server.rack")
            }
            Button(action: { presentSettings = true }) {
                Label("设置…", systemImage: "gearshape")
            }
            Button(action: { showWebFallback = true }) {
                Label("打开网页版", systemImage: "safari")
            }
        } label: {
            HStack(spacing: 6) {
                WandBrandMark(size: 15)
                Text("Wand")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                connectionBadge
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundColor(Theme.textMuted)
            }
            .fixedSize()
        }
        .menuStyle(.borderlessButton)
        .help("\(connectionHelp) · \(displayHost)")
        .accessibilityLabel("Wand，\(connectionAccessibilityValue)")
        .accessibilityHint("打开服务器状态与连接操作")
    }

    private var connectionBadge: some View {
        connectionIndicator
        // Menu 已提供完整的、可朗读的状态；避免 VoiceOver 在同一控件里重复。
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var connectionIndicator: some View {
        switch connectionState {
        case .connecting:
            ProgressView()
                .controlSize(.mini)
                .tint(connectionTint)
        case .connected, .disconnected:
            Circle()
                .fill(connectionTint)
                .frame(width: 6, height: 6)
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

    private var connectionMenuStatus: String {
        switch connectionState {
        case .connecting: return "正在连接"
        case .connected: return "已连接"
        case .disconnected(let message): return "连接失败：\(message)"
        }
    }

    private var connectionHelp: String {
        switch connectionState {
        case .connecting: return "正在连接服务器"
        case .connected: return "服务器已连接"
        case .disconnected(let message): return "连接失败：\(message)"
        }
    }

    private var connectionAccessibilityValue: String {
        "\(connectionMenuStatus)，服务器 \(displayHost)"
    }

    private var sidebarChrome: some View {
        VStack(spacing: 8) {
            Picker("侧栏", selection: sidebarSectionBinding) {
                Text("会话").tag(SidebarSection.sessions)
                Text("项目").tag(SidebarSection.workspaces)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("侧栏内容")

            Button {
                if sidebarSection == .workspaces {
                    showCreateWorkspace = true
                } else {
                    presentNewSession = true
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 16)
                    Text(sidebarSection == .workspaces ? "新建项目" : "新建会话")
                        .font(.system(size: 13, weight: .medium))
                    Spacer(minLength: 0)
                }
                .foregroundColor(Theme.textPrimary)
                .padding(.horizontal, 8)
                .frame(height: 30)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Theme.textPrimary.opacity(0.05))
                )
            }
            .buttonStyle(.plain)
            .keyboardShortcut("n", modifiers: .command)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Theme.textMuted)
                TextField(sidebarSection == .workspaces ? "搜索项目" : "搜索会话", text: $sidebarQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !sidebarQuery.isEmpty {
                    Button {
                        sidebarQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(Theme.textMuted)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Theme.surface.opacity(0.9))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Theme.border, lineWidth: 0.8)
            )
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private var sidebarSectionBinding: Binding<SidebarSection> {
        Binding(
            get: { sidebarSection },
            set: { section in
                sidebarSection = section
                sidebarQuery = ""
                if section == .sessions {
                    selectedWorkspaceTask = nil
                } else {
                    selectedSessionId = nil
                    selectedSession = nil
                    if case .idle = workspaceStore.indexState {
                        Task { await workspaceStore.loadWorkspaceIndex() }
                    }
                }
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
        } else if sidebarSection == .workspaces {
            if let selection = selectedWorkspaceTask {
                WorkspaceTaskView(
                    workspace: selection.workspace,
                    task: selection.task,
                    api: api,
                    store: workspaceStore,
                    gitStatusStore: gitStatusStore
                )
                .id(selection.task.id)
            } else if let sessionId = selectedSessionId {
                MainColumn(
                    api: api,
                    sessionId: sessionId,
                    provider: selectedSessionProvider,
                    session: selectedSession,
                    gitStatusStore: gitStatusStore,
                    showsHeader: true
                )
            } else {
                EmptyMainColumn(
                    title: "选择一个任务",
                    message: "项目把目录、worktree 和工作窗口收在一起。",
                    actionTitle: "新建项目",
                    action: { showCreateWorkspace = true }
                )
            }
        } else if let sessionId = selectedSessionId {
            MainColumn(
                api: api,
                sessionId: sessionId,
                provider: selectedSessionProvider,
                session: selectedSession,
                gitStatusStore: gitStatusStore,
                showsHeader: true
            )
        } else {
            EmptyMainColumn(
                title: "选择会话或新建一个",
                message: "从左侧打开最近的对话，或开始一个新的工作。",
                actionTitle: "新建会话",
                action: { presentNewSession = true }
            )
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
        HStack(spacing: 16) {
            ForEach(RightPanelTab.allCases) { tab in
                Button {
                    rightPanelTab = tab
                } label: {
                    Text(tab.label)
                        .font(.system(size: 12, weight: rightPanelTab == tab ? .semibold : .regular))
                        .foregroundColor(rightPanelTab == tab ? Theme.textPrimary : Theme.textSecondary)
                        .padding(.vertical, 11)
                        .overlay(alignment: .bottom) {
                            Rectangle()
                                .fill(rightPanelTab == tab ? Theme.textPrimary : Color.clear)
                                .frame(height: 1.5)
                        }
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.leading, 12)
        .padding(.trailing, 42)
    }

    @ViewBuilder
    private var rightColumnBody: some View {
        FilePanelView(
            sessionId: selectedSessionId,
            api: api,
            session: selectedSession,
            gitStatusStore: gitStatusStore,
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
    private enum SidebarViewMode: String {
        case sessions
        case directories
    }

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
    var query: String = ""
    @Binding var presentNewSession: Bool
    let onOpenMissions: () -> Void
    let onSessionSelected: (SessionSnapshot) -> Void

    @State private var sessions: [SessionSnapshot] = []
    @State private var historySessions: [HistorySession] = []
    @State private var loading = true
    @State private var loadError: String?
    @State private var isSelecting = false
    @State private var selectedSessionIds: Set<String> = []
    @State private var showNewSession = false
    @State private var newSessionInitialCwd: String?
    @State private var directoryTree: SessionDirectoryTreeResponse?
    @State private var directoryLoadError: String?
    @AppStorage("wand.sidebar.view-mode") private var sidebarViewModeRaw = SidebarViewMode.sessions.rawValue
    @State private var historyActionInProgress = false
    @State private var pendingDeletion: PendingDeletion?
    @State private var deleteInProgress = false
    @State private var deletionError: String?
    @State private var sessionListRevision = ""
    private let refreshTimer = Timer.publish(every: 10, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            header
            list
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.clear)
        .onChange(of: presentNewSession) { requested in
            if requested {
                newSessionInitialCwd = nil
                showNewSession = true
                presentNewSession = false
            }
        }
        .sheet(isPresented: $showNewSession, onDismiss: {
            newSessionInitialCwd = nil
        }) {
            NewSessionView(api: api, initialCwd: newSessionInitialCwd) { newSession in
                showNewSession = false
                sessions.insert(newSession, at: 0)
                onSessionSelected(newSession)
                Task { await load(silent: true) }
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

    private var sidebarViewMode: SidebarViewMode {
        get { SidebarViewMode(rawValue: sidebarViewModeRaw) ?? .sessions }
        nonmutating set {
            sidebarViewModeRaw = newValue.rawValue
            if newValue == .directories {
                isSelecting = false
                selectedSessionIds.removeAll()
            }
        }
    }

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
                Text(sidebarViewMode == .sessions ? "会话" : "目录")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.textTertiary)
                Spacer()
                Menu {
                    Button {
                        sidebarViewMode = .sessions
                    } label: {
                        Label(
                            "会话",
                            systemImage: sidebarViewMode == .sessions ? "checkmark" : "text.bubble"
                        )
                    }
                    Button {
                        sidebarViewMode = .directories
                    } label: {
                        Label(
                            "目录",
                            systemImage: sidebarViewMode == .directories ? "checkmark" : "folder"
                        )
                    }
                    if sidebarViewMode == .sessions {
                        Divider()
                        Button {
                            isSelecting = true
                        } label: {
                            Label("选择多个会话", systemImage: "checkmark.circle")
                        }
                        Button {
                            onOpenMissions()
                        } label: {
                            Label("并行任务", systemImage: "square.stack.3d.up")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Theme.textSecondary)
                        .frame(width: 28, height: 28)
                }
                .menuStyle(.borderlessButton)
                .disabled(deleteInProgress)
                .help("侧栏选项")
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(height: 38)
    }

    // MARK: - 列表

    @ViewBuilder
    private var list: some View {
        if sidebarViewMode == .directories {
            directoryList
        } else if loading && sessions.isEmpty && historySessions.isEmpty {
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
                Button {
                    newSessionInitialCwd = nil
                    showNewSession = true
                } label: {
                    Text("新建会话")
                        .frame(maxWidth: 200)
                }
                .buttonStyle(WandPrimaryButtonStyle())
                Spacer()
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(listEntries) { entry in
                        switch entry {
                        case .session(let session):
                            managedSessionTile(session)
                        case .recoverable(let session):
                            recoverableSessionTile(session)
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 8)
            }
        }
    }

    @ViewBuilder
    private var directoryList: some View {
        if loading && directoryTree == nil {
            VStack {
                Spacer()
                ProgressView().tint(Theme.wandAccent)
                Spacer()
            }
        } else if let directoryLoadError, directoryTree == nil {
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "folder.badge.questionmark")
                    .font(.system(size: 28))
                    .foregroundColor(Theme.textSecondary)
                Text(directoryLoadError)
                    .font(.footnote)
                    .foregroundColor(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                Button("重试") { Task { await load() } }
                    .buttonStyle(WandSecondaryButtonStyle())
                Spacer()
            }
            .padding(20)
        } else if let tree = directoryTree, !tree.roots.isEmpty {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(tree.roots) { node in
                        SessionDirectoryNodeView(
                            node: node,
                            depth: 0,
                            selectedSessionId: selectedSessionId,
                            onOpenSession: onSessionSelected,
                            onResumeHistory: resume,
                            onNewSession: { path in
                                newSessionInitialCwd = path
                                showNewSession = true
                            }
                        )
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 8)
            }
        } else {
            VStack(spacing: 14) {
                Spacer()
                Image(systemName: "folder")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
                Text("还没有会话目录")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                Button {
                    newSessionInitialCwd = nil
                    showNewSession = true
                } label: {
                    Text("新建会话").frame(maxWidth: 200)
                }
                .buttonStyle(WandPrimaryButtonStyle())
                Spacer()
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
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let entries = (visibleSessions.map(ListEntry.session) + recoverableSessions.map(ListEntry.recoverable))
            .sorted { $0.sortTimestamp > $1.sortTimestamp }
        guard !needle.isEmpty else { return entries }
        return entries.filter { entry in
            switch entry {
            case .session(let session):
                return session.displayTitle.lowercased().contains(needle)
                    || (session.cwd?.lowercased().contains(needle) ?? false)
                    || (session.provider?.lowercased().contains(needle) ?? false)
            case .recoverable(let history):
                return history.firstUserMessage.lowercased().contains(needle)
                    || history.cwd.lowercased().contains(needle)
            }
        }
    }

    @discardableResult
    private func load(silent: Bool = false) async -> Bool {
        if !silent { loading = true }
        do {
            let probe = try await api.probeSessionList(
                revision: sessionListRevision.isEmpty ? nil : sessionListRevision
            )
            if silent, probe.unchanged == true {
                loading = false
                return true
            }
            sessionListRevision = probe.revision
            async let directoryRequest = try? api.sessionDirectories()
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
            directoryTree = await directoryRequest
            directoryLoadError = directoryTree == nil ? "无法加载会话目录" : nil
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

private struct SessionDirectoryNodeView: View {
    let node: SessionDirectoryNode
    let depth: Int
    let selectedSessionId: String?
    let onOpenSession: (SessionSnapshot) -> Void
    let onResumeHistory: (HistorySession) -> Void
    let onNewSession: (String) -> Void

    @State private var expanded: Bool
    @State private var hovering = false

    init(
        node: SessionDirectoryNode,
        depth: Int,
        selectedSessionId: String?,
        onOpenSession: @escaping (SessionSnapshot) -> Void,
        onResumeHistory: @escaping (HistorySession) -> Void,
        onNewSession: @escaping (String) -> Void
    ) {
        self.node = node
        self.depth = depth
        self.selectedSessionId = selectedSessionId
        self.onOpenSession = onOpenSession
        self.onResumeHistory = onResumeHistory
        self.onNewSession = onNewSession
        _expanded = State(initialValue: depth == 0 || node.containsSession(selectedSessionId))
    }

    private var activePath: Bool { node.containsSession(selectedSessionId) }

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 2) {
                Button {
                    expanded.toggle()
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(Theme.textMuted)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                        Image(systemName: "folder")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(activePath ? Theme.wandAccent : Theme.textSecondary)
                        Text(node.name)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Theme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("\(node.totalCount)")
                            .font(.system(size: 9.5, weight: .bold, design: .rounded))
                            .foregroundColor(Theme.textMuted)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Theme.surfaceElevated.opacity(0.82))
                            )
                    }
                    .padding(.leading, 7)
                    .padding(.trailing, 4)
                    .frame(minHeight: 36)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(node.path.isEmpty ? node.name : node.path)

                if !node.synthetic && !node.path.isEmpty {
                    Button {
                        onNewSession(node.path)
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Theme.wandAccent)
                            .frame(width: 30, height: 30)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(WandIconButtonStyle())
                    .opacity(hovering ? 1 : 0)
                    .help("在 \(node.path) 新建会话")
                    .accessibilityLabel("在 \(node.path) 新建会话")
                }
            }
            .padding(.leading, CGFloat(min(depth, 6)) * 11)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(activePath ? Theme.wandAccent.opacity(0.08) : (hovering ? Theme.surface.opacity(0.55) : .clear))
            )
            .onHover { hovering = $0 }

            if expanded {
                ForEach(node.entries) { entry in
                    if let session = entry.session {
                        Button {
                            onOpenSession(session)
                        } label: {
                            SessionTile(
                                session: session,
                                isSelected: selectedSessionId == session.id,
                                isSelecting: false,
                                checked: false
                            )
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .padding(.leading, CGFloat(min(depth + 1, 6)) * 9 + 8)
                    } else if let history = entry.history {
                        Button {
                            onResumeHistory(history)
                        } label: {
                            HistoryTile(history: history)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .padding(.leading, CGFloat(min(depth + 1, 6)) * 9 + 8)
                    }
                }
                ForEach(node.children) { child in
                    SessionDirectoryNodeView(
                        node: child,
                        depth: depth + 1,
                        selectedSessionId: selectedSessionId,
                        onOpenSession: onOpenSession,
                        onResumeHistory: onResumeHistory,
                        onNewSession: onNewSession
                    )
                }
            }
        }
        .onChange(of: selectedSessionId) { _ in
            if activePath { expanded = true }
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

    private var folderName: String? {
        guard let cwd = session.cwd, !cwd.isEmpty else { return nil }
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? cwd : name
    }

    private var subtitle: String {
        if let folderName { return folderName }
        switch provider {
        case "codex": return "Codex"
        case "grok": return "Grok"
        case "opencode": return "OpenCode"
        case "qoder": return "Qoder"
        case "pi": return "Pi"
        default: return "Claude"
        }
    }

    private var recentTime: String {
        SessionListDateLabel.relative(iso: session.endedAt ?? session.startedAt)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Group {
                if isSelecting {
                    Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 15))
                        .foregroundColor(checked ? Theme.wandAccent : Theme.textSecondary)
                } else {
                    BrandLogoShape(provider: provider)
                        .fill(Theme.providerColor(provider))
                        .frame(width: 15, height: 15)
                }
            }
            .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 5) {
                    if prominentStatus {
                        Circle().fill(statusColor).frame(width: 5, height: 5)
                        Text(statusLabel)
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundColor(statusColor)
                            .lineLimit(1)
                    } else if !recentTime.isEmpty {
                        Text(recentTime)
                            .font(.system(size: 9.5, weight: .regular))
                            .foregroundColor(Theme.textMuted)
                    }
                    if !prominentStatus && recentTime.isEmpty {
                        Circle().fill(statusColor).frame(width: 5, height: 5)
                    }
                    if let folderName {
                        if prominentStatus || !recentTime.isEmpty {
                            Text("·")
                                .foregroundColor(Theme.textMuted.opacity(0.7))
                        }
                        Text(folderName)
                            .font(.system(size: 9.5))
                            .foregroundColor(Theme.textMuted)
                            .lineLimit(1)
                            .help(session.cwd ?? folderName)
                    } else {
                        Text(status)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundColor(Theme.textSecondary)
                    }
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(minHeight: 46)
        .wandSelectionSurface(isSelected: isSelected && !isSelecting, isHovered: hovering, cornerRadius: 7)
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
        HStack(alignment: .top, spacing: 9) {
            BrandLogoShape(provider: history.provider)
                .fill(Theme.providerColor(history.provider))
                .frame(width: 15, height: 15)
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(displayTitle)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 5) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(Theme.providerColor(history.provider))
                    Text(dateText.isEmpty ? "可恢复" : "\(dateText) · 可恢复")
                        .font(.system(size: 9.5, weight: .regular))
                        .foregroundColor(Theme.textMuted)
                    if !history.cwd.isEmpty {
                        Text("·").foregroundColor(Theme.textMuted.opacity(0.55))
                        WandPathText(path: history.cwd, fontSize: 9.5, color: Theme.textMuted)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(minHeight: 46)
        .wandSelectionSurface(isSelected: false, isHovered: hovering, cornerRadius: 7)
        .onHover { hovering = $0 }
    }
}

// MARK: - 中栏空态 + 中栏容器

struct EmptyMainColumn: View {
    var title: String = "选择会话或新建一个"
    var message: String = "从左侧打开最近的对话，或开始一个新的工作。"
    var actionTitle: String = "新建会话"
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 22, weight: .regular))
                .foregroundColor(Theme.textSecondary)
                .frame(width: 36, height: 36)
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
            Text(message)
                .font(.system(size: 12))
                .foregroundColor(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            if let action {
                Button(actionTitle, action: action)
                    .buttonStyle(WandPrimaryButtonStyle())
                    .padding(.top, 6)
            }
        }
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct MainColumn: View {
    let api: WandAPI
    let sessionId: String
    let provider: String
    let session: SessionSnapshot?
    @ObservedObject var gitStatusStore: GitStatusStore
    var showsHeader: Bool = true

    var body: some View {
        if session?.isStructured == false {
            // PTY 保留 Web 终端渲染器的键盘、光标和 ANSI/TUI 语义，
            // 但只嵌入终端工作区；标题已上收到自绘顶栏。
            VStack(spacing: 0) {
                if showsHeader {
                    SessionHeaderView(
                        provider: provider,
                        title: session?.displayTitle,
                        workingDirectory: session?.cwd
                    )
                }
                PtySessionView(sessionId: sessionId, api: api)
                .id(sessionId)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            // 结构化会话继续使用原生消息与输入体验。
            VStack(spacing: 0) {
                if showsHeader {
                    SessionHeaderView(
                        provider: provider,
                        title: session?.displayTitle,
                        workingDirectory: session?.cwd
                    )
                }
                // 必须按 sessionId 绑定身份:MainShellView 在 if let selectedSessionId 分支内
                // 复用 MainColumn 节点,只换参数。SwiftUI 默认保留子视图的 @StateObject,
                // 切换会话时 ChatStore 仍指向上一个会话(socket 不重连、快照不重拉),
                // 表现为「切了会话,内容不变」。.id(sessionId) 强制整个子树按新身份重建。
                ChatView(sessionId: sessionId, api: api, gitStatusStore: gitStatusStore)
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
        case "pi": return "Pi"
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
        HStack(spacing: 9) {
            BrandLogoShape(provider: provider)
                .fill(providerColor)
                .frame(width: 14, height: 14)
            Text(displayTitle)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            if let workingDirectoryName {
                HStack(spacing: 4) {
                    Image(systemName: "folder")
                        .font(.system(size: 9, weight: .medium))
                    Text(workingDirectoryName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.system(size: 10.5, weight: .regular))
                .foregroundColor(Theme.textSecondary)
                .help(workingDirectory ?? workingDirectoryName)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(Theme.workspaceBackground)
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
        static let sidebarWidth: CGFloat = 272
        static let filePanelWidth: CGFloat = 320
    }
}
