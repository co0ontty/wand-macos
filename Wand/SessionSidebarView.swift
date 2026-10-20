import Combine
import SwiftUI

// DEBUG geometry markers let native tests verify rendered rows without requiring OS AX permission.
extension View {
    @ViewBuilder func sidebarPresence(_ id: String) -> some View {
        #if DEBUG
        background(SidebarPresenceProbe(id: id).allowsHitTesting(false).accessibilityHidden(true))
        #else
        self
        #endif
    }
}

#if DEBUG
private struct SidebarPresenceProbe: NSViewRepresentable {
    let id: String
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.identifier = NSUserInterfaceItemIdentifier(id)
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { view.identifier = NSUserInterfaceItemIdentifier(id) }
}
#endif

// MARK: - 侧栏层级

/// 分区标题。比导航行和列表行更轻、更短，用来切开「工作空间」和「单独会话」。
struct SidebarSectionCaption: View {
    let title: String
    var count: Int? = nil

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Theme.textTertiary)
            if let count {
                Text("\(count)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Theme.textMuted)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Theme.textPrimary.opacity(0.06))
                    )
                    .accessibilityLabel("\(count) 项")
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// 行悬停只服务于侧栏树，避免每个按钮再画一层自己的底。
struct SidebarHoveringRow<Content: View>: View {
    @ViewBuilder var content: (Bool) -> Content
    @State private var hovering = false

    var body: some View {
        content(hovering)
            .onHover { hovering = $0 }
    }
}

extension View {
    /// 当前项同时使用淡底和一条短的强调线。强调线只标出「正在看的那一行」，
    /// 不把整组涂成品牌色。
    func sidebarSelectionChrome(isSelected: Bool, isHovered: Bool = false) -> some View {
        modifier(SidebarSelectionChromeModifier(isSelected: isSelected, isHovered: isHovered))
    }
}

private struct SidebarSelectionChromeModifier: ViewModifier {
    let isSelected: Bool
    let isHovered: Bool

    func body(content: Content) -> some View {
        content
            .wandSelectionSurface(
                isSelected: isSelected,
                isHovered: isHovered,
                cornerRadius: 7
            )
            .overlay(alignment: .leading) {
                if isSelected {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(Theme.wandAccent)
                        .frame(width: 3)
                        .padding(.vertical, 5)
                        .padding(.leading, 3)
                        .allowsHitTesting(false)
                }
            }
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
                // 与行上的时间（`endedAt ?? startedAt`）同一口径，详见
                // SessionTimeFormatting.sessionSortTimestamp。
                return SessionTimeFormatting.sessionSortTimestamp(
                    startedAt: session.startedAt,
                    endedAt: session.endedAt
                )
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
    var activeOnly = false
    let taskGroups: [TaskDirectoryGroup]
    let taskGroupsAvailable: Bool
    @Binding var presentNewSession: Bool
    let onSessionSelected: (SessionSnapshot) -> Void
    var onRequestNewSession: ((String?) -> Void)? = nil

    @State private var sessions: [SessionSnapshot] = []
    @State private var historySessions: [HistorySession] = []
    @State private var loading = true
    @State private var loadError: String?
    @State private var isSelecting = false
    @State private var selectedSessionIds: Set<String> = []
    @State private var showNewSession = false
    @State private var newSessionInitialCwd: String?
    @State private var historyActionInProgress = false
    @State private var pendingDeletion: PendingDeletion?
    @State private var deleteInProgress = false
    @State private var deletionError: String?
    @State private var sessionListRevision = ""
    @State private var loadGeneration = 0
    @State private var archivedSessionsCollapsed = true
    @State private var archiveError: String?
    @State private var archiveInProgress = false
    private let refreshTimer = Timer.publish(every: 10, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            header
            list
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.clear)
        .alert("归档失败", isPresented: archiveErrorPresented) {
            Button("好", role: .cancel) { archiveError = nil }
        } message: {
            Text(archiveError ?? "")
        }
        .onChange(of: query) { _ in
            selectedSessionIds.removeAll()
        }
        .onChange(of: listedSessions.map(\.id)) { ids in
            selectedSessionIds.formIntersection(Set(ids))
        }
        .onChange(of: presentNewSession) { requested in
            if requested {
                requestNewSession()
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
        .onReceive(NotificationCenter.default.publisher(for: .wandRefreshLists)) { notification in
            if let created = notification.object as? SessionSnapshot {
                // Commit the exact accepted identity before an optional server read.
                loadGeneration &+= 1
                sessionListRevision = ""
                sessions.removeAll { $0.id == created.id }
                sessions.insert(created, at: 0)
            }
            Task { await load(silent: true) }
        }
        .confirmationDialog(
            pendingDeletion?.title ?? "确认删除",
            isPresented: deletionConfirmationPresented,
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { target in
            Button(target.actionTitle, role: .destructive) {
                confirmPendingDeletion(target)
            }
            Button("取消", role: .cancel) {}
        } message: { target in
            Text(target.message)
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
                // The dialog's presenting value supplies an immutable action snapshot.
                // Dismissal can clear UI state immediately, without a run-loop race.
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
                SidebarSectionCaption(
                    title: "单独会话",
                    count: listEntries.isEmpty ? nil : listEntries.count
                )
                Spacer(minLength: 0)
                Button {
                    isSelecting = true
                    selectedSessionIds.removeAll()
                } label: {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Theme.textSecondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(WandIconButtonStyle())
                .disabled(deleteInProgress || listedSessions.isEmpty)
                .help("选择多个单独会话")
                .accessibilityLabel("选择多个单独会话")
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(minHeight: 32)
    }

    // MARK: - 列表

    @ViewBuilder
    private var list: some View {
        if loading && sessions.isEmpty && historySessions.isEmpty {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).tint(Theme.wandAccent)
                Text("正在加载会话…")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textSecondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        } else {
            if let loadError {
                VStack(alignment: .leading, spacing: 6) {
                    Text(loadError)
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("重试") { Task { await load() } }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundColor(Theme.wandAccent)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            if listEntries.isEmpty {
                if loadError == nil {
                    Text(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                         ? "还没有单独会话" : "没有匹配的单独会话")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
            } else {
                LazyVStack(spacing: 3) {
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

                Spacer(minLength: 0)
            }
            archivedStandaloneFold
        }
    }

    /// 直属会话自己的「已归档会话」折叠区。归档不杀进程也不删历史，
    /// 收起只是不再占用活跃列表的视线；展开后每条仍可原位恢复。
    @ViewBuilder
    private var archivedStandaloneFold: some View {
        if !archivedEntries.isEmpty {
            let open = !archivedSessionsCollapsed
            VStack(alignment: .leading, spacing: 3) {
                Button {
                    archivedSessionsCollapsed.toggle()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "archivebox").font(.system(size: 10))
                        Text("已归档会话 \(archivedEntries.count)")
                            .font(.system(size: 11, weight: .medium))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .rotationEffect(.degrees(open ? 90 : 0))
                        Spacer(minLength: 0)
                    }
                    .foregroundColor(Theme.textMuted)
                    .padding(.horizontal, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .help(open ? "收起已归档会话" : "展开已归档会话")
                .accessibilityLabel("已归档会话 \(archivedEntries.count) 个，\(open ? "已展开" : "已收起")")

                if open {
                    ForEach(archivedEntries) { entry in
                        if case .session(let session) = entry {
                            managedSessionTile(session)
                        }
                    }
                }
            }
            .padding(.bottom, 8)
            .wandMotion(value: archivedSessionsCollapsed, layout: true)
        }
    }

    /// 已归档的直属会话：与 `listEntries` 用同一套搜索与排序口径，
    /// 免得折叠区里出现「搜不到但看得见」的行。
    private var archivedEntries: [ListEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let entries = visibleArchivedSessions
            .map(ListEntry.session)
            .sorted { $0.sortTimestamp > $1.sortTimestamp }
        guard !needle.isEmpty else { return entries }
        return entries.filter { entry in
            guard case .session(let session) = entry else { return false }
            return TaskListPresentation.searchMatches(query, values: [session.displayTitle,
                TaskListPresentation.groupSearchText(WorkspaceSessionSummary(snapshot: session))])
        }
    }

    private func requestNewSession(cwd: String? = nil) {
        if let onRequestNewSession {
            onRequestNewSession(cwd)
        } else {
            newSessionInitialCwd = cwd
            showNewSession = true
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
            DesktopCopyWorkingDirectoryButton(cwd: session.cwd)
            Button {
                isSelecting = true
                selectedSessionIds.insert(session.id)
            } label: {
                Label("多选", systemImage: "checkmark.circle")
            }
            Button {
                Task { await setArchived(!(session.archived == true), sessions: [session]) }
            } label: {
                Label(
                    session.archived == true ? "恢复会话" : "归档会话",
                    systemImage: session.archived == true ? "tray.and.arrow.up" : "archivebox"
                )
            }
            .disabled(archiveInProgress)
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

    /// 直属会话按归档拆一次：归档项收进本层自己的折叠区，活动列表只留活跃会话。
    private var standaloneSplit: (active: [SessionSnapshot], archived: [SessionSnapshot]) {
        var active: [SessionSnapshot] = []
        var archived: [SessionSnapshot] = []
        for session in TaskListPresentation.standaloneSessions(
            sessions: sessions,
            groups: taskGroups,
            groupsAvailable: taskGroupsAvailable
        ) {
            if session.archived == true { archived.append(session) } else { active.append(session) }
        }
        return (active, archived)
    }

    private var archiveErrorPresented: Binding<Bool> {
        Binding(
            get: { archiveError != nil },
            set: { presented in
                if !presented { archiveError = nil }
            }
        )
    }

    private var visibleSessions: [SessionSnapshot] {
        standaloneSplit.active.filter {
            !activeOnly || TaskListPresentation.isActive(WorkspaceSessionSummary(snapshot: $0), selectedSessionId: selectedSessionId)
        }
    }

    private var visibleArchivedSessions: [SessionSnapshot] { activeOnly ? [] : standaloneSplit.archived }

    /// 归档 / 恢复。归档是软标记：不杀进程、不删历史，也不改任务归属。
    private func setArchived(_ archived: Bool, sessions targets: [SessionSnapshot]) async {
        guard !targets.isEmpty, !archiveInProgress else { return }
        archiveInProgress = true
        defer { archiveInProgress = false }
        do {
            let failed = try await api.batchArchiveWorkspaceSessions(
                sessionIds: targets.map(\.id),
                archived: archived
            )
            if !failed.isEmpty {
                archiveError = "有 \(failed.count) 个会话未能\(archived ? "归档" : "恢复")。"
            }
            await load(silent: true)
        } catch {
            archiveError = "无法\(archived ? "归档" : "恢复")会话：\(error.localizedDescription)"
        }
    }

    private var listedSessions: [SessionSnapshot] {
        listEntries.compactMap { entry in
            if case .session(let session) = entry { return session }
            return nil
        }
    }

    private var recoverableSessions: [HistorySession] {
        let managedIds = Set(sessions.compactMap(\.claudeSessionId))
        guard !activeOnly else { return [] }
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
                return TaskListPresentation.searchMatches(query, values: [session.displayTitle,
                    TaskListPresentation.groupSearchText(WorkspaceSessionSummary(snapshot: session))])
            case .recoverable(let history):
                return TaskListPresentation.searchMatches(query, values: [history.firstUserMessage, history.cwd])
            }
        }
    }

    @discardableResult
    private func load(silent: Bool = false) async -> Bool {
        loadGeneration &+= 1
        let generation = loadGeneration
        if !silent { loading = true }
        do {
            let probe = try await api.probeSessionList(
                revision: sessionListRevision.isEmpty ? nil : sessionListRevision
            )
            guard generation == loadGeneration, !Task.isCancelled else { return false }
            if silent, probe.unchanged == true {
                loading = false
                return true
            }
            let refreshedSessions = try await api.listSessions()
            guard generation == loadGeneration, !Task.isCancelled else { return false }
            sessions = refreshedSessions
            sessionListRevision = probe.revision
            if let selectedSessionId,
               let refreshed = listedSessions.first(where: { $0.id == selectedSessionId }) {
                onSessionSelected(refreshed)
            }
            // Older servers may still return imported history. Their optional
            // endpoints must not make a successful live-session refresh fail.
            let refreshedHistory = await api.refreshLegacyHistory(previous: historySessions)
            guard generation == loadGeneration, !Task.isCancelled else { return false }
            historySessions = refreshedHistory
            loadError = nil
            loading = false
            return true
        } catch {
            guard generation == loadGeneration, !Task.isCancelled else { return false }
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
        let selected = listedSessions.filter { selectedSessionIds.contains($0.id) }
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

    private func confirmPendingDeletion(_ target: PendingDeletion) {
        guard !deleteInProgress else { return }
        deleteInProgress = true
        self.pendingDeletion = nil

        switch target {
        case .sessions(let sessions):
            deleteSessions(sessions)
        case .history(let history):
            deleteHistory(history)
        }
    }

    /// 不做乐观删除：仅在请求成功后移除本地项目。批量请求逐个执行并收集失败项，
    /// 这样局部失败不会让用户误以为所有会话都已删除。
    private func deleteSessions(_ targets: [SessionSnapshot]) {
        guard !targets.isEmpty else {
            deleteInProgress = false
            return
        }

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

// MARK: - 会话 tile

enum SessionListDateLabel {
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

    /// 「刚完成」时不再并排显示状态点与时间，只保留完成提示 + 目录。
    private var showsStatusRow: Bool {
        isJustCompleted || prominentStatus || !recentTime.isEmpty
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
        if let identity = session.identityCaption {
            return [identity, folderName].compactMap { $0 }.joined(separator: " · ")
        }
        if session.providerLabel == "Wand Agent" {
            return [session.providerLabel, folderName].compactMap { $0 }.joined(separator: " · ")
        }
        return folderName ?? session.providerLabel
    }

    /// 完成但还没被明确打开看过；纯展示态，不改 runner 生命周期。
    private var isJustCompleted: Bool {
        SessionCompletion.isJustCompleted(
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
                    if let employeeID = session.employeeId {
                        ContactAvatar(id: employeeID, avatar: session.employeeAvatar ?? "", name: session.employeeName ?? "", provider: session.provider, size: 32)
                    } else {
                        BrandLogo(provider: provider, color: Theme.textPrimary).frame(width: 15, height: 15)
                    }
                }
            }
            .frame(width: session.employeeId == nil ? 18 : 32, height: session.employeeId == nil ? 18 : 32)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 5) {
                    if isJustCompleted {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(Theme.success)
                        Text("刚完成")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Theme.success)
                            .lineLimit(1)
                            .help("已完成，还没查看")
                    } else if prominentStatus {
                        Circle().fill(statusColor).frame(width: 5, height: 5)
                        Text(statusLabel)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(statusColor)
                            .lineLimit(1)
                    } else if !recentTime.isEmpty {
                        Text(recentTime)
                            .font(.system(size: 11, weight: .regular))
                            .foregroundColor(Theme.textMuted)
                    }
                    if !prominentStatus && recentTime.isEmpty {
                        Circle().fill(statusColor).frame(width: 5, height: 5)
                    }
                    if folderName != nil || session.identityCaption != nil || session.providerLabel == "Wand Agent" {
                        if showsStatusRow {
                            Text("·")
                                .foregroundColor(Theme.textMuted.opacity(0.7))
                        }
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundColor(Theme.textMuted)
                            .lineLimit(1)
                            .help([session.identityCaption ?? session.providerLabel, session.cwd].compactMap { $0 }.joined(separator: " · "))
                    } else if !prominentStatus && !isJustCompleted {
                        Text(statusLabel)
                            .font(.system(size: 11))
                            .foregroundColor(Theme.textMuted)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(minHeight: 48)
        .sidebarSelectionChrome(isSelected: isSelected && !isSelecting, isHovered: hovering)
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
            BrandLogo(provider: history.provider, color: Theme.textPrimary)
                .frame(width: 15, height: 15)
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(displayTitle)
                    .font(.system(size: 12.5, weight: .regular))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 5) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(Theme.providerColor(history.provider))
                    Text(dateText.isEmpty ? "可恢复" : "\(dateText) · 可恢复")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(Theme.textMuted)
                    if !history.cwd.isEmpty {
                        Text("·").foregroundColor(Theme.textMuted.opacity(0.55))
                        WandPathText(path: history.cwd, fontSize: 11, color: Theme.textMuted)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .frame(minHeight: 44)
        .sidebarSelectionChrome(isSelected: false, isHovered: hovering)
        .onHover { hovering = $0 }
    }
}

// MARK: - 中栏空态 + 中栏容器
