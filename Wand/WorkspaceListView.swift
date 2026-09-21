import SwiftUI

struct WorkspaceTaskSelection: Equatable {
    let workspace: Workspace
    let task: WorkspaceTask
}

/// 新建任务 sheet 载荷：目录预填（项目组「＋」时为项目 cwd；全局入口为空）。
struct NewTaskSheetRequest: Identifiable, Equatable {
    let id = UUID()
    let cwd: String
    let projectHint: String?
    var workspaceId: String? = nil
}

/// 共享滚动侧栏的工作空间分区：项目、任务及任务内会话。
struct WorkspaceListView: View {
    @ObservedObject var store: WorkspaceStore
    let api: WandAPI
    let selectedTaskId: String?
    var selectedSessionId: String? = nil
    let query: String
    let onOpenTask: (Workspace, WorkspaceTask) -> Void
    var onTaskRenamed: ((WorkspaceTask) -> Void)? = nil
    var onTaskDeleted: ((String) -> Void)? = nil
    var onOpenSession: ((Workspace, WorkspaceSessionSummary) -> Void)? = nil
    var onOpenTaskSession: ((Workspace, WorkspaceTask, WorkspaceSessionSummary) -> Void)? = nil
    var onRequestNewSession: ((Workspace, WorkspaceTask) -> Void)? = nil
    var onRequestNewTask: ((NewTaskSheetRequest) -> Void)? = nil
    var onMergeAgentStarted: ((Workspace, SessionSnapshot) -> Void)? = nil
    var onWorkspaceDeleted: ((String) -> Void)? = nil
    var onCreateWorkspace: (() -> Void)? = nil

    @State private var renameTarget: WorkspaceTask?
    @State private var renameDraft = ""
    @State private var renameError: String?
    @State private var renameBusy = false
    @FocusState private var renameFocused: Bool
    @State private var deleteTarget: WorkspaceTask?
    @State private var deleteBusy = false
    @State private var deleteError: String?
    @State private var expandedTaskGroups = Set<String>()
    @State private var pendingSelectionReveal = false
    @State private var collapsedTaskIds = Set<String>()
    @State private var clearTarget: WorkspaceTaskSummary?
    @State private var clearBusy = false
    @State private var deleteSessionTarget: WorkspaceSessionSummary?
    @State private var deleteSessionBusy = false
    @State private var toastMessage: String?
    @State private var newTaskRequest: NewTaskSheetRequest?
    @State private var isSelecting = false
    @State private var selectedTaskIds = Set<String>()
    @State private var selectedSessionIds = Set<String>()
    @State private var pendingManagedDelete: TaskListPresentation.ManageSelection?

    var body: some View {
        ZStack {
            VStack(spacing: 2) {
                sectionHeader
                stateContent
            }
            if let toastMessage {
                VStack {
                    Text(toastMessage)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Theme.textPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .wandGlassCard(cornerRadius: Theme.Radius.md)
                        .padding(.top, 8)
                    Spacer()
                }
                .allowsHitTesting(false)
            }
        }
        .task {
            async let taskGroupsLoad: Void = store.loadTaskGroups()
            if case .idle = store.indexState {
                await store.loadWorkspaceIndex()
            }
            await taskGroupsLoad
        }
        .onChange(of: manageableSelection) { available in
            selectedTaskIds.formIntersection(available.taskIds)
            selectedSessionIds.formIntersection(available.sessionIds)
        }
        .onChange(of: query) { _ in
            selectedTaskIds.removeAll()
            selectedSessionIds.removeAll()
        }
        .wandMotion(value: expandedTaskGroups, layout: true)
        .wandMotion(value: collapsedTaskIds, layout: true)
        .wandMotion(value: isSelecting, layout: true)
        .onAppear { revealSelection() }
        .onChange(of: selectedTaskId) { _ in revealSelection() }
        .onChange(of: selectedSessionId) { _ in revealSelection() }
        .onChange(of: store.taskGroups) { _ in
            if pendingSelectionReveal { revealSelection() }
        }
        .sheet(item: $newTaskRequest) { request in
            newTaskSheet(request)
        }
        .sheet(item: renameTaskSheetItem) { task in
            renameSheet(
                title: "重命名任务",
                draft: $renameDraft,
                error: renameError,
                busy: renameBusy,
                onCancel: { renameTarget = nil },
                onSave: { Task { await saveTaskRename(task) } }
            )
        }
        .confirmationDialog(
            "删除此任务？",
            isPresented: deleteConfirmationPresented,
            titleVisibility: .visible
        ) {
            if let target = deleteTarget {
                Button("删除任务", role: .destructive) {
                    Task { await confirmDeleteTask(target) }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            if let target = deleteTarget {
                Text("任务「\(target.name)」及其会话和独立 worktree 将被删除，此操作无法撤销。")
            }
        }
        .alert("操作未完成", isPresented: deletionErrorPresented) {
            Button("好", role: .cancel) {
                deleteError = nil
            }
        } message: {
            Text(deleteError ?? "")
        }
        .confirmationDialog(
            "清空全部终端？",
            isPresented: Binding(
                get: { clearTarget != nil },
                set: { if !$0 { clearTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(clearBusy ? "清空中…" : "确认清空", role: .destructive) {
                Task { await confirmClearSessions() }
            }
            Button("取消", role: .cancel) { clearTarget = nil }
        } message: {
            if let target = clearTarget {
                Text("将结束并删除「\(target.name)」的 \(target.listedSessionCount) 个终端，此操作无法撤销。")
            }
        }
        .confirmationDialog(
            "删除终端？",
            isPresented: Binding(
                get: { deleteSessionTarget != nil },
                set: { if !$0 && !deleteSessionBusy { deleteSessionTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(deleteSessionBusy ? "删除中…" : "删除终端", role: .destructive) {
                Task { await confirmDeleteSession() }
            }
            .disabled(deleteSessionBusy)
            Button("取消", role: .cancel) { deleteSessionTarget = nil }
        } message: {
            if let target = deleteSessionTarget {
                Text("终端「\(sessionDeleteLabel(target))」会结束并被删除，此操作无法撤销。")
            }
        }
        .confirmationDialog(
            "删除所选项目？",
            isPresented: Binding(
                get: { pendingManagedDelete != nil },
                set: { if !$0 { pendingManagedDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                Task { await confirmManagedDelete() }
            }
            Button("取消", role: .cancel) { pendingManagedDelete = nil }
        } message: {
            if let selection = pendingManagedDelete {
                Text("将删除\(TaskListPresentation.describeManagedDeletion(selection))，此操作无法撤销。")
            }
        }
    }

    private var sectionHeader: some View {
        HStack(spacing: 4) {
            Text("工作空间")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Theme.textTertiary)
            Spacer(minLength: 0)
            if !manageableSelection.isEmpty && !isSelecting {
                Button {
                    isSelecting = true
                    selectedTaskIds.removeAll()
                    selectedSessionIds.removeAll()
                } label: {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textSecondary)
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(WandIconButtonStyle())
                .help("多选任务和终端")
                .accessibilityLabel("多选任务和终端")
            }
            Button {
                requestNewTask(NewTaskSheetRequest(cwd: "", projectHint: nil))
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(WandIconButtonStyle())
            .help("新建任务")
            .accessibilityLabel("新建任务")
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(height: 34)
    }

    @ViewBuilder
    private var stateContent: some View {
        if !store.taskGroupsLoaded && store.taskGroups.isEmpty {
            if let error = store.taskGroupsError {
                errorState(error)
            } else {
                loadingState
            }
        } else {
            taskGroupsContent
        }
    }

    private var isFiltering: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var visibleTaskGroups: [TaskDirectoryGroup] {
        var groups = store.taskGroups.compactMap { group -> TaskDirectoryGroup? in
            guard !group.isSynthetic || !group.tasks.isEmpty else { return nil }
            return TaskDirectoryGroup(
                workspaceId: group.workspaceId, workspaceName: group.workspaceName,
                workspaceCwd: group.workspaceCwd, synthetic: group.synthetic,
                tasks: group.tasks, standaloneSessions: []
            )
        }
        let groupedWorkspaceIds = Set(groups.map(\.workspaceId))
        groups += store.workspaces.filter { !groupedWorkspaceIds.contains($0.id) }.map {
            TaskDirectoryGroup(
                workspaceId: $0.id, workspaceName: $0.name, workspaceCwd: $0.cwd,
                synthetic: false, tasks: [], standaloneSessions: []
            )
        }
        let filtered = TaskListPresentation.filteredDirectoryGroups(groups, query: query)
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return groups.compactMap { group in
            if group.tasks.isEmpty && !group.isSynthetic {
                return needle.isEmpty
                    || group.workspaceName.localizedCaseInsensitiveContains(needle)
                    || group.workspaceCwd.localizedCaseInsensitiveContains(needle) ? group : nil
            }
            return filtered.first { $0.id == group.id }
        }
    }

    private var manageableSelection: TaskListPresentation.ManageSelection {
        var selection = TaskListPresentation.ManageSelection()
        let groups = visibleTaskGroups
        for group in groups where TaskListPresentation.isDirectoryExpanded(
            userCollapsed: !expandedTaskGroups.contains(group.id),
            directoryCount: groups.count,
            isSearching: isFiltering
        ) {
            for task in group.tasks {
                selection.taskIds.insert(task.id)
                if TaskListPresentation.isTaskSessionsExpanded(
                    userCollapsed: collapsedTaskIds.contains(task.id),
                    sessionCount: task.listedSessionCount,
                    isSearching: isFiltering
                ) {
                    selection.sessionIds.formUnion(task.sessions.map(\.id))
                }
            }
        }
        return selection
    }

    private var taskGroupsContent: some View {
        let visible = visibleTaskGroups
        return VStack(spacing: 2) {
            if isSelecting { manageBar(groups: visible) }
            if let error = store.taskGroupsError {
                errorState(error)
            }
            if visible.isEmpty {
                Text(isFiltering ? "没有匹配的工作空间或任务" : "还没有工作空间任务")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textSecondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(visible) { group in
                    taskGroupBlock(group, directoryCount: visible.count)
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 8)
    }

    private func taskGroupBlock(_ group: TaskDirectoryGroup, directoryCount: Int) -> some View {
        let expanded = TaskListPresentation.isDirectoryExpanded(
            userCollapsed: !expandedTaskGroups.contains(group.id),
            directoryCount: directoryCount,
            isSearching: isFiltering
        )
        let collapsible = !isFiltering && TaskListPresentation.showsDirectoryDisclosure(directoryCount: directoryCount)
        return VStack(spacing: 2) {
            taskGroupHeader(group, expanded: expanded, collapsible: collapsible)
            if expanded {
                ForEach(group.tasks) { summary in
                    taskSummaryRow(summary, group: group)
                }
                if group.tasks.isEmpty {
                    Text("这个目录还没有任务。")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textMuted)
                        .padding(.leading, 12)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func taskGroupHeader(_ group: TaskDirectoryGroup, expanded: Bool, collapsible: Bool) -> some View {
        let sessionTotal = group.tasks.reduce(0) { $0 + $1.listedSessionCount }
        return HStack(spacing: 6) {
            Button {
                guard collapsible else { return }
                toggleCollapsedTaskGroup(group.id)
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: group.isSynthetic ? "folder.badge.questionmark" : "folder.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.textSecondary)
                        .frame(width: 20, height: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 5) {
                            Text(group.workspaceName)
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundColor(Theme.textPrimary)
                                .lineLimit(1)
                            if group.isSynthetic {
                                Text("未归档")
                                    .font(.system(size: 9))
                                    .foregroundColor(Theme.textMuted)
                            }
                        }
                        if let caption = TaskListPresentation.directoryPathCaption(name: group.workspaceName, cwd: group.workspaceCwd) {
                            Text(caption)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(Theme.textMuted)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    if collapsible {
                        treeDisclosureCaret(expanded: expanded)
                    }
                    Text("\(group.tasks.count)/\(sessionTotal)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(Theme.textMuted)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(DesktopNavigationButtonStyle())

            Button {
                requestNewTask(NewTaskSheetRequest(
                    cwd: group.workspaceCwd,
                    projectHint: group.workspaceName,
                    workspaceId: group.synthetic == true ? nil : group.workspaceId
                ))
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(WandIconButtonStyle())
            .help("在此目录新建任务")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private func treeDisclosureCaret(expanded: Bool) -> some View {
        Image(systemName: "chevron.down")
            .font(.system(size: 8, weight: .semibold))
            .foregroundColor(Theme.textMuted)
            .rotationEffect(.degrees(expanded ? 0 : -90))
            .frame(width: 12, height: 14)
    }

    private func toggleCollapsedTaskGroup(_ id: String) {
        if expandedTaskGroups.contains(id) {
            expandedTaskGroups.remove(id)
        } else {
            expandedTaskGroups.insert(id)
        }
    }

    private func revealSelection() {
        guard selectedTaskId != nil || selectedSessionId != nil else {
            pendingSelectionReveal = false
            return
        }
        for group in store.taskGroups {
            let task = group.tasks.first { task in
                if let selectedTaskId { return task.id == selectedTaskId }
                return task.sessions.contains { $0.id == selectedSessionId }
            }
            if let task {
                expandedTaskGroups.insert(group.id)
                collapsedTaskIds.remove(task.id)
                pendingSelectionReveal = false
                return
            }
        }
        pendingSelectionReveal = true
    }

    private func toggleCollapsedTask(_ id: String) {
        if collapsedTaskIds.contains(id) {
            collapsedTaskIds.remove(id)
        } else {
            collapsedTaskIds.insert(id)
        }
    }

    private func taskSummaryRow(_ summary: WorkspaceTaskSummary, group: TaskDirectoryGroup) -> some View {
        let selected = selectedTaskId == summary.id
        let canCollapseSessions = TaskListPresentation.showsTaskSessionDisclosure(sessionCount: summary.listedSessionCount)
        let expanded = TaskListPresentation.isTaskSessionsExpanded(
            userCollapsed: collapsedTaskIds.contains(summary.id),
            sessionCount: summary.listedSessionCount,
            isSearching: isFiltering
        )
        let workspace = workspace(from: group)
        let task = summary.asTask()
        return VStack(spacing: 1) {
            HStack(spacing: 4) {
                Button {
                    if isSelecting {
                        if selectedTaskIds.contains(summary.id) {
                            selectedTaskIds.remove(summary.id)
                        } else {
                            selectedTaskIds.insert(summary.id)
                        }
                        return
                    }
                    collapsedTaskIds.remove(summary.id)
                    onOpenTask(workspace, task)
                } label: {
                    HStack(spacing: 6) {
                        if isSelecting {
                            Image(systemName: selectedTaskIds.contains(summary.id) ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(selectedTaskIds.contains(summary.id) ? Theme.brand : Theme.textMuted)
                                .frame(width: 14, height: 14)
                        } else if summary.isIsolated || summary.status == "done" {
                            Image(systemName: summary.status == "done" ? "checkmark.circle.fill" : "arrow.triangle.branch")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(summary.status == "done" ? Theme.success : Theme.textMuted)
                                .frame(width: 14, height: 14)
                        }
                        Text(summary.name)
                            .font(.system(size: 12.5, weight: selected ? .semibold : .medium))
                            .foregroundColor(Theme.textPrimary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(DesktopNavigationButtonStyle())

                if canCollapseSessions {
                    Button {
                        toggleCollapsedTask(summary.id)
                    } label: {
                        HStack(spacing: 2) {
                            Text("\(summary.listedSessionCount)")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(Theme.textMuted)
                            treeDisclosureCaret(expanded: expanded)
                        }
                    }
                    .buttonStyle(DesktopNavigationButtonStyle())
                    .disabled(isFiltering)
                    .help(isFiltering ? "筛选时显示匹配会话" : expanded ? "收起终端" : "展开终端")
                }

                Button {
                    collapsedTaskIds.remove(summary.id)
                    onRequestNewSession?(workspace, task)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Theme.textSecondary)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(WandIconButtonStyle())
                .help("在「\(summary.name)」中新建会话")
                .accessibilityLabel("在「\(summary.name)」中新建会话")
            }
            .padding(.leading, 8)
            .padding(.trailing, 4)
            .padding(.vertical, 4)
            .wandSelectionSurface(isSelected: selected, isHovered: false, cornerRadius: Theme.Radius.control)
            .contextMenu {
                Button {
                    collapsedTaskIds.remove(summary.id)
                    onOpenTask(workspace, task)
                } label: {
                    Label("打开任务", systemImage: "arrow.forward")
                }
                Button {
                    collapsedTaskIds.remove(summary.id)
                    onRequestNewSession?(workspace, task)
                } label: {
                    Label("新建会话", systemImage: "plus")
                }
                Button {
                    renameDraft = summary.name
                    renameError = nil
                    renameTarget = task
                } label: {
                    Label("重命名", systemImage: "pencil")
                }
                if summary.listedSessionCount > 0 {
                    Button(role: .destructive) {
                        clearTarget = summary
                    } label: {
                        Label("清空会话(\(summary.listedSessionCount))", systemImage: "trash.slash")
                    }
                }
                Button(role: .destructive) {
                    deleteError = nil
                    deleteTarget = task
                } label: {
                    Label("删除", systemImage: "trash")
                }
            }

            if expanded {
                if summary.sessions.isEmpty {
                    Text("还没有终端。点右侧「＋」新建。")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textMuted)
                        .padding(.leading, 12)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(Array(summary.sessions.enumerated()), id: \.element.id) { index, session in
                        taskOwnedSessionRow(session, summary: summary, workspace: workspace, index: index)
                    }
                    if summary.listedSessionCount > summary.sessions.count {
                        Text("列表仅显示 \(summary.sessions.count)/\(summary.listedSessionCount) 个会话，打开任务可查看全部。")
                            .font(.system(size: 10))
                            .foregroundColor(Theme.textMuted)
                            .padding(.leading, 12)
                            .padding(.vertical, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private func taskOwnedSessionRow(
        _ session: WorkspaceSessionSummary,
        summary: WorkspaceTaskSummary,
        workspace: Workspace,
        index: Int
    ) -> some View {
        let selected = selectedSessionId == session.id
        let label = TaskListPresentation.listSessionLabel(
            title: session.title,
            providerLabel: session.providerLabel,
            cwd: session.cwd,
            index: index,
            parentNames: [groupName(workspace), summary.name]
        )
        return Button {
            if isSelecting {
                if selectedSessionIds.contains(session.id) {
                    selectedSessionIds.remove(session.id)
                } else {
                    selectedSessionIds.insert(session.id)
                }
                return
            }
            onOpenTaskSession?(workspace, summary.asTask(), session)
        } label: {
            HStack(spacing: 8) {
                if isSelecting {
                    Image(systemName: selectedSessionIds.contains(session.id) ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(selectedSessionIds.contains(session.id) ? Theme.brand : Theme.textMuted)
                        .frame(width: 14, height: 14)
                }
                BrandLogo(provider: session.provider ?? "terminal", color: selected ? Theme.wandAccent : Theme.textSecondary)
                    .frame(width: 13, height: 13)
                    .frame(width: 18, height: 18)
                Text(label)
                    .font(.system(size: 12, weight: selected ? .semibold : .medium))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                if session.sessionKind == "pty" {
                    Text("终端")
                        .font(.system(size: 9))
                        .foregroundColor(Theme.textMuted)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 12)
            .padding(.trailing, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .wandSelectionSurface(isSelected: selected, isHovered: false, cornerRadius: Theme.Radius.control)
        }
        .buttonStyle(DesktopNavigationButtonStyle())
        .contextMenu {
            Button(role: .destructive) {
                requestDeleteSession(session)
            } label: {
                Label("删除终端", systemImage: "trash")
            }
        }
    }

    private func groupName(_ workspace: Workspace) -> String {
        workspace.name
    }

    /// 聚合行只有 workspaceId/name/cwd；打开任务需要完整 Workspace，按组信息重建。
    private func workspace(from group: TaskDirectoryGroup) -> Workspace {
        if let workspace = store.workspaces.first(where: { $0.id == group.workspaceId }) {
            return workspace
        }
        return Workspace(
            id: group.workspaceId,
            name: group.workspaceName,
            cwd: group.workspaceCwd,
            defaultProvider: nil,
            layout: nil,
            createdAt: "",
            lastOpenedAt: nil
        )
    }

    private var loadingState: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .tint(Theme.wandAccent)
            Text("正在加载工作空间…")
                .font(.system(size: 11))
                .foregroundColor(Theme.textSecondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func errorState(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(message)
                .font(.system(size: 11))
                .foregroundColor(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("重试") {
                Task {
                    await store.loadTaskGroups(force: true)
                    if case .failed = store.indexState { await store.loadWorkspaceIndex() }
                }
            }
            .font(.system(size: 11))
            .buttonStyle(DesktopNavigationButtonStyle())
            .foregroundColor(Theme.wandAccent)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Sheets / dialogs

    private var renameTaskSheetItem: Binding<WorkspaceTask?> {
        Binding(
            get: { renameTarget },
            set: { renameTarget = $0 }
        )
    }

    private var deleteConfirmationPresented: Binding<Bool> {
        Binding(
            get: { deleteTarget != nil },
            set: { presented in
                if !presented {
                    deleteTarget = nil
                }
            }
        )
    }

    private var deletionErrorPresented: Binding<Bool> {
        Binding(
            get: { deleteError != nil },
            set: { presented in
                if !presented {
                    deleteError = nil
                }
            }
        )
    }

    private func requestNewTask(_ request: NewTaskSheetRequest) {
        if let onRequestNewTask {
            onRequestNewTask(request)
        } else {
            newTaskRequest = request
        }
    }

    /// 新建任务 sheet：目录按 find-or-create 归入隐式项目；worktree 开关对齐 web/iOS。
    private func newTaskSheet(_ request: NewTaskSheetRequest) -> some View {
        NewTaskSheetBody(request: request, store: store) { workspace, creation in
            showToast("已创建任务「\(creation.name)」")
            onOpenTask(workspace, WorkspaceTask(
                id: creation.id,
                workspaceId: creation.workspaceId,
                name: creation.name,
                worktree: creation.worktree,
                layout: nil,
                status: creation.status,
                createdAt: "",
                lastOpenedAt: nil
            ))
        }
    }

    private func renameSheet(
        title: String,
        draft: Binding<String>,
        error: String?,
        busy: Bool,
        onCancel: @escaping () -> Void,
        onSave: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.system(size: 22, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .windowDrag()
            Rectangle().fill(Theme.border).frame(height: 0.5)
            VStack(alignment: .leading, spacing: 10) {
                TextField("名称", text: draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .padding(12)
                    .focused($renameFocused)
                    .wandInputSurface(focused: renameFocused, invalid: error != nil,
                                      cornerRadius: Theme.Radius.control)
                if let error {
                    Text(error)
                        .font(.footnote)
                        .foregroundColor(Theme.danger)
                }
            }
            .padding(24)
            HStack {
                Spacer()
                Button("取消", action: onCancel)
                    .buttonStyle(WandSecondaryButtonStyle())
                    .disabled(busy)
                Button(busy ? "保存中…" : "保存", action: onSave)
                    .buttonStyle(WandPrimaryButtonStyle())
                    .disabled(busy || draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 380)
        .background(Theme.workspaceBackground)
        .hideNativeTitleBar()
    }

    private func saveTaskRename(_ task: WorkspaceTask) async {
        let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 80 else {
            renameError = "名称不能为空且不超过 80 字符"
            return
        }
        renameBusy = true
        do {
            let updated = try await store.renameWorkspaceTask(
                workspaceId: task.workspaceId,
                taskId: task.id,
                name: trimmed
            )
            renameTarget = nil
            renameBusy = false
            onTaskRenamed?(updated)
        } catch {
            renameError = error.localizedDescription
            renameBusy = false
        }
    }

    private func confirmDeleteTask(_ target: WorkspaceTask) async {
        deleteBusy = true
        do {
            try await store.deleteWorkspaceTask(workspaceId: target.workspaceId, taskId: target.id)
            onTaskDeleted?(target.id)
            deleteTarget = nil
        } catch {
            deleteError = error.localizedDescription
        }
        deleteBusy = false
    }

    private func requestDeleteSession(_ session: WorkspaceSessionSummary) {
        deleteError = nil
        deleteSessionTarget = session
    }

    @ViewBuilder
    private func manageBar(groups: [TaskDirectoryGroup]) -> some View {
        HStack(spacing: 8) {
            if isSelecting {
                Text(selectedTaskIds.isEmpty && selectedSessionIds.isEmpty
                     ? "点选任务或终端"
                     : "已选择 \(selectedTaskIds.count + selectedSessionIds.count) 项")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                Spacer(minLength: 0)
                Button(allVisibleSelected(groups) ? "取消全选" : "全选") {
                    let all = manageableSelection
                    if allVisibleSelected(groups) {
                        selectedTaskIds.removeAll()
                        selectedSessionIds.removeAll()
                    } else {
                        selectedTaskIds = all.taskIds
                        selectedSessionIds = all.sessionIds
                    }
                }
                .buttonStyle(DesktopNavigationButtonStyle())
                Button("删除", role: .destructive) {
                    let available = manageableSelection
                    let resolved = TaskListPresentation.resolveManagedDeletion(
                        .init(taskIds: selectedTaskIds.intersection(available.taskIds),
                              sessionIds: selectedSessionIds.intersection(available.sessionIds)),
                        groups: groups
                    )
                    if !resolved.isEmpty { pendingManagedDelete = resolved }
                }
                .buttonStyle(DesktopNavigationButtonStyle())
                .disabled(selectedTaskIds.isEmpty && selectedSessionIds.isEmpty)
                Button("完成") {
                    isSelecting = false
                    selectedTaskIds.removeAll()
                    selectedSessionIds.removeAll()
                }
                .buttonStyle(DesktopNavigationButtonStyle())
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private func allVisibleSelected(_ groups: [TaskDirectoryGroup]) -> Bool {
        let all = manageableSelection
        return !all.isEmpty && selectedTaskIds == all.taskIds && selectedSessionIds == all.sessionIds
    }

    private func confirmManagedDelete() async {
        guard let pending = pendingManagedDelete else { return }
        let available = manageableSelection
        let selection = TaskListPresentation.resolveManagedDeletion(
            .init(taskIds: pending.taskIds.intersection(available.taskIds),
                  sessionIds: pending.sessionIds.intersection(available.sessionIds)),
            groups: visibleTaskGroups
        )
        guard !selection.isEmpty else {
            pendingManagedDelete = nil
            return
        }
        do {
            for taskId in selection.taskIds {
                if let task = store.taskGroups.flatMap(\.tasks).first(where: { $0.id == taskId }) {
                    try await store.deleteWorkspaceTask(workspaceId: task.workspaceId, taskId: task.id)
                    onTaskDeleted?(task.id)
                }
            }
            if !selection.sessionIds.isEmpty {
                try await store.deleteSessions(Array(selection.sessionIds))
            }
            pendingManagedDelete = nil
            isSelecting = false
            selectedTaskIds.removeAll()
            selectedSessionIds.removeAll()
            showToast("已删除\(TaskListPresentation.describeManagedDeletion(selection))")
        } catch {
            deleteError = error.localizedDescription
        }
    }

    private func sessionDeleteLabel(_ session: WorkspaceSessionSummary) -> String {
        TaskListPresentation.listSessionLabel(
            title: session.title,
            providerLabel: session.providerLabel,
            cwd: session.cwd,
            index: 0,
            parentNames: []
        )
    }

    private func confirmDeleteSession() async {
        guard let target = deleteSessionTarget, !deleteSessionBusy else { return }
        deleteSessionBusy = true
        do {
            try await store.deleteSessions([target.id])
            showToast("已删除终端「\(sessionDeleteLabel(target))」")
            deleteSessionTarget = nil
        } catch {
            deleteSessionTarget = nil
            deleteError = error.localizedDescription
        }
        deleteSessionBusy = false
    }

    private func confirmClearSessions() async {
        guard let target = clearTarget, !clearBusy else { return }
        clearBusy = true
        do {
            try await store.clearTaskSessions(taskId: target.id)
            showToast("已清空「\(target.name)」的会话")
            clearTarget = nil
        } catch {
            deleteError = error.localizedDescription
        }
        clearBusy = false
    }

    private func showToast(_ message: String) {
        toastMessage = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
            if toastMessage == message { toastMessage = nil }
        }
    }
}
