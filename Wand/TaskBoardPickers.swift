import SwiftUI

/**
 * 任务看板共用的选择器：里程碑（迭代）下拉、Agent 参数网格、截止日期、标签。
 * 新建面板与任务详情共用同一批零件，保证两处行为一致。
 */

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
            WandBoardField("CLI 工具") {
                Picker("", selection: providerBinding) {
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
