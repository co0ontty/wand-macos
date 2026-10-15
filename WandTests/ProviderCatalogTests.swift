import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import Wand

/// provider 名单与归一规则必须与服务端 `src/provider-catalog.ts` 一致。
final class ProviderCatalogTests: XCTestCase {
    func testCatalogCoversEveryServerProvider() throws {
        XCTAssertEqual(
            WandProvider.allCases.map(\.rawValue),
            ["claude", "codex", "opencode", "grok", "qoder", "pi"]
        )
    }


    func testUnknownProviderIsNotDisguisedAsAKnownOne() throws {
        // 展示路径：认不出来的 provider 不得回落到 Claude 的名字。
        XCTAssertEqual(WandProvider.title(for: "qoder"), "Qoder")
        XCTAssertEqual(WandProvider.title(for: "some-future-cli"), "some-future-cli")
        XCTAssertEqual(WandProvider.title(for: nil), "Claude")
        XCTAssertNil(WandProvider.normalizedID("some-future-cli"))
        XCTAssertNil(WandProvider.normalizedID("  "))
        // 启动路径：跟服务端默认一致，未知历史值按 Claude 处理。
        XCTAssertEqual(WandProvider(normalizing: "some-future-cli"), .claude)
    }


    /// 档位名单是跨端不变量：macOS / iOS / Web / Android 必须是同一份。

    func testBoardCatalogSnapshotLabelsKeepUnknownProviders() throws {
        XCTAssertEqual(wandBoardProviders, WandProvider.allCases.map(\.rawValue))
        for (provider, expected) in [("future-cli", "future-cli")] {
            let data = Data("{\"id\":\"test\",\"provider\":\"\(provider)\"}".utf8)
            let snapshot = try JSONDecoder().decode(SessionSnapshot.self, from: data)
            let summary = try JSONDecoder().decode(WorkspaceSessionSummary.self, from: data)
            XCTAssertEqual(snapshot.providerLabel, expected)
            XCTAssertEqual(summary.providerLabel, expected)
        }
    }

    func testSharedServerFixturePreservesExecutionAndOwnershipIdentity() throws {
        struct Expected: Decodable { let providerLabel: String; let badge: String?; let caption: String? }
        struct Entry: Decodable { let name: String; let payload: WorkspaceJSONValue; let expected: Expected }
        struct Fixture: Decodable { let providers: [String]; let cases: [Entry] }
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/session-identity.json")
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        XCTAssertEqual(fixture.providers, WandProvider.allCases.map(\.rawValue))
        for entry in fixture.cases {
            let data = try JSONEncoder().encode(entry.payload)
            let snapshot = try JSONDecoder().decode(SessionSnapshot.self, from: data)
            let summary = try JSONDecoder().decode(WorkspaceSessionSummary.self, from: data)
            for projection in [summary, WorkspaceSessionSummary(snapshot: snapshot)] {
                XCTAssertEqual(projection.providerLabel, entry.expected.providerLabel, entry.name)
                XCTAssertEqual(projection.identityBadge, entry.expected.badge, entry.name)
                XCTAssertEqual(projection.identityCaption, entry.expected.caption, entry.name)
                XCTAssertEqual(projection.employeeId, snapshot.employeeId)
                XCTAssertEqual(projection.employeeAvatar, snapshot.employeeAvatar)
                XCTAssertEqual(projection.teamChat, snapshot.teamChat)
                XCTAssertEqual(projection.teamStep, snapshot.teamStep)
                XCTAssertEqual(projection.workspaceTaskId, snapshot.workspaceTaskId)
            }
            XCTAssertEqual(snapshot.providerLabel, entry.expected.providerLabel, entry.name)
            XCTAssertEqual(snapshot.identityBadge, entry.expected.badge, entry.name)
            XCTAssertEqual(snapshot.identityCaption, entry.expected.caption, entry.name)
        }
        XCTAssertEqual(WandProvider.title(for: "pi-cli-json", engine: "sdk"), "Wand Agent")
        XCTAssertEqual(WandProvider.title(for: "codex", engine: "core"), "Codex")
    }

    @MainActor
    func testWebSocketInitAndStatusKeepExecutionIdentityWithoutResurrectingOldOwnership() throws {
        let api = WandAPI(baseURL: URL(string: "http://fixture.example.test")!, token: nil)
        let store = ChatStore(sessionId: "fixture", api: api)
        defer { store.shutdown() }
        func receive(_ json: String) throws {
            store.receiveForTesting(try JSONDecoder().decode(WsIncoming.self, from: Data(json.utf8)))
        }
        try receive("""
        {"type":"init","data":{"id":"fixture","provider":"pi","sessionKind":"structured",
        "structuredState":{"engine":"core","runner":"pi-cli-json"},"employeeId":"old","employeeName":"旧员工"}}
        """)
        XCTAssertEqual(store.snapshot?.providerLabel, "Wand Agent")
        XCTAssertEqual(store.snapshot?.employeeName, "旧员工")
        try receive("""
        {"type":"status","data":{"structuredState":{"engine":"cli","runner":"pi-cli-json"}}}
        """)
        XCTAssertEqual(store.snapshot?.providerLabel, "Pi")
        try receive("""
        {"type":"init","data":{"id":"fixture","provider":"pi","sessionKind":"structured",
        "structuredState":{"engine":"core","runner":"pi-cli-json"}}}
        """)
        XCTAssertEqual(store.snapshot?.providerLabel, "Wand Agent")
        XCTAssertNil(store.snapshot?.employeeId)
        XCTAssertNil(store.snapshot?.employeeName)
        XCTAssertNil(store.snapshot?.teamChat)
        XCTAssertNil(store.snapshot?.teamStep)
        let catalog = try JSONDecoder().decode(ModelsResponse.self, from: Data("""
        {"models":[],"codexModels":[],"piModels":[{"id":"pi-model","label":"Pi Model"}],
         "defaultModels":{"pi":"pi-model"}}
        """.utf8))
        store.modelCatalogForTesting(catalog)
        XCTAssertEqual(store.availableModels.map(\.id), ["pi-model"])
        try receive("""
        {"type":"status","data":{"provider":"pi","structuredState":{"engine":"cli"}}}
        """)
        XCTAssertEqual(store.snapshot?.providerLabel, "Pi")
        XCTAssertEqual(store.availableModels.map(\.id), ["pi-model"])
        XCTAssertEqual(store.defaultModel, "pi-model")
    }

    @MainActor
    func testIdentityRowsRenderAtDesktopSidebarWidthsInBothThemes() throws {
        guard let output = ProcessInfo.processInfo.environment["WAND_MACOS_VISUAL_DIR"] else {
            throw XCTSkip("设置 WAND_MACOS_VISUAL_DIR 保存本轮原生身份行截图")
        }
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/session-identity.json")
        let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let entries = try (fixture["cases"] as! [[String: Any]]).map { entry -> (SessionSnapshot, WorkspaceSessionSummary) in
            var payload = entry["payload"] as! [String: Any]
            payload["title"] = entry["name"]
            payload["cwd"] = "/fixture/project"
            let data = try JSONSerialization.data(withJSONObject: payload)
            return (try JSONDecoder().decode(SessionSnapshot.self, from: data),
                    try JSONDecoder().decode(WorkspaceSessionSummary.self, from: data))
        }
        let api = WandAPI(baseURL: URL(string: "http://fixture.example.test")!, token: nil)
        let store = WorkspaceStore(api: api, serverID: "visual-fixture")
        let workspace = Workspace(id: "fixture", name: "测试项目", cwd: "/fixture",
                                  defaultProvider: nil, layout: nil, createdAt: "2026-10-12", lastOpenedAt: nil)
        let task = WorkspaceTaskSummary(
            id: "task", workspaceId: "fixture", name: "测试任务", worktree: nil, layout: nil,
            status: "active", createdAt: "2026-10-12", lastOpenedAt: nil, cwd: "/fixture",
            isolated: false, worktreeError: nil, sessions: entries.map { $0.1 }
        )
        let list = WorkspaceListView(store: store, api: api, selectedTaskId: nil, query: "", onOpenTask: { _, _ in })
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for dark in [false, true] {
            for width in [280.0, 360.0] {
                let view = VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                        SessionTile(session: entry.0, isSelected: false, isSelecting: false, checked: false)
                    }
                    Divider().padding(.vertical, 8)
                    ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                        list.sessionRowForTesting(entry.1, summary: task, workspace: workspace, index: index)
                    }
                }
                .padding(12)
                .frame(width: width)
                .background(Theme.workspaceBackground)
                .preferredColorScheme(dark ? .dark : .light)
                let hosting = NSHostingView(rootView: view)
                hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                hosting.frame = NSRect(x: 0, y: 0, width: width, height: 900)
                let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
                window.contentView = hosting
                hosting.layoutSubtreeIfNeeded()
                let height = hosting.fittingSize.height
                XCTAssertGreaterThan(height, 200)
                window.setContentSize(NSSize(width: width, height: height))
                hosting.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: directory.appendingPathComponent("identities-\(dark ? "dark" : "light")-\(Int(width)).png"))
                window.contentView = nil
            }
        }
    }


    func testLogosNormalizeAliasesWithoutGivingUnknownToolsAClaudeMark() {
        let rect = CGRect(x: 0, y: 0, width: 24, height: 24)
        XCTAssertTrue(BrandLogoShape(provider: "future-cli").path(in: rect).isEmpty)
        XCTAssertEqual(BrandLogoShape(provider: "pi-cli-json").path(in: rect), BrandLogoShape(provider: "pi").path(in: rect))
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
