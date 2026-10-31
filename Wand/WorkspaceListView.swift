import SwiftUI
import AppKit

/// Sidebar menus copy their own object's server path, never the active conversation's path.
struct DesktopCopyWorkingDirectoryButton: View {
    let cwd: String?
    @State private var failed = false

    static func availablePath(_ cwd: String?) -> String? {
        guard let cwd, !cwd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return cwd
    }

    static func copy(_ cwd: String?, to pasteboard: NSPasteboard) -> Bool {
        guard let path = availablePath(cwd) else { return false }
        pasteboard.clearContents()
        return pasteboard.setString(path, forType: .string)
    }

    var body: some View {
        if let path = Self.availablePath(cwd) {
            Button {
                failed = !Self.copy(path, to: .general)
            } label: {
                Label(failed ? "复制失败，请重试" : "复制工作目录", systemImage: "doc.on.doc")
            }
            .help(path)
        }
    }
}

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
    var parentTaskId: String? = nil
}

/// 共享滚动侧栏的工作空间分区：项目、任务及任务内会话。
struct WorkspaceListView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var store: WorkspaceStore
    let api: WandAPI
    let selectedTaskId: String?
    var selectedSessionId: String? = nil
    let query: String
    var recentOnly = false
    var activeOnly = false
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
    @State private var knownTaskGroups = Set<String>()
    @State private var collapsedRecentGroups = Set<String>()
    @State private var pendingSelectionReveal = false
    @State private var collapsedTaskIds = Set<String>()
    @State private var expandedStandaloneGroups = Set<String>()
    @State private var clearTarget: WorkspaceTaskSummary?
    @State private var clearBusy = false
    @State private var deleteSessionTarget: WorkspaceSessionSummary?
    @State private var deleteSessionBusy = false
    @State private var toastMessage: String?
    @State private var sectionCreateTarget: TaskDirectoryGroup?
    @State private var moveSessionTarget: WorkspaceSessionSummary?
    @State private var newTaskRequest: NewTaskSheetRequest?
    @State private var isSelecting = false
    @State private var selectedTaskIds = Set<String>()
    @State private var selectedSessionIds = Set<String>()
    @State private var pendingManagedDelete: TaskListPresentation.ManageSelection?
    @State private var renameWorkspaceTarget: TaskDirectoryGroup?
    @State private var renameWorkspaceDraft = ""
    @State private var renameWorkspaceError: String?
    @State private var renameWorkspaceBusy = false
    @State private var deleteWorkspaceTarget: TaskDirectoryGroup?
    @State private var deleteWorkspaceBusy = false
    @State private var deleteWorkspaceError: String?
    @State private var worktreeReviewTarget: TaskDirectoryGroup?
    @State private var worktreeOverview: WorkspaceWorktreeOverview?
    @State private var worktreeLoading = false
    @State private var worktreeError: String?
    @State private var worktreeSelectedTaskIds: Set<String> = []
    @State private var worktreeMergeBusy = false
    @State private var archiveError: String?
    @State private var collapsedArchivedTaskIds = Set<String>()
    @StateObject private var organizationAction = WandTaskOrganizationAction()
    @State private var organizationGroupId: String?
    @State private var lastOrganizationGroupId: String?
    @State private var organizationInitialMode: WandTaskOrganizationMode?

    var body: some View {
        ZStack {
            VStack(spacing: 2) {
                if !recentOnly { sectionHeader }
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
        .onAppear { discoverDirectories(); revealSelection() }
        .onChange(of: selectedTaskId) { _ in revealSelection() }
        .onChange(of: selectedSessionId) { _ in revealSelection() }
        .onChange(of: store.taskGroups) { _ in
            discoverDirectories()
            if pendingSelectionReveal { revealSelection() }
        }
        .onChange(of: recentOnly) { _ in
            isSelecting = false
            selectedTaskIds.removeAll()
            selectedSessionIds.removeAll()
        }
        .wandMotion(value: recentOnly)
        .wandMotion(value: activeOnly)
        .wandMotion(value: collapsedRecentGroups, layout: true)
        .sheet(item: $sectionCreateTarget) { group in
            DesktopWorkspaceSectionSheet(api: api, group: group) { await store.loadTaskGroups(force: true) }
        }
        .sheet(item: $moveSessionTarget) { session in
            DesktopSessionMoveSheet(api: api, store: store, session: session)
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
        .modifier(DirectoryManagementModifier(
            renameWorkspaceTarget: renameWorkspaceSheetItem,
            renameWorkspaceDraft: $renameWorkspaceDraft,
            renameWorkspaceError: renameWorkspaceError,
            renameWorkspaceBusy: renameWorkspaceBusy,
            onSaveRename: { group in Task { await saveWorkspaceRename(group) } },
            worktreeReviewTarget: $worktreeReviewTarget,
            worktreeReviewContent: { AnyView(worktreeReviewSheet($0)) },
            deleteWorkspacePresented: deleteWorkspacePresented,
            deleteWorkspaceBusy: deleteWorkspaceBusy,
            deleteWorkspaceErrorPresented: deleteWorkspaceErrorPresented,
            deleteWorkspaceErrorMessage: deleteWorkspaceError ?? "",
            deleteWorkspaceTarget: deleteWorkspaceTarget,
            onDeleteWorkspace: { target in
                Task { await confirmDeleteWorkspace(target) }
            },
            onClearDeleteError: { deleteWorkspaceError = nil }
        ))
        .alert("归档失败", isPresented: archiveErrorPresented) {
            Button("好", role: .cancel) { archiveError = nil }
        } message: {
            Text(archiveError ?? "")
        }
        .confirmationDialog(
            "删除此任务？",
            isPresented: deleteConfirmationPresented,
            titleVisibility: .visible,
            presenting: deleteTarget
        ) { target in
            Button("删除任务", role: .destructive) {
                Task { await confirmDeleteTask(target) }
            }
            .disabled(deleteBusy)
            Button("取消", role: .cancel) {}
        } message: { target in
            Text(target.kind == "section" ? "删除分区「\(target.name)」，会话移回工作区并继续保留。" : "任务「\(target.name)」及其会话和独立 worktree 将被删除，此操作无法撤销。")
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
            titleVisibility: .visible,
            presenting: clearTarget
        ) { target in
            Button(clearBusy ? "清空中…" : "确认清空", role: .destructive) {
                Task { await confirmClearSessions(target) }
            }
            .disabled(clearBusy)
            Button("取消", role: .cancel) { clearTarget = nil }
        } message: { target in
            Text("将结束并删除「\(target.name)」的 \(target.listedSessionCount) 个终端，此操作无法撤销。")
        }
        .confirmationDialog(
            "删除终端？",
            isPresented: Binding(
                get: { deleteSessionTarget != nil },
                set: { if !$0 && !deleteSessionBusy { deleteSessionTarget = nil } }
            ),
            titleVisibility: .visible,
            presenting: deleteSessionTarget
        ) { target in
            Button(deleteSessionBusy ? "删除中…" : "删除终端", role: .destructive) {
                Task { await confirmDeleteSession(target) }
            }
            .disabled(deleteSessionBusy)
            Button("取消", role: .cancel) { deleteSessionTarget = nil }
        } message: { target in
            Text("终端「\(sessionDeleteLabel(target))」会结束并被删除，此操作无法撤销。")
        }
        .confirmationDialog(
            "删除所选项目？",
            isPresented: Binding(
                get: { pendingManagedDelete != nil },
                set: { if !$0 { pendingManagedDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingManagedDelete
        ) { selection in
            Button("删除", role: .destructive) {
                Task { await confirmManagedDelete(selection) }
            }
            Button("取消", role: .cancel) { pendingManagedDelete = nil }
        } message: { selection in
            Text("将删除\(TaskListPresentation.describeManagedDeletion(selection))，此操作无法撤销。")
        }
    }

    private var sectionHeader: some View {
        HStack(spacing: 2) {
            SidebarSectionCaption(
                title: "工作区",
                count: visibleTaskGroups.isEmpty ? nil : visibleTaskGroups.count
            )
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
            Menu {
                Button {
                    onCreateWorkspace?()
                } label: {
                    Label("新建工作空间", systemImage: "folder.badge.plus")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 26, height: 26)
            .help("工作空间菜单")
            .accessibilityLabel("工作空间菜单")
            .accessibilityHint("新建工作空间")
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.top, 2)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private var stateContent: some View {
        if !store.taskGroupsLoaded && store.taskGroups.isEmpty {
            if let error = store.taskGroupsError {
                errorState(error)
            } else {
                loadingState
            }
        } else if recentOnly {
            recentContent.transition(projectionTransition)
        } else {
            taskGroupsContent.transition(projectionTransition)
        }
    }

    private var projectionTransition: AnyTransition {
        reduceMotion ? .identity : .asymmetric(
            insertion: .opacity.animation(Theme.Motion.structure),
            removal: .opacity.animation(Theme.Motion.feedback))
    }

    private func discoverDirectories() {
        TaskListPresentation.discoverDirectories(store.taskGroups, known: &knownTaskGroups, expanded: &expandedTaskGroups)
    }

    private var isFiltering: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var visibleTaskGroups: [TaskDirectoryGroup] {
        TaskListPresentation.sidebarDirectoryGroups(store.taskGroups, workspaces: store.workspaces, query: query,
            activeOnly: activeOnly, selectedSessionId: selectedSessionId, selectedTaskId: selectedTaskId)
    }

    private var manageableSelection: TaskListPresentation.ManageSelection {
        var selection = TaskListPresentation.ManageSelection()
        let groups = visibleTaskGroups
        for group in groups where TaskListPresentation.isDirectoryExpanded(
            userCollapsed: !expandedTaskGroups.contains(group.id),
            directoryCount: groups.count,
            isSearching: isFiltering || activeOnly
        ) {
            for task in group.tasks {
                selection.taskIds.insert(task.id)
                if TaskListPresentation.isTaskSessionsExpanded(
                    userCollapsed: collapsedTaskIds.contains(task.id),
                    sessionCount: task.listedSessionCount,
                    isSearching: isFiltering || activeOnly
                ) {
                    selection.sessionIds.formUnion(task.sessions.filter {
                        !activeOnly || TaskListPresentation.isActive($0, selectedSessionId: selectedSessionId)
                    }.map(\.id))
                }
            }
        }
        return selection
    }

    private var taskGroupsContent: some View {
        let visible = visibleTaskGroups
        return VStack(spacing: 10) {
            if isSelecting { manageBar(groups: visible) }
            if let error = store.taskGroupsError {
                errorState(error)
            }
            if visible.isEmpty {
                Text(isFiltering ? "没有匹配的执行会话或历史" : "当前没有匹配的执行会话；计划仍在任务面板，归档记录可搜索查看。")
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
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
    }

    /// Compact native tree: leave room for titles while keeping workspace → task → session hierarchy.
    private enum TreeIndent {
        static let task: CGFloat = 28
        static let session: CGFloat = 42
        static let guide: CGFloat = 16
    }

    private func hierarchyTaskRow(_ task: WorkspaceTaskSummary, group: TaskDirectoryGroup, ancestors: [String]) -> AnyView {
        AnyView(VStack(alignment: .leading, spacing: 1) {
            if ancestors.count > 1 { Text("历史深层执行记录 · 保留原归属").font(.caption).foregroundColor(Theme.textSecondary) }
            taskSummaryRow(task, group: group)
            ForEach(group.tasks.filter { $0.parentWorkspaceTaskId == task.id && !ancestors.contains($0.id) && $0.id != task.id }) { child in
                hierarchyTaskRow(child, group: group, ancestors: ancestors + [task.id]).padding(.leading, 12)
            }
        })
    }

    private func taskGroupBlock(_ group: TaskDirectoryGroup, directoryCount: Int) -> some View {
        let expanded = TaskListPresentation.isDirectoryExpanded(
            userCollapsed: !expandedTaskGroups.contains(group.id),
            directoryCount: directoryCount,
            isSearching: isFiltering || activeOnly
        )
        let collapsible = !isFiltering && !activeOnly && TaskListPresentation.showsDirectoryDisclosure(directoryCount: directoryCount)
        let containsSelection = groupContainsSelection(group)
        return VStack(alignment: .leading, spacing: 2) {
            taskGroupHeader(
                group,
                expanded: expanded,
                collapsible: collapsible,
                containsSelection: containsSelection
            )
            if expanded {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(group.tasks) { summary in
                        taskSummaryRow(summary, group: group)
                    }
                    if !group.standaloneSessions.isEmpty {
                        standaloneGroup(group)
                    }
                    if group.tasks.isEmpty && group.standaloneSessions.isEmpty {
                        Text(activeOnly ? "没有活动任务或会话" : "这个目录还没有任务或会话。")
                            .font(.system(size: 11))
                            .foregroundColor(Theme.textMuted)
                            .padding(.leading, TreeIndent.task)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.bottom, 4)
                .background(alignment: .leading) {
                    Rectangle()
                        .fill(Theme.textMuted.opacity(0.45))
                        .frame(width: 1)
                        .padding(.leading, TreeIndent.guide)
                        .padding(.vertical, 4)
                }
                .accessibilityIdentifier("sidebar-directory-children-\(group.id)")
            }
        }
    }

    private func treeSessionActivity(_ session: WorkspaceSessionSummary) -> (color: Color, label: String)? {
        switch session.activityStatus {
        case "queued":
            return (Theme.textSecondary, "排队中")
        case "running":
            return (Theme.success, "运行中")
        case "thinking":
            return (Theme.success, "思考中")
        case "waiting", "waiting-input", "waiting_input", "reconnecting":
            return (Theme.warning, "等待中")
        case "failed":
            return (Theme.danger, "已失败")
        case "permission", "permission-blocked":
            return (Theme.warning, "等待授权")
        default:
            return nil
        }
    }

    private func groupContainsSelection(_ group: TaskDirectoryGroup) -> Bool {
        if let selectedTaskId, group.tasks.contains(where: { $0.id == selectedTaskId }) {
            return true
        }
        if let selectedSessionId {
            return group.standaloneSessions.contains { $0.id == selectedSessionId } || group.tasks.contains { task in
                task.sessions.contains { $0.id == selectedSessionId }
            }
        }
        return false
    }

    private func taskGroupHeader(
        _ group: TaskDirectoryGroup,
        expanded: Bool,
        collapsible: Bool,
        containsSelection: Bool
    ) -> some View {
        let sessionTotal = group.tasks.filter { $0.archived != true && $0.status != "done" }.reduce(0) { $0 + TaskListPresentation.sidebarSessionCount($1) }
        return SidebarHoveringRow { hovering in
            HStack(spacing: 2) {
                collapsibleControl(
                    enabled: collapsible,
                    help: collapsible ? (expanded ? "收起任务" : "展开任务") : "筛选时保持展开",
                    accessibilityLabel: "\(group.workspaceName)，\(expanded ? "已展开" : "已收起")",
                    accessibilityHint: collapsible ? (expanded ? "收起任务" : "展开任务") : "筛选时保持展开",
                    action: { toggleCollapsedTaskGroup(group.id) }
                ) {
                    taskGroupHeaderLabel(
                        group,
                        expanded: expanded,
                        containsSelection: containsSelection,
                        sessionTotal: sessionTotal
                    )
                }
                .sidebarPresence("sidebar-group-\(group.id)")

                if !collapsible {
                    // 筛选期间标题不可折叠：用可见文字说明，别让用户对着没有反应的标题反复点击。
                    Text(activeOnly ? "活动" : "筛选时展开")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(Theme.textMuted)
                        .lineLimit(1)
                        .fixedSize()
                        .accessibilityHidden(true)
                }

                Button {
                    requestNewTask(NewTaskSheetRequest(
                        cwd: group.workspaceCwd,
                        projectHint: group.workspaceName,
                        workspaceId: group.isSynthetic || group.isGlobal ? nil : group.workspaceId
                    ))
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Theme.textSecondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(WandIconButtonStyle())
                .help("在此目录新建任务")
                .accessibilityLabel("在「\(group.workspaceName)」中新建任务")
            }
            .padding(.leading, 4)
            .padding(.trailing, 4)
            .padding(.vertical, 5)
            .sidebarSelectionChrome(isSelected: false, isHovered: hovering)
            .contextMenu {
                Button { sectionCreateTarget = group } label: { Label("新建分区", systemImage: "folder.badge.plus") }
                DesktopCopyWorkingDirectoryButton(cwd: group.isGlobal ? nil : group.workspaceCwd)
                Menu {
                    if lastOrganizationGroupId == group.id && organizationAction.hasState {
                        Button("查看上次归类结果或进度") {
                            organizationInitialMode = nil
                            organizationGroupId = group.id
                        }
                        Divider()
                    }
                    ForEach(WandTaskOrganizationMode.allCases) { mode in
                        Button(mode.label) {
                            organizationAction.reset()
                            lastOrganizationGroupId = group.id
                            organizationInitialMode = mode
                            organizationGroupId = group.id
                        }
                        .help(mode.hint)
                        .disabled(organizationAction.busy || organizationAction.unresolved || isSelecting)
                    }
                } label: {
                    Label("会话自动归类", systemImage: "folder")
                }
                Divider()
                if !group.isSynthetic && !group.isGlobal {
                    Button {
                        requestNewTask(NewTaskSheetRequest(
                            cwd: group.workspaceCwd,
                            projectHint: group.workspaceName,
                            workspaceId: group.workspaceId
                        ))
                    } label: {
                        Label("新建任务", systemImage: "plus")
                    }

                    Button {
                        openWorktreeReview(group)
                    } label: {
                        Label("审查并合并 Worktree", systemImage: "arrow.triangle.merge")
                    }

                    Button {
                        renameWorkspaceDraft = group.workspaceName
                        renameWorkspaceError = nil
                        renameWorkspaceTarget = group
                    } label: {
                        Label("重命名目录", systemImage: "pencil")
                    }

                    Divider()

                    Button(role: .destructive) {
                        deleteWorkspaceError = nil
                        deleteWorkspaceTarget = group
                    } label: {
                        Label("删除目录", systemImage: "trash")
                    }
                } else {
                    // 未归档目录是按 cwd 聚合出来的视图，没有可改可删的目录实体。
                    Text(group.isGlobal ? "未归属工作区" : "目录分组")
                }
            }
            .popover(isPresented: Binding(
                get: { organizationGroupId == group.id },
                set: { if !$0 { organizationGroupId = nil } }
            ), arrowEdge: .bottom) {
                WandTaskOrganizationPanel(api: api, target: .directoryGroup(group), action: organizationAction,
                                          initialMode: organizationInitialMode, onOpenSession: { id in
                    Task {
                        do {
                            let snapshot = try await api.getSession(id: id)
                            onOpenSession?(workspace(from: group), WorkspaceSessionSummary(snapshot: snapshot))
                        } catch { organizationAction.reportError(error.localizedDescription) }
                    }
                }) {
                    await store.loadTaskGroups(force: true)
                }
            }
            .modifier(DirectoryMenuHint(group: group))
        }
    }

    private func taskGroupHeaderLabel(
        _ group: TaskDirectoryGroup,
        expanded: Bool,
        containsSelection: Bool,
        sessionTotal: Int
    ) -> some View {
        HStack(spacing: 6) {
            treeDisclosureCaret(expanded: expanded)
            Image(systemName: group.isSynthetic ? "folder.badge.questionmark" : "folder.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(containsSelection ? Theme.wandAccent : Theme.textSecondary)
                .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(group.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)
                    if group.isSynthetic {
                        Text("目录")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(Theme.textTertiary)
                    }
                }
                if let caption = TaskListPresentation.directoryPathCaption(name: group.workspaceName, cwd: group.workspaceCwd) {
                    Text(caption)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Theme.textMuted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if group.tasks.count > 0 {
                Text("\(group.tasks.count) 任务")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Theme.textMuted)
                    .lineLimit(1)
                    .help("\(group.tasks.count) 个任务，\(sessionTotal) 个会话")
                    .accessibilityLabel("\(group.tasks.count) 个任务，\(sessionTotal) 个会话")
            }
        }
        .contentShape(Rectangle())
    }

    /// 折叠控件不可用时渲染成静态标签：`.plain` 按钮被禁用后外观不变，
    /// 留着按钮就会出现「看起来能点、点了没反应」的假可点区域。
    @ViewBuilder
    private func collapsibleControl<Label: View>(
        enabled: Bool,
        help: String,
        accessibilityLabel: String,
        accessibilityHint: String,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) -> some View {
        if enabled {
            Button(action: action, label: label)
                .buttonStyle(.plain)
                .help(help)
                .accessibilityLabel(accessibilityLabel)
                .accessibilityHint(accessibilityHint)
        } else {
            label()
                .help(help)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(accessibilityLabel)
                .accessibilityHint(accessibilityHint)
        }
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
            if group.standaloneSessions.contains(where: { $0.id == selectedSessionId }) {
                expandedTaskGroups.insert(group.id)
                expandedStandaloneGroups.insert(group.id)
                pendingSelectionReveal = false
                return
            }
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
        let presentedSessions = TaskListPresentation.sidebarSessions(summary.sessions)
        let childSessionSelected = presentedSessions.contains { $0.id == selectedSessionId }
        let selected = selectedTaskId == summary.id && !childSessionSelected
        let visibleOwnCount = summary.archived == true || summary.status == "done" ? 0 : TaskListPresentation.sidebarSessionCount(summary)
        let canCollapseSessions = TaskListPresentation.showsTaskSessionDisclosure(sessionCount: visibleOwnCount)
        let expanded = TaskListPresentation.isTaskSessionsExpanded(
            userCollapsed: collapsedTaskIds.contains(summary.id),
            sessionCount: visibleOwnCount,
            isSearching: isFiltering || activeOnly,
            isOnlyTask: group.tasks.count == 1
        )
        let workspace = TaskListPresentation.workspaceForTask(summary, group: group, workspaces: store.workspaces)
        let task = summary.asTask()
        return VStack(spacing: 1) {
            SidebarHoveringRow { hovering in
                HStack(spacing: 2) {
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
                            }
                            Text(summary.name)
                                .font(.system(size: 12.5, weight: selected ? .semibold : .medium))
                                .foregroundColor(Theme.textPrimary)
                                .lineLimit(1)
                                .multilineTextAlignment(.leading)
                                .help(summary.name)
                            if !isSelecting && summary.isIsolated {
                                Text("隔离")
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundColor(Theme.textTertiary)
                                    .accessibilityLabel("隔离任务")
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("sidebar-task-\(summary.id)")
                    .sidebarPresence("sidebar-task-\(summary.id)")
                    .accessibilityAddTraits(selected ? .isSelected : [])

                    if summary.hasQueuedExecution {
                        Label("排队中", systemImage: "clock")
                            .font(.caption).foregroundColor(Theme.textSecondary)
                            .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                    }
                    if canCollapseSessions {
                        collapsibleControl(
                            enabled: !isFiltering && !activeOnly,
                            help: isFiltering ? "筛选时显示匹配会话" : (expanded ? "收起终端" : "展开终端"),
                            accessibilityLabel: "自身 \(visibleOwnCount) 个可见会话",
                            accessibilityHint: isFiltering ? "筛选时显示匹配会话" : (expanded ? "收起终端" : "展开终端"),
                            action: { toggleCollapsedTask(summary.id) }
                        ) {
                            HStack(spacing: 2) {
                                Text("\(visibleOwnCount)")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(Theme.textMuted)
                                treeDisclosureCaret(expanded: expanded)
                            }
                            .padding(.horizontal, 2)
                            // 与 WandIconButtonStyle 一致的 30 pt 命中区（DESIGN.md）。
                            .frame(minWidth: 30, minHeight: 30)
                            .contentShape(Rectangle())
                        }
                    }

                    if !isSelecting {
                        Button {
                            collapsedTaskIds.remove(summary.id)
                            onRequestNewSession?(workspace, task)
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(Theme.textSecondary)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(WandIconButtonStyle())
                        .help("在「\(summary.name)」中新建会话")
                        .accessibilityLabel("在「\(summary.name)」中新建会话")
                    }
                }
                .padding(.trailing, 4)
                .padding(.vertical, 3)
                .sidebarSelectionChrome(isSelected: selected, isHovered: hovering)
                .padding(.leading, TreeIndent.task)
            }
            .contextMenu {
                DesktopCopyWorkingDirectoryButton(cwd: summary.worktree?.path.isEmpty == false ? summary.worktree?.path : summary.cwd)
                Button {
                    collapsedTaskIds.remove(summary.id)
                    onOpenTask(workspace, task)
                } label: {
                    Label(summary.kind == "section" ? "打开分区" : "打开任务", systemImage: "arrow.forward")
                }
                Button {
                    collapsedTaskIds.remove(summary.id)
                    onRequestNewSession?(workspace, task)
                } label: {
                    Label("新建会话", systemImage: "plus")
                }
                Button {
                    requestNewTask(NewTaskSheetRequest(
                        cwd: summary.worktree?.path.isEmpty == false ? (summary.worktree?.path ?? "") : summary.cwd,
                        projectHint: summary.name,
                        workspaceId: group.workspaceId,
                        parentTaskId: summary.boardTaskId ?? summary.id
                    ))
                } label: {
                    Label("创建目录", systemImage: "folder.badge.plus")
                }.disabled(summary.kind == "section")
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

            if expanded && visibleOwnCount > 0 {
                let split = WorkspaceSessionSummary.splitArchived(presentedSessions)
                if split.active.isEmpty && split.archived.isEmpty {
                    Text(activeOnly ? "没有活动会话" : "还没有终端。点右侧「＋」新建。")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textMuted)
                        .padding(.leading, TreeIndent.session)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    let visibleSessions = activeOnly ? split.active.filter {
                        TaskListPresentation.isActive($0, selectedSessionId: selectedSessionId)
                    } : split.active
                    ForEach(Array(visibleSessions.enumerated()), id: \.element.id) { index, session in
                        taskOwnedSessionRow(session, summary: summary, workspace: workspace, index: index)
                    }
                    if summary.listedSessionCount > summary.sessions.count {
                        Text("列表仅显示 \(presentedSessions.count) 个会话，打开任务可查看全部。")
                            .font(.system(size: 10))
                            .foregroundColor(Theme.textMuted)
                            .padding(.leading, TreeIndent.session)
                            .padding(.vertical, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !activeOnly { archivedSessionsFold(split.archived, summary: summary, workspace: workspace) }
                }
            }
        }
    }

    #if DEBUG
    func sessionRowForTesting(
        _ session: WorkspaceSessionSummary, summary: WorkspaceTaskSummary, workspace: Workspace, index: Int
    ) -> some View {
        taskOwnedSessionRow(session, summary: summary, workspace: workspace, index: index)
    }
    #endif

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
            index: index
        )
        let activity = treeSessionActivity(session)
        let emphasized = selected || activity != nil
        return SidebarHoveringRow { hovering in
            Button {
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
                HStack(spacing: 6) {
                    if isSelecting {
                        Image(systemName: selectedSessionIds.contains(session.id) ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(selectedSessionIds.contains(session.id) ? Theme.brand : Theme.textMuted)
                            .frame(width: 14, height: 14)
                    }
                    if let employeeID = session.employeeId {
                        ContactAvatar(id: employeeID, avatar: session.employeeAvatar ?? "", name: session.employeeName ?? "", provider: session.provider, size: 28)
                    } else {
                        BrandLogo(provider: session.provider ?? "terminal", color: selected ? Theme.wandAccent : Theme.textSecondary)
                            .frame(width: 12, height: 12).frame(width: 16, height: 16)
                    }
                    Text(label)
                        .font(.system(size: 12, weight: selected ? .semibold : (emphasized ? .medium : .regular)))
                        .foregroundColor(emphasized ? Theme.textPrimary : Theme.textSecondary)
                        .lineLimit(1)
                    if let badge = session.identityBadge {
                        Text(badge)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(Theme.textSecondary)
                            .help(session.identityCaption ?? badge)
                    } else if session.providerLabel == "Wand Agent", label != session.providerLabel {
                        Text(session.providerLabel)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(Theme.textSecondary)
                    }
                    if session.sessionKind == "pty" {
                        Text("终端")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(Theme.textMuted)
                    }
                    if session.isJustCompleted {
                        Text("刚完成")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(Theme.success)
                            .help("已完成，还没查看")
                            .accessibilityLabel("刚完成，还没查看")
                    }
                    Spacer(minLength: 0)
                    if let activity {
                        Circle()
                            .fill(activity.color)
                            .frame(width: 6, height: 6)
                            .help(activity.label)
                            .accessibilityLabel(activity.label)
                    }
                }
                .padding(.trailing, 8)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .sidebarSelectionChrome(isSelected: selected, isHovered: hovering)
            .padding(.leading, TreeIndent.session)
        }
        .contextMenu {
            if session.archived != true {
                Button { moveSessionTarget = session } label: { Label("移动到分区", systemImage: "folder") }
            }
            DesktopCopyWorkingDirectoryButton(cwd: session.cwd)
            Button {
                Task { await toggleArchive(session) }
            } label: {
                Label(
                    session.archived == true ? "恢复会话" : "归档会话",
                    systemImage: session.archived == true ? "tray.and.arrow.up" : "archivebox"
                )
            }
            Divider()
            Button(role: .destructive) {
                requestDeleteSession(session)
            } label: {
                Label("删除终端", systemImage: "trash")
            }
        }
    }

    /// 每层自己的「已归档会话」折叠区：归档不杀进程也不删历史，
    /// 收起来只是不再占用活跃列表的视线，恢复入口始终在原位。
    @ViewBuilder
    private func archivedSessionsFold(
        _ archived: [WorkspaceSessionSummary],
        summary: WorkspaceTaskSummary,
        workspace: Workspace
    ) -> some View {
        if !archived.isEmpty {
            let open = !collapsedArchivedTaskIds.contains(summary.id)
            VStack(alignment: .leading, spacing: 2) {
                Button {
                    if open { collapsedArchivedTaskIds.insert(summary.id) }
                    else { collapsedArchivedTaskIds.remove(summary.id) }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "archivebox")
                            .font(.system(size: 10))
                        Text("已归档会话 \(archived.count)")
                            .font(.system(size: 10, weight: .medium))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .rotationEffect(.degrees(open ? 90 : 0))
                        Spacer(minLength: 0)
                    }
                    .foregroundColor(Theme.textMuted)
                    .padding(.trailing, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.leading, TreeIndent.session)
                .padding(.vertical, 3)
                .help(open ? "收起已归档会话" : "展开已归档会话")
                .accessibilityLabel("已归档会话 \(archived.count) 个，\(open ? "已展开" : "已收起")")

                if open {
                    ForEach(Array(archived.enumerated()), id: \.element.id) { _, session in
                        taskOwnedSessionRow(session, summary: summary, workspace: workspace, index: 0)
                    }
                }
            }
            .wandMotion(value: collapsedArchivedTaskIds, layout: true)
        }
    }

    /// 归档是软标记：不杀进程、不删历史，也不改任务归属。
    /// 失败只提示、不改本地状态，避免「界面显示已归档但服务端没改」。
    private func toggleArchive(_ session: WorkspaceSessionSummary) async {
        let target = !(session.archived == true)
        do {
            try await store.archiveSession(session.id, archived: target)
        } catch {
            archiveError = "无法\(target ? "归档" : "恢复")会话：\(error.localizedDescription)"
        }
    }

    private func groupName(_ workspace: Workspace) -> String {
        workspace.name
    }

    /// 聚合行只有 workspaceId/name/cwd；打开任务需要完整 Workspace，按组信息重建。
    private var recentContent: some View {
        let groups = TaskListPresentation.recentGroups(store.taskGroups, query: query,
            activeOnly: activeOnly, selectedSessionId: selectedSessionId)
        return LazyVStack(alignment: .leading, spacing: 8) {
            if let error = store.taskGroupsError { errorState(error) }
            if groups.isEmpty {
                Text(isFiltering ? "没有匹配的会话" : (activeOnly ? "现在没有活动会话" : "还没有会话"))
                    .font(.system(size: 11)).foregroundColor(Theme.textMuted)
                    .padding(12)
            }
            ForEach(groups) { group in
                let expanded = isFiltering || activeOnly || !collapsedRecentGroups.contains(group.id)
                VStack(alignment: .leading, spacing: 2) {
                    Button {
                        if collapsedRecentGroups.contains(group.id) { collapsedRecentGroups.remove(group.id) }
                        else { collapsedRecentGroups.insert(group.id) }
                    } label: {
                        HStack(spacing: 6) {
                            treeDisclosureCaret(expanded: expanded)
                            SidebarSectionCaption(title: group.title, count: group.entries.count)
                            Spacer(minLength: 0)
                        }.padding(.horizontal, 6).frame(height: 30).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .disabled(isFiltering || activeOnly)
                        .accessibilityLabel("\(group.title)，\(expanded ? "已展开" : "已收起")")
                    if expanded {
                        ForEach(group.entries) { entry in recentSessionRow(entry) }
                    }
                }
            }
        }.padding(.horizontal, 8)
    }

    private func standaloneGroup(_ group: TaskDirectoryGroup) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(group.standaloneSessions) { session in
                recentSessionRow(TaskListPresentation.RecentEntry(group: group, task: nil, session: session), inDirectory: true)
            }
        }
    }

    private func recentSessionRow(_ entry: TaskListPresentation.RecentEntry, inDirectory: Bool = false) -> some View {
        let session = entry.session
        let selected = isSelecting && inDirectory ? selectedSessionIds.contains(session.id) : selectedSessionId == session.id
        return SidebarHoveringRow { hovering in
            Button {
                if isSelecting && inDirectory {
                    if selectedSessionIds.contains(session.id) { selectedSessionIds.remove(session.id) }
                    else { selectedSessionIds.insert(session.id) }
                } else if let task = entry.task {
                    let owner = TaskListPresentation.workspaceForTask(task, group: entry.group, workspaces: store.workspaces)
                    onOpenTaskSession?(owner, task.asTask(), session)
                } else { onOpenSession?(workspace(from: entry.group), session) }
            } label: {
                HStack(spacing: 8) {
                    if isSelecting && inDirectory {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(selected ? Theme.brand : Theme.textMuted)
                    }
                    if let employee = session.employeeId {
                        ContactAvatar(id: employee, avatar: session.employeeAvatar ?? "", name: session.employeeName ?? "",
                                      provider: session.provider, size: 28)
                    } else {
                        BrandLogo(provider: session.provider ?? "terminal", color: Theme.textSecondary)
                            .frame(width: 20, height: 20)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(TaskListPresentation.listSessionLabel(title: session.title, providerLabel: session.providerLabel,
                            cwd: session.cwd, index: 0))
                            .font(.system(size: 12, weight: selected ? .semibold : .medium))
                            .foregroundColor(Theme.textPrimary).lineLimit(2)
                        let context = [TaskListPresentation.workspaceLabel(entry.group), entry.task?.name]
                            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                        if !context.isEmpty {
                            Text(context).font(.system(size: 10)).foregroundColor(Theme.textMuted).lineLimit(1)
                                .help(context)
                        }
                    }
                    Spacer(minLength: 0)
                    if session.isJustCompleted {
                        Text("刚完成").font(.system(size: 9)).foregroundColor(Theme.success)
                    } else if let activity = treeSessionActivity(session) {
                        Circle().fill(activity.color).frame(width: 6, height: 6).help(activity.label)
                            .accessibilityLabel(activity.label)
                    }
                }.padding(.horizontal, 8).padding(.vertical, 7).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .sidebarSelectionChrome(isSelected: selected, isHovered: hovering)
                .accessibilityIdentifier("sidebar-\(inDirectory ? "standalone" : "recent")-\(session.id)")
                .sidebarPresence("sidebar-\(inDirectory ? "standalone" : "recent")-\(session.id)")
                .accessibilityAddTraits(selected ? .isSelected : [])
                .help(session.title ?? session.providerLabel)
        }.contextMenu {
            if session.archived != true {
                Button { moveSessionTarget = session } label: { Label("移动到分区", systemImage: "folder") }
            }
            DesktopCopyWorkingDirectoryButton(cwd: session.cwd)
            Button { Task { await toggleArchive(session) } } label: {
                Label("归档会话", systemImage: "archivebox")
            }
            Button(role: .destructive) { requestDeleteSession(session) } label: {
                Label("删除会话", systemImage: "trash")
            }
        }
    }

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

    private var renameWorkspaceSheetItem: Binding<TaskDirectoryGroup?> {
        Binding(
            get: { renameWorkspaceTarget },
            set: { renameWorkspaceTarget = $0 }
        )
    }

    private var archiveErrorPresented: Binding<Bool> {
        Binding(
            get: { archiveError != nil },
            set: { presented in
                if !presented { archiveError = nil }
            }
        )
    }

    private var deleteWorkspaceErrorPresented: Binding<Bool> {
        Binding(
            get: { deleteWorkspaceError != nil },
            set: { presented in
                if !presented { deleteWorkspaceError = nil }
            }
        )
    }

    private var deleteWorkspacePresented: Binding<Bool> {
        Binding(
            get: { deleteWorkspaceTarget != nil },
            set: { presented in
                if !presented && !deleteWorkspaceBusy { deleteWorkspaceTarget = nil }
            }
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
        guard !deleteBusy else { return }
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

    // MARK: - 目录（工作空间）重命名 / 删除 / Worktree 合并

    private func saveWorkspaceRename(_ group: TaskDirectoryGroup) async {
        let trimmed = renameWorkspaceDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 80 else {
            renameWorkspaceError = "名称不能为空且不超过 80 字符"
            return
        }
        renameWorkspaceBusy = true
        do {
            _ = try await store.renameWorkspace(workspaceId: group.workspaceId, name: trimmed)
            renameWorkspaceTarget = nil
            renameWorkspaceBusy = false
            await store.loadTaskGroups(force: true)
        } catch {
            renameWorkspaceError = error.localizedDescription
            renameWorkspaceBusy = false
        }
    }

    private func confirmDeleteWorkspace(_ group: TaskDirectoryGroup) async {
        guard !deleteWorkspaceBusy else { return }
        deleteWorkspaceBusy = true
        do {
            try await store.deleteWorkspace(workspaceId: group.workspaceId)
            deleteWorkspaceTarget = nil
            deleteWorkspaceBusy = false
            onWorkspaceDeleted?(group.workspaceId)
            await store.loadTaskGroups(force: true)
        } catch {
            deleteWorkspaceError = error.localizedDescription
            deleteWorkspaceBusy = false
        }
    }

    /// 打开 worktree 审查前先拉一次概览：worktree 状态在别处也会变，
    /// 用侧栏列表的旧数据判断「有没有可合并项」会把用户带进空面板。
    private func openWorktreeReview(_ group: TaskDirectoryGroup) {
        worktreeReviewTarget = group
        worktreeOverview = nil
        worktreeError = nil
        worktreeSelectedTaskIds = []
        worktreeLoading = true
        Task {
            do {
                let overview = try await store.workspaceWorktreeOverview(workspaceId: group.workspaceId)
                guard worktreeReviewTarget?.workspaceId == group.workspaceId else { return }
                worktreeOverview = overview
                worktreeSelectedTaskIds = Set(overview.actionableWorktrees.map(\.taskId))
            } catch {
                guard worktreeReviewTarget?.workspaceId == group.workspaceId else { return }
                worktreeError = error.localizedDescription
            }
            worktreeLoading = false
        }
    }

    private func startWorktreeMerge(_ group: TaskDirectoryGroup) async {
        guard let overview = worktreeOverview else { return }
        let selected = worktreeSelectedTaskIds.intersection(
            Set(overview.actionableWorktrees.map(\.taskId))
        )
        guard !selected.isEmpty else {
            worktreeError = "没有可合并的 worktree"
            return
        }
        worktreeMergeBusy = true
        do {
            // 用 store 已缓存的 Workspace：worktree 合并只需要名字/目录/默认 provider，
            // 为此再拉一次详情没有收益，缓存未命中就重新加载索引。
            var workspace = store.workspaces.first { $0.id == group.workspaceId }
            if workspace == nil {
                await store.loadWorkspaceIndex()
                workspace = store.workspaces.first { $0.id == group.workspaceId }
            }
            guard let workspace else {
                worktreeError = "找不到该目录，请刷新后重试。"
                worktreeMergeBusy = false
                return
            }
            let started = try await store.startWorktreeMergeAgent(
                workspace: workspace,
                overview: overview,
                selectedTaskIds: selected
            )
            worktreeMergeBusy = false
            worktreeReviewTarget = nil
            onMergeAgentStarted?(workspace, started)
        } catch {
            worktreeError = error.localizedDescription
            worktreeMergeBusy = false
        }
    }

    // MARK: - Worktree 审查 / 合并

    /// 合并交给一个真实的 CLI 会话去做（`onMergeAgentStarted`），
    /// 这里只负责「选哪些 worktree」和把范围说清楚，不代替它执行。
    private func worktreeReviewSheet(_ group: TaskDirectoryGroup) -> some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("审查并合并 Worktree")
                        .font(.system(size: 22, weight: .semibold))
                    Text(group.workspaceName)
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textMuted)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .windowDrag()
            Rectangle().fill(Theme.border).frame(height: 0.5)

            VStack(alignment: .leading, spacing: 12) {
                if worktreeLoading {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在读取 worktree…")
                            .font(.system(size: 12))
                            .foregroundColor(Theme.textSecondary)
                    }
                } else if let error = worktreeError, worktreeOverview == nil {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.danger)
                } else if let overview = worktreeOverview {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.merge")
                            .font(.system(size: 11))
                        Text("合并到 \(overview.targetBranch)")
                            .font(.system(size: 12, weight: .medium))
                        Spacer(minLength: 0)
                        Text("\(overview.actionableWorktrees.count) 个待合并")
                            .font(.system(size: 11))
                            .foregroundColor(Theme.textMuted)
                    }
                    .foregroundColor(Theme.textSecondary)

                    if overview.worktrees.isEmpty {
                        Text("这个目录还没有独立 worktree。")
                            .font(.system(size: 12))
                            .foregroundColor(Theme.textMuted)
                    } else {
                        ScrollView {
                            VStack(spacing: 4) {
                                ForEach(overview.worktrees) { item in
                                    worktreeRow(item)
                                }
                            }
                        }
                        .frame(maxHeight: 300)
                    }

                    if let error = worktreeError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 12))
                            .foregroundColor(Theme.danger)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)

            Rectangle().fill(Theme.border).frame(height: 0.5)
            HStack {
                Text("合并会启动一个 CLI 会话处理选中的 worktree。")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textMuted)
                Spacer()
                Button("取消") { worktreeReviewTarget = nil }
                    .buttonStyle(WandSecondaryButtonStyle())
                    .disabled(worktreeMergeBusy)
                Button(worktreeMergeBusy ? "启动中…" : "启动合并") {
                    Task { await startWorktreeMerge(group) }
                }
                .buttonStyle(WandPrimaryButtonStyle())
                .disabled(worktreeMergeBusy || worktreeLoading || worktreeSelectedTaskIds.isEmpty)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 520)
        .background(Theme.workspaceBackground)
    }

    private func worktreeRow(_ item: WorkspaceWorktreeReview) -> some View {
        let selectable = item.actionable
        return Button {
            guard selectable else { return }
            if worktreeSelectedTaskIds.contains(item.taskId) {
                worktreeSelectedTaskIds.remove(item.taskId)
            } else {
                worktreeSelectedTaskIds.insert(item.taskId)
            }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: worktreeSelectedTaskIds.contains(item.taskId)
                      ? "checkmark.square.fill" : "square")
                    .font(.system(size: 13))
                    .foregroundColor(selectable ? Theme.wandAccent : Theme.textMuted)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.summary)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundColor(selectable ? Theme.textPrimary : Theme.textMuted)
                        .lineLimit(1)
                    Text(item.details)
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textMuted)
                        .lineLimit(2)
                    Text(item.branch)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Theme.textMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                Text(item.stateLabel)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(worktreeStateColor(item))
            }
            .padding(10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!selectable)
        .help(selectable ? item.details : "这个 worktree 现在不可合并：\(item.details)")
    }

    private func worktreeStateColor(_ item: WorkspaceWorktreeReview) -> Color {
        switch item.state {
        case "ready": return Theme.success
        case "dirty": return Theme.warning
        case "conflict": return Theme.danger
        default: return Theme.textMuted
        }
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
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.textPrimary.opacity(0.045))
        )
        .padding(.bottom, 2)
    }

    private func allVisibleSelected(_ groups: [TaskDirectoryGroup]) -> Bool {
        let all = manageableSelection
        return !all.isEmpty && selectedTaskIds == all.taskIds && selectedSessionIds == all.sessionIds
    }

    private func confirmManagedDelete(_ pending: TaskListPresentation.ManageSelection) async {
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
            index: 0
        )
    }

    private func confirmDeleteSession(_ target: WorkspaceSessionSummary) async {
        guard !deleteSessionBusy else { return }
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

    private func confirmClearSessions(_ target: WorkspaceTaskSummary) async {
        guard !clearBusy else { return }
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

/// 未归档目录是按 cwd 聚合出来的视图，没有可改可删的目录实体：
/// 这种行不提示「打开目录菜单」，否则 VoiceOver 会念出一个点不动的入口。
private struct DirectoryMenuHint: ViewModifier {
    let group: TaskDirectoryGroup

    func body(content: Content) -> some View {
        if group.isSynthetic {
            content
        } else {
            content.accessibilityHint("打开目录菜单")
        }
    }
}

/// 目录（工作空间）的重命名 / Worktree 审查 / 删除这组弹层单独成一处：
/// 全部挂在 WorkspaceListView 的 body 上会让类型推断超时。
/// 每个闭包都带上了触发它的目录，sheet 不需要再反查是哪一行。
private struct DirectoryManagementModifier: ViewModifier {
    let renameWorkspaceTarget: Binding<TaskDirectoryGroup?>
    let renameWorkspaceDraft: Binding<String>
    let renameWorkspaceError: String?
    let renameWorkspaceBusy: Bool
    let onSaveRename: (TaskDirectoryGroup) -> Void

    let worktreeReviewTarget: Binding<TaskDirectoryGroup?>
    let worktreeReviewContent: (TaskDirectoryGroup) -> AnyView

    let deleteWorkspacePresented: Binding<Bool>
    let deleteWorkspaceBusy: Bool
    let deleteWorkspaceErrorPresented: Binding<Bool>
    let deleteWorkspaceErrorMessage: String
    let deleteWorkspaceTarget: TaskDirectoryGroup?
    let onDeleteWorkspace: (TaskDirectoryGroup) -> Void
    let onClearDeleteError: () -> Void

    func body(content: Content) -> some View {
        content
            .sheet(item: renameWorkspaceTarget) { group in
                WorkspaceRenameSheet(
                    draft: renameWorkspaceDraft,
                    error: renameWorkspaceError,
                    busy: renameWorkspaceBusy,
                    onCancel: { renameWorkspaceTarget.wrappedValue = nil },
                    onSave: { onSaveRename(group) }
                )
            }
            .sheet(item: worktreeReviewTarget) { group in
                worktreeReviewContent(group)
            }
            .confirmationDialog(
                "删除此目录？",
                isPresented: deleteWorkspacePresented,
                titleVisibility: .visible,
                presenting: deleteWorkspaceTarget
            ) { target in
                Button(deleteWorkspaceBusy ? "删除中…" : "删除目录", role: .destructive) {
                    onDeleteWorkspace(target)
                }
                .disabled(deleteWorkspaceBusy)
                Button("取消", role: .cancel) {}
            } message: { target in
                Text("目录「\(target.workspaceName)」下的 \(target.tasks.count) 个任务及其终端将被删除，此操作无法撤销。")
            }
            .alert("操作未完成", isPresented: deleteWorkspaceErrorPresented) {
                Button("好", role: .cancel) { onClearDeleteError() }
            } message: {
                Text(deleteWorkspaceErrorMessage)
            }
    }
}

private struct WorkspaceRenameSheet: View {
    @Binding var draft: String
    let error: String?
    let busy: Bool
    let onCancel: () -> Void
    let onSave: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("重命名目录").font(.system(size: 22, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .windowDrag()
            Rectangle().fill(Theme.border).frame(height: 0.5)
            VStack(alignment: .leading, spacing: 10) {
                TextField("名称", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .padding(12)
                    .focused($focused)
                    .wandInputSurface(focused: focused, invalid: error != nil,
                                      cornerRadius: Theme.Radius.control)
                if let error {
                    Text(error).font(.footnote).foregroundColor(Theme.danger)
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
                    .disabled(busy || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 380)
    }
}

struct DesktopWorkspaceSectionSheet: View {
    let api: WandAPI
    let group: TaskDirectoryGroup
    var sessionId: String? = nil
    var onCreated: () async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(sessionId == nil ? "新建分区" : "新建分区并移入").font(.headline)
            Text("在 \(group.workspaceName) 中整理会话，不创建任务卡。").foregroundStyle(.secondary)
            TextField("分区名称", text: $name).textFieldStyle(.roundedBorder).disabled(busy)
            if let error { Text(error).foregroundStyle(Theme.danger) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.disabled(busy).keyboardShortcut(.cancelAction)
                Button(busy ? "创建中…" : "创建") {
                    guard !busy else { return }
                    busy = true
                    Task {
                        do {
                            _ = try await api.createWorkspaceSection(name: name.trimmingCharacters(in: .whitespacesAndNewlines), cwd: group.workspaceCwd,
                                workspaceId: group.isSynthetic || group.isGlobal ? nil : group.workspaceId, sessionId: sessionId)
                            await onCreated()
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                        busy = false
                    }
                }.keyboardShortcut(.defaultAction).disabled(busy || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 420).interactiveDismissDisabled(busy)
    }
}

struct DesktopSessionMoveSheet: View {
    let api: WandAPI
    @ObservedObject var store: WorkspaceStore
    let session: WorkspaceSessionSummary
    @Environment(\.dismiss) private var dismiss
    @State private var groups: [TaskDirectoryGroup] = []
    @State private var loading = true
    @State private var busy = false
    @State private var error: String?
    @State private var query = ""
    @State private var selectedId: String?
    @State private var creating = false
    private var source: TaskDirectoryGroup? {
        groups.first { $0.standaloneSessions.contains { $0.id == session.id }
            || $0.tasks.contains { $0.sessions.contains { $0.id == session.id } } }
    }
    private var currentId: String? {
        groups.flatMap(\.tasks).first { $0.sessions.contains { $0.id == session.id } }?.id
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("移动会话到分区").font(.headline)
            Text("只改变归属，保留运行目录、历史和正在执行的会话。").foregroundStyle(.secondary)
            TextField("搜索分区或工作区", text: $query).textFieldStyle(.roundedBorder).disabled(busy)
            if loading { ProgressView() }
            if let error { Text(error).foregroundStyle(Theme.danger) }
            if source != nil { Button("新建分区并移入") { creating = true }.disabled(busy) }
            List(selection: $selectedId) {
                if currentId != nil { Text("移回工作区（不分区）").tag("ungrouped") }
                ForEach(groups) { group in
                    ForEach(group.tasks.filter { $0.id != currentId && (query.isEmpty || (group.workspaceName + " " + $0.name).localizedCaseInsensitiveContains(query)) }) { target in
                        Text("\(group.workspaceName) / \(target.name)").tag(target.id)
                    }
                }
            }.frame(height: 260).disabled(busy)
            HStack {
                Button("重新加载") { Task { await load() } }.disabled(busy || loading)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
                Button(busy ? "移动中…" : "移动") { Task { await move() } }
                    .keyboardShortcut(.defaultAction).disabled(busy || loading || selectedId == nil)
            }
        }.padding(24).frame(width: 500).interactiveDismissDisabled(busy)
        .task { await load() }
        .sheet(isPresented: $creating) {
            if let source {
                DesktopWorkspaceSectionSheet(api: api, group: source, sessionId: session.id) {
                    await store.loadTaskGroups(force: true)
                    dismiss()
                }
            }
        }
    }
    private func load() async {
        loading = true
        error = nil
        do { groups = try await api.listTaskGroups() }
        catch { self.error = error.localizedDescription }
        loading = false
    }
    private func move() async {
        guard let selectedId, !busy else { return }
        busy = true
        error = nil
        do {
            if selectedId == "ungrouped" { try await api.unassignWorkspaceSession(sessionId: session.id) }
            else { try await api.moveWorkspaceSession(taskId: selectedId, sessionId: session.id) }
            await store.loadTaskGroups(force: true)
            dismiss()
        } catch { self.error = error.localizedDescription }
        busy = false
    }
}
