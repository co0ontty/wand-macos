import SwiftUI

/**
 * 任务看板共用的选择器：里程碑（迭代）下拉、Agent 参数网格、截止日期、标签。
 * 新建面板与任务详情共用同一批零件，保证两处行为一致。
 */

// MARK: - 任务归类

@MainActor
final class WandTaskOrganizationAction: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var result: WandTaskOrganizationResult?
    @Published private(set) var error: String?
    @Published private(set) var preview: WandConversationOrganizationPreview?
    @Published private(set) var job: WandConversationOrganizationJob?
    @Published private(set) var note = ""
    private var revision = 0
    private var work: Task<Void, Never>?
    @Published private(set) var submittedToken: String?
    private var cancelling = false
    var unresolved: Bool { submittedToken != nil || job?.status == "running" }
    var hasState: Bool { busy || unresolved || preview != nil || result != nil || error != nil || !note.isEmpty }

    var label: String { busy ? "正在整理会话" : preview != nil ? "确认会话范围" : error != nil ? "归类未完成" : job?.status == "running" ? "后台归类中" : result != nil ? "会话归类结果" : "会话自动归类" }

    func reset() {
        guard !unresolved else {
            note = "前一次范围仍在后台整理或等待回执；请查询原作业，切换目录不会重新发送。"
            return
        }
        revision += 1
        result = nil; error = nil; preview = nil; job = nil; note = ""
    }

    func prepare(api: WandAPI, target: WandTaskOrganizationTarget, mode: WandTaskOrganizationMode, onChanged: @escaping () async -> Void) {
        guard !busy, !unresolved else { return }
        work = Task { await run(api: api, target: target, mode: mode, onChanged: onChanged) }
    }

    func run(api: WandAPI, target: WandTaskOrganizationTarget, mode: WandTaskOrganizationMode, onChanged: () async -> Void) async {
        guard !busy, !unresolved else { return }
        reset(); busy = true; let started = revision
        note = "读取会话正文并估算处理量；尚未调用模型。"
        defer { busy = false }
        do {
            let response = try await api.prepareConversationOrganization(target: target, mode: mode)
            guard started == revision else { return }
            if let id = response.activeJobId {
                let accepted = try await api.conversationOrganizationJob(id: id)
                note = "本范围已有作业，继续查询；不会重复模型请求。"
                try await watch(api: api, accepted: accepted, started: started, onChanged: onChanged)
            } else if response.sessionCount == 0 {
                note = "没有符合范围且有正文的工作会话；跳过 \(response.manualSessionCount) 个人工任务会话，排除 \(response.skippedSessionCount) 个归档/私聊/系统或无正文会话。"
            } else {
                preview = response
                note = "正文 \(response.contentCharacters) 字符，预计 \(response.estimatedModelRequests) 个系统模型请求，使用初二当前配置及原有候选降级；另排除 \(response.skippedSessionCount) 个归档/私聊/系统记录或无正文会话。确认后可自动创建/复用任务并移动会话，不执行其中的工作。"
            }
        } catch {
            guard started == revision else { return }
            if Task.isCancelled { note = "已停止前端查询，后台作业不会因此取消。" }
            else { self.error = error.localizedDescription }
        }
    }

    func confirm(api: WandAPI, onChanged: @escaping () async -> Void) {
        guard !busy, !unresolved, let prepared = preview else { return }
        submittedToken = prepared.token
        busy = true; error = nil; let started = revision
        work = Task {
            defer { busy = false }
            do {
                let accepted = try await api.startConversationOrganization(token: prepared.token, force: prepared.unchanged)
                if started == revision { job = accepted; preview = nil }
                try await watch(api: api, accepted: accepted, started: started, onChanged: onChanged)
            } catch {
                guard started == revision else { return }
                if Task.isCancelled { note = "已停止前端查询，后台可能仍在执行；可查询同一作业或确认请求，不会新建重复请求。" }
                else { self.error = error.localizedDescription }
            }
        }
    }

    func query(api: WandAPI, onChanged: @escaping () async -> Void) {
        guard !busy, job != nil || submittedToken != nil else { return }
        let current = job, token = submittedToken
        busy = true; error = nil; let started = revision
        work = Task {
            defer { busy = false }
            do {
                let original: WandConversationOrganizationJob
                if let current { original = try await api.conversationOrganizationJob(id: current.id) }
                else if let token { original = try await api.conversationOrganizationJobByToken(token) }
                else { return }
                try await watch(api: api, accepted: original, started: started, onChanged: onChanged)
            }
            catch { if !Task.isCancelled && started == revision { self.error = error.localizedDescription } }
        }
    }

    private func watch(api: WandAPI, accepted: WandConversationOrganizationJob, started: Int, onChanged: () async -> Void) async throws {
        var current = accepted
        var polls = 0
        while true {
            try Task.checkCancellation()
            if started == revision { job = current; note = current.stage }
            if current.status != "running" { break }
            guard polls < 900 else {
                if started == revision { error = "前端查询已暂停；后台仍在执行，可继续查询原作业。" }
                return
            }
            polls += 1
            try await Task.sleep(nanoseconds: 800_000_000)
            current = try await api.conversationOrganizationJob(id: current.id)
        }
        submittedToken = nil
        await onChanged()
        guard started == revision else { return }
        result = current.result; job = current
        error = current.status == "failed" || current.status == "interrupted" ? current.error ?? "归类未完成，请查看结果或初二日志。" : nil
    }

    func cancel(api: WandAPI) {
        guard let current = job, current.status == "running", !cancelling else { return }
        cancelling = true
        Task {
            defer { cancelling = false }
            do { try await api.cancelConversationOrganization(id: current.id) }
            catch { self.error = "取消回执未确认，请继续查询原作业；已完成部分不会回滚。" }
        }
    }
    func stopWatching() { work?.cancel(); work = nil }
    func reportError(_ message: String) { error = message }
    func waitForBackgroundWorkForTesting() async { await work?.value }
}

struct WandTaskOrganizationPanel: View {
    let api: WandAPI
    let target: WandTaskOrganizationTarget
    @ObservedObject var action: WandTaskOrganizationAction
    var initialMode: WandTaskOrganizationMode? = nil
    var onOpenSession: ((String) -> Void)? = nil
    let onChanged: () async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("会话自动归类").font(.system(size: 12, weight: .semibold))
            ForEach(WandTaskOrganizationMode.allCases) { mode in
                Button {
                    action.prepare(api: api, target: target, mode: mode, onChanged: onChanged)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(mode.label).font(.system(size: 12, weight: .medium))
                        Text(mode.hint).font(.system(size: 11)).foregroundColor(Theme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(WandSecondaryButtonStyle())
                .disabled(action.busy || action.unresolved)
            }
            confirmationButton
            if action.busy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(action.job.map { "\(action.note)（\($0.processedSessions)/\($0.totalSessions)，模型请求 \($0.modelRequests)）" } ?? action.note).font(.system(size: 12))
                }
                .accessibilityIdentifier("task-organization-progress")
            }
            if let prepared = action.preview, !action.unresolved {
                Text("\(prepared.sessionCount) 个工作会话；跳过 \(prepared.manualSessionCount) 个人工任务会话。\(action.note)")
                    .font(.system(size: 11)).foregroundColor(Theme.textSecondary)
            } else if !action.busy && action.result == nil && !action.note.isEmpty {
                Text(action.note).font(.system(size: 11)).foregroundColor(Theme.textSecondary)
            }
            if let result = action.result {
                VStack(alignment: .leading, spacing: 5) {
                    Text(result.label).font(.system(size: 12, weight: .medium))
                    if !result.detail.isEmpty {
                        Text(result.detail).font(.system(size: 11)).foregroundColor(Theme.textSecondary)
                    }
                }
                .accessibilityIdentifier("task-organization-result")
            }
            if let error = action.error {
                Text(error).font(.system(size: 12)).foregroundColor(Theme.danger)
                    .accessibilityIdentifier("task-organization-error")
            }
            if let job = action.job {
                if job.status == "running" {
                    Button("取消后续归类，保留已完成部分") { action.cancel(api: api) }.buttonStyle(WandSecondaryButtonStyle())
                }
                if let id = job.logSessionId, let onOpenSession {
                    Button("查看初二的本次作业日志") { onOpenSession(id) }.buttonStyle(WandSecondaryButtonStyle())
                }
            }
            Text("关闭面板只停止查看，后台继续；不会中断原工作会话。")
                .font(.system(size: 10)).foregroundColor(Theme.textMuted)
        }
        .foregroundColor(Theme.textPrimary)
        .padding(12)
        .frame(width: 300, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .onDisappear { action.stopWatching() }
        .task {
            if let initialMode {
                await action.run(api: api, target: target, mode: initialMode, onChanged: onChanged)
            }
        }
    }

    private var confirmationButton: some View {
        let title = action.busy ? "正在整理会话…"
            : action.unresolved ? (action.job == nil ? "查询原确认请求" : "继续查询本次作业")
            : action.preview.map { $0.unchanged ? "内容未变，确认重新分析" : "确认整理 \($0.sessionCount) 个会话" }
                ?? (action.result != nil ? "查看本次结果" : "先选择会话范围")
        return Button {
            if action.unresolved || action.result != nil { action.query(api: api, onChanged: onChanged) }
            else { action.confirm(api: api, onChanged: onChanged) }
        } label: {
            ZStack {
                Text(title).font(.system(size: 12, weight: .medium))
                    .id(title).transition(.opacity)
            }
            .frame(width: 220, height: 18)
        }
        .buttonStyle(WandPrimaryButtonStyle())
        .disabled(action.busy || (!action.unresolved && action.preview == nil && action.result == nil))
        .accessibilityIdentifier("task-organization-primary")
        .wandMotion(value: title)
    }
}

struct WandTaskOrganizationButton: View {
    let api: WandAPI
    let target: WandTaskOrganizationTarget
    var onOpenSession: ((String) -> Void)? = nil
    let onChanged: () async -> Void
    @StateObject private var action = WandTaskOrganizationAction()
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            Label(action.label, systemImage: "folder")
                .font(.system(size: 12))
                .frame(width: 112)
        }
        .buttonStyle(WandSecondaryButtonStyle())
        .accessibilityLabel("会话自动归类")
        .help("按真实会话正文自动创建/复用任务，确认后后台整理；默认不挪人工任务会话")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            WandTaskOrganizationPanel(api: api, target: target, action: action, onOpenSession: onOpenSession, onChanged: onChanged)
        }
        .onChange(of: target) { _ in action.reset() }
    }
}

// MARK: - 里程碑（迭代）

/**
 * 里程碑选择器：下拉里选历史迭代，或就地新增一个。
 * 传了 `workspaceId` 就只展示该工作区的迭代（含全局的），新增的也归属该工作区。
 */
struct WandBoardMilestonePicker: View {
    let value: String?
    let workspaceId: String?
    let milestones: [WandBoardMilestone]
    var disabled = false
    let onChange: (String?) -> Void
    /// 新增成功后返回服务端条目；失败时抛错，错误就地展示不下传。
    let onCreate: (String) async throws -> WandBoardMilestone

    @State private var open = false
    @State private var creating = false
    @State private var name = ""
    @State private var busy = false
    @State private var errorMessage = ""
    @FocusState private var nameFocused: Bool

    private var items: [WandBoardMilestone] {
        milestones.filter { $0.isVisible(for: workspaceId) }
    }

    private var selected: WandBoardMilestone? {
        guard let value, !value.isEmpty else { return nil }
        return items.first { $0.id == value }
    }

    private var scoped: Bool {
        !(workspaceId ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Button {
            guard !disabled else { return }
            open = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "flag")
                    .font(.system(size: 11))
                    .foregroundColor(selected == nil ? Theme.textMuted : Theme.wandAccent)
                Text(selected?.name ?? "里程碑")
                    .font(.system(size: 12))
                    .foregroundColor(selected == nil ? Theme.textMuted : Theme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(Theme.textMuted)
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .frame(maxWidth: .infinity, alignment: .leading)
            .wandInputSurface(focused: false, cornerRadius: Theme.Radius.control)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.55 : 1)
        .help(selected.map { "里程碑：\($0.name)" } ?? "里程碑")
        .accessibilityLabel(selected.map { "里程碑：\($0.name)" } ?? "里程碑")
        .popover(isPresented: $open, arrowEdge: .bottom) { menu }
    }

    private var menu: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("里程碑")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                Spacer(minLength: 0)
                if let selected {
                    Button(selected.isDefault ? "回到默认" : "清除") {
                        onChange(nil)
                        closeMenu()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textSecondary)
                }
            }
            if creating {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("里程碑名称，例如：v5.0 发布", text: $name)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .focused($nameFocused)
                        .padding(.horizontal, 8)
                        .frame(height: 26)
                        .wandInputSurface(focused: nameFocused, cornerRadius: Theme.Radius.control)
                        .onSubmit { Task { await submit() } }
                        .disabled(busy)
                    HStack(spacing: 8) {
                        Spacer(minLength: 0)
                        Button("取消") {
                            creating = false
                            errorMessage = ""
                        }
                        .buttonStyle(WandSecondaryButtonStyle())
                        .disabled(busy)
                        Button(busy ? "新增中…" : "新增") {
                            Task { await submit() }
                        }
                        .buttonStyle(WandPrimaryButtonStyle())
                        .disabled(busy || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    if !errorMessage.isEmpty {
                        Text(errorMessage)
                            .font(.system(size: 11))
                            .foregroundColor(Theme.danger)
                    }
                }
            } else {
                if items.isEmpty {
                    Text(scoped ? "这个工作区还没有迭代，新增一个吧。" : "还没有里程碑，新增一个吧。")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(items) { item in
                                Button {
                                    onChange(item.id)
                                    closeMenu()
                                } label: {
                                    HStack(spacing: 7) {
                                        Image(systemName: "flag")
                                            .font(.system(size: 11))
                                            .foregroundColor(item.id == value ? Theme.wandAccent : Theme.textMuted)
                                        Text(item.name)
                                            .font(.system(size: 12))
                                            .foregroundColor(Theme.textPrimary)
                                            .lineLimit(1)
                                        if item.isDefault {
                                            WandBoardMiniTag("默认")
                                        } else if scoped && item.workspaceId == nil {
                                            WandBoardMiniTag("全局")
                                        }
                                        Spacer(minLength: 6)
                                        if item.taskCount > 0 {
                                            Text("\(item.taskCount)")
                                                .font(.system(size: 11, design: .monospaced))
                                                .foregroundColor(Theme.textMuted)
                                        }
                                    }
                                    .padding(.horizontal, 8)
                                    .frame(height: 28)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(
                                        RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                                            .fill(item.id == value ? Color(nsColor: Theme.wandAccentMuted) : Color.clear)
                                    )
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(maxHeight: 220)
                }
                Button {
                    creating = true
                    errorMessage = ""
                    DispatchQueue.main.async { nameFocused = true }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                        Text("新增里程碑").font(.system(size: 12))
                        Spacer(minLength: 0)
                    }
                    .foregroundColor(Theme.wandAccent)
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .frame(width: 270)
        .background(Theme.surfaceElevated)
    }

    private func closeMenu() {
        open = false
        creating = false
        name = ""
        errorMessage = ""
    }

    private func submit() async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !busy else { return }
        busy = true
        errorMessage = ""
        do {
            let created = try await onCreate(trimmed)
            onChange(created.id)
            closeMenu()
        } catch {
            errorMessage = error.localizedDescription
        }
        busy = false
    }
}

/// 下拉里的小标记（默认 / 全局）。
struct WandBoardMiniTag: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundColor(Theme.textMuted)
            .padding(.horizontal, 5)
            .frame(height: 16)
            .background(Capsule().fill(Theme.surface))
            .overlay(Capsule().strokeBorder(Color(nsColor: Theme.borderSubtle), lineWidth: 0.5))
    }
}

// MARK: - Agent 参数

/// CLI 工具 / 模型 / 思考深度 / 工作模式四件套；新建与详情共用。
struct WandBoardAgentEditor: View {
    @Binding var agent: WandBoardTaskAgent
    let catalog: ModelsResponse?
    var disabled = false
    /// 每次改动用它把选择记进全局默认（下次新建沿用）。
    var onChange: (WandBoardTaskAgent) -> Void = { _ in }

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
            alignment: .leading,
            spacing: 10
        ) {
            WandBoardField("执行工具") {
                Picker("", selection: toolBinding) {
                    Text("Wand Agent").tag("wand-agent")
                    ForEach(wandBoardProviders, id: \.self) { provider in
                        Text(wandBoardProviderLabel(provider)).tag(provider)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            WandBoardField("模型") {
                Picker("", selection: modelBinding) {
                    ForEach(wandBoardModelOptions(from: catalog, provider: agent.provider), id: \.id) { option in
                        Text(option.label).tag(option.id)
                    }
                    if !wandBoardModelOptions(from: catalog, provider: agent.provider).contains(where: { $0.id == agent.model }) {
                        Text("\(agent.model)（已保存）").tag(agent.model)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            WandBoardField("思考深度") {
                Picker("", selection: effortBinding) {
                    ForEach(wandBoardEfforts, id: \.self) { effort in
                        Text(wandBoardEffortLabel(effort)).tag(effort)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            WandBoardField("工作模式") {
                Picker("", selection: modeBinding) {
                    ForEach(WandBoardAgentMode.supported(provider: agent.provider)) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
        }
        .disabled(disabled)
        .font(.system(size: 12))
    }

    private var toolBinding: Binding<String> {
        Binding(get: { agent.provider == "pi" && agent.engine == "sdk" ? "wand-agent" : agent.provider }, set: { tool in
            if tool == "wand-agent" {
                var next = agent.withProvider("pi"); next.engine = "sdk"; next.kind = "structured"; agent = next; onChange(next)
            } else {
                providerBinding.wrappedValue = tool
                agent.engine = nil
                onChange(agent)
            }
        })
    }

    private var providerBinding: Binding<String> {
        Binding(
            get: { agent.provider },
            set: { provider in
                var next = agent.withProvider(provider)
                let options = wandBoardModelOptions(from: catalog, provider: provider)
                if !options.contains(where: { $0.id == next.model }) {
                    next.model = options.first?.id ?? "default"
                }
                agent = next
                onChange(next)
            }
        )
    }

    private var modelBinding: Binding<String> {
        Binding(
            get: { agent.model },
            set: { value in
                agent.model = value
                onChange(agent)
            }
        )
    }

    private var effortBinding: Binding<String> {
        Binding(
            get: { agent.thinkingEffort },
            set: { value in
                agent.thinkingEffort = value
                onChange(agent)
            }
        )
    }

    private var modeBinding: Binding<String> {
        Binding(
            get: { agent.mode },
            set: { value in
                agent.mode = WandBoardAgentMode.normalize(provider: agent.provider, value: value)
                onChange(agent)
            }
        )
    }
}

// MARK: - 截止日期

/// 截止日期：未设置时是一个按钮，设置后可改可清空。
struct WandBoardDueDateField: View {
    let value: String?
    var disabled = false
    let onChange: (String?) -> Void

    var body: some View {
        HStack(spacing: 6) {
            if let day = wandBoardDay(fromDueDate: value ?? "") {
                DatePicker(
                    "",
                    selection: Binding(get: { day }, set: { onChange(wandBoardIsoDate($0)) }),
                    displayedComponents: .date
                )
                .labelsHidden()
                .datePickerStyle(.compact)
                Button {
                    onChange(nil)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textMuted)
                }
                .buttonStyle(.plain)
                .help("清除截止日期")
                .accessibilityLabel("清除截止日期")
            } else {
                Button("未设置") {
                    onChange(wandBoardIsoDate(Date()))
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(Theme.textMuted)
                .frame(height: 26)
                .help("设置截止日期")
            }
        }
        .disabled(disabled)
    }
}

// MARK: - 标签

/// 标签输入：逗号（中英文均可）分隔，失焦或回车提交。
struct WandBoardLabelsField: View {
    let labels: [String]
    var disabled = false
    let onChange: ([String]) -> Void

    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("用逗号分隔", text: $draft)
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .focused($focused)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .wandInputSurface(focused: focused, cornerRadius: Theme.Radius.control)
            .onSubmit { commit() }
            .onChange(of: focused) { isFocused in
                if !isFocused { commit() }
            }
            .disabled(disabled)
            .onAppear { draft = labels.joined(separator: ", ") }
            .onChange(of: labels) { next in
                // 服务端回写后同步一次，但不要打断正在输入的用户。
                if !focused { draft = next.joined(separator: ", ") }
            }
            .accessibilityLabel("任务标签")
    }

    private func commit() {
        let parsed = draft
            .split(whereSeparator: { $0 == "," || $0 == "，" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard parsed != labels else { return }
        onChange(parsed)
    }
}

/// Shared planning/reassignment picker. Native popover owns focus and Escape dismissal.
struct WandBoardParentPicker: View {
    let tasks: [WandBoardTask]
    let workspaceId: String?
    var childId: String? = nil
    let value: String?
    var disabled = false
    let onChange: (String?) -> Void
    @State private var open = false
    @State private var query = ""

    private var candidates: [WandBoardTask] {
        tasks.filter { $0.workspaceId == workspaceId && (query.isEmpty || "\($0.identifier) \($0.title)".localizedCaseInsensitiveContains(query)) }
    }
    var body: some View {
        Button { query = ""; open = true } label: {
            Text(tasks.first { $0.id == value }.map { "\($0.identifier) · \($0.title)" } ?? "无父任务")
                .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
        }
        .disabled(disabled)
        .accessibilityLabel("归属父任务")
        .popover(isPresented: $open) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField("搜索主任务编号或标题", text: $query)
                    if !query.isEmpty { Button("清除搜索") { query = "" } }
                }
                Text("同项目未归档主任务均可规划归属；保存不启动执行。")
                    .font(.caption).foregroundColor(Theme.textSecondary)
                Button("无父任务") { onChange(nil); open = false }
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(candidates) { candidate in
                            let reason = wandBoardParentRejection(candidate, tasks: tasks, workspaceId: workspaceId, childId: childId, currentParentId: value)
                            Button { onChange(candidate.id); open = false } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("\(candidate.identifier) · \(candidate.title)")
                                    Text("\(WandBoardStatus(rawValue: candidate.status)?.label ?? candidate.status) · \(wandBoardChildren(of: candidate, in: tasks).count) 个子任务 · \(candidate.sessions.count) 个会话")
                                        .font(.caption).foregroundColor(Theme.textSecondary)
                                    if let reason { Text("不可选：\(reason)").font(.caption).foregroundColor(Theme.textSecondary) }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.disabled(reason != nil)
                        }
                        if candidates.isEmpty { Text("没有匹配的同项目任务，请检查编号、标题或项目目录。") }
                    }
                }.frame(maxHeight: 320)
            }.padding(16).frame(width: 360)
        }
    }
}


/// Task-scoped drafts: dismissing the popover never changes the employee definition.
struct WandBoardEmployeeAssignment: View {
    let employees: [EmployeeContact]
    @Binding var employeeId: String
    @Binding var agent: WandBoardTaskAgent
    @Binding var overridden: Bool
    let catalog: ModelsResponse?
    var disabled = false
    @State private var editing = false
    @State private var pending = WandBoardTaskAgent.default
    @State private var advanced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("指派员工", selection: $employeeId) {
                Text("选择员工").tag("")
                ForEach(employees.filter { !$0.isArchived }) { employee in Text(employee.name).tag(employee.id) }
            }
            .onChange(of: employeeId) { id in
                overridden = false
                if let first = employees.first(where: { $0.id == id })?.candidates.first { agent = first.taskAgent }
            }
            if let employee = employees.first(where: { $0.id == employeeId }) {
                HStack(spacing: 8) {
                    ContactAvatar(id: employee.id, avatar: employee.avatar ?? "", name: employee.name, size: 28)
                    Text(employee.name).fontWeight(.semibold)
                }
                Button { pending = agent; editing = true } label: {
                    Text("\(wandBoardProviderLabel(agent.provider, engine: agent.engine)) · \(wandBoardAgentSummary(agent, catalog))").font(.caption)
                }
                .popover(isPresented: $editing) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("本次任务的工具设置").font(.headline)
                        Text("仅影响本次执行，不改员工默认配置；覆盖后只使用所选配置。").font(.caption)
                        WandBoardAgentEditor(agent: $pending, catalog: catalog)
                        HStack { Button("取消") { editing = false }; Spacer(); Button("应用到本次") { agent = pending; overridden = true; editing = false } }
                    }.padding(16).frame(width: 420)
                }
                if overridden { Button("恢复员工默认") { if let first = employee.candidates.first { agent = first.taskAgent }; overridden = false } }
                Text(overridden ? "已覆盖本次配置" : "按员工已配置候选顺序执行").font(.caption).foregroundColor(Theme.textSecondary)
            }
            DisclosureGroup("高级选项 · 直接指派工具", isExpanded: $advanced) {
                VStack(alignment: .leading, spacing: 8) {
                    Button("改为直接工具指派") { employeeId = ""; overridden = false }
                    if employeeId.isEmpty { WandBoardAgentEditor(agent: $agent, catalog: catalog) }
                }.padding(.top, 8)
            }
        }.disabled(disabled)
    }
}
