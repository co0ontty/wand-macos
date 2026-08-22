import SwiftUI

/// 新建会话保持单列、原生控件优先；只有输入和警告需要独立表面。
struct NewSessionView: View {
    let api: WandAPI
    let initialCwd: String?
    let onCreated: (SessionSnapshot) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var cwd: String
    @State private var recentPaths: [RecentPath] = []
    @State private var provider: Provider = .claude
    @State private var sessionType: SessionType = .structured
    @State private var mode: ModeOption = .managed
    @State private var firstMessage = ""
    @State private var availableModels: [ModelInfo] = []
    @State private var codexModels: [ModelInfo] = []
    @State private var openCodeModels: [ModelInfo] = []
    @State private var grokModels: [ModelInfo] = []
    @State private var qoderModels: [ModelInfo] = []
    @State private var piModels: [ModelInfo] = []
    @State private var serverDefaultModels = ProviderDefaultModels(
        claude: nil,
        codex: nil,
        opencode: nil,
        grok: nil,
        qoder: nil,
        pi: nil
    )
    @State private var selectedModel = ""
    @State private var thinkingEffort = "off"
    @State private var creating = false
    @State private var fullAccessAcknowledged = false
    @State private var errorMessage: String?
    @State private var showBrowser = false
    @FocusState private var focusedInput: NewSessionInput?

    init(
        api: WandAPI,
        initialCwd: String? = nil,
        onCreated: @escaping (SessionSnapshot) -> Void
    ) {
        self.api = api
        self.initialCwd = initialCwd
        self.onCreated = onCreated
        _cwd = State(initialValue: initialCwd?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
    }

    private enum NewSessionInput: Hashable {
        case cwd
        case firstMessage
    }

    enum Provider: String, CaseIterable, Identifiable {
        case claude, codex, opencode, grok, qoder, pi
        var id: String { rawValue }
        var label: String {
            switch self {
            case .claude: return "Claude"
            case .codex: return "Codex"
            case .opencode: return "OpenCode"
            case .grok: return "Grok"
            case .qoder: return "Qoder"
            case .pi: return "Pi"
            }
        }
        var desc: String {
            switch self {
            case .claude: return "完整 Claude 会话能力"
            case .codex: return "结构化 JSONL 或 PTY 会话"
            case .opencode: return "OpenCode 的流式或终端会话"
            case .grok: return "Grok Build 的流式或终端会话"
            case .qoder: return "Qoder CLI 的流式或终端会话"
            case .pi: return "Pi 的 JSON 或终端会话"
            }
        }
        var symbol: String {
            switch self {
            case .claude: return "sparkle"
            case .codex: return "command"
            case .opencode: return "chevron.left.forwardslash.chevron.right"
            case .grok: return "g.circle"
            case .qoder: return "q.circle"
            case .pi: return "p.circle"
            }
        }
    }

    enum SessionType: String, CaseIterable, Identifiable, Hashable {
        case structured, pty
        var id: String { rawValue }
        var label: String { self == .structured ? "结构化" : "PTY" }
        var desc: String { self == .structured ? "智能对话模式" : "交互式终端会话" }
        var symbol: String { self == .structured ? "bubble.left.and.bubble.right" : "terminal" }

        /// 对齐 Web getSessionKindHint：codex PTY 描述 + 结构化说明。
        func hint(tool: Provider) -> String {
            switch (self, tool) {
            case (.structured, .codex):
                return "Codex JSONL 结构化聊天界面，支持多轮对话和工具调用展示。"
            case (.structured, .claude):
                return "结构化聊天界面，支持多轮对话、流式输出和工具调用展示。"
            case (.structured, .opencode):
                return "OpenCode JSON 结构化聊天界面，支持多轮续聊和工具调用展示。"
            case (.structured, .grok):
                return "Grok streaming-json 结构化聊天界面，支持多轮续聊与思考过程展示。"
            case (.structured, .qoder):
                return "Qoder stream-json 结构化聊天界面，支持多轮续聊和工具调用展示。"
            case (.structured, .pi):
                return "Pi JSON 结构化聊天界面，支持续聊、思考过程和工具调用展示。"
            case (.pty, .codex):
                return "Codex PTY 终端会话；terminal 是原始输出，chat 是解析后的阅读视图。"
            case (.pty, .claude):
                return "原始 PTY 终端会话，支持持续交互、终端视图和权限流。"
            case (.pty, .opencode):
                return "OpenCode TUI 的原始 PTY 终端会话。"
            case (.pty, .grok):
                return "Grok Build TUI 的原始 PTY 终端会话。"
            case (.pty, .qoder):
                return "Qoder CLI 的原始 PTY 终端会话。"
            case (.pty, .pi):
                return "Pi TUI 的原始 PTY 终端会话。"
            }
        }
    }

    /// 模式选项：id / label / desc，对齐 Web renderModeCards。
    enum ModeOption: String, CaseIterable, Identifiable, Hashable {
        case managed
        case fullAccess
        case autoEdit
        case standard
        case native

        var id: String { rawValue }

        var label: String {
            switch self {
            case .managed: return "托管"
            case .fullAccess: return "全权限"
            case .autoEdit: return "自动编辑"
            case .standard: return "标准"
            case .native: return "原生"
            }
        }

        var desc: String {
            switch self {
            case .managed: return "全自动完成任务"
            case .fullAccess: return "自动确认权限"
            case .autoEdit: return "自动确认修改"
            case .standard: return "逐步确认操作"
            case .native: return "原生结构化输出"
            }
        }

        var apiValue: String {
            switch self {
            case .managed: return "managed"
            case .fullAccess: return "full-access"
            case .autoEdit: return "auto-edit"
            case .standard: return "default"
            case .native: return "native"
            }
        }

        init?(apiValue: String) {
            switch apiValue {
            case "managed": self = .managed
            case "full-access": self = .fullAccess
            case "auto-edit": self = .autoEdit
            case "default": self = .standard
            case "native": self = .native
            default: return nil
            }
        }

        /// 对齐 Web getSupportedModes：Codex 只支持全权限。
        static func supported(for tool: Provider) -> Set<Self> {
            if tool == .codex { return [.fullAccess] }
            if tool == .opencode || tool == .grok || tool == .pi {
                return [.managed, .fullAccess, .standard]
            }
            if tool == .qoder { return [.managed, .fullAccess, .autoEdit, .standard] }
            return Set(allCases)
        }

        func hint(for tool: Provider) -> String {
            if tool == .codex {
                return "Codex 支持 PTY 终端与结构化（JSONL）两种会话，结构化模式按 full-access 启动。"
            }
            if tool == .grok {
                return self == .managed || self == .fullAccess
                    ? "Grok 将以 always-approve 运行；支持 TUI 与 streaming-json 结构化会话。"
                    : "Grok 使用自身权限确认；支持 TUI 与 streaming-json 结构化会话。"
            }
            if tool == .opencode {
                return self == .managed || self == .fullAccess
                    ? "OpenCode 将以自动确认模式运行；支持 TUI 与 JSON 结构化会话。"
                    : "OpenCode 使用自身权限确认；支持 TUI 与 JSON 结构化会话。"
            }
            if tool == .qoder {
                switch self {
                case .managed, .fullAccess:
                    return "Qoder 将以自动确认模式运行；支持 TUI 与 stream-json 结构化会话。"
                case .autoEdit:
                    return "Qoder 自动确认文件修改，其他操作保持 CLI 的权限流程。"
                default:
                    return "Qoder 使用自身权限确认；支持 TUI 与 stream-json 结构化会话。"
                }
            }
            if tool == .pi {
                return self == .managed || self == .fullAccess
                    ? "Pi 将自动批准工具调用；支持 TUI 与 JSON 结构化会话。"
                    : "Pi 使用自身权限确认；支持 TUI 与 JSON 结构化会话。"
            }
            switch self {
            case .fullAccess:
                return "自动确认权限请求与高权限操作，适合你确认环境安全后的连续修改。"
            case .autoEdit:
                return "保留交互式会话，同时更偏向直接编辑代码。"
            case .native:
                return "调用 Claude 原生 API 输出，适合快速问答或一次性生成。"
            case .managed:
                return "AI 自动完成所有工作，无需中途确认，适合有明确目标的任务。"
            case .standard:
                return "保留标准交互流程，适合手动确认每一步。"
            }
        }
    }

    private var providerModels: [ModelInfo] {
        switch provider {
        case .claude: availableModels
        case .codex: codexModels
        case .opencode: openCodeModels
        case .grok: grokModels
        case .qoder: qoderModels
        case .pi: piModels
        }
    }

    private var thinkingLevels: [ThinkingEffortOption] {
        thinkingEffortOptions(
            provider: provider.rawValue,
            selectedModel: selectedModel,
            defaultModel: serverDefaultModels.model(for: provider.rawValue),
            models: providerModels
        )
    }

    private var supportedModes: Set<ModeOption> {
        ModeOption.supported(for: provider)
    }

    private var modeOptions: [ModeOption] {
        ModeOption.allCases.filter { supportedModes.contains($0) }
    }

    private var modeHint: String {
        mode.hint(for: provider)
    }

    private var sessionKindHint: String {
        sessionType.hint(tool: provider)
    }

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader
            Divider().opacity(0.35)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    fieldLabel("助手")
                    providerPicker

                    fieldLabel("会话类型")
                    sessionTypePicker
                    fieldHint(sessionKindHint)

                    fieldLabel("模型与思考")
                    HStack(spacing: 10) {
                        modelMenuButton
                        ThinkingEffortSlider(
                            options: thinkingLevels,
                            selection: thinkingEffort,
                            accent: Theme.wandAccent
                        ) { thinkingEffort = $0 }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(controlBackground)
                        .frame(maxWidth: .infinity)
                    }

                    fieldLabel("模式")
                    modePicker
                    fieldHint(modeHint)
                    if mode == .fullAccess {
                        fullAccessWarning
                    }

                    fieldLabel("工作目录")
                    cwdCard

                    fieldLabel("首条消息（可选）")
                    firstMessageCard

                    if let errorMessage {
                        errorBanner(errorMessage)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 14)
            }
            .dismissKeyboardOnTap()
            .sheet(isPresented: $showBrowser) {
                DirectoryBrowserView(api: api, startPath: cwd) { picked in
                    cwd = picked
                    showBrowser = false
                }
            }
            Divider().opacity(0.35)
            sheetFooter
        }
        // 内容保持紧凑；小屏仍可通过中间滚动区访问全部字段。
        .frame(minWidth: 720, idealWidth: 780, minHeight: 680, idealHeight: 820)
        .background(WandAmbientBackground())
        // SwiftUI 在 macOS 上 .sheet 会自带 NSWindow 标题栏,跟下面的 sheetHeader 重复,
        // 视觉上「两层标题」很难看。挂这个修饰符把原生标题栏改成透明 + 隐藏文字。
        .hideNativeTitleBar()
        .task { await loadInitial() }
        .onChange(of: provider) { newProvider in
            // 切换到支持模式更少的 provider 时，回落到该 provider 的安全默认模式。
            if !supportedModes.contains(mode) {
                mode = supportedModes.contains(.managed) ? .managed : (modeOptions.first ?? .fullAccess)
            }
            // 切换 provider 后绝不复用上一个 provider 的模型 ID。
            selectedModel = ""
        }
        .onChange(of: mode) { selected in
            if selected != .fullAccess { fullAccessAcknowledged = false }
        }
    }

    // MARK: - 区块组件

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(Theme.textSecondary)
            .padding(.top, 2)
    }

    private func fieldHint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundColor(Theme.textSecondary.opacity(0.85))
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var controlBackground: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Theme.surface)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Theme.border, lineWidth: 0.75)
            )
    }

    private var providerPicker: some View {
        HStack(spacing: 6) {
            ForEach(Provider.allCases) { tool in
                Button {
                    provider = tool
                } label: {
                    HStack(spacing: 6) {
                        BrandLogoShape(provider: tool.rawValue)
                            .fill(Theme.providerColor(tool.rawValue))
                            .frame(width: 13, height: 13)
                        Text(tool.label)
                            .font(.system(size: 12, weight: provider == tool ? .semibold : .medium))
                            .lineLimit(1)
                    }
                    .foregroundColor(Theme.textPrimary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(provider == tool ? Theme.textPrimary.opacity(0.07) : .clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(
                                provider == tool ? Theme.border : Color.clear,
                                lineWidth: 0.75
                            )
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var sessionTypePicker: some View {
        Picker("会话类型", selection: $sessionType) {
            ForEach(SessionType.allCases) { kind in
                Text(kind.label).tag(kind)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
    }

    private var modePicker: some View {
        Picker("模式", selection: $mode) {
            ForEach(modeOptions) { option in
                Text(option.label).tag(option)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
    }

    private var selectedModelLabel: String {
        guard !selectedModel.isEmpty, selectedModel != "default" else { return "默认" }
        return providerModels.first(where: { $0.id == selectedModel })?.label ?? selectedModel
    }

    @ViewBuilder private var modelMenu: some View {
        Button {
            selectedModel = ""
        } label: {
            if selectedModel.isEmpty {
                Label("默认", systemImage: "checkmark")
            } else {
                Text("默认")
            }
        }
        ForEach(providerModels.filter { $0.id != "default" }) { model in
            Button {
                selectedModel = model.id
            } label: {
                if selectedModel == model.id {
                    Label(model.label, systemImage: "checkmark")
                } else {
                    Text(model.label)
                }
            }
        }
        if providerModels.isEmpty {
            Text("暂未加载到模型列表")
        }
    }

    private var modelMenuButton: some View {
        Menu {
            modelMenu
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "cpu")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
                    .frame(width: 18)
                Text(selectedModelLabel)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
            }
            .padding(.horizontal, 10)
        }
        .buttonStyle(.plain)
        .menuStyle(.borderlessButton)
        .frame(minWidth: 180, idealWidth: 210, maxWidth: 240)
        .frame(height: 44)
        .background(controlBackground)
        .accessibilityLabel("模型：\(selectedModelLabel)")
    }

    /// 工作目录保持单行主路径；最近目录进入菜单，避免把弹窗拉成长列表。
    private var cwdCard: some View {
        HStack(spacing: 0) {
            TextField("/path/to/project", text: $cwd)
                .font(.system(size: 14, design: .monospaced))
                .textFieldStyle(.plain)
                .foregroundColor(Theme.textPrimary)
                .tint(Theme.wandAccent)
                .focused($focusedInput, equals: .cwd)
                .padding(.leading, 12)
                .padding(.vertical, 11)
            if !recentPaths.isEmpty {
                Menu {
                    ForEach(recentPaths.prefix(8)) { recent in
                        Button {
                            cwd = recent.path
                        } label: {
                            if cwd == recent.path {
                                Label(recent.displayName, systemImage: "checkmark")
                            } else {
                                Text(recent.displayName)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(Theme.textSecondary)
                        .frame(width: 38, height: 38)
                }
                .menuStyle(.borderlessButton)
                .help("最近目录")
            }
            Button {
                showBrowser = true
            } label: {
                Image(systemName: "folder")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
                    .frame(width: 38, height: 38)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("浏览目录")
        }
        .wandInputSurface(focused: focusedInput == .cwd)
    }

    @ViewBuilder
    private var firstMessageCard: some View {
        // 多行首条消息用 TextField(.vertical)（macOS 13+），用 axis 替代 TextEditor，
        // 占位符自动处理、不需要 scrollContentBackground 调样式，避免 12.x 部署目标的
        // API 限制。12.x 走单行 TextField 占位样式。
        if #available(macOS 13.0, *) {
            TextField("想让它做什么…", text: $firstMessage, axis: .vertical)
                .font(.system(size: 14))
                .lineLimit(2...6)
                .textFieldStyle(.plain)
                .foregroundColor(Theme.textPrimary)
                .tint(Theme.wandAccent)
                .focused($focusedInput, equals: .firstMessage)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .wandInputSurface(focused: focusedInput == .firstMessage)
        } else {
            TextField("想让它做什么…", text: $firstMessage)
                .font(.system(size: 14))
                .textFieldStyle(.plain)
                .foregroundColor(Theme.textPrimary)
                .tint(Theme.wandAccent)
                .focused($focusedInput, equals: .firstMessage)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .wandInputSurface(focused: focusedInput == .firstMessage)
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundColor(Theme.danger)
            Text(message)
                .font(.system(size: 12))
                .foregroundColor(Theme.danger)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.danger.opacity(0.10))
        )
    }

    private var fullAccessWarning: some View {
        Toggle(isOn: $fullAccessAcknowledged) {
            VStack(alignment: .leading, spacing: 3) {
                Text("我确认此目录和环境可以自动执行高权限操作")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                Text("全权限模式会自动同意权限请求。未确认前不能启动会话。")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textSecondary)
            }
        }
        .toggleStyle(.checkbox)
        .padding(12)
        .background(Theme.warning.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.warning.opacity(0.4), lineWidth: 1))
    }

    // MARK: - 头部 / 底部

    private var sheetHeader: some View {
        // 顶部 header 整块可拖动：hideNativeTitleBar() 把原生标题栏隐藏后,
        // 默认 NSWindow 不可拖；用 .gesture(DragGesture) + NSWindow.setFrameOrigin
        // 把 header 转成拖拽区。直接在 .background() 放 NSView 会被 HStack 拦事件，
        // 走 SwiftUI gesture 更稳。
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("新建对话")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                Text("选择助手、目录和运行方式")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textSecondary)
            }
            Spacer()
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .background(Theme.workspaceBackground)
        .windowDrag()
    }

    private var sheetFooter: some View {
        HStack(spacing: 10) {
            Text("\(provider.label) · \(sessionType.label) · \(mode.label) · \((cwd as NSString).lastPathComponent)")
                .font(.system(size: 11))
                .foregroundColor(Theme.textSecondary)
                .lineLimit(1)
                .help(cwd)
            Spacer()
            Button("取消") { dismiss() }
                .buttonStyle(WandSecondaryButtonStyle())
            if creating {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 92)
            } else {
                Button {
                    create()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 11, weight: .bold))
                        Text("启动会话")
                    }
                    .frame(minWidth: 92)
                }
                .buttonStyle(WandPrimaryButtonStyle())
                .disabled(!canCreate)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .background(Theme.workspaceBackground)
    }

    // MARK: - 状态

    private var canCreate: Bool {
        !cwd.trimmingCharacters(in: .whitespaces).isEmpty
            && !creating
            && (mode != .fullAccess || fullAccessAcknowledged)
    }

    private func loadInitial() async {
        let config = try? await api.serverConfig()
        switch config?.defaultProvider {
        case "codex": provider = .codex
        case "opencode": provider = .opencode
        case "grok": provider = .grok
        case "qoder": provider = .qoder
        case "pi": provider = .pi
        default: provider = .claude
        }
        sessionType = config?.defaultSessionKind == "pty" ? .pty : .structured
        if let defaultMode = config?.defaultMode, let parsed = ModeOption(apiValue: defaultMode) {
            if supportedModes.contains(parsed) {
                mode = parsed
            }
        }
        selectedModel = ""
        thinkingEffort = config?.defaultThinkingEffort ?? "off"
        serverDefaultModels = config?.defaultModels ?? ProviderDefaultModels(
            claude: config?.defaultModel,
            codex: config?.defaultCodexModel,
            opencode: config?.defaultOpenCodeModel,
            grok: config?.defaultGrokModel,
            qoder: config?.defaultQoderModel,
            pi: config?.defaultPiModel
        )
        if let response = try? await api.models() {
            availableModels = response.models
            codexModels = response.codexModels
            openCodeModels = response.opencodeModels ?? []
            grokModels = response.grokModels ?? []
            qoderModels = response.qoderModels ?? []
            piModels = response.piModels ?? []
            serverDefaultModels = response.defaultModels ?? ProviderDefaultModels(
                claude: response.defaultModel,
                codex: response.defaultCodexModel,
                opencode: response.defaultOpenCodeModel,
                grok: response.defaultGrokModel,
                qoder: response.defaultQoderModel,
                pi: response.defaultPiModel
            )
        }
        recentPaths = (try? await api.recentPaths()) ?? []
        if cwd.isEmpty {
            if let first = recentPaths.first {
                cwd = first.path
            } else if let def = config?.defaultCwd {
                cwd = def
            }
        }
    }

    private func create() {
        guard canCreate else { return }
        creating = true
        errorMessage = nil
        let path = cwd.trimmingCharacters(in: .whitespaces)
        let prompt = firstMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                try await api.updateNewSessionDefaults(
                    mode: mode.apiValue,
                    model: selectedModel.isEmpty ? nil : selectedModel,
                    provider: provider.rawValue,
                    thinkingEffort: thinkingEffort,
                    defaultSessionKind: sessionType.rawValue
                )
                let snapshot: SessionSnapshot
                switch sessionType {
                case .structured:
                    snapshot = try await api.createStructuredSession(
                        provider: provider.rawValue,
                        cwd: path,
                        mode: mode.apiValue,
                        model: selectedModel,
                        thinkingEffort: thinkingEffort,
                        prompt: prompt.isEmpty ? nil : prompt
                    )
                case .pty:
                    snapshot = try await api.createPtySession(
                        provider: provider.rawValue,
                        cwd: path,
                        mode: mode.apiValue,
                        model: selectedModel,
                        thinkingEffort: thinkingEffort,
                        initialInput: prompt.isEmpty ? nil : prompt
                    )
                }
                creating = false
                onCreated(snapshot)
            } catch {
                creating = false
                errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - 目录浏览器

/// 极简目录浏览器：基于 /api/directory 逐层进入，选中当前目录。
struct DirectoryBrowserView: View {
    let api: WandAPI
    let startPath: String
    let onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var currentPath = "~"
    @State private var items: [DirectoryItem] = []
    @State private var loading = true
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("选择目录")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                Spacer()
                Button("取消") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundColor(Theme.textSecondary)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .wandGlass(.chrome)
            pathHeader
            Divider()
            if loading {
                Spacer()
                ProgressView().tint(Theme.wandAccent)
                Spacer()
            } else if let errorMessage {
                Spacer()
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundColor(Theme.danger)
                    .padding()
                Spacer()
            } else {
                directoryList
            }
            Divider()
            HStack {
                Spacer()
                Button("选择此目录") { onPick(currentPath) }
                    .buttonStyle(WandPrimaryButtonStyle())
            }
            .padding(14)
            .background(Theme.surface)
        }
        .frame(minWidth: 620, minHeight: 520)
        .task {
            currentPath = startPath.isEmpty ? "~" : startPath
            await load()
        }
    }

    private var pathHeader: some View {
        HStack(spacing: 8) {
            Button {
                let parent = (currentPath as NSString).deletingLastPathComponent
                guard !parent.isEmpty, parent != currentPath else { return }
                currentPath = parent
                Task { await load() }
            } label: {
                Image(systemName: "arrow.up.doc")
                    .font(.system(size: 14))
                    .foregroundColor(Theme.wandAccent)
            }
            Text(currentPath)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var directoryList: some View {
        List {
            ForEach(items.filter { $0.isDirectory }) { item in
                Button {
                    currentPath = item.path
                    Task { await load() }
                } label: {
                    HStack {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 14))
                            .foregroundColor(Theme.wandAccent.opacity(0.8))
                        Text(item.name)
                            .font(.system(size: 14))
                            .foregroundColor(Theme.textPrimary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Theme.textSecondary)
                    }
                }
                .listRowBackground(Theme.background)
            }
        }
        .listStyle(.plain)
    }

    private func load() async {
        loading = true
        errorMessage = nil
        do {
            let listing = try await api.listDirectory(currentPath)
            items = listing.items
            // 服务端会把 ~ 之类输入解析为绝对路径；用首项的父路径回填展示。
            if currentPath == "~", let first = listing.items.first {
                currentPath = (first.path as NSString).deletingLastPathComponent
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        loading = false
    }
}
