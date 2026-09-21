import Combine
import SwiftUI

/**
 * 任务看板宿主：标题区、视图切换、项目 / 搜索 / 筛选 / 显示控制、结果摘要、错误与提示条，
 * 以及四个视图（概览 / 看板 / 列表 / 甘特图）与任务详情的路由。
 * 状态口径对齐 Web `task-board-host.tsx`：视图、筛选、显示设置都会持久化到本地。
 */
struct TaskBoardView: View {
    let api: WandAPI
    var linkedWorkspaceId: String? = nil
    let onOpenSession: (String) -> Void
    var onDismiss: (() -> Void)? = nil
    var embedded = false

    @Environment(\.dismiss) private var dismiss

    @State private var tasks: [WandBoardTask] = []
    @State private var workspaces: [Workspace] = []
    @State private var milestones: [WandBoardMilestone] = []
    @State private var catalog: ModelsResponse?
    @State private var loading = true
    @State private var refreshing = false
    @State private var errorMessage: String?
    @State private var notice: String?
    @State private var view: WandBoardView = .board
    @State private var query = ""
    @State private var workspaceFilter = ""
    @State private var filters = WandBoardFilters.empty
    @State private var display = WandBoardDisplay.default
    // 记「已收起」的状态：归档目录默认收起，其余默认展开。
    @State private var collapsedList: Set<String> = [WandBoardStatus.archived.rawValue]
    @State private var selectedId = ""
    @State private var showCreate = false
    @State private var createStatus = WandBoardStatus.todo.rawValue
    @State private var busyId = ""
    @State private var lastAgent = WandBoardTaskAgent.default
    @State private var ganttZoom: WandBoardGanttZoom = .week
    @State private var hideCompleted = false
    @State private var archiveConfirm: WandBoardTask?
    @State private var didLoad = false
    @FocusState private var searchFocused: Bool

    private let ticker = Timer.publish(every: 6, on: .main, in: .common).autoconnect()

    // MARK: - 派生值

    private var selectedTask: WandBoardTask? {
        selectedId.isEmpty ? nil : tasks.first { $0.id == selectedId }
    }

    private var visible: [WandBoardTask] {
        tasks.filter {
            wandBoardMatches(task: $0, query: query, workspaceId: workspaceFilter, filters: filters)
        }
    }

    private var grouped: [String: [WandBoardTask]] {
        wandBoardGroup(tasks: visible)
    }

    private var archiveOpen: Bool {
        if !collapsedList.contains(WandBoardStatus.archived.rawValue) { return true }
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        return filters.statuses.contains(WandBoardStatus.archived.rawValue)
    }

    private var filterActive: Bool { filters.isActive }

    private var filtered: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || filterActive || !workspaceFilter.isEmpty
    }

    private var projectName: String {
        guard !workspaceFilter.isEmpty else { return "所有项目" }
        return workspaces.first { $0.id == workspaceFilter }?.name ?? "项目"
    }

    private var availableLabels: [String] {
        wandBoardCollectLabels(tasks: tasks)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.border).frame(height: 0.5)
            if selectedTask == nil {
                toolbar
                resultSummary
            }
            if let errorMessage {
                banner(
                    text: errorMessage,
                    isError: true,
                    trailing: AnyView(
                        Button("重新加载") { Task { await reload(showProgress: true) } }
                            .buttonStyle(WandSecondaryButtonStyle())
                            .disabled(loading)
                    )
                )
            } else if let notice {
                banner(text: notice, isError: false)
            }
            content
        }
        .frame(minWidth: embedded ? 0 : 640, minHeight: embedded ? 0 : 520)
        .background(Theme.workspaceBackground)
        .sheet(isPresented: $showCreate) {
            WandBoardCreateView(
                workspaces: workspaces,
                milestones: milestones,
                catalog: catalog,
                defaultWorkspaceId: workspaceFilter.isEmpty ? (linkedWorkspaceId ?? "") : workspaceFilter,
                initialStatus: createStatus,
                lastAgent: lastAgent,
                onCreate: { draft in await createTask(draft) },
                onCreateMilestone: { name, workspaceId in
                    try await api.createBoardMilestone(name: name, workspaceId: workspaceId)
                }
            )
        }
        .alert(item: $archiveConfirm) { task in
            Alert(
                title: Text("归档「\(task.title)」？"),
                message: Text("任务会移入归档，并将关联的工作任务标为完成。会话记录会保留。"),
                primaryButton: .destructive(Text("归档任务")) {
                    Task { await archiveCard(task) }
                },
                secondaryButton: .cancel(Text("取消"))
            )
        }
        .onAppear { Task { await bootstrap() } }
        .onReceive(ticker) { _ in
            guard didLoad else { return }
            Task { await reload(showProgress: false, silent: true) }
        }
        .onChange(of: view) { _ in persist() }
        .onChange(of: query) { _ in persist() }
        .onChange(of: workspaceFilter) { _ in persist() }
        .onChange(of: filters) { _ in persist() }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 12) {
            if !embedded || selectedTask != nil {
                Button {
                    if selectedTask != nil {
                        selectedId = ""
                    } else {
                        close()
                    }
                } label: {
                    Label(
                        selectedTask == nil ? "关闭" : "返回",
                        systemImage: selectedTask == nil ? "xmark" : "chevron.left"
                    )
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 8)
                    .frame(height: 30)
                }
                .buttonStyle(DesktopNavigationButtonStyle())
                .help(selectedTask == nil ? "关闭任务看板" : "返回任务看板")
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(selectedTask?.identifier ?? "任务看板")
                    .font(.system(size: 20, weight: .semibold))
                    .monospacedDigit()
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                Text(selectedTask == nil ? "安排工作，跟进执行，确认结果。" : "查看进度与执行记录")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textSecondary)
            }
            Spacer(minLength: 12)
            if selectedTask == nil {
                Button {
                    Task { await reload(showProgress: true) }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.clockwise").font(.system(size: 11))
                        Text("刷新").font(.system(size: 12))
                    }
                }
                .buttonStyle(WandSecondaryButtonStyle())
                .disabled(loading)
                .help("刷新任务")
                .accessibilityLabel("刷新任务")
                Button {
                    openCreate(WandBoardStatus.todo.rawValue)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                        Text("新建任务").font(.system(size: 12))
                    }
                }
                .buttonStyle(WandPrimaryButtonStyle())
                .help("新建任务")
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                ForEach(WandBoardView.allCases) { entry in
                    Button(entry.label) { view = entry }
                        .buttonStyle(WandBoardSegmentButtonStyle(active: entry == view))
                        .help(entry.label)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textMuted)
                TextField("搜索任务", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($searchFocused)
                Button {
                    query = ""
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundColor(Theme.textMuted)
                .opacity(query.isEmpty ? 0 : 1)
                .disabled(query.isEmpty)
                .accessibilityHidden(query.isEmpty)
                .accessibilityLabel("清除任务搜索")
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .frame(width: 200)
            .wandInputSurface(focused: searchFocused, cornerRadius: Theme.Radius.control)

            Picker("", selection: $workspaceFilter) {
                Text("所有目录").tag("")
                ForEach(workspaces) { workspace in
                    Text(workspace.name).tag(workspace.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 170)

            if view != .dashboard {
                WandBoardFilterMenu(
                    filters: filters,
                    labels: availableLabels,
                    onChange: { filters = $0 }
                )
            }
            if view == .board {
                WandBoardDisplayMenu(display: display, onChange: { next in
                    display = next
                    wandBoardWriteDisplay(next)
                })
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 8)
    }

    private var resultSummary: some View {
        HStack(spacing: 8) {
            Text(loading ? "正在同步任务…" : "共 \(visible.count) 个任务\(filtered ? " · 已筛选" : "")")
                .font(.system(size: 11))
                .foregroundColor(filtered ? Theme.wandAccent : Theme.textMuted)
                .accessibilityLabel(loading ? "正在同步任务" : "共 \(visible.count) 个任务")
            if filtered {
                Button("清除筛选") {
                    query = ""
                    filters = .empty
                    workspaceFilter = ""
                    searchFocused = true
                }
                .buttonStyle(WandSecondaryButtonStyle())
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 8)
    }

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        if let task = selectedTask {
            WandBoardDetailView(
                task: task,
                workspaces: workspaces,
                milestones: milestones,
                catalog: catalog,
                busy: busyId == task.id,
                onPatch: { body in await patchTask(task, body) },
                onRemember: rememberAgent,
                onDispatch: { prompt, agent in await dispatch(task, agent: agent, prompt: prompt) },
                onArchive: { await removeTask(task) },
                onOpenSession: onOpenSession,
                onCreateMilestone: { name in
                    try await api.createBoardMilestone(name: name, workspaceId: task.workspaceId)
                }
            )
            .id(task.id)
        } else if loading && tasks.isEmpty {
            VStack(spacing: 12) {
                ProgressView().tint(Theme.wandAccent)
                Text("正在加载任务…")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !loading && visible.isEmpty && filtered {
            VStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 26))
                    .foregroundColor(Theme.textMuted)
                Text("没有找到匹配的任务")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                Text("试试其他关键词，或清除筛选查看全部任务。")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textSecondary)
                Button("查看全部任务") {
                    query = ""
                    filters = .empty
                    workspaceFilter = ""
                }
                .buttonStyle(WandSecondaryButtonStyle())
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            switch view {
            case .dashboard:
                WandBoardDashboardView(
                    projectName: projectName,
                    tasks: visible,
                    onOpenTask: { selectedId = $0 },
                    onOpenSession: onOpenSession
                )
            case .board:
                WandBoardBoardView(
                    grouped: grouped,
                    display: display,
                    loading: loading,
                    busyId: busyId,
                    archiveOpen: archiveOpen,
                    onToggleArchive: { toggleArchive() },
                    onCreateInColumn: { openCreate($0) },
                    onOpenTask: { selectedId = $0 },
                    onOpenSession: onOpenSession,
                    onCompleteTask: { task in Task { await completeTask(task) } },
                    onPatchStatus: { task, status in
                        Task { await patchTask(task, ["status": status]) }
                    },
                    onDispatchTask: { task in
                        let agent = task.agent ?? lastAgent
                        let prompt = wandBoardDropDispatchPrompt(
                            title: task.title,
                            description: task.description
                        )
                        Task { await dispatch(task, agent: agent, prompt: prompt) }
                    },
                    onArchiveTask: { archiveConfirm = $0 },
                    onRestoreTask: { task in
                        Task { await patchTask(task, ["status": WandBoardStatus.todo.rawValue]) }
                    },
                    onCopyIdentifier: { copyIdentifier($0) },
                    onMoveSession: { task, sessionId in
                        Task { await moveSession(to: task, sessionId: sessionId) }
                    },
                    onUnbindSession: { task, sessionId in
                        Task { await unbindSession(from: task, sessionId: sessionId) }
                    },
                    onDropTask: { status, id in
                        Task { await dropTask(status: status, taskId: id) }
                    }
                )
            case .list:
                WandBoardListView(
                    grouped: grouped,
                    collapsed: collapsedList,
                    archiveOpen: archiveOpen,
                    onToggle: { status in
                        if collapsedList.contains(status) {
                            collapsedList.remove(status)
                        } else {
                            collapsedList.insert(status)
                        }
                    },
                    onToggleArchive: { toggleArchive() },
                    onOpenTask: { selectedId = $0 },
                    onOpenSession: onOpenSession
                )
            case .gantt:
                WandBoardGanttView(
                    grouped: grouped,
                    zoom: ganttZoom,
                    hideCompleted: hideCompleted,
                    onZoom: { ganttZoom = $0 },
                    onHideCompleted: { hideCompleted = $0 },
                    onOpenTask: { selectedId = $0 }
                )
            }
        }
    }

    private func banner(text: String, isError: Bool, trailing: AnyView? = nil) -> some View {
        HStack(spacing: 8) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundColor(isError ? Theme.danger : Theme.success)
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(2)
            Spacer(minLength: 8)
            if let trailing { trailing }
            Button {
                if isError { errorMessage = nil } else { notice = nil }
            } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundColor(Theme.textMuted)
            .accessibilityLabel("关闭提示")
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 30)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(isError ? Theme.danger.opacity(0.08) : Theme.success.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .strokeBorder(isError ? Theme.danger.opacity(0.3) : Theme.success.opacity(0.25), lineWidth: 1)
        )
        .padding(.horizontal, 24)
        .padding(.bottom, 8)
        .accessibilityAddTraits(.isStaticText)
    }

    // MARK: - 加载与刷新

    private func bootstrap() async {
        // 沿用上次的视图 / 搜索 / 筛选；显式链接进来的工作区优先于历史记录。
        let state = wandBoardReadViewState()
        view = state.view
        query = state.query
        filters = state.filters
        workspaceFilter = state.workspaceId.isEmpty ? (linkedWorkspaceId ?? "") : state.workspaceId
        display = wandBoardReadDisplay()
        await reload(showProgress: true)
        didLoad = true
        await loadSupporting()
    }

    private func loadSupporting() async {
        workspaces = (try? await api.listWorkspaces()) ?? workspaces
        catalog = try? await api.models()
        milestones = (try? await api.listBoardMilestones()) ?? milestones
        if let agent = try? await api.boardTaskAgentDefaults() {
            lastAgent = agent
        }
    }

    private func reload(showProgress: Bool, silent: Bool = false) async {
        if refreshing { return }
        refreshing = true
        if showProgress { loading = true }
        do {
            tasks = try await api.listBoardTasks()
            errorMessage = nil
        } catch {
            // 静默轮询失败保留上一份列表，只把错误提示留给手动刷新。
            if !silent { errorMessage = error.localizedDescription }
        }
        loading = false
        refreshing = false
        if selectedTask == nil && !selectedId.isEmpty { selectedId = "" }
    }

    private func persist() {
        wandBoardWriteViewState(
            WandBoardViewState(view: view, query: query, workspaceId: workspaceFilter, filters: filters)
        )
    }

    private func close() {
        if let onDismiss { onDismiss() } else { dismiss() }
    }

    private func openCreate(_ status: String) {
        createStatus = status
        showCreate = true
        Task {
            workspaces = (try? await api.listWorkspaces()) ?? workspaces
            milestones = (try? await api.listBoardMilestones()) ?? milestones
            catalog = try? await api.models()
        }
    }

    private func toggleArchive() {
        if collapsedList.contains(WandBoardStatus.archived.rawValue) {
            collapsedList.remove(WandBoardStatus.archived.rawValue)
        } else {
            collapsedList.insert(WandBoardStatus.archived.rawValue)
        }
    }

    // MARK: - 写操作

    /// 串行化写操作：同一时刻只允许一个任务在写，避免连点造成状态错乱。
    private func runFor(_ id: String, _ work: () async throws -> Void) async {
        guard busyId.isEmpty else { return }
        busyId = id
        errorMessage = nil
        do {
            try await work()
        } catch {
            errorMessage = error.localizedDescription
        }
        busyId = ""
    }

    private func createTask(_ draft: WandBoardDraft) async -> Bool {
        var created: WandBoardTask?
        await runFor("__create__") {
            let task = try await api.createBoardTask(
                title: draft.title.trimmingCharacters(in: .whitespacesAndNewlines),
                description: draft.description.trimmingCharacters(in: .whitespacesAndNewlines),
                status: draft.status,
                priority: draft.priority,
                labels: draft.parsedLabels,
                dueDate: draft.dueDate.isEmpty ? nil : draft.dueDate,
                milestoneId: draft.milestoneId.isEmpty ? nil : draft.milestoneId,
                workspaceId: draft.workspaceId.isEmpty ? nil : draft.workspaceId,
                agent: draft.agent
            )
            created = task
            rememberAgent(draft.agent)
            await reload(showProgress: false)
            // 只有「处理中」列 + 有描述才顺带第一次指派；失败只提示，不回滚已创建的任务。
            let prompt = draft.description.trimmingCharacters(in: .whitespacesAndNewlines)
            if wandBoardCreateDispatches(status: draft.status) && !prompt.isEmpty {
                do {
                    let result = try await api.dispatchBoardTask(
                        id: task.id,
                        agent: draft.agent,
                        prompt: prompt,
                        workspaceId: draft.workspaceId.isEmpty ? nil : draft.workspaceId
                    )
                    showNotice("\(wandBoardProviderLabel(result.provider)) 已开始处理「\(task.title)」")
                } catch {
                    errorMessage = error.localizedDescription
                }
                await reload(showProgress: false)
            } else {
                showNotice("已创建任务「\(task.title)」，可在详情中启动执行。")
            }
            // 标题留空时由服务端后台生成，轮询几次把真标题取回来。
            if draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, task.titleSource == "auto" {
                await awaitGeneratedTitle(taskId: task.id, placeholder: task.title)
            }
        }
        return created != nil
    }

    private func patchTask(_ task: WandBoardTask, _ body: [String: Any]) async {
        await runFor(task.id) {
            _ = try await api.updateBoardTask(id: task.id, body: body)
            if let status = body["status"] as? String, status == WandBoardStatus.archived.rawValue {
                collapsedList.remove(WandBoardStatus.archived.rawValue)
                showNotice("已归档「\(task.title)」，拖回任意列或右键「恢复到等待认领」即可恢复。")
            }
            await reload(showProgress: false)
        }
    }

    private func completeTask(_ task: WandBoardTask) async {
        await runFor(task.id) {
            _ = try await api.updateBoardTask(id: task.id, body: ["status": WandBoardStatus.done.rawValue])
            showNotice("「\(task.title)」已移入「等你确认」。")
            await reload(showProgress: false)
        }
    }

    private func dispatch(_ task: WandBoardTask, agent: WandBoardTaskAgent, prompt: String) async {
        rememberAgent(agent)
        await runFor(task.id) {
            // 派发接口自己会把 agent 写回任务（并把「等待认领」推到「处理中」），不用先 PATCH。
            let result = try await api.dispatchBoardTask(
                id: task.id,
                agent: agent,
                prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
                workspaceId: task.workspaceId
            )
            showNotice("\(wandBoardProviderLabel(result.provider)) 已开始处理「\(task.title)」")
            await reload(showProgress: false)
        }
    }

    private func removeTask(_ task: WandBoardTask) async {
        await runFor(task.id) {
            try await api.deleteBoardTask(id: task.id)
            showNotice("已归档「\(task.title)」，会话记录已保留。")
            if selectedId == task.id { selectedId = "" }
            await reload(showProgress: false)
        }
    }

    private func archiveCard(_ task: WandBoardTask) async {
        guard task.status != WandBoardStatus.archived.rawValue else { return }
        await runFor(task.id) {
            _ = try await api.updateBoardTask(id: task.id, body: ["status": WandBoardStatus.archived.rawValue])
            // 归档目录默认折叠，不展开的话卡片只是从看板上消失，用户看不出落在哪里。
            collapsedList.remove(WandBoardStatus.archived.rawValue)
            showNotice("已归档「\(task.title)」，拖回任意列或右键「恢复到等待认领」即可恢复。")
            await reload(showProgress: false)
        }
    }

    /// 拖拽换列：换到「处理中」且这条任务还没派发过时，顺手把首次指派发出去。
    private func dropTask(status: String, taskId: String) async {
        guard let moving = tasks.first(where: { $0.id == taskId }), moving.status != status else { return }
        let dispatches = wandBoardDropDispatches(status: status, sessionCount: moving.sessions.count)
        var dispatchError = ""
        await runFor(taskId) {
            _ = try await api.updateBoardTask(id: taskId, body: ["status": status])
            if dispatches {
                let agent = moving.agent ?? lastAgent
                rememberAgent(agent)
                do {
                    let result = try await api.dispatchBoardTask(
                        id: taskId,
                        agent: agent,
                        prompt: wandBoardDropDispatchPrompt(title: moving.title, description: moving.description),
                        workspaceId: moving.workspaceId
                    )
                    showNotice("\(wandBoardProviderLabel(result.provider)) 已开始处理「\(moving.title)」")
                } catch {
                    // 状态已经改好，派发失败只提示、不回滚：用户可进详情改参数后重试。
                    dispatchError = error.localizedDescription
                }
            }
            if status == WandBoardStatus.archived.rawValue {
                collapsedList.remove(WandBoardStatus.archived.rawValue)
                showNotice("已归档「\(moving.title)」，拖回任意列或右键「恢复到等待认领」即可恢复。")
            }
            await reload(showProgress: false)
            // reload() 会清错误横幅，所以派发失败的提示必须放在它之后才留得住。
            if !dispatchError.isEmpty { errorMessage = dispatchError }
        }
    }

    private func moveSession(to task: WandBoardTask, sessionId: String) async {
        guard !sessionId.isEmpty, !task.sessions.contains(where: { $0.id == sessionId }) else { return }
        await runFor(task.id) {
            try await api.linkBoardTaskSession(taskId: task.id, sessionId: sessionId)
            showNotice("已移入「\(task.title)」，运行目录不变。")
            await reload(showProgress: false)
        }
    }

    private func unbindSession(from task: WandBoardTask, sessionId: String) async {
        await runFor(task.id) {
            try await api.unlinkBoardTaskSession(taskId: task.id, sessionId: sessionId)
            showNotice("已把会话移出「\(task.title)」，会话本身未删除。")
            await reload(showProgress: false)
        }
    }

    private func copyIdentifier(_ task: WandBoardTask) {
        let value = task.identifier.isEmpty ? task.id : task.identifier
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        showNotice("已复制 \(value)")
    }

    private func rememberAgent(_ agent: WandBoardTaskAgent) {
        lastAgent = agent
        Task { _ = try? await api.saveBoardTaskAgentDefaults(agent) }
    }

    private func showNotice(_ text: String) {
        notice = text
        Task {
            // 与 Web 一样是「看一眼就散」的提示条：6 秒后自动消失。
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            if notice == text { notice = nil }
        }
    }

    /**
     * 标题留空时标题由服务端后台生成。创建响应里只有描述首行占位，
     * 这里短轮询几次，拿到真标题就刷新列表；一直没变就保留占位。
     */
    private func awaitGeneratedTitle(taskId: String, placeholder: String) async {
        for delayMs in [1_200, 2_000, 3_000, 5_000, 8_000] {
            // 部署目标是 macOS 12，不能用只在新系统可用的 Task.sleep(for:)。
            try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
            guard let task = try? await api.getBoardTask(id: taskId) else { continue }
            guard !task.title.isEmpty, task.title != placeholder else { continue }
            await reload(showProgress: false)
            return
        }
    }
}

// MARK: - 筛选菜单

/// 状态 / 优先级 / 标签三组筛选；触发器上带命中数量。
struct WandBoardFilterMenu: View {
    let filters: WandBoardFilters
    let labels: [String]
    let onChange: (WandBoardFilters) -> Void

    @State private var open = false

    var body: some View {
        Button {
            open = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "line.3.horizontal.decrease").font(.system(size: 11))
                Text("筛选").font(.system(size: 12))
                if filters.count > 0 { WandBoardMiniTag("\(filters.count)") }
            }
            .foregroundColor(filters.isActive ? Theme.wandAccent : Theme.textSecondary)
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(filters.isActive ? Color(nsColor: Theme.wandAccentMuted) : Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .strokeBorder(filters.isActive ? Theme.wandAccent.opacity(0.4) : Theme.border, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("筛选任务")
        .accessibilityLabel("筛选任务")
        .popover(isPresented: $open, arrowEdge: .bottom) { menu }
    }

    private var menu: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("筛选")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                Spacer(minLength: 0)
                if filters.isActive {
                    Button("清空") { onChange(.empty) }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textSecondary)
                }
            }
            group("状态") {
                ForEach(WandBoardStatus.allCases) { status in
                    chip(status.label, selected: filters.statuses.contains(status.rawValue)) {
                        var next = filters
                        next.statuses = toggled(next.statuses, status.rawValue)
                        onChange(next)
                    }
                }
            }
            group("优先级") {
                ForEach(WandBoardPriority.allCases) { priority in
                    chip(priority.label, selected: filters.priorities.contains(priority.rawValue)) {
                        var next = filters
                        next.priorities = toggled(next.priorities, priority.rawValue)
                        onChange(next)
                    }
                }
            }
            if !labels.isEmpty {
                group("标签") {
                    ForEach(labels, id: \.self) { label in
                        chip(wandBoardLabelName(label), selected: filters.labels.contains(label)) {
                            var next = filters
                            next.labels = toggled(next.labels, label)
                            onChange(next)
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 280)
        .background(Theme.surfaceElevated)
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11))
                .foregroundColor(Theme.textMuted)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 64), spacing: 6, alignment: .leading)],
                alignment: .leading,
                spacing: 6
            ) { content() }
        }
    }

    private func chip(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(selected ? Theme.wandAccent : Theme.textSecondary)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(Capsule().fill(selected ? Color(nsColor: Theme.wandAccentMuted) : Theme.surface))
                .overlay(Capsule().strokeBorder(selected ? Theme.wandAccent.opacity(0.4) : Theme.border, lineWidth: 0.5))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label)\(selected ? "，已选中" : "")")
    }

    private func toggled(_ set: Set<String>, _ value: String) -> Set<String> {
        var next = set
        if next.contains(value) { next.remove(value) } else { next.insert(value) }
        return next
    }
}

// MARK: - 显示菜单

/// 卡片正文与「主列」划分；非主列的状态会落到看板右侧的「其他任务」里。
struct WandBoardDisplayMenu: View {
    let display: WandBoardDisplay
    let onChange: (WandBoardDisplay) -> Void

    @State private var open = false

    var body: some View {
        Button {
            open = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "slider.horizontal.3").font(.system(size: 11))
                Text("显示").font(.system(size: 12))
            }
            .foregroundColor(Theme.textSecondary)
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .strokeBorder(Theme.border, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("显示设置")
        .accessibilityLabel("显示设置")
        .popover(isPresented: $open, arrowEdge: .bottom) { menu }
    }

    private var menu: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("显示")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
            Toggle("显示任务正文", isOn: Binding(
                get: { display.body },
                set: { var next = display; next.body = $0; onChange(next) }
            ))
            .toggleStyle(.checkbox)
            .font(.system(size: 12))
            .foregroundColor(Theme.textSecondary)

            VStack(alignment: .leading, spacing: 6) {
                Text("主列")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textMuted)
                ForEach(WandBoardStatus.columns) { status in
                    Toggle(status.label, isOn: Binding(
                        get: { display.mainStatuses.contains(status.rawValue) },
                        set: { on in
                            var next = display
                            if on {
                                next.mainStatuses.insert(status.rawValue)
                            } else {
                                // 至少保留一列，否则看板会变空。
                                let rest = next.mainStatuses.subtracting([status.rawValue])
                                guard !rest.isEmpty else { return }
                                next.mainStatuses = rest
                            }
                            onChange(next)
                        }
                    ))
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textSecondary)
                    .disabled(display.mainStatuses.count == 1 && display.mainStatuses.contains(status.rawValue))
                }
            }
            Divider().overlay(Theme.border)
            Button("恢复默认") {
                onChange(.default)
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundColor(Theme.wandAccent)
        }
        .padding(12)
        .frame(width: 220)
        .background(Theme.surfaceElevated)
    }
}
