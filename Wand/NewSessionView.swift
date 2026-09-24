import Combine
import SwiftUI

struct SessionCreationContext: Equatable {
    var cwd: String? = nil
    var workspaceId: String? = nil
    var taskId: String? = nil
    var taskName: String? = nil
    var workspaceDefaultProvider: String? = nil
    var startsNewTask = true
}

struct SessionTaskOption: Identifiable {
    let id: String
    let workspaceId: String
    let name: String
    let workspaceName: String
    let cwd: String
    var label: String { workspaceName.isEmpty ? name : "\(workspaceName) / \(name)" }
}

/// Owned by the shell so switching pages does not recreate partially edited settings.
@MainActor
final class SessionCreationDraft: ObservableObject, Identifiable {
    let id = UUID()
    let context: SessionCreationContext
    @Published var cwd: String
    @Published var firstMessage: String
    @Published var provider: NewSessionView.Provider = .claude
    @Published var sessionType: NewSessionView.SessionType = .structured
    @Published var mode: NewSessionView.ModeOption = .managed
    @Published var selectedModel = ""
    @Published var thinkingEffort = "off"
    @Published var fullAccessAcknowledged = false
    @Published var recentPaths: [RecentPath] = []
    @Published var availableModels: [ModelInfo] = []
    @Published var codexModels: [ModelInfo] = []
    @Published var openCodeModels: [ModelInfo] = []
    @Published var grokModels: [ModelInfo] = []
    @Published var qoderModels: [ModelInfo] = []
    @Published var piModels: [ModelInfo] = []
    @Published var serverDefaultModels = ProviderDefaultModels(
        claude: nil, codex: nil, opencode: nil, grok: nil, qoder: nil, pi: nil
    )
    @Published var destination: String
    @Published var taskName = ""
    @Published var worktree = true
    @Published var tasks: [SessionTaskOption] = []
    @Published var workspaces: [Workspace] = []
    @Published private(set) var refreshingOptions = false
    @Published private(set) var optionsRefreshError: String?
    @Published var binding: WorkspaceBinding?
    @Published var loading = true
    @Published var loadingTask = false
    @Published var creating = false
    @Published var errorMessage: String?
    @Published var loadError: String?
    @Published var taskError: String?
    var initialized = false
    var providerWasEdited = false
    var defaultProvider = "claude"
    var defaultMode = "managed"
    var defaultThinkingEffort = "off"
    var unboundCwd: String
    var taskGeneration = 0
    private var optionsRefreshPending = false
    private var optionsRefreshTask: Task<Void, Never>?

    init(context: SessionCreationContext = .init(), initialMessage: String = "") {
        self.context = context
        let initialCwd = context.cwd?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        cwd = initialCwd
        unboundCwd = initialCwd
        firstMessage = initialMessage
        destination = context.taskId ?? (context.startsNewTask ? "new" : "none")
    }

    var resolvedTaskName: String? {
        guard destination != "new", destination != "none" else { return nil }
        if let name = tasks.first(where: { $0.id == destination })?.name,
           !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return name
        }
        if context.taskId == destination, let name = context.taskName,
           !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return name
        }
        return nil
    }

    /// Updating available destinations must never reinitialize an edited creation draft.
    fileprivate func updateOptions(groups: [TaskDirectoryGroup], workspaces: [Workspace]) {
        var options = groups.flatMap { group in
            group.tasks.map { task in
                SessionTaskOption(id: task.id, workspaceId: task.workspaceId, name: task.name,
                                  workspaceName: group.workspaceName, cwd: task.cwd)
            }
        }
        if destination != "new", destination != "none",
           !options.contains(where: { $0.id == destination }) {
            let selected = tasks.first(where: { $0.id == destination })
                ?? SessionTaskOption(id: destination,
                    workspaceId: binding?.workspaceId ?? context.workspaceId ?? "",
                    name: context.taskId == destination ? context.taskName ?? "所选任务" : "所选任务",
                    workspaceName: "", cwd: cwd)
            options.append(selected)
        }
        self.workspaces = workspaces
        tasks = options
    }

    func refreshOptions(api: WandAPI, invalidated: Bool = false) async {
        guard initialized else { return }
        if optionsRefreshTask != nil {
            optionsRefreshPending = optionsRefreshPending || invalidated
            return
        }
        refreshingOptions = true
        // A popover or page can disappear while other callers still need this snapshot.
        // Keep the shared read independent of the initiating SwiftUI task's cancellation.
        let refresh = Task { await performOptionsRefresh(api: api) }
        optionsRefreshTask = refresh
        await refresh.value
    }

    private func performOptionsRefresh(api: WandAPI) async {
        defer {
            refreshingOptions = false
            optionsRefreshTask = nil
        }
        repeat {
            optionsRefreshPending = false
            do {
                async let groupsRequest = api.listTaskGroups()
                async let workspacesRequest = api.listWorkspaces()
                let (groups, workspaces) = try await (groupsRequest, workspacesRequest)
                guard !Task.isCancelled else { return }
                updateOptions(groups: groups, workspaces: workspaces)
                optionsRefreshError = nil
            } catch {
                guard !Task.isCancelled else { return }
                optionsRefreshError = "无法更新任务列表：" + error.localizedDescription
            }
        } while optionsRefreshPending
    }
}

/// One creation form serves the desktop home, task additions and compatibility sheets.
struct NewSessionView: View {
    let api: WandAPI
    let workspaceStore: WorkspaceStore?
    let embedded: Bool
    let onCreated: (SessionSnapshot) -> Void
    @StateObject private var draft: SessionCreationDraft
    @Environment(\.dismiss) private var dismiss
    @State private var showBrowser = false
    @State private var showModelPicker = false
    @State private var modelQuery = ""
    @State private var showRunSettings = false
    @State private var showProviderPicker = false
    @State private var showDirectoryOptions = false
    @State private var showTaskOptions = false
    @State private var composerFocused = false
    @State private var composerHeight: CGFloat = 72
    @State private var composing = false
    @FocusState private var focusedInput: NewSessionInput?

    init(api: WandAPI, initialCwd: String? = nil, initialMessage: String = "",
         draft: SessionCreationDraft? = nil, workspaceStore: WorkspaceStore? = nil,
         embedded: Bool = false, onCreated: @escaping (SessionSnapshot) -> Void) {
        self.api = api
        self.workspaceStore = workspaceStore
        self.embedded = embedded
        self.onCreated = onCreated
        _draft = StateObject(wrappedValue: draft ?? SessionCreationDraft(
            context: SessionCreationContext(cwd: initialCwd), initialMessage: initialMessage
        ))
    }

    private enum NewSessionInput: Hashable { case cwd }

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
        switch draft.provider {
        case .claude: draft.availableModels
        case .codex: draft.codexModels
        case .opencode: draft.openCodeModels
        case .grok: draft.grokModels
        case .qoder: draft.qoderModels
        case .pi: draft.piModels
        }
    }

    private var thinkingLevels: [ThinkingEffortOption] {
        thinkingEffortOptions(
            provider: draft.provider.rawValue,
            selectedModel: draft.selectedModel,
            defaultModel: draft.serverDefaultModels.model(for: draft.provider.rawValue),
            models: providerModels
        )
    }

    private var supportedModes: Set<ModeOption> {
        ModeOption.supported(for: draft.provider)
    }

    private var modeOptions: [ModeOption] {
        ModeOption.allCases.filter { supportedModes.contains($0) }
    }

    private var modeHint: String {
        draft.mode.hint(for: draft.provider)
    }

    private var sessionKindHint: String {
        draft.sessionType.hint(tool: draft.provider)
    }

    var body: some View {
        Group {
            if embedded { form }
            else {
                VStack(spacing: 0) {
                    HStack {
                        Text("新建会话").font(.system(size: 17, weight: .semibold))
                        Spacer()
                        Button("取消") { dismiss() }
                            .buttonStyle(WandSecondaryButtonStyle())
                            .keyboardShortcut(.cancelAction)
                    }.padding(20)
                    form
                }
                .frame(minWidth: 720, idealWidth: 780, minHeight: 540, idealHeight: 720)
                .focusedSceneValue(\.wandDesktopCommandsEnabled, false)
                .hideNativeTitleBar()
            }
        }
        .background(Theme.workspaceBackground)
        .sheet(isPresented: $showBrowser) {
            DirectoryBrowserView(api: api, startPath: draft.cwd) { picked in
                draft.cwd = picked
                showBrowser = false
            }
        }
        .task { await loadInitial() }
        .onAppear { composerFocused = true }
        .onChange(of: draft.mode) { _ in draft.fullAccessAcknowledged = false }
        .onReceive(NotificationCenter.default.publisher(for: .wandDesktopCommand)) { note in
            if note.object as? DesktopCommand == .focusComposer { composerFocused = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .wandRefreshLists)) { _ in
            Task { await draft.refreshOptions(api: api, invalidated: true) }
        }
    }

    private var form: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 26) {
                    Text(isExistingTask ? draft.resolvedTaskName ?? "开始新的会话" : "今天，想完成什么？")
                        .font(.system(size: 30, weight: .medium)).tracking(-0.7)
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(2).multilineTextAlignment(.center)
                    VStack(alignment: .leading, spacing: 0) {
                        firstMessageCard
                        if draft.loading {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("正在读取默认配置…").font(.system(size: 12))
                            }.foregroundColor(Theme.textSecondary).frame(height: 34).padding(.horizontal, 14)
                        } else if let error = draft.loadError {
                            VStack(alignment: .leading, spacing: 8) {
                                errorBanner(error)
                                Button("重试加载") { Task { await loadInitial() } }
                                    .buttonStyle(WandSecondaryButtonStyle())
                            }.padding(14)
                        } else {
                            composerOptions(compact: geometry.size.width < 700)
                                .padding(.horizontal, 12).padding(.bottom, 12)
                                .disabled(draft.creating)
                        }
                    }
                    .wandInputSurface(focused: composerFocused, cornerRadius: Theme.Radius.lg)
                    if let error = draft.taskError {
                        VStack(alignment: .leading, spacing: 8) {
                            errorBanner(error)
                            Button("重新读取任务") { selectDestination(draft.destination) }
                                .buttonStyle(WandSecondaryButtonStyle())
                        }
                    }
                    if let error = draft.errorMessage { errorBanner(error) }
                }
                .frame(maxWidth: 760)
                .padding(.horizontal, 28).padding(.vertical, 32)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .center)
            }
        }
    }

    @ViewBuilder
    private func composerOptions(compact: Bool) -> some View {
        if compact {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) { providerButton; modelMenuButton; Spacer(minLength: 0) }
                HStack(spacing: 4) { directoryButton; taskButton; Spacer(minLength: 4); runSettingsButton; startButton }
            }
        } else {
            HStack(spacing: 4) {
                providerButton
                modelMenuButton
                directoryButton
                taskButton
                Spacer(minLength: 4)
                runSettingsButton
                startButton
            }
        }
    }

    private func chipLabel(_ text: String, symbol: String, width: CGFloat = 130) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 12))
            Text(text).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .medium))
        }
        .foregroundColor(Theme.textSecondary)
        .padding(.horizontal, 8).frame(height: 32)
        .frame(maxWidth: width).contentShape(RoundedRectangle(cornerRadius: Theme.Radius.control))
    }

    private var providerButton: some View {
        Button { showProviderPicker = true } label: {
            HStack(spacing: 6) {
                BrandLogo(provider: draft.provider.rawValue, color: Theme.textPrimary).frame(width: 13, height: 13)
                Text(draft.provider.label).font(.system(size: 12, weight: .medium))
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .medium))
            }.foregroundColor(Theme.textSecondary).padding(.horizontal, 8).frame(height: 32)
        }
        .buttonStyle(DesktopNavigationButtonStyle()).help("选择工具")
        .accessibilityLabel("工具：\(draft.provider.label)")
        .popover(isPresented: $showProviderPicker, arrowEdge: .bottom) { providerPicker.padding(8).frame(width: 210) }
    }

    private var directoryButton: some View {
        Button { showDirectoryOptions = true } label: {
            chipLabel(draft.loadingTask ? "读取目录…" : draft.cwd.isEmpty ? "选择目录" : (draft.cwd as NSString).lastPathComponent,
                      symbol: "folder", width: 145)
        }.buttonStyle(DesktopNavigationButtonStyle()).help(draft.cwd.isEmpty ? "选择工作目录" : draft.cwd)
            .accessibilityLabel("工作目录：\(draft.cwd)")
            .popover(isPresented: $showDirectoryOptions, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("工作目录").font(.system(size: 14, weight: .semibold))
                    if isExistingTask {
                        if draft.loadingTask {
                            // 还没拿到任务详情：不能把入口上下文里的目录当成任务目录展示。
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("正在读取任务的工作目录…")
                            }
                            .font(.system(size: 12))
                            .foregroundColor(Theme.textSecondary)
                            fieldHint("读取完成前不能启动会话。")
                        } else {
                            Text(draft.cwd).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            fieldHint("跟随所选任务的工作目录。切换任务可更改目录。")
                        }
                    } else { cwdCard }
                    HStack { Spacer(); Button("完成") { showDirectoryOptions = false }.buttonStyle(WandSecondaryButtonStyle()) }
                }.padding(20).frame(width: 400).background(Theme.workspaceBackground)
            }
    }

    private var taskLabel: String {
        if draft.destination == "new" { return "新建任务" }
        if draft.destination == "none" { return "不归属任务" }
        return draft.resolvedTaskName ?? "所选任务"
    }

    private var taskButton: some View {
        Button { showTaskOptions = true } label: {
            chipLabel(taskLabel, symbol: "square.stack", width: 135)
        }.buttonStyle(DesktopNavigationButtonStyle()).help("归属任务：\(taskLabel)")
            .accessibilityLabel("归属任务：\(taskLabel)")
            .popover(isPresented: $showTaskOptions, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("归属任务").font(.system(size: 14, weight: .semibold))
                    destinationPicker
                    if draft.refreshingOptions {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("正在更新任务列表…").font(.system(size: 12))
                        }.foregroundColor(Theme.textSecondary)
                    } else if let error = draft.optionsRefreshError {
                        Text(error).font(.system(size: 12)).foregroundColor(Theme.danger)
                        Button("重试更新") { Task { await draft.refreshOptions(api: api) } }
                            .buttonStyle(WandSecondaryButtonStyle())
                    }
                    if draft.destination == "new" {
                        TextField("任务名称（留空自动命名）", text: $draft.taskName).textFieldStyle(.roundedBorder)
                        Toggle("独立工作树", isOn: $draft.worktree).toggleStyle(.checkbox)
                        fieldHint("使用独立分支与目录完成这个任务。")
                    }
                    HStack { Spacer(); Button("完成") { showTaskOptions = false }.buttonStyle(WandSecondaryButtonStyle()) }
                }.padding(20).frame(width: 340).background(Theme.workspaceBackground)
                    .task { await draft.refreshOptions(api: api) }
            }
    }

    private var runSettingsButton: some View {
        Button { showRunSettings = true } label: {
            Image(systemName: "slider.horizontal.3").font(.system(size: 14))
                .foregroundColor(Theme.textSecondary).frame(width: 32, height: 32)
        }.buttonStyle(DesktopNavigationButtonStyle())
            .accessibilityLabel("运行设置").help("\(draft.sessionType.desc) · \(draft.mode.label)")
            .popover(isPresented: $showRunSettings, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("运行设置").font(.system(size: 14, weight: .semibold))
                    ThinkingEffortSlider(options: thinkingLevels, selection: draft.thinkingEffort, accent: Theme.wandAccent) {
                        draft.providerWasEdited = true
                        draft.thinkingEffort = $0
                    }
                    fieldLabel("会话类型")
                    sessionTypePicker.help(sessionKindHint)
                    fieldLabel("权限模式")
                    modePicker
                    fieldHint(modeHint)
                    if draft.mode == .fullAccess { fullAccessWarning }
                    HStack { Spacer(); Button("完成") { showRunSettings = false }.buttonStyle(WandSecondaryButtonStyle()) }
                }.padding(20).frame(width: 360).background(Theme.workspaceBackground)
            }
    }

    private var startButton: some View {
        Button(action: prepareCreate) {
            ZStack {
                if draft.creating { ProgressView().controlSize(.small).tint(.white) }
                else { Image(systemName: "arrow.up").font(.system(size: 15, weight: .semibold)) }
            }.frame(width: 34, height: 34)
        }
        .buttonStyle(WandSendButtonStyle()).disabled(!readyToStart)
        .keyboardShortcut(.return, modifiers: .command)
        .accessibilityLabel(draft.creating ? "正在启动会话" : "启动会话")
        .help("启动会话 · ⌘↵")
    }

    private func prepareCreate() {
        guard readyToStart else { return }
        if draft.mode == .fullAccess && !draft.fullAccessAcknowledged { showRunSettings = true }
        else { create() }
    }

    private var defaultModelLabel: String {
        let model = draft.serverDefaultModels.model(for: draft.provider.rawValue) ?? ""
        let label = providerModels.first(where: { $0.id == model })?.label ?? model
        return label.isEmpty ? "服务器默认" : "服务器默认 · \(label)"
    }

    private var destinationPicker: some View {
        Picker("归属任务", selection: Binding(get: { draft.destination }, set: selectDestination)) {
            Text("新建任务").tag("new")
            Text("暂不归属任务").tag("none")
            Divider()
            ForEach(draft.tasks) { task in Text(task.label).tag(task.id) }
        }
        .labelsHidden().pickerStyle(.menu)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel("归属任务")
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

    private var providerPicker: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Provider.allCases) { tool in
                Button {
                    chooseProvider(tool, userInitiated: true)
                    showProviderPicker = false
                } label: {
                    HStack(spacing: 10) {
                        BrandLogo(provider: tool.rawValue, color: Theme.textPrimary).frame(width: 16, height: 16)
                        Text(tool.label).font(.system(size: 13))
                        Spacer()
                        if draft.provider == tool { Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)) }
                    }.foregroundColor(Theme.textPrimary).padding(.horizontal, 10).frame(height: 34)
                        .contentShape(Rectangle())
                }.buttonStyle(DesktopNavigationButtonStyle())
            }
        }
    }

    private var sessionTypePicker: some View {
        Picker("会话类型", selection: $draft.sessionType) {
            ForEach(SessionType.allCases) { kind in
                Text(kind.label).tag(kind)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
    }

    private var modePicker: some View {
        Picker("模式", selection: Binding(get: { draft.mode }, set: {
            draft.providerWasEdited = true
            draft.mode = $0
        })) {
            ForEach(modeOptions) { option in
                Text(option.label).tag(option)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
    }

    private var selectedModelLabel: String {
        guard !draft.selectedModel.isEmpty, draft.selectedModel != "default" else {
            let model = draft.serverDefaultModels.model(for: draft.provider.rawValue) ?? ""
            let label = providerModels.first(where: { $0.id == model })?.label ?? model
            return label.isEmpty ? "服务器默认" : "默认 · \(label)"
        }
        return providerModels.first(where: { $0.id == draft.selectedModel })?.label ?? draft.selectedModel
    }

    private var filteredNewSessionModels: [ModelInfo] {
        providerModels.filter { model in
            model.id != "default" && matchesModelKeyword(modelQuery, id: model.id, label: model.label)
        }
    }

    private var defaultNewSessionModelMatchesQuery: Bool {
        matchesModelKeyword(modelQuery, id: "", label: defaultModelLabel)
    }

    @ViewBuilder private func modelPickerRow(id: String, label: String) -> some View {
        Button {
            draft.providerWasEdited = true
            draft.selectedModel = id
            showModelPicker = false
            modelQuery = ""
        } label: {
            HStack {
                Text(label)
                    .foregroundColor(Theme.textPrimary)
                Spacer()
                if draft.selectedModel == id || (id.isEmpty && draft.selectedModel.isEmpty) {
                    Image(systemName: "checkmark")
                        .foregroundColor(Theme.wandAccent)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(DesktopNavigationButtonStyle())
    }

    private var compactModelLabel: String {
        let model = draft.selectedModel.isEmpty ? draft.serverDefaultModels.model(for: draft.provider.rawValue) ?? "" : draft.selectedModel
        if model.isEmpty { return "默认模型" }
        let label = providerModels.first(where: { $0.id == model })?.label ?? model
        return label.components(separatedBy: " · ").first?.components(separatedBy: "（").first ?? label
    }

    private var modelMenuButton: some View {
        Button { showModelPicker.toggle() } label: {
            chipLabel(compactModelLabel, symbol: "cpu", width: 150)
        }
        .buttonStyle(DesktopNavigationButtonStyle()).help(selectedModelLabel)
        .accessibilityLabel("模型：\(selectedModelLabel)")
        .popover(isPresented: $showModelPicker, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                SessionModelSearchField(query: $modelQuery)
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        if defaultNewSessionModelMatchesQuery {
                            modelPickerRow(id: "", label: defaultModelLabel)
                        }
                        ForEach(filteredNewSessionModels) { model in
                            modelPickerRow(id: model.id, label: model.label)
                        }
                        if providerModels.isEmpty {
                            Text("暂未加载到模型列表")
                                .font(.system(size: 12))
                                .foregroundColor(Theme.textSecondary)
                        } else if !defaultNewSessionModelMatchesQuery && filteredNewSessionModels.isEmpty {
                            Text("没有匹配的模型")
                                .font(.system(size: 12))
                                .foregroundColor(Theme.textSecondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 260)
            }
            .padding(12)
            .frame(width: 280)
            .background(Theme.workspaceBackground)
        }
        .onChange(of: showModelPicker) { open in
            if !open { modelQuery = "" }
        }
    }

    /// 工作目录保持单行主路径；最近目录进入菜单，避免把弹窗拉成长列表。
    private var cwdCard: some View {
        HStack(spacing: 0) {
            TextField("/path/to/project", text: $draft.cwd)
                .font(.system(size: 14, design: .monospaced))
                .textFieldStyle(.plain)
                .foregroundColor(Theme.textPrimary)
                .tint(Theme.wandAccent)
                .focused($focusedInput, equals: .cwd)
                .padding(.leading, 12)
                .padding(.vertical, 11)
            if !draft.recentPaths.isEmpty {
                Menu {
                    ForEach(draft.recentPaths.prefix(8)) { recent in
                        Button {
                            draft.cwd = recent.path
                        } label: {
                            if draft.cwd == recent.path {
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
                showDirectoryOptions = false
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

    private var firstMessageCard: some View {
        IMEAwareComposerTextView(
            text: $draft.firstMessage, placeholder: "描述你想完成的事…",
            isFocused: composerFocused, sendWithCommandEnter: true,
            onFocusChange: { composerFocused = $0 },
            onCompositionChange: { composing = $0 },
            onSubmit: prepareCreate, onHeightChange: { composerHeight = $0 },
            submitActionName: "启动会话"
        )
        .frame(height: max(104, min(220, composerHeight)))
        .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 12)
        .disabled(draft.creating)
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
        Toggle(isOn: $draft.fullAccessAcknowledged) {
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

    private var isExistingTask: Bool { draft.destination != "new" && draft.destination != "none" }

    private var readyToStart: Bool {
        !draft.loading && draft.loadError == nil && !draft.loadingTask && !draft.creating && !composing
            && (draft.destination == "new" || !draft.cwd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            && (!isExistingTask || draft.binding?.workspaceTaskId == draft.destination)
    }

    private var canCreate: Bool { readyToStart && (draft.mode != .fullAccess || draft.fullAccessAcknowledged) }

    private func chooseProvider(_ provider: Provider, userInitiated: Bool) {
        if userInitiated { draft.providerWasEdited = true }
        guard draft.provider != provider || !draft.initialized else { return }
        draft.provider = provider
        draft.selectedModel = ""
        let supported = ModeOption.supported(for: provider)
        let preferred = ModeOption(apiValue: draft.defaultMode) ?? .managed
        draft.mode = supported.contains(preferred) ? preferred : supported.contains(.managed) ? .managed : .fullAccess
        draft.thinkingEffort = draft.defaultThinkingEffort
        draft.fullAccessAcknowledged = false
    }

    private func selectDestination(_ destination: String) {
        if !isExistingTask { draft.unboundCwd = draft.cwd }
        draft.destination = destination
        draft.taskGeneration += 1
        draft.binding = nil
        draft.taskError = nil
        if destination == "new" || destination == "none" {
            draft.cwd = draft.unboundCwd
            draft.loadingTask = false
            return
        }
        let generation = draft.taskGeneration
        draft.loadingTask = true
        // 记下发起时的目录：任务详情返回时只在用户没动过这一栏的情况下写入。
        let cwdAtRequest = draft.cwd
        Task {
            do {
                let detail = try await api.getWorkspaceTask(taskId: destination)
                guard draft.taskGeneration == generation, draft.destination == destination else { return }
                draft.binding = WorkspaceBinding(workspaceId: detail.workspaceId, workspaceTaskId: detail.id, cwd: detail.cwd)
                // 等待期间用户改过目录就不静默覆盖（已有任务下这一栏是只读的，
                // 但其它写入路径不该被一个过期的响应盖掉）。
                if draft.cwd.isEmpty || Self.isSamePath(draft.cwd, cwdAtRequest) {
                    draft.cwd = detail.cwd
                }
                draft.loadingTask = false
                if !draft.providerWasEdited {
                    let preferred = draft.workspaces.first(where: { $0.id == detail.workspaceId })?.defaultProvider?.rawValue
                        ?? (detail.workspaceId == draft.context.workspaceId ? draft.context.workspaceDefaultProvider : nil)
                        ?? draft.defaultProvider
                    chooseProvider(Provider(rawValue: preferred) ?? .claude, userInitiated: false)
                }
                if let warning = detail.worktreeError { draft.errorMessage = warning }
            } catch {
                guard draft.taskGeneration == generation, draft.destination == destination else { return }
                draft.loadingTask = false
                draft.taskError = "无法读取任务目录：" + error.localizedDescription
            }
        }
    }

    /// 路径比较只用于判断「用户是否改过目录」，容忍多余空格与 `..`、重复斜杠。
    private static func isSamePath(_ lhs: String, _ rhs: String) -> Bool {
        let left = lhs.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = rhs.trimmingCharacters(in: .whitespacesAndNewlines)
        return (left as NSString).standardizingPath == (right as NSString).standardizingPath
    }

    private func loadInitial() async {
        if draft.initialized {
            await draft.refreshOptions(api: api)
            return
        }
        draft.loading = true
        draft.loadError = nil
        do {
            async let configRequest = api.serverConfig()
            async let groupsRequest = api.listTaskGroups()
            async let workspacesRequest = api.listWorkspaces()
            async let modelsRequest = try? api.models()
            async let recentRequest = try? api.recentPaths()
            let (config, groups, workspaces, models, recent) = try await (
                configRequest, groupsRequest, workspacesRequest, modelsRequest, recentRequest
            )
            guard !Task.isCancelled else { return }
            draft.updateOptions(groups: groups, workspaces: workspaces)
            draft.defaultProvider = config.defaultProvider ?? "claude"
            draft.defaultMode = config.defaultMode ?? "managed"
            draft.defaultThinkingEffort = config.defaultThinkingEffort ?? "off"
            let preferredProvider = draft.context.workspaceDefaultProvider
                ?? workspaces.first(where: { $0.id == draft.context.workspaceId })?.defaultProvider?.rawValue
                ?? draft.defaultProvider
            chooseProvider(Provider(rawValue: preferredProvider) ?? .claude, userInitiated: false)
            draft.sessionType = config.defaultSessionKind == "pty" ? .pty : .structured
            draft.worktree = config.defaultTaskWorktree != false
            draft.serverDefaultModels = config.defaultModels ?? ProviderDefaultModels(
                claude: config.defaultModel, codex: config.defaultCodexModel,
                opencode: config.defaultOpenCodeModel, grok: config.defaultGrokModel,
                qoder: config.defaultQoderModel, pi: config.defaultPiModel
            )
            if let models {
                draft.availableModels = models.models
                draft.codexModels = models.codexModels
                draft.openCodeModels = models.opencodeModels ?? []
                draft.grokModels = models.grokModels ?? []
                draft.qoderModels = models.qoderModels ?? []
                draft.piModels = models.piModels ?? []
                if let defaults = models.defaultModels { draft.serverDefaultModels = defaults }
            }
            draft.recentPaths = recent ?? []
            if draft.cwd.isEmpty {
                draft.cwd = (config.defaultCwd?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
                    ?? draft.recentPaths.first?.path ?? ""
            }
            draft.unboundCwd = draft.cwd
            draft.initialized = true
            draft.loading = false
            if isExistingTask { selectDestination(draft.destination) }
            composerFocused = true
        } catch {
            guard !Task.isCancelled else { return }
            draft.loading = false
            draft.loadError = "无法读取默认配置或任务列表：" + error.localizedDescription
        }
    }

    private func create() {
        guard canCreate else { return }
        let prompt = draft.firstMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.creating = true
        draft.errorMessage = nil
        Task {
            do {
                let path = draft.cwd.trimmingCharacters(in: .whitespacesAndNewlines)
                let creatingNewTask = draft.destination == "new"
                if draft.destination == "new" {
                    let creation: WorkspaceTaskCreation
                    let workspace = draft.workspaces.first(where: { $0.id == draft.context.workspaceId })
                    if let workspace, (workspace.cwd as NSString).standardizingPath == (path as NSString).standardizingPath {
                        creation = try await api.createWorkspaceTask(workspaceId: workspace.id, name: draft.taskName,
                            baseRef: nil, worktree: draft.worktree, cwd: nil)
                    } else {
                        creation = try await api.createStandaloneTask(name: draft.taskName,
                            cwd: path.isEmpty ? nil : path, worktree: path.isEmpty ? false : draft.worktree)
                    }
                    // Keep the created task on session failure, so Retry never creates a duplicate task.
                    draft.tasks.append(SessionTaskOption(id: creation.id, workspaceId: creation.workspaceId,
                        name: creation.name, workspaceName: workspace?.name ?? "", cwd: creation.cwd))
                    draft.destination = creation.id
                    draft.cwd = creation.cwd
                    draft.binding = WorkspaceBinding(workspaceId: creation.workspaceId,
                        workspaceTaskId: creation.id, cwd: creation.cwd)
                    await workspaceStore?.loadTaskGroups(force: true)
                }
                let snapshot: SessionSnapshot
                switch draft.sessionType {
                case .structured:
                    snapshot = try await api.createStructuredSession(provider: draft.provider.rawValue,
                        cwd: draft.cwd, mode: draft.mode.apiValue, model: draft.selectedModel,
                        thinkingEffort: draft.thinkingEffort, prompt: prompt.isEmpty ? nil : prompt,
                        workspaceBinding: draft.binding)
                case .pty:
                    snapshot = try await api.createPtySession(provider: draft.provider.rawValue,
                        cwd: draft.cwd, mode: draft.mode.apiValue, model: draft.selectedModel,
                        thinkingEffort: draft.thinkingEffort, initialInput: prompt.isEmpty ? nil : prompt,
                        workspaceBinding: draft.binding)
                }
                // Remember preferences after creation; a preference failure must not hide a live session.
                try? await api.updateNewSessionDefaults(mode: draft.mode.apiValue,
                    model: draft.selectedModel.isEmpty ? nil : draft.selectedModel,
                    provider: draft.provider.rawValue, thinkingEffort: draft.thinkingEffort,
                    defaultSessionKind: draft.sessionType.rawValue)
                if creatingNewTask {
                    try? await api.updateCreationDefaults(defaultProvider: nil, defaultSessionKind: nil,
                                                          defaultTaskWorktree: draft.worktree)
                }
                draft.creating = false
                NotificationCenter.default.post(name: .wandRefreshLists, object: nil)
                onCreated(snapshot)
            } catch {
                draft.creating = false
                draft.errorMessage = error.localizedDescription
            }
        }
    }
}

/// 首页和会话中的模型搜索共用焦点、清空和输入表面。
struct SessionModelSearchField: View {
    @Binding var query: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Theme.textMuted)
            TextField("搜索模型", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($focused)
                .accessibilityLabel("搜索模型")
            Button {
                query = ""
                focused = true
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textMuted)
                    .frame(width: 22, height: 26)
            }
            .buttonStyle(DesktopNavigationButtonStyle())
            .opacity(query.isEmpty ? 0 : 1)
            .disabled(query.isEmpty)
            .accessibilityHidden(query.isEmpty)
            .accessibilityLabel("清除模型搜索")
        }
        .padding(.horizontal, 9)
        .frame(height: 34)
        .wandInputSurface(focused: focused, cornerRadius: Theme.Radius.control)
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
                    .buttonStyle(WandSecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .wandGlass(.chrome)
            pathHeader
            Rectangle().fill(Theme.border).frame(height: 0.5)
            if loading {
                Spacer()
                ProgressView().tint(Theme.wandAccent)
                Spacer()
            } else if let errorMessage {
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 24))
                        .foregroundColor(Theme.warning)
                    Text(errorMessage)
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                    Button("重试") { Task { await load() } }
                        .buttonStyle(WandSecondaryButtonStyle())
                }
                .padding(24)
                Spacer()
            } else {
                directoryList
            }
            Rectangle().fill(Theme.border).frame(height: 0.5)
            HStack {
                Spacer()
                Button("选择此目录") { onPick(currentPath) }
                    .buttonStyle(WandPrimaryButtonStyle())
            }
            .padding(16)
            .background(Theme.workspaceBackground)
        }
        .frame(minWidth: 620, minHeight: 520)
        .background(Theme.workspaceBackground)
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
            .buttonStyle(WandIconButtonStyle())
            .accessibilityLabel("上一级目录")
            .help("上一级目录")
            Text(currentPath)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.head)
                .help(currentPath)
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
                .buttonStyle(DesktopNavigationButtonStyle())
                .listRowBackground(Theme.workspaceBackground)
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
