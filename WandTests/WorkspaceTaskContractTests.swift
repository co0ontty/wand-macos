import XCTest

/// 任务一级容器契约的对齐测试（与 iOS WorkspaceWorktreeTests 同源，防两端漂移）。
final class WorkspaceTaskContractTests: XCTestCase {
    func testTaskListPresentationShortensPathsAndAvoidsSharedDirectoryLabel() {
        XCTAssertEqual(
            TaskListPresentation.shortenWorkspacePath("/Users/me/Self/vibe_coding/wand"),
            "…/vibe_coding/wand"
        )
        XCTAssertNil(TaskListPresentation.taskIsolationCaption(isolated: false))
        XCTAssertEqual(TaskListPresentation.taskIsolationCaption(isolated: true), "隔离")
        XCTAssertEqual(
            TaskListPresentation.listSessionLabel(
                title: "wand",
                providerLabel: "Pi",
                cwd: "/Users/me/wand",
                index: 0,
                parentNames: ["wand"]
            ),
            "Pi 1"
        )
    }

    func testTaskTreeHidesNeedlessCaretsAndKeepsTerminalsOpen() {
        XCTAssertFalse(TaskListPresentation.showsDirectoryDisclosure(directoryCount: 1))
        XCTAssertTrue(TaskListPresentation.showsDirectoryDisclosure(directoryCount: 2))
        XCTAssertTrue(TaskListPresentation.isDirectoryExpanded(userCollapsed: true, directoryCount: 1))
        XCTAssertFalse(TaskListPresentation.isDirectoryExpanded(userCollapsed: true, directoryCount: 2))
        XCTAssertFalse(TaskListPresentation.showsTaskSessionDisclosure(sessionCount: 0))
        XCTAssertTrue(TaskListPresentation.isTaskSessionsExpanded(userCollapsed: true, sessionCount: 0))
        XCTAssertFalse(TaskListPresentation.isTaskSessionsExpanded(userCollapsed: true, sessionCount: 2))
        XCTAssertTrue(TaskListPresentation.isTaskSessionsExpanded(userCollapsed: false, sessionCount: 2))
    }

    func testCreateTaskWorktreeFlagOmitsByDefaultAndSendsFalseExplicitly() {
        // 缺省不传 worktree，交由服务端默认（git 仓库自动隔离）。
        let defaultTask = createWorkspaceTaskRequest(
            workspaceId: "ws-1",
            name: "默认任务",
            baseRef: nil,
            worktree: nil
        )
        XCTAssertNil(defaultTask.body["worktree"])

        let enabledTask = createWorkspaceTaskRequest(
            workspaceId: "ws-1",
            name: "隔离任务",
            baseRef: nil,
            worktree: true
        )
        XCTAssertNil(enabledTask.body["worktree"])

        // 显式 false 必须传 worktree:false，跳过隔离。
        let sharedTask = createWorkspaceTaskRequest(
            workspaceId: "ws-1",
            name: "共享目录任务",
            baseRef: nil,
            worktree: false
        )
        XCTAssertEqual(sharedTask.body["worktree"], .bool(false))
    }

    func testTaskDirectoryGroupsDecodeAggregateShape() throws {
        // GET /api/tasks 的目录组形状：任务带运行期字段，未分组会话归 standaloneSessions。
        let json = """
        [{
          "workspaceId": "ws-1",
          "workspaceName": "Wand",
          "workspaceCwd": "/repo",
          "tasks": [{
            "id": "task-1",
            "workspaceId": "ws-1",
            "name": "修复登录",
            "worktree": {"branch": "wand/login", "path": "/wt/login"},
            "layout": null,
            "status": "active",
            "createdAt": "2026-08-23T00:00:00.000Z",
            "lastOpenedAt": null,
            "cwd": "/wt/login",
            "isolated": true,
            "totalSessions": 4,
            "sessions": [{"id": "s1", "provider": "claude", "title": "登录会话"}]
          }],
          "standaloneSessions": [{"id": "s2", "sessionKind": "pty"}],
          "synthetic": false
        },
        {
          "workspaceId": "cwd:/loose",
          "workspaceName": "loose",
          "workspaceCwd": "/loose",
          "synthetic": true,
          "tasks": [],
          "standaloneSessions": []
        }]
        """
        let groups = try JSONDecoder().decode([TaskDirectoryGroup].self, from: Data(json.utf8))
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].workspaceName, "Wand")
        XCTAssertFalse(groups[0].isSynthetic)
        XCTAssertEqual(groups[0].tasks.count, 1)
        XCTAssertTrue(groups[0].tasks[0].isIsolated)
        XCTAssertEqual(groups[0].tasks[0].cwd, "/wt/login")
        XCTAssertEqual(groups[0].tasks[0].sessions.first?.title, "登录会话")
        XCTAssertEqual(groups[0].tasks[0].totalSessions, 4)
        XCTAssertEqual(groups[0].tasks[0].listedSessionCount, 4)
        XCTAssertEqual(groups[0].standaloneSessions.count, 1)
        XCTAssertTrue(groups[1].isSynthetic)
        XCTAssertTrue(groups[1].tasks.isEmpty)
    }

    func testTaskSummaryFallsBackToEmbeddedSessionCountWhenTotalSessionsOmitted() throws {
        let json = """
        {
          "id": "task-1",
          "workspaceId": "ws-1",
          "name": "修复登录",
          "status": "active",
          "createdAt": "2026-08-23T00:00:00.000Z",
          "cwd": "/repo",
          "sessions": [{"id": "s1"}, {"id": "s2"}]
        }
        """
        let summary = try JSONDecoder().decode(WorkspaceTaskSummary.self, from: Data(json.utf8))
        XCTAssertNil(summary.totalSessions)
        XCTAssertEqual(summary.listedSessionCount, 2)
    }
}
