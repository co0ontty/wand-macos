import SwiftUI

struct TaskBoardView: View {
    let api: WandAPI
    var linkedWorkspaceId: String? = nil
    let onOpenSession: (String) -> Void
    var onDismiss: (() -> Void)? = nil

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
    @State private var busy = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                if let selected {
                    TaskBoardDetailView(
                        task: selected,
                        workspaces: workspaces,
                        catalog: catalog,
                        busy: busy,
                        onPatch: { body in await mutate { _ = try await api.updateBoardTask(id: selected.id, body: body) } },
                        onDispatch: { agent in
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
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    listContent
                }
            }
        }
        .frame(minWidth: 640, minHeight: 520)
        .background(Theme.background)
        .sheet(isPresented: $showCreate) {
            TaskBoardCreateView(
                workspaces: workspaces,
                defaultWorkspaceId: filterWorkspaceId
            ) { title, description, status, priority, workspaceId in
                await mutate {
                    let created = try await api.createBoardTask(
                        title: title,
                        description: description,
                        status: status,
                        priority: priority,
                        workspaceId: workspaceId
                    )
                    showCreate = false
                    selected = created
                }
            }
        }
        .onAppear {
            if filterWorkspaceId.isEmpty { filterWorkspaceId = linkedWorkspaceId ?? "" }
            Task {
                await refresh(showProgress: true)
                workspaces = (try? await api.listWorkspaces()) ?? []
                catalog = try? await api.models()
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
        HStack(spacing: 10) {
            Button(selected == nil ? "关闭" : "返回") {
                if selected != nil { selected = nil } else { close() }
            }
            Text(selected?.title ?? "任务管理")
                .font(.headline)
            Spacer()
            if selected == nil {
                Button("刷新") { Task { await refresh(showProgress: false) } }
                Button("新建") { showCreate = true }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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
                TextField("搜索任务", text: $query)
                    .textFieldStyle(.roundedBorder)
                Picker("项目", selection: $filterWorkspaceId) {
                    Text("所有项目").tag("")
                    ForEach(workspaces) { workspace in
                        Text(workspace.name).tag(workspace.id)
                    }
                }
                .frame(width: 220)
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            List {
                ForEach(WandBoardStatus.allCases) { status in
                    let items = visibleTasks.filter { $0.status == status.rawValue }
                        .sorted { lhs, rhs in
                            if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
                            return lhs.updatedAt > rhs.updatedAt
                        }
                    Section(header: Text("\(status.label)  \(items.count)")) {
                        if items.isEmpty {
                            Text(status.empty).foregroundColor(Theme.textMuted)
                        } else {
                            ForEach(items) { task in
                                Button {
                                    selected = task
                                } label: {
                                    TaskBoardRow(task: task)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
    }

    private func close() {
        if let onDismiss { onDismiss() } else { dismiss() }
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
        VStack(alignment: .leading, spacing: 4) {
            Text(task.identifier.isEmpty ? String(task.id.prefix(8)) : task.identifier)
                .font(.caption)
                .foregroundColor(Theme.textMuted)
            Text(task.title)
                .font(.headline)
                .foregroundColor(Theme.textPrimary)
                .lineLimit(2)
            HStack(spacing: 8) {
                Text(task.workspace?.name ?? "未指定项目")
                if task.priority != "none" {
                    Text(WandBoardPriority(rawValue: task.priority)?.label ?? task.priority)
                        .foregroundColor(Theme.warning)
                }
                Text(task.agent.map { wandBoardProviderLabel($0.provider) } ?? "未指派")
            }
            .font(.caption)
            .foregroundColor(Theme.textMuted)
        }
        .padding(.vertical, 4)
    }
}

private struct TaskBoardDetailView: View {
    let task: WandBoardTask
    let workspaces: [Workspace]
    let catalog: ModelsResponse?
    let busy: Bool
    let onPatch: ([String: Any]) async -> Void
    let onDispatch: (WandBoardTaskAgent) async -> Void
    let onDelete: () async -> Void
    let onOpenSession: (String) -> Void

    @State private var title: String
    @State private var description: String
    @State private var agent: WandBoardTaskAgent

    init(
        task: WandBoardTask,
        workspaces: [Workspace],
        catalog: ModelsResponse?,
        busy: Bool,
        onPatch: @escaping ([String: Any]) async -> Void,
        onDispatch: @escaping (WandBoardTaskAgent) async -> Void,
        onDelete: @escaping () async -> Void,
        onOpenSession: @escaping (String) -> Void
    ) {
        self.task = task
        self.workspaces = workspaces
        self.catalog = catalog
        self.busy = busy
        self.onPatch = onPatch
        self.onDispatch = onDispatch
        self.onDelete = onDelete
        self.onOpenSession = onOpenSession
        _title = State(initialValue: task.title)
        _description = State(initialValue: task.description)
        _agent = State(initialValue: task.agent ?? .default)
    }

    var body: some View {
        Form {
            Section(header: Text("内容")) {
                TextField("任务标题", text: $title)
                TextField("描述", text: $description)
                Button("保存标题与描述") {
                    Task { await onPatch(["title": title.trimmingCharacters(in: .whitespacesAndNewlines), "description": description]) }
                }
                .disabled(busy || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Section(header: Text("属性")) {
                Picker("状态", selection: Binding(
                    get: { task.status },
                    set: { status in Task { await onPatch(["status": status]) } }
                )) {
                    ForEach(WandBoardStatus.allCases) { status in
                        Text(status.label).tag(status.rawValue)
                    }
                }
                Picker("优先级", selection: Binding(
                    get: { task.priority },
                    set: { priority in Task { await onPatch(["priority": priority]) } }
                )) {
                    ForEach(WandBoardPriority.allCases) { priority in
                        Text(priority.label).tag(priority.rawValue)
                    }
                }
                Picker("项目", selection: Binding(
                    get: { task.workspaceId ?? "" },
                    set: { value in
                        Task { await onPatch(["workspaceId": value.isEmpty ? NSNull() : value]) }
                    }
                )) {
                    Text("不指定项目（使用全局目录）").tag("")
                    ForEach(workspaces) { workspace in
                        Text(workspace.name).tag(workspace.id)
                    }
                }
            }
            Section(header: Text("指派 Agent")) {
                Picker("CLI 工具", selection: $agent.provider) {
                    ForEach(wandBoardProviders, id: \.self) { provider in
                        Text(wandBoardProviderLabel(provider)).tag(provider)
                    }
                }
                .onChange(of: agent.provider) { provider in
                    let options = wandBoardModelOptions(from: catalog, provider: provider)
                    if !options.contains(where: { $0.id == agent.model }) {
                        agent.model = options.first?.id ?? "default"
                    }
                }
                Picker("模型", selection: $agent.model) {
                    ForEach(wandBoardModelOptions(from: catalog, provider: agent.provider), id: \.id) { option in
                        Text(option.label).tag(option.id)
                    }
                }
                Picker("思考深度", selection: $agent.thinkingEffort) {
                    ForEach(wandBoardEfforts, id: \.self) { effort in
                        Text(wandBoardEffortLabel(effort)).tag(effort)
                    }
                }
                Button(task.sessions.isEmpty ? "派发 Agent" : "再派发一次") {
                    Task { await onDispatch(agent) }
                }
                .disabled(busy)
            }
            if !task.sessions.isEmpty {
                Section(header: Text("已绑定会话")) {
                    ForEach(task.sessions) { session in
                        Button {
                            onOpenSession(session.id)
                        } label: {
                            HStack {
                                BrandLogo(provider: session.provider, color: Theme.textPrimary)
                                    .frame(width: 14, height: 14)
                                Text("\(wandBoardProviderLabel(session.provider))\(session.model.isEmpty ? "" : " · \(session.model)")")
                            }
                        }
                    }
                }
            }
            Section {
                Button("归档") {
                    Task { await onDelete() }
                }
                .foregroundColor(Theme.danger)
                .disabled(busy)
            }
        }
        .padding(8)
        .onChange(of: task.id) { _ in
            title = task.title
            description = task.description
            agent = task.agent ?? .default
        }
    }
}

private struct TaskBoardCreateView: View {
    let workspaces: [Workspace]
    let defaultWorkspaceId: String
    let onCreate: (String, String, String, String, String?) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var description = ""
    @State private var status = "todo"
    @State private var priority = "none"
    @State private var workspaceId = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("新建任务").font(.headline)
                Spacer()
                Button("取消") { dismiss() }
                Button("创建") {
                    Task {
                        await onCreate(
                            title.trimmingCharacters(in: .whitespacesAndNewlines),
                            description,
                            status,
                            priority,
                            workspaceId.isEmpty ? nil : workspaceId
                        )
                    }
                }
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            TextField("任务标题", text: $title)
            TextField("描述", text: $description)
            Picker("项目", selection: $workspaceId) {
                Text("不指定项目（使用全局目录）").tag("")
                ForEach(workspaces) { workspace in
                    Text(workspace.name).tag(workspace.id)
                }
            }
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
            Spacer()
        }
        .padding(20)
        .frame(minWidth: 420, minHeight: 320)
        .onAppear { workspaceId = defaultWorkspaceId }
    }
}
