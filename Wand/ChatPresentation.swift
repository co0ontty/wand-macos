import Foundation

/// Pure projection of one owner's live facts. A session's `running` status alone
/// only means its process exists; the caller must supply actual turn activity.
struct ChatRunningPresentation: Equatable {
    enum Stage { case idle, received, executing, thinking, output, tool, background, waiting, failed, stopped }
    let stage: Stage
    let label: String
    var toolID: String? = nil
    var startedAt: Date? = nil
    var lastActivityAt: Date? = nil
    var spinning: Bool { [.executing, .thinking, .output, .tool, .background].contains(stage) }
    var hasClock: Bool { startedAt != nil || lastActivityAt != nil }

    static func session(status: String, responding: Bool, permissionBlocked: Bool = false,
                        escalation: Bool = false, queuedCount: Int = 0,
                        archived: Bool = false) -> Self {
        if archived { return .init(stage: .idle, label: "") }
        switch status {
        case "failed": return .init(stage: .failed, label: "执行失败")
        case "stopped": return .init(stage: .stopped, label: "已停止")
        case "done", "exited": return .init(stage: .idle, label: "")
        default: break
        }
        if permissionBlocked || escalation || status == "awaiting_approval" {
            return .init(stage: .waiting, label: "等待你确认操作")
        }
        if ["waiting-input", "waiting_input", "waiting_user"].contains(status) {
            return .init(stage: .waiting, label: "等待你的输入")
        }
        if responding { return .init(stage: .executing, label: "正在执行") }
        if queuedCount > 0 { return .init(stage: .received, label: "已接收 · 排队中") }
        return .init(stage: .idle, label: "")
    }

    static func live(snapshot: SessionSnapshot?, messages: [ConversationTurn], status: String,
                     responding: Bool, permissionBlocked: Bool = false, escalation: Bool = false,
                     queuedCount: Int = 0) -> Self {
        var result = session(status: status, responding: responding, permissionBlocked: permissionBlocked,
                             escalation: escalation, queuedCount: queuedCount, archived: snapshot?.archived == true)
        guard let snapshot, responding, result.stage == .executing || result.stage == .waiting else { return result }
        let state = snapshot.structuredState
        // Optimistic sends can set responding before the server starts the next
        // request. Never reuse a previous snapshot's phase or clock in that gap.
        guard snapshot.isStructured ? state?.inFlight == true : snapshot.ptyBusy == true else { return result }
        let request = snapshot.isStructured ? state?.activeRequestId : nil
        let start = date(snapshot.isStructured ? state?.turnStartedAt : snapshot.ptyTurnStartedAt)
        let boundary = requestBoundary(messages)
        if let boundary {
            let user = messages[boundary]
            guard owns(user, sessionID: snapshot.id) else { return result }
            if let request, let userRequest = user.requestId, request != userRequest { return result }
            let sameRequest = request != nil && user.requestId == request
            // A user timestamp can precede the server's turn-start anchor. It
            // establishes a real transcript boundary, not the action timestamp.
            let timed = start.map { anchor in date(user.createdAt).map { $0 <= anchor } ?? false } ?? false
            guard sameRequest || timed else { return result }
        }
        if result.stage == .executing {
            if let action = currentAction(messages: messages, sessionID: snapshot.id, request: request,
                                          start: start, boundary: boundary) {
                result = action
            }
            if result.stage != .waiting && state?.phase == "background" && snapshot.isStructured {
                result = .init(stage: .background, label: "等待后台任务")
            }
        }
        result.startedAt = start
        result.lastActivityAt = date(snapshot.isStructured ? state?.lastActivityAt : snapshot.ptyLastActivityAt)
        return result
    }

    /// Only compare timestamps supplied by the server. TimelineView is merely a
    /// repaint schedule, never an activity timer or a source of a start timestamp.
    func text(at now: Date) -> String {
        var parts = [label]
        if let startedAt { parts.append("已运行 \(Self.duration(now.timeIntervalSince(startedAt)))") }
        if let lastActivityAt, now.timeIntervalSince(lastActivityAt) >= 60 {
            parts.append("已 \(Self.duration(now.timeIntervalSince(lastActivityAt)))无新消息")
        }
        return parts.joined(separator: " · ")
    }

    private static func duration(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        if seconds < 60 { return "\(seconds) 秒" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes) 分钟" }
        return minutes % 60 == 0 ? "\(minutes / 60) 小时" : "\(minutes / 60) 小时 \(minutes % 60) 分钟"
    }

    private static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private static func owns(_ turn: ConversationTurn, sessionID: String) -> Bool {
        if let source = turn.author?.sessionId, source != sessionID { return false }
        if let source = turn.sessionLink?.sessionId, source != sessionID { return false }
        return turn.sessionPreview == nil && turn.taskPreview == nil && turn.conversationLink == nil
    }

    private static func requestBoundary(_ messages: [ConversationTurn]) -> Int? {
        messages.lastIndex { turn in
            turn.role == "user" && turn.notice != true && turn.content.contains { block in
                if case .text(let text, let subagent) = block { return subagent == nil && !text.isEmpty }
                return false
            }
        }
    }

    private static func currentAction(messages: [ConversationTurn], sessionID: String, request: String?,
                                      start: Date?, boundary: Int?) -> Self? {
        let sameRequest = boundary.map { request != nil && messages[$0].requestId == request } ?? false
        var pending: [(id: String, name: String, question: Bool)] = []
        var completed = Set<String>()
        var latest: Self?
        for turn in messages.dropFirst(boundary.map { $0 + 1 } ?? 0) {
            guard owns(turn, sessionID: sessionID) else { continue }
            if let request, let turnRequest = turn.requestId {
                guard request == turnRequest else { continue }
            } else if !sameRequest {
                guard let start, let created = date(turn.createdAt), created >= start else { continue }
            }
            for block in turn.content {
                switch block {
                case .toolResult(let id, _, _, _, _, nil):
                    if !id.isEmpty { completed.insert(id) }
                    latest = nil
                case .toolUse(let id, let name, _, let input, nil):
                    guard turn.role == "assistant", !id.isEmpty else { continue }
                    // Message streaming can end while the tool/question still
                    // awaits its matching receipt. completedAt is not that receipt.
                    pending.append((id, name, name == "AskUserQuestion" || input["__wandQuestions"] != nil))
                    latest = nil
                case .text(let text, nil) where turn.role == "assistant" && turn.completedAt == nil:
                    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        latest = .init(stage: .output, label: "正在输出")
                    }
                case .thinking(_, nil) where turn.role == "assistant" && turn.completedAt == nil:
                    latest = .init(stage: .thinking, label: "正在思考")
                default: break
                }
            }
        }
        if let tool = pending.last(where: { !completed.contains($0.id) }) {
            if tool.question { return .init(stage: .waiting, label: "等待你的输入", toolID: tool.id) }
            // Identifier only: never surface a command, description or arguments.
            let safeName = tool.name.range(of: #"^[\p{L}\p{N}_.:-]{1,64}$"#, options: .regularExpression) != nil
            return .init(stage: .tool, label: safeName ? "正在使用工具 · \(tool.name)" : "正在使用工具", toolID: tool.id)
        }
        return latest
    }

    static func activityIsCurrent(snapshot: SessionSnapshot?, messages: [ConversationTurn], index: Int) -> Bool {
        guard let snapshot, messages.indices.contains(index),
              snapshot.isStructured ? snapshot.structuredState?.inFlight == true : snapshot.ptyBusy == true else { return false }
        let turn = messages[index]
        guard turn.completedAt == nil, owns(turn, sessionID: snapshot.id) else { return false }
        let request = snapshot.isStructured ? snapshot.structuredState?.activeRequestId : nil
        if let boundary = requestBoundary(messages) {
            guard index > boundary, owns(messages[boundary], sessionID: snapshot.id) else { return false }
            let userRequest = messages[boundary].requestId
            if let request, let userRequest, request != userRequest { return false }
            if let request, let turnRequest = turn.requestId { return request == turnRequest }
            if request != nil && request == userRequest { return true }
        } else if let request, let turnRequest = turn.requestId { return request == turnRequest }
        guard let start = date(snapshot.isStructured ? snapshot.structuredState?.turnStartedAt : snapshot.ptyTurnStartedAt),
              let created = date(turn.createdAt) else { return false }
        return created >= start
    }

    /// A terminal session only terminates its latest unfinished local activity.
    /// Earlier missing receipts remain unknown, including earlier request IDs.
    static func activityTerminal(status: String, sessionID: String, messages: [ConversationTurn], index: Int) -> Stage? {
        guard status == "failed" || status == "stopped", index == messages.count - 1,
              messages.indices.contains(index) else { return nil }
        let turn = messages[index]
        guard turn.role == "assistant", turn.completedAt == nil, owns(turn, sessionID: sessionID),
              let boundary = requestBoundary(messages), index > boundary,
              owns(messages[boundary], sessionID: sessionID) else { return nil }
        if let request = messages[boundary].requestId, let turnRequest = turn.requestId, request != turnRequest { return nil }
        return status == "failed" ? .failed : .stopped
    }

    /// Reply previews belong to their linked source, not a merged transcript.
    static func preview(status: String) -> Self {
        switch status {
        case "starting", "queued": return .init(stage: .received, label: "已接收 · 排队中")
        case "running": return .init(stage: .executing, label: "正在执行")
        case "thinking": return .init(stage: .thinking, label: "正在思考")
        case "unavailable": return .init(stage: .idle, label: "执行会话暂不可用")
        default: return session(status: status, responding: false)
        }
    }
}

/// Explicit user disclosure always wins over automatic completion folding.
enum ChatDisclosurePresentation {
    static func expanded(userChoice: Bool?, running: Bool, attention: Bool) -> Bool {
        userChoice ?? (attention || running)
    }

    /// 活动组默认只在「最新一组运行中」自动展开；思考与报错都不再自动撑开
    /// （对齐 Web/安卓的收起语义），用户手动收放的阅读选择始终优先。
    static func activityExpanded(userChoice: Bool?, isNewest: Bool, running: Bool) -> Bool {
        userChoice ?? (isNewest && running)
    }

    static func activityStatus(hasError: Bool, missingResult: Bool, running: Bool,
                               terminal: ChatRunningPresentation.Stage?) -> String {
        if hasError { return "有执行错误" }
        if missingResult, terminal == .failed { return "执行失败" }
        if missingResult, terminal == .stopped { return "已停止" }
        if running { return "进行中" }
        return missingResult ? "未收到结果" : "过程记录"
    }

    static func toolStatus(hasResult: Bool, isError: Bool, running: Bool) -> String {
        if isError { return "失败" }
        if hasResult { return "完成" }
        return running ? "处理中" : "未收到结果"
    }

    /// Native terminal notifications use the existing correlated tool-result
    /// projection. A Qoder launch acknowledgement alone proves no live status.
    static func subagentStatus(blocks: [ContentBlock], taskID: String?, running: Bool) -> String {
        for block in blocks.reversed() {
            guard case .toolResult(let id, let text, let isError, _, _, _) = block,
                  id == taskID else { continue }
            if isError { return "执行失败" }
            if text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("Async agent launched successfully.\n") {
                return "运行状态未知"
            }
            return "已完成"
        }
        return running ? "处理中" : "运行状态未知"
    }

    static func loadedRange(offset: Int, count: Int, total: Int) -> String {
        guard count > 0 else { return "尚未加载消息，共 \(total) 条；仅列用户提问。" }
        return "已加载消息 \(offset + 1)–\(offset + count)，共 \(total) 条；仅列用户提问。"
    }
}
