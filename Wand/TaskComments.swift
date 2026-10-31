import SwiftUI
import CryptoKit

struct WandTaskCommentDispatch: Decodable, Equatable {
    let employeeId: String
    let employeeName: String
    let state: String
    let sessionId: String?
    let resultAnchor: WandTaskCommentResultAnchor?
    let status: String?
    let error: String?
    var deliveryUncertain: Bool { state == "pending" || state == "unknown" || status == "pending" || status == "unknown" }
    var label: String {
        switch status ?? state {
        case "paused": return "已暂停"
        case "queued": return "排队中"
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
    var purpose: String? = nil
    var reviewWritebackPending: Bool? = nil
}

struct WandTaskCommentResultBlock: Decodable, Hashable {
    let turnOffset: Int
    let blockIndex: Int
}

struct WandTaskCommentBlockWindowEntry {
    let blockIndex: Int
    let block: ContentBlock
    let truncated: Bool
}

struct WandTaskCommentBlockWindow: Decodable {
    var turnOffset: Int
    let hasExplicitTurnOffset: Bool
    let blockOffset: Int
    let blockTotal: Int
    let blocks: [WandTaskCommentBlockWindowEntry]

    private struct WrappedEntry: Decodable {
        let blockIndex: Int
        let block: ContentBlock
        let truncated: Bool?
    }
    private struct Handle: Decodable { let turnOffset: Int; let blockIndex: Int }
    private enum CodingKeys: String, CodingKey { case turnOffset, blockOffset, blockTotal, blocks, truncatedBlocks }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Older servers return a turn-local block page without echoing turnOffset;
        // the request scope remains authoritative for that response shape.
        let decodedTurnOffset = try? c.decode(Int.self, forKey: .turnOffset)
        hasExplicitTurnOffset = decodedTurnOffset != nil
        let decodedBlockOffset = (try? c.decode(Int.self, forKey: .blockOffset)) ?? 0
        turnOffset = decodedTurnOffset ?? -1
        blockOffset = decodedBlockOffset
        let handles = (try? c.decode([Handle].self, forKey: .truncatedBlocks)) ?? []
        let explicitTotal = try? c.decode(Int.self, forKey: .blockTotal)
        let decodedHandles = handles
        let decodedHasTurnOffset = hasExplicitTurnOffset
        let decodedTurnCoordinate = decodedTurnOffset ?? -1
        func isTruncated(_ index: Int) -> Bool {
            decodedHandles.contains { $0.blockIndex == index && (!decodedHasTurnOffset || $0.turnOffset == decodedTurnCoordinate) }
        }
        let decodedBlocks: [WandTaskCommentBlockWindowEntry]
        let decodedTotal: Int
        if let wrapped = try? c.decode([WrappedEntry].self, forKey: .blocks) {
            decodedBlocks = wrapped.map { entry in .init(blockIndex: entry.blockIndex, block: entry.block, truncated: entry.truncated ?? isTruncated(entry.blockIndex)) }
            decodedTotal = explicitTotal ?? decodedBlockOffset + wrapped.count
        } else {
            let raw = try c.decode([ContentBlock].self, forKey: .blocks)
            decodedBlocks = raw.enumerated().map { index, block in
                let absoluteIndex = decodedBlockOffset + index
                return .init(blockIndex: absoluteIndex, block: block, truncated: isTruncated(absoluteIndex))
            }
            guard let explicitTotal else { throw DecodingError.keyNotFound(CodingKeys.blockTotal, .init(codingPath: decoder.codingPath, debugDescription: "Missing blockTotal")) }
            decodedTotal = explicitTotal
        }
        blocks = decodedBlocks
        blockTotal = decodedTotal
        guard (!hasExplicitTurnOffset || turnOffset >= 0), blockOffset >= 0, blockTotal >= blockOffset else {
            throw DecodingError.dataCorruptedError(forKey: .blockOffset, in: c, debugDescription: "Invalid absolute block window coordinates")
        }
    }
}

struct WandTaskCommentToolContent {
    let input: [String: JSONValue]
    let content: JSONValue
    let isError: Bool
    let pending: Bool
}

struct WandTaskCommentResultAnchor: Decodable, Equatable {
    let requestId: String
    let fingerprint: String
    let startIndex: Int
    let endIndex: Int?
    let outcome: String?
}

struct WandTaskCommentResultResponse: Decodable {
    let available: Bool
    let reason: String?
    let sessionId: String?
    let outcome: String?
    let messages: [ConversationTurn]
    let truncatedBlocks: [WandTaskCommentResultBlock]?
    let blockOffset: Int?
    let blockTotal: Int?
    let offset: Int?
    let total: Int?

    init(available: Bool, reason: String?, sessionId: String?, outcome: String?, messages: [ConversationTurn], truncatedBlocks: [WandTaskCommentResultBlock]? = nil, blockOffset: Int? = nil, blockTotal: Int? = nil, offset: Int?, total: Int?) {
        self.available = available; self.reason = reason; self.sessionId = sessionId
        self.outcome = outcome; self.messages = messages; self.truncatedBlocks = truncatedBlocks
        self.blockOffset = blockOffset; self.blockTotal = blockTotal; self.offset = offset; self.total = total
        self.blockWindow = nil
    }

    let blockWindow: WandTaskCommentBlockWindow?

    private enum CodingKeys: String, CodingKey { case available, reason, sessionId, outcome, messages, truncatedBlocks, blockOffset, blockTotal, offset, total, blockWindow }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        available = (try? container.decode(Bool.self, forKey: .available)) ?? false
        reason = try? container.decodeIfPresent(String.self, forKey: .reason)
        sessionId = try? container.decodeIfPresent(String.self, forKey: .sessionId)
        outcome = try? container.decodeIfPresent(String.self, forKey: .outcome)
        messages = (try? container.decode([ConversationTurn].self, forKey: .messages)) ?? []
        truncatedBlocks = try? container.decodeIfPresent([WandTaskCommentResultBlock].self, forKey: .truncatedBlocks)
        blockOffset = try? container.decodeIfPresent(Int.self, forKey: .blockOffset)
        blockTotal = try? container.decodeIfPresent(Int.self, forKey: .blockTotal)
        offset = try? container.decodeIfPresent(Int.self, forKey: .offset)
        total = try? container.decodeIfPresent(Int.self, forKey: .total)
        blockWindow = try? container.decodeIfPresent(WandTaskCommentBlockWindow.self, forKey: .blockWindow)
    }

    var unavailableReason: String? {
        guard !available else { return nil }
        switch reason {
        case "unconfirmed_legacy": return "原执行轮次无法确认。"
        case "execution_not_started": return "该员工执行未开始，暂无结果。"
        case "still_running": return "该员工仍在执行，暂无可确认的结果。执行结束后刷新查看。"
        default: return "原执行结果不可用。"
        }
    }
}

/// Persist only a digest and identity; a saved comment is not evidence of accepted execution.
struct TaskCommentRequestIdentity {
    let key: String
    let requestId: String
    let purpose: String
    private let defaults: UserDefaults
    init(taskId: String, body: String, employeeId: String, sourceCommentId: String?, purpose: String = "execution", defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let data = (try? JSONEncoder().encode([body.trimmingCharacters(in: .whitespacesAndNewlines), employeeId, sourceCommentId ?? ""])) ?? Data()
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        key = "wand.task-comment-request." + taskId + "." + digest
        let saved = defaults.string(forKey: key)
        requestId = saved ?? UUID().uuidString
        self.purpose = defaults.string(forKey: key + ".purpose") ?? (saved == nil ? purpose : "execution")
        defaults.set(requestId, forKey: key); defaults.set(self.purpose, forKey: key + ".purpose")
    }
    func settle(_ comment: WandTaskComment) {
        if comment.dispatch?.deliveryUncertain != true { defaults.removeObject(forKey: key); defaults.removeObject(forKey: key + ".purpose") }
    }
}

struct WandTaskCommentStatus: Decodable {
    let id: String
    let dispatch: WandTaskCommentDispatch?
    let includesDispatch: Bool
    var reviewWritebackPending: Bool? = nil

    init(id: String, dispatch: WandTaskCommentDispatch?, includesDispatch: Bool = true) {
        self.id = id; self.dispatch = dispatch; self.includesDispatch = includesDispatch
    }

    private enum CodingKeys: String, CodingKey { case id, dispatch, reviewWritebackPending }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        includesDispatch = container.contains(.dispatch)
        dispatch = try? container.decodeIfPresent(WandTaskCommentDispatch.self, forKey: .dispatch)
        reviewWritebackPending = try? container.decodeIfPresent(Bool.self, forKey: .reviewWritebackPending)
    }
}

struct WandTaskCommentStatuses: Decodable {
    let comments: [WandTaskCommentStatus]

    init(comments: [WandTaskCommentStatus]) { self.comments = comments }
}

struct WandTaskCommentsPage: Decodable {
    let comments: [WandTaskComment]
    let totalCount: Int
    let nextCursor: String?

    init(comments: [WandTaskComment], totalCount: Int, nextCursor: String?) {
        self.comments = comments
        self.totalCount = totalCount
        self.nextCursor = nextCursor
    }
}

@MainActor
final class TaskCommentsStore: ObservableObject {
    @Published private(set) var comments: [WandTaskComment] = []
    @Published private(set) var totalCount = 0
    @Published private(set) var loading = false
    @Published private(set) var loadingOlder = false
    @Published private(set) var failed = false
    @Published private(set) var olderPageFailed = false
    private(set) var nextCursor: String?
    private var loadedTaskId: String?
    private var taskGeneration = UUID()
    private var refreshGeneration = UUID()
    private var statusGeneration = UUID()
    private var olderPageGeneration = UUID()
    private var loadedOlderPage = false

    var hasOlderPage: Bool { nextCursor != nil }

    func load(taskId: String, fetch: (String, String?, Int) async throws -> WandTaskCommentsPage, limit: Int = 50) async {
        if loadedTaskId != taskId {
            loadedTaskId = taskId
            taskGeneration = UUID()
            comments = []; totalCount = 0; nextCursor = nil
            olderPageFailed = false; loadingOlder = false; loadedOlderPage = false
        }
        let taskRequest = taskGeneration
        let request = UUID()
        refreshGeneration = request
        statusGeneration = UUID()
        olderPageGeneration = UUID()
        loading = true
        defer {
            if taskGeneration == taskRequest, refreshGeneration == request, loadedTaskId == taskId {
                loading = false
            }
        }
        loadingOlder = false
        failed = false
        do {
            let page = try await fetch(taskId, nil, limit)
            guard taskGeneration == taskRequest, refreshGeneration == request, loadedTaskId == taskId, !Task.isCancelled else { return }
            let firstPage = page.comments.filter { $0.taskId == taskId }
            // Polling refreshes the newest page without dropping older pages the user loaded.
            // Fresh rows win by ID so dispatch status changes are reflected in both projections.
            comments = unique(firstPage + comments.filter { $0.taskId == taskId })
            totalCount = max(0, page.totalCount)
            // Keep the user's current pagination position during periodic refreshes.
            // Only initialize/advance it from the first page before older pages were loaded.
            if !loadedOlderPage { nextCursor = page.nextCursor }
            if !loadingOlder { loading = false }
        } catch {
            // Keep successful data on refresh failure, never disguise failure as empty.
            guard taskGeneration == taskRequest, refreshGeneration == request, loadedTaskId == taskId, !Task.isCancelled else { return }
            failed = true
            loading = false
        }
    }

    func refreshStatuses(taskId: String, fetch: (String, [String]) async throws -> WandTaskCommentStatuses) async {
        guard loadedTaskId == taskId, !comments.isEmpty else { return }
        let taskRequest = taskGeneration
        let request = UUID()
        statusGeneration = request
        let ids = Array(Set(comments.filter { $0.taskId == taskId }.map(\.id))).sorted()
        do {
            var statuses: [String: WandTaskCommentStatus] = [:]
            for start in stride(from: 0, to: ids.count, by: 100) {
                try Task.checkCancellation()
                let batch = Array(ids[start..<min(start + 100, ids.count)])
                let response = try await fetch(taskId, batch)
                guard taskGeneration == taskRequest, statusGeneration == request, loadedTaskId == taskId, !Task.isCancelled else { return }
                for item in response.comments where batch.contains(item.id) { statuses[item.id] = item }
            }
            guard taskGeneration == taskRequest, statusGeneration == request, loadedTaskId == taskId, !Task.isCancelled else { return }
            comments = comments.map { comment in
                guard comment.taskId == taskId, let status = statuses[comment.id], status.includesDispatch else { return comment }
                return WandTaskComment(id: comment.id, taskId: comment.taskId, authorName: comment.authorName, body: comment.body,
                    createdAt: comment.createdAt, sourceCommentId: comment.sourceCommentId, dispatch: status.dispatch, purpose: comment.purpose, reviewWritebackPending: status.reviewWritebackPending ?? comment.reviewWritebackPending)
            }
        } catch {
            // Status is a supplemental projection; a failed refresh must not erase loaded comments.
        }
    }

    func loadOlder(taskId: String, fetch: (String, String?, Int) async throws -> WandTaskCommentsPage, limit: Int = 50) async {
        guard loadedTaskId == taskId, let cursor = nextCursor, !loadingOlder else { return }
        let taskRequest = taskGeneration
        let refreshRequest = refreshGeneration
        let request = UUID()
        olderPageGeneration = request
        let olderRequest = request
        loadingOlder = true
        olderPageFailed = false
        defer {
            if taskGeneration == taskRequest, refreshGeneration == refreshRequest, olderPageGeneration == olderRequest,
               loadedTaskId == taskId {
                loadingOlder = false
            }
        }
        do {
            let page = try await fetch(taskId, cursor, limit)
            guard taskGeneration == taskRequest, refreshGeneration == refreshRequest, olderPageGeneration == request,
                  loadedTaskId == taskId, !Task.isCancelled else { return }
            comments = unique(comments + page.comments.filter { $0.taskId == taskId })
            totalCount = max(0, page.totalCount)
            nextCursor = page.nextCursor
            loadedOlderPage = true
            loadingOlder = false
        } catch {
            guard taskGeneration == taskRequest, refreshGeneration == refreshRequest, olderPageGeneration == request,
                  loadedTaskId == taskId, !Task.isCancelled else { return }
            olderPageFailed = true
            loadingOlder = false
        }
    }

    private func unique(_ values: [WandTaskComment]) -> [WandTaskComment] {
        var byId: [String: WandTaskComment] = [:]
        // Input order is newest-page first, so retain the first (freshest) copy.
        for value in values where byId[value.id] == nil { byId[value.id] = value }
        return byId.values.sorted {
            $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt
        }
    }
}

struct TaskCommentItemRow: View {
    let comment: WandTaskComment
    let onReply: () -> Void
    let onOpenExecution: (() -> Void)?
    let onOpenSession: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(comment.authorName).font(.system(size: 12, weight: .medium))
                if comment.reviewWritebackPending == true { Text("验收结论待回填").font(.caption).foregroundColor(Theme.warning) }
                Text(comment.createdAt).font(.system(size: 11)).foregroundColor(Theme.textTertiary)
                Spacer()
                if let dispatch = comment.dispatch {
                    Text("已派发给 @\(dispatch.employeeName)").font(.caption).foregroundColor(Theme.textSecondary)
                    if let sessionId = dispatch.sessionId {
                        Button("查看执行事项") { onOpenExecution?() }.buttonStyle(.plain)
                        Button("打开会话") { onOpenSession(sessionId) }.buttonStyle(.plain)
                    }
                }
                Button("回复并 @", action: onReply).buttonStyle(.plain)
            }
            Text(comment.body).font(.system(size: 13)).lineSpacing(4).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surfaceSoft)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control))
    }
}

struct TaskCommentExecutionItemRow: View {
    let comment: WandTaskComment
    let api: WandAPI?
    let expanded: Bool
    let onToggle: (Bool) -> Void
    let onOpenComment: () -> Void
    let onOpenSession: (String) -> Void
    @State private var result: WandTaskCommentResultResponse?
    @State private var loadingResult = false
    @State private var resultFailed = false
    @State private var fullBlockContent: [String: String] = [:]
    @State private var loadingBlockIds: Set<String> = []
    @State private var blockLoadFailed: Set<String> = []
    @State private var blockWindows: [Int: [WandTaskCommentBlockWindowEntry]] = [:]
    @State private var windowOffsets: [Int: Int] = [:]
    @State private var windowTotals: [Int: Int] = [:]
    @State private var loadingWindows: Set<Int> = []
    @State private var failedWindows: Set<Int> = []
    @State private var loadedTools: [String: WandTaskCommentToolContent] = [:]
    @State private var loadingTools: Set<String> = []
    @State private var failedTools: Set<String> = []
    @State private var requestId = UUID()
    @State private var blockGeneration = UUID()
    private let pageSize = 40

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "person.crop.circle.badge.checkmark").foregroundColor(Theme.wandAccent)
                Text("员工执行").font(.system(size: 12, weight: .semibold))
                Text("@\(comment.dispatch?.employeeName ?? "员工")").font(.system(size: 12))
                Spacer()
                Text(comment.dispatch?.label ?? "状态未知").font(.caption).foregroundColor(Theme.textSecondary)
            }
            HStack {
                Text(comment.createdAt).font(.system(size: 11)).foregroundColor(Theme.textTertiary)
                Spacer()
                Button("查看原评论") { onOpenComment() }.buttonStyle(.plain)
                if let sessionId = comment.dispatch?.sessionId {
                    Button("打开对应会话") { onOpenSession(sessionId) }.buttonStyle(.plain)
                }
            }
            DisclosureGroup(isExpanded: Binding(get: { expanded }, set: onToggle)) {
                if let result {
                    if let unavailable = result.unavailableReason {
                        Text(unavailable).font(.caption).foregroundColor(Theme.textSecondary)
                    } else {
                        ForEach(Array(result.messages.enumerated()), id: \.offset) { turnOffset, turn in
                            let absoluteTurn = (result.offset ?? 0) + turnOffset
                            let turnBlockOffset = turn.blockOffset ?? 0
                            let turnBlockTotal = turn.blockTotal ?? turn.content.count
                            let initialTurnContent = turn.content
                            let boundedTurn = ConversationTurn(role: turn.role, content: initialTurnContent)
                            TurnView(turn: boundedTurn, showHeader: false, interactiveTools: false).padding(.vertical, 4)
                            let nextBlockOffset = windowOffsets[absoluteTurn] ?? (turnBlockOffset + initialTurnContent.count)
                            let totalBlocks = windowTotals[absoluteTurn] ?? turnBlockTotal
                            if nextBlockOffset < totalBlocks {
                                Button(loadingWindows.contains(absoluteTurn) ? "正在加载…" : failedWindows.contains(absoluteTurn) ? "重试加载执行记录" : "加载该轮执行记录（\(nextBlockOffset)/\(totalBlocks)）") { loadBlockWindow(turnOffset: absoluteTurn) }
                                    .disabled(loadingWindows.contains(absoluteTurn))
                            }
                            ForEach(blockWindows[absoluteTurn] ?? [], id: \.blockIndex) { entry in
                                VStack(alignment: .leading, spacing: 4) {
                                    windowBlockView(entry.block)
                                    if entry.truncated {
                                        let key = "\(absoluteTurn):\(entry.blockIndex)"
                                        Button(loadingBlockIds.contains(key) ? "正在读取完整内容…" : blockLoadFailed.contains(key) ? "重试读取完整内容" : "读取完整内容") { loadBlock(turnOffset: absoluteTurn, blockIndex: entry.blockIndex) }
                                            .disabled(loadingBlockIds.contains(key))
                                        if let content = fullBlockContent[key] { Text(content).font(.system(size: 11, design: .monospaced)).textSelection(.enabled) }
                                    }
                                }.padding(.vertical, 3)
                            }
                            ForEach(Array((result.truncatedBlocks ?? []).filter { $0.turnOffset == absoluteTurn }), id: \.blockIndex) { block in
                                let key = "\(block.turnOffset):\(block.blockIndex)"
                                Button(loadingBlockIds.contains(key) ? "正在读取完整内容…" : blockLoadFailed.contains(key) ? "重试读取完整内容" : "读取完整内容") { loadBlock(turnOffset: block.turnOffset, blockIndex: block.blockIndex) }.disabled(loadingBlockIds.contains(key))
                                if let content = fullBlockContent[key] { Text(content).font(.system(size: 11, design: .monospaced)).textSelection(.enabled) }
                            }
                        }
                        if let total = result.total, (result.offset ?? 0) + result.messages.count < total {
                            Button(loadingResult ? "正在加载…" : "加载更多结果（\((result.offset ?? 0) + result.messages.count)/\(total)）") { loadResult(offset: (result.offset ?? 0) + result.messages.count) }
                                .disabled(loadingResult).buttonStyle(.plain)
                        }
                    }
                } else if loadingResult {
                    ProgressView("正在加载原执行结果…").controlSize(.small)
                } else if resultFailed {
                    Text("原执行结果暂时无法加载。").font(.caption).foregroundColor(Theme.textSecondary)
                    Button("重试") { loadResult(offset: 0) }.buttonStyle(.plain)
                } else {
                    Text(comment.dispatch?.resultAnchor == nil ? "原执行轮次无法确认。" : "展开后加载该执行轮次的只读结果。")
                        .font(.caption).foregroundColor(Theme.textSecondary)
                }
            } label: {
                Text(result == nil ? "查看原执行结果" : "原执行结果 · \(result?.outcome ?? "进行中")")
                    .font(.system(size: 12, weight: .medium))
            }
            .onChange(of: comment.dispatch?.resultAnchor) { anchor in
                result = nil
                fullBlockContent = [:]; loadingBlockIds = []; blockLoadFailed = []
                blockWindows = [:]; windowOffsets = [:]; windowTotals = [:]; loadingWindows = []; failedWindows = []
                loadedTools = [:]; loadingTools = []; failedTools = []
                requestId = UUID(); blockGeneration = UUID()
                loadingResult = false
                resultFailed = false
                guard anchor != nil, expanded else { return }
                loadResult(offset: 0)
            }
            .onChange(of: expanded) { open in
                if open && result == nil && !loadingResult { loadResult(offset: 0) }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surfaceSoft)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control))
    }

    @ViewBuilder private func windowBlockView(_ block: ContentBlock) -> some View {
        switch block {
        case .text(let text, _): Text(text).textSelection(.enabled)
        case .thinking(let thinking, _): Text(thinking).foregroundColor(Theme.textSecondary).textSelection(.enabled)
        case .toolUse(let id, let name, _, let input, _):
            VStack(alignment: .leading, spacing: 3) {
                Text("\(name) · \(id)").font(.system(size: 11, weight: .medium, design: .monospaced))
                Text(JSONValue.object(input).prettyPrintedJSON).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                Button(loadingTools.contains(id) ? "正在读取工具详情…" : failedTools.contains(id) ? "重试读取工具详情" : "查看完整工具输入与结果") { loadTool(id) }
                    .disabled(loadingTools.contains(id))
                if let tool = loadedTools[id] {
                    Text("调用输入").font(.caption.weight(.semibold))
                    Text(JSONValue.object(tool.input).prettyPrintedJSON).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    Text(tool.pending ? "工具结果尚未返回" : "工具结果").font(.caption.weight(.semibold))
                    Text(tool.content.prettyPrintedJSON).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                }
            }
        case .toolResult(let id, let text, let isError, _, _, _):
            VStack(alignment: .leading, spacing: 3) {
                Text("\(isError ? "工具错误" : "工具结果") · \(id)").font(.system(size: 11, design: .monospaced))
                Text(text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                Button(loadingTools.contains(id) ? "正在读取工具详情…" : failedTools.contains(id) ? "重试读取工具详情" : "查看完整工具输入与结果") { loadTool(id) }
                    .disabled(loadingTools.contains(id))
                if let tool = loadedTools[id] {
                    Text("调用输入").font(.caption.weight(.semibold))
                    Text(JSONValue.object(tool.input).prettyPrintedJSON).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    Text(tool.pending ? "工具结果尚未返回" : tool.isError ? "工具错误结果" : "工具结果").font(.caption.weight(.semibold))
                    Text(tool.content.prettyPrintedJSON).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                }
            }
        case .unknown: EmptyView()
        }
    }

    private func loadBlock(turnOffset: Int, blockIndex: Int) {
        let key = "\(turnOffset):\(blockIndex)"
        guard !loadingBlockIds.contains(key), let api else { return }
        let generation = blockGeneration
        loadingBlockIds.insert(key); blockLoadFailed.remove(key)
        Task {
            do {
                let value = try await api.boardTaskCommentResultBlock(taskId: comment.taskId, commentId: comment.id, turnOffset: turnOffset, blockIndex: blockIndex)
                await MainActor.run {
                    guard blockGeneration == generation, !Task.isCancelled else { return }
                    fullBlockContent[key] = value; loadingBlockIds.remove(key)
                }
            } catch {
                await MainActor.run {
                    guard blockGeneration == generation, !Task.isCancelled else { return }
                    loadingBlockIds.remove(key); blockLoadFailed.insert(key)
                }
            }
        }
    }

    private func loadBlockWindow(turnOffset: Int) {
        guard let api, !loadingWindows.contains(turnOffset) else { return }
        let generation = blockGeneration
        let offset = windowOffsets[turnOffset] ?? result?.messages.enumerated().first(where: { (result?.offset ?? 0) + $0.offset == turnOffset }).map { ($0.element.blockOffset ?? 0) + $0.element.content.count } ?? 0
        loadingWindows.insert(turnOffset); failedWindows.remove(turnOffset)
        Task {
            do {
                let page = try await api.boardTaskCommentBlockWindow(taskId: comment.taskId, commentId: comment.id, turnOffset: turnOffset, blockOffset: offset)
                let expectedTotal = windowTotals[turnOffset] ?? result?.messages.enumerated().first(where: { (result?.offset ?? 0) + $0.offset == turnOffset }).map { $0.element.blockTotal ?? $0.element.content.count }
                guard blockGeneration == generation, !Task.isCancelled,
                      page.turnOffset == turnOffset, page.blockOffset == offset,
                      page.blockTotal >= 0, page.blockTotal <= 100_000,
                      expectedTotal == nil || page.blockTotal == expectedTotal,
                      offset <= page.blockTotal, page.blocks.count <= 64,
                      page.blocks.enumerated().allSatisfy({ offset + $0.offset == $0.element.blockIndex && $0.element.blockIndex < page.blockTotal }),
                      !page.blocks.isEmpty || offset == page.blockTotal else { throw URLError(.cannotParseResponse) }
                await MainActor.run {
                    guard blockGeneration == generation else { return }
                    var merged = Dictionary((blockWindows[turnOffset] ?? []).map { ($0.blockIndex, $0) }, uniquingKeysWith: { first, _ in first })
                        for entry in page.blocks { merged[entry.blockIndex] = entry }
                    blockWindows[turnOffset] = merged.values.sorted { $0.blockIndex < $1.blockIndex }
                    windowOffsets[turnOffset] = page.blockOffset + page.blocks.count
                    windowTotals[turnOffset] = page.blockTotal
                    loadingWindows.remove(turnOffset)
                }
            } catch {
                await MainActor.run {
                    guard blockGeneration == generation else { return }
                    loadingWindows.remove(turnOffset); failedWindows.insert(turnOffset)
                }
            }
        }
    }

    private func loadTool(_ toolId: String) {
        guard let api, !loadingTools.contains(toolId) else { return }
        let generation = blockGeneration
        loadingTools.insert(toolId); failedTools.remove(toolId)
        Task {
            do {
                let value = try await api.boardTaskCommentToolContent(taskId: comment.taskId, commentId: comment.id, toolId: toolId)
                await MainActor.run {
                    guard blockGeneration == generation, !Task.isCancelled else { return }
                    loadedTools[toolId] = value; loadingTools.remove(toolId)
                }
            } catch {
                await MainActor.run {
                    guard blockGeneration == generation, !Task.isCancelled else { return }
                    loadingTools.remove(toolId); failedTools.insert(toolId)
                }
            }
        }
    }

    private func loadResult(offset: Int) {
        guard api != nil, comment.dispatch?.resultAnchor != nil else { return }
        let generation = UUID(); requestId = generation
        loadingResult = true; resultFailed = false
        Task {
            do {
                guard let api else { return }
                let value = try await api.boardTaskCommentResult(taskId: comment.taskId, commentId: comment.id, offset: offset, limit: pageSize)
                guard requestId == generation, !Task.isCancelled else { return }
                if offset == 0 || value.available == false { result = value }
                else if let current = result {
                    let currentOffset = current.offset ?? 0
                    let merged = WandTaskCommentResultResponse(available: value.available, reason: value.reason, sessionId: value.sessionId, outcome: value.outcome,
                        messages: current.messages + value.messages,
                        truncatedBlocks: (current.truncatedBlocks ?? []) + (value.truncatedBlocks ?? []),
                        blockOffset: current.blockOffset, blockTotal: value.blockTotal,
                        offset: currentOffset, total: value.total)
                    result = merged
                }
                loadingResult = false
            } catch {
                guard requestId == generation, !Task.isCancelled else { return }
                resultFailed = true; loadingResult = false
            }
        }
    }
}

struct TaskCommentsSection: View {
    let comments: [WandTaskComment]
    let totalCount: Int
    let loading: Bool
    let loadingOlder: Bool
    let olderPageFailed: Bool
    let hasOlderPage: Bool
    let failed: Bool
    let retry: () -> Void
    let loadOlder: () -> Void
    var onReply: (String) -> Void = { _ in }
    var onOpenSession: (String) -> Void = { _ in }
    var onOpenExecution: (String) -> Void = { _ in }
    var commentToReveal: String? = nil
    var onRevealed: () -> Void = {}
    var onRevealComment: (String) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            WandBoardSectionTitle(title: "评论", detail: "共 \(totalCount) 条")
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
                TaskCommentItemRow(comment: comment, onReply: { onReply(comment.id) }, onOpenExecution: { onOpenExecution(comment.id) }, onOpenSession: onOpenSession)
                    .id("comment-\(comment.id)")
            }
            if hasOlderPage {
                Button(loadingOlder ? "正在加载更早评论…" : olderPageFailed ? "重试加载更早评论" : "加载更早评论") { loadOlder() }
                    .buttonStyle(WandSecondaryButtonStyle()).disabled(loadingOlder)
            }
            if !comments.isEmpty { Button("刷新评论", action: retry).buttonStyle(.plain).disabled(loading) }
        }
        .accessibilityIdentifier("task-comments")
        .onChange(of: comments.map(\.id)) { ids in
            guard let commentToReveal else { return }
            if commentToReveal == "__latest__", let latest = comments.last?.id {
                DispatchQueue.main.async { onRevealComment(latest) }
            } else if ids.contains(commentToReveal) {
                DispatchQueue.main.async { onRevealed() }
            }
        }
        .onAppear {
            guard let commentToReveal else { return }
            if commentToReveal == "__latest__", let latest = comments.last?.id {
                DispatchQueue.main.async { onRevealComment(latest) }
            } else if comments.contains(where: { $0.id == commentToReveal }) {
                DispatchQueue.main.async { onRevealed() }
            }
        }
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
        let combined = String(chars[..<start] + token + chars[end...])
        let normalized = removeLeadingSelectedMention(combined, name: name)
        return (normalized, min(normalized.count, start + token.count))
    }

    static func removeLeadingSelectedMention(_ body: String, name: String) -> String {
        guard !name.isEmpty else { return body }
        let pattern = "^(?:@\(NSRegularExpression.escapedPattern(for: name))\\s+)+"
        return body.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
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
