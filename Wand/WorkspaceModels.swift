import Foundation

enum WorkspaceSessionKind: String, CaseIterable, Identifiable {
    case structured
    case pty

    var id: String { rawValue }

    var title: String {
        switch self {
        case .structured: return "结构化"
        case .pty: return "PTY"
        }
    }

    var summary: String {
        switch self {
        case .structured: return "智能对话模式"
        case .pty: return "原始 CLI 终端"
        }
    }
}

enum WorkspaceSessionTarget: String, CaseIterable, Codable, Identifiable {
    case claude
    case codex
    case opencode
    case grok
    case qoder
    case pi
    case shell

    var id: String { rawValue }

    var provider: WandProvider? {
        self == .shell ? nil : WandProvider(rawValue: rawValue)
    }

    var title: String {
        provider?.title ?? "空白终端"
    }

    var summary: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "OpenAI Codex CLI"
        case .opencode: return "OpenCode CLI"
        case .grok: return "Grok Build CLI"
        case .qoder: return "Qoder CLI"
        case .pi: return "Pi coding agent"
        case .shell: return "不启动 Agent 的交互式 Shell"
        }
    }

    init(provider: WandProvider) {
        self = WorkspaceSessionTarget(rawValue: provider.rawValue) ?? .claude
    }
}

struct WorkspaceBinding: Equatable {
    let workspaceId: String
    let workspaceTaskId: String
    let cwd: String
}

/// Codable JSON used only to retain future pane-tab fields during a decode/encode round trip.
indirect enum WorkspaceJSONValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: WorkspaceJSONValue])
    case array([WorkspaceJSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([WorkspaceJSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: WorkspaceJSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }
}

enum PaneTab: Codable, Equatable, Identifiable {
    case session(id: String, sessionId: String)
    case editor(id: String, path: String)
    case preview(id: String, path: String)
    case unknown(id: String, kind: String, payload: [String: WorkspaceJSONValue])

    var id: String {
        switch self {
        case .session(let id, _), .editor(let id, _), .preview(let id, _), .unknown(let id, _, _):
            return id
        }
    }

    var sessionId: String? {
        if case .session(_, let sessionId) = self { return sessionId }
        return nil
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, sessionId, path
    }

    init(from decoder: Decoder) throws {
        let rawValue = try WorkspaceJSONValue(from: decoder)
        guard case .object(let payload) = rawValue else {
            self = .unknown(id: "unknown-tab", kind: "unknown", payload: [:])
            return
        }
        let id = payload["id"]?.stringValue ?? "unknown-tab"
        let kind = payload["kind"]?.stringValue ?? "unknown"
        switch kind {
        case "session":
            if let sessionId = payload["sessionId"]?.stringValue, !sessionId.isEmpty {
                self = .session(id: id, sessionId: sessionId)
            } else {
                self = .unknown(id: id, kind: kind, payload: payload)
            }
        case "editor":
            if let path = payload["path"]?.stringValue, !path.isEmpty {
                self = .editor(id: id, path: path)
            } else {
                self = .unknown(id: id, kind: kind, payload: payload)
            }
        case "preview":
            if let path = payload["path"]?.stringValue, !path.isEmpty {
                self = .preview(id: id, path: path)
            } else {
                self = .unknown(id: id, kind: kind, payload: payload)
            }
        default:
            self = .unknown(id: id, kind: kind, payload: payload)
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .session(let id, let sessionId):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode("session", forKey: .kind)
            try container.encode(sessionId, forKey: .sessionId)
        case .editor(let id, let path):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode("editor", forKey: .kind)
            try container.encode(path, forKey: .path)
        case .preview(let id, let path):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode("preview", forKey: .kind)
            try container.encode(path, forKey: .path)
        case .unknown(let id, let kind, var payload):
            payload["id"] = .string(id)
            payload["kind"] = .string(kind)
            try WorkspaceJSONValue.object(payload).encode(to: encoder)
        }
    }
}

indirect enum LayoutNode: Codable, Equatable {
    case pane(tabs: [PaneTab], active: Int)
    case split(direction: String, ratio: Double, first: LayoutNode, second: LayoutNode)

    private enum CodingKeys: String, CodingKey {
        case type, tabs, active, dir, ratio, children
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "pane":
            let tabs = (try? container.decode([PaneTab].self, forKey: .tabs)) ?? []
            let requested = (try? container.decode(Int.self, forKey: .active)) ?? 0
            self = .pane(tabs: tabs, active: min(max(0, requested), max(0, tabs.count - 1)))
        case "split":
            let direction = try container.decode(String.self, forKey: .dir)
            let children = try container.decode([LayoutNode].self, forKey: .children)
            guard children.count == 2 else {
                throw DecodingError.dataCorruptedError(
                    forKey: .children,
                    in: container,
                    debugDescription: "A split layout requires exactly two children"
                )
            }
            let ratio = (try? container.decode(Double.self, forKey: .ratio)) ?? 0.5
            self = .split(
                direction: direction,
                ratio: min(0.95, max(0.05, ratio)),
                first: children[0],
                second: children[1]
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown layout node"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pane(let tabs, let active):
            try container.encode("pane", forKey: .type)
            try container.encode(tabs, forKey: .tabs)
            try container.encode(active, forKey: .active)
        case .split(let direction, let ratio, let first, let second):
            try container.encode("split", forKey: .type)
            try container.encode(direction, forKey: .dir)
            try container.encode(ratio, forKey: .ratio)
            try container.encode([first, second], forKey: .children)
        }
    }
}

struct WorkWindowLayout: Codable, Equatable, Identifiable {
    let id: String
    let layout: LayoutNode
    let activeTabId: String?
}

struct TaskWindowLayout: Codable, Equatable {
    let type: String
    let windows: [WorkWindowLayout]
    let activeWindowId: String?

    private enum CodingKeys: String, CodingKey {
        case type, windows, activeWindowId
    }

    init(windows: [WorkWindowLayout], activeWindowId: String?) {
        type = "windows"
        self.windows = windows
        self.activeWindowId = activeWindowId
    }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: CodingKeys.self),
           (try? container.decode(String.self, forKey: .type)) == "windows" {
            type = "windows"
            windows = (try? container.decode([WorkWindowLayout].self, forKey: .windows)) ?? []
            activeWindowId = try? container.decodeIfPresent(String.self, forKey: .activeWindowId)
            return
        }

        // Old servers persisted a single LayoutNode directly.
        let legacy = try LayoutNode(from: decoder)
        type = "windows"
        windows = [WorkWindowLayout(id: "window-legacy", layout: legacy, activeTabId: nil)]
        activeWindowId = "window-legacy"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("windows", forKey: .type)
        try container.encode(windows, forKey: .windows)
        try container.encodeIfPresent(activeWindowId, forKey: .activeWindowId)
    }
}

struct Workspace: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let cwd: String
    let defaultProvider: WandProvider?
    let layout: LayoutNode?
    let createdAt: String
    let lastOpenedAt: String?
    /// v4.40+ 服务端附带；老服务端缺省时由任务列表推算。
    let worktreeCount: Int?
    let sessionCount: Int?

    init(
        id: String,
        name: String,
        cwd: String,
        defaultProvider: WandProvider?,
        layout: LayoutNode?,
        createdAt: String,
        lastOpenedAt: String?,
        worktreeCount: Int? = nil,
        sessionCount: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.cwd = cwd
        self.defaultProvider = defaultProvider
        self.layout = layout
        self.createdAt = createdAt
        self.lastOpenedAt = lastOpenedAt
        self.worktreeCount = worktreeCount
        self.sessionCount = sessionCount
    }
}

/// 与 Web WorkspaceSessionTeamChat / WorkspaceSessionTeamStep 的字段契约一致。
struct WorkspaceSessionTeamChat: Codable, Equatable {
    let teamId: String
    let runId: String
    let teamName: String
    let chatTitle: String?
    let memberCount: Int
}

struct WorkspaceSessionTeamStep: Codable, Equatable {
    let runId: String
    let stepId: String
    let kind: String
    let title: String
    let memberId: String
    let memberName: String
    let teamName: String
    let stepStatus: String
    let runStatus: String
    let runFinished: Bool
}

func sessionIdentityBadge(
    employeeId: String?, teamChat: WorkspaceSessionTeamChat?, teamStep: WorkspaceSessionTeamStep?
) -> String? {
    if teamChat != nil { return "群聊" }
    if teamStep != nil { return "团队" }
    return employeeId?.isEmpty == false ? "员工" : nil
}

func sessionIdentityCaption(
    employeeId: String?, employeeName: String?,
    teamChat: WorkspaceSessionTeamChat?, teamStep: WorkspaceSessionTeamStep?
) -> String? {
    if let teamChat { return "\(teamChat.teamName) · 群聊" }
    if let teamStep { return "\(teamStep.teamName) · \(teamStep.memberName)" }
    guard employeeId?.isEmpty == false else { return nil }
    return employeeName?.isEmpty == false ? employeeName : "员工会话"
}

struct WorkspaceSessionSummary: Codable, Equatable, Identifiable {
    var executionStatus: String? = nil
    let id: String
    let provider: String?
    let sessionKind: String?
    let runner: String?
    let engine: String?
    let employeeId: String?
    let employeeName: String?
    let employeeAvatar: String?
    let teamChat: WorkspaceSessionTeamChat?
    let teamStep: WorkspaceSessionTeamStep?
    let title: String?
    let status: String?
    let cwd: String?
    let startedAt: String?
    let workspaceTaskId: String?
    let ptyBusy: Bool?
    let providerCliActive: Bool?
    let inFlight: Bool?
    /// 归档是软标记：不杀进程、不删历史，只是把它收进每层自己的「已归档会话」折叠区。
    let archived: Bool?
    let archivedAt: String?
    let completionRevision: Int?
    let viewedCompletionRevision: Int?

    init(snapshot: SessionSnapshot) {
        id = snapshot.id
        provider = snapshot.provider
        sessionKind = snapshot.sessionKind
        runner = snapshot.runner
        engine = snapshot.engine ?? snapshot.structuredState?.engine
        employeeId = snapshot.employeeId
        employeeName = snapshot.employeeName
        employeeAvatar = snapshot.employeeAvatar
        teamChat = snapshot.teamChat
        teamStep = snapshot.teamStep
        title = snapshot.title
        status = snapshot.status
        cwd = snapshot.cwd
        startedAt = snapshot.startedAt
        workspaceTaskId = snapshot.workspaceTaskId
        ptyBusy = snapshot.ptyBusy
        providerCliActive = snapshot.providerCliActive
        inFlight = snapshot.structuredState?.inFlight
        executionStatus = snapshot.structuredState?.inFlight != true && snapshot.archived != true
            && snapshot.status != "failed" && snapshot.structuredState?.lastError == nil
            && !(snapshot.queuedMessages ?? []).isEmpty ? "queued" : nil
        archived = snapshot.archived
        archivedAt = snapshot.archivedAt
        completionRevision = snapshot.completionRevision
        viewedCompletionRevision = snapshot.viewedCompletionRevision
    }

    /// 列表只展示活跃会话；归档项由调用方拆进折叠区（对齐 Web `splitArchivedSessions`）。
    /// 在这里分一次而不是每处渲染时过滤，避免「归档了却仍出现在活跃列表」的两套口径。
    static func splitArchived(
        _ sessions: [WorkspaceSessionSummary]
    ) -> (active: [WorkspaceSessionSummary], archived: [WorkspaceSessionSummary]) {
        var active: [WorkspaceSessionSummary] = []
        var archived: [WorkspaceSessionSummary] = []
        for session in sessions {
            if session.archived == true { archived.append(session) } else { active.append(session) }
        }
        return (active, archived)
    }

    var activityStatus: String {
        if archived != true && inFlight != true && ptyBusy != true && status != "failed" && executionStatus == "queued" { return "queued" }
        return effectiveSessionStatus(
            sessionKind: sessionKind,
            status: status,
            provider: provider,
            ptyBusy: ptyBusy,
            providerCliActive: providerCliActive,
            inFlight: inFlight
        )
    }

    var providerLabel: String {
        guard let provider, !provider.isEmpty else { return "终端" }
        return WandProvider.title(for: provider, engine: engine)
    }

    var identityBadge: String? {
        sessionIdentityBadge(employeeId: employeeId, teamChat: teamChat, teamStep: teamStep)
    }

    var identityCaption: String? {
        sessionIdentityCaption(employeeId: employeeId, employeeName: employeeName, teamChat: teamChat, teamStep: teamStep)
    }

    /// 完成但还没被明确打开看过。纯展示态，不改会话的 idle/running/exited。
    var isJustCompleted: Bool {
        SessionCompletion.isJustCompleted(
            completion: completionRevision,
            viewed: viewedCompletionRevision,
            status: status,
            archived: archived,
            ptyBusy: ptyBusy,
            inFlight: inFlight,
            permissionBlocked: nil,
            pendingEscalation: nil,
            providerCliExitCode: nil
        )
    }
}

struct WorkspaceTaskWorktree: Codable, Equatable {
    let branch: String
    let path: String
    let baseRef: String?
    let repoRoot: String?
}

struct WorkspaceTask: Codable, Equatable, Identifiable {
    let id: String
    let workspaceId: String
    let name: String
    let worktree: WorkspaceTaskWorktree?
    let layout: TaskWindowLayout?
    let status: String
    let createdAt: String
    let lastOpenedAt: String?
}

/// GET /api/tasks 聚合行：任务 + 运行期派生字段；目录信息在 TaskDirectoryGroup 上。
struct WorkspaceTaskSummary: Codable, Equatable, Identifiable {
    var executionStatus: String? = nil
    var queuedExecutionCount: Int? = nil
    var hasQueuedExecution: Bool { executionStatus == "queued" }
    var hasActiveExecution: Bool { executionStatus == "queued" || executionStatus == "running" }
    var parentWorkspaceTaskId: String? = nil
    let id: String
    let workspaceId: String
    let name: String
    let worktree: WorkspaceTaskWorktree?
    let layout: TaskWindowLayout?
    let status: String
    let createdAt: String
    let lastOpenedAt: String?
    let cwd: String
    let isolated: Bool?
    let worktreeError: String?
    let sessions: [WorkspaceSessionSummary]
    let totalSessions: Int?
    let archived: Bool?

    var isIsolated: Bool { isolated ?? (worktree != nil) }
    var listedSessionCount: Int { totalSessions ?? sessions.count }

    init(
        id: String,
        workspaceId: String,
        name: String,
        worktree: WorkspaceTaskWorktree?,
        layout: TaskWindowLayout?,
        status: String,
        createdAt: String,
        lastOpenedAt: String?,
        cwd: String,
        isolated: Bool?,
        worktreeError: String?,
        sessions: [WorkspaceSessionSummary],
        totalSessions: Int? = nil,
        archived: Bool? = nil,
        parentWorkspaceTaskId: String? = nil,
        executionStatus: String? = nil,
        queuedExecutionCount: Int? = nil
    ) {
        self.parentWorkspaceTaskId = parentWorkspaceTaskId
        self.id = id
        self.workspaceId = workspaceId
        self.name = name
        self.worktree = worktree
        self.layout = layout
        self.status = status
        self.createdAt = createdAt
        self.lastOpenedAt = lastOpenedAt
        self.cwd = cwd
        self.isolated = isolated
        self.worktreeError = worktreeError
        self.sessions = sessions
        self.totalSessions = totalSessions ?? sessions.count
        self.executionStatus = executionStatus
        self.queuedExecutionCount = queuedExecutionCount
        self.archived = archived
    }

    func asTask() -> WorkspaceTask {
        WorkspaceTask(
            id: id,
            workspaceId: workspaceId,
            name: name,
            worktree: worktree,
            layout: layout,
            status: status,
            createdAt: createdAt,
            lastOpenedAt: lastOpenedAt
        )
    }
}

/// 目录组一级容器：任务归属目录；未绑定任务的会话归入 standaloneSessions。
/// synthetic 表示该目录没有项目实体，仅用于展示。
struct TaskDirectoryGroup: Codable, Equatable, Identifiable {
    let workspaceId: String
    let workspaceName: String
    let workspaceCwd: String
    let synthetic: Bool?
    let tasks: [WorkspaceTaskSummary]
    let standaloneSessions: [WorkspaceSessionSummary]

    let global: Bool?

    var id: String { workspaceId }
    var isSynthetic: Bool { synthetic ?? false }
    var isGlobal: Bool { global ?? false }
    var displayName: String { isGlobal ? "未归属工作区" : workspaceName }

    init(workspaceId: String, workspaceName: String, workspaceCwd: String, synthetic: Bool?,
         tasks: [WorkspaceTaskSummary], standaloneSessions: [WorkspaceSessionSummary], global: Bool? = nil) {
        self.workspaceId = workspaceId
        self.workspaceName = workspaceName
        self.workspaceCwd = workspaceCwd
        self.synthetic = synthetic
        self.tasks = tasks
        self.standaloneSessions = standaloneSessions
        self.global = global
    }
}


struct TaskGroupsPage: Equatable {
    let groups: [TaskDirectoryGroup]
    let revision: String?
    let unchanged: Bool

    static func decode(from data: Data) throws -> TaskGroupsPage {
        let object = try JSONSerialization.jsonObject(with: data)
        if let array = object as? [Any] {
            let encoded = try JSONSerialization.data(withJSONObject: array)
            let groups = try JSONDecoder().decode([TaskDirectoryGroup].self, from: encoded)
            return TaskGroupsPage(groups: groups, revision: nil, unchanged: false)
        }
        guard let dict = object as? [String: Any] else {
            throw NSError(domain: "Wand", code: 1, userInfo: [NSLocalizedDescriptionKey: "任务列表响应无效"])
        }
        let unchanged = dict["unchanged"] as? Bool ?? false
        let revision = dict["revision"] as? String
        let groups: [TaskDirectoryGroup]
        if let raw = dict["groups"] {
            let encoded = try JSONSerialization.data(withJSONObject: raw)
            groups = try JSONDecoder().decode([TaskDirectoryGroup].self, from: encoded)
        } else {
            groups = []
        }
        return TaskGroupsPage(groups: groups, revision: revision, unchanged: unchanged)
    }
}


struct SessionBatchDeleteResponse: Decodable {
    let deleted: Int?
}

/// 「刚完成」的判定与确认口径，对齐服务端 `src/session-completion-state.ts`
/// 与 Web `markSessionCompletionViewed`。这是**纯展示态**：不改 runner 的
/// idle/running/exited，不影响输入资格，也不因为读了列表就消耗掉。
enum SessionCompletion {
    /// 迟到的 HTTP/WS 投影可以推进代次，但不能把代次拉回去。
    static func merge(
        current: (completion: Int, viewed: Int),
        incoming: (completion: Int?, viewed: Int?)
    ) -> (completion: Int, viewed: Int) {
        (
            max(current.completion, incoming.completion ?? 0),
            max(current.viewed, incoming.viewed ?? 0)
        )
    }

    static func isJustCompleted(
        completion: Int?,
        viewed: Int?,
        status: String?,
        archived: Bool?,
        ptyBusy: Bool?,
        inFlight: Bool?,
        permissionBlocked: Bool?,
        pendingEscalation: Bool?,
        providerCliExitCode: Int?
    ) -> Bool {
        guard (completion ?? 0) > (viewed ?? 0) else { return false }
        guard archived != true, ptyBusy != true, inFlight != true else { return false }
        guard permissionBlocked != true, pendingEscalation != true else { return false }
        // CLI 非零退出是失败，不算「完成但还没看」。
        if let code = providerCliExitCode, code != 0 { return false }
        return ["idle", "running", "exited"].contains(status ?? "")
    }

    /// 只有「用户明确打开且这一代结果真的在屏幕上」才确认。
    /// 自动选中、后台轮询、重连、切服务器都不算。
    static func shouldAcknowledge(
        isJustCompleted: Bool,
        explicitOpen: Bool,
        isSelected: Bool,
        modalVisible: Bool
    ) -> Bool {
        isJustCompleted && explicitOpen && isSelected && !modalVisible
    }
}

/// `POST /api/sessions/batch-archive` 的响应：`failed` 缺省即全部成功。
struct SessionBatchArchiveResponse: Decodable {
    let archived: Int?
    let failed: [String]?
}

/// `POST /api/sessions/:id/completion/view` 的响应：回带确认后的两个代次。
struct SessionCompletionResponse: Decodable {
    let completionRevision: Int?
    let viewedCompletionRevision: Int?
}

enum TaskListPresentation {
    static func searchMatches(_ query: String, values: [String?]) -> Bool {
        let words = query.lowercased().split(whereSeparator: { $0.isWhitespace })
        let text = values.compactMap { $0 }.joined(separator: " ").lowercased()
        return words.allSatisfy { text.contains($0) }
    }

    static func groupSearchText(_ session: WorkspaceSessionSummary) -> String {
        [session.title, session.providerLabel, session.cwd, session.employeeName,
         session.teamChat?.teamName, session.teamStep?.teamName, session.teamStep?.memberName]
            .compactMap { $0 }.joined(separator: " ")
    }

    static func isActive(_ session: WorkspaceSessionSummary, selectedSessionId: String?) -> Bool {
        guard session.archived != true else { return false }
        return session.executionStatus == "queued" || session.ptyBusy == true || session.inFlight == true || session.isJustCompleted
            || (session.sessionKind == "pty" && ["", "shell"].contains(session.provider ?? "") && session.providerCliActive == true)
            || ["thinking", "failed", "waiting-input", "waiting_input", "permission-blocked", "permission", "reconnecting"].contains(session.status ?? "")
    }

    /// Open newly discovered populated directories once; polling never reopens a user's fold.
    static func discoverDirectories(_ groups: [TaskDirectoryGroup], known: inout Set<String>, expanded: inout Set<String>) {
        for group in groups where !known.contains(group.id) {
            known.insert(group.id)
            if !group.tasks.isEmpty || !group.standaloneSessions.isEmpty { expanded.insert(group.id) }
        }
    }

    static func sidebarSessions(_ sessions: [WorkspaceSessionSummary]) -> [WorkspaceSessionSummary] {
        sessions.filter { DesktopGroupChatPresentation.isVisible || $0.teamChat == nil }
    }

    static func sidebarSessionCount(_ task: WorkspaceTaskSummary) -> Int {
        DesktopGroupChatPresentation.isVisible ? task.listedSessionCount : sidebarSessions(task.sessions).count
    }

    static func sidebarDirectoryGroups(_ groups: [TaskDirectoryGroup], workspaces: [Workspace], query: String,
                                       activeOnly: Bool, selectedSessionId: String?, selectedTaskId: String?) -> [TaskDirectoryGroup] {
        return groups.compactMap { group in
            let candidates = group.tasks
            let matching = candidates.filter { task in
                let sessions = sidebarSessions(task.sessions)
                return task.archived != true && task.status != "done" &&
                (!activeOnly || task.hasActiveExecution || sessions.contains { isActive($0, selectedSessionId: selectedSessionId) }) &&
                (task.hasActiveExecution || task.sessions.count > 0 || (task.id == selectedTaskId) || !query.isEmpty) &&
                searchMatches(query, values: [group.displayName, group.workspaceCwd, task.name, task.cwd] + sessions.map { groupSearchText($0) })
            }
            var keep = Set(matching.map(\.id))
            for task in matching {
                var parent = task.parentWorkspaceTaskId
                var seen = Set<String>()
                while let id = parent, !seen.contains(id) {
                    seen.insert(id); keep.insert(id)
                    parent = candidates.first { $0.id == id }?.parentWorkspaceTaskId
                }
            }
            let sessions = sidebarSessions(group.standaloneSessions).filter { ($0.archived != true || !query.isEmpty) && (!activeOnly || isActive($0, selectedSessionId: selectedSessionId)) && searchMatches(query, values: [groupSearchText($0), group.displayName, group.workspaceCwd]) }
            let tasks = candidates.filter { keep.contains($0.id) }
            guard !tasks.isEmpty || !sessions.isEmpty else { return nil }
            return TaskDirectoryGroup(workspaceId: group.workspaceId, workspaceName: group.workspaceName,
                workspaceCwd: group.workspaceCwd, synthetic: group.synthetic, tasks: tasks,
                standaloneSessions: sessions, global: group.global)
        }.sorted { !$0.isGlobal && $1.isGlobal }
    }

    /// A directory grouping key (including cwd:...) is not a task's execution owner.
    static func workspaceForTask(_ task: WorkspaceTaskSummary, group: TaskDirectoryGroup, workspaces: [Workspace]) -> Workspace {
        workspaces.first { $0.id == task.workspaceId } ?? Workspace(
            id: task.workspaceId, name: group.displayName, cwd: group.workspaceCwd,
            defaultProvider: nil, layout: nil, createdAt: "", lastOpenedAt: nil)
    }

    static func workspaceLabel(_ group: TaskDirectoryGroup) -> String? {
        guard !group.isGlobal, group.workspaceId != "wand-global" else { return nil }
        let name = group.workspaceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = name.isEmpty ? group.workspaceCwd.trimmingCharacters(in: .whitespacesAndNewlines) : name
        return value.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init)
    }

    struct RecentEntry: Identifiable {
        let group: TaskDirectoryGroup
        let task: WorkspaceTaskSummary?
        let session: WorkspaceSessionSummary
        var id: String { session.id }
    }

    struct RecentGroup: Identifiable {
        let id: String
        let title: String
        let entries: [RecentEntry]
    }

    static func recentGroups(_ groups: [TaskDirectoryGroup], query: String, activeOnly: Bool,
                             selectedSessionId: String?) -> [RecentGroup] {
        var seen = Set<String>()
        var entries: [RecentEntry] = []
        for group in groups {
            for task in group.tasks where task.status != "done" && task.archived != true {
                entries += task.sessions.map { RecentEntry(group: group, task: task, session: $0) }
            }
            entries += group.standaloneSessions.map { RecentEntry(group: group, task: nil, session: $0) }
        }
        entries = entries.filter { entry in
            (DesktopGroupChatPresentation.isVisible || entry.session.teamChat == nil) && entry.session.archived != true && seen.insert(entry.id).inserted
        }.sorted { left, right in
            let a = left.session.startedAt ?? "", b = right.session.startedAt ?? ""
            return a == b ? left.id < right.id : a > b
        }
        var keys: [String] = []
        var buckets: [String: [RecentEntry]] = [:]
        var titles: [String: String] = [:]
        for entry in entries {
            let session = entry.session
            let key: String, title: String
            if let employee = session.employeeId, !employee.isEmpty {
                key = "employee:\(employee)"; title = session.employeeName ?? "员工"
            } else if let team = session.teamChat {
                key = "team:\(team.teamId)"; title = team.teamName
            } else if let step = session.teamStep {
                key = "team-run:\(step.runId)"; title = step.teamName
            } else if session.sessionKind == "pty" {
                let blank = (session.provider ?? "").isEmpty || session.provider == "shell"
                key = blank ? "blank-terminal" : "terminal"; title = blank ? "空白终端" : "PTY 终端"
            } else {
                key = "cli:\(session.provider ?? "")"; title = session.providerLabel
            }
            if buckets[key] == nil { keys.append(key); titles[key] = title; buckets[key] = [] }
            if (!activeOnly || isActive(session, selectedSessionId: selectedSessionId))
                && searchMatches(query, values: [groupSearchText(session), entry.task?.name, entry.group.displayName, entry.group.workspaceCwd]) {
                buckets[key, default: []].append(entry)
            }
        }
        keys = keys.filter { $0 != "terminal" && $0 != "blank-terminal" }
            + ["terminal", "blank-terminal"].filter { buckets[$0] != nil }
        return keys.compactMap { key in
            guard let entries = buckets[key], !entries.isEmpty else { return nil }
            return RecentGroup(id: key, title: titles[key] ?? "会话", entries: entries)
        }
    }

    /// Use the complete task tree, before search or presentation limits are applied.
    static func standaloneSessions(
        sessions: [SessionSnapshot],
        groups: [TaskDirectoryGroup],
        groupsAvailable: Bool
    ) -> [SessionSnapshot] {
        let visibleSessions = sessions.filter { DesktopGroupChatPresentation.isVisible || $0.teamChat == nil }
        guard groupsAvailable else { return visibleSessions }
        let tasks = groups.flatMap(\.tasks)
        let taskIds = Set(tasks.map(\.id))
        let ownedSessionIds = Set(tasks.flatMap { $0.sessions.map(\.id) })
        let standaloneIds = Set(groups.flatMap { $0.standaloneSessions.map(\.id) })
        return visibleSessions.filter { session in
            if ownedSessionIds.contains(session.id) { return false }
            // The task response may be newer than the cached session's membership.
            if standaloneIds.contains(session.id) { return true }
            let taskId = session.workspaceTaskId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return !taskIds.contains(taskId)
        }
    }

    static func filteredDirectoryGroups(_ groups: [TaskDirectoryGroup], query: String) -> [TaskDirectoryGroup] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        func matches(_ values: String?...) -> Bool { searchMatches(query, values: values) }
        func matchesSession(_ session: WorkspaceSessionSummary) -> Bool {
            matches(groupSearchText(session))
        }
        return groups.compactMap { group in
            guard !group.tasks.isEmpty || !group.standaloneSessions.isEmpty else { return nil }
            if needle.isEmpty || matches(group.displayName, group.workspaceCwd) {
                return group
            }
            // Search selects whole tasks, never a partial destructive-action scope.
            let tasks = group.tasks.filter { task in
                searchMatches(query, values: [group.displayName, task.name, task.cwd]
                    + task.sessions.map { groupSearchText($0) })
            }
            let standaloneSessions = matches("\(group.workspaceName) - 未分组任务")
                ? group.standaloneSessions : group.standaloneSessions.filter(matchesSession)
            guard !tasks.isEmpty || !standaloneSessions.isEmpty else { return nil }
            return TaskDirectoryGroup(
                workspaceId: group.workspaceId, workspaceName: group.workspaceName,
                workspaceCwd: group.workspaceCwd, synthetic: group.synthetic,
                tasks: tasks, standaloneSessions: standaloneSessions, global: group.global
            )
        }
    }

    static func shortenWorkspacePath(_ path: String) -> String {
        let normalized = path.replacingOccurrences(of: "\\", with: "/").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let rooted = path.hasPrefix("/")
        let parts = normalized.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        if parts.count <= 2 {
            let joined = parts.joined(separator: "/")
            return rooted ? "/\(joined)" : (joined.isEmpty ? path : joined)
        }
        return "…/\(parts.suffix(2).joined(separator: "/"))"
    }

    static func directoryPathCaption(name: String, cwd: String) -> String? {
        let shortened = shortenWorkspacePath(cwd)
        if shortened.isEmpty || shortened == name { return nil }
        return shortened
    }

    static func taskIsolationCaption(isolated: Bool) -> String? {
        isolated ? "隔离" : nil
    }

    static func showsDirectoryDisclosure(directoryCount: Int) -> Bool {
        directoryCount > 0
    }

    static func showsTaskSessionDisclosure(sessionCount: Int) -> Bool {
        sessionCount > 0
    }

    static func isDirectoryExpanded(userCollapsed: Bool, directoryCount: Int, isSearching: Bool = false) -> Bool {
        directoryCount > 0 && (isSearching || !userCollapsed)
    }

    /// 无终端的任务默认折叠、不显示空提示；只有当它是目录里唯一任务（或搜索命中）时才展开引导创建首个会话。
    static func isTaskSessionsExpanded(
        userCollapsed: Bool,
        sessionCount: Int,
        isSearching: Bool = false,
        isOnlyTask: Bool = false
    ) -> Bool {
        guard showsTaskSessionDisclosure(sessionCount: sessionCount) else { return isSearching || isOnlyTask }
        return isSearching || !userCollapsed
    }

    struct ManageSelection: Equatable {
        var taskIds: Set<String> = []
        var sessionIds: Set<String> = []
        var count: Int { taskIds.count + sessionIds.count }
        var isEmpty: Bool { count == 0 }
    }

    static func collectManagedIds(_ groups: [TaskDirectoryGroup]) -> ManageSelection {
        var taskIds = Set<String>()
        var sessionIds = Set<String>()
        for group in groups {
            for task in group.tasks {
                taskIds.insert(task.id)
                task.sessions.forEach { sessionIds.insert($0.id) }
            }
            group.standaloneSessions.forEach { sessionIds.insert($0.id) }
        }
        return ManageSelection(taskIds: taskIds, sessionIds: sessionIds)
    }

    static func resolveManagedDeletion(
        _ selection: ManageSelection,
        groups: [TaskDirectoryGroup]
    ) -> ManageSelection {
        let owned = Set(groups.flatMap(\.tasks).filter { selection.taskIds.contains($0.id) }.flatMap { $0.sessions.map(\.id) })
        return ManageSelection(
            taskIds: selection.taskIds,
            sessionIds: selection.sessionIds.filter { !owned.contains($0) }
        )
    }

    static func describeManagedDeletion(_ selection: ManageSelection) -> String {
        var parts: [String] = []
        if !selection.taskIds.isEmpty { parts.append("\(selection.taskIds.count) 个任务") }
        if !selection.sessionIds.isEmpty { parts.append("\(selection.sessionIds.count) 个终端") }
        return parts.isEmpty ? "所选项目" : parts.joined(separator: "和")
    }

    /// 占位标题（空 / 会话 / 裸 CLI 名 / 「CLI N」）不是会话标题。
    private static let placeholderSessionTitles: Set<String> = [
        "会话", "wand 会话", "claude", "codex", "opencode", "grok", "qoder", "pi", "终端",
    ]

    static func isPlaceholderSessionTitle(_ title: String) -> Bool {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.isEmpty || placeholderSessionTitles.contains(normalized) { return true }
        return normalized.range(
            of: #"^(claude|codex|opencode|grok|qoder|pi|终端)\s+\d+$"#,
            options: .regularExpression
        ) != nil
    }

    /// 旧版终端把 cwd 末段当标题：目录名不算会话标题。
    private static func isDirectoryFallbackTitle(_ title: String, cwd: String?) -> Bool {
        let leaf = (cwd ?? "").replacingOccurrences(of: "\\", with: "/").split(separator: "/").map(String.init).last ?? ""
        return !leaf.isEmpty && leaf.caseInsensitiveCompare(title) == .orderedSame
    }

    /// 有会话标题就显示标题（和任务名重复也照显示）；只有占位标题或目录名兜底时才回退「CLI 序号」。
    static func listSessionLabel(
        title: String?,
        providerLabel: String,
        cwd: String?,
        index: Int
    ) -> String {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty, !isPlaceholderSessionTitle(trimmed), !isDirectoryFallbackTitle(trimmed, cwd: cwd) {
            return trimmed
        }
        return "\(providerLabel) \(index + 1)"
    }
}

struct WorkspaceTaskDetail: Codable, Equatable, Identifiable {
    let id: String
    let workspaceId: String
    let name: String
    let worktree: WorkspaceTaskWorktree?
    let layout: TaskWindowLayout?
    let status: String
    let createdAt: String
    let lastOpenedAt: String?
    let cwd: String
    let isolated: Bool?
    let worktreeError: String?
    let sessions: [WorkspaceSessionSummary]

    var isIsolated: Bool { isolated ?? (worktree != nil) }

    func replacing(
        layout: TaskWindowLayout?,
        sessions: [WorkspaceSessionSummary]? = nil
    ) -> WorkspaceTaskDetail {
        WorkspaceTaskDetail(
            id: id,
            workspaceId: workspaceId,
            name: name,
            worktree: worktree,
            layout: layout,
            status: status,
            createdAt: createdAt,
            lastOpenedAt: lastOpenedAt,
            cwd: cwd,
            isolated: isolated,
            worktreeError: worktreeError,
            sessions: sessions ?? self.sessions
        )
    }
}
