import SwiftUI

/// 新建工作页的任务属性；字段与 Web `IssueDraft` 对齐。
struct WandBoardDraft {
    var employeeId = ""
    var employeeOverride = false
    var saveAndDispatch = false
    var parentTaskId: String? = nil
    var title = ""
    var description = ""
    var status = WandBoardStatus.todo.rawValue
    /// 与 Web `DEFAULT_WAND_TASK_PRIORITY` 一致：没挑优先级时默认「低」，不落成「无优先级」。
    var priority = WandBoardPriority.low.rawValue
    var workspaceId = ""
    var dueDate = ""
    var milestoneId = ""
    var labels = ""
    var agent = WandBoardTaskAgent.default

    var parsedLabels: [String] {
        labels
            .split(whereSeparator: { $0 == "," || $0 == "，" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var isEmpty: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}


/// Context only: opening a creation page never creates a task or starts execution.
struct WandTaskPlanningContext: Hashable {
    var workspaceId = ""
    var status = WandBoardStatus.backlog.rawValue
    var parentTaskId: String? = nil
}

@MainActor
final class WandTaskPlanningDraft: ObservableObject {
    @Published var draft = WandBoardDraft()
    @Published var workspaces: [Workspace] = []
    @Published var milestones: [WandBoardMilestone] = []
    @Published var employees: [EmployeeContact] = []
    @Published var tasks: [WandBoardTask] = []
    @Published var catalog: ModelsResponse?
    @Published var loading = true
    @Published var loadError: String?
    @Published private(set) var creating = false
    @Published private(set) var unconfirmed = false
    @Published private(set) var createdTask: WandBoardTask?
    @Published private(set) var errorMessage: String?
    @Published var directory: String
    @Published var createMore = false
    private var initialized = false

    init(context: WandTaskPlanningContext, cwd: String = "") {
        directory = cwd
        draft.workspaceId = context.workspaceId
        draft.status = context.status
        draft.parentTaskId = context.parentTaskId
    }

    func prepare(cwd: String, employeeId: String?) {
        guard !initialized else { return }
        if directory.isEmpty, draft.workspaceId.isEmpty { directory = cwd }
        if draft.employeeId.isEmpty { draft.employeeId = employeeId ?? "" }
    }

    func load(api: WandAPI) async {
        guard !initialized else { return }
        initialized = true
        loading = true
        loadError = nil
        defer { loading = false }
        do {
            async let workspaceChoices = api.listWorkspaces()
            async let taskChoices = api.listBoardTasks()
            async let employeeChoices = api.employeeContacts()
            async let milestoneChoices = api.listBoardMilestones()
            async let modelChoices = api.models()
            async let defaults = api.boardTaskAgentDefaults()
            let values = try await (workspaceChoices, taskChoices, employeeChoices, milestoneChoices, modelChoices, defaults)
            workspaces = values.0; tasks = values.1; employees = values.2
            if draft.workspaceId.isEmpty, !directory.isEmpty,
               let matching = workspaces.first(where: { ($0.cwd as NSString).standardizingPath == (directory as NSString).standardizingPath }) {
                draft.workspaceId = matching.id
            }
            milestones = values.3; catalog = values.4
            draft.agent = values.5
            if let employee = employees.first(where: { $0.id == draft.employeeId && !$0.isArchived })
                ?? employees.first(where: { $0.id == "e_wand_default" && !$0.isArchived })
                ?? employees.first(where: { !$0.isArchived }) {
                draft.employeeId = employee.id
                draft.agent = employee.candidates.first?.taskAgent ?? values.5
            }
        } catch {
            loadError = error.localizedDescription
            initialized = false
        }
    }

    func canSubmit(text: String, title: String, execute: Bool) -> Bool {
        !loading && loadError == nil && !creating && !unconfirmed && createdTask == nil
            && (!title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            && (!execute || (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draft.status != WandBoardStatus.backlog.rawValue))
    }

    func submit(text: String, title: String, execute: Bool, api: WandAPI) async -> WandBoardTask? {
        guard canSubmit(text: text, title: title, execute: execute) else { return nil }
        var submitted = draft
        submitted.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        submitted.description = text.trimmingCharacters(in: .whitespacesAndNewlines)
        creating = true
        errorMessage = nil
        defer { creating = false }
        do {
            let path = directory.trimmingCharacters(in: .whitespacesAndNewlines)
            if submitted.workspaceId.isEmpty, !path.isEmpty {
                let workspace = try await api.createWorkspace(name: (path as NSString).lastPathComponent,
                    cwd: path, defaultProvider: nil)
                // Keep this receipt when task creation is rejected; a retry must reuse the workspace.
                draft.workspaceId = workspace.id
                submitted.workspaceId = workspace.id
                workspaces.append(workspace)
            }
            let task = try await api.createBoardTask(
                title: submitted.title, description: submitted.description, status: submitted.status,
                priority: submitted.priority, labels: submitted.parsedLabels,
                dueDate: submitted.dueDate.isEmpty ? nil : submitted.dueDate,
                milestoneId: submitted.milestoneId.isEmpty ? nil : submitted.milestoneId,
                workspaceId: submitted.workspaceId.isEmpty ? nil : submitted.workspaceId,
                agent: submitted.agent, parentTaskId: submitted.parentTaskId,
                employeeId: submitted.employeeId.isEmpty ? nil : submitted.employeeId,
                employeeOverride: submitted.employeeOverride
            )
            createdTask = task
            NotificationCenter.default.post(name: .wandRefreshLists, object: nil)
            if execute {
                do {
                    _ = try await api.dispatchBoardTask(id: task.id, agent: submitted.agent,
                        prompt: wandBoardExecutionPrompt(task, parent: tasks.first { $0.id == submitted.parentTaskId }, instruction: submitted.description),
                        workspaceId: submitted.workspaceId.isEmpty ? nil : submitted.workspaceId,
                        employeeId: submitted.employeeId.isEmpty ? nil : submitted.employeeId,
                        employeeOverride: submitted.employeeOverride)
                } catch {
                    errorMessage = "任务已创建。" + (SessionCreationDraft.deliveryIsUncertain(error)
                        ? "执行结果未确认，请打开任务核对，不要重复派发。"
                        : "执行未启动，可从任务详情重试。") + " " + error.localizedDescription
                }
            }
            return task
        } catch {
            unconfirmed = SessionCreationDraft.deliveryIsUncertain(error)
            errorMessage = unconfirmed ? "创建结果未确认，请先核对任务列表，不要重复提交。 " + error.localizedDescription : error.localizedDescription
            return nil
        }
    }

    func allowRetryAfterReview() {
        guard unconfirmed, !creating else { return }
        unconfirmed = false
        errorMessage = nil
    }

    func startAnother() {
        guard createdTask != nil, !creating else { return }
        draft = wandBoardDraftAfterCreateMore(draft)
        createdTask = nil
        errorMessage = nil
    }

    func createMilestone(_ name: String, api: WandAPI) async throws -> WandBoardMilestone {
        let milestone = try await api.createBoardMilestone(name: name, workspaceId: draft.workspaceId.isEmpty ? nil : draft.workspaceId)
        milestones.append(milestone)
        return milestone
    }
}

/// Planning and execution use the same page, native editor and submit preference.
struct WandBoardCreateView: View {
    let api: WandAPI
    @ObservedObject var owner: WandTaskPlanningDraft
    @Binding var text: String
    @Binding var title: String
    @Binding var kind: NewSessionView.SessionType
    @Binding var composerFocused: Bool
    let onCreated: (WandBoardTask) -> Void
    @State private var composerHeight: CGFloat = 72
    @State private var composing = false
    @State private var showProperties = false
    @State private var showDirectoryOptions = false
    @State private var showAssignment = false
    @State private var confirmUnknownRetry = false
    @AppStorage("wand.sendWithCommandEnter") private var sendWithCommandEnter = false

    var body: some View {
        NewWorkPage { width in
            NewWorkInvitation(width: width) {
                invitationEmployee
            } directory: {
                invitationDirectory
            } task: {
                invitationTask
            }
            .disabled(owner.loading || owner.creating || owner.createdTask != nil || owner.unconfirmed)
        } content: { width in
            VStack(spacing: 12) {
                if let error = owner.loadError {
                    Text(error).foregroundColor(Theme.danger)
                    Button("重试加载") { Task { await owner.load(api: api) } }
                }
                if let error = owner.errorMessage {
                    Text(error).foregroundColor(Theme.danger).font(.system(size: 12))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if owner.unconfirmed {
                    Button("核对列表后允许重试") { confirmUnknownRetry = true }
                        .buttonStyle(WandSecondaryButtonStyle())
                }
                if let created = owner.createdTask {
                    HStack {
                        Text("任务已创建").foregroundColor(Theme.success)
                        Spacer()
                        Button("查看任务") { onCreated(created) }.buttonStyle(WandPrimaryButtonStyle())
                        Button("再建一个") { owner.startAnother(); text = ""; title = ""; composerFocused = true }
                            .buttonStyle(WandSecondaryButtonStyle())
                    }
                }
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Button { showDirectoryOptions.toggle() } label: {
                            Label(owner.workspaces.first { $0.id == owner.draft.workspaceId }?.name
                                ?? (owner.directory.isEmpty ? "全局目录" : (owner.directory as NSString).lastPathComponent), systemImage: "folder")
                                .lineLimit(1).frame(height: 32)
                        }.buttonStyle(DesktopNavigationButtonStyle()).accessibilityLabel("目录与任务属性")
                        Spacer(minLength: 0)
                        Button { showAssignment.toggle() } label: {
                            Label(owner.employees.first { $0.id == owner.draft.employeeId }?.name ?? "执行对象", systemImage: "person.crop.circle")
                                .lineLimit(1).frame(height: 32)
                        }.buttonStyle(DesktopNavigationButtonStyle()).accessibilityLabel("执行对象")
                        Menu {
                            Button("任务属性") { showProperties.toggle() }
                            Picker("工作类型", selection: $kind) {
                                ForEach(NewSessionView.SessionType.allCases) { Text($0.label).tag($0) }
                            }
                        } label: { Image(systemName: "gearshape").frame(width: 28, height: 32) }
                            .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("新工作设置")
                    }.font(.system(size: 12)).foregroundColor(Theme.textSecondary).padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Theme.surfaceSoft, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    if let parent = owner.tasks.first(where: { $0.id == owner.draft.parentTaskId }) {
                        DisclosureGroup("主目标 \(parent.identifier) · \(parent.title)") { Text(parent.description).textSelection(.enabled) }
                            .font(.system(size: 12)).padding(12)
                    }
                    IMEAwareComposerTextView(text: $text, placeholder: "随心输入，描述你想完成的事…",
                        isFocused: composerFocused, sendWithCommandEnter: sendWithCommandEnter,
                        onFocusChange: { composerFocused = $0 }, onCompositionChange: { composing = $0 },
                        onSubmit: { submit(execute: owner.draft.saveAndDispatch) },
                        onHeightChange: { composerHeight = $0 }, submitActionName: owner.draft.saveAndDispatch ? "创建并开始执行" : "仅创建任务")
                        .frame(height: max(48, min(220, composerHeight)))
                        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
                        .accessibilityIdentifier("new-work-description")
                    footer(compact: width < 600)
                        .padding(.horizontal, 12).padding(.bottom, 12)
                }
                .wandInputSurface(focused: composerFocused, cornerRadius: 24)
                .disabled(owner.loading || owner.creating || owner.createdTask != nil || owner.unconfirmed)
                if owner.loading { ProgressView("正在读取工作配置…").controlSize(.small) }
            }
        }
        .task { await owner.load(api: api) }
        .onChange(of: owner.draft.status) { status in
            if status == WandBoardStatus.backlog.rawValue { owner.draft.saveAndDispatch = false }
        }
        .confirmationDialog("已核对没有新任务？", isPresented: $confirmUnknownRetry) {
            Button("允许重新创建", role: .destructive) { owner.allowRetryAfterReview() }
            Button("取消", role: .cancel) {}
        } message: { Text("原请求可能已经成功。请先核对任务列表；确认未创建后才解除门禁，不会自动重发。") }
    }

    private var invitationEmployee: some View {
        Button { showAssignment.toggle() } label: {
            HStack(spacing: 4) {
                if let employee = owner.employees.first(where: { $0.id == owner.draft.employeeId }) {
                    WorkingAvatar(id: employee.id, name: employee.name, avatar: employee.avatar ?? "", size: 28)
                } else { Image(systemName: "sparkles").frame(width: 28, height: 28) }
                Image(systemName: "chevron.down").font(.system(size: 10)).foregroundColor(Theme.textSecondary)
            }
        }
        .buttonStyle(.plain)
        .help(owner.employees.first { $0.id == owner.draft.employeeId }?.name ?? "选择员工")
        .accessibilityLabel("新任务员工")
        .accessibilityIdentifier("new-work-invitation-employee")
        .popover(isPresented: $showAssignment, arrowEdge: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ComposerPopoverHeader(title: "执行对象") { showAssignment = false }
                    assign
                }.padding(16)
            }.frame(width: 420).frame(maxHeight: 540)
                .font(.system(size: 13)).multilineTextAlignment(.leading)
        }
    }

    private var projectName: String {
        owner.workspaces.first { $0.id == owner.draft.workspaceId }?.name
            ?? (owner.directory.isEmpty ? "Wand" : (owner.directory as NSString).lastPathComponent)
    }

    private var invitationDirectory: some View {
        Button { showDirectoryOptions.toggle() } label: {
            HStack(spacing: 4) {
                Text(projectName).underline(true, color: Theme.border)
                Image(systemName: "chevron.down").font(.system(size: 10)).foregroundColor(Theme.textSecondary)
            }
        }
        .buttonStyle(.plain).help(owner.directory.isEmpty ? "选择工作目录" : owner.directory)
        .accessibilityLabel("新任务目录")
        .accessibilityIdentifier("new-work-invitation-directory")
        .popover(isPresented: $showDirectoryOptions, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                ComposerPopoverHeader(title: "工作目录") { showDirectoryOptions = false }
                directoryField
            }.padding(16).frame(width: 360)
                .font(.system(size: 13)).multilineTextAlignment(.leading)
        }
    }

    private var invitationTask: some View {
        let taskLabel = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "新任务" : title
        return Button { showProperties.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: "square.stack").font(.system(size: 11)).foregroundColor(Theme.textSecondary)
                Text(taskLabel).underline(true, color: Theme.border).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 10)).foregroundColor(Theme.textSecondary)
            }
        }
        .buttonStyle(.plain).help("任务：" + taskLabel)
        .accessibilityLabel("新任务标题与属性")
        .accessibilityIdentifier("new-work-invitation-task")
        .popover(isPresented: $showProperties, arrowEdge: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ComposerPopoverHeader(title: "任务属性") { showProperties = false }
                    WandBoardField("任务标题 可选") {
                        TextField("留空按描述生成", text: $title)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("new-work-task-title")
                    }
                    properties
                    WandBoardField("归属父任务") {
                        WandBoardParentPicker(tasks: owner.tasks,
                            workspaceId: owner.draft.workspaceId.isEmpty ? nil : owner.draft.workspaceId,
                            value: owner.draft.parentTaskId, disabled: owner.creating) { owner.draft.parentTaskId = $0 }
                    }
                    Toggle("创建后继续添加", isOn: $owner.createMore)
                        .toggleStyle(.checkbox).font(.system(size: 12))
                }.padding(16)
            }.frame(width: 420).frame(maxHeight: 540)
                .font(.system(size: 13)).multilineTextAlignment(.leading)
        }
    }

    private var directoryField: some View {
                WandBoardField("项目目录") {
                    Picker("", selection: $owner.draft.workspaceId) {
                        Text("不指定目录（使用全局目录）").tag("")
                        ForEach(owner.workspaces) { workspace in
                            Text(workspace.name).tag(workspace.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .onChange(of: owner.draft.workspaceId) { id in
                        owner.directory = owner.workspaces.first { $0.id == id }?.cwd ?? ""
                    }
                    if owner.draft.workspaceId.isEmpty {
                        TextField("工作目录（留空使用全局目录）", text: $owner.directory)
                            .textFieldStyle(.roundedBorder)
                    }
                }
    }

    private var properties: some View {
        VStack(alignment: .leading, spacing: 10) {
            WandBoardSectionTitle(title: "任务属性")
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                alignment: .leading,
                spacing: 10
            ) {
                directoryField
                WandBoardField("状态") {
                    Picker("", selection: $owner.draft.status) {
                        ForEach(WandBoardStatus.activeColumns) { item in
                            Text(item.label).tag(item.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                WandBoardField("优先级") {
                    Picker("", selection: $owner.draft.priority) {
                        ForEach(WandBoardPriority.allCases) { item in
                            Text(item.label).tag(item.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                WandBoardField("截止日期") {
                    WandBoardDueDateField(value: owner.draft.dueDate.isEmpty ? nil : owner.draft.dueDate) { value in
                        owner.draft.dueDate = value ?? ""
                    }
                }
                WandBoardField("里程碑") {
                    WandBoardMilestonePicker(
                        value: owner.draft.milestoneId.isEmpty ? nil : owner.draft.milestoneId,
                        workspaceId: owner.draft.workspaceId,
                        milestones: owner.milestones,
                        onChange: { owner.draft.milestoneId = $0 ?? "" },
                        onCreate: { try await owner.createMilestone($0, api: api) }
                    )
                }
                WandBoardField("标签") {
                    WandBoardLabelsField(labels: owner.draft.parsedLabels) { labels in
                        owner.draft.labels = labels.joined(separator: ", ")
                    }
                }
            }
        }
    }

    private var assign: some View {
        VStack(alignment: .leading, spacing: 10) {
            WandBoardSectionTitle(
                title: owner.draft.saveAndDispatch ? "第一次指派" : "执行员工",
                detail: owner.draft.saveAndDispatch
                    ? (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "有描述时会立刻发给所选 Agent" : "补上描述才会立刻派发")
                    : "仅保存任务的指派计划，不修改员工默认配置"
            )
            WandBoardEmployeeAssignment(employees: owner.employees, employeeId: $owner.draft.employeeId, agent: $owner.draft.agent, overridden: $owner.draft.employeeOverride, catalog: owner.catalog)
        }
    }


    @ViewBuilder
    private func footer(compact: Bool) -> some View {
        if compact {
            VStack(alignment: .leading, spacing: 10) { keyboardAction; submissionButtons }
        } else {
            HStack(spacing: 10) { keyboardAction; Spacer(minLength: 0); submissionButtons }
        }
    }

    private var keyboardAction: some View {
        Toggle(sendWithCommandEnter ? "⌘↵ 创建并执行" : "↵ 创建并执行", isOn: $owner.draft.saveAndDispatch)
            .toggleStyle(.checkbox).font(.system(size: 12))
            .disabled(owner.draft.status == WandBoardStatus.backlog.rawValue)
    }

    private var submissionButtons: some View {
        HStack(spacing: 8) {
            Button(owner.creating ? "创建中…" : "仅创建任务") { submit(execute: false) }
                .buttonStyle(WandSecondaryButtonStyle())
                .disabled(composing || !owner.canSubmit(text: text, title: title, execute: false))
            Button("创建并开始执行") { submit(execute: true) }
                .buttonStyle(WandPrimaryButtonStyle())
                .disabled(composing || !owner.canSubmit(text: text, title: title, execute: true))
                .help(owner.draft.status == WandBoardStatus.backlog.rawValue ? "待立项只保存；请先将任务状态改为等待认领或处理中。" : "创建任务并使用当前执行对象开始工作")
        }
    }

    private func submit(execute: Bool) {
        guard !composing else { return }
        Task {
            guard let created = await owner.submit(text: text, title: title, execute: execute, api: api) else { return }
            guard owner.errorMessage == nil else { return }
            if owner.createMore {
                owner.startAnother(); text = ""; title = ""; composerFocused = true
            } else { onCreated(created) }
        }
    }
}
