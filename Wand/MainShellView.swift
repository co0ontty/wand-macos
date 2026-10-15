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
    private let makeSettings: (@escaping () -> Void) -> SettingsView

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
    @State private var sidebarSearchOpen = false
    @AppStorage("wand.desktop.sidebarRecent") private var sidebarRecent = false
    @AppStorage("wand.desktop.sidebarActiveOnly") private var sidebarActiveOnly = false
    @State private var sidebarScrollRequest: SidebarScrollRequest?
    private let sidebarRefreshTimer = Timer.publish(every: 10, on: .main, in: .common).autoconnect()
    @State private var showCreateWorkspace = false
    /// 「用户明确打开了这个会话」。只有带 intent 的那次打开才允许确认完成代次：
    /// 自动选中最近会话、后台轮询、重连、切任务都不算（对齐 Web completionViewIntent）。
    @State private var completionViewIntentSessionId: String?
    @State private var displayedCompletionSessionId: String?
    @State private var displayedCompletionRevision = 0
    @State private var acknowledgedCompletionRevision: Int?
    @State private var creationDraft = SessionCreationDraft()
    @State private var creationDrafts: [CreationDraftKey: SessionCreationDraft] = [:]
    @State private var showCreation = true
    /// 连接状态(给顶栏的 connection dot 用)。
    @State private var connectionState: ShellConnectionState = .connecting
    @State private var showTroubleshooting = false
    @State private var showTaskBoard = false
    @State private var showCommunications = false
    @StateObject private var communicationsStore: CommunicationsStore
    @StateObject private var gitStatusStore = GitStatusStore()
    @StateObject private var workspaceStore: WorkspaceStore

    init(serverURL: URL, token: String?, makeSettings: ((@escaping () -> Void) -> SettingsView)? = nil) {
        self.serverURL = serverURL
        self.token = token
        self.makeSettings = makeSettings ?? { close in
            SettingsView(serverURL: serverURL, token: token, onClose: close, titlebarLeadingInset: 40)
        }
        _communicationsStore = StateObject(wrappedValue: CommunicationsStore(
            api: WandAPI(baseURL: serverURL, token: token), serverURL: serverURL
        ))
        _workspaceStore = StateObject(wrappedValue: WorkspaceStore(
            api: WandAPI(baseURL: serverURL, token: token),
            serverID: serverURL.absoluteString
        ))
    }

    private struct SidebarScrollRequest {
        let id = UUID()
        let section: SidebarSection
    }

    /// 导航轨 + 260 会话栏 + 600 阅读区 + 320 Inspector + 间距。
    /// 低于该值时右栏覆盖在内容之上，保持主任务宽度稳定。
    private let persistentRightPanelMinimumWidth: CGFloat = 1_280

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
        .focusedSceneValue(\.wandDesktopDisabledCommands, unavailableCommands)
        .sheet(isPresented: $showCommandPalette, onDismiss: openPendingDestination) {
            DesktopCommandPalette(api: api, onCommand: { command in
                pendingCommand = command
                showCommandPalette = false
            }, onSession: { session in
                showCommandPalette = false
                closeSettings()
                presentSession(session)
            }, onWorkspace: { workspace in
                closeSettings()
                showCommunications = false
                showCommandPalette = false
                sidebarVisible = true
                sidebarQuery = workspace.name
                sidebarSearchOpen = true
                sidebarRecent = false
                sidebarScrollRequest = SidebarScrollRequest(section: .workspaces)
            }, onDismiss: { showCommandPalette = false }, unavailableCommands: unavailableCommands)
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
            openPendingActivitySession()
        }
        .onReceive(NotificationCenter.default.publisher(for: .wandOpenActivitySession)) { _ in
            openPendingActivitySession()
        }
        .onChange(of: hasPresentedSheet) { presented in
            if !presented { openPendingActivitySession() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .wandDesktopCommand)) { note in
            guard let command = note.object as? DesktopCommand else { return }
            handle(command)
        }
        .onChange(of: settingsPresented) { presented in
            guard !presented, let session = selectedSession,
                  !showCreation, !showCommunications, !showTaskBoard else { return }
            acknowledgeCompletionIfViewed(session)
        }
        .onChange(of: selectedSessionId) { id in
            if id == nil {
                selectedSession = nil
            }
        }
        .onChange(of: workspaceStore.visibleSnapshot?.id) { _ in
            guard !showCreation, !showCommunications, let selection = selectedWorkspaceTask,
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
        // 品牌与窗口操作共用一行；导航轨固定，列表和工作页分别保留自己的滚动。
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

    private func openPendingActivitySession() {
        guard !hasPresentedSheet, let id = DesktopActivityMonitor.shared.pendingOpenSessionID else { return }
        let connection = DesktopActivityMonitor.shared.connectionID
        DesktopActivityMonitor.shared.consumeOpenSession(id)
        closeSettings()
        Task {
            do {
                let session = try await api.getSession(id: id)
                guard connection == DesktopActivityMonitor.shared.connectionID else { return }
                presentSession(session)
            } catch {
                guard connection == DesktopActivityMonitor.shared.connectionID else { return }
                connectionState = .failure(error)
            }
        }
    }

    private func openSessionFromMissions(_ sessionId: String) {
        showCommunications = false
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
                openCompletionIntent(session.id)
            } catch {
                connectionState = .failure(error)
            }
        }
    }

    private func presentSession(_ session: SessionSnapshot) {
        showCommunications = false
        showTaskBoard = false
        showCreation = false
        selectedWorkspaceTask = nil
        selectedSessionCwdHint = nil
        selectedSessionId = session.id
        selectedSessionProvider = session.provider ?? "claude"
        selectedSession = session
        connectionState = .connected
        openCompletionIntent(session.id)
    }

    private func openCompletionIntent(_ sessionId: String) {
        completionViewIntentSessionId = sessionId
        acknowledgedCompletionRevision = nil
        if displayedCompletionSessionId == sessionId, let session = selectedSession {
            acknowledgeCompletionIfViewed(session)
        } else {
            displayedCompletionSessionId = nil
            displayedCompletionRevision = 0
        }
    }

    private func clearCompletionIntent() {
        completionViewIntentSessionId = nil
        displayedCompletionSessionId = nil
        displayedCompletionRevision = 0
        acknowledgedCompletionRevision = nil
    }

    private func completionSnapshotDisplayed(_ session: SessionSnapshot) {
        guard selectedSessionId == session.id else { return }
        displayedCompletionSessionId = session.id
        displayedCompletionRevision = session.completionRevision ?? 0
        selectedSession = session
        acknowledgeCompletionIfViewed(session)
    }

    /// 只在「明确打开 + 这一代结果真的在屏幕上 + 没有任何弹层挡着」时确认完成代次。
    /// 同一代次只发一次；失败保留未读提示，下一次明确打开还能重试。
    private func acknowledgeCompletionIfViewed(_ session: SessionSnapshot) {
        guard !settingsPresented, !showCreation, !showCommunications, !showTaskBoard,
              displayedCompletionSessionId == session.id,
              (session.completionRevision ?? 0) <= displayedCompletionRevision else { return }
        let isJustCompleted = SessionCompletion.isJustCompleted(
            completion: session.completionRevision,
            viewed: session.viewedCompletionRevision,
            status: session.status,
            archived: session.archived,
            ptyBusy: session.ptyBusy,
            inFlight: session.structuredState?.inFlight,
            permissionBlocked: session.permissionBlocked,
            pendingEscalation: session.pendingEscalation != nil,
            providerCliExitCode: session.providerCliExitCode
        )
        guard SessionCompletion.shouldAcknowledge(
            isJustCompleted: isJustCompleted,
            explicitOpen: completionViewIntentSessionId == session.id,
            isSelected: selectedSessionId == session.id,
            modalVisible: anyModalSheetPresented
        ) else { return }
        let revision = session.completionRevision ?? 0
        guard revision > 0, acknowledgedCompletionRevision != revision else { return }
        acknowledgedCompletionRevision = revision
        Task {
            do {
                try await workspaceStore.markSessionCompletionViewed(
                    sessionId: session.id,
                    completionRevision: revision
                )
            } catch {
                // A late failure must not unlock another session/generation's request.
                if completionViewIntentSessionId == session.id, acknowledgedCompletionRevision == revision {
                    acknowledgedCompletionRevision = nil
                }
            }
        }
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
        showCommunications = false
        showTaskBoard = false
        filePanelOpen = false
        selectedWorkspaceTask = taskSelection
        clearCompletionIntent()
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
            workspaceDefaultProvider: workspace?.defaultProvider?.rawValue,
            startsNewTask: true
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
        SessionCreationDraft.creationIsVisible(showCreation: showCreation, showCommunications: showCommunications,
            showTaskBoard: showTaskBoard, hasSelectedTask: selectedWorkspaceTask != nil,
            hasSelectedSession: selectedSessionId != nil, settingsPresented: settingsPresented)
    }

    private func openCreatedSession(_ session: SessionSnapshot, originDraftID: UUID) {
        let shouldOpen = SessionCreationDraft.shouldOpenReceipt(originDraftID: originDraftID,
            currentDraftID: creationDraft.id, creationVisible: creationDestinationVisible)
        creationDrafts = creationDrafts.filter { $0.value.id != originDraftID || !$0.value.firstMessage.isEmpty }
        if creationDraft.id == originDraftID {
            if creationDraft.firstMessage.isEmpty {
                creationDraft = SessionCreationDraft(context: creationDraft.context)
            } else {
                creationDrafts[CreationDraftKey(creationDraft.context)] = creationDraft
            }
        }
        if shouldOpen {
            sidebarQuery = ""
            sidebarVisible = true
            presentSession(session)
        }
        Task {
            async let indexLoad: Void = workspaceStore.loadWorkspaceIndex()
            async let groupsLoad: Void = workspaceStore.loadTaskGroups(force: true)
            _ = await (indexLoad, groupsLoad)
            guard shouldOpen, let taskId = session.workspaceTaskId,
                  let detail = try? await api.getWorkspaceTask(taskId: taskId),
                  let workspace = workspaceStore.workspaces.first(where: {
                      $0.id == (session.workspaceId ?? detail.workspaceId)
                  }),
                  !settingsPresented, !showCreation, !showTaskBoard, selectedSessionId == session.id else { return }
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

    // MARK: - 页面与三栏

    @State private var settingsPresented = false

    private var sidebarListVisible: Bool { sidebarVisible && !settingsPresented }

    private func content(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            sidebarColumn
                .background(Theme.sidebarBackground)
            Rectangle().fill(Theme.border.opacity(0.5)).frame(width: 0.5)
            DesktopPageStack(settingsPresented: settingsPresented,
                workspaceWidth: max(0, width - Theme.LayoutMetrics.navigationRailWidth
                    - (sidebarVisible ? Theme.LayoutMetrics.sidebarWidth : 0) - 0.5)) {
                workspaceContent(width: width)
            } settings: {
                makeSettings(closeSettings)
            }
        }
    }

    private func workspaceContent(width: CGFloat) -> some View {
        let usesPersistentRightPanel = width >= persistentRightPanelMinimumWidth
        let compactPanelWidth = min(380, max(320, width * 0.42))

        return ZStack(alignment: .trailing) {
            HStack(spacing: 0) {
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
                if filePanelOpen && !showCommunications && usesPersistentRightPanel {
                    Rectangle()
                        .fill(Color(nsColor: Theme.borderSubtle))
                        .frame(width: 0.5)
                    rightColumn
                        .frame(width: Theme.LayoutMetrics.filePanelWidth)
                        .background(Theme.surfaceElevated)
                        .transition(rightPanelTransition)
                }
            }

            if filePanelOpen && !showCommunications && !usesPersistentRightPanel {
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
        DesktopSidebarLayout(listVisible: sidebarListVisible, onToggle: { handle(.toggleSidebar) }) {
            DesktopNavigationRail(selection: settingsPresented ? .settings : showTaskBoard ? .taskBoard
                : showCommunications ? (communicationsStore.section == .contacts ? .contacts : .conversations) : .workspaces,
                onCommand: handle)
        } list: {
            VStack(spacing: 0) {
                sidebarChrome
                if showCommunications {
                    CommunicationsSidebar(store: communicationsStore,
                        sessions: workspaceStore.taskGroups.flatMap { $0.tasks.flatMap(\.sessions) + $0.standaloneSessions },
                        selectedSessionID: selectedSessionId)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(spacing: 0) {
                                workspaceSidebar.id(SidebarSection.workspaces)
                                if !sidebarRecent {
                                    sidebarSectionBreak
                                    SidebarColumn(
                                        api: api,
                                        selectedSessionId: Binding(
                                            get: {
                                                showTaskBoard || showCreation || showCommunications || selectedWorkspaceTask != nil
                                                    ? nil : selectedSessionId
                                            },
                                            set: { selectedSessionId = $0 }
                                        ),
                                        query: sidebarQuery,
                                        activeOnly: sidebarActiveOnly,
                                        taskGroups: workspaceStore.taskGroups,
                                        taskGroupsAvailable: workspaceStore.taskGroupsLoaded,
                                        presentNewSession: .constant(false),
                                        onSessionSelected: { presentSession($0) },
                                        onRequestNewSession: { cwd in
                                            beginCreation(context: SessionCreationContext(cwd: cwd, startsNewTask: false))
                                        }
                                    )
                                    .id(SidebarSection.sessions)
                                    .transition(reduceMotion ? .identity : .asymmetric(
                                        insertion: .opacity.animation(Theme.Motion.structure),
                                        removal: .opacity.animation(Theme.Motion.feedback)))
                                }
                            }
                            .wandMotion(value: sidebarRecent)
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
                }
                sidebarFooter
            }
        }
    }

    private var workspaceSidebar: some View {
        WorkspaceListView(
            store: workspaceStore,
            api: api,
            selectedTaskId: showTaskBoard ? nil : selectedWorkspaceTask?.task.id,
            selectedSessionId: selectedSessionId,
            query: sidebarQuery,
            recentOnly: sidebarRecent,
            activeOnly: sidebarActiveOnly,
            onOpenTask: { workspace, task in
                showCommunications = false
                showTaskBoard = false
                showCreation = false
                clearCompletionIntent()
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
                showCommunications = false
                showTaskBoard = false
                showCreation = false
                openCompletionIntent(session.id)
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
        VStack(spacing: 8) {
            if showCommunications {
                HStack {
                    Text(communicationsStore.section == .contacts ? "通讯录" : "对话")
                        .font(.system(size: 14, weight: .semibold)).foregroundColor(Theme.textPrimary)
                    Spacer()
                    commandSearchButton
                }.frame(height: 32)
            } else {
                HStack(spacing: 4) {
                    navigationRow(.newSession, active: showCreation && selectedWorkspaceTask == nil)
                    commandSearchButton
                }
                HStack(spacing: 4) {
                    ZStack(alignment: .leading) {
                        Text("执行会话").font(.system(size: 13, weight: .semibold))
                            .foregroundColor(Theme.textPrimary).opacity(sidebarSearchOpen ? 0 : 1)
                            .accessibilityHidden(sidebarSearchOpen)
                        TextField("搜索工作区、任务或会话", text: $sidebarQuery)
                            .textFieldStyle(.plain).focused($sidebarSearchFocused)
                            .font(.system(size: 12)).padding(.horizontal, 8).frame(height: 32)
                            .wandInputSurface(focused: sidebarSearchFocused, cornerRadius: Theme.Radius.control)
                            .opacity(sidebarSearchOpen ? 1 : 0).allowsHitTesting(sidebarSearchOpen)
                            .disabled(!sidebarSearchOpen)
                            .accessibilityHidden(!sidebarSearchOpen)
                            .onExitCommand { closeSidebarSearch() }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                        .sidebarPresence("sidebar-search-slot")
                    Button {
                        if sidebarSearchOpen { closeSidebarSearch() }
                        else { sidebarSearchOpen = true; sidebarSearchFocused = true }
                    } label: {
                        ZStack {
                            Image(systemName: "magnifyingglass").opacity(sidebarSearchOpen ? 0 : 1)
                                .rotationEffect(.degrees(reduceMotion || !sidebarSearchOpen ? 0 : -45))
                            Image(systemName: "arrow.uturn.backward").opacity(sidebarSearchOpen ? 1 : 0)
                                .rotationEffect(.degrees(reduceMotion || sidebarSearchOpen ? 0 : 45))
                        }.frame(width: 28, height: 28)
                    }.buttonStyle(WandIconButtonStyle())
                        .help(sidebarSearchOpen ? "收起搜索" : "搜索工作区、任务或会话")
                        .accessibilityLabel(sidebarSearchOpen ? "收起搜索" : "搜索工作区、任务或会话")
                        .sidebarPresence("sidebar-search-button")
                    Menu {
                        Button("刷新列表", systemImage: "arrow.clockwise") {
                            closeSidebarSearch()
                            Task { await workspaceStore.loadTaskGroups(force: true) }
                            NotificationCenter.default.post(name: .wandRefreshLists, object: nil)
                        }
                        Button("新建工作区", systemImage: "folder.badge.plus") { showCreateWorkspace = true }
                    } label: { Image(systemName: "ellipsis").frame(width: 24, height: 28) }
                        .menuStyle(.borderlessButton).fixedSize().help("列表选项").accessibilityLabel("列表选项")
                }.frame(height: 32).padding(.top, 4).wandMotion(value: sidebarSearchOpen)
                HStack(spacing: 6) {
                    Picker("会话组织方式", selection: $sidebarRecent) {
                        Text("按工作区").tag(false)
                        Text("最近会话").tag(true)
                    }.pickerStyle(.segmented).labelsHidden()
                    SidebarActivityFilter(active: sidebarActiveOnly) { sidebarActiveOnly.toggle() }
                }
            }
        }.padding(.horizontal, 12).padding(.top, 4).padding(.bottom, 10)
    }

    private func closeSidebarSearch() {
        sidebarQuery = ""
        sidebarSearchOpen = false
        sidebarSearchFocused = false
    }

    private var commandSearchButton: some View {
        Button { handle(.search) } label: {
            Image(systemName: DesktopCommand.search.symbol).frame(width: 28, height: 28)
        }.buttonStyle(WandIconButtonStyle())
            .help("搜索与命令 · ⇧⌘P").accessibilityLabel("搜索与命令")
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
            if showCommunications {
                Text(communicationsStore.section == .contacts ? "通讯录" : "对话")
                    .font(.system(size: 15, weight: .medium))
            } else if showCreation {
                SessionCreationToolbarTitle(draft: creationDraft)
            } else if showTaskBoard {
                Text("任务看板").font(.system(size: 15, weight: .medium))
            } else if selectedWorkspaceTask == nil, let session = selectedSession {
                BrandLogo(provider: selectedSessionProvider, color: Theme.textSecondary)
                    .frame(width: 16, height: 16)
                    .help(session.providerLabel)
                    .accessibilityLabel(session.providerLabel)
                Text(session.displayTitle).font(.system(size: 15, weight: .medium))
                    .lineLimit(1).help(session.displayTitle)
            } else {
                Text(selectedWorkspaceTask?.workspace.name ?? "Wand")
                    .font(.system(size: 15, weight: .medium)).foregroundColor(Theme.textSecondary).lineLimit(1)
            }
            WindowDragRegion().frame(minWidth: 12, maxWidth: .infinity).frame(height: 52)
            if !showCreation, !showTaskBoard, !showCommunications, selectedSessionId != nil || selectedWorkspaceTask != nil {
                filePanelToggleButton
            }
        }
        .padding(.leading, sidebarListVisible ? 20 : 40).padding(.trailing, 20).frame(height: 52)
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
        showCommandPalette || showTroubleshooting || showCreateWorkspace
    }

    /// 任意模态弹层（含子视图挂的快捷提交、文件预览、重命名等）都挡住完成确认：
    /// 用 keyWindow 的 sheetParent 全局判定，别只数根视图那几个。
    /// 与 DesktopCommands.send() 用同一个事实源。
    private var anyModalSheetPresented: Bool {
        hasPresentedSheet || NSApp.keyWindow?.sheetParent != nil
    }

    private var unavailableCommands: Set<DesktopCommand> {
        if settingsPresented { return [.toggleInspector, .findConversation, .focusComposer] }
        guard showCommunications else { return [] }
        if communicationsStore.section == .contacts || communicationsStore.selectedID == nil {
            return [.toggleInspector, .findConversation, .focusComposer]
        }
        return [.toggleInspector]
    }

    private func closeSettings() {
        guard settingsPresented else { return }
        NSApp.keyWindow?.makeFirstResponder(nil)
        settingsPresented = false
    }

    private func handle(_ command: DesktopCommand) {
        guard !anyModalSheetPresented, !unavailableCommands.contains(command) else { return }
        switch command {
        case .newSession, .newTask, .workspaces, .sessions, .taskBoard, .conversations, .contacts:
            closeSettings()
        default: break
        }
        switch command {
        case .newSession:
            beginCreation()
        case .newTask:
            beginNewTask(NewTaskSheetRequest(cwd: "", projectHint: nil))
        case .search: showCommandPalette = true
        case .toggleSidebar:
            if settingsPresented { closeSettings() }
            else { withAnimation(structuralAnimation) { sidebarVisible.toggle() } }
        case .toggleInspector: withAnimation(structuralAnimation) { filePanelOpen.toggle() }
        case .workspaces, .sessions:
            showCommunications = false
            sidebarVisible = true
            closeSidebarSearch()
            sidebarRecent = false
            sidebarActiveOnly = false
            sidebarScrollRequest = SidebarScrollRequest(
                section: command == .workspaces ? .workspaces : .sessions
            )
        case .taskBoard: showCommunications = false; showCreation = false; showTaskBoard = true; filePanelOpen = false
        case .conversations, .contacts:
            showCommunications = true; showCreation = false; showTaskBoard = false
            communicationsStore.section = command == .contacts ? .contacts : .conversations
            sidebarVisible = true
        case .settings:
            guard !settingsPresented else { return }
            sidebarSearchFocused = false
            NSApp.keyWindow?.makeFirstResponder(nil)
            settingsPresented = true
        case .reconnect: recoverConnection()
        case .focusComposer, .findConversation: break
        }
    }

    @ViewBuilder
    private var mainColumn: some View {
        if showCommunications {
            CommunicationsContent(store: communicationsStore, baseURL: serverURL, onOpenSession: openSessionFromMissions)
        } else if case .disconnected(let message, _) = connectionState, selectedSessionId == nil, selectedWorkspaceTask == nil {
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
                },
                onSnapshotViewed: completionSnapshotDisplayed
            )
            .id(selection.task.id)
        } else if let sessionId = selectedSessionId {
            MainColumn(
                api: api,
                sessionId: sessionId,
                provider: selectedSessionProvider,
                session: selectedSession,
                gitStatusStore: gitStatusStore,
                showsHeader: false,
                onSnapshotViewed: completionSnapshotDisplayed
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

struct MainColumn: View {
    let api: WandAPI
    let sessionId: String
    let provider: String
    let session: SessionSnapshot?
    @ObservedObject var gitStatusStore: GitStatusStore
    var showsHeader: Bool = true
    var onSnapshotViewed: ((SessionSnapshot) -> Void)? = nil

    var body: some View {
        if session?.isStructured == false {
            // PTY 使用 AppKit 终端直连 /ws；标题由原生主壳统一呈现。
            VStack(spacing: 0) {
                if showsHeader {
                    SessionHeaderView(
                        provider: provider,
                        title: session?.displayTitle,
                        workingDirectory: session?.cwd,
                        engine: session?.engine ?? session?.structuredState?.engine
                    )
                }
                PtySessionView(sessionId: sessionId, api: api, onViewed: {
                    if let session { onSnapshotViewed?(session) }
                })
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
                        workingDirectory: session?.cwd,
                        engine: session?.engine ?? session?.structuredState?.engine
                    )
                }
                // 必须按 sessionId 绑定身份:MainShellView 在 if let selectedSessionId 分支内
                // 复用 MainColumn 节点,只换参数。SwiftUI 默认保留子视图的 @StateObject,
                // 切换会话时 ChatStore 仍指向上一个会话(socket 不重连、快照不重拉),
                // 表现为「切了会话,内容不变」。.id(sessionId) 强制整个子树按新身份重建。
                ChatView(sessionId: sessionId, api: api, gitStatusStore: gitStatusStore,
                         onSnapshotViewed: onSnapshotViewed)
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
    var engine: String? = nil

    private var providerLabel: String {
        WandProvider.title(for: provider, engine: engine)
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

/// Page changes alter visibility, never the lifetime of the current chat, terminal or draft.
struct DesktopPageStack<Workspace: View, Settings: View>: View {
    let settingsPresented: Bool
    var workspaceWidth: CGFloat? = nil
    @ViewBuilder let workspace: () -> Workspace
    @ViewBuilder let settings: () -> Settings
    @State private var settingsVisited = false

    var body: some View {
        ZStack(alignment: .leading) {
            // Settings borrows the list's space, not the retained terminal's geometry.
            workspace().frame(width: workspaceWidth).desktopPage(active: !settingsPresented)
            if settingsVisited || settingsPresented {
                settings().desktopPage(active: settingsPresented)
            }
        }
        .onChange(of: settingsPresented) { if $0 { settingsVisited = true } }
        .onAppear { if settingsPresented { settingsVisited = true } }
    }
}

extension View {
    func desktopPage(active: Bool) -> some View {
        opacity(active ? 1 : 0)
            .allowsHitTesting(active)
            .accessibilityHidden(!active)
            .disabled(!active)
            .environment(\.desktopPageActive, active)
    }
}

/// The navigation rail stays reachable while settings borrows the list's space.
struct DesktopSidebarLayout<Rail: View, List: View>: View {
    let listVisible: Bool
    let onToggle: () -> Void
    @ViewBuilder let rail: () -> Rail
    @ViewBuilder let list: () -> List

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if listVisible {
                    WandBrandMark(size: 22)
                    Text("Wand").font(.system(size: 14, weight: .semibold)).foregroundColor(Theme.textPrimary)
                    WindowDragRegion().frame(maxWidth: .infinity)
                    Button(action: onToggle) {
                        Image(systemName: "sidebar.left").frame(width: 28, height: 28)
                    }.buttonStyle(WandIconButtonStyle()).help("隐藏列表 · ⌃⌘S")
                        .accessibilityLabel("隐藏列表")
                } else {
                    WindowDragRegion()
                }
            }
            .padding(.leading, listVisible ? 82 : 0).padding(.trailing, listVisible ? 12 : 0)
            .frame(height: 52).windowDrag().sidebarPresence("desktop-sidebar-header")
            HStack(spacing: 0) {
                rail().frame(width: Theme.LayoutMetrics.navigationRailWidth)
                list()
                    .frame(width: Theme.LayoutMetrics.sidebarWidth)
                    .desktopPage(active: listVisible)
                    .frame(width: listVisible ? Theme.LayoutMetrics.sidebarWidth : 0, alignment: .leading)
                    .clipped()
            }
            .frame(maxHeight: .infinity)
            .sidebarPresence("desktop-sidebar-body")
        }
        .frame(width: Theme.LayoutMetrics.navigationRailWidth + (listVisible ? Theme.LayoutMetrics.sidebarWidth : 0))
    }
}

struct DesktopNavigationRail: View {
    let selection: DesktopCommand
    let onCommand: (DesktopCommand) -> Void

    var body: some View {
        VStack(spacing: 4) {
            item(.conversations, title: "对话")
            item(.workspaces, title: "工作区")
            item(.taskBoard, title: "任务")
            item(.contacts, title: "通讯录")
            Spacer(minLength: 12)
            item(.settings, title: "设置")
        }
        .padding(.horizontal, 6).padding(.top, 4).padding(.bottom, 12)
        .sidebarPresence("desktop-navigation-rail")
    }

    private func item(_ command: DesktopCommand, title: String) -> some View {
        let active = selection == command
        return Button { onCommand(command) } label: {
            VStack(spacing: 4) {
                Image(systemName: command.symbol).font(.system(size: 17, weight: .medium))
                Text(title).font(.system(size: 10, weight: .medium))
            }
            .foregroundColor(active ? Theme.wandAccent : Theme.textSecondary)
            .frame(width: 44, height: 48).contentShape(Rectangle())
        }
        .buttonStyle(DesktopNavigationButtonStyle(active: active))
        .help(command.title + " · " + command.shortcutLabel)
        .accessibilityLabel(command.title)
        .accessibilityAddTraits(active ? .isSelected : [])
        .sidebarPresence("desktop-navigation-\(command.rawValue)")
    }
}

// MARK: - 布局尺寸

extension Theme {
    enum LayoutMetrics {
        static let navigationRailWidth: CGFloat = 56
        static let sidebarWidth: CGFloat = 260
        static let filePanelWidth: CGFloat = 320
    }
}
