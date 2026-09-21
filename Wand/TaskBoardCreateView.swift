import SwiftUI

/// 新建任务对话框里的草稿；字段与 Web `IssueDraft` 对齐。
struct WandBoardDraft {
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

/**
 * 新建任务面板：标题可选（留空按描述自动生成）、描述是主输入，
 * 「处理中」列新建时创建即派发；「等待认领」列只落库。
 */
struct WandBoardCreateView: View {
    let workspaces: [Workspace]
    let milestones: [WandBoardMilestone]
    let catalog: ModelsResponse?
    let defaultWorkspaceId: String
    let initialStatus: String
    let onCreate: (WandBoardDraft) async -> Bool
    let onCreateMilestone: (String, String?) async throws -> WandBoardMilestone

    @Environment(\.dismiss) private var dismiss
    @State private var draft = WandBoardDraft()
    @State private var creationMore = false
    @State private var creating = false
    @State private var errorMessage: String?
    @FocusState private var focusedField: String?

    init(
        workspaces: [Workspace],
        milestones: [WandBoardMilestone],
        catalog: ModelsResponse?,
        defaultWorkspaceId: String,
        initialStatus: String = WandBoardStatus.todo.rawValue,
        lastAgent: WandBoardTaskAgent = .default,
        onCreate: @escaping (WandBoardDraft) async -> Bool,
        onCreateMilestone: @escaping (String, String?) async throws -> WandBoardMilestone
    ) {
        self.workspaces = workspaces
        self.milestones = milestones
        self.catalog = catalog
        self.defaultWorkspaceId = defaultWorkspaceId
        self.initialStatus = initialStatus
        self.onCreate = onCreate
        self.onCreateMilestone = onCreateMilestone
        var initial = WandBoardDraft()
        initial.status = initialStatus
        initial.priority = WandBoardPriority.low.rawValue
        initial.workspaceId = defaultWorkspaceId
        initial.agent = lastAgent
        _draft = State(initialValue: initial)
    }

    /// 「处理中」列的新建代表已经决定要跑：创建后立刻派 Agent。
    private var dispatches: Bool { wandBoardCreateDispatches(status: draft.status) }

    private var hasDescription: Bool {
        !draft.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.border).frame(height: 0.5)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    writing
                    properties
                    assign
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.system(size: 12))
                            .foregroundColor(Theme.danger)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                                    .fill(Theme.danger.opacity(0.08))
                            )
                    }
                }
                .padding(24)
                .disabled(creating)
            }
            Rectangle().fill(Theme.border).frame(height: 0.5)
            footer
        }
        .frame(width: 640)
        .frame(minHeight: 520, idealHeight: 640, maxHeight: 760)
        .background(Theme.workspaceBackground)
        .hideNativeTitleBar()
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("新建任务")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                Text(
                    dispatches
                        ? "描述要完成的工作，创建后交给所选工具执行。"
                        : "先记录要做的事，准备好后再从任务详情启动执行。"
                )
                .font(.system(size: 12))
                .foregroundColor(Theme.textSecondary)
            }
            Spacer(minLength: 0)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(WandIconButtonStyle())
            .disabled(creating)
            .help("关闭新建任务")
            .accessibilityLabel("关闭新建任务")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .windowDrag()
    }

    private var writing: some View {
        VStack(alignment: .leading, spacing: 10) {
            WandBoardField("任务标题 可选") {
                TextField("不填写则按描述自动生成", text: $draft.title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .medium))
                    .focused($focusedField, equals: "title")
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .wandInputSurface(focused: focusedField == "title", cornerRadius: Theme.Radius.control)
            }
            WandBoardField(dispatches ? "任务描述（作为第一次指派）" : "任务描述") {
                TextEditor(text: $draft.description)
                    .font(.system(size: 13))
                    .lineSpacing(4)
                    .focused($focusedField, equals: "description")
                    .padding(8)
                    .frame(height: 130)
                    .wandInputSurface(focused: focusedField == "description", cornerRadius: Theme.Radius.control)
                    .overlay(alignment: .topLeading) {
                        if draft.description.isEmpty {
                            Text(
                                dispatches
                                    ? "添加描述…（将作为第一个 Agent 的指派内容）"
                                    : "添加描述…（只创建任务，不指派 Agent）"
                            )
                            .font(.system(size: 13))
                            .foregroundColor(Theme.textMuted)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 9)
                            .allowsHitTesting(false)
                        }
                    }
                    .accessibilityLabel("任务描述")
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
                WandBoardField("项目目录") {
                    Picker("", selection: $draft.workspaceId) {
                        Text("不指定目录（使用全局目录）").tag("")
                        ForEach(workspaces) { workspace in
                            Text(workspace.name).tag(workspace.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                WandBoardField("状态") {
                    Picker("", selection: $draft.status) {
                        ForEach(WandBoardStatus.columns) { item in
                            Text(item.label).tag(item.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                WandBoardField("优先级") {
                    Picker("", selection: $draft.priority) {
                        ForEach(WandBoardPriority.allCases) { item in
                            Text(item.label).tag(item.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                WandBoardField("截止日期") {
                    WandBoardDueDateField(value: draft.dueDate.isEmpty ? nil : draft.dueDate) { value in
                        draft.dueDate = value ?? ""
                    }
                }
                WandBoardField("里程碑") {
                    WandBoardMilestonePicker(
                        value: draft.milestoneId.isEmpty ? nil : draft.milestoneId,
                        workspaceId: draft.workspaceId,
                        milestones: milestones,
                        onChange: { draft.milestoneId = $0 ?? "" },
                        onCreate: { try await onCreateMilestone($0, draft.workspaceId.isEmpty ? nil : draft.workspaceId) }
                    )
                }
                WandBoardField("标签") {
                    WandBoardLabelsField(labels: draft.parsedLabels) { labels in
                        draft.labels = labels.joined(separator: ", ")
                    }
                }
            }
        }
    }

    private var assign: some View {
        VStack(alignment: .leading, spacing: 10) {
            WandBoardSectionTitle(
                title: dispatches ? "第一次指派" : "Agent 与运行模式",
                detail: dispatches
                    ? (hasDescription ? "有描述时会立刻发给所选 Agent" : "补上描述才会立刻派发")
                    : "会记入全局默认，之后派发沿用"
            )
            WandBoardAgentEditor(agent: $draft.agent, catalog: catalog)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Toggle("创建更多", isOn: $creationMore)
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
                .foregroundColor(Theme.textSecondary)
                .disabled(creating)
            Spacer(minLength: 0)
            Button("取消") { dismiss() }
                .buttonStyle(WandSecondaryButtonStyle())
                .disabled(creating)
            Button(creating ? "正在保存…" : (dispatches && hasDescription ? "创建并指派" : "创建任务")) {
                submit()
            }
            .buttonStyle(WandPrimaryButtonStyle())
            .disabled(creating || draft.isEmpty)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private func submit() {
        guard !creating, !draft.isEmpty else { return }
        creating = true
        errorMessage = nil
        Task {
            let ok = await onCreate(draft)
            creating = false
            guard ok else {
                errorMessage = "创建失败，请重试。"
                return
            }
            if creationMore {
                // 连续创建只沿用项目 / 状态 / Agent，其余回默认值。
                draft = wandBoardDraftAfterCreateMore(draft)
                focusedField = "description"
            } else {
                dismiss()
            }
        }
    }
}
