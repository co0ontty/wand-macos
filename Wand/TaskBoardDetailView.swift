import SwiftUI

/**
 * 任务详情：主区（标题 / 描述 / 已指派 Agent / 派发编辑器）+ 右侧属性栏。
 * 交互口径对齐 Web `IssueDetail`：标题失焦保存、属性右栏改完立即写回、派发需要提示词。
 */
struct WandBoardDetailView: View {
    let task: WandBoardTask
    let workspaces: [Workspace]
    let milestones: [WandBoardMilestone]
    let catalog: ModelsResponse?
    let busy: Bool
    let onPatch: ([String: Any]) async -> Void
    let onRemember: (WandBoardTaskAgent) -> Void
    let onDispatch: (String, WandBoardTaskAgent) async -> Void
    let onArchive: () async -> Void
    let onOpenSession: (String) -> Void
    let onCreateMilestone: (String) async throws -> WandBoardMilestone

    @State private var title: String
    @State private var description: String
    @State private var savedDescription: String
    @State private var agent: WandBoardTaskAgent
    @State private var composeOpen: Bool
    @State private var composePrompt: String
    @FocusState private var focusedField: String?

    init(
        task: WandBoardTask,
        workspaces: [Workspace],
        milestones: [WandBoardMilestone],
        catalog: ModelsResponse?,
        busy: Bool,
        onPatch: @escaping ([String: Any]) async -> Void,
        onRemember: @escaping (WandBoardTaskAgent) -> Void,
        onDispatch: @escaping (String, WandBoardTaskAgent) async -> Void,
        onArchive: @escaping () async -> Void,
        onOpenSession: @escaping (String) -> Void,
        onCreateMilestone: @escaping (String) async throws -> WandBoardMilestone
    ) {
        self.task = task
        self.workspaces = workspaces
        self.milestones = milestones
        self.catalog = catalog
        self.busy = busy
        self.onPatch = onPatch
        self.onRemember = onRemember
        self.onDispatch = onDispatch
        self.onArchive = onArchive
        self.onOpenSession = onOpenSession
        self.onCreateMilestone = onCreateMilestone
        _title = State(initialValue: task.title)
        _description = State(initialValue: task.description)
        _savedDescription = State(initialValue: task.description)
        _agent = State(initialValue: task.agent ?? .default)
        let assigned = !task.sessions.isEmpty
        _composeOpen = State(initialValue: !assigned)
        _composePrompt = State(initialValue: assigned ? "" : task.description)
    }

    private var status: WandBoardStatus { WandBoardStatus(rawValue: task.status) ?? .todo }

    private var workspaceOptions: [(id: String, name: String)] {
        var options = workspaces.map { (id: $0.id, name: $0.name) }
        if let id = task.workspaceId, let workspace = task.workspace,
           !options.contains(where: { $0.id == id }) {
            options.insert((id: workspace.id, name: "\(workspace.name) · \(workspace.cwd)"), at: 0)
        }
        return options
    }

    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 18) {
                    Text("ID: \(task.identifier.isEmpty ? String(task.id.prefix(8)) : task.identifier)")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(Theme.textTertiary)
                        .textSelection(.enabled)
                    titleField
                    descriptionSection
                    WandBoardAgentSessionList(
                        sessions: task.sessions,
                        assigned: task.agent,
                        onOpenSession: onOpenSession
                    )
                    composeSection
                }
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                properties
                    .frame(width: 250)
            }
            .padding(28)
        }
        .background(Theme.workspaceBackground)
        .onChange(of: task.id) { _ in
            title = task.title
            description = task.description
            savedDescription = task.description
            agent = task.agent ?? .default
            let assigned = !task.sessions.isEmpty
            composeOpen = !assigned
            composePrompt = assigned ? "" : task.description
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
                WandBoardSectionTitle(title: "任务描述", detail: "留空时派发用标题作为指令")
                if description != savedDescription {
                    Button("保存描述") {
                        let value = description
                        Task {
                            await onPatch(["description": value])
                            savedDescription = value
                        }
                    }
                    .buttonStyle(WandSecondaryButtonStyle())
                    .disabled(busy)
                }
            }
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
                .accessibilityLabel("任务描述")
        }
    }

    private var composeSection: some View {
        Group {
            if composeOpen {
                VStack(alignment: .leading, spacing: 10) {
                    WandBoardSectionTitle(
                        title: task.sessions.isEmpty ? "指派 Agent" : "再指派一个 Agent",
                        detail: "先输入提示词，再选参数直接派发"
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
                                Text("输入这次派给 Agent 的提示词…")
                                    .font(.system(size: 13))
                                    .foregroundColor(Theme.textMuted)
                                    .padding(.horizontal, 13)
                                    .padding(.vertical, 9)
                                    .allowsHitTesting(false)
                            }
                        }
                        .accessibilityLabel("派发提示词")
                    WandBoardAgentEditor(
                        agent: $agent,
                        catalog: catalog,
                        disabled: busy,
                        onChange: onRemember
                    )
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
                            let prompt = composePrompt
                            let sending = agent
                            Task { await onDispatch(prompt, sending) }
                        }
                        .buttonStyle(WandPrimaryButtonStyle())
                        .disabled(busy || composePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            } else {
                Button {
                    composePrompt = ""
                    composeOpen = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                        Text("再指派一个 Agent").font(.system(size: 12))
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
