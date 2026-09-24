import Combine
import SwiftUI

/// Native desktop navigation with a continuous workspace and session sidebar.
/// The reading area stays mounted while settings and the inspector open.
enum ShellConnectionState {
    case connecting
    case connected
    case disconnected(String, requiresAuthentication: Bool = false)

    static func failure(_ error: Error) -> ShellConnectionState {
        if let apiError = error as? WandAPI.APIError, case .unauthorized = apiError {
            return .disconnected(error.localizedDescription, requiresAuthentication: true)
        }
        return .disconnected(error.localizedDescription)
    }

    var requiresAuthentication: Bool {
        if case .disconnected(_, let required) = self { return required }
        return false
    }
}

enum SidebarSection: String {
    case sessions
    case workspaces
}

/// A collapsible sidebar, stable reading column and optional file inspector.
/// Commands and every visible navigation entry use the same action catalog.
struct MainShellView: View {
    let serverURL: URL
    let token: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var filePanelOpen: Bool = false
    @AppStorage("wand.desktop.sidebarVisible") private var sidebarVisible = true
    @State private var showCommandPalette = false
    @State private var pendingCommand: DesktopCommand?
    @FocusState private var sidebarSearchFocused: Bool
    @State private var rightPanelTab: RightPanelTab = .files
    /// 当前选中的会话 id。
    @State private var selectedSessionId: String?
    /// 侧栏点开任务会话时先记住它自己的 cwd，等会话快照回来再接替。
    /// 没有它，右侧文件树会在快照到达前向服务器要「默认目录」（问题清单 #3）。
    @State private var selectedSessionCwdHint: String?
    @State private var selectedSessionProvider: String = "claude"
    @State private var selectedSession: SessionSnapshot?
    @State private var selectedWorkspaceTask: WorkspaceTaskSelection?
    @State private var sidebarQuery = ""
    @State private var sidebarScrollRequest: SidebarScrollRequest?
    private let sidebarRefreshTimer = Timer.publish(every: 10, on: .main, in: .common).autoconnect()
    @State private var showCreateWorkspace = false
    @State private var creationDraft = SessionCreationDraft()
    @State private var creationDrafts: [CreationDraftKey: SessionCreationDraft] = [:]
    @State private var showCreation = true
    /// 连接状态(给顶栏的 connection dot 用)。
    @State private var connectionState: ShellConnectionState = .connecting
    @State private var showTroubleshooting = false
    @State private var showTaskBoard = false
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

    private struct SidebarScrollRequest {
        let id = UUID()
        let section: SidebarSection
    }

    /// 260 会话栏 + 600 可读聊天区 + 320 Inspector + 间距与边距。
    /// 低于该值时右栏覆盖在内容之上，保持主任务宽度稳定。
    private let persistentRightPanelMinimumWidth: CGFloat = 1_220

    private var api: WandAPI { WandAPI(baseURL: serverURL, token: token) }

    /// Navigation identity excludes display labels and defaults so renamed tasks
    /// and refreshed server preferences do not discard a partially edited form.
    private enum CreationDraftKey: Hashable {
        case task(String)
        case workspace(String, startsNewTask: Bool)
        case directory(String, startsNewTask: Bool)
        case home(startsNewTask: Bool)

        init(_ context: SessionCreationContext) {
            if let taskId = context.taskId {
                self = .task(taskId)
            } else if let workspaceId = context.workspaceId {
                self = .workspace(workspaceId, startsNewTask: context.startsNewTask)
            } else if let cwd = context.cwd, !cwd.isEmpty {
                self = .directory((cwd as NSString).standardizingPath,
                                  startsNewTask: context.startsNewTask)
            } else {
                self = .home(startsNewTask: context.startsNewTask)
            }
        }
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

    }

    /// 面板属于偶发的空间变化，只保留短促、无回弹的空间提示。
    /// 会话切换、标签点击等高频路径不复用这个动画，保持即时。
    private var structuralAnimation: Animation? {
        reduceMotion
            ? nil
            : Theme.Motion.structure
    }

    var body: some View {
        nativeShell
        .focusedSceneValue(\.wandDesktopCommandsEnabled, !hasPresentedSheet)
        .sheet(isPresented: $presentSettings) {
            SettingsView(serverURL: serverURL, token: token)
                .environmentObject(ServerStore.shared)
        }
        .sheet(isPresented: $showCommandPalette, onDismiss: openPendingDestination) {
            DesktopCommandPalette(api: api, onCommand: { command in
                pendingCommand = command
                showCommandPalette = false
            }, onSession: { session in
                showCommandPalette = false
                presentSession(session)
            }, onWorkspace: { workspace in
                showCommandPalette = false
                sidebarVisible = true
                sidebarQuery = workspace.name
                sidebarScrollRequest = SidebarScrollRequest(section: .workspaces)
            }, onDismiss: { showCommandPalette = false })
        }
        .sheet(isPresented: $showTroubleshooting) {
            TroubleshootingView(
                context: TroubleshootingContext(
                    serverURL: serverURL,
                    errorMessage: disconnectedMessage,
                    source: "主窗口连接状态"
                ),
                onRetry: recoverConnection
            )
        }
        .sheet(isPresented: $showCreateWorkspace) {
            WorkspaceCreateView(api: api, store: workspaceStore) { created in
                showCreateWorkspace = false
                beginCreation(context: SessionCreationContext(
                    cwd: created.cwd,
                    workspaceId: created.id,
                    workspaceDefaultProvider: created.defaultProvider?.rawValue
                ))
            }
        }
        .task {
            await checkConnectionAsync()
        }
        .onReceive(NotificationCenter.default.publisher(for: .wandDesktopCommand)) { note in
            guard let command = note.object as? DesktopCommand else { return }
            handle(command)
        }
        .onChange(of: selectedSessionId) { id in
            if id == nil {
                selectedSession = nil
            }
        }
        .onChange(of: workspaceStore.visibleSnapshot?.id) { _ in
            guard !showCreation, let selection = selectedWorkspaceTask,
                  selection.task.id == workspaceStore.currentTask?.id else { return }
            guard let snapshot = workspaceStore.visibleSnapshot else {
                // 会话快照正在重读（store 先清空再写回）属于过程态，不是「用户没有会话」。
                // 这里清选择会让右侧文件树退回服务器默认目录。
                guard !workspaceStore.sessionLoading else { return }
                selectedSessionId = nil
                selectedSession = nil
                selectedSessionCwdHint = nil
                return
            }
            selectedSessionId = snapshot.id
            selectedSessionProvider = snapshot.provider ?? "claude"
            selectedSession = snapshot
            selectedSessionCwdHint = nil
        }
        .onReceive(sidebarRefreshTimer) { _ in
            Task { await workspaceStore.loadTaskGroups(force: true) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .wandRefreshLists)) { _ in
            Task { await workspaceStore.loadTaskGroups(force: true) }
        }
    }

    private var nativeShell: some View {
        // 标题区与正文同色；侧栏首行保留窗口操作，品牌置于下方，连接和设置留在底部。
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
        if case .disconnected(let message, _) = connectionState { return message }
        return nil
    }

    private var recoveryTitle: String {
        connectionState.requiresAuthentication ? "重新登录" : "重试连接"
    }

    private func recoverConnection() {
        if connectionState.requiresAuthentication {
            NotificationCenter.default.post(name: .wandRequestSwitchServer, object: serverURL)
        } else {
            Task { await checkConnectionAsync() }
        }
    }

    private func checkConnectionAsync() async {
        connectionState = .connecting
        do {
            _ = try await api.listSessions()
            connectionState = .connected
            NotificationCenter.default.post(name: .wandRefreshLists, object: nil)
            await workspaceStore.loadTaskGroups(force: true)
        } catch {
            connectionState = .failure(error)
            if let apiError = error as? WandAPI.APIError,
               case .network = apiError,
               LocalNetworkPermission.shouldCheckForServer(serverURL.host) {
                LocalNetworkPermission.offerRecoveryIfDenied()
            }
        }
    }

    private func openSessionFromMissions(_ sessionId: String) {
        selectedWorkspaceTask = nil
        selectedSessionCwdHint = nil
        showTaskBoard = false
        showCreation = false
        Task {
            do {
                let session = try await api.getSession(id: sessionId)
                selectedSessionId = session.id
                selectedSessionProvider = session.provider ?? "claude"
                selectedSession = session
                connectionState = .connected
            } catch {
                connectionState = .failure(error)
            }
        }
    }

    private func presentSession(_ session: SessionSnapshot) {
        showTaskBoard = false
        showCreation = false
        selectedWorkspaceTask = nil
        selectedSessionCwdHint = nil
        selectedSessionId = session.id
        selectedSessionProvider = session.provider ?? "claude"
        selectedSession = session
        connectionState = .connected
    }

    private func beginCreation(
        context: SessionCreationContext = .init(),
        taskSelection: WorkspaceTaskSelection? = nil
    ) {
        creationDrafts[CreationDraftKey(creationDraft.context)] = creationDraft
        let key = CreationDraftKey(context)
        if let existingDraft = creationDrafts[key] {
            creationDraft = existingDraft
        } else {
            let newDraft = SessionCreationDraft(context: context)
            creationDrafts[key] = newDraft
            creationDraft = newDraft
        }
        showCreation = true
        showTaskBoard = false
        filePanelOpen = false
        selectedWorkspaceTask = taskSelection
        selectedSessionId = nil
        selectedSession = nil
        selectedSessionCwdHint = nil
    }

    private func beginNewTask(_ request: NewTaskSheetRequest) {
        let workspace = workspaceStore.workspaces.first {
            if let workspaceId = request.workspaceId { return $0.id == workspaceId }
            return !request.cwd.isEmpty
                && ($0.cwd as NSString).standardizingPath == (request.cwd as NSString).standardizingPath
        }
        beginCreation(context: SessionCreationContext(
            cwd: request.cwd.isEmpty ? nil : request.cwd,
            workspaceId: request.workspaceId ?? workspace?.id,
            workspaceDefaultProvider: workspace?.defaultProvider?.rawValue
        ))
    }

    private func beginTaskSession(workspace: Workspace, task: WorkspaceTask) {
        beginCreation(context: SessionCreationContext(
            cwd: workspace.cwd,
            workspaceId: workspace.id,
            taskId: task.id,
            taskName: task.name,
            workspaceDefaultProvider: workspace.defaultProvider?.rawValue,
            startsNewTask: false
        ), taskSelection: WorkspaceTaskSelection(workspace: workspace, task: task))
    }

    private var creationDestinationVisible: Bool {
        showCreation || (!showTaskBoard
            && selectedWorkspaceTask == nil && selectedSessionId == nil)
    }

    private func openCreatedSession(_ session: SessionSnapshot, originDraftID: UUID) {
        let shouldOpen = creationDraft.id == originDraftID && creationDestinationVisible
        creationDrafts = creationDrafts.filter { $0.value.id != originDraftID }
        if creationDraft.id == originDraftID {
            creationDraft = SessionCreationDraft(context: creationDraft.context)
        }
        if shouldOpen { presentSession(session) }
        NotificationCenter.default.post(name: .wandRefreshLists, object: nil)
        Task {
            await workspaceStore.loadWorkspaceIndex()
            await workspaceStore.loadTaskGroups(force: true)
            guard shouldOpen, let taskId = session.workspaceTaskId,
                  let detail = try? await api.getWorkspaceTask(taskId: taskId),
                  let workspace = workspaceStore.workspaces.first(where: {
                      $0.id == (session.workspaceId ?? detail.workspaceId)
                  }),
                  !showCreation, !showTaskBoard, selectedSessionId == session.id else { return }
            let task = WorkspaceTask(
                id: detail.id,
                workspaceId: detail.workspaceId,
                name: detail.name,
                worktree: detail.worktree,
                layout: detail.layout,
                status: detail.status,
                createdAt: detail.createdAt,
                lastOpenedAt: detail.lastOpenedAt
            )
            selectedWorkspaceTask = WorkspaceTaskSelection(workspace: workspace, task: task)
            await workspaceStore.openTask(workspace: workspace, task: task,
                                          preferredSessionId: session.id)
        }
    }

    // MARK: - 状态

    @State private var presentSettings: Bool = false

    // MARK: - 三栏

    private func content(width: CGFloat) -> some View {
        let usesPersistentRightPanel = width >= persistentRightPanelMinimumWidth
        let compactPanelWidth = min(380, max(320, width * 0.42))

        return ZStack(alignment: .trailing) {
            HStack(spacing: 0) {
                if sidebarVisible {
                    sidebarColumn
                        .frame(width: Theme.LayoutMetrics.sidebarWidth)
                        .background(Theme.sidebarBackground)
                        .transition(reduceMotion ? .identity : .move(edge: .leading).combined(with: .opacity))
                    Rectangle().fill(Theme.border.opacity(0.5)).frame(width: 0.5)
                }
                VStack(spacing: 0) {
                    desktopToolbar
                    if let message = disconnectedMessage, selectedSessionId != nil || selectedWorkspaceTask != nil {
                        HStack(spacing: 8) {
                            Image(systemName: "wifi.exclamationmark")
                            Text("连接中断，当前内容已保留。" + message).lineLimit(1)
                            Spacer()
                            Button(recoveryTitle, action: recoverConnection)
                        }.font(.system(size: 12)).foregroundColor(Theme.warning).padding(10)
                    }
                    mainColumn
                }
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
        reduceMotion ? .identity : .offset(x: 10).combined(with: .opacity)
    }

    private var sidebarColumn: some View {
        VStack(spacing: 0) {
            sidebarTitleBar
            sidebarBrand
            sidebarChrome
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        workspaceSidebar.id(SidebarSection.workspaces)
                        sidebarSectionBreak
                        SidebarColumn(
                            api: api,
                            selectedSessionId: Binding(
                                get: {
                                    showTaskBoard || showCreation || selectedWorkspaceTask != nil
                                        ? nil : selectedSessionId
                                },
                                set: { selectedSessionId = $0 }
                            ),
                            query: sidebarQuery,
                            taskGroups: workspaceStore.taskGroups,
                            taskGroupsAvailable: workspaceStore.taskGroupsLoaded,
                            presentNewSession: .constant(false),
                            onSessionSelected: { presentSession($0) },
                            onRequestNewSession: { cwd in
                                beginCreation(context: SessionCreationContext(cwd: cwd, startsNewTask: false))
                            }
                        )
                        .id(SidebarSection.sessions)
                    }
                    .padding(.top, 4)
                    .padding(.bottom, 16)
                }
                .onChange(of: sidebarScrollRequest?.id) { _ in
                    if let request = sidebarScrollRequest {
                        proxy.scrollTo(request.section, anchor: .top)
                    }
                }
                .onAppear {
                    if let request = sidebarScrollRequest {
                        proxy.scrollTo(request.section, anchor: .top)
                    }
                }
            }
            sidebarFooter
        }
    }

    private var workspaceSidebar: some View {
        WorkspaceListView(
            store: workspaceStore,
            api: api,
            selectedTaskId: showTaskBoard ? nil : selectedWorkspaceTask?.task.id,
            selectedSessionId: selectedSessionId,
            query: sidebarQuery,
            onOpenTask: { workspace, task in
                showTaskBoard = false
                showCreation = false
                selectedSessionId = nil
                selectedSession = nil
                selectedSessionCwdHint = nil
                selectedWorkspaceTask = WorkspaceTaskSelection(
                    workspace: workspace,
                    task: task
                )
            },
            onTaskRenamed: { updated in
                if let selection = selectedWorkspaceTask, selection.task.id == updated.id {
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
                        presentSession(snapshot)
                    } catch {
                        connectionState = .failure(error)
                    }
                }
            },
            onOpenTaskSession: { workspace, task, session in
                showTaskBoard = false
                showCreation = false
                selectedSessionId = session.id
                // 摘要里已带 cwd：先用它填右侧文件栏，避免空路径被当成服务器默认目录。
                selectedSessionCwdHint = session.cwd
                selectedSession = nil
                selectedWorkspaceTask = WorkspaceTaskSelection(
                    workspace: workspace,
                    task: task
                )
                Task { await workspaceStore.openTask(workspace: workspace, task: task, preferredSessionId: session.id) }
            },
            onRequestNewSession: { workspace, task in
                beginTaskSession(workspace: workspace, task: task)
            },
            onRequestNewTask: beginNewTask,
            onMergeAgentStarted: { _, started in
                presentSession(started)
            },
            onWorkspaceDeleted: { workspaceId in
                if selectedWorkspaceTask?.workspace.id == workspaceId {
                    selectedWorkspaceTask = nil
                }
            },
            onCreateWorkspace: { showCreateWorkspace = true }
        )
    }

    // Leave the first row clear for the macOS traffic lights and sidebar toggle.
    private var sidebarTitleBar: some View {
        HStack(spacing: 8) {
            WindowDragRegion().frame(maxWidth: .infinity).frame(height: 52)
            Button { handle(.toggleSidebar) } label: {
                Image(systemName: "sidebar.left").frame(width: 28, height: 28)
            }.buttonStyle(WandIconButtonStyle()).help("隐藏侧栏 · ⌃⌘S")
                .accessibilityLabel("隐藏侧栏")
        }
        .padding(.leading, 82).padding(.trailing, 12)
        .frame(height: 52)
        .windowDrag()
    }

    private var sidebarBrand: some View {
        HStack(spacing: 10) {
            WandBrandMark(size: 36)
            Text("Wand")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: 56)
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
        Button { handle(.settings) } label: {
            Image(systemName: "gearshape").frame(width: 28, height: 28)
        }
        .buttonStyle(WandIconButtonStyle())
        .help("设置 · ⌘,")
        .accessibilityLabel("设置")
    }

    /// 底部连接状态和服务器地址保持可点击，可直接恢复连接或切换服务器。
    private var identityMenu: some View {
        Menu {
            Section("服务器") {
                Label(displayHost, systemImage: "server.rack")
                Label(connectionMenuStatus, systemImage: connectionSystemImage)
            }

            Divider()

            Button(action: recoverConnection) {
                Label(recoveryTitle, systemImage: "arrow.clockwise")
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
        } label: {
            HStack(spacing: 6) {
                connectionBadge
                Text(displayHost)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .help("\(connectionHelp) · \(displayHost)")
        .accessibilityLabel(connectionAccessibilityValue)
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
        case .disconnected(let message, _): return "连接失败：\(message)"
        }
    }

    private var connectionHelp: String {
        switch connectionState {
        case .connecting: return "正在连接服务器"
        case .connected: return "服务器已连接"
        case .disconnected(let message, _): return "连接失败：\(message)"
        }
    }

    private var connectionAccessibilityValue: String {
        "\(connectionMenuStatus)，服务器 \(displayHost)"
    }

    private var sidebarChrome: some View {
        VStack(spacing: 3) {
            navigationRow(.newSession, active: showCreation && selectedWorkspaceTask == nil)
            navigationRow(.search)
            navigationRow(.taskBoard, active: showTaskBoard)
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease").foregroundColor(Theme.textSecondary)
                TextField("筛选工作空间与会话…", text: $sidebarQuery)
                    .textFieldStyle(.plain).focused($sidebarSearchFocused)
                if !sidebarQuery.isEmpty {
                    Button { sidebarQuery = ""; sidebarSearchFocused = true } label: {
                        Image(systemName: "xmark.circle.fill")
                    }.buttonStyle(.plain).accessibilityLabel("清除筛选").help("清除筛选")
                }
            }
            .font(.system(size: 12)).padding(.horizontal, 9).frame(height: 32)
            .wandInputSurface(focused: sidebarSearchFocused, cornerRadius: Theme.Radius.control)
            .padding(.top, 12)
        }.padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 12)
    }

    /// 操作区结束之后，用一条短分隔把工作空间树和单独会话切开。
    private var sidebarSectionBreak: some View {
        Rectangle()
            .fill(Theme.border.opacity(0.9))
            .frame(height: 0.5)
            .padding(.horizontal, 14)
            .padding(.top, 16)
            .padding(.bottom, 12)
    }

    private func navigationRow(_ command: DesktopCommand, active: Bool = false) -> some View {
        Button { handle(command) } label: {
            HStack(spacing: 10) {
                Image(systemName: command.symbol).font(.system(size: 14)).frame(width: 20)
                Text(command.title).font(.system(size: 13, weight: active ? .semibold : .regular))
                Spacer(minLength: 4)
                if command == .newSession || command == .search {
                    Text(command.shortcutLabel).font(.system(size: 10)).foregroundColor(Theme.textTertiary)
                }
            }
            .foregroundColor(Theme.textPrimary).padding(.horizontal, 9).frame(height: 38)
            .contentShape(Rectangle())
        }.buttonStyle(DesktopNavigationButtonStyle(active: active))
            .help(command.subtitle + (command.shortcutLabel.isEmpty ? "" : " · " + command.shortcutLabel))
            .accessibilityAddTraits(active ? .isSelected : [])
    }

    private var sidebarFooter: some View {
        VStack(spacing: 8) {
            Divider()
            HStack(spacing: 10) {
                identityMenu
                settingsMenu
            }.padding(.horizontal, 4).padding(.vertical, 4)
        }.padding(12)
    }

    private var desktopToolbar: some View {
        HStack(spacing: 10) {
            if !sidebarVisible {
                Button { handle(.toggleSidebar) } label: {
                    Image(systemName: "sidebar.left").frame(width: 28, height: 28)
                }.buttonStyle(WandIconButtonStyle()).help("显示侧栏 · ⌃⌘S")
                    .accessibilityLabel("显示侧栏")
            }
            if showCreation {
                SessionCreationToolbarTitle(draft: creationDraft)
            } else if showTaskBoard {
                Text("任务看板").font(.system(size: 15, weight: .medium))
            } else if selectedWorkspaceTask == nil, let session = selectedSession {
                BrandLogo(provider: selectedSessionProvider, color: Theme.textSecondary)
                    .frame(width: 16, height: 16)
                Text(session.displayTitle).font(.system(size: 15, weight: .medium))
                    .lineLimit(1).help(session.displayTitle)
            } else {
                Text(selectedWorkspaceTask?.workspace.name ?? "Wand")
                    .font(.system(size: 15, weight: .medium)).foregroundColor(Theme.textSecondary).lineLimit(1)
            }
            WindowDragRegion().frame(minWidth: 12, maxWidth: .infinity).frame(height: 52)
            if !showCreation, !showTaskBoard, selectedSessionId != nil || selectedWorkspaceTask != nil {
                filePanelToggleButton
            }
        }
        .padding(.leading, sidebarVisible ? 24 : 86).padding(.trailing, 20).frame(height: 52)
        .background(Theme.workspaceBackground)
        .windowDrag()
    }

    private func openPendingDestination() {
        if let command = pendingCommand {
            pendingCommand = nil
            // This is an explicit palette selection, not a shortcut from a sheet.
            // AppKit can still report the closing sheet as key during onDismiss;
            // the shortcut guard would silently discard the selected command.
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .wandDesktopCommand, object: command)
            }
        }
    }

    private var hasPresentedSheet: Bool {
        presentSettings || showCommandPalette || showTroubleshooting || showCreateWorkspace
    }

    private func handle(_ command: DesktopCommand) {
        switch command {
        case .newSession:
            beginCreation()
        case .newTask:
            beginNewTask(NewTaskSheetRequest(cwd: "", projectHint: nil))
        case .search: showCommandPalette = true
        case .toggleSidebar: withAnimation(structuralAnimation) { sidebarVisible.toggle() }
        case .toggleInspector: withAnimation(structuralAnimation) { filePanelOpen.toggle() }
        case .workspaces, .sessions:
            sidebarVisible = true
            sidebarQuery = ""
            sidebarScrollRequest = SidebarScrollRequest(
                section: command == .workspaces ? .workspaces : .sessions
            )
        case .taskBoard: showCreation = false; showTaskBoard = true; filePanelOpen = false
        case .settings: presentSettings = true
        case .reconnect: recoverConnection()
        case .focusComposer, .findConversation: break
        }
    }

    @ViewBuilder
    private var mainColumn: some View {
        if case .disconnected(let message, _) = connectionState, selectedSessionId == nil, selectedWorkspaceTask == nil {
            ConnectionFailureView(
                message: message,
                requiresAuthentication: connectionState.requiresAuthentication,
                onRetry: recoverConnection,
                onSwitchServer: { NotificationCenter.default.post(name: .wandRequestSwitchServer, object: nil) },
                onTroubleshoot: { showTroubleshooting = true }
            )
        } else if showCreation {
            creationView
        } else if showTaskBoard {
            TaskBoardView(api: api, onOpenSession: openSessionFromMissions, embedded: true)
        } else if let selection = selectedWorkspaceTask {
            WorkspaceTaskView(
                workspace: selection.workspace,
                task: selection.task,
                api: api,
                store: workspaceStore,
                gitStatusStore: gitStatusStore,
                preferredSessionId: selectedSessionId,
                onRequestNewSession: {
                    beginTaskSession(workspace: selection.workspace, task: selection.task)
                }
            )
            .id(selection.task.id)
        } else if let sessionId = selectedSessionId {
            MainColumn(
                api: api,
                sessionId: sessionId,
                provider: selectedSessionProvider,
                session: selectedSession,
                gitStatusStore: gitStatusStore,
                showsHeader: false
            )
        } else {
            creationView
        }
    }

    private var creationView: some View {
        let originDraftID = creationDraft.id
        return DesktopWelcomeView(api: api, draft: creationDraft, workspaceStore: workspaceStore) {
            openCreatedSession($0, originDraftID: originDraftID)
        }
        .id(originDraftID)
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
            .help("折叠文件面板").accessibilityLabel("折叠文件面板")
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
                .buttonStyle(DesktopNavigationButtonStyle())
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
            rootPath: filePanelRootPath,
            rootPathPending: filePanelRootPending,
            gitStatusStore: gitStatusStore,
            tab: $rightPanelTab
        )
    }

    /// 文件栏根目录：会话快照优先，其次本次点开时记住的 cwd。
    private var filePanelRootPath: String? {
        Self.normalizedPath(selectedSession?.cwd) ?? Self.normalizedPath(selectedSessionCwdHint)
    }

    /// 会话或任务已经选定、但工作目录还没到：文件树应等待而不是列出服务器默认目录。
    private var filePanelRootPending: Bool {
        guard filePanelRootPath == nil else { return false }
        if selectedSessionId != nil || workspaceStore.sessionLoading { return true }
        guard selectedWorkspaceTask != nil else { return false }
        switch workspaceStore.taskState {
        case .idle, .loading:
            return true
        case .ready(let detail):
            // 有会话但快照还没回来。
            return !detail.sessions.isEmpty
        case .empty, .failed:
            return false
        }
    }

    private static func normalizedPath(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

}

private struct ConnectionFailureView: View {
    let message: String
    let requiresAuthentication: Bool
    let onRetry: () -> Void
    let onSwitchServer: () -> Void
    let onTroubleshoot: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 26, weight: .regular))
                .foregroundColor(Theme.textSecondary)
                .frame(width: 64, height: 64)
                .background(Circle().fill(Theme.surface))
                .accessibilityHidden(true)
            Text(requiresAuthentication ? "请重新登录" : "无法连接服务器")
                .font(.system(size: 24, weight: .semibold))
                .tracking(-0.4)
                .foregroundColor(Theme.textPrimary)
            Text(message)
                .font(.system(size: 13))
                .lineSpacing(5)
                .foregroundColor(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
                .textSelection(.enabled)
            HStack(spacing: 10) {
                Button(requiresAuthentication ? "重新登录" : "重试连接", action: onRetry)
                    .buttonStyle(WandPrimaryButtonStyle())
                Button("切换服务器", action: onSwitchServer)
                    .buttonStyle(WandSecondaryButtonStyle())
            }
            .padding(.top, 8)
            Button(action: onTroubleshoot) {
                Label("故障排查", systemImage: "stethoscope")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textSecondary)
                    .padding(.horizontal, 10).padding(.vertical, 6)
            }.buttonStyle(DesktopNavigationButtonStyle())
            Spacer()
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}

struct EmptyMainColumn: View {
    var title: String = "选择会话或新建一个"
    var message: String = "从左侧打开最近的对话，或开始一个新的工作。"
    var actionTitle: String = "新建会话"
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            WandBrandMark(size: 36)
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
            // PTY 使用 AppKit 终端直连 /ws；标题由原生主壳统一呈现。
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

/// Observe the draft itself so a refreshed task name updates the toolbar without replacing its identity.
struct SessionCreationToolbarTitle: View {
    @ObservedObject var draft: SessionCreationDraft

    @MainActor
    static func title(for draft: SessionCreationDraft) -> String {
        draft.resolvedTaskName ?? "新建会话"
    }

    var body: some View {
        Text(Self.title(for: draft))
            .font(.system(size: 15, weight: .medium))
            .foregroundColor(Theme.textSecondary)
            .lineLimit(1)
            .help(Self.title(for: draft))
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
            BrandLogo(provider: provider, color: Theme.textPrimary)
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

// MARK: - 布局尺寸

extension Theme {
    enum LayoutMetrics {
        static let sidebarWidth: CGFloat = 260
        static let filePanelWidth: CGFloat = 320
    }
}
