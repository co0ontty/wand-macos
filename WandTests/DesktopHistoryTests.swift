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
