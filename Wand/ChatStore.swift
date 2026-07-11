import Foundation
import Combine

/// AskUserQuestion 卡片的本地选择状态（对齐 Web 端 state.askUserSelections）。
struct AskUserSelectionState {
    /// questionIndex → 已选 optionIndex 集合。
    var selected: [Int: Set<Int>] = [:]
    var submitted = false
}

/// 单个会话的状态机：拉取快照、订阅 WebSocket、合并增量推送、发送输入与权限决策。
/// 合流规则对齐浏览器端 websocket.ts：
///   - init / messages 全量 → 直接替换
///   - incremental + lastMessage → 末条同 role 时替换，否则按 messageCount 追加
///   - chunk-only 事件是终端视图的，聊天视图直接忽略
@MainActor
final class ChatStore: ObservableObject {
    @Published var messages: [ConversationTurn] = []
    @Published var isResponding = false
    @Published var status: String = "running"
    @Published var queuedMessages: [String] = []
    @Published var pendingEscalation: EscalationRequest?
    /// PTY 旧式权限提示（permissionBlocked 为 true 但没有结构化 escalation 时）。
    @Published var legacyPermissionPrompt: PermissionRequestInfo?
    @Published var permissionBlocked = false
    @Published var currentTaskTitle: String?
    @Published var connected = true
    @Published var loading = true
    @Published var loadError: String?
    @Published var toast: String?
    @Published var availableModels: [ModelInfo] = []
    @Published var defaultModel: String?
    @Published var selectedModel: String?
    @Published var thinkingEffort = "off"
    /// AskUserQuestion 卡片的选择状态（toolUseId → 各题已选项 + 是否已提交）。
    /// 放 store 而非卡片 @State：流式推送会整条替换消息重建视图，局部状态会丢。
    @Published var askUserSelections: [String: AskUserSelectionState] = [:]
    // 消息窗口化：messages 是完整历史的后缀，loadedOffset = messages[0] 的绝对下标。
    @Published private(set) var loadedOffset = 0
    @Published private(set) var messageTotal = 0
    @Published private(set) var loadingEarlier = false

    let sessionId: String
    let api: WandAPI
    @Published private(set) var snapshot: SessionSnapshot?
    private let socket: WandSocket
    private var started = false
    private let earlierPageSize = 40
    private var queuePromotePending = false

    var isStructured: Bool { snapshot?.isStructured ?? true }
    var sessionEnded: Bool { ["exited", "failed", "stopped"].contains(status) }
    var canLoadEarlier: Bool { loadedOffset > 0 }
    private var isInFlight: Bool { isStructured && isResponding && status == "running" }

    init(sessionId: String, api: WandAPI) {
        self.sessionId = sessionId
        self.api = api
        self.socket = WandSocket(baseURL: api.baseURL)
    }

    // MARK: - 生命周期

    func start() {
        guard !started else { return }
        started = true

        // WandSocket 的回调已保证主线程，用 assumeIsolated 接回 MainActor 隔离，
        // 不用 Task 包装——Task 不保证 FIFO，会打乱增量合流顺序。
        socket.onEvent = { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        socket.onConnectionChange = { [weak self] up in
            MainActor.assumeIsolated { self?.connected = up }
        }

        Task {
            do {
                let snap = try await api.getSession(id: sessionId)
                apply(snapshot: snap)
                loading = false
            } catch {
                loading = false
                loadError = error.localizedDescription
            }
            await loadModels()
            socket.connect()
            socket.subscribe(sessionId: sessionId)
        }
    }

    func shutdown() {
        socket.close()
    }

    // MARK: - 推送合流

    /// 应用一份窗口化消息快照。服务端 init/output/ended 可能只给最近一窗；
    /// 本地如果已经加载过更早前缀，需要保留，避免用户刚展开历史又被 WS 尾窗覆盖。
    private func applyWindowedMessages(_ incoming: [ConversationTurn]?, offset: Int?, total: Int?) {
        guard let incoming else { return }
        let snapOffset = offset ?? 0
        let snapTotal = total ?? max(snapOffset + incoming.count, incoming.count)
        if incoming.isEmpty, !messages.isEmpty, snapTotal == 0 { return }

        if messages.isEmpty {
            messages = incoming
            loadedOffset = snapOffset
        } else if loadedOffset <= snapOffset {
            let keep = min(max(snapOffset - loadedOffset, 0), messages.count)
            messages = Array(messages.prefix(keep)) + incoming
        } else {
            messages = incoming
            loadedOffset = snapOffset
        }
        messageTotal = max(snapTotal, loadedOffset + messages.count)
    }

    private func apply(snapshot snap: SessionSnapshot) {
        self.snapshot = snap
        applyWindowedMessages(snap.messages, offset: snap.messageOffset, total: snap.messageTotal)
        status = snap.status ?? status
        isResponding = snap.isResponding
        queuedMessages = snap.queuedMessages ?? []
        pendingEscalation = snap.pendingEscalation
        permissionBlocked = snap.permissionBlocked ?? (snap.pendingEscalation != nil)
        currentTaskTitle = snap.currentTaskTitle
        selectedModel = snap.selectedModel
        thinkingEffort = snap.thinkingEffort ?? "off"
        if snap.pendingEscalation != nil { legacyPermissionPrompt = nil }
    }

    private func handle(_ event: WsIncoming) {
        guard event.sessionId == sessionId || event.sessionId == nil else { return }
        switch event.type {
        case "init":
            if let data = event.data {
                applyWsSnapshot(data)
                loading = false
            }
        case "output":
            if let data = event.data { applyOutput(data) }
        case "status":
            if let data = event.data { applyStatus(data) }
        case "ended":
            if let data = event.data {
                applyWindowedMessages(data.messages, offset: data.messageOffset, total: data.messageTotal)
                status = data.status ?? "exited"
                isResponding = false
                applyCommonFields(data)
            } else {
                status = "exited"
                isResponding = false
            }
        case "error":
            if let message = event.error, !message.isEmpty { toast = message }
        default:
            break
        }
    }

    /// init 的 data 就是一份完整 SessionSnapshot（以 WsData 超集形状承接）。
    private func applyWsSnapshot(_ data: WsData) {
        applyWindowedMessages(data.messages, offset: data.messageOffset, total: data.messageTotal)
        status = data.status ?? status
        if let s = data.structuredState { isResponding = s.inFlight ?? false }
        applyCommonFields(data)
        if snapshot == nil, let id = data.id {
            // 极端情况：REST 快照还没回来 WS init 先到，补一份最小 snapshot。
            snapshot = SessionSnapshot(
                id: id, sessionKind: data.sessionKind, provider: data.provider,
                runner: data.runner, command: data.command, cwd: data.cwd,
                mode: data.mode, status: data.status, exitCode: data.exitCode,
                startedAt: data.startedAt, endedAt: data.endedAt, archived: data.archived,
                summary: data.summary, currentTaskTitle: data.currentTaskTitle,
                selectedModel: data.selectedModel, thinkingEffort: data.thinkingEffort,
                claudeSessionId: data.claudeSessionId,
                messages: nil, messageOffset: data.messageOffset, messageTotal: data.messageTotal,
                queuedMessages: data.queuedMessages,
                structuredState: data.structuredState, pendingEscalation: data.pendingEscalation,
                permissionBlocked: data.permissionBlocked,
                autoApprovePermissions: data.autoApprovePermissions
            )
        }
    }

    private func applyOutput(_ data: WsData) {
        let incremental = data.incremental ?? false
        if let msgs = data.messages {
            // 全量赢（窗口合并：保留已加载的更早前缀）。
            applyWindowedMessages(msgs, offset: data.messageOffset, total: data.messageTotal)
        } else if incremental, let incoming = data.lastMessage {
            let expected = data.messageCount ?? 0
            if let last = messages.last, last.role == incoming.role {
                messages[messages.count - 1] = incoming
            } else if loadedOffset + messages.count < expected || expected == 0 {
                messages.append(incoming)
            }
            if expected > 0 { messageTotal = max(messageTotal, expected) }
        }
        if let responding = data.isResponding { isResponding = responding }
        applyCommonFields(data)
    }

    private func applyStatus(_ data: WsData) {
        if let s = data.status { status = s }
        applyCommonFields(data)
        // PTY 旧式权限提示：status 事件带 permissionRequest（无结构化 escalation 时启用）。
        if let prompt = data.permissionRequest, pendingEscalation == nil {
            legacyPermissionPrompt = prompt
            permissionBlocked = true
        }
    }

    private func applyCommonFields(_ data: WsData) {
        if let s = data.structuredState { isResponding = s.inFlight ?? isResponding }
        if let q = data.queuedMessages { queuedMessages = q }
        if let esc = data.pendingEscalation {
            pendingEscalation = esc
            legacyPermissionPrompt = nil
        }
        if let blocked = data.permissionBlocked {
            permissionBlocked = blocked
            if !blocked {
                pendingEscalation = nil
                legacyPermissionPrompt = nil
            }
        }
        if let title = data.currentTaskTitle { currentTaskTitle = title }
        if let model = data.selectedModel { selectedModel = model }
        if let effort = data.thinkingEffort { thinkingEffort = effort }
    }

    // MARK: - 用户动作

    /// 发送一条消息。PTY 会话走 chat 视图语义（结尾补换行），结构化会话直接发文本。
    func send(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let queueing = isStructured && isResponding && status == "running"
        let previousMessages = messages
        let previousQueue = queuedMessages
        if isStructured {
            if queueing {
                queuedMessages.append(trimmed)
                toast = "已加入排队，等当前回复完成会自动发送。"
            } else {
                messages.append(ConversationTurn(role: "user", content: [.text(text: trimmed, subagent: nil)]))
                isResponding = true
            }
        }
        Task {
            do {
                if isStructured {
                    try await api.sendInput(id: sessionId, input: trimmed)
                } else {
                    try await api.sendInput(id: sessionId, input: trimmed + "\n", view: "chat")
                }
            } catch {
                toast = error.localizedDescription
                if isStructured {
                    if queueing {
                        queuedMessages = previousQueue
                    } else {
                        messages = previousMessages
                        isResponding = false
                    }
                }
            }
        }
    }

    func setModel(_ model: String?) {
        let previous = selectedModel
        selectedModel = model
        Task {
            do {
                let snap = try await api.setModel(id: sessionId, model: model)
                apply(snapshot: snap)
            } catch {
                selectedModel = previous
                toast = error.localizedDescription
            }
        }
    }

    func setThinkingEffort(_ effort: String) {
        let previous = thinkingEffort
        thinkingEffort = effort
        Task {
            do {
                let snap = try await api.setThinkingEffort(id: sessionId, thinkingEffort: effort)
                apply(snapshot: snap)
            } catch {
                thinkingEffort = previous
                toast = error.localizedDescription
            }
        }
    }

    private func loadModels() async {
        guard let response = try? await api.models() else { return }
        let provider = snapshot?.provider ?? "claude"
        availableModels = provider == "codex" ? response.codexModels : response.models
        defaultModel = response.defaultModelId(for: provider)
    }

    // MARK: - AskUserQuestion 交互（对齐 Web 端 __askSelect / __askSubmit）

    /// 点选一个选项：单选点同一项取消、换选项替换；多选逐项 toggle。已提交后不可改。
    func toggleAskOption(toolUseId: String, questionIndex: Int, optionIndex: Int, multiSelect: Bool) {
        var sel = askUserSelections[toolUseId] ?? AskUserSelectionState()
        guard !sel.submitted else { return }
        var current = sel.selected[questionIndex] ?? []
        if multiSelect {
            if current.contains(optionIndex) { current.remove(optionIndex) } else { current.insert(optionIndex) }
        } else {
            current = current.contains(optionIndex) ? [] : [optionIndex]
        }
        sel.selected[questionIndex] = current
        askUserSelections[toolUseId] = sel
    }

    /// 提交答案：每道题一行、同题多选 ", " 连接（对齐 Web），走与普通消息相同的输入通道。
    /// 答案不乐观插入用户气泡——服务端会把它作为 tool_result 回推、卡片转只读态。
    func submitAskUser(toolUseId: String, answerText: String) {
        var sel = askUserSelections[toolUseId] ?? AskUserSelectionState()
        guard !sel.submitted else { return }
        sel.submitted = true
        askUserSelections[toolUseId] = sel
        if isStructured { isResponding = true }
        Task {
            do {
                if isStructured {
                    try await api.sendInput(id: sessionId, input: answerText)
                } else {
                    try await api.sendInput(id: sessionId, input: answerText + "\n", view: "chat")
                }
            } catch {
                toast = error.localizedDescription
                var rollback = askUserSelections[toolUseId] ?? AskUserSelectionState()
                rollback.submitted = false
                askUserSelections[toolUseId] = rollback
                if isStructured { isResponding = false }
            }
        }
    }

    // MARK: - 排队消息（仅结构化会话）

    /// 把第 index 条排队消息立即发送。服务端负责摘队列项，客户端只做乐观显示和失败回滚。
    func promoteQueued(index: Int) {
        guard !queuePromotePending, queuedMessages.indices.contains(index) else { return }
        let previous = queuedMessages
        let picked = previous[index]
        var rest = previous
        rest.remove(at: index)
        let inFlight = isInFlight
        queuePromotePending = true
        queuedMessages = rest
        toast = inFlight ? "已请求中断当前回复，立即发送这条。" : "已立即发送这条消息。"
        Task {
            do {
                let snap = try await api.promoteQueued(id: sessionId, index: index, expectedText: picked)
                apply(snapshot: snap)
            } catch {
                queuedMessages = previous
                toast = error.localizedDescription
            }
            queuePromotePending = false
        }
    }

    /// 删除第 index 条排队消息（乐观 + 失败回滚）。
    func deleteQueued(index: Int) {
        let previous = queuedMessages
        guard previous.indices.contains(index) else { return }
        queuedMessages.remove(at: index)
        Task {
            do {
                try await api.deleteQueued(id: sessionId, index: index)
            } catch {
                queuedMessages = previous
                toast = error.localizedDescription
            }
        }
    }

    /// 清空全部排队消息（乐观 + 失败回滚）。
    func clearQueued() {
        let previous = queuedMessages
        guard !previous.isEmpty else { return }
        queuedMessages = []
        Task {
            do {
                try await api.clearQueued(id: sessionId)
                toast = "已清空 \(previous.count) 条排队消息。"
            } catch {
                queuedMessages = previous
                toast = error.localizedDescription
            }
        }
    }

    /// 停止当前回复：结构化会话调 stop（杀掉当前回合），PTY 发 Esc 中断。
    func stopResponding() {
        Task {
            do {
                if isStructured {
                    try await api.stopSession(id: sessionId)
                    isResponding = false
                } else {
                    try await api.sendInput(id: sessionId, input: "\u{1B}", view: "chat", shortcutKey: "esc")
                }
            } catch {
                toast = error.localizedDescription
            }
        }
    }

    /// 权限决策。结构化 escalation 走 resolve 端点；PTY 旧式提示走 approve/deny。
    func resolvePermission(_ resolution: String) {
        if let esc = pendingEscalation {
            pendingEscalation = nil
            permissionBlocked = false
            Task {
                do {
                    let snap = try await api.resolveEscalation(sessionId: sessionId, requestId: esc.requestId, resolution: resolution)
                    apply(snapshot: snap)
                } catch {
                    toast = error.localizedDescription
                    socket.requestResync()
                }
            }
        } else if legacyPermissionPrompt != nil {
            legacyPermissionPrompt = nil
            permissionBlocked = false
            Task {
                do {
                    if resolution == "deny" {
                        _ = try await api.denyPermission(sessionId: sessionId)
                    } else {
                        _ = try await api.approvePermission(sessionId: sessionId)
                    }
                } catch {
                    toast = error.localizedDescription
                    socket.requestResync()
                }
            }
        }
    }

    /// 会话已结束时按 claudeSessionId 原地恢复（服务端 reuseId 复用本会话）。
    func resume() {
        Task {
            do {
                let snap = try await api.resumeSession(id: sessionId)
                apply(snapshot: snap)
                socket.requestResync()
                toast = "会话已恢复"
            } catch {
                toast = error.localizedDescription
            }
        }
    }

    /// 加载更早的一页消息，prepend 到 messages 并前移 loadedOffset。
    func loadEarlier() {
        guard canLoadEarlier, !loadingEarlier else { return }
        let currentOffset = loadedOffset
        let newOffset = max(0, currentOffset - earlierPageSize)
        let limit = currentOffset - newOffset
        guard limit > 0 else { return }
        loadingEarlier = true
        Task {
            do {
                let page = try await api.fetchMessages(id: sessionId, offset: newOffset, limit: limit)
                if loadedOffset == currentOffset {
                    messages = page.messages + messages
                    loadedOffset = newOffset
                    messageTotal = max(messageTotal, page.total)
                }
            } catch {
                toast = error.localizedDescription
            }
            loadingEarlier = false
        }
    }
}
