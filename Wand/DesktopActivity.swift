import Foundation

/// Desktop surfaces are projections of the server's execution facts, never process lifetime alone.
struct DesktopActivity: Identifiable, Equatable, Sendable {
    enum Phase: String, Sendable {
        case running, waiting, completed, failed, stopped, idle

        var label: String {
            switch self {
            case .running: return "执行中"
            case .waiting: return "等待处理"
            case .completed: return "执行完成"
            case .failed: return "执行失败"
            case .stopped: return "已停止"
            case .idle: return "空闲"
            }
        }

        var symbol: String {
            switch self {
            case .running: return "arrow.triangle.2.circlepath"
            case .waiting: return "hand.raised.fill"
            case .completed: return "checkmark.circle.fill"
            case .failed: return "exclamationmark.circle.fill"
            case .stopped: return "stop.circle"
            case .idle: return "moon"
            }
        }

        var isActive: Bool { self == .running || self == .waiting }
    }

    let id: String
    let title: String
    let phase: Phase
    let completionRevision: Int
    let requestID: String?
    let startedAt: String?
    let providerLabel: String
    let model: String?
    let activeRequestID: String?
    var progress: DesktopExecutionProgress?
    var progressUnavailable = false

    var stateIdentity: String {
        "\(id):\(phase.rawValue):\(completionRevision):\(requestID ?? ""):\(activeRequestID ?? ""):\(providerLabel):\(model ?? "")"
    }

    var identityLabel: String {
        [providerLabel, model].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var progressLabel: String {
        progress?.progressLabel ?? (progressUnavailable ? "进度暂不可用" : "正在同步执行进度")
    }

    var executionSummary: String {
        [progressLabel, progress?.toolLabel, progress?.resultLabel,
         progress?.elapsed.map { "本轮用时 \($0)" }].compactMap { $0 }.joined(separator: " · ")
    }

    var notificationBody: String { [title, identityLabel, executionSummary].joined(separator: "\n") }

    init(_ snapshot: SessionSnapshot) {
        id = snapshot.id
        title = String(snapshot.displayTitle.prefix(120))
        completionRevision = snapshot.completionRevision ?? 0
        requestID = snapshot.pendingEscalation?.requestId
        startedAt = snapshot.startedAt
        providerLabel = (snapshot.provider ?? "").isEmpty && !snapshot.isStructured ? "Shell 终端" : snapshot.providerLabel
        model = snapshot.structuredState?.model ?? snapshot.selectedModel
        activeRequestID = snapshot.structuredState?.activeRequestId
        phase = Self.phase(for: snapshot)
        if snapshot.messages != nil { progress = DesktopExecutionProgress(snapshot: snapshot) }
    }

    static func phase(for snapshot: SessionSnapshot) -> Phase {
        let responding = snapshot.isStructured || isProviderCliSession(snapshot.provider)
            ? snapshot.isResponding
            : snapshot.status == "running" && snapshot.ptyCommandRunning == true
        if snapshot.status == "failed" {
            return .failed
        } else if snapshot.status == "stopped" {
            return .stopped
        } else if snapshot.hasPendingPermission || ["waiting_input", "waiting-input", "waiting_user"].contains(snapshot.status ?? "") {
            return .waiting
        } else if responding || snapshot.status == "initializing" {
            return .running
        } else if (snapshot.exitCode.map { $0 != 0 } ?? false)
                    || (snapshot.providerCliExitCode.map { $0 != 0 } ?? false)
                    || !(snapshot.structuredState?.lastError ?? "").isEmpty {
            return .failed
        } else if (snapshot.completionRevision ?? 0) > 0 {
            return .completed
        } else {
            // An idle provider, removed row, disconnect, or exit without a completion receipt isn't success.
            return .idle
        }
    }
}

struct DesktopActivityEvent: Identifiable, Equatable {
    enum Kind: Equatable { case stateChange, stepCompleted }
    var kind: Kind = .stateChange
    let activity: DesktopActivity
    let sequence: Int
    var id: String { "\(activity.id):\(sequence)" }
    var notificationTitle: String {
        kind == .stepCompleted ? "步骤进展 · \(activity.title)" : "\(activity.phase.label) · \(activity.title)"
    }
}

/// Edge detection stays independent of AppKit/notification authorization for deterministic tests.
struct DesktopActivityLedger {
    private(set) var previous: [String: DesktopActivity] = [:]
    private(set) var recent: [DesktopActivityEvent] = []
    private var hasBaseline = false
    private var sequence = 0
    private var baselineAt = Date()

    mutating func reset() { self = Self() }

    mutating func loseConnection() {
        // Reconnection is a new baseline: don't replay events accumulated while offline.
        hasBaseline = false
        recent = []
    }

    mutating func apply(_ snapshots: [SessionSnapshot], now: Date = Date()) -> [DesktopActivityEvent] {
        let activities = snapshots.filter { $0.archived != true }.map(DesktopActivity.init)
        let next = Dictionary(activities.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        defer { previous = next; hasBaseline = true }
        guard hasBaseline else { baselineAt = now; return [] }
        var events: [DesktopActivityEvent] = []
        for activity in activities {
            let old = previous[activity.id]
            let newCompletion = activity.completionRevision > (old?.completionRevision ?? 0)
            let changed = old?.phase != activity.phase
                || (activity.phase == .waiting && old?.requestID != activity.requestID)
                || (!activity.phase.isActive && newCompletion)
            guard changed, activity.phase != .running, activity.phase != .idle else { continue }
            if old == nil {
                // A newly discovered historical row must not produce a notification storm.
                guard let started = activity.startedAt.flatMap(Self.parseDate), started >= baselineAt else { continue }
            }
            sequence += 1
            let event = DesktopActivityEvent(activity: activity, sequence: sequence)
            events.append(event)
            recent.removeAll { $0.activity.id == activity.id }
            recent.insert(event, at: 0)
        }
        recent.removeAll { next[$0.activity.id] == nil || next[$0.activity.id]?.phase.isActive == true }
        recent = Array(recent.prefix(12))
        return events
    }

    mutating func dismissRecent() { recent = [] }

    var visible: [DesktopActivity] {
        let active = previous.values.filter { $0.phase.isActive }.sorted {
            if $0.phase != $1.phase { return $0.phase == .waiting }
            return $0.id < $1.id
        }
        return active + recent.compactMap { event in
            guard let current = previous[event.activity.id], !current.phase.isActive else { return nil }
            return current
        }
    }

    private static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}
