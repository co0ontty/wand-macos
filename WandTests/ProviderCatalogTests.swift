import Foundation
import XCTest
@testable import Wand

/// provider 名单与归一规则必须与服务端 `src/provider-catalog.ts` 一致。
/// 历史回归：macOS 曾另建一份只含 6 个 provider 的枚举，Gemini 整体缺失，
/// 且未知值兜底成 Claude —— Gemini 会话在界面上被错标成 Claude。
final class ProviderCatalogTests: XCTestCase {
    func testCatalogCoversEveryServerProvider() throws {
        XCTAssertEqual(
            WandProvider.allCases.map(\.rawValue),
            ["claude", "codex", "opencode", "grok", "qoder", "pi", "gemini"]
        )
    }

    func testGeminiNormalizesFromServerAliasesAndKeepsItsRunner() throws {
        for raw in ["gemini", "Gemini", " gemini-cli ", "gemini-cli-json"] {
            XCTAssertEqual(WandProvider(normalizing: raw), .gemini, raw)
            XCTAssertEqual(WandProvider.normalizedID(raw), "gemini", raw)
        }
        XCTAssertEqual(WandProvider.gemini.title, "Gemini")
        XCTAssertEqual(WandProvider.gemini.structuredRunner, "gemini-cli-json")
    }

    func testUnknownProviderIsNotDisguisedAsAKnownOne() throws {
        // 展示路径：认不出来的 provider 不得回落到 Claude 的名字。
        XCTAssertEqual(WandProvider.title(for: "gemini"), "Gemini")
        XCTAssertEqual(WandProvider.title(for: "qoder"), "Qoder")
        XCTAssertEqual(WandProvider.title(for: "some-future-cli"), "some-future-cli")
        XCTAssertEqual(WandProvider.title(for: nil), "Claude")
        XCTAssertNil(WandProvider.normalizedID("some-future-cli"))
        XCTAssertNil(WandProvider.normalizedID("  "))
        // 启动路径：跟服务端默认一致，未知历史值按 Claude 处理。
        XCTAssertEqual(WandProvider(normalizing: "some-future-cli"), .claude)
    }

    func testGeminiIsDispatchableAsATaskTarget() throws {
        XCTAssertEqual(WorkspaceSessionTarget(provider: .gemini), .gemini)
        XCTAssertEqual(WorkspaceSessionTarget.gemini.provider, .gemini)
        XCTAssertEqual(WorkspaceSessionTarget.gemini.title, "Gemini")
    }

    /// 档位名单是跨端不变量：macOS / iOS / Web / Android 必须是同一份。
    /// Gemini 走与 Web `getSupportedModes` 一样的兜底全量，不在客户端单方面收紧。
    func testModeListsMatchTheCrossClientInvariant() throws {
        func ids(_ provider: WandProvider) -> Set<String> {
            Set(NewSessionView.ModeOption.supported(for: provider).map(\.apiValue))
        }
        // 与 iOS WandProvider.supportedModeIDs 逐项对齐。
        XCTAssertEqual(ids(.codex), ["full-access"])
        XCTAssertEqual(ids(.opencode), ["default", "full-access", "managed"])
        XCTAssertEqual(ids(.grok), ["default", "full-access", "managed"])
        XCTAssertEqual(ids(.pi), ["default", "full-access", "managed"])
        XCTAssertEqual(ids(.qoder), ["default", "full-access", "auto-edit", "managed"])
        XCTAssertEqual(ids(.claude), ["default", "full-access", "auto-edit", "native", "managed"])
        XCTAssertEqual(ids(.gemini), ids(.claude))
    }

    func testGeminiModelsComeFromItsOwnCatalogNotClauses() throws {
        // 回归：Gemini 曾经落到 default 分支，显示 Claude 的模型列表和默认模型。
        let payload = """
        {
          "models": [{ "id": "claude-model", "label": "Claude Model" }],
          "codexModels": [],
          "geminiModels": [{ "id": "gemini-model", "label": "Gemini Model" }],
          "defaultModels": { "gemini": "gemini-model" }
        }
        """
        let decoded = try JSONDecoder().decode(ModelsResponse.self, from: Data(payload.utf8))
        XCTAssertEqual(decoded.models(for: "gemini").map(\.id), ["gemini-model"])
        XCTAssertEqual(decoded.models(for: "claude").map(\.id), ["claude-model"])
        XCTAssertEqual(decoded.defaultModelId(for: "gemini"), "gemini-model")
    }

    func testAliasListStillResolvesTheOlderProviders() throws {
        XCTAssertEqual(WandProvider(normalizing: "pi-cli-json"), .pi)
        XCTAssertEqual(WandProvider(normalizing: "qodercli"), .qoder)
        XCTAssertEqual(WandProvider(normalizing: "open_code"), .opencode)
    }

    /// 会话归档的语义边界：归档是软标记，只是从活跃列表拆进折叠区，
    /// 不改会话身份、不改归属，也不能把「字段缺失」当成已归档。
    func testArchivedSessionsSplitOutOfTheActiveListOnce() throws {
        let json = """
        [
          { "id": "a", "archived": false },
          { "id": "b", "archived": true },
          { "id": "c" },
          { "id": "d", "archived": true }
        ]
        """
        let sessions = try JSONDecoder().decode([WorkspaceSessionSummary].self, from: Data(json.utf8))
        let split = WorkspaceSessionSummary.splitArchived(sessions)
        XCTAssertEqual(split.active.map(\.id), ["a", "c"])
        XCTAssertEqual(split.archived.map(\.id), ["b", "d"])
    }

    func testBatchArchiveResponseTreatsMissingFailedAsSuccess() throws {
        let ok = try JSONDecoder().decode(
            SessionBatchArchiveResponse.self,
            from: Data(#"{"ok":true,"archived":2}"#.utf8)
        )
        XCTAssertEqual(ok.failed ?? [], [])
        XCTAssertEqual(ok.archived, 2)

        let partial = try JSONDecoder().decode(
            SessionBatchArchiveResponse.self,
            from: Data(#"{"ok":true,"archived":1,"failed":["x"]}"#.utf8)
        )
        XCTAssertEqual(partial.failed, ["x"])
    }

    /// 「刚完成」是纯展示态：判定与确认都不能顺手改会话生命周期，
    /// 也不能被列表刷新 / 自动选中 / 弹层挡住时消耗掉。
    func testJustCompletedRequiresAnUnviewedGeneration() throws {
        func justCompleted(
            completion: Int?,
            viewed: Int?,
            status: String? = "idle",
            archived: Bool? = false,
            ptyBusy: Bool? = false,
            inFlight: Bool? = false,
            permissionBlocked: Bool? = false,
            pendingEscalation: Bool? = false,
            exitCode: Int? = nil
        ) -> Bool {
            SessionCompletion.isJustCompleted(
                completion: completion, viewed: viewed, status: status, archived: archived,
                ptyBusy: ptyBusy, inFlight: inFlight, permissionBlocked: permissionBlocked,
                pendingEscalation: pendingEscalation, providerCliExitCode: exitCode
            )
        }

        XCTAssertTrue(justCompleted(completion: 3, viewed: 2))
        // 已看过、代次相同、或字段缺失都不是「刚完成」。
        XCTAssertFalse(justCompleted(completion: 2, viewed: 2))
        XCTAssertFalse(justCompleted(completion: nil, viewed: nil))
        // 运行中、归档、忙、等待授权、待处理提权都盖掉未读提示。
        XCTAssertFalse(justCompleted(completion: 3, viewed: 2, status: "failed"))
        XCTAssertTrue(justCompleted(completion: 3, viewed: 2, status: "exited"))
        XCTAssertFalse(justCompleted(completion: 3, viewed: 2, archived: true))
        XCTAssertFalse(justCompleted(completion: 3, viewed: 2, ptyBusy: true))
        XCTAssertFalse(justCompleted(completion: 3, viewed: 2, inFlight: true))
        XCTAssertFalse(justCompleted(completion: 3, viewed: 2, permissionBlocked: true))
        XCTAssertFalse(justCompleted(completion: 3, viewed: 2, pendingEscalation: true))
        // CLI 非零退出是失败，不是「完成但还没看」。
        XCTAssertFalse(justCompleted(completion: 3, viewed: 2, exitCode: 1))
        XCTAssertTrue(justCompleted(completion: 3, viewed: 2, exitCode: 0))
    }

    func testAcknowledgementNeedsAnExplicitVisibleOpen() throws {
        // 自动选中 / 没在屏幕上 / 有弹层，都不消耗完成代次。
        XCTAssertFalse(SessionCompletion.shouldAcknowledge(
            isJustCompleted: true, explicitOpen: false, isSelected: true, modalVisible: false))
        XCTAssertFalse(SessionCompletion.shouldAcknowledge(
            isJustCompleted: true, explicitOpen: true, isSelected: false, modalVisible: false))
        XCTAssertFalse(SessionCompletion.shouldAcknowledge(
            isJustCompleted: true, explicitOpen: true, isSelected: true, modalVisible: true))
        XCTAssertFalse(SessionCompletion.shouldAcknowledge(
            isJustCompleted: false, explicitOpen: true, isSelected: true, modalVisible: false))
        XCTAssertTrue(SessionCompletion.shouldAcknowledge(
            isJustCompleted: true, explicitOpen: true, isSelected: true, modalVisible: false))
    }

    func testCompletionGenerationsNeverMoveBackwards() throws {
        let merged = SessionCompletion.merge(
            current: (completion: 5, viewed: 2),
            incoming: (completion: 3, viewed: 1)
        )
        XCTAssertEqual(merged.completion, 5)
        XCTAssertEqual(merged.viewed, 2)
        let advanced = SessionCompletion.merge(
            current: (completion: 5, viewed: 2),
            incoming: (completion: nil, viewed: 6)
        )
        XCTAssertEqual(advanced.completion, 5)
        XCTAssertEqual(advanced.viewed, 6)
    }
}
