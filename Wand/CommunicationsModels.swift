import Foundation

/// 未设置并发上限时的默认值；服务端与各客户端保持一致。
let employeeDefaultMaxConcurrentTasks = 2

/// Public employee metadata only. Knowledge endpoints are never fetched; role prompts are not projected or cached.
struct EmployeeContact: Decodable, Identifiable {
    let id: String
    let name: String
    let duty: String
    let avatar: String?
    let agents: [EmployeeExecutionCandidate]?
    let tags: [String]?
    let systemKey: String?
    let archivedAt: String?
    var systemSessionLimit: Int? = nil
    /// 同时执行的任务上限；旧响应缺省时按默认值 2 展示。超出的派发留在任务里排队。
    var maxConcurrentTasks: Int? = nil

    var effectiveMaxConcurrentTasks: Int { maxConcurrentTasks ?? employeeDefaultMaxConcurrentTasks }
    var isArchived: Bool { archivedAt?.isEmpty == false }
    var conversationID: String { "dm_" + id }
    var candidates: [EmployeeExecutionCandidate] { agents ?? [] }
}

struct EmployeeExecutionCandidate: Decodable {
    let provider: String
    let engine: String?
    let model: String?
    let kind: String?
    let mode: String?
    let thinkingEffort: String?

    var toolLabel: String { WandProvider.title(for: provider, engine: engine) }
    var executionPreferenceBody: [String: Any] {
        var body: [String: Any] = ["provider": provider, "model": model ?? "default", "thinkingEffort": thinkingEffort ?? "off"]
        if let engine { body["engine"] = engine }
        return body
    }
    func with(model: String? = nil, thinking: String? = nil) -> Self {
        Self(provider: provider, engine: engine, model: model ?? self.model, kind: "structured", mode: mode,
             thinkingEffort: thinking ?? thinkingEffort)
    }
}

struct ConversationRecipient: Decodable {
    let id: String
    let name: String
    let employeeId: String?
    let avatar: String?
    let duty: String?
    let isLeader: Bool?
    var agent: EmployeeExecutionCandidate? = nil
}

struct ConversationRoster: Decodable {
    let name: String?
    let members: [ConversationRecipient]
}

struct ConversationRun: Decodable, Identifiable {
    let id: String
    let taskId: String
    let status: String
    let statusDetail: String?
    let cwd: String?
    let chatSessionId: String?
    let objective: String?
    let roundNumber: Int?
    let stepLimit: Int?
    var team: ConversationRoster? = nil
    var isActive: Bool { ["running", "awaiting_approval", "waiting_user"].contains(status) }
}

struct ConversationTaskRecord: Decodable {
    struct TaskRecord: Decodable {
        let id: String
        let title: String
        let description: String?
        let workspaceId: String?
        var status: String? = nil
    }
    struct Startup: Decodable { let state: String }
    let task: TaskRecord
    let runs: [ConversationRun]
    var startup: Startup? = nil
}

struct ConversationRunDetail: Decodable { let run: ConversationRun }

struct DingTalkGroupBinding: Decodable, Identifiable {
    let id: String
    let employeeId: String
    let state: String
}
struct DingTalkGroupOrigin: Decodable {
    let provider: String
    let groupId: String
    let syncState: String
    let syncError: String?
    let historyComplete: Bool?
    let bindings: [DingTalkGroupBinding]?
    var statusText: String {
        if syncState == "live" { return "钉钉群 · \(bindings?.count ?? 0) 名已接入员工" }
        if syncState == "at_only" { return "钉钉群 · 仅同步 @消息" }
        return "钉钉群 · 消息同步尚未就绪"
    }
}

struct NativeConversation: Decodable, Identifiable {
    let id: String
    let kind: String
    let peerEmployeeId: String?
    let name: String?
    let title: String?
    let memberVersion: Int?
    let team: ConversationRoster?
    let unavailableReason: String?
    let memberUnavailableReasons: [String: String]?
    let pinnedAt: String?
    let dissolvedAt: String?
    let deleting: Bool?
    let preview: String?
    let messageAt: String?
    let messages: [ConversationTurn]?
    let tasks: [ConversationTaskRecord]?
    let runDetails: [ConversationRunDetail]?
    var sessionId: String? = nil
    var communicationSessionId: String? = nil
    var historySessionIds: [String]? = nil
    var history: ConversationHistory? = nil
    var external: DingTalkGroupOrigin? = nil

    var isArchived: Bool { dissolvedAt?.isEmpty == false || (tasks ?? []).contains { $0.task.status == "archived" } }
    func isActivity(sessions: [WorkspaceSessionSummary], selectedConversationID: String?, selectedSessionID: String?) -> Bool {
        let linkedIDs = Set(([sessionId, communicationSessionId] + runs.map(\.chatSessionId)).compactMap { $0 } + (historySessionIds ?? []))
        if sessions.contains(where: { session in
            let belongs = kind == "dm" ? session.employeeId == peerEmployeeId && session.teamChat == nil : linkedIDs.contains(session.id)
            return belongs && TaskListPresentation.isActive(session, selectedSessionId: selectedSessionID)
        }) { return true }
        return (tasks ?? []).contains { entry in
            guard entry.task.status != "archived" else { return false }
            if let run = entry.runs.first { return run.isActive || run.status == "failed" }
            return ["pending", "failed"].contains(entry.startup?.state ?? "")
        }
    }

    var displayTitle: String { title?.isEmpty == false ? title! : name?.isEmpty == false ? name! : "对话" }
    var isGroup: Bool { kind == "group" }
    var turns: [ConversationTurn] { messages ?? [] }
    var members: [ConversationRecipient] { team?.members ?? [] }
    var runs: [ConversationRun] { (tasks ?? []).flatMap(\.runs) }
    var sendBlockReason: String? {
        if deleting == true { return "对话正在删除，原草稿保留。" }
        if dissolvedAt?.isEmpty == false { return external != nil ? "此钉钉群镜像已暂停；不影响真实群聊。" : "群已解散；仍可阅读历史。" }
        if kind != "dm" && kind != "group" { return "当前客户端不支持此对话类型。" }
        return unavailableReason?.isEmpty == false ? unavailableReason : nil
    }
}

struct ConversationTarget: Codable, Equatable, Hashable {
    let taskId: String
    let runId: String
    var key: String { taskId + ":" + runId }
    var body: [String: String] { ["taskId": taskId, "runId": runId] }
}

struct ConversationReceipt: Decodable {
    let requestId: String
    let state: String
    let conversationId: String
    let taskId: String?
    let runId: String?
    let sessionId: String?
    let startup: String?
    let error: String?

    var isTerminal: Bool { state == "accepted" || state == "rejected" }
}

struct ConversationMessageAuthor: Decodable {
    let id: String
    let name: String
    let avatar: String?
    let provider: String?
    let engine: String?
    let sessionId: String?
}

struct ConversationSessionLink: Decodable { let sessionId: String; let title: String? }
struct ConversationTaskLink: Decodable { let conversationId: String; let taskId: String; let title: String? }
struct ConversationReplyPreview: Decodable { let status: String; let text: String }
struct ConversationTaskReplyPreview: Decodable { let runId: String?; let status: String; let text: String }

struct ConversationScope: Hashable {
    let conversationID: String
    let target: ConversationTarget?
    var key: String { conversationID + ":" + (target?.key ?? "talk") }
}

struct ConversationPendingRequest: Codable, Equatable, Identifiable {
    let id: String
    let fingerprint: String
    let conversationID: String
    let target: ConversationTarget?
    let operation: String
}

struct ConversationGroupDraft {
    var name = ""
    var employeeIDs: [String] = []
    var leaderID = ""

    mutating func toggle(_ id: String) {
        if employeeIDs.contains(id) { employeeIDs.removeAll { $0 == id } }
        else { employeeIDs.append(id) }
        if !employeeIDs.contains(leaderID) { leaderID = employeeIDs.first ?? "" }
    }
    var body: [String: Any] {
        ["name": name.trimmingCharacters(in: .whitespacesAndNewlines), "employeeIds": employeeIDs, "leaderId": leaderID]
    }
    var validationError: String? {
        if employeeIDs.isEmpty { return "至少选择一位员工。" }
        if !employeeIDs.contains(leaderID) { return "请从已选成员中指定负责人。" }
        if name.count > 80 { return "群名称不能超过 80 个字符。" }
        return nil
    }
}

func conversationRunLabel(_ status: String) -> String {
    switch status {
    case "starting": return "准备中"
    case "running": return "进行中"
    case "awaiting_approval": return "等你批准计划"
    case "waiting_user": return "等你回复"
    case "done": return "已完成"
    case "failed": return "执行失败"
    case "stopped": return "已停止"
    case "unavailable": return "原会话不可用"
    default: return status
    }
}
