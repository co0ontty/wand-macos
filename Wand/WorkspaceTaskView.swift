import SwiftUI

/// 主栏任务窗：Orca 风格的标签条 + 当前工作窗口。
/// 桌面端去掉 iOS 导航栏，标签和空态直接铺在工作区里。
struct WorkspaceTaskView: View {
    let workspace: Workspace
    let task: WorkspaceTask
    let api: WandAPI
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var gitStatusStore: GitStatusStore
    var preferredSessionId: String? = nil
    var onRequestNewSession: (() -> Void)? = nil
    var onSnapshotViewed: ((SessionSnapshot) -> Void)? = nil
    var showsHeader = true
    @State private var creationDraft: SessionCreationDraft?

    var body: some View {
        ZStack {
            Theme.workspaceBackground
            content
        }
        .task(id: task.id) {
            if store.currentTask?.id == task.id, store.taskState.detail != nil {
                if let preferredSessionId {
                    await store.selectSession(id: preferredSessionId)
                }
                return
            }
            await store.openTask(workspace: workspace, task: task,
                                 preferredSessionId: preferredSessionId)
        }

    }

    @ViewBuilder
    private var content: some View {
        if let creationDraft {
            NewSessionView(api: api, draft: creationDraft, workspaceStore: store,
                           embedded: true) { session in
                Task {
                    await store.openTask(workspace: workspace, task: task,
                                         preferredSessionId: session.id)
                    self.creationDraft = nil
                    await store.loadTaskGroups(force: true)
                }
            }
            .id(creationDraft.id)
        } else if store.currentTask?.id != task.id {
            loadingState("正在打开任务…")
        } else {
            switch store.taskState {
            case .idle, .loading:
                loadingState("正在恢复任务上下文…")
            case .failed(let message):
                errorState(message)
            case .empty:
                emptyTask
            case .ready(let detail):
                readyTask(detail)
            }
        }
    }

    private var emptyTask: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task { requestNewSession() }
    }

    private func requestNewSession() {
        if let onRequestNewSession {
            onRequestNewSession()
        } else {
            creationDraft = SessionCreationDraft(context: SessionCreationContext(
                cwd: store.taskState.detail?.cwd ?? workspace.cwd,
                workspaceId: workspace.id,
                taskId: task.id,
                taskName: task.name,
                workspaceDefaultProvider: workspace.defaultProvider?.rawValue,
                startsNewTask: false
            ))
        }
    }

    private func readyTask(_ detail: WorkspaceTaskDetail) -> some View {
        VStack(spacing: 0) {
            if let warning = store.layoutWarning {
                warningBanner(warning)
            }
            if showsHeader {
                WorkspaceSessionHeader(store: store, sessions: detail.sessions, selectedId: store.visibleSessionID,
                    onSelect: { id in Task { await store.selectSession(id: id) } }, onNew: requestNewSession)
                Rectangle().fill(Theme.border).frame(height: 0.5)
            }
            sessionContent
        }
    }

    @ViewBuilder
    private var sessionContent: some View {
        // 换任务时 store 会保留上一个会话快照直到新快照到达（否则壳层会把「加载中」
        // 当成「没有会话」）。这里只渲染确实属于当前任务详情的会话，避免旧会话
        // 在新任务下闪一帧。
        if let snapshot = store.visibleSnapshot,
           snapshot.id == store.visibleSessionID,
           store.taskState.detail?.sessions.contains(where: { $0.id == snapshot.id }) == true {
            MainColumn(
                api: api,
                sessionId: snapshot.id,
                provider: snapshot.provider ?? "claude",
                session: snapshot,
                gitStatusStore: gitStatusStore,
                showsHeader: false,
                onSnapshotViewed: onSnapshotViewed
            )
            .id(snapshot.id)
        } else if store.sessionLoading {
            loadingState("正在加载工作窗口…")
        } else if let error = store.sessionError {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 26, weight: .light))
                    .foregroundColor(Theme.danger)
                Text(error)
                    .font(.system(size: 13))
                    .foregroundColor(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                if let id = store.visibleSessionID {
                    Button("重试") { Task { await store.selectSession(id: id) } }
                        .buttonStyle(WandSecondaryButtonStyle())
                }
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            loadingState("正在选择工作窗口…")
        }
    }

    private func warningBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
            Text(message)
                .font(.system(size: 13))
                .lineLimit(2)
            Spacer(minLength: 4)
            Button { store.clearLayoutWarning() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
            }
            .buttonStyle(WandIconButtonStyle())
        }
        .foregroundColor(Theme.textSecondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.warning.opacity(0.06))
    }

    private func loadingState(_ text: String) -> some View {
        VStack(spacing: 12) {
            ProgressView().tint(Theme.wandAccent)
            Text(text)
                .font(.system(size: 13))
                .foregroundColor(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 26, weight: .light))
                .foregroundColor(Theme.textSecondary)
            Text(message)
                .font(.system(size: 13))
                .foregroundColor(Theme.textSecondary)
                .multilineTextAlignment(.center)
            Button("重试") { Task { await store.reloadCurrentTask() } }
                .buttonStyle(WandSecondaryButtonStyle())
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Server directory membership owns sibling tabs; never guess it from matching cwd strings.
enum DesktopSessionTabScope {
    static func liveStandaloneIds(groups: [TaskDirectoryGroup]) -> Set<String> {
        var ids = Set<String>()
        for group in groups {
            for session in group.standaloneSessions where session.archived != true && session.workspaceTaskId == nil && session.teamChat == nil {
                ids.insert(session.id)
            }
        }
        return ids
    }

    static func standalone(groups: [TaskDirectoryGroup], selected: SessionSnapshot) -> [WorkspaceSessionSummary] {
        let live = WorkspaceSessionSummary(snapshot: selected)
        guard selected.archived != true, selected.workspaceTaskId == nil,
              let group = groups.first(where: { $0.standaloneSessions.contains(where: { $0.id == selected.id }) }) else { return [live] }
        let sessions = group.standaloneSessions.filter {
            $0.archived != true && $0.workspaceTaskId == nil && $0.teamChat == nil
        }.map { $0.id == selected.id ? live : $0 }
        guard sessions.contains(where: { $0.id == selected.id }) else { return [live] }
        return sessions.enumerated().sorted { lhs, rhs in
            let a = lhs.element.startedAt ?? "", b = rhs.element.startedAt ?? ""
            return a == b ? lhs.offset < rhs.offset : a < b
        }.map(\.element)
    }
}

/// One reusable native tab strip in the main toolbar. Content and deletion remain separate owners.
struct WorkspaceSessionHeader: View {
    @ObservedObject var store: WorkspaceStore
    let sessions: [WorkspaceSessionSummary]
    let selectedId: String?
    let onSelect: (String) -> Void
    let onNew: () -> Void
    var onDeleted: (String) -> Void = { _ in }
    @State private var pendingDelete: WorkspaceSessionSummary?
    @State private var deleting = false
    @State private var deleteError: String?

    var body: some View {
        HStack(spacing: 8) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                            tab(session, index: index).id(session.id)
                        }
                    }.padding(.vertical, 4)
                }
                .onChange(of: selectedId) { id in if let id { proxy.scrollTo(id, anchor: .center) } }
                .onAppear { if let selectedId { proxy.scrollTo(selectedId, anchor: .center) } }
            }
            Button(action: onNew) { Image(systemName: "plus").frame(width: 28, height: 28) }
                .buttonStyle(WandIconButtonStyle()).help("在当前目录新建会话").accessibilityLabel("新建会话")
                .sidebarPresence("workbar-new")
        }
        .frame(height: 44)
        .accessibilityIdentifier("unified-workspace-session-tabs")
        .alert("关闭并删除会话？", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 && !deleting { pendingDelete = nil } }
        ), presenting: pendingDelete) { target in
            Button("取消", role: .cancel) { pendingDelete = nil }
            Button(deleting ? "删除中…" : "删除", role: .destructive) {
                Task { await confirmDeleteSession(target) }
            }.disabled(deleting)
        } message: { target in
            Text("会话「\(label(target, index: 0))」会结束并被删除，此操作无法撤销。")
        }
        .alert("删除未完成", isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })) {
            Button("好", role: .cancel) { deleteError = nil }
        } message: { Text(deleteError ?? "") }
    }

    private func confirmDeleteSession(_ target: WorkspaceSessionSummary) async {
        guard !deleting else { return }
        deleting = true
        do {
            try await store.deleteSessions([target.id])
            pendingDelete = nil
            onDeleted(target.id)
        } catch { deleteError = error.localizedDescription }
        deleting = false
    }

    private func label(_ session: WorkspaceSessionSummary, index: Int) -> String {
        TaskListPresentation.listSessionLabel(title: session.title, providerLabel: session.providerLabel, cwd: session.cwd, index: index)
    }

    private func tab(_ session: WorkspaceSessionSummary, index: Int) -> some View {
        let selected = selectedId == session.id
        let title = label(session, index: index)
        return HStack(spacing: 0) {
            Button { onSelect(session.id) } label: {
                HStack(spacing: 8) {
                    BrandLogo(provider: session.provider, color: Theme.textSecondary).frame(width: 16, height: 16)
                    Text(title).font(.system(size: 12, weight: selected ? .semibold : .medium))
                        .lineLimit(1).truncationMode(.tail).frame(maxWidth: 240)
                    if ["running", "thinking"].contains(session.activityStatus) {
                        Circle().fill(Theme.success).frame(width: 5, height: 5).accessibilityLabel("运行中")
                    }
                }
                .foregroundColor(selected ? Theme.textPrimary : Theme.textSecondary)
                .padding(.leading, 10).padding(.trailing, 4).frame(height: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(DesktopNavigationButtonStyle()).help(title)
            .sidebarPresence("workbar-tab-\(session.id)")
            .accessibilityAddTraits(selected ? .isSelected : [])
            Button { pendingDelete = session } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .regular)).frame(width: 24, height: 32)
            }.buttonStyle(WandIconButtonStyle()).disabled(deleting)
                .help("关闭并删除会话 \(title)").accessibilityLabel("关闭并删除会话 \(title)")
        }
        .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
            .fill(selected ? Theme.wandAccent.opacity(0.06) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
            .stroke(selected ? Theme.wandAccent : Theme.border, lineWidth: 0.5).allowsHitTesting(false))
        .contextMenu {
            Button(role: .destructive) { pendingDelete = session } label: { Label("关闭并删除会话", systemImage: "trash") }
                .disabled(deleting)
        }
    }
}
