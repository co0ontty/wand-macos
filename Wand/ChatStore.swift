import Foundation
import Combine

protocol QueueRetrievalTransport {
    func deleteQueued(id: String, index: Int, expectedText: String) async throws -> SessionSnapshot
}

extension WandAPI: QueueRetrievalTransport {}

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
    @Published var queuedMessages: [String] = [] {
        didSet { queueMutationRevision &+= 1 }
    }
    @Published private(set) var queueMutationPending = false
    struct RemovedQueueText { let text: String; var confirmed = false; var pending = true }
    @Published private(set) var removedQueueText: RemovedQueueText?
    @Published var pendingEscalation: EscalationRequest?
    /// PTY 旧式权限提示（permissionBlocked 为 true 但没有结构化 escalation 时）。
    @Published var legacyPermissionPrompt: PermissionRequestInfo?
    @Published var permissionBlocked = false
    @Published var currentTaskTitle: String?
    @Published var connected = true
    @Published var loading = true
    @Published private(set) var sending = false
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
    @Published private(set) var todoTurnEvidence: TodoTurnEvidence?
    private var todoLeadingBlockOffset = 0
    private var todoSource: TodoTurnSource? {
        TodoTurnSource.find(sessionID: sessionId, messages: messages, offset: loadedOffset,
            leadingBlockOffset: todoLeadingBlockOffset,
            activeRequestID: snapshot?.structuredState?.inFlight == true ? snapshot?.structuredState?.activeRequestId : nil)
    }
    var todoProgress: (todos: [TodoItem], context: TodoExecutionPresentation)? {
        guard let source = todoSource else { return nil }
        let todos = TodoItem.currentTodos(in: messages, startIndex: source.startIndex)
        guard !todos.isEmpty else { return nil }
        return (todos, .make(source: source, status: status, active: isResponding,
            permission: permissionBlocked || pendingEscalation != nil, archived: snapshot?.archived == true,
            connected: connected, evidence: todoTurnEvidence))
    }
    @Published private(set) var loadingEarlier = false

    let sessionId: String
    let api: WandAPI
    @Published private(set) var snapshot: SessionSnapshot?
    private let socket: WandSocket
    private var started = false
    private var modelCatalog: ModelsResponse?
    private let earlierPageSize = 40
    private var settingsMutationTail: Task<Void, Never>?
    private var modelUpdateRevision: UInt64 = 0
    private var thinkingUpdateRevision: UInt64 = 0
    private var queueMutationRevision: UInt64 = 0
    /// Unconfirmed submissions stay in this session's memory and are never replayed.
    @Published private(set) var unconfirmedInputs = Set<String>()
    private var modeUpdateRevision: UInt64 = 0
    @Published private(set) var currentEmployee: EmployeeContact?
    var mode: String { snapshot?.mode ?? "default" }
    var displayEmployeeName: String { currentEmployee?.name ?? snapshot?.employeeName ?? "员工" }
    var displayEmployeeAvatar: String { if let currentEmployee { return currentEmployee.avatar ?? "" }; return snapshot?.employeeAvatar ?? "" }

    var isStructured: Bool { snapshot?.isStructured ?? true }
    var isReadOnlySystemCall: Bool { snapshot?.isReadOnlySystemCall == true }
    var sessionEnded: Bool { ["exited", "failed", "stopped"].contains(status) }
    var canLoadEarlier: Bool { loadedOffset > 0 }

    private let drafts: ConversationDraftCache
    private let queueRetrievalTransport: any QueueRetrievalTransport

    init(sessionId: String, api: WandAPI, drafts: ConversationDraftCache = .shared,
         queueRetrievalTransport: (any QueueRetrievalTransport)? = nil) {
        self.sessionId = sessionId
        self.api = api
        self.drafts = drafts
        self.queueRetrievalTransport = queueRetrievalTransport ?? api
        self.socket = WandSocket.sharedChat(api: api)
    }

    // MARK: - 生命周期

    private var realtimeRevision = 0
    func start() {
        guard !started else { socket.connect(); socket.subscribe(sessionId: sessionId); return }
        started = true

        // WandSocket 的回调已保证主线程，用 assumeIsolated 接回 MainActor 隔离，
        // 不用 Task 包装——Task 不保证 FIFO，会打乱增量合流顺序。
        socket.onEvent = { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        socket.onConnectionChange = { [weak self] up in
            MainActor.assumeIsolated {
                self?.connected = up
                if !up { self?.todoTurnEvidence = nil }
            }
        }

        socket.subscribe(sessionId: sessionId)
        socket.connect()
        let revision = realtimeRevision
        Task {
            do {
                try await Task.sleep(nanoseconds: 400_000_000)
                if snapshot == nil {
                    let snap = try await api.getSession(id: sessionId)
                    if realtimeRevision == revision { apply(snapshot: snap) }
                }
                loading = false
            } catch {
                loading = false
                if snapshot == nil { loadError = error.localizedDescription }
            }
            await loadModels()
            if let id = snapshot?.employeeId, let employees = try? await api.employeeContacts() {
                currentEmployee = employees.first { $0.id == id }
            }
        }
    }

    func shutdown() {
        socket.close()
    }

    func retryLoad() {
        loading = true
        loadError = nil
        Task {
            do {
                let snap = try await api.getSession(id: sessionId)
                apply(snapshot: snap)
                loading = false
                socket.connect()
                socket.subscribe(sessionId: sessionId)
            } catch {
                loading = false
                loadError = error.localizedDescription
            }
        }
    }

    #if DEBUG
    func receiveForTesting(_ event: WsIncoming) { handle(event) }
    func modelCatalogForTesting(_ catalog: ModelsResponse) { applyModelCatalog(catalog) }
    #endif

    // MARK: - 推送合流

    /// 应用一份窗口化消息快照。服务端 init/output/ended 可能只给最近一窗；
    /// 本地如果已经加载过更早前缀，需要保留，避免用户刚展开历史又被 WS 尾窗覆盖。
    private func applyWindowedMessages(_ incoming: [ConversationTurn]?, offset: Int?, total: Int?, leadingBlockOffset: Int? = nil) {
        guard let incoming else { return }
        let snapOffset = offset ?? 0
        let snapTotal = total ?? max(snapOffset + incoming.count, incoming.count)
        if incoming.isEmpty, !messages.isEmpty, snapTotal == 0 { return }

        if messages.isEmpty || loadedOffset >= snapOffset { todoLeadingBlockOffset = leadingBlockOffset ?? 0 }
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
        let previousError = snapshot?.structuredState?.lastError
        self.snapshot = snap
        if let modelCatalog { applyModelCatalog(modelCatalog) }
        applyWindowedMessages(snap.messages, offset: snap.messageOffset, total: snap.messageTotal, leadingBlockOffset: snap.leadingBlockOffset)
        status = snap.status ?? status
        isResponding = snap.isResponding
        if sessionEnded { clearRuntimeFacts() }
        queuedMessages = snap.queuedMessages ?? []
        pendingEscalation = snap.pendingEscalation
        permissionBlocked = snap.permissionBlocked ?? (snap.pendingEscalation != nil)
        todoTurnEvidence = TodoTurnEvidence.observe(todoTurnEvidence, source: todoSource, active: isResponding)
        currentTaskTitle = snap.currentTaskTitle
        selectedModel = snap.selectedModel
        thinkingEffort = snap.thinkingEffort ?? "off"
        if snap.pendingEscalation != nil { legacyPermissionPrompt = nil }
        if let error = snap.structuredState?.lastError?.trimmingCharacters(in: .whitespacesAndNewlines),
           !error.isEmpty, error != previousError {
            toast = error
        }
    }

    private func handle(_ event: WsIncoming) {
        if ["init", "output", "status", "ended"].contains(event.type) { realtimeRevision += 1 }
        guard event.sessionId == sessionId || event.sessionId == nil else { return }
        defer { todoTurnEvidence = TodoTurnEvidence.observe(todoTurnEvidence, source: todoSource, active: isResponding, event: event) }
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
                applyWindowedMessages(data.messages, offset: data.messageOffset, total: data.messageTotal, leadingBlockOffset: data.leadingBlockOffset)
                status = data.status ?? "exited"
                isResponding = false
                applyCommonFields(data)
            } else {
                status = "exited"
                isResponding = false
            }
            clearRuntimeFacts()
        case "error":
            if let message = event.error, !message.isEmpty { toast = message }
        default:
            break
        }
    }

    /// init 的 data 就是一份完整 SessionSnapshot（以 WsData 超集形状承接）。
    private func applyWsSnapshot(_ data: WsData) {
        applyWindowedMessages(data.messages, offset: data.messageOffset, total: data.messageTotal, leadingBlockOffset: data.leadingBlockOffset)
        status = data.status ?? status
        if let s = data.structuredState { isResponding = s.inFlight ?? false }
        if snapshot == nil, let id = data.id {
            // 极端情况：REST 快照还没回来 WS init 先到，补一份最小 snapshot。
            snapshot = SessionSnapshot(
                id: id, sessionKind: data.sessionKind, provider: data.provider,
                runner: data.runner, command: data.command, cwd: data.cwd,
                mode: data.mode, status: data.status, exitCode: data.exitCode,
                startedAt: data.startedAt, endedAt: data.endedAt, archived: data.archived,
                archivedAt: data.archivedAt,
                completionRevision: data.completionRevision,
                viewedCompletionRevision: data.viewedCompletionRevision,
                title: data.title, description: data.description, titleGenerating: data.titleGenerating,
                workspaceId: data.workspaceId, workspaceTaskId: data.workspaceTaskId,
                summary: data.summary, currentTaskTitle: data.currentTaskTitle,
                selectedModel: data.selectedModel, thinkingEffort: data.thinkingEffort,
                claudeSessionId: data.claudeSessionId,
                messages: nil, messageOffset: data.messageOffset, messageTotal: data.messageTotal,
                queuedMessages: data.queuedMessages,
                structuredState: data.structuredState, pendingEscalation: data.pendingEscalation,
                permissionBlocked: data.permissionBlocked,
                autoApprovePermissions: data.autoApprovePermissions
            )
            snapshot?.ptyBusy = data.ptyBusy
            snapshot?.providerCliActive = data.providerCliActive
            snapshot?.providerCliExitCode = data.providerCliExitCode
        }
        applyCommonFields(data, authoritative: true)
        // init 是权威快照：缺失身份也要清除，不能带着上一位员工或上一个团队。
        snapshot?.provider = data.provider
        snapshot?.runner = data.runner
        snapshot?.engine = data.structuredState?.engine ?? data.engine
        snapshot?.automationId = data.automationId
        snapshot?.employeeId = data.employeeId
        snapshot?.employeeName = data.employeeName
        snapshot?.employeeAvatar = data.employeeAvatar
        snapshot?.teamChat = data.teamChat
        snapshot?.teamStep = data.teamStep
        if let modelCatalog { applyModelCatalog(modelCatalog) }
    }

    private func applyOutput(_ data: WsData) {
        let incremental = data.incremental ?? false
        if let msgs = data.messages {
            // 全量赢（窗口合并：保留已加载的更早前缀）。
            applyWindowedMessages(msgs, offset: data.messageOffset, total: data.messageTotal, leadingBlockOffset: data.leadingBlockOffset)
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

    private func applyCommonFields(_ data: WsData, authoritative: Bool = false) {
        if let updatedStatus = data.status { status = updatedStatus }
        snapshot?.status = status
        applyRuntimeFacts(data, authoritative: authoritative)
        if let provider = data.provider, provider != snapshot?.provider {
            snapshot?.provider = provider
            if let modelCatalog { applyModelCatalog(modelCatalog) }
        }
        if let runner = data.runner { snapshot?.runner = runner }
        if let engine = data.structuredState?.engine ?? data.engine { snapshot?.engine = engine }
        if let automationId = data.automationId { snapshot?.automationId = automationId }
        if let id = data.employeeId { snapshot?.employeeId = id }
        if let name = data.employeeName { snapshot?.employeeName = name }
        if let avatar = data.employeeAvatar { snapshot?.employeeAvatar = avatar }
        if let chat = data.teamChat { snapshot?.teamChat = chat }
        if let step = data.teamStep { snapshot?.teamStep = step }
        if let active = data.providerCliActive {
            snapshot?.providerCliActive = active
            isResponding = snapshot?.isResponding ?? isResponding
        }
        if let exitCode = data.providerCliExitCode { snapshot?.providerCliExitCode = exitCode }
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
        if sessionEnded || status == "done"
            || (data.isResponding == false && !data.$structuredState.isPresent && data.ptyBusy != true) {
            clearRuntimeFacts()
        }
    }

    /// structuredState is a complete server projection, not a patch. Replacing it
    /// also drops omitted anchors on a new/legacy request instead of borrowing old ones.
    private func applyRuntimeFacts(_ data: WsData, authoritative: Bool) {
        if authoritative || data.$structuredState.isPresent {
            snapshot?.structuredState = data.structuredState
            if isStructured {
                isResponding = data.structuredState?.inFlight
                    ?? (data.structuredState == nil ? (data.isResponding ?? false) : (authoritative ? false : isResponding))
            }
        }
        let wasBusy = snapshot?.ptyBusy == true
        if authoritative || data.ptyBusy != nil { snapshot?.ptyBusy = data.ptyBusy }
        if authoritative || data.ptyCommandRunning != nil { snapshot?.ptyCommandRunning = data.ptyCommandRunning }
        let newPtyTurn = !wasBusy && data.ptyBusy == true
            || (data.$ptyTurnStartedAt.isPresent && data.ptyTurnStartedAt != snapshot?.ptyTurnStartedAt)
        if authoritative || newPtyTurn || data.$ptyTurnStartedAt.isPresent {
            snapshot?.ptyTurnStartedAt = data.ptyTurnStartedAt
        }
        if authoritative || newPtyTurn || data.$ptyLastActivityAt.isPresent {
            snapshot?.ptyLastActivityAt = data.ptyLastActivityAt
        }
        if snapshot?.ptyBusy != true {
            snapshot?.ptyTurnStartedAt = nil
            snapshot?.ptyLastActivityAt = nil
        }
        if data.ptyBusy != nil || (authoritative && !isStructured) {
            isResponding = snapshot?.isResponding ?? false
        }
        if snapshot?.structuredState?.inFlight != true {
            snapshot?.structuredState?.activeRequestId = nil
            snapshot?.structuredState?.turnStartedAt = nil
            snapshot?.structuredState?.lastActivityAt = nil
            snapshot?.structuredState?.phase = nil
        }
    }

    private func clearRuntimeFacts() {
        isResponding = false
        snapshot?.status = status
        snapshot?.structuredState?.inFlight = false
        snapshot?.structuredState?.activeRequestId = nil
        snapshot?.structuredState?.turnStartedAt = nil
        snapshot?.structuredState?.lastActivityAt = nil
        snapshot?.structuredState?.phase = nil
        snapshot?.ptyBusy = false
        snapshot?.ptyTurnStartedAt = nil
        snapshot?.ptyLastActivityAt = nil
        snapshot?.ptyCommandRunning = false
    }

    // MARK: - 用户动作

    /// 发送一条消息。PTY 会话分包发送正文与 Return，结构化会话直接发文本。
    func send(text: String, onAccepted: @escaping () -> Void = {},
              onUnknown: @escaping () -> Void = {}, onFailure: @escaping () -> Void = {}) {
        guard !isReadOnlySystemCall else { toast = "系统调用记录只读，不能继续发送。"; onFailure(); return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !sending, !queueMutationPending else { return }
        guard !unconfirmedInputs.contains(trimmed) else {
            toast = "这条消息的送达尚未确认，请先核对会话，避免重复发送。"
            onUnknown()
            return
        }
        sending = true
        let queueing = isStructured && isResponding && status == "running"
        let previousMessages = messages
        if isStructured && !queueing {
            messages.append(ConversationTurn(role: "user", content: [.text(text: trimmed, subagent: nil)]))
            isResponding = true
        }
        Task {
            defer { sending = false }
            var acceptedPtyText = false
            do {
                if isStructured {
                    let snap = try await api.sendInput(id: sessionId, input: trimmed, respondImmediately: true)
                    apply(snapshot: snap)
                    socket.requestResync()
                } else {
                    try await sendPtyInput(trimmed, view: "chat", onTextAccepted: { acceptedPtyText = true })
                }
                onAccepted()
            } catch {
                toast = error.localizedDescription
                socket.requestResync()
                guard !acceptedPtyText, Self.inputWasRejected(error) else {
                    unconfirmedInputs.insert(trimmed)
                    toast = "消息送达结果尚未确认，请核对会话后继续；不会自动重发。"
                    onUnknown()
                    return
                }
                if isStructured && !queueing {
                    messages = previousMessages
                    isResponding = false
                }
                onFailure()
            }
        }
    }

    /// Explicit acknowledgment only unlocks manual input; it never replays a request.
    func acknowledgeUnconfirmedInput(_ text: String) {
        guard !sending else { return }
        unconfirmedInputs.remove(text)
    }

    private func sendPtyChatInput(_ text: String) async throws {
        try await sendPtyInput(text, view: "chat")
    }

    static func inputWasRejected(_ error: Error) -> Bool {
        guard let error = error as? WandAPI.APIError else { return false }
        switch error {
        case .invalidURL, .unauthorized: return true
        case .server(let status, _): return (400..<500).contains(status) && ![408, 409].contains(status)
        case .network: return false
        }
    }

    private func sendPtyInput(_ text: String, view: String, onTextAccepted: () -> Void = {}) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if status != "running" {
            toast = "正在恢复会话…"
            let resumed = try await api.resumeSession(id: sessionId)
            apply(snapshot: resumed)
            socket.requestResync()
        }
        try await api.sendPtyInputChunk(
            id: sessionId,
            input: trimmed,
            view: view,
            shortcutKey: "enter_text"
        )
        onTextAccepted()
        try await Task.sleep(nanoseconds: 30_000_000)
        try await api.sendPtyInputChunk(
            id: sessionId,
            input: "\r",
            view: view,
            shortcutKey: "enter_text"
        )
    }

    func setModel(_ model: String?) {
        guard !isReadOnlySystemCall else { toast = "系统调用记录只读，不能修改执行模型。"; return }
        let previous = selectedModel
        modelUpdateRevision &+= 1
        let revision = modelUpdateRevision
        selectedModel = model
        enqueueSettingsMutation { [self] in
            do {
                let snap = try await api.setModel(id: sessionId, model: model)
                guard revision == modelUpdateRevision else { return }
                selectedModel = snap.selectedModel ?? model
            } catch {
                guard revision == modelUpdateRevision else { return }
                selectedModel = previous
                toast = error.localizedDescription
            }
        }
    }

    func setThinkingEffort(_ effort: String) {
        guard !isReadOnlySystemCall else { toast = "系统调用记录只读，不能修改思考设置。"; return }
        let previous = thinkingEffort
        thinkingUpdateRevision &+= 1
        let revision = thinkingUpdateRevision
        thinkingEffort = effort
        enqueueSettingsMutation { [self] in
            do {
                let snap = try await api.setThinkingEffort(id: sessionId, thinkingEffort: effort)
                guard revision == thinkingUpdateRevision else { return }
                thinkingEffort = snap.thinkingEffort ?? effort
            } catch {
                guard revision == thinkingUpdateRevision else { return }
                thinkingEffort = previous
                toast = error.localizedDescription
            }
        }
    }

    private func enqueueSettingsMutation(
        _ mutation: @escaping @MainActor () async -> Void
    ) {
        let previous = settingsMutationTail
        settingsMutationTail = Task { @MainActor in
            _ = await previous?.result
            await mutation()
        }
    }

    func setMode(_ mode: String) {
        guard !isReadOnlySystemCall else { toast = "系统调用记录只读，不能修改执行模式。"; return }
        guard snapshot?.provider != "codex" else { return }
        modeUpdateRevision &+= 1; let captured = modeUpdateRevision
        enqueueSettingsMutation { [self] in
            do {
                let result = try await api.setMode(id: sessionId, mode: mode)
                guard captured == modeUpdateRevision else { return }
                apply(snapshot: result)
            } catch { if captured == modeUpdateRevision { toast = error.localizedDescription } }
        }
    }

    private func loadModels() async {
        guard let response = try? await api.models() else { return }
        applyModelCatalog(response)
    }

    private func applyModelCatalog(_ response: ModelsResponse) {
        modelCatalog = response
        let provider = snapshot?.provider ?? "claude"
        availableModels = response.models(for: provider)
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
                    try await api.sendInput(id: sessionId, input: answerText, respondImmediately: true)
                    socket.requestResync()
                } else {
                    try await sendPtyChatInput(answerText)
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

    /// Queue mutations wait for server confirmation. A late response must not replace
    /// a newer WebSocket queue, and an unknown result must never resurrect an item.
    private func applyQueueReceipt(_ snap: SessionSnapshot, revision: UInt64) throws {
        guard snap.id == sessionId, let queue = snap.queuedMessages else { throw WandAPI.APIError.network("队列确认无效，请核对最新状态") }
        if queueMutationRevision == revision { queuedMessages = queue }
        socket.requestResync()
    }

    func promoteQueued(index: Int) {
        guard !queueMutationPending, !sending, queuedMessages.indices.contains(index) else { return }
        let picked = queuedMessages[index]
        let revision = queueMutationRevision
        queueMutationPending = true
        Task {
            defer { queueMutationPending = false }
            do {
                let snap = try await api.promoteQueued(id: sessionId, index: index, expectedText: picked)
                try applyQueueReceipt(snap, revision: revision)
            } catch {
                socket.requestResync()
                toast = error.localizedDescription
            }
        }
    }

    /// The source stays in the session cache until confirmation or explicit dismissal.
    @discardableResult
    func retrieveQueued(index: Int) -> Task<Void, Never>? {
        guard !queueMutationPending, !sending, queuedMessages.indices.contains(index) else { return nil }
        let picked = queuedMessages[index]
        guard drafts.beginQueueRetrieval(picked, serverURL: api.baseURL, sessionID: sessionId) else { return nil }
        let revision = queueMutationRevision
        queueMutationPending = true
        return Task {
            defer { queueMutationPending = false }
            do {
                let snap = try await queueRetrievalTransport.deleteQueued(id: sessionId, index: index, expectedText: picked)
                try applyQueueReceipt(snap, revision: revision)
                drafts.finishQueueRetrieval(confirmed: true, serverURL: api.baseURL, sessionID: sessionId)
            } catch {
                drafts.finishQueueRetrieval(confirmed: false, serverURL: api.baseURL, sessionID: sessionId)
                socket.requestResync()
                toast = "未确认取回结果，请核对队列；原文已保留，可复制。"
            }
        }
    }

    func deleteQueued(index: Int) {
        guard !queueMutationPending, !sending, removedQueueText == nil, queuedMessages.indices.contains(index) else { return }
        let picked = queuedMessages[index]
        removedQueueText = RemovedQueueText(text: picked)
        let revision = queueMutationRevision
        queueMutationPending = true
        Task {
            defer { queueMutationPending = false }
            do {
                let snap = try await api.deleteQueued(id: sessionId, index: index, expectedText: picked)
                try applyQueueReceipt(snap, revision: revision)
                removedQueueText?.confirmed = true
            } catch {
                socket.requestResync()
                toast = "移除结果待核对；原文已保留，未自动重试。"
            }
            removedQueueText?.pending = false
        }
    }

    func clearQueued() {
        guard !queueMutationPending, !sending, removedQueueText == nil, !queuedMessages.isEmpty else { return }
        let expected = queuedMessages
        removedQueueText = RemovedQueueText(text: expected.joined(separator: "\n\n"))
        let revision = queueMutationRevision
        queueMutationPending = true
        Task {
            defer { queueMutationPending = false }
            do {
                let snap = try await api.clearQueued(id: sessionId, expectedQueue: expected)
                try applyQueueReceipt(snap, revision: revision)
                removedQueueText?.confirmed = true
            } catch {
                socket.requestResync()
                toast = "清空结果待核对；原文已保留，未自动重试。"
            }
            removedQueueText?.pending = false
        }
    }

    func recoverRemovedQueueToDraft() {
        guard let removed = removedQueueText, removed.confirmed, !removed.pending else { return }
        removedQueueText = nil
        drafts.recover(submitted: ConversationDraft(text: removed.text, attachments: []), serverURL: api.baseURL, sessionID: sessionId, reason: .queueRetrieval)
    }

    func dismissRemovedQueueText() {
        if removedQueueText?.pending == false { removedQueueText = nil }
    }

    func moveQueued(index: Int, delta: Int) {
        let destination = index + delta
        guard !queueMutationPending, !sending, queuedMessages.indices.contains(index), queuedMessages.indices.contains(destination) else { return }
        reorderQueued(index: index, destination: destination, expected: queuedMessages)
    }

    /// Both menu moves and native handle drops share the same snapshot/receipt owner.
    func reorderQueued(index: Int, destination: Int, expected: [String]) {
        guard !queueMutationPending, !sending, queuedMessages == expected,
              expected.indices.contains(index), expected.indices.contains(destination), index != destination else { return }
        var order = Array(expected.indices)
        let picked = order.remove(at: index)
        order.insert(picked, at: destination)
        let revision = queueMutationRevision
        queueMutationPending = true
        Task {
            defer { queueMutationPending = false }
            do {
                let snap = try await api.reorderQueued(id: sessionId, order: order, expectedQueue: expected)
                try applyQueueReceipt(snap, revision: revision)
            } catch { socket.requestResync(); toast = "排序结果待核对，未自动重试。" }
        }
    }

    /// 停止当前回复：结构化会话调 stop（杀掉当前回合），PTY 发 Esc 中断。
    func stopResponding() {
        guard !isReadOnlySystemCall else { toast = "请在发起该调用的功能中取消，日志不能控制执行。"; return }
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

    /// 权限决策。PTY 与 Claude SDK structured 都走 approve/deny；无 pending 时忽略。
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
        guard !isReadOnlySystemCall else { toast = "系统调用记录不能恢复为交互任务。"; return }
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
