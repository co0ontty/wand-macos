import SwiftUI
import Combine

/// Current macOS user's client preference, isolated by Wand server (never by a credential).
enum QuickTerminalDock: String {
    case right, bottom
    init(stored: String?) { self = stored == "bottom" ? .bottom : .right }
}

@MainActor
final class QuickTerminalModel: ObservableObject {
    @Published var isOpen = false
    @Published private(set) var dock: QuickTerminalDock
    @Published private(set) var terminal: PtyTerminalStore?
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    @Published private(set) var cwd = ""
    private let api: WandAPI
    private let defaults: UserDefaults
    private let makeTerminal: @MainActor (String, WandAPI) -> PtyTerminalStore
    private let key: String
    private var sessionId: String
    private var creationUnconfirmed = false
    private var observation: AnyCancellable?
    private var launch: Task<Void, Never>?

    init(api: WandAPI, defaults: UserDefaults = .standard,
         makeTerminal: @escaping @MainActor (String, WandAPI) -> PtyTerminalStore = { PtyTerminalStore(sessionId: $0, api: $1) }) {
        self.api = api
        self.defaults = defaults
        self.makeTerminal = makeTerminal
        key = "wand.quick-terminal.v1." + api.baseURL.absoluteString
        dock = QuickTerminalDock(stored: defaults.string(forKey: key + ".dock"))
        sessionId = defaults.string(forKey: key + ".session") ?? ""
        creationUnconfirmed = sessionId.isEmpty && defaults.bool(forKey: key + ".creating")
        if creationUnconfirmed { error = "上次创建终端未确认，请先在会话列表检查；不会重复创建。" }
    }

    func setDock(_ value: QuickTerminalDock) {
        dock = value
        defaults.set(value.rawValue, forKey: key + ".dock")
    }

    func open(cwd: String?) {
        isOpen = true
        if let terminal {
            terminal.setLayoutActive(true)
            // close() disables the retained NSView immediately. Re-enable it before
            // focusing; waiting for SwiftUI's next update makes this focus request a no-op.
            terminal.terminal.inputEnabled = terminal.ready && !terminal.sessionEnded
            terminal.terminal.focusTerminal()
            return
        }
        if sessionId.isEmpty {
            // Other windows use the same OS-user/client preference. Read just before
            // creation; MainActor serializes this check and the pending write.
            sessionId = defaults.string(forKey: key + ".session") ?? ""
            creationUnconfirmed = sessionId.isEmpty && defaults.bool(forKey: key + ".creating")
        }
        guard !busy, !creationUnconfirmed else { return }
        busy = true
        error = nil
        if sessionId.isEmpty {
            creationUnconfirmed = true
            defaults.set(true, forKey: key + ".creating")
        }
        let originalResponder = NSApp.keyWindow?.firstResponder
        launch = Task { [weak self, weak originalResponder] in
            guard let self else { return }
            defer { self.busy = false; self.launch = nil }
            do {
                let snapshot: SessionSnapshot
                if !self.sessionId.isEmpty {
                    snapshot = try await self.api.getSession(id: self.sessionId)
                } else {
                    // Unknown delivery must not automatically create another process.
                    snapshot = try await self.api.createBlankTerminal(cwd: cwd?.isEmpty == false ? cwd! : "~", initialInput: nil)
                }
                guard snapshot.sessionKind == "pty", snapshot.provider?.isEmpty != false else {
                    self.error = "原终端引用无效，请在会话列表确认；不会自动新建进程。"
                    return
                }
                self.sessionId = snapshot.id
                self.defaults.set(snapshot.id, forKey: self.key + ".session")
                self.creationUnconfirmed = false
                self.defaults.set(false, forKey: self.key + ".creating")
                self.cwd = snapshot.cwd ?? ""
                let store = self.makeTerminal(snapshot.id, self.api)
                self.terminal = store
                store.setLayoutActive(self.isOpen)
                self.observation = store.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
                store.start()
                DispatchQueue.main.async { [weak self, weak originalResponder] in
                    guard let self, self.isOpen,
                          NSApp.keyWindow?.firstResponder === originalResponder else { return }
                    store.terminal.focusTerminal()
                }
            } catch {
                self.error = self.sessionId.isEmpty
                    ? "创建终端未确认，请先在会话列表检查，避免重复创建。"
                    : "原终端暂不可用，请重试连接或在会话列表确认；不会自动新建进程。"
            }
        }
    }

    func close() {
        isOpen = false
        terminal?.setLayoutActive(false)
        terminal?.terminal.inputEnabled = false
    }
    func reconnect() {
        if let terminal { terminal.retry() }
        else if !sessionId.isEmpty { open(cwd: nil) }
    }
    var connectionLabel: String {
        if busy { return "连接中" }
        guard let terminal else { return error == nil ? "未连接" : "连接失败" }
        if terminal.sessionEnded { return "进程已结束" }
        if terminal.loadError != nil { return "连接异常" }
        if terminal.ready { return "已连接" }
        return terminal.loading ? "连接中" : "已断开 · 自动重连中"
    }
}

/// One stable subtree per surface; docking changes geometry, never store/NSView identity.
struct QuickTerminalWorkspace<Content: View>: View {
    @ObservedObject var model: QuickTerminalModel
    let content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var fraction: CGFloat?
    @State private var dragStart: CGFloat?

    init(model: QuickTerminalModel, @ViewBuilder content: () -> Content) {
        self.model = model
        self.content = content()
    }

    var body: some View {
        GeometryReader { geometry in
            let bottom = model.dock == .bottom || geometry.size.width < 680
            let axis = bottom ? geometry.size.height : geometry.size.width
            let minimum = min(bottom ? 190.0 : 280.0, axis * 0.6)
            let size = model.isOpen ? min(axis * 0.7, max(minimum, axis * (fraction ?? (bottom ? 0.35 : 0.4)))) : 0
            ZStack(alignment: .bottomTrailing) {
                content
                    .padding(.trailing, bottom ? 0 : size)
                    .padding(.bottom, bottom ? size : 0)
                panel
                    .frame(width: bottom ? geometry.size.width : size,
                           height: bottom ? size : geometry.size.height)
                    .clipped()
                    .opacity(model.isOpen ? 1 : 0)
                    .allowsHitTesting(model.isOpen)
                    .accessibilityHidden(!model.isOpen)
                    .disabled(!model.isOpen)
                Color.clear
                    .frame(width: bottom ? geometry.size.width : 5, height: bottom ? 5 : geometry.size.height)
                    .overlay(Rectangle().fill(Theme.border)
                        .frame(width: bottom ? nil : 1, height: bottom ? 1 : nil))
                    .contentShape(Rectangle())
                    .offset(x: bottom ? 0 : -max(0, size - 5), y: bottom ? -max(0, size - 5) : 0)
                    .opacity(model.isOpen ? 1 : 0)
                    .allowsHitTesting(model.isOpen)
                    .accessibilityLabel("调整终端大小")
                    .accessibilityAdjustableAction { direction in
                        fraction = min(0.7, max(0.25, (fraction ?? (bottom ? 0.35 : 0.4)) + (direction == .increment ? 0.05 : -0.05)))
                    }
                    .gesture(DragGesture().onChanged { value in
                        if dragStart == nil { dragStart = size }
                        fraction = min(0.7, max(0.25, ((dragStart ?? size) - (bottom ? value.translation.height : value.translation.width)) / max(1, axis)))
                    }.onEnded { _ in dragStart = nil })
            }
            .animation(dragStart == nil && !reduceMotion ? Theme.Motion.structure : nil, value: model.isOpen)
            .animation(reduceMotion ? nil : Theme.Motion.structure, value: model.dock)
            .onChange(of: model.dock) { _ in fraction = nil }
        }
    }

    private var directory: String {
        model.terminal?.cwd.isEmpty == false ? model.terminal!.cwd : model.cwd
    }

    private var panel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("终端").fontWeight(.semibold).fixedSize()
                if model.connectionLabel == "已连接" {
                    Circle().fill(Theme.success).frame(width: 6, height: 6)
                        .accessibilityLabel("已连接").help("已连接")
                } else {
                    Text(model.connectionLabel).foregroundColor(Theme.textSecondary).lineLimit(1)
                }
                Text(directory.isEmpty ? "服务端主目录" : (directory as NSString).lastPathComponent)
                    .foregroundColor(Theme.textSecondary).lineLimit(1).truncationMode(.middle)
                    .help(directory.isEmpty ? "服务端主目录" : directory)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Menu {
                    Button("停靠到右侧" + (model.dock == .right ? "（已选）" : "")) { model.setDock(.right) }
                    Button("停靠到底部" + (model.dock == .bottom ? "（已选）" : "")) { model.setDock(.bottom) }
                    Divider()
                    Button("重新连接") { model.reconnect() }.disabled(model.busy)
                } label: { Image(systemName: "ellipsis").frame(width: 24, height: 24) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("终端选项")
                .help("终端选项 · " + (model.dock == .right ? "右侧" : "底部") + "停靠")
                Button { model.close() } label: { Image(systemName: "xmark").frame(width: 24, height: 24) }
                    .buttonStyle(WandIconButtonStyle()).accessibilityLabel("关闭终端面板")
                    .help("仅隐藏面板，运行命令不受影响；结束 shell 请在终端输入 exit")
            }.font(.system(size: 12)).padding(.horizontal, 8).frame(minHeight: 40)
                .background(Theme.surfaceElevated)
            if let message = model.error ?? model.terminal?.loadError {
                HStack {
                    Text(message).font(.system(size: 12)).foregroundColor(Theme.warning)
                    Spacer(minLength: 4)
                    Button("重新连接") { model.reconnect() }.disabled(model.busy)
                }.padding(8).background(Theme.surfaceElevated)
            }
            if let store = model.terminal {
                NativeTerminalSurface(terminal: store.terminal, focusOnMount: false)
                    .environment(\.desktopPageActive, model.isOpen)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else { Spacer(minLength: 0) }
        }.background(Color(nsColor: NativeTerminalView.canvasColor))
            .accessibilityHint("运行在 Wand 主机；关闭仅隐藏，命令继续运行。结束 shell 请在终端输入 exit。")
    }
}
