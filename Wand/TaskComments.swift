import SwiftUI
import CryptoKit

struct WandTaskCommentDispatch: Decodable, Equatable {
    let employeeId: String
    let employeeName: String
    let state: String
    let sessionId: String?
    let status: String?
    let error: String?
    var deliveryUncertain: Bool { state == "pending" || state == "unknown" || status == "pending" || status == "unknown" }
    var label: String {
        switch status ?? state {
        case "running": return "执行中"
        case "blocked": return "等待审批"
        case "idle": return "本轮已结束"
        case "exited": return "会话已退出"
        case "failed": return "执行失败"
        case "stopped": return "已停止"
        case "history": return "历史会话"
        case "unavailable": return "会话不可用"
        case "accepted": return "已创建执行"
        default: return "送达未知 · 不会重放"
        }
    }
}


struct WandTaskComment: Decodable, Identifiable, Equatable {
    let id: String
    let taskId: String
    let authorName: String
    let body: String
    let createdAt: String
    var sourceCommentId: String? = nil
    var dispatch: WandTaskCommentDispatch? = nil
}

/// Persist only a digest and identity; a saved comment is not evidence of accepted execution.
struct TaskCommentRequestIdentity {
    let key: String
    let requestId: String
    private let defaults: UserDefaults
    init(taskId: String, body: String, employeeId: String, sourceCommentId: String?, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let data = (try? JSONEncoder().encode([body.trimmingCharacters(in: .whitespacesAndNewlines), employeeId, sourceCommentId ?? ""])) ?? Data()
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        key = "wand.task-comment-request." + taskId + "." + digest
        requestId = defaults.string(forKey: key) ?? UUID().uuidString
        defaults.set(requestId, forKey: key)
    }
    func settle(_ comment: WandTaskComment) {
        if comment.dispatch?.deliveryUncertain != true { defaults.removeObject(forKey: key) }
    }
}

@MainActor
final class TaskCommentsStore: ObservableObject {
    @Published private(set) var comments: [WandTaskComment] = []
    @Published private(set) var loading = false
    @Published private(set) var failed = false
    private var loadedTaskId: String?
    private var revision = UUID()

    func load(taskId: String, fetch: (String) async throws -> [WandTaskComment]) async {
        let request = UUID()
        revision = request
        if loadedTaskId != taskId { comments = [] }
        loadedTaskId = taskId
        loading = true
        failed = false
        do {
            let result = try await fetch(taskId)
            guard revision == request, !Task.isCancelled else { return }
            comments = result.filter { $0.taskId == taskId }
            loading = false
        } catch {
            // Keep successful data on refresh failure, never disguise failure as empty.
            guard revision == request, !Task.isCancelled else { return }
            failed = true
            loading = false
        }
    }
}

struct TaskCommentsSection: View {
    let comments: [WandTaskComment]
    let loading: Bool
    let failed: Bool
    let retry: () -> Void
    var onReply: (String) -> Void = { _ in }
    var onOpenSession: (String) -> Void = { _ in }

    var body: some View {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top) {
                        WandBoardSectionTitle(title: comments.isEmpty ? "评论" : "评论 · \(comments.count)", detail: comments.isEmpty ? nil : "最近 \(comments.count) 条")
                        Button("刷新评论", action: retry)
                            .buttonStyle(WandSecondaryButtonStyle())
                            .disabled(loading)
                    }
                    if failed {
                        HStack {
                            Text("评论暂时加载失败").foregroundColor(Theme.textSecondary)
                            Button("重试", action: retry).buttonStyle(WandSecondaryButtonStyle())
                        }
                    } else if comments.isEmpty {
                        Text(loading ? "正在加载评论…" : "暂无评论，任务背景与要求请查看上方描述。")
                            .font(.system(size: 12)).foregroundColor(Theme.textSecondary)
                    }
                    ForEach(comments) { comment in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 8) {
                                Text(comment.authorName).font(.system(size: 12, weight: .medium))
                                Text(formattedDate(comment.createdAt)).font(.system(size: 11)).foregroundColor(Theme.textTertiary)
                            }
                            Button("回复并 @") { onReply(comment.id) }.buttonStyle(.plain)
                            if let dispatch = comment.dispatch {
                                HStack {
                                    Text("@\(dispatch.employeeName) · \(dispatch.label)").font(.caption)
                                    if let sessionId = dispatch.sessionId { Button("查看执行") { onOpenSession(sessionId) } }
                                }
                            }
                            Text(comment.body).font(.system(size: 13)).lineSpacing(4)
                                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        }
                        .foregroundColor(Theme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Theme.surfaceSoft)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control))
                    }
                }
                .accessibilityIdentifier("task-comments")
    }

    private func formattedDate(_ value: String) -> String {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = parser.date(from: value) ?? ISO8601DateFormatter().date(from: value)
        return date?.formatted(date: .abbreviated, time: .shortened) ?? value
    }
}

enum TaskCommentMention {
    struct Query: Equatable { let start: Int; let text: String }

    static func query(in body: String, caret: Int) -> Query? {
        let chars = Array(body)
        let index = min(max(caret, 0), chars.count)
        guard index > 0, let at = chars[..<index].lastIndex(of: Character("@")) else { return nil }
        if at > 0, !chars[at - 1].isWhitespace { return nil }
        let text = String(chars[(at + 1)..<index])
        if text.contains(where: \.isWhitespace) { return nil }
        return Query(start: at, text: text)
    }

    static func insert(body: String, caret: Int, name: String) -> (body: String, caret: Int) {
        let chars = Array(body)
        let end = min(max(caret, 0), chars.count)
        let start = query(in: body, caret: end)?.start ?? end
        let token = Array("@\(name) ")
        return (String(chars[..<start] + token + chars[end...]), start + token.count)
    }

    static func holds(_ body: String, name: String) -> Bool {
        guard !name.isEmpty else { return false }
        let pattern = "(^|\\s)@\(NSRegularExpression.escapedPattern(for: name))(?=\\s|$)"
        return body.range(of: pattern, options: .regularExpression) != nil
    }

    static func caretOffset(from old: String, to new: String) -> Int {
        let previous = Array(old), next = Array(new)
        var head = 0
        while head < previous.count && head < next.count && previous[head] == next[head] { head += 1 }
        var oldEnd = previous.count, newEnd = next.count
        while oldEnd > head && newEnd > head && previous[oldEnd - 1] == next[newEnd - 1] {
            oldEnd -= 1; newEnd -= 1
        }
        return newEnd
    }
}
