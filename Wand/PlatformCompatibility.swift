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

// MARK: - iOS-only SwiftUI 修饰符的 macOS 垫片
// 原生视图（SessionListView / ChatView / ChatStore …）以 iOS 版为源头近乎原样拷贝，
// 这里补齐 iOS-only API 的 macOS 等价/空实现，让拷贝过来的代码不用改也能编译。
// 注意 `ToolbarItemPlacement.navigationBarTrailing` 之类在 macOS SDK 里是
// 「显式 unavailable」的真实符号，垫不掉——拷贝时要把它替换成 `.primaryAction`。

/// iOS `NavigationBarItem.TitleDisplayMode` 的占位（macOS 没有导航栏标题模式）。
enum WandTitleDisplayMode {
    case automatic, inline, large
}

extension View {
    /// macOS 没有 iOS 式导航栏：标题展示模式是 no-op。
    func navigationBarTitleDisplayMode(_ mode: WandTitleDisplayMode) -> some View { self }

    /// macOS 没有 iOS 式导航栏：隐藏导航栏是 no-op。
    func navigationBarHidden(_ hidden: Bool) -> some View { self }

    /// `.listRowSeparator(.hidden)` 需要 macOS 13+；deployment target 12 时降级保留分隔线。
    @ViewBuilder func wandHideListRowSeparator() -> some View {
        if #available(macOS 13.0, *) {
            self.listRowSeparator(.hidden)
        } else {
            self
        }
    }
}
