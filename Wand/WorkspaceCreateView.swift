import SwiftUI

/// 新建项目 sheet：名称 + 服务器目录 + 默认 Agent。
/// 目录走服务端路径（可远程），浏览器用已有 DirectoryBrowserView。
enum WorkspaceAddDraftStore {
    static var initialCwd = ""
    static var cwd = ""
    static var name = ""
    static func restore(initialCwd: String) -> (cwd: String, name: String)? {
        guard self.initialCwd == initialCwd, !cwd.isEmpty || !name.isEmpty else { return nil }
        return (cwd, name)
    }
    static func remember(initialCwd: String, cwd: String, name: String) {
        self.initialCwd = initialCwd
        self.cwd = cwd
        self.name = name
    }
    static var suppressRemember = false
    static func clear() {
        initialCwd = ""
        cwd = ""
        name = ""
    }
}

struct WorkspaceCreateView: View {
    let api: WandAPI
    @ObservedObject var store: WorkspaceStore
    var initialCwd = ""
    let onCreated: (Workspace) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var cwd = ""
    @State private var defaultProvider: WandProvider = .claude
    @State private var recentPaths: [WorkspaceRecentPath] = []
    @State private var creating = false
    @State private var errorMessage: String?
    @State private var showBrowser = false
    @State private var recentPathsExpanded = false
    @FocusState private var focusedField: String?

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader
            Rectangle().fill(Theme.border).frame(height: 0.5)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 7) {
                        fieldLabel("名称")
                        TextField("例如：Wand", text: $name)
                            .textFieldStyle(.plain)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .focused($focusedField, equals: "name")
                            .wandInputSurface(focused: focusedField == "name", cornerRadius: Theme.Radius.control)
                    }

                    VStack(alignment: .leading, spacing: 7) {
                        fieldLabel("工作目录")
                        HStack(spacing: 8) {
                            TextField("服务器上的路径，例如 /Users/you/project", text: $cwd)
                                .textFieldStyle(.plain)
                                .font(.system(size: 13, design: .monospaced))
                                .focused($focusedField, equals: "cwd")
                            Button("浏览…") { showBrowser = true }
                                .buttonStyle(WandSecondaryButtonStyle())
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .wandInputSurface(focused: focusedField == "cwd", cornerRadius: Theme.Radius.control)
                    }

                    if !recentPaths.isEmpty {
                        DisclosureGroup("最近使用的目录", isExpanded: $recentPathsExpanded) {
                            VStack(spacing: 6) {
                                ForEach(recentPaths.prefix(5)) { item in
                                    Button {
                                        cwd = item.path
                                        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                            name = item.name
                                        }
                                    } label: {
                                        HStack(spacing: 8) {
                                            Image(systemName: "folder")
                                                .font(.system(size: 12))
                                                .foregroundColor(Theme.textMuted)
                                            Text(item.path)
                                                .font(.system(size: 12, design: .monospaced))
                                                .foregroundColor(Theme.textPrimary)
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                            Spacer(minLength: 0)
                                        }
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(DesktopNavigationButtonStyle())
                                    .help(item.path)
                                }
                            }
                            .padding(.top, 6)
                        }
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textSecondary)
                    }

                    Picker("默认工具", selection: $defaultProvider) {
                        ForEach(WandProvider.allCases) { provider in
                            Text(provider.title).tag(provider)
                        }
                    }
                    .font(.system(size: 13))

                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundColor(Theme.danger)
                    }
                }
                .padding(24)
                .disabled(creating)
                .wandMotion(value: recentPathsExpanded, layout: true)
            }
            Rectangle().fill(Theme.border).frame(height: 0.5)
            sheetFooter
        }
        .frame(minWidth: 560, idealWidth: 620, minHeight: 460, idealHeight: 520)
        .background(Theme.workspaceBackground)
        .hideNativeTitleBar()
        .sheet(isPresented: $showBrowser) {
            DirectoryBrowserView(api: api, startPath: cwd) { picked in
                cwd = picked
                showBrowser = false
                if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    name = (picked as NSString).lastPathComponent
                }
            }
        }
        .onAppear {
            if let restored = WorkspaceAddDraftStore.restore(initialCwd: initialCwd) {
                cwd = restored.cwd
                name = restored.name
            } else if cwd.isEmpty {
                cwd = initialCwd
            }
        }
        .onDisappear {
            if WorkspaceAddDraftStore.suppressRemember {
                WorkspaceAddDraftStore.clear()
                WorkspaceAddDraftStore.suppressRemember = false
            } else {
                WorkspaceAddDraftStore.remember(initialCwd: initialCwd, cwd: cwd, name: name)
            }
        }
        .task {
            if let provider = try? await api.workspaceDefaultProvider() {
                defaultProvider = provider
            }
            if let recent = try? await api.workspaceRecentPaths() {
                recentPaths = recent
            }
        }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedCwd: String {
        cwd.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSubmit: Bool {
        !creating && !trimmedName.isEmpty && !trimmedCwd.isEmpty
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(Theme.textSecondary)
    }

    private var sheetHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                Text("新建工作空间")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                Text("选择工作目录，将相关任务放在一起。")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textSecondary)
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .background(Theme.workspaceBackground)
        .contentShape(Rectangle())
        .windowDrag()
    }

    private var sheetFooter: some View {
        HStack {
            Spacer()
            Button("取消") { dismiss() }
                .buttonStyle(WandSecondaryButtonStyle())
                .disabled(creating)
            Button {
                Task { await submit() }
            } label: {
                Text(creating ? "创建中…" : "创建工作空间")
                    .frame(minWidth: 88)
            }
            .buttonStyle(WandPrimaryButtonStyle())
            .disabled(!canSubmit)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(Theme.workspaceBackground)
    }

    private func submit() async {
        guard canSubmit else { return }
        creating = true
        errorMessage = nil
        do {
            let created = try await store.createWorkspace(
                name: trimmedName,
                cwd: trimmedCwd,
                defaultProvider: defaultProvider
            )
            creating = false
            WorkspaceAddDraftStore.clear()
            WorkspaceAddDraftStore.suppressRemember = true
            onCreated(created)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            creating = false
        }
    }
}


private struct WorkspaceAPIEnvironmentKey: EnvironmentKey {
    static let defaultValue: WandAPI? = nil
}
extension EnvironmentValues {
    var workspaceAPI: WandAPI? {
        get { self[WorkspaceAPIEnvironmentKey.self] }
        set { self[WorkspaceAPIEnvironmentKey.self] = newValue }
    }
}

struct WorkspaceSelector: View {
    @Binding var selection: String
    let choices: [(id: String, name: String)]
    var emptyLabel = "未归属工作区"
    var initialCwd = ""
    var onCreated: (Workspace) -> Void = { _ in }
    @Environment(\.workspaceAPI) private var api
    @State private var adding = false
    @State private var added: Workspace?

    var body: some View {
        Menu {
            Button(emptyLabel) { selection = "" }
            ForEach(choices, id: \.id) { choice in
                Button(choice.name) { selection = choice.id }
            }
            if let added, !choices.contains(where: { $0.id == added.id }) {
                Button(added.name) { selection = added.id }
            }
            Divider()
            Button("添加工作区", systemImage: "plus") { adding = true }
        } label: {
            Label(choices.first { $0.id == selection }?.name ?? (added?.id == selection ? added?.name : nil) ?? emptyLabel, systemImage: "folder")
        }
        .accessibilityLabel("选择工作区")
        .sheet(isPresented: $adding) {
            if let api {
                WorkspaceAddDialog(api: api, initialCwd: initialCwd) { workspace in
                    added = workspace; selection = workspace.id; onCreated(workspace); adding = false
                }
            }
        }
    }
}

struct AddWorkspaceButton: View {
    var initialCwd = ""
    var apiOverride: WandAPI? = nil
    var onCreated: (Workspace) -> Void = { _ in }
    @Environment(\.workspaceAPI) private var environmentAPI
    @State private var adding = false
    private var api: WandAPI? { apiOverride ?? environmentAPI }
    var body: some View {
        Button("添加工作区", systemImage: "plus") { adding = true }
            .accessibilityLabel("添加工作区")
            .sheet(isPresented: $adding) {
                if let api { WorkspaceAddDialog(api: api, initialCwd: initialCwd) { workspace in onCreated(workspace); adding = false } }
            }
    }
}

struct WorkspaceAddDialog: View {
    let api: WandAPI
    var initialCwd = ""
    let onCreated: (Workspace) -> Void
    @StateObject private var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    init(api: WandAPI, initialCwd: String = "", onCreated: @escaping (Workspace) -> Void) {
        self.api = api
        self.initialCwd = initialCwd
        self.onCreated = onCreated
        _store = StateObject(wrappedValue: WorkspaceStore(api: api, serverID: api.baseURL.absoluteString))
    }
    var body: some View {
        WorkspaceCreateView(api: api, store: store, initialCwd: initialCwd) { workspace in
            NotificationCenter.default.post(name: .wandRefreshLists, object: nil)
            onCreated(workspace)
        }
    }
}
