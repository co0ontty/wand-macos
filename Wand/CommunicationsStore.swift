import Combine
import Foundation

@MainActor
final class CommunicationsStore: ObservableObject {
    enum Section { case conversations, contacts }
    @Published var section: Section = .conversations
    @Published var query = ""
    @Published var includesArchivedContacts = false
    @Published private(set) var contacts: [EmployeeContact] = []
    @Published private(set) var items: [NativeConversation] = []
    @Published private(set) var contactsError: String?
    @Published private(set) var conversationsError: String?
    @Published private(set) var indexLoading = false
    @Published private(set) var indexLoaded = false
    @Published private(set) var selectedID: String?
    @Published private(set) var selectedContactID: String?
    @Published private(set) var detail: NativeConversation?
    @Published private(set) var detailError: String?
    @Published private(set) var detailLoading = false
    @Published private(set) var defaultCwd = ""
    @Published private(set) var defaultCwdError: String?
    @Published var target: ConversationTarget?
    @Published var messageQuery = ""
    @Published var messageSearchExpanded = false

    let api: CommunicationsServing
    let ledger: ConversationRequestLedger
    private var composers: [ConversationScope: ConversationComposerState] = [:]
    private var operations: [String: ConversationOperationState] = [:]
    private var detailTask: Task<Void, Never>?
    private var detailGeneration: UInt64 = 0
    private var indexGeneration: UInt64 = 0
    private var metadata: [String: NativeConversation] = [:]
    private var loadedDefaults = false

    init(api: CommunicationsServing, serverURL: URL, defaults: UserDefaults = .standard) {
        self.api = api
        ledger = ConversationRequestLedger(api: api, serverURL: serverURL, defaults: defaults)
    }

    var selectedScope: ConversationScope? { selectedID.map { ConversationScope(conversationID: $0, target: target) } }
    var filteredContacts: [EmployeeContact] {
        contacts.filter { (includesArchivedContacts || !$0.isArchived) && matches([$0.name, $0.duty] + ($0.tags ?? [])) }
    }
    var filteredConversations: [NativeConversation] {
        items.filter { matches([$0.displayTitle, $0.preview ?? ""]) }.sorted {
            if ($0.pinnedAt != nil) != ($1.pinnedAt != nil) { return $0.pinnedAt != nil }
            if $0.messageAt != $1.messageAt { return ($0.messageAt ?? "") > ($1.messageAt ?? "") }
            return $0.id < $1.id
        }
    }
    func contact(_ id: String?) -> EmployeeContact? { contacts.first { $0.id == id } }
    private func matches(_ strings: [String]) -> Bool {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || strings.contains { $0.localizedStandardContains(value) }
    }

    func refreshIndex() async {
        guard !indexLoading else { return }
        indexLoading = true; indexGeneration &+= 1
        let captured = indexGeneration
        defer { if indexGeneration == captured { indexLoading = false } }
        async let employeeResult = api.employeeContacts()
        async let conversationResult = api.conversations()
        do {
            let value = try await employeeResult
            if captured == indexGeneration { contacts = value; contactsError = nil }
        } catch { if captured == indexGeneration { contactsError = error.localizedDescription } }
        do {
            let value = try await conversationResult
            if captured == indexGeneration {
                items = value; conversationsError = nil; indexLoaded = true
                for item in value { metadata[item.id] = item }
            }
        } catch { if captured == indexGeneration { conversationsError = error.localizedDescription } }
        if !loadedDefaults {
            do {
                let value = try await api.communicationsDefaultCwd()
                defaultCwd = value; loadedDefaults = true; defaultCwdError = nil
                for composer in composers.values { composer.applyDefaultCwd(value) }
            } catch { defaultCwdError = "默认执行目录读取失败，可手动填写后发送。" }
        }
    }

    func selectContact(_ employee: EmployeeContact) { selectedContactID = employee.id; section = .contacts }
    func selectEmployee(_ employee: EmployeeContact) { select(employee.conversationID) }
    func select(_ id: String) {
        section = .conversations
        guard selectedID != id else { refreshDetail(); return }
        selectedID = id; target = nil; detail = nil; detailError = nil
        messageQuery = ""; messageSearchExpanded = false
        refreshDetail()
    }
    func selectTarget(_ next: ConversationTarget?) {
        // Explicit targets have independent drafts; never move an old draft to a different run.
        target = next
    }
    func refreshDetail() {
        guard let id = selectedID else { return }
        detailTask?.cancel(); detailGeneration &+= 1
        let captured = detailGeneration
        detailLoading = true
        detailTask = Task { [weak self] in
            guard let self else { return }
            do {
                let value = try await self.api.conversation(id: id)
                guard !Task.isCancelled, captured == self.detailGeneration, self.selectedID == id else { return }
                guard value.id == id else { throw WandAPI.APIError.network("返回的对话与请求不一致，未展示其内容。") }
                self.detail = value; self.metadata[id] = value; self.detailError = nil; self.detailLoading = false
            } catch {
                guard !Task.isCancelled, captured == self.detailGeneration, self.selectedID == id else { return }
                self.detailError = error.localizedDescription; self.detailLoading = false
            }
        }
    }
    func refreshVisible() async {
        await refreshIndex()
        if !detailLoading { refreshDetail() }
    }
    func composer(for scope: ConversationScope) -> ConversationComposerState {
        if let existing = composers[scope] { return existing }
        let state = ConversationComposerState(scope: scope, cwd: defaultCwd, pending: ledger.request(for: scope))
        composers[scope] = state; return state
    }
    func operation(_ key: String, pendingOperation: String? = nil, conversationID: String = "") -> ConversationOperationState {
        if let existing = operations[key] { return existing }
        let state = ConversationOperationState(pending: ledger.pending.first {
            $0.operation == pendingOperation && $0.conversationID == conversationID
        })
        operations[key] = state; return state
    }
    func sendBlockReason(for scope: ConversationScope) -> String? {
        if selectedID == scope.conversationID, detailError != nil { return "对话刷新失败，请重新读取后发送；草稿保留。" }
        guard let value = metadata[scope.conversationID] else { return "请先读取对话，草稿保留。" }
        if let reason = value.sendBlockReason { return reason }
        if let selected = scope.target,
           !value.runs.contains(where: { $0.id == selected.runId && $0.taskId == selected.taskId && $0.isActive }) {
            return "所选轮次已结束或不属于此对话；请明确切回群内沟通。"
        }
        return nil
    }
    func send(_ scope: ConversationScope) async {
        guard sendBlockReason(for: scope) == nil else { return }
        let receipt = await composer(for: scope).submit(ledger: ledger)
        if receipt != nil { await refreshIndex() }
        if selectedID == scope.conversationID { refreshDetail() }
    }
    func reconcile(_ scope: ConversationScope) async {
        let receipt = await composer(for: scope).reconcile(ledger: ledger)
        if receipt?.isTerminal == true { await refreshIndex() }
        if selectedID == scope.conversationID { refreshDetail() }
    }
    func addAttachments(_ urls: [URL], scope: ConversationScope) async {
        let owner = composer(for: scope)
        guard sendBlockReason(for: scope) == nil, !urls.isEmpty else { return }
        guard urls.count + owner.attachments.count <= 5 else { owner.failUpload(ConversationDeliveryError.notSent("最多添加 5 个附件。")); return }
        guard let capturedRevision = owner.beginUpload() else { return }
        do {
            var body: [String: Any] = [:]
            if !owner.cwd.isEmpty { body["cwd"] = owner.cwd }
            let channel = try await ledger.perform(
                path: "/api/conversations/\(ConversationComposerState.encode(scope.conversationID))/channel",
                body: body, scope: scope, operation: "channel"
            )
            guard let sessionID = channel.sessionId, !sessionID.isEmpty else { throw ConversationDeliveryError.notSent("附件通道未返回有效会话；原消息尚未发送。") }
            guard owner.uploadStillCurrent(capturedRevision) else { owner.completeUpload([], revision: capturedRevision); return }
            let files = try await api.uploadAttachments(id: sessionID, urls: urls)
            owner.completeUpload(files, revision: capturedRevision)
        } catch { owner.failUpload(error) }
    }
    func createGroup(_ draft: ConversationGroupDraft, operation: ConversationOperationState) async -> ConversationReceipt? {
        if let reason = draft.validationError { operation.localFailure(reason); return nil }
        guard draft.employeeIDs.allSatisfy({ id in contacts.contains { $0.id == id && !$0.isArchived } }) else {
            operation.localFailure("所选员工已不可用，请核对通讯录。"); return nil
        }
        let result = await operation.perform(ledger: ledger, path: "/api/conversations", body: ["group": draft.body],
                                             scope: ConversationScope(conversationID: "", target: nil), operation: "create-group")
        if result != nil { await refreshIndex() }
        return result
    }
    func invite(_ draft: ConversationGroupDraft, into conversation: NativeConversation, operation: ConversationOperationState) async -> ConversationReceipt? {
        if let reason = draft.validationError { operation.localFailure(reason); return nil }
        guard let version = conversation.memberVersion else { operation.localFailure("群成员版本缺失，请重新读取。"); return nil }
        let result = await operation.perform(ledger: ledger,
            path: "/api/conversations/\(ConversationComposerState.encode(conversation.id))/invitations",
            body: ["memberVersion": version, "group": draft.body], scope: ConversationScope(conversationID: conversation.id, target: nil), operation: "invite")
        if result != nil { await refreshIndex(); if selectedID == conversation.id { refreshDetail() } }
        return result
    }
    func actionIdentity(_ action: String, scope: ConversationScope) -> String {
        let base = "action:\(scope.target?.key ?? ""):\(action)"
        if let pending = ledger.pending.first(where: {
            $0.conversationID == scope.conversationID && $0.target == scope.target
                && ($0.operation == base || $0.operation.hasPrefix(base + ":"))
        }) { return pending.operation }
        if action == "continue" {
            let limit = metadata[scope.conversationID]?.runs.first { $0.id == scope.target?.runId }?.stepLimit ?? 0
            return base + ":\(limit)"
        }
        return base
    }
    func act(_ action: String, scope: ConversationScope, operation: ConversationOperationState) async {
        guard let target = scope.target else { operation.localFailure("请明确选择任务轮次。"); return }
        _ = await operation.perform(ledger: ledger,
            path: "/api/conversations/\(ConversationComposerState.encode(scope.conversationID))/actions",
            body: ["target": target.body, "action": action], scope: scope, operation: actionIdentity(action, scope: scope))
        if selectedID == scope.conversationID { refreshDetail() }
    }
    #if DEBUG
    func waitForDetailForTesting() async { await detailTask?.value }
    #endif
}
