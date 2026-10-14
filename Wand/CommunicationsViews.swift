import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct CommunicationsSidebar: View {
    @ObservedObject var store: CommunicationsStore
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundColor(Theme.textSecondary)
                TextField(store.section == .contacts ? "搜索员工、职责、标签…" : "搜索对话…", text: $store.query)
                    .textFieldStyle(.plain).focused($searchFocused)
                if !store.query.isEmpty {
                    Button { store.query = ""; searchFocused = true } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).accessibilityLabel("清除搜索")
                }
            }
            .font(.system(size: 12)).padding(.horizontal, 9).frame(height: 32)
            .wandInputSurface(focused: searchFocused, cornerRadius: Theme.Radius.control)
            .padding(.horizontal, 12)
            if store.section == .contacts {
                Toggle("显示已归档员工", isOn: $store.includesArchivedContacts)
                    .toggleStyle(.checkbox).font(.system(size: 11)).padding(.horizontal, 14)
            }
            if let error = store.section == .contacts ? store.contactsError : store.conversationsError {
                Text(error).font(.system(size: 11)).foregroundColor(Theme.danger)
                    .lineLimit(3).padding(.horizontal, 14)
            }
            ScrollView {
                LazyVStack(spacing: 3) {
                    if store.section == .contacts {
                        ForEach(store.filteredContacts) { contact in
                            Button { store.selectContact(contact) } label: {
                                HStack(spacing: 9) {
                                    ContactAvatar(id: contact.id, avatar: contact.avatar ?? "", name: contact.name, provider: contact.candidates.first?.provider, size: 44)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(contact.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                        Text(contact.isArchived ? "已归档 · 仅查看历史" : contact.duty)
                                            .font(.system(size: 11)).foregroundColor(Theme.textSecondary).lineLimit(2)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .foregroundColor(Theme.textPrimary).padding(.horizontal, 9).frame(minHeight: 56)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(DesktopNavigationButtonStyle(active: store.selectedContactID == contact.id))
                            .accessibilityLabel(contact.name + "，" + contact.duty)
                        }
                        if store.filteredContacts.isEmpty && !store.indexLoading {
                            Text(store.query.isEmpty ? "通讯录暂为空；可在 Web 创建员工后刷新。" : "没有匹配的员工")
                                .font(.system(size: 12)).foregroundColor(Theme.textSecondary).padding(16)
                        }
                    } else {
                        ForEach(store.filteredConversations) { conversation in
                            Button { store.select(conversation.id) } label: {
                                HStack(spacing: 9) {
                                    ContactAvatar(id: conversation.peerEmployeeId ?? conversation.id, avatar: store.contact(conversation.peerEmployeeId)?.avatar ?? "", name: conversation.displayTitle, team: conversation.isGroup, size: 44)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(conversation.displayTitle).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                        Text(conversation.dissolvedAt != nil ? "已解散 · 历史保留" : conversation.preview ?? "尚无消息")
                                            .font(.system(size: 11)).foregroundColor(Theme.textSecondary).lineLimit(2)
                                    }
                                    Spacer(minLength: 0)
                                    if conversation.pinnedAt != nil { Image(systemName: "pin.fill").font(.system(size: 9)) }
                                }
                                .foregroundColor(Theme.textPrimary).padding(.horizontal, 9).frame(minHeight: 56)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(DesktopNavigationButtonStyle(active: store.selectedID == conversation.id))
                            .accessibilityLabel(conversation.displayTitle)
                        }
                        if store.filteredConversations.isEmpty && !store.indexLoading {
                            Text(store.query.isEmpty ? "从通讯录选择员工开始私聊，或在上方加号发起群聊。" : "没有匹配的对话")
                                .font(.system(size: 12)).foregroundColor(Theme.textSecondary).padding(16)
                        }
                    }
                    if store.indexLoading && !store.indexLoaded { ProgressView().controlSize(.small).padding(16) }
                }
                .padding(.horizontal, 12).padding(.bottom, 16)
            }
        }
    }
}

struct CommunicationsContent: View {
    @ObservedObject var store: CommunicationsStore
    let baseURL: URL
    let onOpenSession: (String) -> Void
    @State private var groupEditorOpen = false
    private let refresh = Timer.publish(every: 6, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(store.section == .contacts ? "通讯录" : store.detail?.displayTitle ?? "对话")
                    .font(.system(size: 18, weight: .semibold)).foregroundColor(Theme.textPrimary).lineLimit(1)
                    .opacity(store.section == .conversations && store.detail != nil ? 0 : 1)
                Spacer()
                if store.section == .conversations && store.selectedID != nil { ConversationMessageSearch(store: store) }
                Button { Task { await store.refreshVisible() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(WandIconButtonStyle()).frame(width: 32, height: 32).help("刷新通讯录与对话")
                Button { groupEditorOpen.toggle() } label: { Image(systemName: "plus") }
                    .buttonStyle(WandIconButtonStyle(isActive: groupEditorOpen)).frame(width: 32, height: 32)
                    .accessibilityLabel("发起群聊").help("发起群聊")
                    .popover(isPresented: $groupEditorOpen, arrowEdge: .top) {
                        ConversationGroupEditor(store: store, invitation: nil) { groupEditorOpen = false }
                    }
            }
            .padding(.horizontal, 24).frame(height: store.section == .conversations && store.detail != nil ? FocusComposerMetrics.normalCompanionClearance : 60)
            .overlay {
                if store.section == .conversations, let detail = store.detail {
                    let employee = store.contact(detail.peerEmployeeId)
                    let session = detail.turns.reversed().first { ["starting", "running", "waiting_user"].contains($0.sessionPreview?.status ?? "") }?.sessionLink?.sessionId
                    if let api = store.api as? WandAPI, let session, let employee {
                        ExecutingConversationCompanion(api: api, sessionID: session, employee: employee).id(session).overlay { companionEditTarget }
                    } else if let employee {
                        WorkingAvatar(id: employee.id, name: employee.name, avatar: employee.avatar ?? "", size: 88).overlay { companionEditTarget }
                    } else {
                        ContactAvatar(id: detail.id, name: detail.displayTitle, team: detail.isGroup, size: 88).overlay { companionEditTarget }
                    }
                }
            }
            Divider()
            if store.section == .contacts {
                if let contact = store.contact(store.selectedContactID) {
                    ConversationContactProfile(contact: contact) { store.selectEmployee(contact) }
                } else {
                    communicationEmpty("选择一位员工", detail: "查看职责与执行候选，再打开独立私聊。", symbol: "person.crop.rectangle")
                }
            } else if let detail = store.detail, detail.id == store.selectedID, let scope = store.selectedScope {
                ConversationPane(store: store, conversation: detail, scope: scope, baseURL: baseURL, onOpenSession: onOpenSession)
            } else if store.detailLoading {
                VStack(spacing: 10) { ProgressView(); Text("正在读取对话…").foregroundColor(Theme.textSecondary) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = store.detailError {
                VStack(spacing: 12) {
                    Text(error).foregroundColor(Theme.danger).multilineTextAlignment(.center)
                    Button("重新读取") { store.refreshDetail() }.buttonStyle(WandSecondaryButtonStyle())
                }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                communicationEmpty("和员工一起推进工作", detail: "打开已有对话，或从通讯录发起私聊。每份工作都链接到自己的原生执行会话。", symbol: "bubble.left.and.bubble.right")
            }
        }
        .background(Theme.workspaceBackground)
        .task { await store.refreshVisible() }
        .onReceive(refresh) { _ in Task { await store.refreshVisible() } }
        .onChange(of: store.query) { _ in groupEditorOpen = false }
        .onChange(of: store.section) { _ in groupEditorOpen = false }
        .onReceive(NotificationCenter.default.publisher(for: .wandDesktopCommand)) { note in
            if note.object as? DesktopCommand == .findConversation && store.section == .conversations && store.selectedID != nil {
                groupEditorOpen = false; store.messageSearchExpanded = true
            }
        }
        .onExitCommand { groupEditorOpen = false }
    }
    private var companionEditTarget: some View {
        Color.clear.contentShape(Rectangle()).frame(width: 88, height: 88)
            .onTapGesture { DesktopCommand.focusComposer.send() }
            .accessibilityLabel("当前伙伴，点按编辑消息").accessibilityAddTraits(.isButton)
    }
}

private struct ExecutingConversationCompanion: View {
    let employee: EmployeeContact
    @StateObject private var execution: ChatStore
    init(api: WandAPI, sessionID: String, employee: EmployeeContact) {
        self.employee = employee
        _execution = StateObject(wrappedValue: ChatStore(sessionId: sessionID, api: api))
    }
    var body: some View {
        let active = execution.isResponding && execution.status == "running" && !execution.permissionBlocked
        WorkingAvatar(id: employee.id, name: employee.name, avatar: employee.avatar ?? "",
            activity: avatarFileActivity(messages: execution.messages, executing: active),
            thinking: avatarIsThinking(messages: execution.messages, executing: active), size: 88)
            .onAppear { execution.start() }.onDisappear { execution.shutdown() }
    }
}

private struct ConversationMessageSearch: View {
    @ObservedObject var store: CommunicationsStore
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 6) {
            if store.messageSearchExpanded {
                TextField("查找消息与过程…", text: $store.messageQuery).textFieldStyle(.plain).font(.system(size: 12))
                    .focused($focused).frame(width: 160).onAppear { focused = true }
                    .onExitCommand { store.messageQuery = ""; store.messageSearchExpanded = false }
            }
            Button {
                if !store.messageSearchExpanded { store.messageSearchExpanded = true; focused = true }
                else if !store.messageQuery.isEmpty { store.messageQuery = ""; focused = true }
                else { store.messageSearchExpanded = false }
            } label: {
                ZStack {
                    Image(systemName: "magnifyingglass").opacity(store.messageSearchExpanded ? 0 : 1)
                    Image(systemName: "xmark").opacity(store.messageSearchExpanded ? 1 : 0)
                }.frame(width: 28, height: 28)
            }.buttonStyle(WandIconButtonStyle()).accessibilityLabel(store.messageSearchExpanded ? "清除或收起消息搜索" : "查找当前对话")
        }.wandMotion(value: store.messageSearchExpanded, layout: true)
    }
}

private struct ConversationContactProfile: View {
    let contact: EmployeeContact
    let open: () -> Void
    @State private var expandedDuty = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 16) {
                    ContactAvatar(id: contact.id, avatar: contact.avatar ?? "", name: contact.name, size: 56)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(contact.name).font(.system(size: 24, weight: .semibold)).foregroundColor(Theme.textPrimary)
                        Text(contact.isArchived ? "已归档 · 原有对话仍可查看" : (contact.tags ?? []).joined(separator: " · "))
                            .font(.system(size: 12)).foregroundColor(Theme.textSecondary)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("职责").font(.system(size: 13, weight: .semibold))
                        Spacer()
                        if contact.duty.count > 140 {
                            Button(expandedDuty ? "收起职责" : "展开完整职责") { expandedDuty.toggle() }
                                .buttonStyle(.plain).foregroundColor(Theme.wandAccent)
                        }
                    }
                    Text(contact.duty.isEmpty ? "暂未填写职责" : contact.duty)
                        .font(.system(size: 15)).lineSpacing(5).lineLimit(expandedDuty ? nil : 6).textSelection(.enabled)
                }.wandMotion(value: expandedDuty, layout: true)
                VStack(alignment: .leading, spacing: 10) {
                    Text("执行候选").font(.system(size: 13, weight: .semibold))
                    ForEach(Array(contact.candidates.enumerated()), id: \.offset) { index, candidate in
                        HStack(alignment: .top, spacing: 12) {
                            Text(index == 0 ? "首选" : "候选 \(index + 1)").font(.system(size: 11)).foregroundColor(Theme.textSecondary).frame(width: 46, alignment: .leading)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(candidate.toolLabel).font(.system(size: 13, weight: .medium))
                                Text([candidate.model ?? "默认模型", candidate.mode ?? "标准权限"].joined(separator: " · "))
                                    .font(.system(size: 12)).foregroundColor(Theme.textSecondary).textSelection(.enabled)
                            }
                        }
                    }
                    if contact.candidates.isEmpty { Text("执行配置未就绪；打开私聊后以服务端实际可用状态为准。").font(.system(size: 12)).foregroundColor(Theme.textSecondary) }
                }
                Button(contact.isArchived ? "查看私聊记录" : "打开私聊", action: open)
                    .buttonStyle(WandPrimaryButtonStyle())
                Text("这里只展示员工资料，不读取员工知识。每条私聊新消息独立执行；跟进原工作请从对应消息打开执行会话。")
                    .font(.system(size: 12)).foregroundColor(Theme.textSecondary)
            }
            .foregroundColor(Theme.textPrimary).padding(32).frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct ConversationPane: View {
    @ObservedObject var store: CommunicationsStore
    let conversation: NativeConversation
    let scope: ConversationScope
    let baseURL: URL
    let onOpenSession: (String) -> Void
    @State private var messagesLimit = 80
    @State private var membersExpanded = false
    @StateObject private var composerFocus = ComposerFocusController()
    @State private var inviteOpen = false

    private var composer: ConversationComposerState { store.composer(for: scope) }
    private var displayed: [(index: Int, turn: ConversationTurn, id: String)] {
        let query = store.messageQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = Set(ConversationSearch.matches(in: conversation.turns, offset: 0, query: query))
        return conversation.turns.enumerated().filter { index, turn in
            query.isEmpty || matches.contains(index) || [turn.sessionPreview?.text, turn.taskPreview?.text]
                .compactMap { $0 }.contains { $0.localizedStandardContains(query) }
        }.suffix(messagesLimit).map {
            ($0.offset, $0.element, $0.element.messageId ?? "\(conversation.id):\($0.offset)")
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            if let error = store.detailError {
                HStack {
                    Text(error).font(.system(size: 11)).foregroundColor(Theme.warning).lineLimit(2)
                    Spacer()
                    Button("重新读取") { store.refreshDetail() }.buttonStyle(WandSecondaryButtonStyle())
                }.padding(12)
            }
            if conversation.isGroup {
                groupContext.padding(.horizontal, 24).padding(.vertical, 12)
                Divider()
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        if conversation.turns.count > messagesLimit {
                            Button("显示更早的消息（\(conversation.turns.count - messagesLimit) 条）") { messagesLimit += 80 }
                                .buttonStyle(WandSecondaryButtonStyle())
                        }
                        if !store.messageQuery.isEmpty && displayed.isEmpty {
                            Text("没有匹配的已加载消息").font(.system(size: 13)).foregroundColor(Theme.textSecondary)
                        }
                        if conversation.turns.isEmpty {
                            Text(conversation.isGroup ? "群内尚无消息。普通消息仅沟通；明确 @成员 才会派发新任务。" : "这里是你和员工的独立私聊。发送新工作后，会出现精确的执行会话入口。")
                                .font(.system(size: 14)).foregroundColor(Theme.textSecondary).padding(.vertical, 32)
                        }
                        ForEach(displayed, id: \.id) { item in
                            CommunicationMessageRow(turn: item.turn, baseURL: baseURL, contacts: store.contacts, members: conversation.members, onOpenSession: onOpenSession,
                                onSelectTarget: { id, target in store.select(id); store.selectTarget(target) })
                                .id(item.id)
                        }
                        Color.clear.frame(height: 1).id("conversation-bottom")
                    }
                    .padding(.horizontal, 24).padding(.vertical, 24)
                    .chatContentWidth()
                }
                .clipped().simultaneousGesture(TapGesture().onEnded { composerFocus.collapseFromContent() })
                .onAppear { proxy.scrollTo("conversation-bottom", anchor: .bottom) }
            }
            Divider()
            ConversationComposerSurface(owner: composer, store: store, conversation: conversation, focus: composerFocus)
                .chatContentWidth()
                .id(scope.key)
        }
        .onChange(of: conversation.id) { _ in messagesLimit = 80; inviteOpen = false; membersExpanded = false; composerFocus.resetPresentation() }
        .onChange(of: scope.key) { _ in composerFocus.resetPresentation() }
    }

    private func pendingAction(_ action: String) -> Bool {
        let identity = store.actionIdentity(action, scope: scope)
        return store.ledger.pending.contains { $0.conversationID == scope.conversationID && $0.target == scope.target && $0.operation == identity }
    }

    private var groupContext: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                DisclosureGroup("\(conversation.members.count) 位成员", isExpanded: $membersExpanded) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(conversation.members, id: \.id) { member in
                            HStack(spacing: 8) {
                                ContactAvatar(id: member.employeeId ?? member.id, avatar: store.contact(member.employeeId)?.avatar ?? member.avatar ?? "", name: member.name, size: 28)
                                Text(member.name).font(.system(size: 12))
                                if member.isLeader == true { Text("负责人").font(.system(size: 10)).foregroundColor(Theme.textSecondary) }
                                if let reason = conversation.memberUnavailableReasons?[member.id] { Text(reason).font(.system(size: 11)).foregroundColor(Theme.warning) }
                                Spacer()
                            }
                        }
                    }.padding(.top, 8)
                }.font(.system(size: 12)).frame(maxWidth: 340, alignment: .leading)
                Spacer(minLength: 4)
                Button("邀请员工") { inviteOpen.toggle() }
                    .buttonStyle(WandSecondaryButtonStyle()).disabled(conversation.sendBlockReason != nil)
                    .popover(isPresented: $inviteOpen, arrowEdge: .top) {
                        ConversationGroupEditor(store: store, invitation: conversation) { inviteOpen = false }
                    }
            }
            if !conversation.runs.isEmpty {
                HStack(spacing: 10) {
                    Picker("发送目标", selection: Binding(get: { store.target }, set: { store.selectTarget($0); inviteOpen = false })) {
                        Text("群内沟通 · 不自动跟随任务").tag(ConversationTarget?.none)
                        ForEach(conversation.runs) { run in
                            Text("\(conversationRunLabel(run.status)) · \(run.objective ?? run.id)")
                                .tag(Optional(ConversationTarget(taskId: run.taskId, runId: run.id)))
                        }
                    }.pickerStyle(.menu).frame(maxWidth: 440)
                    if let target = scope.target, let run = conversation.runs.first(where: { $0.id == target.runId && $0.taskId == target.taskId }) {
                        if run.status == "awaiting_approval" || pendingAction("approve") { ConversationRunAction(store: store, scope: scope, action: "approve", title: "批准计划") }
                        if run.status == "waiting_user" || pendingAction("continue") { ConversationRunAction(store: store, scope: scope, action: "continue", title: "继续 +10 步") }
                        if run.isActive || pendingAction("stop") { ConversationRunAction(store: store, scope: scope, action: "stop", title: "停止本轮", requiresConfirmation: true) }
                    }
                }
            }
        }.foregroundColor(Theme.textPrimary).wandMotion(value: membersExpanded, layout: true)
    }
}

private struct CommunicationMessageRow: View {
    let turn: ConversationTurn
    let baseURL: URL
    let contacts: [EmployeeContact]
    let members: [ConversationRecipient]
    let onOpenSession: (String) -> Void
    let onSelectTarget: (String, ConversationTarget) -> Void
    @State private var previewExpanded = false

    var body: some View {
        VStack(alignment: turn.role == "user" ? .trailing : .leading, spacing: 8) {
            if turn.notice == true {
                Text(turn.content.compactMap { if case let .text(text, _) = $0 { return text }; return nil }.joined(separator: "\n"))
                    .font(.system(size: 12)).foregroundColor(Theme.textSecondary).frame(maxWidth: .infinity)
            } else {
                HStack(spacing: 7) {
                    let employeeID = members.first { $0.id == turn.author?.id }?.employeeId ?? turn.author?.id ?? ""
                    let current = contacts.first { $0.id == employeeID }
                    ContactAvatar(id: turn.role == "user" ? "" : employeeID, avatar: current?.avatar ?? turn.author?.avatar ?? "",
                        name: turn.role == "user" ? "" : turn.author?.name ?? "", provider: turn.author?.provider, size: 28)
                    Text(turn.author?.name ?? (turn.role == "user" ? "我" : "助手"))
                        .font(.system(size: 12, weight: .medium)).foregroundColor(Theme.textSecondary)
                    if let createdAt = turn.createdAt { Text(SessionListDateLabel.relative(iso: createdAt)).font(.system(size: 10)).foregroundColor(Theme.textMuted) }
                }.frame(maxWidth: .infinity, alignment: turn.role == "user" ? .trailing : .leading)
                if let link = turn.sessionLink {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(link.title?.isEmpty == false ? link.title! : "执行会话").font(.system(size: 14, weight: .medium))
                            Spacer()
                            if (turn.sessionPreview?.text.count ?? 0) > 180 {
                                Button(previewExpanded ? "收起预览" : "展开完整预览") { previewExpanded.toggle() }
                                    .buttonStyle(.plain).foregroundColor(Theme.wandAccent)
                            }
                        }
                        if let preview = turn.sessionPreview {
                            Text(preview.text.isEmpty ? "打开原会话查看完整进度。" : preview.text)
                                .font(.system(size: 14)).lineSpacing(4).lineLimit(previewExpanded ? nil : 4).textSelection(.enabled)
                        }
                        Button("打开对应执行会话") { onOpenSession(link.sessionId) }
                            .buttonStyle(WandSecondaryButtonStyle()).disabled(turn.sessionPreview?.status == "unavailable")
                    }.frame(maxWidth: .infinity, alignment: .leading).wandMotion(value: previewExpanded, layout: true)
                } else {
                    TurnView(turn: turn, baseURL: baseURL, showHeader: false, interactiveTools: false)
                    if let link = turn.conversationLink, let preview = turn.taskPreview {
                        VStack(alignment: .leading, spacing: 7) {
                            Text(link.title ?? "群任务").font(.system(size: 13, weight: .medium))
                            Text(preview.text).font(.system(size: 13)).lineLimit(previewExpanded ? nil : 4).textSelection(.enabled)
                            if let runID = preview.runId {
                                Button("选择这轮任务") { onSelectTarget(link.conversationId, ConversationTarget(taskId: link.taskId, runId: runID)) }
                                    .buttonStyle(WandSecondaryButtonStyle())
                            }
                        }
                    }
                    if let session = turn.author?.sessionId, turn.role != "user" {
                        Button("打开完整执行过程") { onOpenSession(session) }.buttonStyle(.plain).foregroundColor(Theme.wandAccent).font(.system(size: 12))
                    }
                }
            }
        }
        .foregroundColor(Theme.textPrimary)
    }
}

struct ConversationComposerSurface: View {
    @ObservedObject var owner: ConversationComposerState
    @ObservedObject var store: CommunicationsStore
    let conversation: NativeConversation
    @ObservedObject var focus: ComposerFocusController
    @AppStorage("wand.sendWithCommandEnter") private var commandEnter = false
    @State private var composing = false
    @State private var height: CGFloat = 36
    @State private var importFiles = false
    @State private var menuOpen = false
    @State private var settingsOpen = false
    private var blockReason: String? { store.sendBlockReason(for: owner.scope) }
    private var failed: Bool {
        switch owner.phase { case .rejected, .acceptedWithFailure: return true; default: return false }
    }
    private var expanded: Bool { focus.editing || focus.focused || failed || owner.unknownID != nil || owner.isSending || owner.uploading }
    private var phase: NativeComposerPhase {
        if owner.isSending || owner.reconciling { return .sending }
        switch owner.phase {
        case .idle: return .idle
        case .sending: return .sending
        case .sent: return .sent
        case .rejected, .acceptedWithFailure: return .failed
        case .unknown: return .unknown
        }
    }
    private var candidate: EmployeeExecutionCandidate? { store.contact(conversation.peerEmployeeId)?.candidates.first }
    var body: some View {
        VStack(spacing: 6) {
            if !owner.feedback.isEmpty || blockReason != nil {
                Text(owner.feedback.isEmpty ? blockReason ?? "" : owner.feedback)
                    .font(.system(size: 12)).foregroundColor(owner.unknownID != nil ? Theme.warning : failed ? Theme.danger : Theme.textSecondary)
                    .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            }
            FocusComposerSurface(expanded: expanded, hasDraft: !owner.text.isEmpty || !owner.attachments.isEmpty,
                summary: owner.attachments.isEmpty ? (owner.text.isEmpty ? "发消息…" : "草稿 · \(owner.text.count) 字") : "草稿 · \(owner.attachments.count) 附件", onFocus: { focus.focus() },
                editor: {
                    VStack(spacing: 4) {
                        if !owner.attachments.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(owner.attachments, id: \.savedPath) { file in
                                        HStack(spacing: 0) {
                                            Label(file.originalName, systemImage: "doc").font(.system(size: 12)).lineLimit(1).frame(minHeight: 44)
                                            Button { owner.removeAttachment(file.savedPath) } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
                                                .buttonStyle(.plain).accessibilityLabel("移除附件 \(file.originalName)")
                                        }
                                    }
                                }
                            }
                        }
                        IMEAwareComposerTextView(text: Binding(get: { owner.text }, set: { owner.edit($0) }),
                            placeholder: owner.unknownID == nil ? "输入消息…" : "新输入保留；请先核对上一份请求…", isFocused: focus.focused,
                            sendWithCommandEnter: commandEnter, onFocusChange: { value in
                                focus.focused = value; if value { focus.editing = true }
                            }, onCompositionChange: { composing = $0 }, onSubmit: send,
                            onHeightChange: { height = min(max($0, 34), FocusComposerMetrics.maximumTextHeight) },
                            onEscape: { if menuOpen { menuOpen = false } else { focus.collapse() } })
                            .frame(height: height).frame(maxWidth: .infinity)
                    }
                }, add: {
                    Button { focus.borrow("menu", open: true); menuOpen.toggle() } label: {
                        Image(systemName: "plus").font(.system(size: 18)).frame(width: 48, height: 48)
                    }.buttonStyle(.plain).accessibilityLabel("添加附件与对话操作").disabled(owner.isSending || owner.uploading)
                        .popover(isPresented: $menuOpen, arrowEdge: .bottom) { menu }
                }, send: {
                    NativeComposerActionButton(phase: phase,
                        canSubmit: !composing && !owner.uploading && (owner.unknownID != nil || (blockReason == nil && owner.canSubmit))) {
                        menuOpen = false
                        Task { if owner.unknownID != nil { await store.reconcile(owner.scope) } else { await store.send(owner.scope) } }
                    }
                }, settings: {
                    HStack(spacing: 2) {
                        setting("模型", value: candidate?.model == "default" ? "跟随服务端模型" : candidate?.model ?? "未取得")
                        setting("权限", value: candidate?.mode ?? "未取得")
                        setting("思考", value: candidate?.thinkingEffort ?? "未取得")
                    }
                }, primaryVisible: nativeComposerPrimaryVisible(text: owner.text, hasAttachments: !owner.attachments.isEmpty,
                    turnRunning: false, phase: phase))
        }
        .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 6)
        .onChange(of: owner.isSending) { value in if value { focus.submit() } }
        .onChange(of: menuOpen) { if !$0 { focus.resume("menu") } }
        .onChange(of: settingsOpen) { if !$0 { focus.resume("settings") } }
        .onChange(of: owner.phase) { value in
            if case .sent = value { focus.accepted(hasPendingContent: !owner.text.isEmpty || !owner.attachments.isEmpty || composing) }
            if case .rejected = value { focus.failed() }
            if case .unknown = value { focus.failed() }
            if case .acceptedWithFailure = value { focus.failed() }
        }
        .popover(isPresented: $settingsOpen, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                Text("员工默认配置").font(.headline)
                Text("以下配置影响后续新工作，不支持仅覆盖本条消息；不改变历史会话或自动修改员工配置。").font(.system(size: 13))
                Text("\(candidate?.toolLabel ?? "配置不可用") · \(candidate?.model ?? "首选模型未取得")")
                Text("权限：\(candidate?.mode ?? "未取得")；思考：\(candidate?.thinkingEffort ?? "未取得")")
                Button("完成") { settingsOpen = false }
            }.padding(20).frame(width: 340)
        }
        .fileImporter(isPresented: $importFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case let .success(urls) = result { Task { await store.addAttachments(urls, scope: owner.scope) } }
            focus.resume("files")
        }
        .onReceive(NotificationCenter.default.publisher(for: .wandDesktopCommand)) { notification in
            if notification.object as? DesktopCommand == .focusComposer { menuOpen = false; focus.focus() }
        }
        .onExitCommand { if menuOpen { menuOpen = false } else { focus.collapse() } }
    }
    private func setting(_ label: String, value: String) -> some View {
        Button { focus.borrow("settings", open: true); settingsOpen = true } label: {
            ComposerSettingLabel(title: label == "模型" ? value : "\(label)：\(value)")
        }.buttonStyle(.plain).accessibilityLabel("\(label)：\(value)，员工默认配置，影响后续新工作")
    }
    private var menu: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button("添加附件") { focus.borrow("files", open: true); menuOpen = false; importFiles = true }.buttonStyle(WandSecondaryButtonStyle())
            if conversation.isGroup {
                ForEach(conversation.members, id: \.id) { member in
                    Button("@\(member.name)") { owner.edit("@\(member.id) " + owner.text); menuOpen = false; focus.focus() }.buttonStyle(.plain)
                }
            }
            TextField("工作目录（可选）", text: Binding(get: { owner.cwd }, set: { owner.editCwd($0) })).textFieldStyle(.roundedBorder)
            Button("清除当前草稿") { owner.discard(); menuOpen = false }.buttonStyle(.plain)
        }.padding(16).frame(width: 280)
    }
    private func send() {
        guard !composing && blockReason == nil && owner.canSubmit else { return }
        menuOpen = false; Task { await store.send(owner.scope) }
    }
}

private struct ConversationRunAction: View {
    @ObservedObject var store: CommunicationsStore
    let scope: ConversationScope
    let action: String
    let title: String
    var requiresConfirmation = false
    @State private var confirmation = false
    private var operation: ConversationOperationState {
        let identity = store.actionIdentity(action, scope: scope)
        return store.operation(identity + ":" + scope.conversationID, pendingOperation: identity, conversationID: scope.conversationID)
    }
    var body: some View {
        ConversationOperationButton(operation: operation, title: title) {
            if operation.unknownID != nil { Task { _ = await operation.reconcile(ledger: store.ledger); store.refreshDetail() } }
            else if requiresConfirmation { confirmation = true }
            else { Task { await store.act(action, scope: scope, operation: operation) } }
        }
        .confirmationDialog("停止这轮任务？", isPresented: $confirmation) {
            Button("停止本轮", role: .destructive) { Task { await store.act(action, scope: scope, operation: operation) } }
        } message: { Text("只作用于当前选择的任务与轮次，其他工作不受影响。") }
    }
}

private struct ConversationOperationButton: View {
    @ObservedObject var operation: ConversationOperationState
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                ZStack {
                    ProgressView().controlSize(.mini).opacity(operation.busy ? 1 : 0)
                    Image(systemName: "checkmark").opacity(operation.receipt?.state == "accepted" && !operation.busy ? 1 : 0)
                }.frame(width: 14, height: 14)
                Text(operation.unknownID != nil ? "核对请求" : operation.receipt?.state == "accepted" ? "已接受" : title)
                    .font(.system(size: 12))
            }.frame(width: 104, height: 26)
        }.buttonStyle(WandSecondaryButtonStyle()).disabled(operation.busy).help(operation.feedback)
            .wandMotion(value: operation.busy)
    }
}

struct ConversationGroupEditor: View {
    @ObservedObject var store: CommunicationsStore
    let invitation: NativeConversation?
    let close: () -> Void
    @State private var draft = ConversationGroupDraft()
    @State private var capturedInvitation: NativeConversation?
    @FocusState private var nameFocused: Bool
    private var operation: ConversationOperationState {
        let id = invitation?.id ?? ""
        return store.operation("\(invitation == nil ? "create-group" : "invite"):\(id)",
                               pendingOperation: invitation == nil ? "create-group" : "invite", conversationID: id)
    }
    private var candidates: [EmployeeContact] {
        let existing = Set(invitation?.members.compactMap(\.employeeId) ?? [])
        return store.contacts.filter { !$0.isArchived && !existing.contains($0.id) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(invitation == nil ? "发起群聊" : "邀请员工").font(.system(size: 17, weight: .semibold))
                Spacer()
                Button(action: close) { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("关闭")
            }
            if invitation == nil {
                TextField("群名称（可留空）", text: $draft.name).textFieldStyle(.roundedBorder).focused($nameFocused)
            }
            Text(invitation == nil ? "选择成员，并明确指定负责人。创建不会自动派发工作。" : "选择要加入的员工；已有负责人保持不变，不会自动派发工作。")
                .font(.system(size: 12)).foregroundColor(Theme.textSecondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(candidates) { contact in
                        Toggle(isOn: Binding(get: { draft.employeeIDs.contains(contact.id) }, set: { _ in draft.toggle(contact.id) })) {
                            HStack(spacing: 8) {
                                ContactAvatar(id: contact.id, avatar: contact.avatar ?? "", name: contact.name, size: 28)
                                Text(contact.name).lineLimit(1)
                            }
                        }.toggleStyle(.checkbox).font(.system(size: 13))
                    }
                }.padding(.vertical, 4)
            }.frame(height: 210)
            if invitation == nil && !draft.employeeIDs.isEmpty {
                Picker("负责人", selection: $draft.leaderID) {
                    ForEach(store.contacts.filter { draft.employeeIDs.contains($0.id) }) { contact in Text(contact.name).tag(contact.id) }
                }.pickerStyle(.menu)
            }
            Text(operation.feedback).font(.system(size: 12)).foregroundColor(operation.unknownID == nil ? Theme.textSecondary : Theme.warning)
                .lineLimit(3).frame(height: 42, alignment: .topLeading)
            HStack {
                ConversationOperationButton(operation: operation, title: invitation == nil ? "创建群聊" : "确认邀请") {
                    Task {
                        if operation.unknownID != nil { _ = await operation.reconcile(ledger: store.ledger); await store.refreshIndex() }
                        else if let accepted = operation.receipt, accepted.state == "accepted" { store.select(accepted.conversationId); close() }
                        else if let capturedInvitation { _ = await store.invite(draft, into: capturedInvitation, operation: operation) }
                        else { _ = await store.createGroup(draft, operation: operation) }
                    }
                }
                if let receipt = operation.receipt, receipt.state == "accepted" {
                    Button("打开对话") { store.select(receipt.conversationId); close() }.buttonStyle(WandSecondaryButtonStyle())
                    Button(invitation == nil ? "再建一个群" : "再次邀请") {
                        operation.resetAcceptedOutcome(); draft = ConversationGroupDraft()
                        capturedInvitation = invitation == nil ? nil : store.detail
                    }.buttonStyle(.plain).font(.system(size: 11))
                }
                Spacer()
            }
        }
        .padding(20).frame(width: 360).foregroundColor(Theme.textPrimary)
        .onAppear { capturedInvitation = invitation; nameFocused = invitation == nil }
        .onExitCommand(perform: close)
    }
}

private func communicationEmpty(_ title: String, detail: String, symbol: String) -> some View {
    VStack(spacing: 14) {
        Image(systemName: symbol).font(.system(size: 28)).foregroundColor(Theme.textSecondary)
        Text(title).font(.system(size: 21, weight: .semibold)).foregroundColor(Theme.textPrimary)
        Text(detail).font(.system(size: 14)).foregroundColor(Theme.textSecondary).multilineTextAlignment(.center).frame(maxWidth: 420)
    }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
}
