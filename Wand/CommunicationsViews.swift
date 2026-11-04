import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct CommunicationsSidebar: View {
    @ObservedObject var store: CommunicationsStore
    var sessions: [WorkspaceSessionSummary] = []
    var taskGroups: [TaskDirectoryGroup] = []
    var taskGroupsLoaded = false
    var taskGroupsError: String? = nil
    var selectedSessionID: String? = nil
    var onCreateSession: ((EmployeeContact) -> Void)? = nil
    var onShowConversation: () -> Void = {}
    var onOpenSession: (String) -> Void = { _ in }
    private var conversationRows: [NativeConversation] { store.conversationList(sessions: sessions, selectedSessionID: selectedSessionID, entries: indexedEntries) }
    @FocusState private var searchFocused: Bool
    @FocusState private var filterFocused: Bool
    @State private var expandedPeople: Set<String> = []
    @State private var otherOpen = false
    @State private var filtersOpen = false

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 7) {
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
                if store.section == .conversations {
                    Button { filtersOpen.toggle() } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "line.3.horizontal.decrease.circle")
                            Text(store.listFilters.count == 0 ? "筛选" : "\(store.listFilters.count)")
                        }.font(.system(size: 12)).frame(width: 64, height: 32)
                    }
                    .buttonStyle(DesktopNavigationButtonStyle(active: store.listFilters.count > 0))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).stroke(Theme.border, lineWidth: 1))
                    .focused($filterFocused)
                    .help("更多筛选：任务阶段与查看归档，选择后即时生效，不影响当前会话")
                    .accessibilityLabel("筛选对话，\(store.listFilters.count) 个条件")
                    .popover(isPresented: $filtersOpen, arrowEdge: .top) {
                        ConversationFilterPanel(store: store, close: { filtersOpen = false })
                    }
                    .onChange(of: filtersOpen) { if !$0 { filterFocused = true } }
                }
            }.padding(.horizontal, 12)
            if store.section == .contacts {
                Toggle("显示已归档员工", isOn: $store.includesArchivedContacts)
                    .toggleStyle(.checkbox).font(.system(size: 11)).padding(.horizontal, 14)
            }
            if store.section == .conversations {
                if store.listFilters.count > 0 {
                    HStack(spacing: 6) {
                        Text(filterSummary).lineLimit(1).help(filterSummary).accessibilityLabel(filterSummary)
                        Spacer(minLength: 0)
                        Button("清除") { store.listFilters = ConversationListFilters() }
                            .buttonStyle(.plain).foregroundColor(Theme.wandAccent).accessibilityLabel("清除筛选，保留搜索")
                    }.font(.system(size: 11)).foregroundColor(Theme.textSecondary).padding(.horizontal, 14)
                }
                Text("\(conversationRows.count + sessionOnlyPeople.count) 个对话 · \(matchingEntries.count) 条关联会话")
                    .font(.system(size: 11)).foregroundColor(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14)
                if let taskGroupsError {
                    Text("任务关联读取失败：" + taskGroupsError).font(.system(size: 11)).foregroundColor(Theme.danger)
                        .lineLimit(2).padding(.horizontal, 14)
                } else if !taskGroupsLoaded {
                    Text("正在读取任务关联…").font(.system(size: 11)).foregroundColor(Theme.textSecondary)
                }
            }
            if let error = store.section == .contacts ? store.contactsError : store.conversationsError {
                Text(error).font(.system(size: 11)).foregroundColor(Theme.danger)
                    .lineLimit(3).padding(.horizontal, 14)
            }
            ScrollView {
                LazyVStack(spacing: 3) {
                    if store.section == .contacts {
                        ForEach(store.filteredContacts) { contact in
                            Button { if let onCreateSession { onCreateSession(contact) } else { onShowConversation(); store.selectContact(contact) } } label: {
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
                        ForEach(conversationRows) { conversation in
                            conversationPerson(conversation)
                        }
                        ForEach(sessionOnlyPeople, id: \.id) { person in
                            sessionOnlyPerson(person)
                        }
                        if !otherConversationSessions.isEmpty {
                            otherConversationSection
                        }
                        if conversationRows.isEmpty && sessionOnlyPeople.isEmpty && otherConversationSessions.isEmpty && !store.indexLoading && taskGroupsLoaded && taskGroupsError == nil {
                            Text(store.listFilters.hasFacets ? "没有符合筛选条件的对话。" : !store.query.isEmpty ? "没有匹配的对话" : store.activityOnly ? "现在没有符合筛选条件的活动对话。" : store.archiveFilter == .archived ? "还没有已归档的对话。" : store.archiveFilter == .unarchived ? "还没有未归档的对话。" : DesktopGroupChatPresentation.isVisible ? "从通讯录选择员工开始私聊，或在上方加号发起群聊。" : "从通讯录选择员工开始私聊。")
                                .font(.system(size: 12)).foregroundColor(Theme.textSecondary).padding(16)
                        }
                    }
                    if store.indexLoading && !store.indexLoaded { ProgressView().controlSize(.small).padding(16) }
                }
                .padding(.horizontal, 12).padding(.bottom, 16)
            }
        }
    }

    private var indexedEntries: [ConversationSessionEntry] {
        ConversationSessionEntry.index(groups: taskGroups, fallback: sessions)
    }

    private var matchingEntries: [ConversationSessionEntry] {
        indexedEntries.filter { entry in
            let parent = store.items.first { $0.kind == "dm" && $0.peerEmployeeId == entry.session.employeeId }
            return entry.matches(store.listFilters, query: store.query, parentTitle: parent?.displayTitle, conversationArchived: parent?.isArchived == true)
        }
    }

    private var filterSummary: String { store.filterSummary(groups: taskGroups) }

    private func sessions(for employeeId: String?) -> [ConversationSessionEntry] {
        guard let employeeId else { return [] }
        return matchingEntries.filter { $0.session.employeeId == employeeId }
    }

    private var otherConversationSessions: [ConversationSessionEntry] {
        matchingEntries.filter { ($0.session.employeeId ?? "").isEmpty }
    }

    private var sessionOnlyPeople: [(id: String, name: String, preview: String)] {
        let owned = Set(store.items.compactMap { $0.kind == "dm" ? $0.peerEmployeeId : nil })
        var seen = Set<String>()
        var rows: [(String, String, String)] = []
        for entry in matchingEntries {
            let session = entry.session
            guard let employeeId = session.employeeId, !employeeId.isEmpty, !owned.contains(employeeId), seen.insert(employeeId).inserted else { continue }
            rows.append((employeeId, session.employeeName ?? "员工", session.title ?? "有工作会话，尚未开始私聊"))
        }
        return rows
    }

    private func sessionOnlyPerson(_ person: (id: String, name: String, preview: String)) -> some View {
        let conversationId = "dm_\(person.id)"
        let personSessions = sessions(for: person.id)
        let expanded = expandedPeople.contains(conversationId) || !store.query.isEmpty
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Button { onShowConversation(); store.select(conversationId) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(person.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        Text("\(personSessions.count) 条匹配会话").font(.system(size: 11)).foregroundColor(Theme.textSecondary).lineLimit(1)
                    }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }.buttonStyle(.plain).accessibilityLabel("打开\(person.name)的私聊")
                Button {
                    if expandedPeople.contains(conversationId) { expandedPeople.remove(conversationId) } else { expandedPeople.insert(conversationId) }
                } label: { Image(systemName: "chevron.right").rotationEffect(.degrees(expanded ? 90 : 0)).frame(width: 28, height: 32) }
                    .buttonStyle(.plain).accessibilityLabel("展开\(person.name)的会话")
            }
            if expanded {
                ForEach(personSessions, id: \.id) { session in conversationSessionRow(session) }
            }
        }.padding(.horizontal, 9)
    }

    @ViewBuilder private func conversationPerson(_ conversation: NativeConversation) -> some View {
        let personSessions = sessions(for: conversation.peerEmployeeId)
        let expanded = expandedPeople.contains(conversation.id) || !store.query.isEmpty
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Button { onShowConversation(); store.select(conversation.id) } label: {
                    HStack(spacing: 9) {
                        if conversation.external != nil { Image(systemName: "person.3").frame(width: 36, height: 36).foregroundColor(Theme.textSecondary) }
                        else if conversation.isGroup { ContactGroupAvatar(profile: store.userProfile, members: conversation.members, contacts: store.contacts) }
                        else { ContactAvatar(id: conversation.peerEmployeeId ?? conversation.id, avatar: store.contact(conversation.peerEmployeeId)?.avatar ?? "", name: conversation.displayTitle, size: 36) }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(conversation.displayTitle).font(.system(size: 13, weight: .medium)).lineLimit(1)
                            Text(personSessions.isEmpty ? conversation.preview ?? "私聊" : "\(personSessions.count) 条匹配会话")
                                .font(.system(size: 11)).foregroundColor(Theme.textSecondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        if conversation.pinnedAt != nil { Image(systemName: "pin.fill").font(.system(size: 9)) }
                    }.frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                }.buttonStyle(.plain).accessibilityLabel("打开\(conversation.displayTitle)的私聊")
                if conversation.kind == "dm" && !personSessions.isEmpty {
                    Button {
                        if expandedPeople.contains(conversation.id) { expandedPeople.remove(conversation.id) }
                        else { expandedPeople.insert(conversation.id) }
                    } label: {
                        Image(systemName: "chevron.right").rotationEffect(.degrees(expanded ? 90 : 0))
                            .frame(width: 28, height: 32)
                    }.buttonStyle(.plain).accessibilityLabel(expanded ? "收起\(conversation.displayTitle)的会话" : "展开\(conversation.displayTitle)的会话")
                }
            }
            .foregroundColor(Theme.textPrimary).padding(.horizontal, 9)
            .background(selectedSessionID == nil && store.selectedID == conversation.id ? Theme.wandAccent.opacity(0.12) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            if expanded {
                ForEach(personSessions, id: \.id) { session in
                    conversationSessionRow(session)
                }
            }
        }
    }

    private var otherConversationSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button { otherOpen.toggle() } label: {
                HStack {
                    Image(systemName: "terminal")
                    Text("其他会话")
                    Spacer()
                    Text("\(otherConversationSessions.count)")
                    Image(systemName: "chevron.right").rotationEffect(.degrees(otherOpen || !store.query.isEmpty ? 90 : 0))
                }.font(.system(size: 12)).foregroundColor(Theme.textSecondary).frame(minHeight: 36)
            }.buttonStyle(.plain).accessibilityLabel("其他会话")
            if otherOpen || !store.query.isEmpty {
                ForEach(otherConversationSessions, id: \.id) { session in conversationSessionRow(session) }
            }
        }.padding(.horizontal, 9).padding(.top, 8)
    }

    private func conversationSessionRow(_ entry: ConversationSessionEntry) -> some View {
        let session = entry.session
        return Button { onOpenSession(session.id) } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title ?? "会话").font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(entry.caption).help(entry.caption)
                    .font(.system(size: 10)).foregroundColor(Theme.textSecondary).lineLimit(1)
            }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).padding(.leading, 28)
        }.buttonStyle(DesktopNavigationButtonStyle(active: selectedSessionID == session.id))
            .disabled(entry.isSystemCall)
            .help(entry.isSystemCall ? "系统调用记录仅供查看，不可继续执行" : entry.caption)
            .accessibilityLabel("\(session.title ?? "会话")，\(entry.caption)")
    }
}

private struct ConversationFilterPanel: View {
    @ObservedObject var store: CommunicationsStore
    let close: () -> Void
    private var archivedOnly: Bool { store.listFilters.runtimeValues == [.archived] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ComposerPopoverHeader(title: "更多筛选", close: close)
            Picker("任务阶段", selection: Binding(get: { store.taskStageFilter }, set: { store.taskStageFilter = $0; close() })) {
                ForEach(ConversationTaskStage.allCases, id: \.self) { Text($0.label).tag($0) }
            }.pickerStyle(.menu).help("选择后即时筛选列表，保留工作区与员工条件")
            Button(archivedOnly ? "返回未归档会话" : "只看已归档会话") {
                store.showArchivedSessions(!archivedOnly); close()
            }.help("保留工作区与员工，切换到所选范围的全部运行状态")
            if store.taskStageFilter != .all {
                Button("清除任务阶段") { store.taskStageFilter = .all; close() }
            }
        }.font(.system(size: 12)).padding(16).frame(width: 260)
            .onExitCommand(perform: close)
    }
}

/// Text-only activity toggle shared by the workspace and conversation filters.
struct SidebarActivityFilter: View {
    let active: Bool
    var label = "只看活动会话"
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text("活动").font(.system(size: 11, weight: .medium)).frame(width: 48, height: 28)
                .foregroundColor(active ? Theme.wandAccent : Theme.textSecondary)
                .background(Capsule().fill(active ? Theme.wandAccent.opacity(0.12) : .clear))
                .overlay(Capsule().stroke(active ? Theme.wandAccent.opacity(0.45) : Theme.border, lineWidth: 1))
        }.buttonStyle(.plain).wandMotion(value: active)
            .help("在跑、待处理及尚未查看的刚完成内容")
            .accessibilityLabel(label).accessibilityValue(active ? "已开启" : "已关闭")
    }
}

struct CommunicationsContent: View {
    @Environment(\.desktopPageActive) private var pageActive
    @ObservedObject var store: CommunicationsStore
    let baseURL: URL
    let onOpenSession: (String) -> Void
    @State private var groupEditorOpen = false
    private let refresh = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(store.section == .contacts ? "通讯录" : store.detail?.displayTitle ?? "对话")
                    .font(.system(size: 18, weight: .semibold)).foregroundColor(Theme.textPrimary).lineLimit(1)
                Spacer()
                if store.section == .conversations && store.selectedID != nil { ConversationMessageSearch(store: store) }
                Button { Task { await store.refreshVisible() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(WandIconButtonStyle()).frame(width: 32, height: 32).help("刷新通讯录与对话")
                if DesktopGroupChatPresentation.isVisible {
                    Button { groupEditorOpen.toggle() } label: { Image(systemName: "plus") }
                        .buttonStyle(WandIconButtonStyle(isActive: groupEditorOpen)).frame(width: 32, height: 32)
                        .accessibilityLabel("发起群聊").help("发起群聊")
                        .popover(isPresented: $groupEditorOpen, arrowEdge: .top) {
                            ConversationGroupEditor(store: store, invitation: nil) { groupEditorOpen = false }
                        }
                }
            }
            .padding(.horizontal, 24).frame(height: 56)
            Divider()
            if store.section == .contacts {
                if let contact = store.contact(store.selectedContactID) {
                    ConversationContactProfile(contact: contact, api: store.api as? WandAPI) { store.selectEmployee(contact) }
                        .id(contact.id)
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
                    Button("重新读取") { store.refreshDetail() }.buttonStyle(.bordered)
                }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                communicationEmpty("和员工一起推进工作", detail: "打开已有对话，或从通讯录发起私聊。每份工作都链接到自己的原生执行会话。", symbol: "bubble.left.and.bubble.right")
            }
        }
        .background(Theme.workspaceBackground)
        .task { await store.refreshVisible() }
        .onDisappear { store.stopRealtime() }
        .onReceive(refresh) { _ in Task { await store.refreshVisible() } }
        .onReceive(NotificationCenter.default.publisher(for: .wandIdentitySaved)) { _ in Task { await store.refreshIndex() } }
        .onChange(of: store.query) { _ in groupEditorOpen = false }
        .onChange(of: store.section) { _ in groupEditorOpen = false }
        .onReceive(NotificationCenter.default.publisher(for: .wandDesktopCommand)) { note in
            if pageActive && note.object as? DesktopCommand == .findConversation && store.section == .conversations && store.selectedID != nil {
                groupEditorOpen = false; store.messageSearchExpanded = true
            }
        }
        .onExitCommand { groupEditorOpen = false }
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
            thinking: avatarIsThinking(messages: execution.messages, executing: active), size: FocusComposerMetrics.normalCompanionSize)
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
    let api: WandAPI?
    let open: () -> Void
    @State private var expandedDuty = false
    @State private var settingsExpanded = false
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
                if let api {
                    DisclosureGroup(isExpanded: $settingsExpanded) {
                        SettingsEmployeeIdentities(api: api, loadData: {
                            async let profile = api.communicationsUserProfile()
                            async let contacts = api.employeeContacts()
                            return try await (profile, contacts)
                        }, initialEmployeeID: contact.id)
                        .padding(.top, 12)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("员工设置").font(.system(size: 13, weight: .semibold))
                            Text([
                                contact.systemSessionLimit.map { $0 == 0 ? "系统调用历史：不保留已结束记录" : "系统调用历史：保留最新 \($0) 条已结束记录" } ?? "系统调用历史：不限",
                                "并发任务：同时 \(contact.effectiveMaxConcurrentTasks) 个，超出排队",
                            ].joined(separator: " · "))
                                .font(.system(size: 12)).foregroundColor(Theme.textSecondary)
                        }
                    }
                    .accessibilityIdentifier("contact-employee-settings")
                    .wandMotion(value: settingsExpanded, layout: true)
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
    @Environment(\.desktopPageActive) private var pageActive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var store: CommunicationsStore
    let conversation: NativeConversation
    let scope: ConversationScope
    let baseURL: URL
    let onOpenSession: (String) -> Void
    @State private var messagesLimit = 80
    @State private var historyAnchor: String?
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
    private var turnNavigationScope: String { "\(baseURL.absoluteString)|conversation|\(scope.key)" }
    private var turnNavigation: TurnNavigationIndex {
        TurnNavigationIndex(scope: turnNavigationScope, turns: conversation.turns, offset: 0,
                            visibleIndices: Set(displayed.map(\.index)))
    }
    private var turnNavigationNote: String {
        "当前显示 \(displayed.count) / 已加载 \(conversation.turns.count) 条消息；仅列用户提问。"
            + (store.messageQuery.isEmpty ? "更早内容使用列表顶部的显示按钮。" : "当前目录遵循消息搜索筛选。")
    }

    var body: some View {
        VStack(spacing: 0) {
            if let error = store.detailError {
                HStack {
                    Text(error).font(.system(size: 11)).foregroundColor(Theme.warning).lineLimit(2)
                    Spacer()
                    Button("重新读取") { store.refreshDetail() }.buttonStyle(.bordered)
                }.padding(12)
            }
            if let origin = conversation.external {
                VStack(alignment: .leading, spacing: 6) {
                    Text(origin.statusText).font(.system(size: 13, weight: .medium))
                    Text(origin.syncError ?? "普通群消息只同步展示；请在钉钉中原生 @员工。最终正文回群，执行过程只在 Wand 查看。")
                        .font(.system(size: 12)).foregroundColor(Theme.textSecondary)
                    Text("已接入员工：" + (origin.bindings ?? []).map { store.contact($0.employeeId)?.name ?? "员工已不可用" }.joined(separator: "、"))
                        .font(.system(size: 12)).foregroundColor(Theme.textSecondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                Divider()
            } else if conversation.isGroup {
                groupContext.padding(.horizontal, 24).padding(.vertical, 12)
                Divider()
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        if conversation.history?.hasEarlier == true {
                            Button(store.detailLoading ? "加载中…" : "加载更早消息") { historyAnchor = displayed.first?.id; store.refreshDetail(older: true); messagesLimit += 40 }
                                .buttonStyle(.bordered).disabled(store.detailLoading)
                        }
                        if conversation.turns.count > messagesLimit {
                            Button("显示更早的消息（\(conversation.turns.count - messagesLimit) 条）") { messagesLimit += 80 }
                                .buttonStyle(.bordered)
                        }
                        if !store.messageQuery.isEmpty && displayed.isEmpty {
                            Text("没有匹配的已加载消息").font(.system(size: 13)).foregroundColor(Theme.textSecondary)
                        }
                        if conversation.turns.isEmpty {
                            Text(conversation.external != nil ? "正在同步钉钉群消息；普通消息不启动员工。" : conversation.isGroup ? "群内尚无消息。普通消息仅沟通；明确 @成员 才会派发新任务。" : "这里是你和员工的独立私聊。发送新工作后，会出现精确的执行会话入口。")
                                .font(.system(size: 14)).foregroundColor(Theme.textSecondary).padding(.vertical, 32)
                        }
                        ForEach(displayed, id: \.id) { item in
                            CommunicationMessageRow(turn: item.turn, baseURL: baseURL, contacts: store.contacts, members: conversation.members, profile: store.userProfile, onOpenSession: onOpenSession,
                                onSelectTarget: { id, target in store.select(id); store.selectTarget(target) })
                                .id(item.id)
                        }
                        Color.clear.frame(height: 1).id("conversation-bottom")
                    }
                    .padding(.horizontal, 24).padding(.vertical, 24)
                    .chatContentWidth()
                }
                .clipped().simultaneousGesture(TapGesture().onEnded { composerFocus.collapseFromContent() })
                .overlay(alignment: .leading) {
                    HStack {
                        TurnNavigator(entries: turnNavigation.entries, windowNote: turnNavigationNote) { id in
                            guard pageActive, store.selectedID == conversation.id,
                                  store.selectedScope == scope,
                                  let index = turnNavigation.resolve(id),
                                  let row = displayed.first(where: { $0.index == index }) else { return }
                            withAnimation(reduceMotion ? nil : Theme.Motion.structure) {
                                proxy.scrollTo(row.id, anchor: .top)
                            }
                        }
                        .id(turnNavigationScope + "|query|" + store.messageQuery)
                    }
                    .padding(.horizontal, 24).padding(.vertical, 4)
                }
                .onAppear { proxy.scrollTo("conversation-bottom", anchor: .bottom) }
                .onChange(of: conversation.turns.first?.messageId) { _ in
                    if let anchor = historyAnchor { historyAnchor = nil; proxy.scrollTo(anchor, anchor: .top) }
                }
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
                DisclosureGroup("\(conversation.members.count + 1) 位成员", isExpanded: $membersExpanded) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            ContactAvatar(id: "user", avatar: store.userProfile.avatar, name: store.userProfile.displayName, size: 28)
                            Text(store.userProfile.displayName + " · 我").font(.system(size: 12)); Spacer()
                        }
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
                    .buttonStyle(.bordered).disabled(conversation.sendBlockReason != nil)
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
    let profile: NativeUserProfile
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
                    ContactAvatar(id: turn.role == "user" ? "user" : employeeID, avatar: turn.role == "user" ? profile.avatar : current?.avatar ?? turn.author?.avatar ?? "",
                        name: turn.role == "user" ? profile.displayName : current?.name ?? turn.author?.name ?? "", provider: turn.role == "user" ? nil : turn.author?.provider, size: 28)
                    Text(turn.role == "user" ? profile.displayName : current?.name ?? turn.author?.name ?? "助手")
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
                            let status = ChatRunningPresentation.preview(status: preview.status)
                            if !status.label.isEmpty {
                                Text(status.label).font(.system(size: 12))
                                    .foregroundColor(status.stage == .failed ? Theme.danger : Theme.textSecondary)
                            }
                            Text(messageLinkedText(preview.text.isEmpty ? "打开原会话查看完整进度。" : preview.text))
                                .messageLinkHandling(baseURL: baseURL)
                                .environment(\.messageFileContext, WandMessageFileContext(sessionID: link.sessionId))
                                .font(.system(size: 14)).lineSpacing(4).lineLimit(previewExpanded ? nil : 4).textSelection(.enabled)
                        }
                        Button(turn.sessionPreview?.historyOnly == true ? "查看历史回复" : "打开对应执行会话") { onOpenSession(link.sessionId) }
                            .buttonStyle(.bordered).disabled(turn.sessionPreview?.status == "unavailable")
                    }.frame(maxWidth: .infinity, alignment: .leading).wandMotion(value: previewExpanded, layout: true)
                } else {
                    TurnView(turn: turn, baseURL: baseURL, showHeader: false, interactiveTools: false)
                    if let link = turn.conversationLink, let preview = turn.taskPreview {
                        VStack(alignment: .leading, spacing: 7) {
                            Text(link.title ?? "群任务").font(.system(size: 13, weight: .medium))
                            let status = ChatRunningPresentation.preview(status: preview.status)
                            if !status.label.isEmpty {
                                Text(status.label).font(.system(size: 12))
                                    .foregroundColor(status.stage == .failed ? Theme.danger : Theme.textSecondary)
                            }
                            Text(preview.text).font(.system(size: 13)).lineLimit(previewExpanded ? nil : 4).textSelection(.enabled)
                            if let runID = preview.runId {
                                Button("选择这轮任务") { onSelectTarget(link.conversationId, ConversationTarget(taskId: link.taskId, runId: runID)) }
                                    .buttonStyle(.bordered)
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
    @Environment(\.desktopPageActive) private var pageActive
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
    @State private var directoryOpen = false
    @State private var directoryDraft = ""
    @State private var recentDirectories: [RecentPath] = []
    @Environment(\.workspaceAPI) private var workspaceAPI
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
    private var editablePreference: Bool { !conversation.isGroup && owner.scope.target == nil }
    private var candidate: EmployeeExecutionCandidate? {
        if editablePreference, let preference = store.executionPreference { return preference }
        if let target = owner.scope.target {
            return conversation.runs.first { $0.id == target.runId }?.team?.members.first { $0.isLeader == true }?.agent
        }
        if conversation.isGroup { return conversation.members.first { $0.isLeader == true }?.agent }
        return store.contact(conversation.peerEmployeeId)?.candidates.first
    }
    private var preferredModel: String {
        guard let model = candidate?.model, !model.isEmpty else { return "配置未就绪" }
        let resolved = wandModelDisplayName(provider: candidate?.provider ?? "", model: model, catalog: store.modelCatalog)
        return resolved.isEmpty ? "工具默认模型（待解析）" : resolved
    }
    private var preferredThinking: String {
        guard let candidate, let effort = candidate.thinkingEffort else { return "未取得" }
        return thinkingEffortOptions(provider: candidate.provider, selectedModel: candidate.model,
            defaultModel: store.modelCatalog?.defaultModelId(for: candidate.provider), models: store.modelCatalog?.models(for: candidate.provider) ?? [])
            .first { $0.id == effort }?.shortLabel ?? composerThinkingPreference(effort)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !owner.feedback.isEmpty || blockReason != nil {
                Text(owner.feedback.isEmpty ? blockReason ?? "" : owner.feedback)
                    .font(.system(size: 12)).foregroundColor(owner.unknownID != nil ? Theme.warning : failed ? Theme.danger : Theme.textSecondary)
                    .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 6)
            }
            FocusComposerSurface(expanded: expanded, hasDraft: !owner.text.isEmpty || !owner.attachments.isEmpty,
                summary: owner.attachments.isEmpty ? (owner.text.isEmpty ? "输入消息…" : "草稿 · \(owner.text.count) 字") : "草稿 · \(owner.attachments.count) 附件", onFocus: { focus.focus() },
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
                            onEscape: { if menuOpen { menuOpen = false } else { focus.collapse() } },
                            onPasteAttachment: { store.importAttachments(from: $0, scope: owner.scope) })
                            .frame(height: height).frame(maxWidth: .infinity)
                    }
                }, add: {
                    Button { focus.borrow("menu", open: true); menuOpen.toggle() } label: {
                        Image(systemName: "plus").font(.system(size: 18))
                    }.buttonStyle(ComposerControlStyle()).accessibilityLabel("添加附件与对话操作").disabled(owner.isSending || owner.uploading)
                        .popover(isPresented: $menuOpen, arrowEdge: .bottom) { menu }
                }, send: {
                    NativeComposerActionButton(phase: phase,
                        canSubmit: !composing && !owner.uploading && (owner.unknownID != nil || (blockReason == nil && owner.canSubmit))) {
                        menuOpen = false
                        Task { if owner.unknownID != nil { await store.reconcile(owner.scope) } else { await store.send(owner.scope) } }
                    }
                }, isFocused: focus.focused, runtime: AnyView(HStack(spacing: 4) {
                    if let employee = store.contact(conversation.peerEmployeeId) {
                        Button { focus.borrow("settings", open: expanded); settingsOpen = true } label: {
                            WorkingAvatar(id: employee.id, name: employee.name, avatar: employee.avatar ?? "", size: 24)
                        }.buttonStyle(.plain).frame(width: 32, height: 32).help(employee.name)
                    }
                    if editablePreference, let candidate {
                        executionSelectors(candidate).disabled(owner.isSending || owner.unknownID != nil || blockReason != nil)
                    } else {
                        Text(preferredModel).lineLimit(1).truncationMode(.tail)
                        Text(preferredThinking).fixedSize()
                    }
                }.font(.system(size: 12)).frame(maxWidth: 280)))
            HStack(spacing: 8) { directorySelector; Spacer(minLength: 0) }
                .font(.system(size: 12)).foregroundColor(Theme.textSecondary).padding(.top, 6)
        }
        .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 8)
        .onChange(of: owner.isSending) { value in if value { focus.submit() } }
        .onChange(of: menuOpen) { if !$0 { focus.resume("menu") } }
        .onChange(of: settingsOpen) { if !$0 { focus.resume("settings") } }
        .onChange(of: directoryOpen) { if !$0 { focus.resume("directory") } }
        .onChange(of: conversation.id) { _ in directoryOpen = false }
        .onChange(of: owner.isSending) { if $0 { directoryOpen = false } }
        .onChange(of: owner.phase) { value in
            if case .sent = value { focus.accepted(hasPendingContent: !owner.text.isEmpty || !owner.attachments.isEmpty || composing) }
            if case .rejected = value { focus.failed() }
            if case .unknown = value { focus.failed() }
            if case .acceptedWithFailure = value { focus.failed() }
        }
        .popover(isPresented: $settingsOpen, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                ComposerPopoverHeader(title: owner.scope.target == nil ? "新工作的首选配置" : "本轮负责人的首选配置") { settingsOpen = false }
                Text(owner.scope.target == nil ? "以下为新工作的首选配置；降级后以实际执行会话为准，不改变历史会话或自动修改员工配置。" : "以下为此轮负责人保存的首选配置；补充消息沿用原执行会话，降级后以实际会话为准。").font(.system(size: 13))
                Text("\(candidate?.toolLabel ?? "配置不可用") · \(preferredModel)")
                Text("权限：\(candidate?.mode ?? "未取得")；思考：\(preferredThinking)")
                Button("完成") { settingsOpen = false }
            }.padding(20).frame(width: 340)
        }
        .fileImporter(isPresented: $importFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case let .success(urls) = result { Task { await store.addAttachments(urls, scope: owner.scope) } }
            focus.resume("files")
        }
        .onReceive(NotificationCenter.default.publisher(for: .wandDesktopCommand)) { notification in
            if pageActive && notification.object as? DesktopCommand == .focusComposer { menuOpen = false; focus.focus() }
        }
        .onExitCommand { if menuOpen { menuOpen = false } else { focus.collapse() } }
    }
    private var companion: some View {
        ComposerIdentityHeader(kind: .conversation, portrait: {
            let employee = store.contact(conversation.peerEmployeeId)
            let session = conversation.turns.reversed().first { ["starting", "running", "waiting_user"].contains($0.sessionPreview?.status ?? "") }?.sessionLink?.sessionId
            ComposerCompanion(focus: focus.focus) {
                if let api = store.api as? WandAPI, let session, let employee {
                    ExecutingConversationCompanion(api: api, sessionID: session, employee: employee).id(session)
                } else if let employee {
                    WorkingAvatar(id: employee.id, name: employee.name, avatar: employee.avatar ?? "", size: FocusComposerMetrics.normalCompanionSize)
                } else {
                    if conversation.isGroup { ContactGroupAvatar(profile: store.userProfile, members: conversation.members, contacts: store.contacts, size: FocusComposerMetrics.normalCompanionSize) }
                    else { ContactAvatar(id: conversation.id, name: conversation.displayTitle, size: FocusComposerMetrics.normalCompanionSize) }
                }
            }
        }, identity: { Text(conversation.displayTitle).foregroundColor(Theme.textPrimary) }, runtime: {
            HStack(spacing: 8) {
                if editablePreference, let candidate {
                    executionSelectors(candidate).disabled(owner.isSending || owner.unknownID != nil || blockReason != nil)
                    directorySelector
                } else {
                    Text(candidate?.toolLabel ?? "工具未就绪").lineLimit(1)
                    Text(preferredModel).lineLimit(1).truncationMode(.tail)
                    Text("·").accessibilityHidden(true)
                    Text("思考：" + preferredThinking).lineLimit(1).fixedSize()
                }
            }.font(.system(size: 12)).foregroundColor(Theme.textSecondary)
                .help("首选模型：\(preferredModel)；思考：\(preferredThinking)。降级后以实际执行会话为准。")
        })
    }

    private var directorySelector: some View {
        let cwd = owner.cwd.isEmpty ? store.defaultCwd : owner.cwd
        return Button {
            directoryDraft = cwd; focus.borrow("directory", open: expanded); directoryOpen.toggle()
        } label: {
            Label(cwd.isEmpty ? "选择目录" : (cwd as NSString).lastPathComponent, systemImage: "folder")
                .lineLimit(1).truncationMode(.middle)
        }
        .buttonStyle(.plain).frame(maxWidth: 160)
        .help(cwd.isEmpty ? "默认目录尚未读取" : cwd).accessibilityLabel("选择运行目录：\(cwd)")
        .disabled(owner.isSending || owner.unknownID != nil || blockReason != nil)
        .popover(isPresented: $directoryOpen, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                ComposerPopoverHeader(title: "本次消息运行目录") { directoryOpen = false }
                TextField("输入服务端目录路径", text: $directoryDraft).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("本次消息运行目录路径")
                ForEach(recentDirectories.prefix(6)) { item in
                    Button(item.path) { owner.editCwd(item.path); directoryOpen = false }.lineLimit(1).help(item.path)
                }
                Text("只影响之后发送的新工作，不改变已有工作的目录。")
                    .font(.system(size: 12)).foregroundColor(Theme.textSecondary)
                HStack {
                    Button("使用默认目录") { owner.editCwd(store.defaultCwd); directoryOpen = false }
                    Spacer()
                    Button("使用此目录") {
                        owner.editCwd(directoryDraft.trimmingCharacters(in: .whitespacesAndNewlines)); directoryOpen = false
                    }.disabled(directoryDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(16).frame(width: 340)
                .task { recentDirectories = (try? await workspaceAPI?.recentPaths()) ?? [] }
        }
    }

    @ViewBuilder
    private func executionSelectors(_ candidate: EmployeeExecutionCandidate) -> some View {
        Menu {
            ForEach(WandProvider.allCases) { provider in
                Button(provider.title) {
                    store.executionPreference = EmployeeExecutionCandidate(provider: provider.rawValue, engine: "cli", model: "default",
                        kind: "structured", mode: nil, thinkingEffort: "off")
                }
            }
            Button(WandProvider.title(for: "pi", engine: "sdk")) {
                store.executionPreference = EmployeeExecutionCandidate(provider: "pi", engine: "sdk", model: "default",
                    kind: "structured", mode: nil, thinkingEffort: "off")
            }
        } label: { BrandLogo(provider: candidate.provider, color: Theme.textPrimary).frame(width: 16, height: 16) }
            .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("本页执行工具")
        Menu {
            Button("跟随服务端默认") { store.executionPreference = candidate.with(model: "default", thinking: "off") }
            ForEach((store.modelCatalog?.models(for: candidate.provider) ?? []).filter { $0.id != "default" }) { model in
                Button(model.label) { store.executionPreference = candidate.with(model: model.id, thinking: "off") }
            }
        } label: { Text(preferredModel).lineLimit(1).truncationMode(.tail) }
            .menuStyle(.borderlessButton).accessibilityLabel("本页模型")
        Menu {
            Button("自动（模型默认）") { store.executionPreference = candidate.with(thinking: "off") }
            ForEach(thinkingEffortOptions(provider: candidate.provider, selectedModel: candidate.model,
                defaultModel: store.modelCatalog?.defaultModelId(for: candidate.provider),
                models: store.modelCatalog?.models(for: candidate.provider) ?? []).filter { $0.id != "off" }) { effort in
                Button(effort.label) { store.executionPreference = candidate.with(thinking: effort.id) }
            }
        } label: { Text(preferredThinking).lineLimit(1) }
            .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("本页思考深度")
    }
    private func setting(_ label: String, value: String, icon: String) -> some View {
        Button { focus.borrow("settings", open: expanded); settingsOpen = true } label: {
            ComposerSettingLabel(title: value, icon: icon)
        }.buttonStyle(.plain).help("\(label)：\(value)")
            .accessibilityLabel("\(label)：\(value)，首选配置，不代表降级后的实际执行")
    }
    private var menu: some View {
        VStack(alignment: .leading, spacing: 10) {
            ComposerPopoverHeader(title: "对话操作") { menuOpen = false }
            if store.executionPreference != nil && editablePreference {
                Text("临时选择在本页联系人间共用，不改员工默认；只执行所选配置，不自动降级。")
                    .font(.system(size: 12)).foregroundColor(Theme.textSecondary)
                Button("恢复员工默认执行配置") { store.executionPreference = nil; menuOpen = false }
            }
            if conversation.external == nil {
            setting("执行工具", value: candidate?.toolLabel ?? "工具未就绪", icon: "terminal")
            setting("首选模型", value: preferredModel, icon: "cpu")
            setting("权限", value: candidate?.mode.map(composerPermissionLabel) ?? "未取得", icon: "shield")
            setting("思考", value: preferredThinking, icon: "brain")
            } else { Text("钉钉群消息：仅文字；普通发言不派发内部任务。请在钉钉中原生 @已接入员工。")
                .font(.system(size: 12)).foregroundColor(Theme.textSecondary) }
            Divider()
            Button("添加附件") { focus.borrow("files", open: true); menuOpen = false; importFiles = true }.buttonStyle(.bordered).disabled(conversation.external != nil)
            if conversation.isGroup {
                ForEach(conversation.members, id: \.id) { member in
                    Button("@\(member.name)") { owner.edit("@\(member.id) " + owner.text); menuOpen = false; focus.focus() }.buttonStyle(.plain)
                }
            }
            if conversation.external == nil && conversation.isGroup { TextField("工作目录（可选）", text: Binding(get: { owner.cwd }, set: { owner.editCwd($0) })).textFieldStyle(.roundedBorder) }
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
        }.buttonStyle(.bordered).disabled(operation.busy).help(operation.feedback)
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
                    Button("打开对话") { store.select(receipt.conversationId); close() }.buttonStyle(.bordered)
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


struct CapsuleCircleButtonStyle: ButtonStyle {
    var active = false
    func makeBody(configuration: Configuration) -> some View {
        CapsuleCircleButtonBody(configuration: configuration, active: active)
    }
    private struct CapsuleCircleButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let active: Bool
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.colorSchemeContrast) private var contrast

        var body: some View {
            configuration.label
                .background(
                    Circle()
                        .fill(Theme.textPrimary.opacity(
                            isEnabled && configuration.isPressed ? 0.14 : (active ? 0.10 : (isEnabled && hovering ? 0.05 : 0))
                        ))
                )
                .overlay {
                    if active {
                        Circle()
                            .stroke(Theme.wandAccent.opacity(0.45), lineWidth: 1)
                            .allowsHitTesting(false)
                    }
                }
                .contentShape(Circle())
                .foregroundColor(active ? Theme.wandAccent : (hovering ? Theme.textPrimary : Theme.textSecondary))
                .opacity(isEnabled ? 1 : 0.45)
                .onHover { hovering = $0 }
                .wandMotion(value: hovering)
        }
    }
}

/// Three independent facets share the flat list's state owner. Popovers leave the rail anchored.
struct DesktopSidebarCapsules: View {
    @ObservedObject var store: CommunicationsStore
    let groups: [TaskDirectoryGroup]
    @Environment(\.workspaceAPI) private var workspaceAPI
    @State private var addingWorkspace = false
    private enum PickerKind: String { case runtime = "运行状态", workspace = "工作区", employee = "人物" }
    @State private var expanded: PickerKind?
    private var workspaces: [(id: String, label: String)] { ConversationSessionEntry.workspaceOptions(groups) }
    private var employees: [ConversationEmployeeFilterOption] { store.employeeOptions(groups: groups) }
    private var runtimeOptions: [DesktopCapsuleFilterOption] {
        ([ConversationRuntimeFilter.all] + ConversationRuntimeFilter.sidebarChoices).map {
            DesktopCapsuleFilterOption(id: $0.rawValue, label: $0.label, symbol: runtimeSymbol($0))
        }
    }
    private var workspaceOptions: [DesktopCapsuleFilterOption] {
        workspaces.map { DesktopCapsuleFilterOption(id: $0.id, label: $0.label, symbol: $0.id == "all" ? "folder.badge.plus" : "folder") }
    }
    private var employeeOptions: [DesktopCapsuleFilterOption] {
        employees.map { DesktopCapsuleFilterOption(id: $0.id, label: $0.label, symbol: $0.id == "all" ? "person.2" : "person", avatar: $0.id == "all" || $0.id == "none" ? nil : $0.avatar) }
    }
    var body: some View {
        VStack(spacing: 8) {
            capsule(.runtime, options: runtimeOptions)
            capsule(.workspace, options: workspaceOptions)
            capsule(.employee, options: employeeOptions)
        }.padding(.top, 12).padding(.bottom, 8)
        .sheet(isPresented: $addingWorkspace) {
            if let workspaceAPI {
                WorkspaceAddDialog(api: workspaceAPI) { workspace in
                    store.workspaceFilter = "id:" + workspace.id
                    addingWorkspace = false
                    expanded = nil
                }
            }
        }
    }
    private func selected(_ kind: PickerKind) -> [String] {
        switch kind {
        case .runtime: return ConversationRuntimeFilter.sidebarChoices.filter { store.runtimeFilters.contains($0) }.map(\.rawValue)
        case .workspace: return ConversationFilterSelection.values(store.workspaceFilter)
        case .employee: return ConversationFilterSelection.values(store.employeeFilter)
        }
    }
    private func isSelected(_ kind: PickerKind, _ id: String) -> Bool {
        let values = selected(kind)
        return id == "all" ? values.isEmpty : values.contains(id)
    }
    private func toggle(_ kind: PickerKind, _ id: String) {
        switch kind {
        case .runtime: if let value = ConversationRuntimeFilter(rawValue: id) { store.toggleRuntime(value) }
        case .workspace: store.toggleWorkspace(id)
        case .employee: store.toggleEmployee(id)
        }
    }
    private func favorite(_ kind: PickerKind, options: [DesktopCapsuleFilterOption]) -> DesktopCapsuleFilterOption? {
        let remembered: [String]
        switch kind {
        case .runtime: remembered = ConversationRuntimeFilter.sidebarChoices.filter { store.lastCapsuleRuntime.selections.contains($0) }.map(\.rawValue)
        case .workspace: remembered = ConversationFilterSelection.values(store.lastCapsuleWorkspace)
        case .employee: remembered = ConversationFilterSelection.values(store.lastCapsuleEmployee)
        }
        let preferred = selected(kind).first ?? remembered.first
        return options.first { $0.id == preferred && $0.id != "all" }
            ?? options.first { $0.id != "all" && $0.id != "none" }
            ?? options.first { $0.id == "none" }
    }
    private func capsule(_ kind: PickerKind, options: [DesktopCapsuleFilterOption]) -> some View {
        VStack(spacing: 4) {
            Text(kind.rawValue).font(.system(size: 10)).foregroundColor(Theme.textSecondary)
            VStack(spacing: 4) {
                if let all = options.first { optionButton(all, kind: kind) }
                if let preferred = favorite(kind, options: options) {
                    optionButton(preferred, kind: kind)
                        .overlay(alignment: .topTrailing) {
                            if selected(kind).count > 1 {
                                Text("\(selected(kind).count)").font(.system(size: 9, weight: .semibold))
                                    .padding(3).background(Theme.surfaceElevated, in: Circle()).allowsHitTesting(false)
                            }
                        }
                }
                if kind == .workspace {
                    Button { addingWorkspace = true } label: { Image(systemName: "plus").frame(width: 40, height: 40) }
                        .buttonStyle(CapsuleCircleButtonStyle(active: false))
                        .help("添加工作区：填写目录和别名").accessibilityLabel("添加工作区")
                }
                Button { expanded = expanded == kind ? nil : kind } label: {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(expanded == kind ? 90 : 0)).frame(width: 40, height: 24)
                }.buttonStyle(CapsuleCircleButtonStyle(active: expanded == kind))
                    .help("展开\(kind.rawValue)筛选，可多选")
                    .accessibilityLabel("展开\(kind.rawValue)筛选，可多选")
                    .popover(isPresented: Binding(get: { expanded == kind }, set: { if !$0 { expanded = nil } }), arrowEdge: .trailing) {
                        DesktopCapsuleFilterPicker(title: "筛选" + kind.rawValue, options: options,
                            selected: { isSelected(kind, $0) }, toggle: { toggle(kind, $0) }, close: { expanded = nil })
                    }
            }.padding(4).background(Capsule().fill(Theme.surfaceElevated))
                .overlay(Capsule().stroke(Color(nsColor: Theme.borderSubtle), lineWidth: 0.5))
                .onMoveCommand { if $0 == .down { expanded = kind } }
                .onExitCommand { expanded = nil }
        }.wandMotion(value: expanded)
    }
    private func optionButton(_ option: DesktopCapsuleFilterOption, kind: PickerKind) -> some View {
        Button { toggle(kind, option.id) } label: { option.portrait(size: 28).frame(width: 40, height: 40) }
            .buttonStyle(CapsuleCircleButtonStyle(active: isSelected(kind, option.id)))
            .help("筛选\(kind.rawValue)：\(option.label)；可在展开面板中多选")
            .accessibilityLabel("筛选\(kind == .employee ? "员工" : kind.rawValue)：" + option.label)
            .accessibilityAddTraits(isSelected(kind, option.id) ? .isSelected : [])
            .accessibilityAction(named: Text("展开更多选项")) { expanded = kind }
    }
    private func runtimeSymbol(_ value: ConversationRuntimeFilter) -> String {
        switch value {
        case .confirmation: return "exclamationmark.bubble"
        case .running: return "waveform.path.ecg"
        case .queued: return "clock"
        case .idle: return "circle"
        case .finished: return "stop.circle"
        case .failed: return "xmark.circle"
        case .archived: return "archivebox"
        default: return "square.3.layers.3d"
        }
    }
}

private struct DesktopCapsuleFilterOption: Identifiable {
    let id: String
    let label: String
    let symbol: String
    var avatar: String? = nil
    @ViewBuilder func portrait(size: CGFloat) -> some View {
        if let avatar { ContactAvatar(id: id, avatar: avatar, name: label, size: size) }
        else if id.hasPrefix("id:") {
            Image(systemName: symbol).font(.system(size: size * 0.65))
                .overlay(alignment: .bottomTrailing) {
                    Text(String(label.prefix(2)).uppercased()).font(.system(size: 8, weight: .semibold))
                        .padding(.horizontal, 2).background(Theme.surfaceElevated).offset(x: 4, y: 3)
                }
        } else { Image(systemName: symbol).font(.system(size: size * 0.65)) }
    }
}

private struct DesktopCapsuleFilterPicker: View {
    let title: String
    let options: [DesktopCapsuleFilterOption]
    let selected: (String) -> Bool
    let toggle: (String) -> Void
    let close: () -> Void
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ComposerPopoverHeader(title: title, close: close)
            TextField("搜索…", text: $query).textFieldStyle(.roundedBorder).focused($searchFocused)
                .accessibilityLabel(title + "搜索")
            Text("同类可多选；选择全部可清除此类条件。")
                .font(.system(size: 11)).foregroundColor(Theme.textSecondary)
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(options.filter { query.isEmpty || $0.label.localizedStandardContains(query) }) { option in
                        Button { toggle(option.id) } label: {
                            HStack(spacing: 8) {
                                option.portrait(size: 24).frame(width: 28, height: 28)
                                Text(option.label).lineLimit(1)
                                Spacer(minLength: 0)
                                Image(systemName: "checkmark").opacity(selected(option.id) ? 1 : 0)
                            }.padding(6).contentShape(Rectangle())
                        }.buttonStyle(DesktopNavigationButtonStyle(active: selected(option.id)))
                            .accessibilityLabel(option.label).accessibilityValue(selected(option.id) ? "已选择" : "未选择")
                            .accessibilityAddTraits(selected(option.id) ? .isSelected : [])
                    }
                    if !options.contains(where: { query.isEmpty || $0.label.localizedStandardContains(query) }) {
                        Text("没有匹配的选项").foregroundColor(Theme.textSecondary).padding(8)
                    }
                }
            }.frame(maxHeight: 260)
            Button("完成", action: close).frame(maxWidth: .infinity, alignment: .trailing)
        }.font(.system(size: 12)).padding(12).frame(width: 280)
            .onAppear { searchFocused = true }.onExitCommand(perform: close)
    }
}

struct DesktopUnifiedSessionList: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var communications: CommunicationsStore
    let api: WandAPI
    let selectedID: String?
    let selectedConversationID: String?
    let onOpen: (String) -> Void
    let onOpenConversation: (NativeConversation) -> Void
    let onOpenQueuedTask: (String) -> Void
    let onDeleted: (String) -> Void
    @State private var filtersOpen = false
    @State private var queueExpanded = false
    @State private var deleteTarget: WorkspaceSessionSummary?
    @State private var moveTarget: WorkspaceSessionSummary?
    @State private var error: String?
    @State private var busy = false
    @State private var locateID: String?
    private var entries: [ConversationSessionEntry] { ConversationSessionEntry.index(groups: store.conversationTaskGroups) }
    private var rows: [ConversationSessionEntry] { entries.filter { $0.matches(communications.listFilters, query: communications.query) } }
    private var attentionRows: [ConversationSessionEntry] { rows.filter { ConversationRuntimeFilter.attention($0.session) } }
    private var otherRows: [ConversationSessionEntry] { rows.filter { !ConversationRuntimeFilter.attention($0.session) } }
    private var legacyRows: [NativeConversation] {
        let ids = Set(entries.map(\.id))
        return communications.items.filter { item in
            let id = item.communicationSessionId ?? item.sessionId
            return id != nil && !ids.contains(id!) && communications.listFilters.runtimeValues.isEmpty
                && communications.taskStageFilter == .all && communications.listFilters.matchesWorkspace("none")
                && communications.listFilters.matchesEmployee(item.peerEmployeeId) && !item.isArchived && !communications.activityOnly
                && communications.archiveFilter.matches(item.isArchived)
                && TaskListPresentation.searchMatches(communications.query, values: [item.displayTitle, item.preview])
        }
    }
    private var queuedTasks: [(group: TaskDirectoryGroup, task: WorkspaceTaskSummary, count: Int)] {
        let filters = communications.listFilters
        guard (filters.runtimeValues.isEmpty || filters.runtimeValues.contains(.queued)), filters.archive != .archived, filters.matchesEmployee(nil) else { return [] }
        return store.conversationTaskGroups.flatMap { group in
            group.tasks.compactMap { task in
                let count = task.queuedDispatchCount ?? (task.hasQueuedExecution ? task.queuedExecutionCount ?? 0 : 0)
                let workspace = group.userAdded == true && !group.isSynthetic && !group.isGlobal ? "id:" + group.workspaceId : "none"
                guard count > 0, task.archived != true, task.boardTaskId != nil,
                      filters.matchesWorkspace(workspace),
                      filters.taskStage == .all || filters.taskStage.rawValue == task.boardTaskStatus,
                      TaskListPresentation.searchMatches(communications.query, values: [task.name, group.workspaceName]) else { return nil }
                return (group, task, count)
            }
        }
    }
    private var filterSummary: String { communications.filterSummary(groups: store.conversationTaskGroups) }
    var body: some View {
        VStack(spacing: 8) {
            searchBar
            Text(filterSummary).lineLimit(2).help(filterSummary)
                .font(.system(size: 11)).foregroundColor(Theme.textSecondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12)
            Text("\(rows.count + legacyRows.count) 个会话 · \(queuedTasks.reduce(0) { $0 + $1.count }) 条任务派发排队中").font(.system(size: 11)).foregroundColor(Theme.textSecondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12)
            if let selectedID, entries.contains(where: { $0.id == selectedID }), !rows.contains(where: { $0.id == selectedID }) {
                VStack(alignment: .leading) {
                    Text("当前会话不在筛选结果中").font(.system(size: 11))
                    Button("定位当前会话") {
                        if let entry = entries.first(where: { $0.id == selectedID }) { communications.revealSession(entry); locateID = selectedID }
                    }.help("保留匹配当前会话的筛选与搜索，仅解除排除它的条件")
                }.padding(.horizontal, 12)
            }
            if let error = error ?? store.taskGroupsError { Text(error).font(.system(size: 11)).foregroundColor(Theme.danger).padding(.horizontal, 12) }
            sessionList
        }
        .sheet(item: $moveTarget) { DesktopSessionMoveSheet(api: api, store: store, session: $0) }
        .alert("删除会话？", isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })) {
            Button("取消", role: .cancel) { deleteTarget = nil }
            Button("删除", role: .destructive) {
                guard let target = deleteTarget else { return }
                deleteTarget = nil
                Task { do { try await store.deleteSessions([target.id]); onDeleted(target.id) } catch { self.error = error.localizedDescription } }
            }
        } message: { Text("将删除这条会话的消息与执行记录，此操作无法撤销。") }
    }
    private var searchBar: some View {
        HStack {
            TextField("搜索会话", text: $communications.query).textFieldStyle(.roundedBorder).accessibilityLabel("搜索会话")
            if !communications.query.isEmpty { Button { communications.query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).accessibilityLabel("清空搜索") }
            Button { filtersOpen = true } label: { Image(systemName: "line.3.horizontal.decrease").frame(width: 28, height: 28) }
                .buttonStyle(WandIconButtonStyle()).help("更多筛选：任务阶段与查看归档，选择后即时生效，不影响当前会话").accessibilityLabel("更多会话筛选")
                .popover(isPresented: $filtersOpen) {
                    ConversationFilterPanel(store: communications, close: { filtersOpen = false })
                }
        }.padding(.horizontal, 12)
    }

    private var sessionList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 3) {
                    if !queuedTasks.isEmpty {
                        DisclosureGroup(isExpanded: $queueExpanded) {
                        ForEach(queuedTasks, id: \.task.id) { entry in
                            Button { if let id = entry.task.boardTaskId { onOpenQueuedTask(id) } } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "clock").foregroundColor(Theme.textSecondary)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(entry.task.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                        Text("\(entry.group.workspaceName) · \(entry.count) 条派发排队中")
                                            .font(.system(size: 11)).foregroundColor(Theme.textSecondary).lineLimit(1)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }.frame(minHeight: 52).padding(.horizontal, 8)
                            }.buttonStyle(DesktopNavigationButtonStyle(active: false))
                                .help("查看排队任务：" + entry.task.name)
                        }
                        } label: {
                            HStack { Text("排队任务"); Spacer(); Text("\(queuedTasks.count)") }
                                .font(.system(size: 11, weight: .semibold)).foregroundColor(Theme.textSecondary)
                        }.padding(8)
                    }
                    if !attentionRows.isEmpty {
                        HStack { Text("我需要关注"); Spacer(); Text("\(attentionRows.count)") }
                            .font(.system(size: 11, weight: .semibold)).foregroundColor(Theme.textSecondary).padding(8)
                        ForEach(attentionRows) { entry in sessionRow(entry).id(entry.id) }
                        if !otherRows.isEmpty {
                            HStack { Text("其他会话"); Spacer(); Text("\(otherRows.count)") }
                                .font(.system(size: 11, weight: .semibold)).foregroundColor(Theme.textSecondary).padding(8)
                        }
                    }
                    ForEach(otherRows) { entry in sessionRow(entry).id(entry.id) }
                    ForEach(legacyRows) { item in
                        Button { onOpenConversation(item) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.displayTitle).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                Text(item.preview ?? "历史会话").font(.system(size: 11)).foregroundColor(Theme.textSecondary).lineLimit(1)
                            }.frame(maxWidth: .infinity, minHeight: 52, alignment: .leading).padding(.horizontal, 8)
                        }.buttonStyle(DesktopNavigationButtonStyle(active: selectedConversationID == item.id))
                    }
                    if rows.isEmpty && legacyRows.isEmpty && queuedTasks.isEmpty && store.taskGroupsLoaded {
                        Text("没有符合条件的会话").foregroundColor(Theme.textSecondary).padding(12)
                        Button("清除筛选与搜索") { communications.listFilters = ConversationListFilters(); communications.query = "" }
                    }
                    if !store.taskGroupsLoaded { ProgressView().controlSize(.small).padding() }
                }.padding(.horizontal, 8).padding(.bottom, 12)
            }.onChange(of: communications.listFilters.runtime) { runtime in if runtime == .queued { queueExpanded = true } }
            .onChange(of: locateID) { id in if let id { proxy.scrollTo(id, anchor: .center); locateID = nil } }
        }
    }

    private func sessionRow(_ entry: ConversationSessionEntry) -> some View {
        let session = entry.session
        return Button { onOpen(session.id) } label: {
            HStack(spacing: 8) {
                BrandLogo(provider: session.provider ?? "terminal", color: Theme.textSecondary).frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.title ?? session.providerLabel).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text([session.employeeName ?? session.providerLabel, entry.workspaceLabel, ConversationRuntimeFilter.statusLabel(session)].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 11)).foregroundColor(Theme.textSecondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if TaskListPresentation.isActive(session, selectedSessionId: nil) { Image(systemName: "circle.fill").font(.system(size: 6)).foregroundColor(Theme.success).accessibilityLabel("活动会话") }
            }.frame(maxWidth: .infinity, minHeight: 52, alignment: .leading).padding(.horizontal, 8)
        }.buttonStyle(DesktopNavigationButtonStyle(active: selectedID == session.id))
            .help((session.title ?? session.providerLabel) + " · " + entry.caption)
            .contextMenu {
                Button("打开会话") { onOpen(session.id) }
                DesktopCopyWorkingDirectoryButton(cwd: session.cwd)
                if !entry.archived { Button("移动到分区") { moveTarget = session } }
                Button(entry.archived ? "恢复会话" : "归档会话") {
                    Task { do { try await store.archiveSession(session.id, archived: !entry.archived) } catch { self.error = error.localizedDescription } }
                }
                Divider()
                Button("删除会话…", role: .destructive) { deleteTarget = session }
            }
    }
}
