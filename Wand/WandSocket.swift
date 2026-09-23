import Foundation

/// Single-session transport shared by native chat and the AppKit terminal.
/// Callbacks and queue mutations stay on the main thread; never replay input after reconnect.
protocol PtySocketTransport: AnyObject {
    var onEvent: ((WsIncoming) -> Void)? { get set }
    var onConnectionChange: ((Bool) -> Void)? { get set }
    var onResync: (() -> Void)? { get set }
    var onError: ((String) -> Void)? { get set }
    func connect()
    func close()
    func subscribe(sessionId: String, ptyAck: Bool)
    func requestResync()
    func sendPtyInput(_ text: String, userInput: Bool)
    func resizePty(cols: Int, rows: Int)
    func acknowledgePty(bytes: Int)
}

final class WandSocket: PtySocketTransport {
    var onEvent: ((WsIncoming) -> Void)?
    var onConnectionChange: ((Bool) -> Void)?
    var onResync: (() -> Void)?
    var onError: ((String) -> Void)?

    private let baseURL: URL
    private let prepareConnection: (() async throws -> Void)?
    private var preparation: Task<Void, Never>?
    private var task: URLSessionWebSocketTask?
    private var subscribedSessionId: String?
    private var ptyAck = false
    private var awaitingSnapshot = true
    private var lastSeq: Int?
    private var lastMessageAt = Date()
    private var watchdog: Timer?
    private var reconnectDelay: TimeInterval = 1
    private var closed = true
    private var connected = false
    private var generation = 0
    private var sendQueue: [String] = []
    private var queuedBytes = 0
    private var sending = false

    init(baseURL: URL, prepareConnection: (() async throws -> Void)? = nil) {
        self.baseURL = baseURL
        self.prepareConnection = prepareConnection
    }

    deinit {
        preparation?.cancel()
        watchdog?.invalidate()
        task?.cancel(with: .goingAway, reason: nil)
    }

    func connect() {
        guard closed else { return }
        closed = false
        openSocket()
        startWatchdog()
    }

    func close() {
        closed = true
        watchdog?.invalidate()
        watchdog = nil
        invalidateConnection()
    }

    func subscribe(sessionId: String, ptyAck: Bool = false) {
        subscribedSessionId = sessionId
        self.ptyAck = ptyAck
        awaitingSnapshot = true
        lastSeq = nil
        sendSubscription()
    }

    private func sendSubscription() {
        guard let id = subscribedSessionId else { return }
        sendJSON(["type": "subscribe", "sessionId": id, "capabilities": ["ptyAck": ptyAck]])
    }

    func requestResync() {
        guard let id = subscribedSessionId else { return }
        awaitingSnapshot = true
        onResync?()
        sendJSON(["type": "resync", "sessionId": id])
    }

    func sendPtyInput(_ text: String, userInput: Bool) {
        guard connected, !awaitingSnapshot, let id = subscribedSessionId else { return }
        for chunk in PtyTerminalInput.chunks(text) {
            var payload: [String: Any] = [
                "type": "pty_input", "sessionId": id, "data": chunk, "userInput": userInput,
            ]
            if userInput && chunk == "\r" { payload["shortcutKey"] = "enter_text" }
            sendJSON(payload)
        }
    }

    func resizePty(cols: Int, rows: Int) {
        guard connected, !awaitingSnapshot, let id = subscribedSessionId,
              cols > 0, rows > 0 else { return }
        sendJSON(["type": "pty_resize", "sessionId": id, "cols": cols, "rows": rows])
    }

    func acknowledgePty(bytes: Int) {
        guard ptyAck, bytes > 0, let id = subscribedSessionId else { return }
        sendJSON(["type": "pty_ack", "sessionId": id, "bytes": bytes])
    }

    private var wsURL: URL? {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: true)
        components?.scheme = baseURL.scheme == "https" ? "wss" : "ws"
        components?.path = "/ws"
        components?.query = nil
        components?.fragment = nil
        return components?.url
    }

    private func openSocket() {
        guard !closed, let url = wsURL else { return }
        generation += 1
        let gen = generation
        awaitingSnapshot = true
        lastSeq = nil
        preparation = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                // A native REST request also renews an expired session cookie before WS upgrade.
                try await self.prepareConnection?()
                guard !self.closed, gen == self.generation else { return }
                let socket = SelfSignedSession.shared.session.webSocketTask(with: url)
                // Render v1 permits a 64 MiB attach frame; Node's init also adds session DTO.
                // Keep a bounded allowance above that size so large valid snapshots can resync.
                socket.maximumMessageSize = 80 * 1024 * 1024
                self.task = socket
                self.lastMessageAt = Date()
                socket.resume()
                self.sendSubscription()
                self.receiveNext(socket, generation: gen)
            } catch {
                guard !self.closed, gen == self.generation else { return }
                self.onError?(error.localizedDescription)
                self.scheduleReconnect()
            }
        }
    }

    private func receiveNext(_ socket: URLSessionWebSocketTask, generation gen: Int) {
        socket.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self, !self.closed, gen == self.generation else { return }
                switch result {
                case .failure:
                    self.scheduleReconnect()
                case .success(let message):
                    self.lastMessageAt = Date()
                    self.reconnectDelay = 1
                    if !self.connected {
                        self.connected = true
                        self.onConnectionChange?(true)
                    }
                    switch message {
                    case .string(let text): self.handle(Data(text.utf8))
                    case .data(let data): self.handle(data)
                    @unknown default: break
                    }
                    self.receiveNext(socket, generation: gen)
                }
            }
        }
    }

    // Internal for deterministic protocol tests, without opening a network connection.
    func handle(_ data: Data) {
        guard let incoming = try? JSONDecoder().decode(WsIncoming.self, from: data) else { return }
        if incoming.type == "ping" {
            sendJSON(["type": "pong", "t": incoming.t ?? 0])
            return
        }
        guard incoming.sessionId == nil || incoming.sessionId == subscribedSessionId else { return }
        switch incoming.type {
        case "resync_required":
            requestResync()
            return
        case "init":
            lastSeq = incoming.seq
            awaitingSnapshot = false
        case "output":
            // Drop stale queued frames, but ACK them so the server's backlog can drain.
            if awaitingSnapshot || (incoming.seq != nil && lastSeq != nil && incoming.seq! <= lastSeq!) {
                acknowledgePty(bytes: incoming.ptyBytes ?? 0)
                return
            }
            if let seq = incoming.seq, let lastSeq, seq > lastSeq + 1 {
                acknowledgePty(bytes: incoming.ptyBytes ?? 0)
                requestResync()
                return
            }
            if let seq = incoming.seq { lastSeq = seq }
        default: break
        }
        onEvent?(incoming)
    }

    private func sendJSON(_ payload: [String: Any]) {
        guard task != nil,
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else { return }
        guard queuedBytes + data.count <= 2 * 1024 * 1024 else {
            onError?("终端发送积压，连接已重置；未确认的输入不会自动重发。")
            scheduleReconnect()
            return
        }
        sendQueue.append(text)
        queuedBytes += data.count
        drainSendQueue()
    }

    private func drainSendQueue() {
        guard !sending, let socket = task, let text = sendQueue.first else { return }
        sending = true
        let gen = generation
        socket.send(.string(text)) { [weak self] error in
            DispatchQueue.main.async {
                guard let self, gen == self.generation else { return }
                if error != nil {
                    self.onError?("终端发送失败；未确认的输入不会自动重发。")
                    self.scheduleReconnect()
                    return
                }
                self.sendQueue.removeFirst()
                self.queuedBytes -= text.utf8.count
                self.sending = false
                self.drainSendQueue()
            }
        }
    }

    private func invalidateConnection() {
        generation += 1
        preparation?.cancel()
        preparation = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        sendQueue.removeAll()
        queuedBytes = 0
        sending = false
        awaitingSnapshot = true
        connected = false
        onConnectionChange?(false)
    }

    private func scheduleReconnect() {
        guard !closed else { return }
        invalidateConnection()
        let gen = generation
        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, 30)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.closed, gen == self.generation else { return }
            self.openSocket()
        }
    }

    private func startWatchdog() {
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            guard let self, !self.closed, self.task != nil else { return }
            if Date().timeIntervalSince(self.lastMessageAt) > 40 { self.scheduleReconnect() }
        }
    }
}
