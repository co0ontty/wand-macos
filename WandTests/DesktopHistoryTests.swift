import Foundation
import XCTest
@testable import Wand

final class DesktopHistoryTests: XCTestCase {
    func testOneProviderFailureKeepsItsPreviousHistoryAndRefreshesTheOther() {
        let previous = [history("claude-old", provider: nil), history("codex-old", provider: "codex")]
        let merged = LegacyHistoryRefresh.merge(previous: previous, results: [
            LegacyHistoryRefresh(provider: "claude", sessions: nil),
            LegacyHistoryRefresh(provider: "codex", sessions: [history("codex-new", provider: nil)]),
        ])
        XCTAssertEqual(merged.map(\.claudeSessionId), ["claude-old", "codex-new"])
        XCTAssertEqual(merged.last?.provider, "codex", "The endpoint identifies untagged legacy records.")
    }

    func testEmptyCurrentServerHistoryResponseRemovesLegacyRecords() {
        let merged = LegacyHistoryRefresh.merge(
            previous: [history("old", provider: nil)],
            results: [LegacyHistoryRefresh(provider: "claude", sessions: [])]
        )
        XCTAssertTrue(merged.isEmpty)
    }

    func testUnavailableLegacyEndpointsDoNotEraseTheLastKnownHistory() {
        let merged = LegacyHistoryRefresh.merge(
            previous: [history("old", provider: "codex")],
            results: [
                LegacyHistoryRefresh(provider: "claude", sessions: nil),
                LegacyHistoryRefresh(provider: "codex", sessions: nil),
            ]
        )
        XCTAssertEqual(merged.map(\.claudeSessionId), ["old"])
    }

    func testUnknownHistoryProviderCannotFallThroughToClaudeMutations() throws {
        XCTAssertEqual(try WandAPI.legacyHistoryProvider(nil), "claude")
        XCTAssertEqual(try WandAPI.legacyHistoryProvider("opencode"), "opencode")
        XCTAssertEqual(try WandAPI.legacyHistoryProvider("qoder"), "qoder")
        for provider in ["grok", "pi", "unknown", "../../claude"] {
            XCTAssertThrowsError(try WandAPI.legacyHistoryProvider(provider))
        }
    }

    private func history(_ id: String, provider: String?) -> HistorySession {
        HistorySession(
            claudeSessionId: id, cwd: "/project", firstUserMessage: "历史任务",
            timestamp: nil, mtimeMs: 1, hasConversation: true,
            managedByWand: false, provider: provider
        )
    }
}

/// 「单独会话」列表的排序时间必须和行上显示的时间同一口径（macOS 问题清单 #8）。
final class SessionSidebarSortTests: XCTestCase {
    func testEndedSessionSortsByItsEndTime() {
        let yesterday = "2026-09-23T10:00:00.000Z"
        let lastWeek = "2026-09-18T10:00:00.000Z"
        let justNow = "2026-09-24T10:00:00.000Z"

        let stillRunning = SessionTimeFormatting.sessionSortTimestamp(
            startedAt: yesterday, endedAt: nil
        )
        let finished = SessionTimeFormatting.sessionSortTimestamp(
            startedAt: lastWeek, endedAt: justNow
        )

        XCTAssertGreaterThan(finished, stillRunning, "刚结束的会话必须排在只有旧开始时间的会话上面。")
    }

    func testRunningSessionSortsByStartTimeAndMissingTimesSink() {
        let started = "2026-09-24T09:00:00.000Z"
        XCTAssertEqual(
            SessionTimeFormatting.sessionSortTimestamp(startedAt: started, endedAt: nil),
            SessionTimeFormatting.date(from: started)!.timeIntervalSince1970,
            accuracy: 0.001
        )
        XCTAssertEqual(SessionTimeFormatting.sessionSortTimestamp(startedAt: nil, endedAt: nil), 0)
    }

    func testEndTimeWinsOverStartTime() {
        let started = "2026-09-24T09:00:00.000Z"
        let ended = "2026-09-24T11:00:00.000Z"
        XCTAssertEqual(
            SessionTimeFormatting.sessionSortTimestamp(startedAt: started, endedAt: ended),
            SessionTimeFormatting.date(from: ended)!.timeIntervalSince1970,
            accuracy: 0.001
        )
    }
}
