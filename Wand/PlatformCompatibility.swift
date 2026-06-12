import Combine
import SwiftUI

/// iOS-only integrations used by the shared native views. macOS keeps the same
/// view model surface while desktop-specific entry points remain unavailable.
enum QuickAction: Equatable {
    case newSession
    case openWeb
    case openSession(id: String)
}

final class QuickActionCoordinator: ObservableObject {
    static let shared = QuickActionCoordinator()

    @Published private(set) var pending: QuickAction?

    private init() {}

    func consume(where matches: (QuickAction) -> Bool) -> QuickAction? {
        guard let action = pending, matches(action) else { return nil }
        pending = nil
        return action
    }

    static func updateRecentSessionShortcuts(_ sessions: [SessionSnapshot]) {}
}

final class KeyboardObserver: ObservableObject {
    @Published private(set) var lift: CGFloat = 0
}

final class SpeechRecognizerService: ObservableObject {
    @Published private(set) var transcript = ""
    @Published private(set) var isRecording = false
    @Published private(set) var usingOnDevice = false

    func start(onError: @escaping (String) -> Void) {
        onError("macOS 暂不支持语音输入")
    }

    func stop(cancelled: Bool, commit: ((String) -> Void)? = nil) {}
}

enum SessionLiveActivityState {
    case responding
    case permission
}

final class SessionLiveActivityController {
    static let shared = SessionLiveActivityController()

    func start(sessionId: String, title: String, taskTitle: String?, queuedCount: Int) {}
    func update(sessionId: String, state: SessionLiveActivityState, taskTitle: String?, queuedCount: Int) {}
    func end(sessionId: String, immediately: Bool = false) {}
}
