import SwiftUI

@MainActor private enum TaskDispatchDraftCache { static var drafts: [String: String] = [:] }

/**
 * 任务详情：主区（标题 / 描述 / 已指派 Agent / 派发编辑器）+ 右侧属性栏。
 * 交互口径对齐 Web `IssueDetail`：标题失焦保存、属性右栏改完立即写回、派发需要提示词。
 */
struct WandBoardDetailView: View {
    let task: WandBoardTask
    let api: WandAPI?
    @State private var replyCommentId: String?
    @State private var selectedExecutionCommentId: String?
    @State private var commentToReveal: String?
    let initialCommentToReveal: String?
    let onCommentsRevealed: () -> Void
    let allTasks: [WandBoardTask]
    let loadComments: (String, String?, Int) async throws -> WandTaskCommentsPage
    let onOpenTask: ((String) -> Void)?
    let workspaces: [Workspace]
    let milestones: [WandBoardMilestone]
    let catalog: ModelsResponse?
    let busy: Bool
    /// 非空时打开空的指派框。右键「派发」用它，避免把任务描述预填进去。
    let composeToken: UUID?
    let onPatch: ([String: Any]) async -> Void
    let onRemember: (WandBoardTaskAgent) -> Void
    let onCreateChild: () -> Void
    let employees: [EmployeeContact]
    let onDispatchEmployee: ((String, String, WandBoardTaskAgent?) async -> Void)?
    @State private var selectedEmployeeId = ""
    @State private var employeeOverride = false
    @State private var confirmDispatch = false
    @State private var approvedDispatchPrompt = ""
    @State private var approvedConfiguration = ""
    let onDispatch: (String, WandBoardTaskAgent) async -> Void
    let onArchive: () async -> Void
    let onOpenSession: (String) -> Void
    let onCreateMilestone: (String) async throws -> WandBoardMilestone

    @StateObject private var commentsStore = TaskCommentsStore()
    @State private var title: String
    @State private var description: String
    @State private var editingDescription = false
    @State private var submittedDescription: String?
    @State private var agent: WandBoardTaskAgent
    @State private var composeOpen: Bool
    @State private var composePrompt: String
    @FocusState private var focusedField: String?

    init(
        task: WandBoardTask,
        allTasks: [WandBoardTask] = [],
        api: WandAPI? = nil,
        loadComments: @escaping (String, String?, Int) async throws -> WandTaskCommentsPage = { _, _, _ in WandTaskCommentsPage(comments: [], totalCount: 0, nextCursor: nil) },
        onOpenTask: ((String) -> Void)? = nil,
        commentToReveal: String? = nil,
        onCommentsRevealed: @escaping () -> Void = {},
        workspaces: [Workspace],
        milestones: [WandBoardMilestone],
        catalog: ModelsResponse?,
        busy: Bool,
        composeToken: UUID? = nil,
        onPatch: @escaping ([String: Any]) async -> Void,
        onRemember: @escaping (WandBoardTaskAgent) -> Void,
        onCreateChild: @escaping () -> Void = {},
        employees: [EmployeeContact] = [],
        onDispatchEmployee: ((String, String, WandBoardTaskAgent?) async -> Void)? = nil,
        onDispatch: @escaping (String, WandBoardTaskAgent) async -> Void,
        onArchive: @escaping () async -> Void,
        onOpenSession: @escaping (String) -> Void,
        onCreateMilestone: @escaping (String) async throws -> WandBoardMilestone
    ) {
        self.task = task
        self.api = api
        let preferredEmployeeId = employees.first(where: { $0.id == "e_wand_default" && !$0.isArchived })?.id ?? ""
        let initialEmployeeId = task.executionSubject?.type == "employee" ? task.executionSubject?.id ?? "" : (task.agent == nil && task.executionSubject == nil ? preferredEmployeeId : "")
        _selectedEmployeeId = State(initialValue: initialEmployeeId)
        self.allTasks = allTasks
        self.loadComments = loadComments
        self.onOpenTask = onOpenTask
        self.initialCommentToReveal = commentToReveal
        self.onCommentsRevealed = onCommentsRevealed
        _commentToReveal = State(initialValue: commentToReveal)
        self.workspaces = workspaces
        self.milestones = milestones
        self.catalog = catalog
        self.busy = busy
        self.composeToken = composeToken
        self.onPatch = onPatch
        self.onRemember = onRemember
        self.onCreateChild = onCreateChild
        self.employees = employees
        self.onDispatchEmployee = onDispatchEmployee
        self.onDispatch = onDispatch
        self.onArchive = onArchive
        self.onOpenSession = onOpenSession
        self.onCreateMilestone = onCreateMilestone
        _title = State(initialValue: task.title)
        _description = State(initialValue: task.description)
        let initialCandidate = employees.first(where: { $0.id == initialEmployeeId })?.candidates.first?.taskAgent
        _agent = State(initialValue: task.executionSubject?.agentOverride ?? initialCandidate ?? task.agent ?? .default)
        _employeeOverride = State(initialValue: task.executionSubject?.agentOverride != nil)
        _composeOpen = State(initialValue: false)
        _composePrompt = State(initialValue: "")
    }

    private var status: WandBoardStatus { WandBoardStatus(rawValue: task.status) ?? .todo }
    private var taskIdentifierLabel: String {
        let identifier = task.identifier.isEmpty ? String(task.id.prefix(8)) : task.identifier
        return "ID: " + identifier
    }

    private func refreshCommentStatuses() async {
        guard let api else { return }
        await commentsStore.refreshStatuses(taskId: task.id) { taskId, ids in
            try await api.boardTaskCommentStatuses(taskId: taskId, commentIds: ids)
        }
    }

    private var workspaceOptions: [(id: String, name: String)] {
        var options = workspaces.map { (id: $0.id, name: $0.name) }
        if let id = task.workspaceId, let workspace = task.workspace,
           !options.contains(where: { $0.id == id }) {
            options.insert((id: workspace.id, name: "\(workspace.name) · \(workspace.cwd)"), at: 0)
        }
        return options
    }

    private func mainColumn(scrollProxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(taskIdentifierLabel)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(Theme.textTertiary)
                .textSelection(.enabled)
            titleField
            VStack(alignment: .leading, spacing: 6) {
                Text("负责人").font(.caption).foregroundColor(Theme.textSecondary)
                WandBoardAgentChips(assignee: task.assignedExecutor, subject: task.executionSubject, sessions: task.sessions, assigned: task.agent)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("任务负责人")
            descriptionSection
            TaskCommentsSection(
                comments: commentsStore.comments,
                totalCount: commentsStore.totalCount,
                loading: commentsStore.loading,
                loadingOlder: commentsStore.loadingOlder,
                olderPageFailed: commentsStore.olderPageFailed,
                hasOlderPage: commentsStore.hasOlderPage,
                failed: commentsStore.failed,
                retry: { Task { await commentsStore.load(taskId: task.id, fetch: loadComments); await refreshCommentStatuses() } },
                loadOlder: { Task { await commentsStore.loadOlder(taskId: task.id, fetch: loadComments); await refreshCommentStatuses() } },
                onReply: { replyCommentId = $0 },
                onOpenSession: onOpenSession,
                onOpenExecution: { commentId in
                    selectedExecutionCommentId = commentId
                    withAnimation(Theme.Motion.structure) {
                        scrollProxy.scrollTo("execution-\(commentId)", anchor: .center)
                    }
                },
                commentToReveal: commentToReveal,
                onRevealed: { commentToReveal = nil; onCommentsRevealed() },
                onRevealComment: { commentId in
                    withAnimation(Theme.Motion.structure) { scrollProxy.scrollTo("comment-\(commentId)", anchor: .center) }
                    commentToReveal = nil
                    onCommentsRevealed()
                }
            )
            if let api {
                TaskCommentComposer(
                    api: api,
                    taskId: task.id,
                    employees: employees.filter { !$0.isArchived }.map { (id: $0.id, name: $0.name) },
                    sourceCommentId: $replyCommentId
                ) {
                    await commentsStore.load(taskId: task.id, fetch: loadComments)
                }
                .id(task.id)
            }
            taskRelationships
            WandBoardSessionSummaryView(sessions: task.sessions)
                .id("session-summary-\(task.id)")
            WandTaskAcceptanceEditor(
                task: task,
                children: wandBoardChildren(of: task, in: allTasks),
                busy: busy,
                onPatch: onPatch
            )
            .id(task.id)
            WandBoardAgentSessionList(
                assignee: task.assignedExecutor,
                // 评论派发产生的会话也是本任务的真实产物，不能在详情中隐藏。
                sessions: task.sessions,
                assigned: task.agent,
                onOpenSession: onOpenSession,
                catalog: catalog
            )
            composeSection
        }
        .frame(maxWidth: 760, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var body: some View {
        GeometryReader { geometry in
          let compact = geometry.size.width < 820
          let columns = compact ? [GridItem(.flexible(), alignment: .topLeading)] : [GridItem(.flexible(), alignment: .topLeading), GridItem(.fixed(250), alignment: .topLeading)]
          ScrollViewReader { scrollProxy in
          ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 24) {
                mainColumn(scrollProxy: scrollProxy)
                properties
                    .frame(width: compact ? nil : 250)
            }
            .padding(compact ? 16 : 28)
          }
          .onChange(of: selectedExecutionCommentId) { id in
              guard let id else { return }
              withAnimation(Theme.Motion.structure) { scrollProxy.scrollTo("execution-\(id)", anchor: .center) }
          }
          .onChange(of: commentToReveal) { id in
              guard let id else { return }
              withAnimation(Theme.Motion.structure) { scrollProxy.scrollTo("comment-\(id)", anchor: .center) }
          }
        }
        }
        .background(Theme.workspaceBackground)
        .confirmationDialog("确认新建一次执行", isPresented: $confirmDispatch, titleVisibility: .visible) {
            Button("确认派发") {
                let prompt = approvedDispatchPrompt
                if !selectedEmployeeId.isEmpty, let onDispatchEmployee { Task { await onDispatchEmployee(prompt, selectedEmployeeId, employeeOverride ? agent : nil) } }
                else { let sending = agent; Task { await onDispatch(prompt, sending) } }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("\(approvedDispatchPrompt)\n\n执行配置：\(approvedConfiguration)\n沿用现有权限与费用边界；已有会话从原记录精确继续，此处新建执行，不代表验收通过。")
        }
        .task(id: task.id) {
            while !Task.isCancelled {
                await commentsStore.load(taskId: task.id, fetch: loadComments)
                await refreshCommentStatuses()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
        .onChange(of: task.description) { value in
            if !editingDescription || submittedDescription == value {
                description = value
                editingDescription = false
                submittedDescription = nil
            }
        }
        .onChange(of: task.id) { _ in
            selectedEmployeeId = task.executionSubject?.type == "employee" ? task.executionSubject?.id ?? "" : ""
            commentToReveal = initialCommentToReveal
            selectedExecutionCommentId = nil
            title = task.title
            description = task.description
            editingDescription = false
            submittedDescription = nil
            employeeOverride = task.executionSubject?.agentOverride != nil
            agent = task.executionSubject?.agentOverride ?? employees.first(where: { $0.id == selectedEmployeeId })?.candidates.first?.taskAgent ?? task.agent ?? .default
            composeOpen = false
            replyCommentId = nil
            composePrompt = TaskDispatchDraftCache.drafts[task.id] ?? ""
        }
        .onChange(of: composePrompt) { value in TaskDispatchDraftCache.drafts[task.id] = value }
        .onAppear {
            composePrompt = TaskDispatchDraftCache.drafts[task.id] ?? ""
            guard composeToken != nil else { return }
            selectedEmployeeId = ""
            composeOpen = true
        }
        .onChange(of: composeToken) { token in
            guard token != nil else { return }
            selectedEmployeeId = ""
            composeOpen = true
            composePrompt = TaskDispatchDraftCache.drafts[task.id] ?? ""
        }
        .onChange(of: task.sessions.count) { _ in
            // 派发成功后收起编辑器并清空提示词，避免误以为还能再发一次同一段话。
            if !task.sessions.isEmpty {
                composeOpen = false
                composePrompt = ""
            }
        }
    }

    // MARK: 主区

    @ViewBuilder
    private var taskRelationships: some View {
        let parent = wandBoardParent(of: task, in: allTasks)
        let children = wandBoardChildren(of: task, in: allTasks)
        if parent != nil || !children.isEmpty || task.parentTaskId == nil {
            VStack(alignment: .leading, spacing: 8) {
                WandBoardSectionTitle(title: "关联任务", detail: "归类保留原任务及其会话，不删除历史")
                if let parent { relatedTaskRow(parent, caption: "父任务") }
                if task.parentTaskId == nil && task.status != "archived" { Button("添加业务子任务（独立验收）", action: onCreateChild) }
                if !children.isEmpty {
                    Text("\(children.count) 个正式子任务")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Theme.textSecondary)
                    ForEach(children) { child in relatedTaskRow(child, caption: "子任务") }
                }
                let executionComments = commentsStore.comments.filter { $0.dispatch != nil }
                WandBoardSectionTitle(title: "员工执行事项", detail: executionComments.isEmpty ? nil : "\(executionComments.count) 项 · 不计入正式子任务")
                if executionComments.isEmpty {
                    Text(commentsStore.loading ? "正在同步员工执行事项…" : "通过评论中的 @ 选择员工并提交后，执行事项会显示在这里。")
                        .font(.system(size: 12)).foregroundColor(Theme.textSecondary)
                } else {
                    ForEach(executionComments) { comment in
                        TaskCommentExecutionItemRow(
                            comment: comment,
                            api: api,
                            expanded: selectedExecutionCommentId == comment.id,
                            onToggle: { isOpen in selectedExecutionCommentId = isOpen ? comment.id : nil },
                            onOpenComment: { focusedField = nil; commentToReveal = comment.id },
                            onOpenSession: onOpenSession
                        )
                        .id("execution-\(comment.id)")
                    }
                }
            }
            .accessibilityIdentifier("task-relationships")
        }
    }

    private func relatedTaskRow(_ related: WandBoardTask, caption: String) -> some View {
        Button { onOpenTask?(related.id) } label: {
            HStack(spacing: 8) {
                WandBoardStatusGlyph(status: WandBoardStatus(rawValue: related.status) ?? .todo)
                Text(caption).font(.system(size: 11)).foregroundColor(Theme.textSecondary)
                Text(related.identifier).font(.system(size: 10, design: .monospaced)).foregroundColor(Theme.textTertiary)
                Text(related.title).font(.system(size: 12)).foregroundColor(Theme.textPrimary).lineLimit(2)
                Spacer(minLength: 0)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(WandBoardRowButtonStyle())
        .disabled(onOpenTask == nil)
        .help("\(caption)：\(related.title)")
        .accessibilityLabel("\(caption) \(related.identifier) \(related.title)")
    }

    private var titleField: some View {
        TextField("任务标题（留空按描述自动生成）", text: $title)
            .textFieldStyle(.plain)
            .font(.system(size: 20, weight: .semibold))
            .foregroundColor(Theme.textPrimary)
            .focused($focusedField, equals: "title")
            .onSubmit { commitTitle() }
            .onChange(of: focusedField) { next in
                if next != "title" { commitTitle() }
            }
            .disabled(busy)
            .padding(.vertical, 4)
    }

    private func commitTitle() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != task.title else { return }
        Task { await onPatch(["title": trimmed]) }
    }

    private var descriptionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                WandBoardSectionTitle(title: "任务描述")
                Button(editingDescription ? "取消编辑" : "编辑描述") {
                    description = task.description
                    editingDescription.toggle()
                }
                .buttonStyle(WandSecondaryButtonStyle())
                .disabled(busy)
            }
            if editingDescription {
              TextEditor(text: $description)
                .font(.system(size: 13))
                .lineSpacing(4)
                .focused($focusedField, equals: "description")
                .padding(8)
                .frame(minHeight: 90, idealHeight: 120, maxHeight: 200)
                .wandInputSurface(focused: focusedField == "description", cornerRadius: Theme.Radius.control)
                .overlay(alignment: .topLeading) {
                    if description.isEmpty {
                        Text("补充背景、验收标准或复现步骤…")
                            .font(.system(size: 13))
                            .foregroundColor(Theme.textMuted)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 9)
                            .allowsHitTesting(false)
                    }
                }
                .disabled(busy)
                .accessibilityLabel("编辑任务描述")
              HStack {
                  Text("仅保存描述，不会启动执行。")
                      .font(.system(size: 11)).foregroundColor(Theme.textTertiary)
                  Spacer()
                  Button(busy ? "正在保存…" : "保存描述") {
                      let value = description
                      submittedDescription = value
                      if value == task.description { editingDescription = false }
                      else { Task { await onPatch(["description": value]) } }
                  }
                  .buttonStyle(WandPrimaryButtonStyle())
                  .disabled(busy)
              }
            } else {
                Text(task.description.isEmpty ? "暂无描述，可补充背景、验收标准或复现步骤。" : task.description)
                    .font(.system(size: 13)).lineSpacing(4)
                    .foregroundColor(task.description.isEmpty ? Theme.textSecondary : Theme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityLabel("任务描述")
            }
        }
        .wandMotion(value: editingDescription)
        .onChange(of: editingDescription) { editing in
            if editing { focusedField = "description" }
        }
        .onExitCommand {
            guard editingDescription, !busy else { return }
            editingDescription = false
            description = task.description
        }
    }

    private var composeSection: some View {
        Group {
            if composeOpen {
                VStack(alignment: .leading, spacing: 10) {
                    WandBoardSectionTitle(
                        title: "新建并行会话（CLI）",
                        detail: "独立范围才并行；同目录或同文件重叠先串行协调，或隔离后合并。不改变权限、费用与并发配置。"
                    )
                    TextEditor(text: $composePrompt)
                        .font(.system(size: 13))
                        .lineSpacing(4)
                        .focused($focusedField, equals: "compose")
                        .padding(8)
                        .frame(height: 110)
                        .wandInputSurface(
                            focused: focusedField == "compose",
                            cornerRadius: Theme.Radius.control
                        )
                        .overlay(alignment: .topLeading) {
                            if composePrompt.isEmpty {
                                Text("输入本轮执行范围，确认时预览任务快照与主目标约束。")
                                    .font(.system(size: 13))
                                    .foregroundColor(Theme.textMuted)
                                    .padding(.horizontal, 13)
                                    .padding(.vertical, 9)
                                    .allowsHitTesting(false)
                            }
                        }
                        .accessibilityLabel("派发提示词")
                    WandBoardEmployeeAssignment(employees: [], employeeId: $selectedEmployeeId, agent: $agent, overridden: $employeeOverride, catalog: catalog, disabled: busy)
                    HStack(spacing: 8) {
                        Spacer(minLength: 0)
                        if !task.sessions.isEmpty {
                            Button("取消") {
                                composeOpen = false
                                composePrompt = ""
                            }
                            .buttonStyle(WandSecondaryButtonStyle())
                            .disabled(busy)
                        }
                        Button(busy ? "正在派发…" : "派发 Agent") {
                            approvedDispatchPrompt = wandBoardExecutionPrompt(task, parent: wandBoardParent(of: task, in: allTasks), instruction: composePrompt)
                            approvedConfiguration = (employeeOverride ? nil : employees.first(where: { $0.id == selectedEmployeeId })).map { employee in
                                employee.name + "；" + employee.candidates.map { "\($0.toolLabel) · \($0.model ?? "服务默认模型") · \($0.mode ?? "default")" }.joined(separator: "；")
                            } ?? "\(WandProvider.title(for: agent.provider)) · \(agent.model) · \(agent.mode)"
                            confirmDispatch = true
                        }
                        .buttonStyle(WandPrimaryButtonStyle())
                        .disabled(busy || composePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            } else {
                Button {
                    selectedEmployeeId = ""
                    composePrompt = ""
                    composeOpen = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                        Text("新建并行会话（CLI）").font(.system(size: 12))
                    }
                    .foregroundColor(Theme.textSecondary)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                            .fill(Theme.surface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                            .strokeBorder(Theme.border, lineWidth: 1)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(busy)
            }
        }
    }

    // MARK: 属性栏

    private var properties: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("属性")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Theme.textPrimary)

            WandBoardField("状态") {
                Picker("", selection: Binding(
                    get: { task.status },
                    set: { value in Task { await onPatch(["status": value]) } }
                )) {
                    ForEach(WandBoardStatus.allCases) { item in
                        Text(item.label).tag(item.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .disabled(busy)
            }

            WandBoardField("优先级") {
                Picker("", selection: Binding(
                    get: { task.priority },
                    set: { value in Task { await onPatch(["priority": value]) } }
                )) {
                    ForEach(WandBoardPriority.allCases) { item in
                        Text(item.label).tag(item.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .disabled(busy)
            }

            WandBoardField("项目目录") {
                Picker("", selection: Binding(
                    get: { task.workspaceId ?? "" },
                    set: { value in
                        Task { await onPatch(["workspaceId": value.isEmpty ? NSNull() : value]) }
                    }
                )) {
                    Text("不指定项目（使用全局目录）").tag("")
                    ForEach(workspaceOptions, id: \.id) { option in
                        Text(option.name).tag(option.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .disabled(busy)
            }

            WandBoardField("归属父任务") {
                WandBoardParentPicker(tasks: allTasks, workspaceId: task.workspaceId, childId: task.id,
                    value: task.parentTaskId, disabled: busy) { value in
                    Task { await onPatch(["parentTaskId": value.map { $0 as Any } ?? NSNull()]) }
                }
            }

            WandBoardField("里程碑") {
                WandBoardMilestonePicker(
                    value: task.milestoneId,
                    workspaceId: task.workspaceId,
                    milestones: milestones,
                    disabled: busy,
                    onChange: { milestoneId in
                        Task { await onPatch(["milestoneId": milestoneId ?? NSNull()]) }
                    },
                    onCreate: onCreateMilestone
                )
            }

            WandBoardField("截止日期") {
                WandBoardDueDateField(value: task.dueDate, disabled: busy) { value in
                    Task { await onPatch(["dueDate": value ?? NSNull()]) }
                }
            }

            WandBoardField("标签") {
                VStack(alignment: .leading, spacing: 6) {
                    WandBoardLabelsField(labels: task.labels, disabled: busy) { labels in
                        Task { await onPatch(["labels": labels]) }
                    }
                    if !task.labels.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(Array(task.labels.enumerated()), id: \.offset) { _, label in
                                WandBoardLabelChip(label: label)
                            }
                        }
                    }
                }
            }

            Divider().overlay(Theme.border)

            Button {
                Task { await onArchive() }
            } label: {
                Text(status == .archived ? "已归档" : "归档")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.danger)
                    .frame(maxWidth: .infinity)
                    .frame(height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                            .fill(Theme.surface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                            .strokeBorder(Theme.danger.opacity(0.35), lineWidth: 1)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(busy || status == .archived)
            .help("归档后侧栏隐藏，终端与执行记录保留")

            Text("创建 \(wandBoardFormatStamp(task.createdAt)) · 更新 \(wandBoardFormatStamp(task.updatedAt))")
                .font(.system(size: 11))
                .foregroundColor(Theme.textMuted)
        }
        .font(.system(size: 12))
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                .fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                .strokeBorder(Color(nsColor: Theme.borderSubtle), lineWidth: 1)
        )
    }
}
