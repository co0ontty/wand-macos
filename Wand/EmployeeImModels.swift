import Foundation

/// Employee IM notification configuration (Telegram / 钉钉).
/// Matches src/employee-im-types.ts contract. Credentials are write-only.
struct EmployeeImConfig: Decodable, Equatable {
    let events: [String]
    let telegram: EmployeeImChannel
    let dingtalk: EmployeeImChannel
}

struct EmployeeImChannel: Decodable, Equatable {
    let enabled: Bool
    let chatId: String?
    let botTokenConfigured: Bool?
    let webhookConfigured: Bool?
    let secretConfigured: Bool?
}

struct EmployeeImTestResult: Decodable {
    let ok: Bool
}

/// Editable, per-employee draft. Secrets are never populated from GET; an empty
/// secret means preserve the saved value unless the corresponding clear flag is set.
struct EmployeeImChannelDraft: Equatable {
    var enabled = false
    var chatId = ""
    var botToken = ""
    var botTokenConfigured = false
    var clearBotToken = false
    var webhook = ""
    var webhookConfigured = false
    var clearWebhook = false
    var secret = ""
    var secretConfigured = false
    var clearSecret = false

    init(channel: EmployeeImChannel? = nil) {
        guard let channel else { return }
        enabled = channel.enabled
        chatId = channel.chatId ?? ""
        botTokenConfigured = channel.botTokenConfigured == true
        webhookConfigured = channel.webhookConfigured == true
        secretConfigured = channel.secretConfigured == true
    }

    var hasSecretChanges: Bool {
        !botToken.isEmpty || !webhook.isEmpty || !secret.isEmpty || clearBotToken || clearWebhook || clearSecret
    }
}

/// Events list matching EMPLOYEE_IM_EVENTS (value, label)
let employeeImEvents: [(value: String, label: String)] = [
    ("task_started", "开始处理任务"),
    ("task_completed", "任务完成"),
    ("task_failed", "任务失败"),
    ("task_stopped", "任务停止"),
    ("waiting_permission", "等待权限或计划审批"),
    ("waiting_input", "等待用户输入"),
    ("message_queued", "消息进入队列"),
    ("step_completed", "步骤完成"),
    ("candidate_switched", "执行候选切换"),
    ("team_started", "团队开始任务"),
    ("team_completed", "团队任务完成"),
    ("team_failed", "团队任务失败"),
    ("team_stopped", "团队任务停止")
]

let employeeImEventGroups: [(label: String, events: [String])] = [
    (label: "处理进度", events: ["task_started", "message_queued", "step_completed", "candidate_switched"]),
    (label: "需要你介入", events: ["waiting_permission", "waiting_input"]),
    (label: "执行结果", events: ["task_completed", "task_failed", "task_stopped"]),
    (label: "团队任务", events: ["team_started", "team_completed", "team_failed", "team_stopped"])
]

let employeeImPrimaryEvents = ["task_started", "task_completed", "task_failed", "task_stopped", "waiting_permission", "waiting_input"]
let employeeImMoreEventGroups = employeeImEventGroups.map { group in
    (label: group.label, events: group.events.filter { !employeeImPrimaryEvents.contains($0) })
}.filter { !$0.events.isEmpty }

/// Build channel input body for PUT. Only include credential keys when user supplied value or explicit clear (null).
/// Empty string / absent preserves server value per contract.
func makeImChannelInput(
    enabled: Bool,
    chatId: String?,
    botToken: String?,
    clearBotToken: Bool,
    webhook: String?,
    clearWebhook: Bool,
    secret: String?,
    clearSecret: Bool
) -> [String: Any] {
    var input: [String: Any] = ["enabled": enabled]
    if let chatId { input["chatId"] = chatId }
    if clearBotToken {
        input["botToken"] = NSNull()
    } else if let token = botToken, !token.isEmpty {
        input["botToken"] = token
    }
    if clearWebhook {
        input["webhook"] = NSNull()
    } else if let hook = webhook, !hook.isEmpty {
        input["webhook"] = hook
    }
    if clearSecret {
        input["secret"] = NSNull()
    } else if let sec = secret, !sec.isEmpty {
        input["secret"] = sec
    }
    return input
}
