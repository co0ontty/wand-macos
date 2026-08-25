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
}

/// 侧栏项目树：项目展开后是任务和直属会话。交互对齐 Orca / Web「项目」面板。
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
    var onOpenParallel: ((Workspace, WorkspaceTask) -> Void)? = nil
    var onMergeAgentStarted: ((Workspace, SessionSnapshot) -> Void)? = nil
    var onWorkspaceDeleted: ((String) -> Void)? = nil
    var onCreateWorkspace: (() -> Void)? = nil

    @State private var expandedWorkspaceIds = Set<String>()
    @State private var renameTarget: WorkspaceTask?
    @State private var renameDraft = ""
    @State private var renameError: String?
    @State private var renameBusy = false
    @State private var deleteTarget: WorkspaceTask?
    @State private var deleteBusy = false
    @State private var deleteError: String?
    @State private var collapsedTaskGroups = Set<String>()
    @State private var collapsedTaskIds = Set<String>()
    @State private var collapsedLooseGroups = Set<String>()
    @State private var clearTarget: WorkspaceTaskSummary?
    @State private var clearBusy = false
    @State private var deleteSessionTarget: WorkspaceSessionSummary?
    @State private var deleteSessionBusy = false
    @State private var renameWorkspaceTarget: Workspace?
    @State private var renameWorkspaceDraft = ""
    @State private var renameWorkspaceError: String?
    @State private var renameWorkspaceBusy = false
    @State private var deleteWorkspaceTarget: Workspace?
    @State private var deleteWorkspaceBusy = false
    @State private var deleteWorkspaceError: String?
    @State private var reviewTarget: Workspace?
    @State private var toastMessage: String?
    @State private var newTaskRequest: NewTaskSheetRequest?

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                stateContent
            }
            if let toastMessage {
                VStack {
                    Text(toastMessage)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(Color.black.opacity(0.78)))
                        .padding(.top, 8)
                    Spacer()
                }
                .allowsHitTesting(false)
            }
        }
        .task {
            if case .idle = store.indexState {
                await store.loadWorkspaceIndex()
            }
            await store.loadTaskGroups()
        }
        .onChange(of: selectedTaskId) { taskId in
            if let taskId { collapsedTaskIds.remove(taskId) }
        }
        .onChange(of: store.workspaces.map(\.id).joined(separator: ",")) { ids in
            if expandedWorkspaceIds.isEmpty {
                expandedWorkspaceIds = Set(ids.split(separator: ",").map(String.init))
            }
        }
        .onChange(of: expandedWorkspaceIdsDescription) { _ in
            for workspaceId in expandedWorkspaceIds where store.standaloneSessions[workspaceId] == nil {
                Task { await store.loadWorkspaceSessions(workspaceId: workspaceId) }
            }
        }
        .sheet(item: $reviewTarget) { workspace in
            WorkspaceWorktreeReviewView(
                workspace: workspace,
                api: api,
                store: store,
                onMergeAgentStarted: { started in
                    onMergeAgentStarted?(workspace, started)
                }
            )
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
        .sheet(item: renameWorkspaceSheetItem) { workspace in
            renameSheet(
                title: "重命名项目",
                draft: $renameWorkspaceDraft,
                error: renameWorkspaceError,
                busy: renameWorkspaceBusy,
                onCancel: { renameWorkspaceTarget = nil },
                onSave: { Task { await saveWorkspaceRename(workspace) } }
            )
        }
        .confirmationDialog(
            deleteTarget == nil ? "删除此项目？" : "删除此任务？",
            isPresented: deleteConfirmationPresented,
            titleVisibility: .visible
        ) {
            if let target = deleteTarget {
                Button("删除任务", role: .destructive) {
                    Task { await confirmDeleteTask(target) }
                }
            } else if let target = deleteWorkspaceTarget {
                Button("删除项目", role: .destructive) {
                    Task { await confirmDeleteWorkspace(target) }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            if let target = deleteTarget {
                Text("任务「\(target.name)」及其会话和独立 worktree 将被删除，此操作无法撤销。")
            } else if let target = deleteWorkspaceTarget {
                Text("项目「\(target.name)」及其任务、会话与独立 worktree 将被删除，此操作无法撤销。")
            }
        }
        .alert("操作未完成", isPresented: deletionErrorPresented) {
            Button("好", role: .cancel) {
                deleteError = nil
                deleteWorkspaceError = nil
            }
        } message: {
            Text(deleteError ?? deleteWorkspaceError ?? "")
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
    }

    private var expandedWorkspaceIdsDescription: String {
        expandedWorkspaceIds.sorted().joined(separator: ",")
    }

    @ViewBuilder
    private var stateContent: some View {
        switch store.indexState {
        case .idle, .loading:
            if store.workspaces.isEmpty {
                loadingState
            } else {
                workspaceContent
            }
        case .failed(let message):
            if store.workspaces.isEmpty {
                errorState(message)
            } else {
                workspaceContent
            }
        case .loaded:
            workspaceContent
        }
    }

    private var visibleWorkspaces: [Workspace] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return store.workspaces }
        return store.workspaces.filter { workspace in
            workspace.name.lowercased().contains(needle)
                || workspace.cwd.lowercased().contains(needle)
                || store.tasks(for: workspace.id).contains { $0.name.lowercased().contains(needle) }
        }
    }

    @ViewBuilder
    private var workspaceContent: some View {
        taskGroupsContent
    }

    @ViewBuilder
    private var projectTreeContent: some View {
        if visibleWorkspaces.isEmpty {
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "folder")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
                Text(store.workspaces.isEmpty ? "还没有项目" : "没有匹配的项目")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                if store.workspaces.isEmpty {
                    Button("新建项目") { onCreateWorkspace?() }
                        .buttonStyle(WandPrimaryButtonStyle())
                }
                Spacer()
            }
            .padding(16)
        } else {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(visibleWorkspaces) { workspace in
                        workspaceBlock(workspace)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 8)
            }
        }
    }

    /// 任务一级视图：GET /api/tasks 聚合，目录组为一级容器，未分组会话不丢失。
    @ViewBuilder
    private var taskGroupsContent: some View {
        let visible = store.taskGroups.filter { !$0.tasks.isEmpty || !$0.standaloneSessions.isEmpty }
        if visible.isEmpty && store.taskGroupsError == nil {
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
                Text("还没有任务")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                Text("新建任务时选目录，之后在任务里建会话无需再选目录。")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                Button("新建任务") {
                    newTaskRequest = NewTaskSheetRequest(cwd: "", projectHint: nil)
                }
                .buttonStyle(WandPrimaryButtonStyle())
                Spacer()
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 2, pinnedViews: [.sectionHeaders]) {
                    if let error = store.taskGroupsError {
                        inlineError(error)
                    }
                    ForEach(visible) { group in
                        taskGroupBlock(group, directoryCount: visible.count)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 8)
            }
        }
    }

    private func taskGroupBlock(_ group: TaskDirectoryGroup, directoryCount: Int) -> some View {
        let expanded = TaskListPresentation.isDirectoryExpanded(
            userCollapsed: collapsedTaskGroups.contains(group.id),
            directoryCount: directoryCount
        )
        let collapsible = TaskListPresentation.showsDirectoryDisclosure(directoryCount: directoryCount)
        return VStack(spacing: 2) {
            taskGroupHeader(group, expanded: expanded, collapsible: collapsible)
            if expanded {
                ForEach(group.tasks) { summary in
                    taskSummaryRow(summary, group: group)
                }
                if group.tasks.isEmpty && group.standaloneSessions.isEmpty {
                    Text("这个目录还没有任务。")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textMuted)
                        .padding(.leading, 12)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !group.standaloneSessions.isEmpty {
                    standaloneSessionBlock(group)
                }
            }
        }
    }

    private func standaloneSessionBlock(_ group: TaskDirectoryGroup) -> some View {
        let expanded = !collapsedLooseGroups.contains(group.id)
        return VStack(alignment: .leading, spacing: 2) {
            Button {
                toggleCollapsedLooseGroup(group.id)
            } label: {
                HStack {
                    Text("未分组会话（\(group.standaloneSessions.count)）")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textMuted)
                    Spacer(minLength: 6)
                    treeDisclosureCaret(expanded: expanded)
                }
                .padding(.leading, 12)
                .padding(.trailing, 6)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expanded ? "收起未分组会话" : "展开未分组会话")
            if expanded {
                ForEach(group.standaloneSessions) { session in
                    standaloneSessionRow(session, workspace: workspace(from: group))
                }
            }
        }
    }

    private func taskGroupHeader(_ group: TaskDirectoryGroup, expanded: Bool, collapsible: Bool) -> some View {
        let sessionTotal = group.tasks.reduce(0) { $0 + $1.listedSessionCount } + group.standaloneSessions.count
        return HStack(spacing: 6) {
            Button {
                guard collapsible else { return }
                toggleCollapsedTaskGroup(group.id)
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: group.isSynthetic ? "folder.badge.questionmark" : "folder")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Theme.wandAccent)
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
            .buttonStyle(.plain)

            Button {
                newTaskRequest = NewTaskSheetRequest(cwd: group.workspaceCwd, projectHint: group.workspaceName)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(WandIconButtonStyle())
            .help("在此目录新建任务")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
    }

    private func treeDisclosureCaret(expanded: Bool) -> some View {
        Image(systemName: "chevron.down")
            .font(.system(size: 8, weight: .semibold))
            .foregroundColor(Theme.textMuted)
            .rotationEffect(.degrees(expanded ? 0 : -90))
            .frame(width: 12, height: 14)
    }

    private func toggleCollapsedTaskGroup(_ id: String) {
        if collapsedTaskGroups.contains(id) {
            collapsedTaskGroups.remove(id)
        } else {
            collapsedTaskGroups.insert(id)
        }
    }

    private func toggleCollapsedTask(_ id: String) {
        if collapsedTaskIds.contains(id) {
            collapsedTaskIds.remove(id)
        } else {
            collapsedTaskIds.insert(id)
        }
    }

    private func toggleCollapsedLooseGroup(_ id: String) {
        if collapsedLooseGroups.contains(id) {
            collapsedLooseGroups.remove(id)
        } else {
            collapsedLooseGroups.insert(id)
        }
    }

    private func taskSummaryRow(_ summary: WorkspaceTaskSummary, group: TaskDirectoryGroup) -> some View {
        let selected = selectedTaskId == summary.id
        let canCollapseSessions = TaskListPresentation.showsTaskSessionDisclosure(sessionCount: summary.listedSessionCount)
        let expanded = TaskListPresentation.isTaskSessionsExpanded(
            userCollapsed: collapsedTaskIds.contains(summary.id),
            sessionCount: summary.listedSessionCount
        )
        let workspace = workspace(from: group)
        let task = summary.asTask()
        return VStack(spacing: 1) {
            HStack(spacing: 4) {
                Button {
                    collapsedTaskIds.remove(summary.id)
                    onOpenTask(workspace, task)
                } label: {
                    HStack(spacing: 6) {
                        if summary.isIsolated || summary.status == "done" {
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
                .buttonStyle(.plain)

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
                    .buttonStyle(.plain)
                    .help(expanded ? "收起终端" : "展开终端")
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
                .help("在「\(summary.name)」中新建终端")
            }
            .padding(.leading, 8)
            .padding(.trailing, 4)
            .padding(.vertical, 4)
            .wandSelectionSurface(isSelected: selected, isHovered: false, cornerRadius: 7)
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
                    Label("新建终端", systemImage: "plus")
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
                if onOpenParallel != nil {
                    Button {
                        onOpenParallel?(workspace, task)
                    } label: {
                        Label("并行任务", systemImage: "square.stack.3d.up")
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
            onOpenTaskSession?(workspace, summary.asTask(), session)
        } label: {
            HStack(spacing: 8) {
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
            .wandSelectionSurface(isSelected: selected, isHovered: false, cornerRadius: 7)
        }
        .buttonStyle(.plain)
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
        Workspace(
            id: group.workspaceId,
            name: group.workspaceName,
            cwd: group.workspaceCwd,
            defaultProvider: nil,
            layout: nil,
            createdAt: "",
            lastOpenedAt: nil
        )
    }

    private func workspaceBlock(_ workspace: Workspace) -> some View {
        let expanded = expandedWorkspaceIds.contains(workspace.id)
        let tasks = store.tasks(for: workspace.id)
        let sessions = store.standaloneSessions[workspace.id] ?? []
        return VStack(spacing: 2) {
            workspaceHeader(workspace, expanded: expanded)
            if expanded {
                if let error = store.taskErrors[workspace.id] {
                    inlineError(error)
                }
                ForEach(sessions) { session in
                    standaloneSessionRow(session, workspace: workspace)
                }
                ForEach(tasks) { task in
                    taskRow(task, workspace: workspace)
                }
                if sessions.isEmpty && tasks.isEmpty && store.taskErrors[workspace.id] == nil {
                    Text("还没有任务")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textMuted)
                        .padding(.leading, 36)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func workspaceHeader(_ workspace: Workspace, expanded: Bool) -> some View {
        HStack(spacing: 6) {
            Button {
                if expanded {
                    expandedWorkspaceIds.remove(workspace.id)
                } else {
                    expandedWorkspaceIds.insert(workspace.id)
                    Task { await store.loadWorkspaceSessions(workspaceId: workspace.id) }
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(Theme.textMuted)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Image(systemName: "folder")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Theme.wandAccent)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(workspace.name)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundColor(Theme.textPrimary)
                            .lineLimit(1)
                        Text((workspace.cwd as NSString).lastPathComponent)
                            .font(.system(size: 10))
                            .foregroundColor(Theme.textMuted)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                newTaskRequest = NewTaskSheetRequest(cwd: workspace.cwd, projectHint: workspace.name)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(WandIconButtonStyle())
            .help("新建任务")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.clear)
        )
        .contextMenu {
            Button {
                newTaskRequest = NewTaskSheetRequest(cwd: workspace.cwd, projectHint: workspace.name)
            } label: {
                Label("新任务", systemImage: "plus")
            }
            Button {
                reviewTarget = workspace
            } label: {
                Label("Worktree 审查", systemImage: "arrow.triangle.branch")
            }
            Button {
                renameWorkspaceDraft = workspace.name
                renameWorkspaceError = nil
                renameWorkspaceTarget = workspace
            } label: {
                Label("重命名项目", systemImage: "pencil")
            }
            Button(role: .destructive) {
                deleteWorkspaceError = nil
                deleteWorkspaceTarget = workspace
            } label: {
                Label("删除项目", systemImage: "trash")
            }
        }
    }

    private func standaloneSessionRow(
        _ session: WorkspaceSessionSummary,
        workspace: Workspace
    ) -> some View {
        Button {
            onOpenSession?(workspace, session)
        } label: {
            HStack(spacing: 8) {
                BrandLogo(provider: session.provider ?? "terminal", color: Theme.textSecondary)
                    .frame(width: 13, height: 13)
                    .frame(width: 18, height: 18)
                Text(TaskListPresentation.listSessionLabel(
                    title: session.title,
                    providerLabel: session.providerLabel,
                    cwd: session.cwd,
                    index: 0,
                    parentNames: [workspace.name]
                ))
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Circle()
                    .fill(session.status == "running" ? Theme.success : Theme.textMuted.opacity(0.45))
                    .frame(width: 6, height: 6)
            }
            .padding(.leading, 28)
            .padding(.trailing, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                requestDeleteSession(session)
            } label: {
                Label("删除终端", systemImage: "trash")
            }
        }
    }

    private func taskRow(_ task: WorkspaceTask, workspace: Workspace) -> some View {
        let selected = selectedTaskId == task.id
        return Button {
            onOpenTask(workspace, task)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: task.status == "done" ? "checkmark.circle.fill" : "arrow.triangle.branch")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(task.status == "done" ? Theme.success : Theme.textSecondary)
                    .frame(width: 18, height: 18)
                Text(task.name)
                    .font(.system(size: 12.5, weight: selected ? .semibold : .medium))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(.leading, 28)
            .padding(.trailing, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .wandSelectionSurface(isSelected: selected, isHovered: false, cornerRadius: 7)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                renameDraft = task.name
                renameError = nil
                renameTarget = task
            } label: {
                Label("重命名", systemImage: "pencil")
            }
            Button(role: .destructive) {
                deleteError = nil
                deleteTarget = task
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    private func inlineError(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.system(size: 11))
            .foregroundColor(Theme.danger)
            .padding(.leading, 28)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var loadingState: some View {
        VStack {
            Spacer()
            ProgressView().tint(Theme.wandAccent)
            Spacer()
        }
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 26))
                .foregroundColor(Theme.textSecondary)
            Text(message)
                .font(.footnote)
                .foregroundColor(Theme.textSecondary)
                .multilineTextAlignment(.center)
            Button("重试") { Task { await store.loadWorkspaceIndex() } }
                .buttonStyle(WandSecondaryButtonStyle())
            Spacer()
        }
        .padding(16)
    }

    // MARK: - Sheets / dialogs

    private var renameTaskSheetItem: Binding<WorkspaceTask?> {
        Binding(
            get: { renameTarget },
            set: { renameTarget = $0 }
        )
    }

    private var renameWorkspaceSheetItem: Binding<Workspace?> {
        Binding(
            get: { renameWorkspaceTarget },
            set: { renameWorkspaceTarget = $0 }
        )
    }

    private var deleteConfirmationPresented: Binding<Bool> {
        Binding(
            get: { deleteTarget != nil || deleteWorkspaceTarget != nil },
            set: { presented in
                if !presented {
                    deleteTarget = nil
                    deleteWorkspaceTarget = nil
                }
            }
        )
    }

    private var deletionErrorPresented: Binding<Bool> {
        Binding(
            get: { deleteError != nil || deleteWorkspaceError != nil },
            set: { presented in
                if !presented {
                    deleteError = nil
                    deleteWorkspaceError = nil
                }
            }
        )
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
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
            }
            .padding(16)
            .windowDrag()
            Divider().opacity(0.35)
            VStack(alignment: .leading, spacing: 10) {
                TextField("名称", text: draft)
                    .textFieldStyle(.roundedBorder)
                if let error {
                    Text(error)
                        .font(.footnote)
                        .foregroundColor(Theme.danger)
                }
            }
            .padding(16)
            HStack {
                Spacer()
                Button("取消", action: onCancel)
                    .buttonStyle(WandSecondaryButtonStyle())
                    .disabled(busy)
                Button(busy ? "保存中…" : "保存", action: onSave)
                    .buttonStyle(WandPrimaryButtonStyle())
                    .disabled(busy || draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(16)
        }
        .frame(width: 380)
        .background(WandAmbientBackground())
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

    private func saveWorkspaceRename(_ workspace: Workspace) async {
        let trimmed = renameWorkspaceDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            renameWorkspaceError = "名称不能为空"
            return
        }
        renameWorkspaceBusy = true
        do {
            _ = try await store.renameWorkspace(workspaceId: workspace.id, name: trimmed)
            renameWorkspaceTarget = nil
            renameWorkspaceBusy = false
        } catch {
            renameWorkspaceError = error.localizedDescription
            renameWorkspaceBusy = false
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

    private func confirmDeleteWorkspace(_ target: Workspace) async {
        deleteWorkspaceBusy = true
        do {
            try await store.deleteWorkspace(workspaceId: target.id)
            onWorkspaceDeleted?(target.id)
            deleteWorkspaceTarget = nil
        } catch {
            deleteWorkspaceError = error.localizedDescription
        }
        deleteWorkspaceBusy = false
    }

    private func showToast(_ message: String) {
        toastMessage = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
            if toastMessage == message { toastMessage = nil }
        }
    }
}
