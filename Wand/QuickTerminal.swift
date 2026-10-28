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
    @Published private var missingSession = false
    @Published private var terminalEnded = false
    @Published private var referenceUnconfirmed = false
    private let api: WandAPI
    private let defaults: UserDefaults
    private let makeTerminal: @MainActor (String, WandAPI) -> PtyTerminalStore
    private let key: String
    private var sessionId: String
    private var creationUnconfirmed = false
    private var observation: AnyCancellable?
    private var statusObservation: AnyCancellable?
    private var launch: Task<Void, Never>?
    private var requestedCwd: String?

    init(api: WandAPI, defaults: UserDefaults = .standard,
         makeTerminal: @escaping @MainActor (String, WandAPI) -> PtyTerminalStore = { PtyTerminalStore(sessionId: $0, api: $1) }) {
        self.api = api
        self.defaults = defaults
        self.makeTerminal = makeTerminal
        key = "wand.quick-terminal.v1." + api.baseURL.absoluteString
        dock = QuickTerminalDock(stored: defaults.string(forKey: key + ".dock"))
        sessionId = defaults.string(forKey: key + ".session") ?? ""
        creationUnconfirmed = sessionId.isEmpty && defaults.bool(forKey: key + ".creating")
        if creationUnconfirmed { error = "上次创建终端未确认，已暂停重复创建。" }
    }

    func setDock(_ value: QuickTerminalDock) {
        dock = value
        defaults.set(value.rawValue, forKey: key + ".dock")
    }

    /// After authentication, migrate only the saved panel reference without opening
    /// its surface or creating a process. Normal standalone shells stay untouched.
    func reconcileSavedTerminal() async {
        let savedId = defaults.string(forKey: key + ".session") ?? ""
        guard !savedId.isEmpty, !defaults.bool(forKey: key + ".creating") else { return }
        do {
            let snapshot = try await api.getSession(id: savedId)
            guard snapshot.id == savedId, snapshot.sessionKind == "pty", snapshot.provider?.isEmpty != false,
                  snapshot.sessionSource != "quick-terminal",
                  defaults.string(forKey: key + ".session") == savedId,
                  !defaults.bool(forKey: key + ".creating") else { return }
            let claimed = try await api.claimQuickTerminal(id: savedId)
            guard claimed.id == savedId, claimed.sessionKind == "pty", claimed.provider?.isEmpty != false,
                  claimed.sessionSource == "quick-terminal" else { return }
            NotificationCenter.default.post(name: .wandRefreshLists, object: nil)
        } catch {
            // A panel's metadata retry must not block authentication or create a
            // replacement. Opening the panel reports the actual connection error.
        }
    }

    func open(cwd: String?, reconnect: Bool = false) {
        isOpen = true
        if let cwd, !cwd.isEmpty { requestedCwd = cwd }
        guard !busy else { return }
        // Another window may already be replacing this reference. The pending
        // write happens on MainActor before any POST can suspend.
        let storedId = defaults.string(forKey: key + ".session") ?? ""
        creationUnconfirmed = defaults.bool(forKey: key + ".creating")
        guard !creationUnconfirmed else {
            error = "上次创建终端未确认，已暂停重复创建。"
            return
        }
        if !storedId.isEmpty, storedId != sessionId {
            releaseTerminal()
            sessionId = storedId
            missingSession = false
            terminalEnded = false
        }
        if let terminal, !reconnect {
            terminal.setLayoutActive(true)
            // close() disables the retained NSView immediately. Re-enable it before
            // focusing; waiting for SwiftUI's next update makes this focus request a no-op.
            terminal.terminal.inputEnabled = terminal.ready && !terminal.sessionEnded
            terminal.terminal.focusTerminal()
            return
        }
        busy = true
        error = nil
        missingSession = false
        referenceUnconfirmed = true
        if sessionId.isEmpty {
            creationUnconfirmed = true
            defaults.set(true, forKey: key + ".creating")
        }
        let originalResponder = NSApp.keyWindow?.firstResponder
        let originalSessionId = sessionId
        launch = Task { [weak self, weak originalResponder] in
            guard let self else { return }
            defer { self.busy = false; self.launch = nil }
            var readingOriginal = !originalSessionId.isEmpty
            do {
                let snapshot: SessionSnapshot
                var refreshLists = originalSessionId.isEmpty
                if !originalSessionId.isEmpty {
                    let original = try await self.api.getSession(id: originalSessionId)
                    readingOriginal = false
                    guard original.id == originalSessionId, original.sessionKind == "pty", original.provider?.isEmpty != false else {
                        self.error = "终端响应无效，请重新连接；不会自动重复创建。"
                        return
                    }
                    if original.sessionSource == "quick-terminal" {
                        snapshot = original
                    } else {
                        // Only the exact client-owned reference is migrated; never
                        // infer quick terminals from their title, cwd or shell name.
                        snapshot = try await self.api.claimQuickTerminal(id: originalSessionId)
                        refreshLists = true
                    }
                } else {
                    // Unknown delivery must not automatically create another process.
                    snapshot = try await self.api.createBlankTerminal(cwd: self.requestedCwd ?? "~", initialInput: nil, quickTerminal: true)
                }
                guard !snapshot.id.isEmpty, snapshot.sessionKind == "pty", snapshot.provider?.isEmpty != false,
                      snapshot.sessionSource == "quick-terminal", originalSessionId.isEmpty || snapshot.id == originalSessionId else {
                    self.error = "终端响应无效，请重新连接；不会自动重复创建。"
                    return
                }
                if refreshLists { NotificationCenter.default.post(name: .wandRefreshLists, object: nil) }
                if !originalSessionId.isEmpty,
                   self.defaults.bool(forKey: self.key + ".creating")
                    || self.defaults.string(forKey: self.key + ".session") != originalSessionId {
                    self.error = "终端已在另一窗口更新，请重新连接。"
                    return
                }
                self.sessionId = snapshot.id
                self.defaults.set(snapshot.id, forKey: self.key + ".session")
                self.creationUnconfirmed = false
                self.defaults.set(false, forKey: self.key + ".creating")
                self.referenceUnconfirmed = false
                self.cwd = snapshot.cwd ?? ""
                self.terminalEnded = ["exited", "failed", "stopped"].contains(snapshot.status ?? "")
                if let store = self.terminal {
                    store.retry()
                    return
                }
                let store = self.makeTerminal(snapshot.id, self.api)
                self.terminal = store
                store.setLayoutActive(self.isOpen)
                self.observation = store.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
                // The first publisher value is the store's default, not a server
                // fact. Later runtime states supersede the initial HTTP snapshot.
                self.statusObservation = store.$status.dropFirst().sink { [weak self] status in
                    self?.terminalEnded = ["exited", "failed", "stopped"].contains(status)
                }
                store.start()
                DispatchQueue.main.async { [weak self, weak originalResponder] in
                    guard let self, self.isOpen,
                          NSApp.keyWindow?.firstResponder === originalResponder else { return }
                    store.terminal.focusTerminal()
                }
            } catch {
                if readingOriginal,
                   case WandAPI.APIError.server(let status, _) = error, [404, 410].contains(status) {
                    self.missingSession = true
                    self.referenceUnconfirmed = false
                    self.error = "原终端已不存在，可以新建终端继续使用。"
                    self.terminal?.shutdown()
                    self.terminal?.terminal.inputEnabled = false
                } else {
                    if originalSessionId.isEmpty {
                        self.error = "创建终端未确认，已暂停重复创建。"
                    } else if case WandAPI.APIError.unauthorized = error {
                        self.error = "登录已失效，请重新登录后连接原终端。"
                    } else if case WandAPI.APIError.server(403, _) = error {
                        self.error = "当前连接没有访问原终端的权限，请检查连接权限。"
                    } else {
                        self.error = "原终端暂不可用，请重试连接；不会自动新建进程。"
                    }
                }
            }
        }
    }

    var canCreateTerminal: Bool {
        !busy && !creationUnconfirmed && !referenceUnconfirmed && (missingSession || terminalEnded)
    }
    var recoveryMessage: String? {
        error ?? terminal?.loadError ?? (terminalEnded ? "原终端进程已结束，可以新建终端继续使用。" : nil)
    }

    /// Explicit replacement releases only this client's view/socket, never history or a server process.
    func createNewTerminal() {
        guard canCreateTerminal else { return }
        let storedId = defaults.string(forKey: key + ".session") ?? ""
        if defaults.bool(forKey: key + ".creating") || (!storedId.isEmpty && storedId != sessionId) {
            open(cwd: requestedCwd)
            return
        }
        releaseTerminal()
        sessionId = ""
        defaults.set("", forKey: key + ".session")
        missingSession = false
        terminalEnded = false
        open(cwd: requestedCwd ?? (cwd.isEmpty ? nil : cwd))
    }

    private func releaseTerminal() {
        observation?.cancel()
        observation = nil
        statusObservation?.cancel()
        statusObservation = nil
        terminal?.shutdown()
        terminal = nil
    }

    func close() {
        isOpen = false
        terminal?.setLayoutActive(false)
        terminal?.terminal.inputEnabled = false
    }
    func reconnect() {
        if !sessionId.isEmpty || creationUnconfirmed { open(cwd: requestedCwd, reconnect: true) }
    }
    var connectionLabel: String {
        if busy { return "连接中" }
        if missingSession { return "终端已不存在" }
        guard let terminal else { return error == nil ? "未连接" : "连接失败" }
        if terminalEnded { return "进程已结束" }
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
                    if model.canCreateTerminal {
                        Button("新建终端") { model.createNewTerminal() }
                    }
                } label: { Image(systemName: "ellipsis").frame(width: 24, height: 24) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("终端选项")
                .help("终端选项 · " + (model.dock == .right ? "右侧" : "底部") + "停靠")
                Button { model.close() } label: { Image(systemName: "xmark").frame(width: 24, height: 24) }
                    .buttonStyle(WandIconButtonStyle()).accessibilityLabel("关闭终端面板")
                    .help("仅隐藏面板，运行命令不受影响；结束 shell 请在终端输入 exit")
            }.font(.system(size: 12)).padding(.horizontal, 8).frame(minHeight: 40)
                .background(Theme.surfaceElevated)
            if let message = model.recoveryMessage {
                HStack {
                    Text(message).font(.system(size: 12)).foregroundColor(Theme.warning)
                    Spacer(minLength: 4)
                    if model.canCreateTerminal {
                        Button("新建终端") { model.createNewTerminal() }
                    } else {
                        Button("重新连接") { model.reconnect() }.disabled(model.busy)
                    }
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
