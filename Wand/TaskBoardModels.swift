import Foundation
import SwiftUI

// MARK: - 任务归类（服务端为范围与归属的事实源）

enum WandTaskOrganizationMode: String, CaseIterable, Identifiable {
    case auto, all
    var id: String { rawValue }
    var label: String { self == .auto ? "默认范围会话" : "所有工作会话" }
    var hint: String { self == .auto ? "未分组及系统任务中的工作会话，不挪人工任务会话" : "包括人工任务会话，仍排除归档、私聊、自动化和系统日志" }
}

enum WandTaskOrganizationTarget: Equatable {
    case all
    case workspace(String)
    case directory(String)

    var jsonObject: [String: String] {
        switch self {
        case .all: return ["kind": "all"]
        case .workspace(let id): return ["kind": "workspace", "workspaceId": id]
        case .directory(let cwd): return ["kind": "directory", "cwd": cwd]
        }
    }

    static func directoryGroup(_ group: TaskDirectoryGroup) -> Self {
        group.isSynthetic || group.isGlobal ? .directory(group.workspaceCwd) : .workspace(group.workspaceId)
    }
}

struct WandConversationOrganizationPreview: Decodable {
    let token: String
    let sessionCount: Int
    let manualSessionCount: Int
    let skippedSessionCount: Int
    let existingTaskCount: Int
    let contentCharacters: Int
    let estimatedModelRequests: Int
    let unchanged: Bool
    let activeJobId: String?
}
struct WandConversationOrganizationPreparation: Decodable { let preview: WandConversationOrganizationPreview }
struct WandConversationOrganizationJob: Decodable {
    let id: String
    let status: String
    let stage: String
    let processedSessions: Int
    let totalSessions: Int
    let modelRequests: Int
    let result: WandTaskOrganizationResult
    let logSessionId: String?
    let error: String?
}
struct WandConversationOrganizationJobResponse: Decodable { let job: WandConversationOrganizationJob }

struct WandTaskOrganizationResult: Decodable {
    struct SessionMove: Decodable { let sessionId: String }
    struct TaskParent: Decodable { let taskId: String }
    struct Refusal: Decodable { let reason: String }
    let foundTasks: Int?
    let eligibleTasks: Int?
    let skippedTasks: Int?
    let movedSessions: [SessionMove]
    let categorizedTasks: [TaskParent]?
    let refused: [Refusal]
    let eligibleSessions: Int?
    let analyzedSessions: Int?
    let skippedManualSessions: Int?
    let skippedSessions: Int?
    let createdTasks: [TaskParent]?
    let reusedTasks: [TaskParent]?
    let updatedTasks: [TaskParent]?
    let unassignedSessions: [SessionMove]?
    let unchanged: Bool?
    let cancelled: Bool?
    let error: String?

    var label: String {
        var changes: [String] = []
        if let eligibleSessions {
            if unchanged == true { return "内容和归属未变化，没有重复建任务或调用模型" }
            if let createdTasks, !createdTasks.isEmpty { changes.append("新建 \(createdTasks.count) 个任务") }
            if let updatedTasks, !updatedTasks.isEmpty { changes.append("更新 \(updatedTasks.count) 个系统任务标题") }
            if let reusedTasks, !reusedTasks.isEmpty { changes.append("复用 \(Set(reusedTasks.map(\.taskId)).count) 个任务") }
            if !movedSessions.isEmpty { changes.append("归入 \(movedSessions.count) 个会话") }
            if !changes.isEmpty { return (cancelled == true || error != nil ? "部分完成：" : "已") + changes.joined(separator: "、") }
            if error != nil { return "会话归类未完成" }
            if cancelled == true { return "已取消后续归类" }
            return eligibleSessions == 0 ? "没有符合范围且有正文的工作会话" : "会话尚未得到明确工作分组，本次未作调整"
        }
        if let categorizedTasks, !categorizedTasks.isEmpty { changes.append("归类 \(categorizedTasks.count) 个任务") }
        if !movedSessions.isEmpty { changes.append("归属 \(movedSessions.count) 个会话") }
        if !changes.isEmpty { return "已" + changes.joined(separator: "、") }
        if !refused.isEmpty { return "未调整任何任务或会话" }
        return eligibleTasks == 0 ? "没有符合归类范围的任务" : "未发现可安全归类的项"
    }

    var detail: String {
        var parts: [String] = []
        if let eligibleSessions {
            parts.append("已检查 \(analyzedSessions ?? 0)/\(eligibleSessions) 个工作会话")
            if let skippedManualSessions, skippedManualSessions > 0 { parts.append("跳过 \(skippedManualSessions) 个人工任务会话") }
            if let skippedSessions, skippedSessions > 0 { parts.append("排除 \(skippedSessions) 个归档/私聊/系统记录或无正文会话") }
            if let unassignedSessions, !unassignedSessions.isEmpty { parts.append("\(unassignedSessions.count) 个会话未确定主题") }
            if let first = refused.first { parts.append(first.reason) }
            if let error { parts.append(error) }
            return parts.joined(separator: "；")
        }
        if let eligibleTasks { parts.append("已检查 \(eligibleTasks) 个任务") }
        if let skippedTasks, skippedTasks > 0 { parts.append("已跳过 \(skippedTasks) 个用户自定标题的任务") }
        if let first = refused.first {
            let hasChanges = !movedSessions.isEmpty || categorizedTasks?.isEmpty == false
            parts.append(hasChanges ? "另有 \(refused.count) 项未处理：\(first.reason)" : first.reason)
        }
        return parts.joined(separator: "；")
    }
}

// MARK: - 派发 Agent 配置

/**
 * 任务派发时的工作模式。只开放三种：托管（全自动）/ 全限（自动确认权限）/ 标准（逐步确认）。
 * 与 Web `ISSUE_AGENT_MODES` 一一对应；`auto-edit` / `native` 属于新建会话的高级选项，不进任务看板。
 */
enum WandBoardAgentMode: String, CaseIterable, Identifiable {
    case managed
    case fullAccess = "full-access"
    case standard = "default"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .managed: return "托管"
        case .fullAccess: return "全限"
        case .standard: return "标准"
        }
    }

    var detail: String {
        switch self {
        case .managed: return "全自动完成任务，不再逐条确认"
        case .fullAccess: return "自动确认权限，适合确认环境后的连续修改"
        case .standard: return "逐步确认操作"
        }
    }

    /// 各 provider 实际支持的工作模式：Codex 只有全限一个有效值。
    static func supported(provider: String) -> [WandBoardAgentMode] {
        provider == "codex" ? [.fullAccess] : allCases
    }

    /// 把任意（含旧数据 / 其它客户端缺省的）模式夹到该 provider 真正支持的值。
    static func normalize(provider: String, value: String?) -> String {
        let supported = supported(provider: provider)
        if let value, let mode = WandBoardAgentMode(rawValue: value), supported.contains(mode) {
            return mode.rawValue
        }
        if supported.contains(.standard) { return WandBoardAgentMode.standard.rawValue }
        return supported.first?.rawValue ?? WandBoardAgentMode.standard.rawValue
    }

    static func label(forValue value: String?) -> String {
        WandBoardAgentMode(rawValue: value ?? "")?.label ?? WandBoardAgentMode.standard.label
    }
}

/// 派发出来的会话形态；与任务详情里的会话列表一致。
enum WandBoardAgentKind: String, CaseIterable, Identifiable {
    case structured
    case pty

    var id: String { rawValue }
    var label: String { self == .pty ? "CLI 终端" : "结构化对话" }

    static func normalize(_ value: String?) -> String {
        WandBoardAgentKind(rawValue: value ?? "")?.rawValue ?? WandBoardAgentKind.structured.rawValue
    }
}

struct WandBoardTaskAgent: Codable, Equatable {
    var provider: String
    var model: String
    var thinkingEffort: String
    var mode: String
    var kind: String
    var engine: String?
    var toolKey: String { provider + ":" + (engine ?? "cli") }

    static let `default` = WandBoardTaskAgent(
        provider: "claude",
        model: "default",
        thinkingEffort: "off",
        mode: WandBoardAgentMode.standard.rawValue,
        kind: WandBoardAgentKind.structured.rawValue
    )

    init(
        provider: String,
        model: String,
        thinkingEffort: String,
        mode: String = "default",
        kind: String = "structured",
        engine: String? = nil
    ) {
        self.provider = provider
        self.model = model
        self.thinkingEffort = thinkingEffort
        self.mode = WandBoardAgentMode.normalize(provider: provider, value: mode)
        self.kind = WandBoardAgentKind.normalize(kind)
        self.engine = engine
    }

    private enum CodingKeys: String, CodingKey { case provider, model, thinkingEffort, mode, kind, engine }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // 老服务端不返回 mode / kind：按标准模式 + 结构化会话兜底，避免解码整条任务失败。
        self.init(
            provider: (try? container.decode(String.self, forKey: .provider)) ?? "claude",
            model: (try? container.decode(String.self, forKey: .model)) ?? "default",
            thinkingEffort: (try? container.decode(String.self, forKey: .thinkingEffort)) ?? "off",
            mode: (try? container.decode(String.self, forKey: .mode)) ?? "default",
            kind: (try? container.decode(String.self, forKey: .kind)) ?? "structured",
            engine: try? container.decodeIfPresent(String.self, forKey: .engine)
        )
    }

    /// 切到另一个 provider 时把模式夹到它支持的值，避免把 Codex 不收的 `default` 提交上去。
    func withProvider(_ provider: String) -> WandBoardTaskAgent {
        WandBoardTaskAgent(
            provider: provider,
            model: model,
            thinkingEffort: thinkingEffort,
            mode: WandBoardAgentMode.normalize(provider: provider, value: mode),
            kind: kind,
            engine: provider == self.provider ? engine : nil
        )
    }

    func jsonObject() -> [String: Any] {
        var object: [String: Any] = [
            "provider": provider,
            "model": model,
            "thinkingEffort": thinkingEffort,
            "mode": mode,
            "kind": kind,
        ]
        if let engine { object["engine"] = engine }
        return object
    }
}

// MARK: - 里程碑（迭代）

struct WandBoardMilestoneRef: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let isDefault: Bool

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = (try? container.decode(String.self, forKey: .name)) ?? ""
        isDefault = (try? container.decode(Bool.self, forKey: .isDefault)) ?? false
    }

    private enum CodingKeys: String, CodingKey { case id, name, isDefault }
}

/// `/api/wand-milestones` 的响应体。
struct WandBoardMilestoneListResponse: Decodable {
    let milestones: [WandBoardMilestone]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        milestones = (try? container.decode([WandBoardMilestone].self, forKey: .milestones)) ?? []
    }

    private enum CodingKeys: String, CodingKey { case milestones }
}

/// `/api/wand-milestones` 返回的条目：里程碑本体 + 看板任务数量。
struct WandBoardMilestone: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let dueDate: String?
    let workspaceId: String?
    let isDefault: Bool
    let taskCount: Int

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = (try? container.decode(String.self, forKey: .name)) ?? ""
        dueDate = try? container.decodeIfPresent(String.self, forKey: .dueDate)
        workspaceId = try? container.decodeIfPresent(String.self, forKey: .workspaceId)
        isDefault = (try? container.decode(Bool.self, forKey: .isDefault)) ?? false
        taskCount = (try? container.decode(Int.self, forKey: .taskCount)) ?? 0
    }

    /// 已选工作区时只展示「该工作区 + 全局」的迭代，与 Web `visibleMilestones` 口径一致。
    func isVisible(for workspaceId: String?) -> Bool {
        guard let workspaceId, !workspaceId.isEmpty else { return true }
        return self.workspaceId == nil || self.workspaceId == workspaceId
    }
}

// MARK: - 任务与会话

struct WandBoardWorkspace: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let cwd: String
}

struct WandBoardTaskSession: Codable, Equatable, Identifiable {
    let employeeName: String?
    let employeeId: String?
    let employeeAvatar: String?
    let id: String
    let provider: String
    let engine: String?
    let sessionKind: String
    let title: String
    let status: String
    let cwd: String
    let model: String
    let thinkingEffort: String
    /// 会话实际跑的工作模式；旧会话可能为空，显示时回落到任务上的配置。
    let mode: String

    var isStructured: Bool { sessionKind != "pty" && sessionKind != "shell" }
    var isRunning: Bool { status == "running" }
    var toolEngine: String { engine == "core" || engine == "sdk" ? "sdk" : "cli" }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        employeeName = try? container.decodeIfPresent(String.self, forKey: .employeeName)
        employeeId = try? container.decodeIfPresent(String.self, forKey: .employeeId)
        employeeAvatar = try? container.decodeIfPresent(String.self, forKey: .employeeAvatar)
        id = (try? container.decode(String.self, forKey: .id)) ?? ""
        provider = (try? container.decode(String.self, forKey: .provider)) ?? ""
        engine = try? container.decodeIfPresent(String.self, forKey: .engine)
        sessionKind = (try? container.decode(String.self, forKey: .sessionKind)) ?? ""
        title = (try? container.decode(String.self, forKey: .title)) ?? id
        status = (try? container.decode(String.self, forKey: .status)) ?? ""
        cwd = (try? container.decode(String.self, forKey: .cwd)) ?? ""
        model = (try? container.decode(String.self, forKey: .model)) ?? ""
        thinkingEffort = (try? container.decode(String.self, forKey: .thinkingEffort)) ?? "off"
        mode = (try? container.decode(String.self, forKey: .mode)) ?? ""
    }

    private enum CodingKeys: String, CodingKey {
        case employeeName, employeeId, employeeAvatar, id, provider, engine, sessionKind, title, status, cwd, model, thinkingEffort, mode
    }
}

struct WandBoardDispatchResult: Decodable {
    let ok: Bool
    let taskId: String
    let sessionId: String
    let provider: String
    let cwd: String
    let title: String
    let status: String
    let model: String

    private struct Session: Decodable {
        let id: String?
        let provider: String?
        let cwd: String?
        let model: String?
        let mode: String?
        let sessionKind: String?
    }

    private enum CodingKeys: String, CodingKey { case ok, taskId, session }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = (try? container.decode(Bool.self, forKey: .ok)) ?? true
        taskId = (try? container.decode(String.self, forKey: .taskId)) ?? ""
        let session = try? container.decode(Session.self, forKey: .session)
        sessionId = session?.id ?? ""
        provider = session?.provider ?? ""
        cwd = session?.cwd ?? ""
        model = session?.model ?? ""
        // 派发响应不带会话标题，卡片上按 provider 显示即可。
        title = ""
        status = "running"
    }
}

struct WandBoardTask: Decodable, Identifiable, Equatable {
    private enum CodingKeys: String, CodingKey {
        case assignedExecutor
        case executionSubject, acceptance, id, workspaceId, workspaceTaskId, parentTaskId, identifier, title, titleSource, description, status, priority
        case labels, dueDate, milestoneId, milestone, sortOrder, agent, createdAt, updatedAt
        case sessionIds, sessions, workspace
    }

    let executionSubject: WandTaskExecutionSubject?
    let acceptance: WandTaskAcceptance?
    let id: String
    let workspaceId: String?
    /// 关联的侧栏工作任务 id；拖拽会话入卡与「移动到其它任务」用它。
    let workspaceTaskId: String?
    /// 看板卡片 ID（不是侧栏 workspaceTaskId）；归类只写这个关系，不删除子任务。
    let parentTaskId: String?
    let identifier: String
    let title: String
    /// "auto" = 标题由服务端按描述自动生成；老服务端不返回时按用户手写处理。
    let titleSource: String
    let description: String
    let status: String
    let priority: String
    let labels: [String]
    let dueDate: String?
    let milestoneId: String?
    let milestone: WandBoardMilestoneRef?
    let sortOrder: Int
    let assignedExecutor: WandBoardAssignedExecutor?
    let agent: WandBoardTaskAgent?
    let createdAt: String
    let updatedAt: String
    let sessionIds: [String]
    let sessions: [WandBoardTaskSession]
    let workspace: WandBoardWorkspace?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        executionSubject = try? container.decodeIfPresent(WandTaskExecutionSubject.self, forKey: .executionSubject)
        acceptance = try? container.decodeIfPresent(WandTaskAcceptance.self, forKey: .acceptance)
        id = try container.decode(String.self, forKey: .id)
        workspaceId = try? container.decodeIfPresent(String.self, forKey: .workspaceId)
        workspaceTaskId = try? container.decodeIfPresent(String.self, forKey: .workspaceTaskId)
        let parent = try? container.decodeIfPresent(String.self, forKey: .parentTaskId)
        parentTaskId = parent?.isEmpty == false ? parent : nil
        identifier = (try? container.decode(String.self, forKey: .identifier)) ?? ""
        title = (try? container.decode(String.self, forKey: .title)) ?? "任务"
        titleSource = (try? container.decode(String.self, forKey: .titleSource)) ?? "user"
        description = (try? container.decode(String.self, forKey: .description)) ?? ""
        status = (try? container.decode(String.self, forKey: .status)) ?? "todo"
        priority = (try? container.decode(String.self, forKey: .priority)) ?? "none"
        labels = (try? container.decode([String].self, forKey: .labels)) ?? []
        dueDate = try? container.decodeIfPresent(String.self, forKey: .dueDate)
        milestoneId = try? container.decodeIfPresent(String.self, forKey: .milestoneId)
        milestone = try? container.decodeIfPresent(WandBoardMilestoneRef.self, forKey: .milestone)
        sortOrder = (try? container.decode(Int.self, forKey: .sortOrder)) ?? 0
        assignedExecutor = try? container.decodeIfPresent(WandBoardAssignedExecutor.self, forKey: .assignedExecutor)
        agent = try? container.decodeIfPresent(WandBoardTaskAgent.self, forKey: .agent)
        createdAt = (try? container.decode(String.self, forKey: .createdAt)) ?? ""
        updatedAt = (try? container.decode(String.self, forKey: .updatedAt)) ?? ""
        sessionIds = (try? container.decode([String].self, forKey: .sessionIds)) ?? []
        // 单个会话缺字段不该牵连同任务其它会话，没有 id 的条目直接丢弃。
        sessions = ((try? container.decode([WandBoardTaskSession].self, forKey: .sessions)) ?? [])
            .filter { !$0.id.isEmpty }
        workspace = try? container.decodeIfPresent(WandBoardWorkspace.self, forKey: .workspace)
    }
}

/// 使用未筛选的同一份看板列表投影关系，筛选掉父任务时也不会丢失归属提示。
func wandBoardParent(of task: WandBoardTask, in tasks: [WandBoardTask]) -> WandBoardTask? {
    guard let id = task.parentTaskId, id != task.id else { return nil }
    return tasks.first { $0.id == id }
}

func wandBoardChildren(of task: WandBoardTask, in tasks: [WandBoardTask]) -> [WandBoardTask] {
    tasks.filter { $0.id != task.id && $0.parentTaskId == task.id }
}

// MARK: - 状态与优先级

/**
 * 看板状态。前三列是看板主列，`archived` 是「等你确认」下面的独立归档目录，
 * 与 Web `ISSUE_COLUMNS` + `ISSUE_ARCHIVE_COLUMN` 一致。
 */
enum WandBoardStatus: String, CaseIterable, Identifiable {
    case todo, doing, done, archived

    var id: String { rawValue }

    /// 看板主列：归档只作为目录出现，不占一列。
    static let columns: [WandBoardStatus] = [.todo, .doing, .done]

    var isColumn: Bool { self != .archived }

    var label: String {
        switch self {
        case .todo: return "等待认领"
        case .doing: return "处理中"
        case .done: return "等你确认"
        case .archived: return "归档任务"
        }
    }

    var empty: String {
        switch self {
        case .todo: return "还没有等待认领的任务"
        case .doing: return "暂无处理中的任务"
        case .done: return "还没有待确认的任务"
        case .archived: return "还没有归档的任务"
        }
    }

    var isClosed: Bool { self == .done || self == .archived }

    /// 列头 / 状态图标的强调色，取自 Web `--tb-column-*`。
    var color: Color {
        switch self {
        case .todo: return Color(red: 176 / 255, green: 122 / 255, blue: 58 / 255)
        case .doing: return Color(red: 197 / 255, green: 101 / 255, blue: 61 / 255)
        case .done: return Color(red: 93 / 255, green: 106 / 255, blue: 88 / 255)
        case .archived: return Theme.textMuted
        }
    }
}

enum WandBoardPriority: String, CaseIterable, Identifiable {
    case none, urgent, high, medium, low
    var id: String { rawValue }
    var label: String {
        switch self {
        case .none: return "无优先级"
        case .urgent: return "紧急"
        case .high: return "高"
        case .medium: return "中"
        case .low: return "低"
        }
    }

    /// 紧急 / 高用产品主色，中等待用 warning，其余用次级文字色（对齐 Web `.task-board-priority`）。
    var color: Color {
        switch self {
        case .urgent, .high: return Theme.wandAccent
        case .medium: return Theme.warning
        case .none, .low: return Theme.textSecondary
        }
    }

    var symbolName: String {
        switch self {
        case .urgent: return "exclamationmark.triangle.fill"
        case .high: return "arrow.up.circle.fill"
        case .medium: return "minus.circle.fill"
        case .low: return "arrow.down.circle.fill"
        case .none: return "circle.dashed"
        }
    }

    static func label(for value: String) -> String {
        WandBoardPriority(rawValue: value)?.label ?? value
    }
}

// MARK: - 面板视图与筛选

/// 看板视图；与 Web `ISSUE_BOARD_VIEWS` 一致。
enum WandBoardView: String, CaseIterable, Identifiable {
    case dashboard, board, list, gantt

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dashboard: return "概览"
        case .board: return "看板"
        case .list: return "列表"
        case .gantt: return "甘特图"
        }
    }

    var symbolName: String {
        switch self {
        case .dashboard: return "chart.pie"
        case .board: return "rectangle.split.3x1"
        case .list: return "list.bullet"
        case .gantt: return "chart.bar.doc.horizontal"
        }
    }
}

/// 筛选条件：状态 / 优先级 / 标签三组，空数组表示不限。
struct WandBoardFilters: Equatable {
    var statuses: Set<String> = []
    var priorities: Set<String> = []
    var labels: Set<String> = []

    static let empty = WandBoardFilters()

    var count: Int {
        (statuses.isEmpty ? 0 : 1) + (priorities.isEmpty ? 0 : 1) + (labels.isEmpty ? 0 : 1)
    }

    var isActive: Bool { count > 0 }
}

/// 显示设置：卡片正文与「主列」划分（非主列的状态落入「其他任务」侧栏）。
struct WandBoardDisplay: Equatable {
    var body = false
    var mainStatuses: Set<String> = Set(WandBoardStatus.columns.map(\.rawValue))

    static let `default` = WandBoardDisplay()
}

/// 甘特图时间尺度。
enum WandBoardGanttZoom: String, CaseIterable, Identifiable {
    case day, week, month

    var id: String { rawValue }

    var label: String {
        switch self {
        case .day: return "日视图"
        case .week: return "周视图"
        case .month: return "月视图"
        }
    }

    var days: Int {
        switch self {
        case .day: return 14
        case .week: return 42
        case .month: return 90
        }
    }
}

// MARK: - 标签配色

private let wandBoardLabelBugColor = Color(red: 178 / 255, green: 79 / 255, blue: 69 / 255)
private let wandBoardLabelFeatureColor = Color(red: 74 / 255, green: 111 / 255, blue: 165 / 255)

private let wandBoardLabelPalette: [Color] = [
    Color(red: 197 / 255, green: 101 / 255, blue: 61 / 255),
    Color(red: 79 / 255, green: 122 / 255, blue: 88 / 255),
    Color(red: 169 / 255, green: 106 / 255, blue: 47 / 255),
    Color(red: 74 / 255, green: 111 / 255, blue: 165 / 255),
    Color(red: 178 / 255, green: 79 / 255, blue: 69 / 255),
    Color(red: 111 / 255, green: 109 / 255, blue: 163 / 255),
    Color(red: 138 / 255, green: 107 / 255, blue: 74 / 255),
]

/// 标签语义色：缺陷 / 特性走语义色，其余按名字做稳定散列取色（与 Web 同一套调色板）。
enum WandBoardLabelTone {
    case bug
    case feature
    case neutral
}

func wandBoardLabelTone(_ label: String) -> WandBoardLabelTone {
    let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
    let upper = trimmed.uppercased()
    if trimmed == "缺陷" || upper == "BUG" { return .bug }
    if trimmed == "特性" || trimmed == "新功能" { return .feature }
    return .neutral
}

/**
 * 标签展示名：缺陷 / BUG 统一显示 `BUG`，特性显示「新功能」，其余原样（对齐 Web `issueLabelName`）。
 */
func wandBoardLabelName(_ label: String) -> String {
    if label == "缺陷" || label.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "BUG" {
        return "BUG"
    }
    if label == "特性" { return "新功能" }
    return label
}

func wandBoardLabelColor(_ label: String) -> Color {
    switch wandBoardLabelTone(label) {
    case .bug: return wandBoardLabelBugColor
    case .feature: return wandBoardLabelFeatureColor
    case .neutral: break
    }
    // 与 Web `issueLabelColor` 同一套散列，保证同一个标签在各端同色。
    var hash: UInt32 = 0
    for scalar in label.unicodeScalars {
        hash = hash &* 31 &+ UInt32(truncatingIfNeeded: scalar.value)
    }
    return wandBoardLabelPalette[Int(hash % UInt32(wandBoardLabelPalette.count))]
}

// MARK: - Provider / 思考深度标签

let wandBoardProviders = WandProvider.allCases.map(\.rawValue)
let wandBoardEfforts = ["off", "standard", "deep", "max"]

func wandBoardProviderLabel(_ provider: String, engine: String? = nil) -> String {
    switch provider {
    case "session", "shell": return "终端"
    case "": return "Agent"
    default: return WandProvider.title(for: provider, engine: engine)
    }
}

func wandBoardEffortLabel(_ effort: String) -> String {
    switch effort {
    case "off", "": return "关闭"
    case "standard": return "标准"
    case "deep": return "深入"
    case "max": return "最大"
    default: return effort
    }
}

func wandBoardSessionStatusLabel(_ status: String) -> String {
    switch status {
    case "running": return "进行中"
    case "idle": return "空闲"
    case "exited": return "已结束"
    case "failed": return "失败"
    default: return status.isEmpty ? "会话" : status
    }
}

func wandBoardModelOptions(from catalog: ModelsResponse?, provider: String) -> [(id: String, label: String)] {
    let models = catalog?.models(for: provider) ?? []
    let mapped = models.map { (id: $0.id, label: $0.label.isEmpty ? $0.id : $0.label) }
    if mapped.contains(where: { $0.id == "default" }) { return mapped }
    let fallback = catalog?.defaultModelId(for: provider) ?? ""
    let defaultLabel = fallback.isEmpty ? "跟随服务端默认" : "跟随服务端默认（\(fallback)）"
    return [(id: "default", label: defaultLabel)] + mapped
}

// MARK: - 派发时机

/// 「创建更多」后的草稿重置：与 Web `emptyDraft(draft.workspaceId, draft.status, draft.agent)` 一致，
/// 只沿用项目 / 状态 / Agent，其余（优先级、里程碑、截止日期、标签）回默认值。
func wandBoardDraftAfterCreateMore(_ draft: WandBoardDraft) -> WandBoardDraft {
    var next = WandBoardDraft()
    next.workspaceId = draft.workspaceId
    next.status = draft.status
    next.agent = draft.agent
    next.employeeId = draft.employeeId
    next.employeeOverride = draft.employeeOverride
    return next
}

/// 新建任务是否顺带完成第一次指派：「等待认领」列只创建，「处理中」列创建后立刻派发。
func wandBoardCreateDispatches(status: String) -> Bool { false }

/**
 * 拖进「处理中」是否顺带派发：只有还没派发过（没有绑定会话）的任务才自动派发，
 * 已经在跑 / 跑过的卡再拖回来只改状态，避免拖一次就多开一个 session。
 *
 * 命中时调用方必须先向用户确认：派发会创建真实会话，不能拖一下就静默启动 Agent。
 */
func wandBoardDropDispatches(status: String, sessionCount: Int) -> Bool {
    false
}

/// 拖进「处理中」前的派发确认：把将要发给 Agent 的说明一并列出。
struct WandBoardDropDispatchConfirm: Identifiable, Equatable {
    let taskId: String
    let status: String
    let title: String
    let prompt: String

    var id: String { taskId }
}

/// 拖拽派发用的提示词：优先任务描述，其次标题，最后给一句兜底指令。
func wandBoardDropDispatchPrompt(title: String, description: String) -> String {
    let text = description.trimmingCharacters(in: .whitespacesAndNewlines)
    if !text.isEmpty { return text }
    let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
    return name.isEmpty ? "执行此任务" : name
}

// MARK: - 会话分组

struct WandBoardAgentGroup: Identifiable, Equatable {
    var id: String { agent?.toolKey ?? provider + ":cli" }
    let provider: String
    let agent: WandBoardTaskAgent?
    let sessions: [WandBoardTaskSession]
}

/**
 * 打开任务时按 CLI 工具列出已执行 / 已指派的 Agent。
 * 先保留任务上的指派，再把绑定会话归进对应组；未识别的会话单独成组。
 */
func wandBoardSessionGroups(
    sessions: [WandBoardTaskSession],
    assigned: WandBoardTaskAgent?
) -> [WandBoardAgentGroup] {
    var providers: [String] = []
    var agents: [String: WandBoardTaskAgent] = [:]
    var grouped: [String: [WandBoardTaskSession]] = [:]
    func ensure(_ provider: String, _ agent: WandBoardTaskAgent?) {
        let key = provider.isEmpty ? "session" : agent?.toolKey ?? (provider + ":cli")
        if !providers.contains(key) {
            providers.append(key)
            grouped[key] = []
        }
        if agents[key] == nil, let agent {
            agents[key] = agent
        }
    }
    if let assigned, wandBoardProviders.contains(assigned.provider) {
        ensure(assigned.provider, assigned)
    }
    for session in sessions {
        let agent = wandBoardProviders.contains(session.provider)
            ? WandBoardTaskAgent(
                provider: session.provider,
                model: session.model.isEmpty ? "default" : session.model,
                thinkingEffort: session.thinkingEffort.isEmpty ? "off" : session.thinkingEffort,
                mode: session.mode,
                kind: session.sessionKind == "pty" ? "pty" : "structured",
                engine: session.toolEngine
            )
            : nil
        let key = session.provider.isEmpty ? "session" : agent?.toolKey ?? (session.provider + ":cli")
        ensure(session.provider, agent)
        grouped[key, default: []].append(session)
    }
    return providers.map { key in
        WandBoardAgentGroup(provider: agents[key]?.provider ?? grouped[key]?.first.map { $0.provider.isEmpty ? "session" : $0.provider } ?? "session", agent: agents[key], sessions: grouped[key] ?? [])
    }
}

/// 卡片上的 Agent 胶囊：每个「跑过或已指派」的 CLI 工具一个。
func wandBoardListAgents(
    sessions: [WandBoardTaskSession],
    assigned: WandBoardTaskAgent?
) -> [WandBoardTaskAgent] {
    wandBoardSessionGroups(sessions: sessions, assigned: assigned).compactMap(\.agent)
}

// MARK: - 日期与逾期

func wandBoardIsoDate(_ date: Date) -> String {
    let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
}

func wandBoardDay(fromDueDate value: String) -> Date? {
    let parts = value.split(separator: "-")
    guard parts.count == 3,
          let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
    else { return nil }
    var components = DateComponents()
    components.year = year
    components.month = month
    components.day = day
    components.hour = 12
    return Calendar.current.date(from: components)
}

/// 截止日期短标签：严格 `yyyy-MM-dd` 才转成 `M/D`，其它形态回落到相对时间（对齐 Web `issueDueStamp`）。
func wandBoardDueStamp(_ value: String?) -> String {
    guard let value, !value.isEmpty else { return "" }
    if value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil {
        let parts = value.split(separator: "-")
        if parts.count == 3, let month = Int(parts[1]), let day = Int(parts[2]) {
            return "\(month)/\(day)"
        }
    }
    return wandBoardFormatStamp(value)
}

/// 已确认 / 已归档不算逾期。
func wandBoardIsOverdue(_ dueDate: String?, status: String, today: Date = Date()) -> Bool {
    guard let dueDate, !dueDate.isEmpty else { return false }
    guard let status = WandBoardStatus(rawValue: status), !status.isClosed else { return false }
    return dueDate < wandBoardIsoDate(today)
}

/// 时间戳短标签：`M/D`。
func wandBoardFormatStamp(_ value: String?) -> String {
    guard let value, !value.isEmpty else { return "" }
    if let date = SessionTimeFormatting.date(from: value) {
        let components = Calendar.current.dateComponents([.month, .day], from: date)
        return "\(components.month ?? 0)/\(components.day ?? 0)"
    }
    return wandBoardDueStamp(value)
}

func wandBoardDate(from value: String?) -> Date? {
    guard let value, !value.isEmpty else { return nil }
    return SessionTimeFormatting.date(from: value) ?? wandBoardDay(fromDueDate: value)
}

// MARK: - 概览统计

struct WandBoardStats {
    let total: Int
    let todo: Int
    let doing: Int
    let done: Int
    let overdue: Int
    let high: Int
    var remaining: Int { todo + doing }
}

func wandBoardStats(tasks: [WandBoardTask]) -> WandBoardStats {
    let today = Date()
    var todo = 0
    var doing = 0
    var done = 0
    var overdue = 0
    var high = 0
    for task in tasks {
        switch task.status {
        case WandBoardStatus.todo.rawValue: todo += 1
        case WandBoardStatus.doing.rawValue: doing += 1
        case WandBoardStatus.done.rawValue: done += 1
        default: break
        }
        if wandBoardIsOverdue(task.dueDate, status: task.status, today: today) { overdue += 1 }
        if task.priority == WandBoardPriority.high.rawValue || task.priority == WandBoardPriority.urgent.rawValue {
            high += 1
        }
    }
    return WandBoardStats(total: tasks.count, todo: todo, doing: doing, done: done, overdue: overdue, high: high)
}

struct WandBoardProgressPoint: Identifiable {
    let id: Int
    let scope: Int
    let started: Int
    let completed: Int
}

/// 概览折线图数据：按任务创建时间把 [最早创建时间, 现在] 等分 13 个点。
func wandBoardProgressSeries(tasks: [WandBoardTask], now: Date = Date()) -> [WandBoardProgressPoint] {
    let created = tasks.compactMap { wandBoardDate(from: $0.createdAt)?.timeIntervalSince1970 }
    let start = created.min() ?? now.timeIntervalSince1970 - 12 * 86_400
    let interval = max(1, (now.timeIntervalSince1970 - start) / 12)
    return (0...12).map { index in
        let timestamp = index == 12 ? now.timeIntervalSince1970 : start + interval * Double(index)
        let scope = tasks.filter {
            (wandBoardDate(from: $0.createdAt)?.timeIntervalSince1970 ?? .greatestFiniteMagnitude) <= timestamp
        }.count
        let started = tasks.filter { task in
            guard let createdAt = wandBoardDate(from: task.createdAt)?.timeIntervalSince1970 else { return false }
            if task.status == WandBoardStatus.todo.rawValue { return false }
            let updatedAt = wandBoardDate(from: task.updatedAt)?.timeIntervalSince1970 ?? createdAt
            return max(createdAt, updatedAt) <= timestamp
        }.count
        let completed = tasks.filter { task in
            guard let status = WandBoardStatus(rawValue: task.status), status.isClosed else { return false }
            return (wandBoardDate(from: task.updatedAt)?.timeIntervalSince1970 ?? .greatestFiniteMagnitude) <= timestamp
        }.count
        return WandBoardProgressPoint(id: index, scope: scope, started: started, completed: completed)
    }
}

// MARK: - 甘特范围

struct WandBoardGanttRange {
    let start: String
    let days: Int
    let columns: [String]
}

func wandBoardGanttRange(zoom: WandBoardGanttZoom, today: Date = Date()) -> WandBoardGanttRange {
    let span = zoom.days
    let startDate = Calendar.current.date(byAdding: .day, value: -span / 4, to: today) ?? today
    let start = wandBoardIsoDate(startDate)
    let columns = (0..<span).map { offset in
        wandBoardIsoDate(Calendar.current.date(byAdding: .day, value: offset, to: startDate) ?? startDate)
    }
    return WandBoardGanttRange(start: start, days: span, columns: columns)
}

/// 任务在甘特轨道上的位置：起点取创建日，终点取截止日期（没有截止日期时按已确认 / 3 天兜底）。
func wandBoardGanttSpan(task: WandBoardTask, range: WandBoardGanttRange) -> (offset: Int, length: Int) {
    let startBase = wandBoardDay(fromDueDate: range.start) ?? Date()
    let createdDay = wandBoardDate(from: task.createdAt).map(wandBoardIsoDate) ?? wandBoardIsoDate(Date())
    var finishDay = wandBoardIsoDate(Date())
    if let dueDate = task.dueDate, !dueDate.isEmpty {
        finishDay = dueDate
    } else if let status = WandBoardStatus(rawValue: task.status), status.isClosed {
        finishDay = wandBoardDate(from: task.updatedAt).map(wandBoardIsoDate) ?? createdDay
    } else {
        finishDay = wandBoardIsoDate(
            Calendar.current.date(byAdding: .day, value: 3, to: wandBoardDay(fromDueDate: createdDay) ?? Date()) ?? Date()
        )
    }
    let startMs = startBase.timeIntervalSince1970
    let createdMs = (wandBoardDay(fromDueDate: createdDay) ?? startBase).timeIntervalSince1970
    let finishMs = (wandBoardDay(fromDueDate: finishDay) ?? startBase).timeIntervalSince1970
    let offset = max(0, Int(((createdMs - startMs) / 86_400).rounded()))
    let end = min(range.days, max(offset + 1, Int(((finishMs - startMs) / 86_400).rounded()) + 1))
    let clampedOffset = min(offset, range.days - 1)
    return (clampedOffset, max(1, end - clampedOffset))
}

// MARK: - 筛选与搜索

func wandBoardMatches(
    task: WandBoardTask,
    query: String,
    workspaceId: String,
    filters: WandBoardFilters
) -> Bool {
    if !workspaceId.isEmpty, (task.workspaceId ?? "") != workspaceId { return false }
    if !filters.statuses.isEmpty, !filters.statuses.contains(task.status) { return false }
    if !filters.priorities.isEmpty, !filters.priorities.contains(task.priority) { return false }
    if !filters.labels.isEmpty, !filters.labels.contains(where: { task.labels.contains($0) }) { return false }
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
    if needle.isEmpty { return true }
    // 搜索范围与 Web `filterIssues` 一致：标题 / 编号 / 描述 / 标签，不含项目名。
    let haystack = ([task.title, task.identifier, task.description] + task.labels)
        .joined(separator: " ")
    return haystack.localizedCaseInsensitiveContains(needle)
}

/// 面板里出现过的全部标签，按中文排序。
func wandBoardCollectLabels(tasks: [WandBoardTask]) -> [String] {
    var seen = Set<String>()
    var labels: [String] = []
    for task in tasks {
        for label in task.labels where !label.isEmpty && !seen.contains(label) {
            seen.insert(label)
            labels.append(label)
        }
    }
    return labels.sorted { $0.localizedCompare($1) == .orderedAscending }
}

/// 按状态分组；归档单独成组，不进看板主列。
func wandBoardGroup(tasks: [WandBoardTask]) -> [String: [WandBoardTask]] {
    var grouped: [String: [WandBoardTask]] = [:]
    for status in WandBoardStatus.allCases { grouped[status.rawValue] = [] }
    for task in tasks {
        let key = WandBoardStatus(rawValue: task.status)?.rawValue ?? WandBoardStatus.todo.rawValue
        grouped[key, default: []].append(task)
    }
    return grouped
}

// MARK: - 视图状态持久化

private let wandBoardViewStateKey = "wand.desktop.taskBoard.viewState"
private let wandBoardDisplayKey = "wand.desktop.taskBoard.display"

struct WandBoardViewState: Equatable {
    var view: WandBoardView = .board
    var query = ""
    var workspaceId = ""
    var filters = WandBoardFilters()

    static let `default` = WandBoardViewState()
}

func wandBoardReadViewState(defaults: UserDefaults = .standard) -> WandBoardViewState {
    guard let data = defaults.data(forKey: wandBoardViewStateKey),
          let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return .default }
    var state = WandBoardViewState.default
    if let view = raw["view"] as? String, let parsed = WandBoardView(rawValue: view) { state.view = parsed }
    state.query = (raw["query"] as? String) ?? ""
    state.workspaceId = (raw["workspaceId"] as? String) ?? ""
    if let statuses = raw["statuses"] as? [String] { state.filters.statuses = Set(statuses) }
    if let priorities = raw["priorities"] as? [String] { state.filters.priorities = Set(priorities) }
    if let labels = raw["labels"] as? [String] { state.filters.labels = Set(labels) }
    return state
}

func wandBoardWriteViewState(_ state: WandBoardViewState, defaults: UserDefaults = .standard) {
    let raw: [String: Any] = [
        "view": state.view.rawValue,
        "query": state.query,
        "workspaceId": state.workspaceId,
        "statuses": Array(state.filters.statuses),
        "priorities": Array(state.filters.priorities),
        "labels": Array(state.filters.labels),
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: raw) else { return }
    defaults.set(data, forKey: wandBoardViewStateKey)
}

func wandBoardReadDisplay(defaults: UserDefaults = .standard) -> WandBoardDisplay {
    guard let data = defaults.data(forKey: wandBoardDisplayKey),
          let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return .default }
    var display = WandBoardDisplay.default
    display.body = (raw["body"] as? Bool) ?? false
    if let statuses = raw["mainStatuses"] as? [String] {
        let allowed = Set(WandBoardStatus.columns.map(\.rawValue))
        let filtered = statuses.filter { allowed.contains($0) }
        if !filtered.isEmpty { display.mainStatuses = Set(filtered) }
    }
    return display
}

func wandBoardWriteDisplay(_ display: WandBoardDisplay, defaults: UserDefaults = .standard) {
    let raw: [String: Any] = ["body": display.body, "mainStatuses": Array(display.mainStatuses)]
    guard let data = try? JSONSerialization.data(withJSONObject: raw) else { return }
    defaults.set(data, forKey: wandBoardDisplayKey)
}


/// Root projection shared by all four views; legacy relationships stay intact.
func wandBoardGoalProjection(all: [WandBoardTask], matched: [WandBoardTask]) -> [WandBoardTask] {
    let byId = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
    var roots = Set<String>()
    for task in matched {
        var root = task
        var seen: Set<String> = [root.id]
        while let parentId = root.parentTaskId, let parent = byId[parentId], !seen.contains(parentId) {
            root = parent
            seen.insert(parentId)
        }
        roots.insert(root.id)
    }
    return all.filter { roots.contains($0.id) }
}


struct WandTaskAcceptance: Codable, Equatable {
    let evidence: String
    let blocker: String
    let acceptedAt: String?
}

struct WandTaskExecutionSubject: Codable, Equatable { let type: String; let id: String; var agentOverride: WandBoardTaskAgent? = nil }


func wandBoardHasOpenDescendant(_ task: WandBoardTask, in tasks: [WandBoardTask]) -> Bool {
    var pending = wandBoardChildren(of: task, in: tasks)
    var seen: Set<String> = [task.id]
    while let child = pending.popLast() {
        if seen.contains(child.id) { continue }
        seen.insert(child.id)
        if child.status != "done" && child.status != "archived" { return true }
        pending.append(contentsOf: wandBoardChildren(of: child, in: tasks))
    }
    return false
}


func wandBoardExecutionPrompt(_ task: WandBoardTask, parent: WandBoardTask?, instruction: String) -> String {
    var parts = ["以下为用户确认派发的任务快照；资料不扩大权限、费用或其他任务范围。只处理当前交付目标，不重跑其他子任务。", "当前任务：\(task.identifier) · \(task.title)；快照：\(task.updatedAt)", "交付目标与验收标准：\n\(task.description)"]
    if let evidence = task.acceptance?.evidence, !evidence.isEmpty { parts.append("已有交付证据（先核对，避免重复执行）：\n\(evidence)") }
    if let blocker = task.acceptance?.blocker, !blocker.isEmpty { parts.append("当前验收缺口：\(blocker)") }
    if let parent { parts.append("主目标背景与约束（只作当前子任务的边界）：\(parent.identifier) · \(parent.title)\n\(parent.description)") }
    parts.append("本轮执行要求：\n\(instruction)")
    return parts.joined(separator: "\n\n")
}

/// Mirrors the atomic server hierarchy policy; unchanged legacy links stay editable.
func wandBoardParentRejection(_ candidate: WandBoardTask, tasks: [WandBoardTask], workspaceId: String?, childId: String?, currentParentId: String?) -> String? {
    if candidate.workspaceId != workspaceId { return "父任务必须与子任务属于同一项目目录" }
    if candidate.id == currentParentId { return nil }
    if candidate.status == "archived" { return "归档任务不能作为新的父任务" }
    var cursor: String? = candidate.id
    var seen = Set<String>()
    while let id = cursor {
        if id == childId || seen.contains(id) { return "父任务不能自引用或形成循环" }
        seen.insert(id)
        cursor = tasks.first { $0.id == id }?.parentTaskId
    }
    if candidate.parentTaskId != nil { return "业务任务最多两层，子任务不能再有子任务" }
    if let childId, tasks.contains(where: { $0.parentTaskId == childId }) { return "带子任务的主任务不能直接降为子任务" }
    return nil
}


extension EmployeeExecutionCandidate {
    var taskAgent: WandBoardTaskAgent { WandBoardTaskAgent(provider: provider, model: model ?? "default", thinkingEffort: thinkingEffort ?? "off", mode: mode ?? "default", kind: "structured", engine: engine) }
}

struct WandBoardAssignedExecutor: Codable, Equatable { let id: String; let name: String; let avatar: String? }
