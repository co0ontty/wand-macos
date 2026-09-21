import SwiftUI

struct TaskBoardView: View {
    let api: WandAPI
    var linkedWorkspaceId: String? = nil
    let onOpenSession: (String) -> Void
    var onDismiss: (() -> Void)? = nil
    var embedded = false

    @Environment(\.dismiss) private var dismiss
    @State private var tasks: [WandBoardTask] = []
    @State private var workspaces: [Workspace] = []
    @State private var catalog: ModelsResponse?
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var query = ""
    @State private var filterWorkspaceId = ""
    @State private var selected: WandBoardTask?
    @State private var showCreate = false
    // 从哪一列点开的「新建」决定初始状态：待办 = 只创建，进行中 = 创建并指派。
    @State private var createStatus = "todo"
    @State private var busy = false
    @State private var lastAgent = WandBoardTaskAgent.default
    @State private var archiveExpanded = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header.frame(maxWidth: embedded ? 1120 : .infinity)
            Rectangle().fill(Theme.border).frame(height: 0.5)
            Group {
                if let selected {
                    TaskBoardDetailView(
                        task: selected,
                        workspaces: workspaces,
                        catalog: catalog,
                        lastAgent: lastAgent,
                        busy: busy,
                        onPatch: { body in await mutate { _ = try await api.updateBoardTask(id: selected.id, body: body) } },
                        onRemember: rememberAgent,
                        onDispatch: { agent in
                            rememberAgent(agent)
                            await mutate {
                                _ = try await api.updateBoardTask(id: selected.id, body: ["agent": agent.jsonObject()])
                                let result = try await api.dispatchBoardTask(id: selected.id, agent: agent)
                                if !result.sessionId.isEmpty { onOpenSession(result.sessionId) }
                            }
                        },
                        onDelete: {
                            await mutate {
                                try await api.deleteBoardTask(id: selected.id)
                                self.selected = nil
                            }
                        },
                        onOpenSession: onOpenSession
                    )
                } else if loading && tasks.isEmpty {
                    VStack(spacing: 12) {
                        ProgressView().tint(Theme.wandAccent)
                        Text("正在加载任务…")
                            .font(.system(size: 13))
                            .foregroundColor(Theme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    listContent.frame(maxWidth: embedded ? 1120 : .infinity)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(minWidth: embedded ? 0 : 640, minHeight: embedded ? 0 : 520)
        .background(Theme.workspaceBackground)
        .wandMotion(value: archiveExpanded, layout: true)
        .sheet(isPresented: $showCreate) {
            TaskBoardCreateView(
                workspaces: workspaces,
                catalog: catalog,
                lastAgent: lastAgent,
                defaultWorkspaceId: filterWorkspaceId,
                initialStatus: createStatus
            ) { title, description, status, priority, workspaceId, agent in
                await mutate {
                    let created = try await api.createBoardTask(
                        title: title,
                        description: description,
                        status: status,
                        priority: priority,
                        workspaceId: workspaceId,
                        agent: agent
                    )
                    rememberAgent(agent)
                    showCreate = false
                    selected = created
                    // 只有「进行中」列的新建才顺带第一次指派；「待办」列只创建任务。
                    if wandBoardCreateDispatches(status: status),
                       !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        _ = try? await api.dispatchBoardTask(id: created.id, agent: agent)
                        await refresh(showProgress: false)
                    }
                    if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       created.titleSource == "auto" {
                        Task { await awaitGeneratedTitle(taskId: created.id, placeholder: created.title) }
                    }
                }
            }
        }
        .onAppear {
            if filterWorkspaceId.isEmpty { filterWorkspaceId = linkedWorkspaceId ?? "" }
            Task {
                await refresh(showProgress: true)
                workspaces = (try? await api.listWorkspaces()) ?? []
                catalog = try? await api.models()
                lastAgent = (try? await api.boardTaskAgentDefaults()) ?? .default
            }
        }
        .alert(item: Binding(
            get: { errorMessage.map { IdentifiedMessage(id: $0, text: $0) } },
            set: { errorMessage = $0?.text }
        )) { item in
            Alert(title: Text("任务操作失败"), message: Text(item.text), dismissButton: .default(Text("好")))
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            if !embedded || selected != nil {
                Button {
                    if selected != nil { selected = nil } else { close() }
                } label: {
                    Label(selected == nil ? "关闭" : "返回", systemImage: selected == nil ? "xmark" : "chevron.left")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 8)
                        .frame(height: 30)
                }
                .buttonStyle(DesktopNavigationButtonStyle())
            }
            if let selected {
                Text(selected.title)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                    .help(selected.title)
            } else if !embedded {
                Text("任务看板")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
            } else {
                Text("安排工作，跟踪进度")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.textSecondary)
            }
            Spacer(minLength: 12)
            if selected == nil {
                Button { Task { await refresh(showProgress: false) } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(WandIconButtonStyle())
                .help("刷新任务")
                .accessibilityLabel("刷新任务")
                Button("新建任务") { openCreate("todo") }
                    .buttonStyle(WandPrimaryButtonStyle())
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private func openCreate(_ status: String) {
        createStatus = status
        showCreate = true
    }

    private var visibleTasks: [WandBoardTask] {
        tasks.filter { task in
            let haystack = "\(task.title) \(task.description) \(task.identifier) \(task.workspace?.name ?? "")"
            let matchesQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || haystack.localizedCaseInsensitiveContains(query)
            let matchesWorkspace = filterWorkspaceId.isEmpty || task.workspaceId == filterWorkspaceId
            return matchesQuery && matchesWorkspace
        }
    }

    private var listContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(Theme.textMuted)
                    TextField("搜索任务", text: $query)
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                    Button { query = ""; searchFocused = true } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(WandIconButtonStyle())
                    .opacity(query.isEmpty ? 0 : 1)
                    .disabled(query.isEmpty)
                    .accessibilityHidden(query.isEmpty)
                    .accessibilityLabel("清除任务搜索")
                    .help("清除搜索")
                }
                .font(.system(size: 13))
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .wandInputSurface(focused: searchFocused, cornerRadius: Theme.Radius.control)
                Picker("项目", selection: $filterWorkspaceId) {
                    Text("所有项目").tag("")
                    ForEach(workspaces) { workspace in
                        Text(workspace.name).tag(workspace.id)
                    }
                }
                .frame(width: 220)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 8)
            List {
                ForEach(WandBoardStatus.allCases) { status in
                    let items = visibleTasks.filter { $0.status == status.rawValue }
                    let archived = status == .done
                        ? visibleTasks.filter { $0.status == "archived" }
                        : []
                    Section(header: HStack(spacing: 8) {
                        Text(status.label)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Theme.textPrimary)
                        Text("\(items.count)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(Theme.textMuted)
                        Spacer()
                        Button {
                            openCreate(status.rawValue)
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 11, weight: .semibold))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(WandIconButtonStyle())
                        .help("在\(status.label)中新建任务")
                        .accessibilityLabel("在\(status.label)中新建任务")
                    }) {
                        if items.isEmpty && archived.isEmpty {
                            Text(status.empty)
                                .font(.system(size: 12))
                                .foregroundColor(Theme.textSecondary)
                                .padding(.vertical, 12)
                        } else {
                            ForEach(items) { task in
                                Button {
                                    selected = task
                                } label: {
                                    TaskBoardRow(task: task)
                                }
                                .buttonStyle(DesktopNavigationButtonStyle())
                            }
                            if !archived.isEmpty {
                                DisclosureGroup(isExpanded: Binding(
                                    get: { archiveExpanded || !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty },
                                    set: { archiveExpanded = $0 }
                                )) {
                                    ForEach(archived) { task in
                                        Button {
                                            selected = task
                                        } label: {
                                            TaskBoardRow(task: task)
                                        }
                                        .buttonStyle(DesktopNavigationButtonStyle())
                                    }
                                } label: {
                                    Label("归档任务  \(archived.count)", systemImage: "folder")
                                        .foregroundColor(Theme.textMuted)
                                }
                            }
                        }
                    }
                    .listRowBackground(Theme.workspaceBackground)
                }
            }
            .listStyle(.plain)
            .modifier(TaskBoardListSurface(embedded: true))
            .padding(.horizontal, 12)
        }
    }

    private func close() {
        if let onDismiss { onDismiss() } else { dismiss() }
    }

    private func rememberAgent(_ agent: WandBoardTaskAgent) {
        lastAgent = agent
        Task { _ = try? await api.saveBoardTaskAgentDefaults(agent) }
    }

    private func refresh(showProgress: Bool) async {
        if showProgress { loading = true }
        do {
            tasks = try await api.listBoardTasks()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        loading = false
    }

    /**
     * 标题留空时标题由服务端后台生成。创建响应里只有描述首行占位，
     * 这里短轮询几次，拿到真标题就刷新列表和详情；一直没变就保留占位。
     */
    private func awaitGeneratedTitle(taskId: String, placeholder: String) async {
        for delayMs in [1_200, 2_000, 3_000, 5_000, 8_000] {
            // 部署目标是 macOS 12，不能用只在新系统可用的 Task.sleep(for:)。
            try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
            guard let task = try? await api.getBoardTask(id: taskId) else { continue }
            guard !task.title.isEmpty, task.title != placeholder else { continue }
            await refresh(showProgress: false)
            if let id = selected?.id {
                selected = tasks.first(where: { $0.id == id }) ?? selected
            }
            return
        }
    }

    private func mutate(_ work: () async throws -> Void) async {
        busy = true
        do {
            try await work()
            await refresh(showProgress: false)
            if let id = selected?.id {
                selected = tasks.first(where: { $0.id == id }) ?? selected
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        busy = false
    }
}

private struct IdentifiedMessage: Identifiable {
    let id: String
    let text: String
}

private struct TaskBoardRow: View {
    let task: WandBoardTask

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text(task.identifier.isEmpty ? String(task.id.prefix(8)) : task.identifier)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(Theme.textMuted)
                .frame(width: 72, alignment: .leading)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 7) {
                Text(task.title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(2)
                HStack(spacing: 10) {
                    Text(task.workspace?.name ?? "未指定项目")
                        .lineLimit(1)
                    if task.priority != "none" {
                        Text(WandBoardPriority(rawValue: task.priority)?.label ?? task.priority)
                            .foregroundColor(Theme.warning)
                    }
                    Text(task.agent.map { wandBoardProviderLabel($0.provider) } ?? "未指派")
                }
                .font(.system(size: 11))
                .foregroundColor(Theme.textSecondary)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(Theme.textMuted)
                .padding(.top, 4)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private struct TaskBoardDetailView: View {
    let task: WandBoardTask
    let workspaces: [Workspace]
    let catalog: ModelsResponse?
    let lastAgent: WandBoardTaskAgent
    let busy: Bool
    let onPatch: ([String: Any]) async -> Void
    let onRemember: (WandBoardTaskAgent) -> Void
    let onDispatch: (WandBoardTaskAgent) async -> Void
    let onDelete: () async -> Void
    let onOpenSession: (String) -> Void

    @State private var title: String
    @State private var description: String
    @State private var agent: WandBoardTaskAgent
    @State private var attributesExpanded = false
    @FocusState private var focusedField: String?

    init(
        task: WandBoardTask,
        workspaces: [Workspace],
        catalog: ModelsResponse?,
        lastAgent: WandBoardTaskAgent,
        busy: Bool,
        onPatch: @escaping ([String: Any]) async -> Void,
        onRemember: @escaping (WandBoardTaskAgent) -> Void,
        onDispatch: @escaping (WandBoardTaskAgent) async -> Void,
        onDelete: @escaping () async -> Void,
        onOpenSession: @escaping (String) -> Void
    ) {
        self.task = task
        self.workspaces = workspaces
        self.catalog = catalog
        self.lastAgent = lastAgent
        self.busy = busy
        self.onPatch = onPatch
        self.onRemember = onRemember
        self.onDispatch = onDispatch
        self.onDelete = onDelete
        self.onOpenSession = onOpenSession
        _title = State(initialValue: task.title)
        _description = State(initialValue: task.description)
        _agent = State(initialValue: task.agent ?? lastAgent)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                TaskBoardFormSection(title: "任务内容") {
                    TextField("任务标题", text: $title)
                        .textFieldStyle(.plain)
                        .font(.system(size: 16, weight: .medium))
                        .focused($focusedField, equals: "title")
                        .padding(12)
                        .wandInputSurface(focused: focusedField == "title", cornerRadius: Theme.Radius.control)
                    TextEditor(text: $description)
                        .font(.system(size: 13))
                        .lineSpacing(4)
                        .focused($focusedField, equals: "description")
                        .modifier(TaskBoardListSurface(embedded: true))
                        .padding(10)
                        .frame(minHeight: 130, idealHeight: 170)
                        .wandInputSurface(focused: focusedField == "description", cornerRadius: Theme.Radius.control)
                        .accessibilityLabel("任务描述")
                    Button("保存标题与描述") {
                        Task {
                            await onPatch([
                                "title": title.trimmingCharacters(in: .whitespacesAndNewlines),
                                "description": description,
                            ])
                        }
                    }
                    .buttonStyle(WandSecondaryButtonStyle())
                    .disabled(busy || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                DisclosureGroup("任务属性", isExpanded: $attributesExpanded) {
                    VStack(alignment: .leading, spacing: 14) {
                        Picker(
                            "状态",
                            selection: Binding(
                                get: { task.status },
                                set: { status in Task { await onPatch(["status": status]) } }
                            )
                        ) {
                            ForEach(WandBoardStatus.allCases) { status in
                                Text(status.label).tag(status.rawValue)
                            }
                        }
                        Picker(
                            "优先级",
                            selection: Binding(
                                get: { task.priority },
                                set: { priority in Task { await onPatch(["priority": priority]) } }
                            )
                        ) {
                            ForEach(WandBoardPriority.allCases) { priority in
                                Text(priority.label).tag(priority.rawValue)
                            }
                        }
                        Picker(
                            "项目",
                            selection: Binding(
                                get: { task.workspaceId ?? "" },
                                set: { value in
                                    Task { await onPatch(["workspaceId": value.isEmpty ? NSNull() : value]) }
                                }
                            )
                        ) {
                            Text("不指定项目（使用全局目录）").tag("")
                            ForEach(workspaces) { workspace in
                                Text(workspace.name).tag(workspace.id)
                            }
                        }
                    }
                    .padding(.top, 12)
                }
                .font(.system(size: 13, weight: .medium))
                TaskBoardFormSection(title: task.sessions.isEmpty ? "指派工具" : "继续指派") {
                    Picker(
                        "工具",
                        selection: Binding(
                            get: { agent.provider },
                            set: { provider in
                                agent.provider = provider
                                let options = wandBoardModelOptions(from: catalog, provider: provider)
                                if !options.contains(where: { $0.id == agent.model }) {
                                    agent.model = options.first?.id ?? "default"
                                }
                                onRemember(agent)
                            }
                        )
                    ) {
                        ForEach(wandBoardProviders, id: \.self) { provider in
                            Text(wandBoardProviderLabel(provider)).tag(provider)
                        }
                    }
                    Picker(
                        "模型",
                        selection: Binding(
                            get: { agent.model },
                            set: { model in
                                agent.model = model
                                onRemember(agent)
                            }
                        )
                    ) {
                        ForEach(wandBoardModelOptions(from: catalog, provider: agent.provider), id: \.id) { option in
                            Text(option.label).tag(option.id)
                        }
                    }
                    Picker(
                        "思考深度",
                        selection: Binding(
                            get: { agent.thinkingEffort },
                            set: { effort in
                                agent.thinkingEffort = effort
                                onRemember(agent)
                            }
                        )
                    ) {
                        ForEach(wandBoardEfforts, id: \.self) { effort in
                            Text(wandBoardEffortLabel(effort)).tag(effort)
                        }
                    }
                    Button(task.sessions.isEmpty ? "派发 Agent" : "再派发一次") {
                        Task { await onDispatch(agent) }
                    }
                    .buttonStyle(WandPrimaryButtonStyle())
                    .disabled(busy)
                }
                TaskBoardFormSection(title: "相关会话") {
                    let groups = wandBoardSessionGroups(sessions: task.sessions, assigned: task.agent)
                    if groups.isEmpty {
                        Text("还没有指派 Agent。描述会作为第一次派发的任务内容。")
                            .foregroundColor(Theme.textMuted)
                    } else {
                        ForEach(groups) { group in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(wandBoardProviderLabel(group.provider))
                                    .font(.subheadline.weight(.semibold))
                                if group.sessions.isEmpty {
                                    Text("已指派，等待派发")
                                        .font(.caption)
                                        .foregroundColor(Theme.textMuted)
                                } else {
                                    ForEach(group.sessions) { session in
                                        Button {
                                            onOpenSession(session.id)
                                        } label: {
                                            HStack {
                                                BrandLogo(provider: session.provider, color: Theme.textPrimary)
                                                    .frame(width: 14, height: 14)
                                                VStack(alignment: .leading, spacing: 2) {
                                                    Text(
                                                        session.title.isEmpty
                                                            ? wandBoardProviderLabel(session.provider) : session.title)
                                                    Text(
                                                        [session.model, session.status].filter { !$0.isEmpty }.joined(
                                                            separator: " · ")
                                                    )
                                                    .font(.caption)
                                                    .foregroundColor(Theme.textMuted)
                                                }
                                                Spacer()
                                                Image(systemName: "arrow.up.right")
                                                    .font(.system(size: 10))
                                                    .foregroundColor(Theme.textMuted)
                                            }
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 10)
                                            .contentShape(Rectangle())
                                        }
                                        .buttonStyle(DesktopNavigationButtonStyle())
                                    }
                                }
                            }
                        }
                    }
                }
                HStack {
                    Spacer()
                    Button("归档") {
                        Task { await onDelete() }
                    }
                    .buttonStyle(WandSecondaryButtonStyle())
                    .foregroundColor(Theme.danger)
                    .disabled(busy)
                }
            }
            .font(.system(size: 13))
            .foregroundColor(Theme.textPrimary)
            .frame(maxWidth: 760, alignment: .leading)
            .padding(32)
            .frame(maxWidth: .infinity)
            .wandMotion(value: attributesExpanded, layout: true)
        }
        .background(Theme.workspaceBackground)
        .onChange(of: task.id) { _ in
            title = task.title
            description = task.description
            agent = task.agent ?? lastAgent
        }
    }
}

private struct TaskBoardCreateView: View {
    let workspaces: [Workspace]
    let catalog: ModelsResponse?
    let lastAgent: WandBoardTaskAgent
    let defaultWorkspaceId: String
    let onCreate: (String, String, String, String, String?, WandBoardTaskAgent) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var description = ""
    @State private var status: String
    @State private var priority = "none"
    @State private var workspaceId = ""
    @State private var agent: WandBoardTaskAgent
    @State private var creating = false
    @State private var optionsExpanded = false
    @FocusState private var focusedField: String?

    init(
        workspaces: [Workspace],
        catalog: ModelsResponse?,
        lastAgent: WandBoardTaskAgent,
        defaultWorkspaceId: String,
        initialStatus: String = "todo",
        onCreate: @escaping (String, String, String, String, String?, WandBoardTaskAgent) async -> Void
    ) {
        self.workspaces = workspaces
        self.catalog = catalog
        self.lastAgent = lastAgent
        self.defaultWorkspaceId = defaultWorkspaceId
        self.onCreate = onCreate
        _status = State(initialValue: initialStatus)
        _agent = State(initialValue: lastAgent)
    }

    /// 「进行中」列的新建代表已经决定要跑，所以创建后立刻派 Agent；其他列只落库。
    private var dispatches: Bool { wandBoardCreateDispatches(status: status) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("新建任务")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .windowDrag()
            Rectangle().fill(Theme.border).frame(height: 0.5)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    TaskBoardFormSection(title: "任务内容") {
                        TextField("任务标题（可选）", text: $title, prompt: Text("不填写则按描述自动生成"))
                            .textFieldStyle(.plain)
                            .focused($focusedField, equals: "title")
                            .padding(12)
                            .wandInputSurface(focused: focusedField == "title", cornerRadius: Theme.Radius.control)
                        Text(dispatches ? "描述将作为首次指派的任务内容" : "描述（只创建任务）")
                            .font(.system(size: 12))
                            .foregroundColor(Theme.textSecondary)
                        TextEditor(text: $description)
                            .font(.system(size: 13))
                            .lineSpacing(4)
                            .focused($focusedField, equals: "description")
                            .modifier(TaskBoardListSurface(embedded: true))
                            .padding(10)
                            .frame(height: 132)
                            .wandInputSurface(
                                focused: focusedField == "description", cornerRadius: Theme.Radius.control
                            )
                            .accessibilityLabel("任务描述")
                    }
                    Picker("目录", selection: $workspaceId) {
                        Text("不指定目录（使用全局目录）").tag("")
                        ForEach(workspaces) { workspace in
                            Text(workspace.name).tag(workspace.id)
                        }
                    }
                    if dispatches {
                        Picker(
                            "第一次指派",
                            selection: Binding(
                                get: { agent.provider },
                                set: { provider in
                                    agent.provider = provider
                                    let options = wandBoardModelOptions(from: catalog, provider: provider)
                                    if !options.contains(where: { $0.id == agent.model }) {
                                        agent.model = options.first?.id ?? "default"
                                    }
                                }
                            )
                        ) {
                            ForEach(wandBoardProviders, id: \.self) { provider in
                                Text(wandBoardProviderLabel(provider)).tag(provider)
                            }
                        }
                        Picker(
                            "模型",
                            selection: Binding(
                                get: { agent.model },
                                set: { agent.model = $0 }
                            )
                        ) {
                            ForEach(wandBoardModelOptions(from: catalog, provider: agent.provider), id: \.id) {
                                option in
                                Text(option.label).tag(option.id)
                            }
                        }
                        Picker(
                            "思考深度",
                            selection: Binding(
                                get: { agent.thinkingEffort },
                                set: { agent.thinkingEffort = $0 }
                            )
                        ) {
                            ForEach(wandBoardEfforts, id: \.self) { effort in
                                Text(wandBoardEffortLabel(effort)).tag(effort)
                            }
                        }
                    }
                    DisclosureGroup("状态与优先级", isExpanded: $optionsExpanded) {
                        VStack(alignment: .leading, spacing: 14) {
                            Picker("状态", selection: $status) {
                                ForEach(WandBoardStatus.allCases) { item in
                                    Text(item.label).tag(item.rawValue)
                                }
                            }
                            Picker("优先级", selection: $priority) {
                                ForEach(WandBoardPriority.allCases) { item in
                                    Text(item.label).tag(item.rawValue)
                                }
                            }
                        }
                        .padding(.top, 12)
                    }
                }
                .font(.system(size: 13))
                .foregroundColor(Theme.textPrimary)
                .padding(24)
                .disabled(creating)
                .wandMotion(value: optionsExpanded, layout: true)
                .wandMotion(value: dispatches, layout: true)
            }
            Rectangle().fill(Theme.border).frame(height: 0.5)
            HStack(spacing: 8) {
                Spacer()
                Button("取消") { dismiss() }
                    .buttonStyle(WandSecondaryButtonStyle())
                    .disabled(creating)
                Button {
                    guard !creating else { return }
                    creating = true
                    Task {
                        await onCreate(
                            title.trimmingCharacters(in: .whitespacesAndNewlines),
                            description, status, priority,
                            workspaceId.isEmpty ? nil : workspaceId, agent
                        )
                        creating = false
                    }
                } label: {
                    Text(
                        creating
                            ? "创建中…"
                            : (dispatches && !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "创建并指派" : "创建任务")
                    )
                    .frame(minWidth: 88)
                }
                .buttonStyle(WandPrimaryButtonStyle())
                .disabled(
                    creating
                        || (title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            && description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                )
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 560)
        .frame(minHeight: 460, idealHeight: 540, maxHeight: 580)
        .background(Theme.workspaceBackground)
        .hideNativeTitleBar()
        .onAppear { workspaceId = defaultWorkspaceId }
    }
}

private struct TaskBoardFormSection<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Theme.textSecondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/**
 * 新建任务是否顺带完成第一次指派。
 * 「待办」列只创建任务；「进行中」列代表已经决定要跑，所以创建后立刻派给所选 Agent。
 */
func wandBoardCreateDispatches(status: String) -> Bool { status == "doing" }


private struct TaskBoardListSurface: ViewModifier {
    let embedded: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 13.0, *), embedded {
            content.scrollContentBackground(.hidden)
                .background(Theme.workspaceBackground)
        } else {
            content
        }
    }
}
