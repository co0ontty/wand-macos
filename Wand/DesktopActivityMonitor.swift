import AppKit
import Combine
import CryptoKit
import UserNotifications

protocol DesktopActivityServing: AnyObject {
    func listSessions() async throws -> [SessionSnapshot]
    func getSession(id: String, blockBudget: Int) async throws -> SessionSnapshot
}
extension WandAPI: DesktopActivityServing {}

/// App-owned, not tied to the visible ChatStore: background and task-bound sessions are included.
@MainActor
final class DesktopActivityMonitor: ObservableObject {
    static let shared = DesktopActivityMonitor(defaults: NativeAcceptance.defaults)
    @Published private(set) var activities: [DesktopActivity] = []
    @Published private(set) var connectionLabel = "未连接服务器"
    @Published private(set) var isFresh = false
    @Published private(set) var notificationsEnabled: Bool
    @Published private(set) var islandEnabled: Bool
    @Published private(set) var notificationMessage = "关键节点通知尚未开启"
    @Published private(set) var pendingOpenSessionID: String?
    private(set) var connectionID = UUID()
    private(set) var sourceID: String?
    private var ledger = DesktopActivityLedger()
    private var api: DesktopActivityServing?
    private var polling: Task<Void, Never>?
    private var observation: AnyCancellable?
    private var refreshing = false
    private struct ProgressSample {
        let identity: String
        let progress: DesktopExecutionProgress?
    }
    private var progressSamples: [String: ProgressSample] = [:]
    private var progressTask: Task<Void, Never>?
    private var pendingEvents: [DesktopActivityEvent] = []
    private var progressCursor = 0
    private var milestoneSequence = 0
    private let defaults: UserDefaults
    var onEvents: (([DesktopActivityEvent]) -> Void)?
    var onReset: (() -> Void)?
    var onOpenWindow: (() -> Void)?

    init(defaults: UserDefaults) {
        self.defaults = defaults
        notificationsEnabled = defaults.bool(forKey: "wand.desktop.notifications")
        islandEnabled = defaults.bool(forKey: "wand.desktop.activityIsland")
    }

    var summary: String {
        guard isFresh else { return connectionLabel }
        let running = activities.filter { $0.phase == .running }.count
        let waiting = activities.filter { $0.phase == .waiting }.count
        if waiting > 0 { return "\(waiting) 待处理 · \(running) 执行中" }
        if running > 0 { return "\(running) 个任务执行中" }
        return activities.isEmpty ? "暂无执行中的任务" : "任务有新进展"
    }

    func start(store: ServerStore) {
        guard observation == nil else { return }
        observation = store.$connectionID.sink { [weak self, weak store] id in
            Task { @MainActor in
                guard let self, let store, id == store.connectionID else { return }
                self.connect(id: id, api: store.serverURL.map { WandAPI(baseURL: $0, token: store.token) }, sourceID: store.serverURL.map(Self.sourceIdentifier))
            }
        }
    }

    func connect(id: UUID, api: DesktopActivityServing?, poll: Bool = true, sourceID: String? = nil) {
        polling?.cancel()
        progressTask?.cancel()
        progressTask = nil
        progressSamples = [:]
        pendingEvents = []
        progressCursor = 0
        connectionID = id
        self.api = api
        self.sourceID = sourceID
        refreshing = false
        isFresh = false
        activities = []
        pendingOpenSessionID = nil
        ledger.reset()
        connectionLabel = api == nil ? "未连接服务器" : "正在同步任务"
        onReset?()
        guard api != nil, poll else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                // Metadata stays timely even when a separate, bounded progress read is slow.
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    func stop() {
        polling?.cancel()
        polling = nil
        observation = nil
        connect(id: UUID(), api: nil, poll: false)
    }

    func refresh(waitForProgress: Bool = false) async {
        guard let api, !refreshing else { return }
        let id = connectionID
        refreshing = true
        defer { if id == connectionID { refreshing = false } }
        do {
            let snapshots = try await api.listSessions()
            guard id == connectionID, !Task.isCancelled else { return }
            let events = ledger.apply(snapshots)
            progressSamples = progressSamples.filter { key, sample in ledger.previous[key]?.stateIdentity == sample.identity }
            for event in events {
                pendingEvents.removeAll { $0.activity.id == event.activity.id }
                pendingEvents.append(event)
            }
            // Coalesced to one node per known session; don't silently drop a burst of completions.
            pendingEvents.removeAll { ledger.previous[$0.activity.id] == nil }
            activities = ledger.visible.map(decorated)
            isFresh = true
            connectionLabel = "已连接"
            startProgressRefresh(api: api, connection: id)
            if waitForProgress { await progressTask?.value }
        } catch {
            guard id == connectionID, !Task.isCancelled else { return }
            // Never infer completion from a failed fetch or disappearance.
            isFresh = false
            connectionLabel = "连接中断 · 状态待同步"
            ledger.loseConnection()
            progressTask?.cancel()
            progressTask = nil
            progressSamples = [:]
            pendingEvents = []
            activities = []
        }
    }

    private func decorated(_ activity: DesktopActivity) -> DesktopActivity {
        guard let sample = progressSamples[activity.id], sample.identity == activity.stateIdentity else { return activity }
        var result = activity
        result.progress = sample.progress
        result.progressUnavailable = sample.progress == nil
        return result
    }

    /// At most four bounded chat suffixes at once; no raw tool arguments/results are retained.
    /// Key-node events are enriched before delivery; detail failures never hide authoritative status.
    private func startProgressRefresh(api: DesktopActivityServing, connection: UUID) {
        guard progressTask == nil, isFresh else { return }
        let eventBatch = Array(pendingEvents.prefix(4))
        var candidates = eventBatch.map(\.activity)
        let visible = ledger.visible
        if !visible.isEmpty {
            let offset = progressCursor % visible.count
            let rotated = Array(visible.dropFirst(offset)) + Array(visible.prefix(offset))
            for activity in rotated where !candidates.contains(where: { $0.id == activity.id }) {
                guard candidates.count < 4 else { break }
                if activity.phase.isActive || progressSamples[activity.id] == nil { candidates.append(activity) }
            }
            progressCursor = (offset + max(1, candidates.count - eventBatch.count)) % visible.count
        }
        guard !candidates.isEmpty else { return }
        progressTask = Task { [weak self] in
            let samples = await withTaskGroup(of: (DesktopActivity, DesktopExecutionProgress?).self) { group in
                for activity in candidates {
                    group.addTask {
                        guard !Task.isCancelled,
                              let snapshot = try? await api.getSession(id: activity.id, blockBudget: WandAPI.chatBlockWindow),
                              !Task.isCancelled,
                              DesktopActivity(snapshot).stateIdentity == activity.stateIdentity else { return (activity, nil) }
                        return (activity, DesktopExecutionProgress(snapshot: snapshot))
                    }
                }
                var samples: [(DesktopActivity, DesktopExecutionProgress?)] = []
                for await sample in group { samples.append(sample) }
                return samples
            }
            guard let self, connection == self.connectionID, !Task.isCancelled else { return }
            var milestones: [DesktopActivityEvent] = []
            for (activity, progress) in samples {
                let old = self.progressSamples[activity.id]
                self.progressSamples[activity.id] = ProgressSample(identity: activity.stateIdentity, progress: progress)
                if activity.phase.isActive, old?.identity == activity.stateIdentity,
                   let previous = old?.progress?.completedSteps, let completed = progress?.completedSteps,
                   completed > previous, progress?.coversCurrentTurn == true,
                   !eventBatch.contains(where: { $0.activity.id == activity.id }) {
                    self.milestoneSequence += 1
                    milestones.append(DesktopActivityEvent(kind: .stepCompleted, activity: self.decorated(activity), sequence: self.milestoneSequence))
                }
            }
            self.activities = self.ledger.visible.map(self.decorated)
            let delivered = eventBatch.map { DesktopActivityEvent(kind: $0.kind, activity: self.decorated($0.activity), sequence: $0.sequence) }
            let deliveredIDs = Set(eventBatch.map(\.id))
            self.pendingEvents.removeAll { deliveredIDs.contains($0.id) }
            self.progressTask = nil
            if !(delivered + milestones).isEmpty { self.onEvents?(delivered + milestones) }
            if !self.pendingEvents.isEmpty { self.startProgressRefresh(api: api, connection: connection) }
        }
    }

    func dismissRecent() {
        ledger.dismissRecent()
        activities = ledger.visible.map(decorated)
    }

    func setIslandEnabled(_ enabled: Bool) {
        islandEnabled = enabled
        defaults.set(enabled, forKey: "wand.desktop.activityIsland")
    }

    func setNotificationsEnabled(_ enabled: Bool) {
        notificationsEnabled = enabled
        defaults.set(enabled, forKey: "wand.desktop.notifications")
    }

    func setNotificationMessage(_ value: String) { notificationMessage = value }

    func openSession(_ id: String) {
        guard isFresh, ledger.previous[id] != nil else { return }
        pendingOpenSessionID = id
        onOpenWindow?()
        NotificationCenter.default.post(name: .wandOpenActivitySession, object: nil)
    }

    static func sourceIdentifier(_ url: URL) -> String {
        // Stable across launches, opaque in Notification Center, and excludes credentials / URL query.
        let scheme = url.scheme?.lowercased() ?? ""
        let origin = "\(scheme)://\(url.host?.lowercased() ?? ""):\(url.port ?? (scheme == "https" ? 443 : 80))"
        return SHA256.hash(data: Data(origin.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func openNotificationSession(_ id: String, source: String) {
        guard !id.isEmpty, sourceID == source, api != nil else { return }
        pendingOpenSessionID = id
        onOpenWindow?()
        NotificationCenter.default.post(name: .wandOpenActivitySession, object: nil)
    }

    func consumeOpenSession(_ id: String) {
        if pendingOpenSessionID == id { pendingOpenSessionID = nil }
    }
}

protocol DesktopNotificationCenter: AnyObject {
    var delegate: UNUserNotificationCenterDelegate? { get set }
    func requestAuthorization(options: UNAuthorizationOptions, completionHandler: @escaping @Sendable (Bool, Error?) -> Void)
    func getNotificationSettings(completionHandler: @escaping @Sendable (UNNotificationSettings) -> Void)
    func add(_ request: UNNotificationRequest, withCompletionHandler completionHandler: (@Sendable (Error?) -> Void)?)
    func removePendingNotificationRequests(withIdentifiers identifiers: [String])
    func removeDeliveredNotifications(withIdentifiers identifiers: [String])
}
extension UNUserNotificationCenter: DesktopNotificationCenter {}

/// Authorization is requested only by the user's enable action, never by startup or polling.
@MainActor
final class DesktopActivityNotifications: NSObject, UNUserNotificationCenterDelegate {
    private let monitor: DesktopActivityMonitor
    private let center: DesktopNotificationCenter
    private var generation = UUID()
    private var pendingSessionIDs: [String: String] = [:]
    private var deliveredOrder: [String] = []

    init(monitor: DesktopActivityMonitor, center: DesktopNotificationCenter = UNUserNotificationCenter.current()) {
        self.monitor = monitor
        self.center = center
        super.init()
        center.delegate = self
    }

    func reset() {
        generation = UUID()
        let identifiers = Array(pendingSessionIDs.keys)
        pendingSessionIDs = [:]
        deliveredOrder = []
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled else {
            monitor.setNotificationsEnabled(false)
            reset()
            monitor.setNotificationMessage("关键节点通知已关闭")
            return
        }
        let requestGeneration = generation
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            Task { @MainActor in
                guard let self, requestGeneration == self.generation else { return }
                self.monitor.setNotificationsEnabled(granted && error == nil)
                self.monitor.setNotificationMessage(granted && error == nil
                    ? "通知已开启；横幅、声音和预览由系统设置控制"
                    : "通知未获授权，请在系统设置 → 通知 → Wand 中开启")
            }
        }
    }

    func refreshAuthorization() {
        center.getNotificationSettings { [weak self] settings in
            Task { @MainActor in
                guard let self else { return }
                let allowed = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
                if self.monitor.notificationsEnabled && !allowed {
                    self.monitor.setNotificationMessage("通知被系统禁用，请在系统设置 → 通知 → Wand 中开启")
                } else if self.monitor.notificationsEnabled {
                    self.monitor.setNotificationMessage("通知已开启；横幅、声音和预览由系统设置控制")
                }
            }
        }
    }

    func deliver(_ events: [DesktopActivityEvent]) {
        guard monitor.notificationsEnabled else { return }
        for event in events {
            // One delivered banner per session; don't expose prompts, commands, paths, or error payloads.
            let identifier = "wand.activity.\(generation.uuidString).\(event.activity.id)"
            pendingSessionIDs[identifier] = event.activity.id
            deliveredOrder.removeAll { $0 == identifier }
            deliveredOrder.append(identifier)
            if deliveredOrder.count > 64 {
                let removed = deliveredOrder.removeFirst()
                pendingSessionIDs[removed] = nil
                center.removeDeliveredNotifications(withIdentifiers: [removed])
            }
            let content = UNMutableNotificationContent()
            content.title = event.notificationTitle
            content.subtitle = event.activity.identityLabel
            content.body = event.activity.executionSummary
            content.sound = .default
            if let source = monitor.sourceID {
                content.userInfo = ["sessionId": event.activity.id, "source": source]
            }
            let deliveryGeneration = generation
            center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil)) { [weak self] error in
                Task { @MainActor in
                    guard let self else { return }
                    guard deliveryGeneration == self.generation else {
                        self.center.removePendingNotificationRequests(withIdentifiers: [identifier])
                        self.center.removeDeliveredNotifications(withIdentifiers: [identifier])
                        return
                    }
                    if error != nil { self.monitor.setNotificationMessage("通知发送失败，请检查系统通知权限") }
                }
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        Task { @MainActor [weak self] in
            let allowed = self?.monitor.notificationsEnabled == true
                && self?.pendingSessionIDs[notification.request.identifier] != nil
            completionHandler(allowed ? [.banner, .list, .sound] : [])
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor [weak self] in
            if let self {
                let info = response.notification.request.content.userInfo
                if let id = info["sessionId"] as? String, let source = info["source"] as? String {
                    self.monitor.openNotificationSession(id, source: source)
                } else if let id = self.pendingSessionIDs[response.notification.request.identifier] {
                    self.monitor.openSession(id)
                }
            }
            completionHandler()
        }
    }
}

extension Notification.Name {
    static let wandOpenActivitySession = Notification.Name("WandOpenActivitySession")
}
