import Foundation

/// Counts come from typed tool-use/result blocks and canonical task-list semantics, not text matching.
/// A bounded suffix is explicitly labelled as a sample, never passed off as the whole execution.
struct DesktopExecutionProgress: Equatable, Sendable {
    let completedSteps: Int?
    let totalSteps: Int?
    let currentStep: String?
    let toolCalls: Int
    let successfulCalls: Int
    let failedCalls: Int
    let pendingCalls: Int
    let currentTool: String?
    let lastTool: String?
    let coversCurrentTurn: Bool
    let hasMessages: Bool
    let elapsed: String?
    let sampledAt: Date

    init(snapshot: SessionSnapshot, now: Date = Date()) {
        sampledAt = now
        let messages = snapshot.messages ?? []
        let userIndex = messages.lastIndex { $0.role == "user" }
        coversCurrentTurn = userIndex != nil || (snapshot.messageOffset ?? 0) == 0
        let current = userIndex.map { Array(messages.dropFirst($0 + 1)) } ?? messages
        hasMessages = snapshot.messages != nil
        var uses: [(id: String, name: String)] = []
        var seen = Set<String>()
        var results: [String: Bool] = [:]
        for turn in current {
            for block in turn.content {
                switch block {
                case .toolUse(let id, let name, _, _, _):
                    if seen.insert(id).inserted { uses.append((id, Self.compact(name))) }
                case .toolResult(let id, _, let isError, _, _, _): results[id] = isError
                default: break
                }
            }
        }
        let todos = TodoItem.currentTodos(in: current).filter { $0.status != "deleted" }
        completedSteps = todos.isEmpty ? nil : todos.filter { $0.status == "completed" }.count
        totalSteps = todos.isEmpty ? nil : todos.count
        currentStep = todos.first { $0.status == "in_progress" }.map { Self.compact($0.activeForm ?? $0.content) }
        toolCalls = uses.count
        successfulCalls = uses.filter { results[$0.id] == false }.count
        failedCalls = uses.filter { results[$0.id] == true }.count
        pendingCalls = uses.filter { results[$0.id] == nil }.count
        let active = DesktopActivity.phase(for: snapshot).isActive
        currentTool = active ? uses.last(where: { results[$0.id] == nil })?.name : nil
        lastTool = uses.last?.name

        // Don't mistake a long-lived session's age for the duration of this turn.
        let start = snapshot.structuredState?.turnStartedAt ?? snapshot.ptyTurnStartedAt
            ?? userIndex.flatMap { messages[$0].createdAt }
        let end = active ? now : SessionTimeFormatting.date(from:
            current.last(where: { $0.role == "assistant" })?.completedAt ?? snapshot.endedAt)
        if let start, let end, SessionTimeFormatting.date(from: start) != nil {
            elapsed = SessionTimeFormatting.duration(startedAt: start, endedAt: nil, now: end)
        } else { elapsed = nil }
    }

    var progressLabel: String {
        let scope = coversCurrentTurn ? "本轮" : "近期采样"
        if let completedSteps, let totalSteps {
            return "\(scope)步骤 \(completedSteps)/\(totalSteps) · 工具调用 \(toolCalls) 次"
        }
        guard hasMessages else { return "执行器未提供结构化步骤" }
        return "\(scope)工具调用 \(toolCalls) 次"
    }

    var resultLabel: String {
        guard hasMessages else { return "工具结果未提供" }
        let pending = pendingCalls > 0 ? " · \(pendingCalls) 未收到结果" : ""
        return "工具成功 \(successfulCalls) · 失败 \(failedCalls)\(pending)"
    }

    var toolLabel: String? {
        if let currentTool { return "正在调用 \(currentTool)" }
        if let lastTool { return "最近调用 \(lastTool)" }
        return nil
    }

    private static func compact(_ value: String) -> String {
        String(value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").prefix(100))
    }
}
