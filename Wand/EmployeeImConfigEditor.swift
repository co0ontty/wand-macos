import SwiftUI

extension WandAPI {
    func employeeImConfig(id: String) async throws -> EmployeeImConfig {
        try await request(EmployeeImConfig.self, method: "GET", path: "/api/silicon-employees/\(percentEncodePathComponent(id))/im")
    }
    @discardableResult
    func saveEmployeeImConfig(id: String, events: [String], telegram: [String: Any], dingtalk: [String: Any]) async throws -> EmployeeImConfig {
        try await request(EmployeeImConfig.self, method: "PUT", path: "/api/silicon-employees/\(percentEncodePathComponent(id))/im", body: ["events": events, "telegram": telegram, "dingtalk": dingtalk])
    }
    func testEmployeeIm(id: String, provider: String) async throws -> EmployeeImTestResult {
        try await request(EmployeeImTestResult.self, method: "POST", path: "/api/silicon-employees/\(percentEncodePathComponent(id))/im/test", body: ["provider": provider])
    }
}

struct EmployeeImConfigEditor: View {
    let api: WandAPI
    let employeeID: String
    let onNeedsAdmin: () -> Void
    var onDirtyChange: (Bool) -> Void = { _ in }
    var onBusyChange: (Bool) -> Void = { _ in }
    @State private var events: [String] = []
    @State private var savedEvents: [String] = []
    @State private var telegram = EmployeeImChannelDraft()
    @State private var dingtalk = EmployeeImChannelDraft()
    @State private var savedTelegram = EmployeeImChannelDraft()
    @State private var savedDingtalk = EmployeeImChannelDraft()
    @State private var loading = true
    @State private var loaded = false
    @State private var saving = false
    @State private var testing: String?
    @State private var message: String?
    @State private var testMessages: [String: String] = [:]
    @State private var error: String?
    @State private var expanded: Set<String> = []
    private var dirty: Bool { events != savedEvents || telegram != savedTelegram || dingtalk != savedDingtalk }
    private var busy: Bool { saving || testing != nil }
    private var selectedCount: Int { events.count }
    private var moreSelected: Int { events.filter { !employeeImPrimaryEvents.contains($0) }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Text("IM 通知").font(.system(size: 16, weight: .semibold))
                Spacer(minLength: 8)
                Button("撤销") {
                    events = savedEvents; telegram = savedTelegram; dingtalk = savedDingtalk
                    error = nil; message = nil; expanded = []
                }.buttonStyle(WandSecondaryButtonStyle()).disabled(busy || !dirty)
                Button { Task { await save() } } label: {
                    Text(saving ? "保存中…" : message == "已保存" ? "已保存" : error != nil ? "保存失败" : "保存")
                        .frame(width: 112, height: 20)
                }.buttonStyle(WandPrimaryButtonStyle()).disabled(loading || busy || !dirty).accessibilityLabel("保存通知设置")
            }
            Text("所选节点会发送到所有已开启的渠道。")
                .font(.system(size: 12)).foregroundColor(Theme.textSecondary)
            if let error {
                Text(error).font(.system(size: 12)).foregroundColor(Theme.danger)
                if !loaded { Button("重新读取") { Task { await load() } }.buttonStyle(WandSecondaryButtonStyle()).disabled(loading) }
            }
            if loading { ProgressView("正在读取通知设置…") }
            if loaded {
                EmployeeImDestination(provider: "telegram", title: "Telegram", draft: $telegram,
                    expanded: expansion("telegram"), busy: busy,
                    isTesting: testing == "telegram", feedback: testMessages["telegram"],
                    testDisabled: dirty || busy || !savedTelegram.botTokenConfigured || savedTelegram.chatId.isEmpty,
                    onTest: { Task { await test("telegram") } })
                Divider()
                EmployeeImDestination(provider: "dingtalk", title: "钉钉", draft: $dingtalk,
                    expanded: expansion("dingtalk"), busy: busy,
                    isTesting: testing == "dingtalk", feedback: testMessages["dingtalk"],
                    testDisabled: dirty || busy || !savedDingtalk.webhookConfigured,
                    onTest: { Task { await test("dingtalk") } })
                Divider()
                subheading("通知节点", detail: selectedCount == 0 ? "未选择" : "已选 \(selectedCount) 项")
                eventOptions
                Text("仅发送状态摘要，不包含对话正文。")
                    .font(.system(size: 12)).foregroundColor(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 8)
        .accessibilityIdentifier("employee-im-editor-\(employeeID)")
        .wandMotion(value: expanded, layout: true)
        .onChange(of: dirty) { value in onDirtyChange(value); if value { message = nil } }
        .onChange(of: busy) { value in onBusyChange(value) }
        .onDisappear { onBusyChange(false) }
        .onExitCommand(perform: expanded.isEmpty || busy ? nil : { expanded = [] })
        .task { await load() }
    }

    private func subheading(_ title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 8)
            Text(detail).font(.system(size: 12)).foregroundColor(Theme.textSecondary)
        }
    }
    private var eventOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            eventGrid(employeeImPrimaryEvents)
            DisclosureGroup(isExpanded: expansion("events")) {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(employeeImMoreEventGroups, id: \.label) { group in
                        Text(group.label).font(.system(size: 12)).foregroundColor(Theme.textSecondary)
                        eventGrid(group.events)
                    }
                }.padding(.top, 8)
            } label: {
                HStack {
                    Text("更多节点")
                    Spacer()
                    if moreSelected > 0 { Text("\(moreSelected) 项已选").foregroundColor(Theme.textSecondary) }
                }.font(.system(size: 12))
            }
        }.disabled(busy).accessibilityIdentifier("employee-im-common-events")
    }
    private func eventGrid(_ values: [String]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), alignment: .leading)], alignment: .leading, spacing: 0) {
            ForEach(values, id: \.self) { event in
                Toggle(employeeImEvents.first { $0.value == event }?.label ?? event, isOn: Binding(
                    get: { events.contains(event) },
                    set: { selected in
                        if selected { if !events.contains(event) { events.append(event) } }
                        else { events.removeAll { $0 == event } }
                    }
                )).toggleStyle(.checkbox).frame(minHeight: 44)
            }
        }
    }
    private func expansion(_ provider: String) -> Binding<Bool> {
        Binding(get: { expanded.contains(provider) }, set: { value in
            if value { expanded.insert(provider) } else { expanded.remove(provider) }
        })
    }
    private func load() async {
        loading = true; error = nil
        defer { loading = false }
        do {
            let config = try await api.employeeImConfig(id: employeeID)
            guard !Task.isCancelled else { return }
            events = config.events; savedEvents = events
            telegram = EmployeeImChannelDraft(channel: config.telegram); dingtalk = EmployeeImChannelDraft(channel: config.dingtalk)
            savedTelegram = telegram; savedDingtalk = dingtalk; loaded = true
        } catch {
            guard !Task.isCancelled else { return }
            self.error = errorMessage(error); if isAdminError(error) { onNeedsAdmin() }
        }
    }
    private func save() async {
        guard !busy, !loading, loaded, dirty else { return }
        if telegram.enabled && (telegram.chatId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || telegram.clearBotToken || (!telegram.botTokenConfigured && telegram.botToken.isEmpty)) {
            expanded.insert("telegram"); error = "启用 Telegram 前，请补齐 Bot Token 和 Chat ID。"; return
        }
        if dingtalk.enabled && (dingtalk.clearWebhook || (!dingtalk.webhookConfigured && dingtalk.webhook.isEmpty)) {
            expanded.insert("dingtalk"); error = "启用钉钉前，请填写机器人 Webhook。"; return
        }
        saving = true; error = nil; message = nil
        defer { saving = false }
        do {
            let response = try await api.saveEmployeeImConfig(id: employeeID, events: events,
                telegram: makeImChannelInput(enabled: telegram.enabled, chatId: telegram.chatId,
                    botToken: telegram.botToken, clearBotToken: telegram.clearBotToken, webhook: nil, clearWebhook: false, secret: nil, clearSecret: false),
                dingtalk: makeImChannelInput(enabled: dingtalk.enabled, chatId: nil,
                    botToken: nil, clearBotToken: false, webhook: dingtalk.webhook, clearWebhook: dingtalk.clearWebhook, secret: dingtalk.secret, clearSecret: dingtalk.clearSecret))
            events = response.events; savedEvents = events
            telegram = EmployeeImChannelDraft(channel: response.telegram); dingtalk = EmployeeImChannelDraft(channel: response.dingtalk)
            savedTelegram = telegram; savedDingtalk = dingtalk; message = "已保存"
        } catch { self.error = errorMessage(error); if isAdminError(error) { onNeedsAdmin() } }
    }
    private func test(_ provider: String) async {
        guard !busy, !loading, loaded, !dirty else { return }
        testing = provider; testMessages[provider] = nil
        defer { testing = nil }
        do {
            let response = try await api.testEmployeeIm(id: employeeID, provider: provider)
            testMessages[provider] = response.ok ? "测试成功" : "发送未确认"
        } catch { testMessages[provider] = "发送未确认"; self.error = errorMessage(error); if isAdminError(error) { onNeedsAdmin() } }
    }
    private func isAdminError(_ error: Error) -> Bool {
        guard let error = error as? WandAPI.APIError else { return false }
        if case .server(status: 403, message: _) = error { return true }; return false
    }
    private func errorMessage(_ error: Error) -> String {
        isAdminError(error) ? "需要管理员登录后才能配置通知。草稿已保留。" : error.localizedDescription
    }
}

/// Destinations hold only addressing/credentials. Selected events are shared by every enabled channel.
private struct EmployeeImDestination: View {
    let provider: String
    let title: String
    @Binding var draft: EmployeeImChannelDraft
    @Binding var expanded: Bool
    let busy: Bool
    let isTesting: Bool
    let feedback: String?
    let testDisabled: Bool
    let onTest: () -> Void
    private var ready: Bool {
        provider == "telegram" ? !draft.chatId.isEmpty && !draft.clearBotToken && (draft.botTokenConfigured || !draft.botToken.isEmpty)
            : !draft.clearWebhook && (draft.webhookConfigured || !draft.webhook.isEmpty)
    }
    private var summary: String {
        if provider == "telegram" { return ready ? "接收目标 \(draft.chatId)" : "未配置" }
        return draft.clearWebhook ? "保存后清除机器人" : !draft.webhook.isEmpty ? "新机器人待保存" : draft.webhookConfigured ? "群机器人已配置" : "未配置"
    }
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 12) {
                if provider == "telegram" {
                    secretField("Bot Token", text: $draft.botToken, configured: draft.botTokenConfigured, clear: $draft.clearBotToken)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Chat ID").font(.system(size: 12)).foregroundColor(Theme.textSecondary)
                        TextField("用户、群聊 ID 或 @频道名", text: $draft.chatId).textFieldStyle(.roundedBorder)
                    }
                } else {
                    secretField("Webhook", text: $draft.webhook, configured: draft.webhookConfigured, clear: $draft.clearWebhook)
                    secretField("签名 Secret（可选）", text: $draft.secret, configured: draft.secretConfigured, clear: $draft.clearSecret)
                }
                Text(provider == "telegram" ? "私聊请先向机器人发送 /start。" : "使用自定义机器人 Webhook；开启加签时填写 Secret。")
                    .font(.system(size: 12)).foregroundColor(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Button(action: onTest) {
                        Text(isTesting ? "发送中…" : feedback == "测试成功" ? "已发送" : feedback != nil ? "发送未确认" : "发送测试消息").frame(width: 112, height: 20)
                    }.buttonStyle(WandSecondaryButtonStyle()).disabled(testDisabled).accessibilityLabel("发送\(title)测试消息")
                    Text(testDisabled ? "配置并保存后可测试" : "").font(.system(size: 12)).foregroundColor(Theme.textSecondary)
                }
            }.padding(.vertical, 12)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 14, weight: .medium))
                    Text(summary).font(.system(size: 12)).foregroundColor(Theme.textSecondary).lineLimit(1).help(summary)
                }
                Spacer(minLength: 8)
                Toggle("启用 \(title) 通知", isOn: $draft.enabled).toggleStyle(.switch).labelsHidden()
            }.padding(.vertical, 4)
        }
        .disabled(busy)
        .onChange(of: draft.enabled) { value in if value && !ready { expanded = true } }
        .accessibilityIdentifier("employee-im-channel-\(provider)")
    }
    private func secretField(_ label: String, text: Binding<String>, configured: Bool, clear: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 12)).foregroundColor(Theme.textSecondary)
            HStack(spacing: 8) {
                SecureField(configured ? "已配置，留空保持不变" : label, text: text).textFieldStyle(.roundedBorder).disabled(clear.wrappedValue)
                if configured {
                    Toggle("清除", isOn: clear).toggleStyle(.checkbox).help("保存后清除该凭据；启用时先关闭渠道")
                }
            }
        }
    }
}
