import AppKit
import SwiftUI

/// One catalog owns the menu bar, command palette and keyboard reference.
enum DesktopCommand: String, CaseIterable, Identifiable {
    case newSession, newTask, search, toggleSidebar, toggleInspector
    case workspaces, sessions, taskBoard, settings
    case focusComposer, findConversation, reconnect

    var id: String { rawValue }
    var title: String {
        switch self {
        case .newSession: return "新建会话"
        case .newTask: return "新建工作任务"
        case .search: return "搜索与命令"
        case .toggleSidebar: return "显示 / 隐藏侧栏"
        case .toggleInspector: return "显示 / 隐藏检查器"
        case .workspaces: return "工作空间"
        case .sessions: return "单独会话"
        case .taskBoard: return "任务看板"
        case .settings: return "设置"
        case .focusComposer: return "聚焦消息输入框"
        case .findConversation: return "查找当前对话"
        case .reconnect: return "刷新连接"
        }
    }
    var subtitle: String {
        switch self {
        case .newSession: return "选择 AI 工具，开始聊天或终端会话"
        case .newTask: return "把目录、工作树与多个会话组织在一起"
        case .search: return "查找会话、工作空间和应用操作"
        case .toggleSidebar: return "为当前工作腾出更多空间"
        case .toggleInspector: return "文件预览、Git 变更和会话详情"
        case .workspaces: return "定位侧栏上方的工作空间与任务"
        case .sessions: return "定位侧栏下方的独立会话与历史记录"
        case .taskBoard: return "管理待办、进度、优先级与归档"
        case .settings: return "外观、输入、连接和客户端更新"
        case .focusComposer: return "继续当前对话；终端保持自己的按键语义"
        case .findConversation: return "在已加载的聊天内容中定位文字"
        case .reconnect: return "重新检查服务器连接并刷新列表"
        }
    }
    var symbol: String {
        switch self {
        case .newSession: return "square.and.pencil"
        case .newTask: return "plus.rectangle.on.folder"
        case .search: return "magnifyingglass"
        case .toggleSidebar: return "sidebar.left"
        case .toggleInspector: return "sidebar.right"
        case .workspaces: return "folder"
        case .sessions: return "bubble.left.and.bubble.right"
        case .taskBoard: return "checklist"
        case .settings: return "gearshape"
        case .focusComposer: return "text.cursor"
        case .findConversation: return "text.magnifyingglass"
        case .reconnect: return "arrow.clockwise"
        }
    }
    var shortcutLabel: String {
        switch self {
        case .newSession: return "⌘N"
        case .newTask: return "⇧⌘N"
        case .search: return "⇧⌘P"
        case .toggleSidebar: return "⌃⌘S"
        case .toggleInspector: return "⌥⌘I"
        case .workspaces: return "⌘2"
        case .sessions: return "⌘1"
        case .taskBoard: return "⌘3"
        case .settings: return "⌘,"
        case .focusComposer: return "⌘L"
        case .findConversation: return "⌘F"
        case .reconnect: return "⇧⌘R"
        }
    }
    var key: KeyEquivalent {
        switch self {
        case .newSession, .newTask: return "n"
        case .search: return "p"
        case .toggleSidebar: return "s"
        case .toggleInspector: return "i"
        case .workspaces: return "2"
        case .sessions: return "1"
        case .taskBoard: return "3"
        case .settings: return ","
        case .focusComposer: return "l"
        case .findConversation: return "f"
        case .reconnect: return "r"
        }
    }
    var modifiers: EventModifiers {
        switch self {
        case .newTask, .search, .reconnect: return [.command, .shift]
        case .toggleSidebar: return [.command, .control]
        case .toggleInspector: return [.command, .option]
        default: return .command
        }
    }
    func send() {
        // A nested file preview or provider picker owns keyboard input until it closes.
        guard NSApp.keyWindow?.sheetParent == nil else { return }
        NotificationCenter.default.post(name: .wandDesktopCommand, object: self)
    }
}

extension Notification.Name {
    static let wandDesktopCommand = Notification.Name("WandDesktopCommand")
    static let wandRefreshLists = Notification.Name("WandRefreshLists")
}

struct DesktopCommandMenuItem: View {
    let command: DesktopCommand
    @FocusedValue(\.wandDesktopCommandsEnabled) private var enabled
    var body: some View {
        Button(command.title) { command.send() }
            .keyboardShortcut(command.key, modifiers: command.modifiers)
            .disabled(enabled != true)
    }
}

private struct DesktopCommandsEnabledKey: FocusedValueKey {
    typealias Value = Bool
}

extension FocusedValues {
    var wandDesktopCommandsEnabled: Bool? {
        get { self[DesktopCommandsEnabledKey.self] }
        set { self[DesktopCommandsEnabledKey.self] = newValue }
    }
}

struct DesktopCommandPalette: View {
    let api: WandAPI
    let onCommand: (DesktopCommand) -> Void
    let onSession: (SessionSnapshot) -> Void
    let onWorkspace: (Workspace) -> Void
    let onDismiss: () -> Void
    @State private var query = ""
    @State private var selection = 0
    @State private var sessions: [SessionSnapshot] = []
    @State private var workspaces: [Workspace] = []
    @State private var loading = true
    @State private var error: String?

    private enum Result: Identifiable {
        case command(DesktopCommand), session(SessionSnapshot), workspace(Workspace)
        var id: String {
            switch self {
            case .command(let value): return "command-" + value.id
            case .session(let value): return "session-" + value.id
            case .workspace(let value): return "workspace-" + value.id
            }
        }
        var title: String {
            switch self {
            case .command(let value): return value.title
            case .session(let value): return value.title?.isEmpty == false ? value.title! : "未命名会话"
            case .workspace(let value): return value.name
            }
        }
        var detail: String {
            switch self {
            case .command(let value): return value.subtitle
            case .session(let value): return [value.provider, value.cwd].compactMap { $0 }.joined(separator: " · ")
            case .workspace(let value): return value.cwd
            }
        }
        var symbol: String {
            switch self {
            case .command(let value): return value.symbol
            case .session: return "bubble.left"
            case .workspace: return "folder"
            }
        }
    }
    private var results: [Result] {
        let commands = DesktopCommand.allCases.filter { $0 != .search }.map(Result.command)
        let entries = query.isEmpty
            ? Array(sessions.prefix(6)).map(Result.session) + commands + workspaces.map(Result.workspace)
            : sessions.map(Result.session) + workspaces.map(Result.workspace) + commands
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.filter { needle.isEmpty || ($0.title + " " + $0.detail).localizedStandardContains(needle) }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").foregroundColor(Theme.textSecondary)
                DesktopPaletteInput(text: $query, onMove: move, onSubmit: activateSelection, onCancel: onDismiss)
                    .frame(height: 32)
                    .accessibilityLabel("搜索会话、工作空间或命令")
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).help("清除搜索").accessibilityLabel("清除搜索")
                }
                Button("关闭", action: onDismiss).keyboardShortcut(.cancelAction)
                    .buttonStyle(.plain).foregroundColor(Theme.textSecondary)
            }
            .padding(20)
            Divider()
            if loading {
                HStack { ProgressView().controlSize(.small); Text("正在读取最近的工作…"); Spacer() }
                    .font(.system(size: 12)).padding(.horizontal, 20).padding(.top, 12)
            }
            if let error {
                HStack {
                    Text(error).lineLimit(2)
                    Spacer()
                    Button("重试") { Task { await load() } }.disabled(loading)
                }.font(.system(size: 12)).foregroundColor(Theme.warning).padding(12)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 3) {
                        if results.isEmpty {
                            VStack(spacing: 10) {
                                Image(systemName: "magnifyingglass").font(.system(size: 26))
                                Text("没有找到匹配内容").font(.headline)
                                Text("试试会话标题、目录、工具名或「设置」。").font(.subheadline)
                            }.foregroundColor(Theme.textSecondary).padding(45)
                        }
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                            Button { activate(result) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: result.symbol).frame(width: 22).foregroundColor(Theme.textSecondary)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(result.title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                                        Text(result.detail).font(.system(size: 11)).foregroundColor(Theme.textSecondary).lineLimit(1)
                                    }
                                    Spacer()
                                    if case .command(let command) = result {
                                        Text(command.shortcutLabel).font(.system(size: 12, design: .monospaced)).foregroundColor(Theme.textSecondary)
                                    }
                                }
                                .foregroundColor(Theme.textPrimary).padding(11).contentShape(Rectangle())
                                .background(RoundedRectangle(cornerRadius: 9).fill(index == selection ? Theme.textPrimary.opacity(0.08) : .clear))
                            }
                            .buttonStyle(.plain).id(result.id)
                            .accessibilityAddTraits(index == selection ? .isSelected : [])
                        }
                    }.padding(10)
                }
                .onChange(of: selection) { index in
                    if results.indices.contains(index) { proxy.scrollTo(results[index].id) }
                }
            }
            Divider()
            HStack {
                Text("↑ ↓ 选择    ↵ 打开    esc 关闭")
                Spacer()
                Text("\(results.count) 个结果")
            }.font(.system(size: 11)).foregroundColor(Theme.textSecondary).padding(14)
        }
        .frame(width: 640, height: 540).background(Theme.surfaceElevated)
        .onChange(of: query) { _ in selection = 0 }
        .task { await load() }
    }
    private func move(_ delta: Int) {
        selection = min(max(0, selection + delta), max(0, results.count - 1))
    }
    private func activateSelection() {
        guard results.indices.contains(selection) else { return }
        activate(results[selection])
    }
    private func activate(_ result: Result) {
        switch result {
        case .command(let value): onCommand(value)
        case .session(let value): onSession(value)
        case .workspace(let value): onWorkspace(value)
        }
    }
    private func load() async {
        loading = true
        defer { loading = false }
        do {
            async let sessionList = api.listSessions()
            async let workspaceList = api.listWorkspaces()
            let (loadedSessions, loadedWorkspaces) = try await (sessionList, workspaceList)
            let selectedID = results.indices.contains(selection) ? results[selection].id : nil
            sessions = loadedSessions
            workspaces = loadedWorkspaces
            selection = results.firstIndex(where: { $0.id == selectedID }) ?? 0
            error = nil
        } catch {
            self.error = "无法读取最近的工作，仍可使用下方命令。"
        }
    }
}

/// Native field editor keeps arrow navigation and Return IME-safe on macOS 12.
private struct DesktopPaletteInput: NSViewRepresentable {
    @Binding var text: String
    let onMove: (Int) -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 17)
        field.placeholderString = "搜索会话、工作空间或命令…"
        field.delegate = context.coordinator
        DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: DesktopPaletteInput
        init(_ parent: DesktopPaletteInput) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            switch selector {
            case #selector(NSResponder.moveDown(_:)): parent.onMove(1)
            case #selector(NSResponder.moveUp(_:)): parent.onMove(-1)
            case #selector(NSResponder.insertNewline(_:)): parent.onSubmit()
            case #selector(NSResponder.cancelOperation(_:)): parent.onCancel()
            default: return false
            }
            return true
        }
    }
}
