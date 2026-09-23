import Combine
import Foundation

/// The server checkpoint is ANSI text plus an ordered tail of writes and resizes.
/// It is not an xterm.js object: any compatible terminal emulator can replay it.
struct PtyTerminalSnapshot: Decodable {
    struct Operation: Decodable {
        let type: String
        let data: String?
        let cols: Int?
        let rows: Int?
    }

    let version: Int
    let data: String
    let cols: Int
    let rows: Int
    let pending: [Operation]

    static func validSize(cols: Int, rows: Int) -> Bool {
        (1...1000).contains(cols) && (1...1000).contains(rows)
    }

    var isReplayable: Bool {
        version == 1 && Self.validSize(cols: cols, rows: rows) && pending.allSatisfy {
            switch $0.type {
            case "data": return $0.data != nil
            case "resize": return Self.validSize(cols: $0.cols ?? 0, rows: $0.rows ?? 0)
            default: return false
            }
        }
    }
}

enum PtyTerminalInput {
    /// Stay below the server's per-frame limit without splitting a UTF-8 scalar.
    /// Do not trim, append LF, or turn a native Return into a text+newline packet.
    static func chunks(_ text: String, maxBytes: Int = 16 * 1024) -> [String] {
        guard !text.isEmpty else { return [] }
        let limit = max(4, maxBytes)
        var result: [String] = []
        var chunk = ""
        var bytes = 0
        for scalar in text.unicodeScalars {
            let count = scalar.utf8.count
            if bytes + count > limit {
                result.append(chunk)
                chunk = ""
                bytes = 0
            }
            chunk.unicodeScalars.append(scalar)
            bytes += count
        }
        if !chunk.isEmpty { result.append(chunk) }
        return result
    }
}

@MainActor
final class PtyTerminalStore: ObservableObject {
    @Published private(set) var loading = true
    @Published private(set) var ready = false
    @Published private(set) var status = "running"
    @Published private(set) var cwd = ""
    @Published private(set) var pendingEscalation: EscalationRequest?
    @Published private(set) var legacyPermissionPrompt: PermissionRequestInfo?
    @Published private(set) var sizeLabel = ""
    @Published private(set) var scale: Double
    @Published private(set) var loadError: String?
    @Published var toast: String?

    let terminal = NativeTerminalView()
    private let sessionId: String
    private let api: WandAPI
    private let socket: PtySocketTransport
    private let defaults: UserDefaults
    private var started = false
    private var resizeWork: DispatchWorkItem?
    private var lastSize = ""
    private var permissionTask: Task<Void, Never>?
    private var resumeTask: Task<Void, Never>?

    var scaleLabel: String { "\(Int((scale * 100).rounded()))%" }
    var sessionEnded: Bool { ["exited", "failed", "stopped"].contains(status) }

    init(sessionId: String, api: WandAPI, socket: PtySocketTransport? = nil,
         defaults: UserDefaults = .standard) {
        self.sessionId = sessionId
        self.api = api
        self.defaults = defaults
        self.socket = socket ?? WandSocket(baseURL: api.baseURL, prepareConnection: {
            _ = try await api.getSession(id: sessionId)
        })
        let saved = defaults.double(forKey: "wand.nativeTerminalScale")
        scale = saved.isFinite && saved > 0 ? min(3, max(0.5, saved)) : 1
        terminal.setScale(scale)
        terminal.onInput = { [weak self] text, userInput in self?.sendInput(text, userInput: userInput) }
        terminal.onScaleChange = { [weak self] delta in self?.adjustScale(delta) }
        terminal.onSizeChange = { [weak self] cols, rows in
            // AppKit layout can run inside a SwiftUI update; publish after that transaction.
            DispatchQueue.main.async { self?.sizeChanged(cols: cols, rows: rows) }
        }
        self.socket.onEvent = { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        self.socket.onConnectionChange = { [weak self] connected in
            MainActor.assumeIsolated {
                guard let self, self.started else { return }
                if !connected {
                    self.ready = false
                    self.loading = false
                    self.lastSize = ""
                }
            }
        }
        self.socket.onResync = { [weak self] in
            MainActor.assumeIsolated { self?.ready = false }
        }
        self.socket.onError = { [weak self] message in
            MainActor.assumeIsolated {
                guard let self, self.started else { return }
                self.loadError = message
                self.loading = false
            }
        }
    }

    func start() {
        guard !started else { return }
        started = true
        loading = true
        socket.subscribe(sessionId: sessionId, ptyAck: true)
        socket.connect()
    }

    func shutdown() {
        started = false
        ready = false
        resizeWork?.cancel()
        resizeWork = nil
        permissionTask?.cancel()
        resumeTask?.cancel()
        socket.close()
    }

    func retry() {
        shutdown()
        loadError = nil
        start()
    }

    func refresh() {
        if ready { socket.requestResync() } else { retry() }
    }

    private func handle(_ event: WsIncoming) {
        guard started, event.sessionId == sessionId else { return }
        switch event.type {
        case "init":
            guard let data = event.data else { return }
            terminal.restore(data)
            applyMetadata(data, snapshot: true)
            loading = false
            loadError = nil
            ready = true
            lastSize = ""
            sizeChanged(cols: terminal.getTerminal().cols, rows: terminal.getTerminal().rows)
        case "output":
            if let chunk = event.data?.chunk, ready { terminal.feedOutput(chunk) }
            // SwiftTerm feed parses synchronously; ACK only after consumption.
            socket.acknowledgePty(bytes: event.ptyBytes ?? 0)
            if let data = event.data { applyMetadata(data) }
        case "status", "ended":
            if let data = event.data { applyMetadata(data) }
            if event.type == "ended" { status = event.data?.status ?? "exited" }
        case "error":
            loadError = event.error ?? "终端请求失败"
            loading = false
            ready = false
        case "pty_error":
            // 写入结果可能不确定；保持终端可读，阻止再次输入直到快照重新同步。
            loadError = "终端操作未确认。请检查输出后重新连接，避免重复执行命令。"
            loading = false
            ready = false
        default: break
        }
    }

    private func applyMetadata(_ data: WsData, snapshot: Bool = false) {
        if let value = data.status { status = value }
        if let value = data.cwd { cwd = value }
        if snapshot || data.permissionBlocked == false {
            pendingEscalation = nil
            legacyPermissionPrompt = nil
        }
        if let escalation = data.pendingEscalation {
            pendingEscalation = escalation
            legacyPermissionPrompt = nil
        } else if let prompt = data.permissionRequest, pendingEscalation == nil {
            legacyPermissionPrompt = prompt
        }
    }

    func sendInput(_ text: String, userInput: Bool = true) {
        guard started, ready, !sessionEnded else {
            if userInput { toast = "终端未就绪，输入未发送；连接恢复后请重新输入。" }
            return
        }
        socket.sendPtyInput(text, userInput: userInput)
    }

    private func sizeChanged(cols: Int, rows: Int) {
        guard PtyTerminalSnapshot.validSize(cols: cols, rows: rows) else { return }
        let label = "\(cols)×\(rows)"
        sizeLabel = label
        resizeWork?.cancel()
        resizeWork = nil
        guard started, ready, !sessionEnded, label != lastSize else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.started, self.ready, !self.sessionEnded,
                  self.sizeLabel == label else { return }
            self.lastSize = label
            self.socket.resizePty(cols: cols, rows: rows)
        }
        resizeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    func adjustScale(_ delta: Double?) {
        scale = delta.map { min(3, max(0.5, scale + $0)) } ?? 1
        defaults.set(scale, forKey: "wand.nativeTerminalScale")
        terminal.setScale(scale)
    }

    func resolvePermission(_ resolution: String) {
        guard permissionTask == nil else { return }
        let escalation = pendingEscalation
        guard escalation != nil || legacyPermissionPrompt != nil else { return }
        permissionTask = Task { [weak self] in
            guard let self else { return }
            defer { self.permissionTask = nil }
            do {
                if let escalation {
                    _ = try await self.api.resolveEscalation(sessionId: self.sessionId,
                        requestId: escalation.requestId, resolution: resolution)
                } else if resolution == "deny" {
                    _ = try await self.api.denyPermission(sessionId: self.sessionId)
                } else {
                    _ = try await self.api.approvePermission(sessionId: self.sessionId)
                }
                guard self.started, !Task.isCancelled else { return }
                self.socket.requestResync()
            } catch {
                guard self.started, !Task.isCancelled else { return }
                self.toast = error.localizedDescription
            }
        }
    }

    func resume() {
        guard resumeTask == nil else { return }
        resumeTask = Task { [weak self] in
            guard let self else { return }
            defer { self.resumeTask = nil }
            do {
                _ = try await self.api.resumeSession(id: self.sessionId)
                guard self.started, !Task.isCancelled else { return }
                self.refresh()
            } catch {
                guard self.started, !Task.isCancelled else { return }
                self.toast = error.localizedDescription
            }
        }
    }
}
