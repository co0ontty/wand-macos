import AppKit
import SwiftUI
import XCTest
@testable import Wand

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
                index: 0
            ),
            "Pi 1"
        )
        // 任务名重复的标题照显示：最新会话的标题常常正好等于任务首行。
        XCTAssertEqual(
            TaskListPresentation.listSessionLabel(
                title: "重构会话恢复流程",
                providerLabel: "Pi",
                cwd: "/Users/me/wand",
                index: 0
            ),
            "重构会话恢复流程"
        )
    }

    func testTaskTreeLetsEveryWorkspaceCollapseAndKeepsTerminalsOpen() {
        XCTAssertFalse(TaskListPresentation.showsDirectoryDisclosure(directoryCount: 0))
        XCTAssertTrue(TaskListPresentation.showsDirectoryDisclosure(directoryCount: 1))
        XCTAssertTrue(TaskListPresentation.showsDirectoryDisclosure(directoryCount: 2))
        XCTAssertFalse(TaskListPresentation.isDirectoryExpanded(userCollapsed: true, directoryCount: 1))
        XCTAssertTrue(TaskListPresentation.isDirectoryExpanded(userCollapsed: false, directoryCount: 1))
        XCTAssertFalse(TaskListPresentation.isDirectoryExpanded(userCollapsed: true, directoryCount: 2))
        XCTAssertFalse(TaskListPresentation.showsTaskSessionDisclosure(sessionCount: 0))
        XCTAssertFalse(TaskListPresentation.isTaskSessionsExpanded(userCollapsed: false, sessionCount: 0))
        XCTAssertTrue(TaskListPresentation.isTaskSessionsExpanded(
            userCollapsed: false, sessionCount: 0, isOnlyTask: true
        ))
        XCTAssertTrue(TaskListPresentation.isTaskSessionsExpanded(
            userCollapsed: true, sessionCount: 0, isSearching: true
        ))
        XCTAssertFalse(TaskListPresentation.isTaskSessionsExpanded(userCollapsed: true, sessionCount: 2))
        XCTAssertTrue(TaskListPresentation.isTaskSessionsExpanded(userCollapsed: false, sessionCount: 2))
    }

    func testTaskSearchMatchesProjectNamesAndDirectoriesWithoutDroppingChildren() throws {
        let groups = try searchGroups()
        for query in ["  wAND ui \n", "/REPO/UI"] {
            XCTAssertEqual(TaskListPresentation.filteredDirectoryGroups(groups, query: query), [groups[0]])
        }
        XCTAssertEqual(
            TaskListPresentation.filteredDirectoryGroups(groups, query: " \n\t "),
            Array(groups.prefix(2)),
            "An empty search keeps all populated groups in their original order"
        )
        XCTAssertTrue(TaskListPresentation.filteredDirectoryGroups(groups, query: "missing-project").isEmpty)
    }

    func testTaskSearchMatchesTaskNameAndActualWorktreeDirectory() throws {
        let groups = try searchGroups()
        for query in ["界面", "CHECKOUT"] {
            let result = TaskListPresentation.filteredDirectoryGroups(groups, query: query)
            XCTAssertEqual(result.map(\.id), ["ui"])
            XCTAssertEqual(result.first?.tasks, [groups[0].tasks[0]])
            XCTAssertEqual(result.first?.standaloneSessions, [])
        }
    }

    func testTaskSearchFindsOwnedAndLooseSessionsAndPreservesTaskMetadata() throws {
        let groups = try searchGroups()
        let result = TaskListPresentation.filteredDirectoryGroups(groups, query: "  PAYMENTS \n")
        let task = try XCTUnwrap(result.first?.tasks.first)
        XCTAssertEqual(result.map(\.id), ["ui"])
        XCTAssertEqual(task.id, "checkout")
        XCTAssertEqual(task.sessions.map(\.id), ["layout", "payment-review"], "Search keeps the complete task and action scope")
        XCTAssertEqual(task.listedSessionCount, 6, "Filtering never rewrites the task's total session count")
        XCTAssertEqual(task.cwd, groups[0].tasks[0].cwd)
        XCTAssertEqual(task.isolated, true)
        XCTAssertEqual(task.worktreeError, groups[0].tasks[0].worktreeError)
        XCTAssertEqual(task.asTask(), groups[0].tasks[0].asTask())
        XCTAssertEqual(result.first?.standaloneSessions, [])

        for query in ["Documentation", "qoder", "/scratch/docs"] {
            let loose = TaskListPresentation.filteredDirectoryGroups(groups, query: query)
            XCTAssertEqual(loose.map(\.id), ["ui"])
            XCTAssertEqual(loose.first?.tasks, [])
            XCTAssertEqual(loose.first?.standaloneSessions.map(\.id), ["docs"])
        }
        XCTAssertEqual(groups[0].tasks[0].sessions.count, 2, "Filtering leaves the source tree intact")
    }

    func testTaskSearchTemporarilyExpandsCollapsedResults() {
        for searching in [false, true, false] {
            for directoryCount in [1, 2] {
                XCTAssertEqual(TaskListPresentation.isDirectoryExpanded(
                    userCollapsed: true, directoryCount: directoryCount, isSearching: searching
                ), searching)
            }
            XCTAssertEqual(TaskListPresentation.isTaskSessionsExpanded(
                userCollapsed: true, sessionCount: 2, isSearching: searching
            ), searching)
        }
        XCTAssertTrue(TaskListPresentation.isDirectoryExpanded(
            userCollapsed: false, directoryCount: 2, isSearching: false
        ))
        XCTAssertTrue(TaskListPresentation.isTaskSessionsExpanded(
            userCollapsed: false, sessionCount: 2, isSearching: false
        ))
    }

    func testPopulatedDirectoriesAreVisibleInitiallyAndPollingPreservesManualFolds() throws {
        let groups = try searchGroups()
        var known = Set<String>(), expanded = Set<String>()
        TaskListPresentation.discoverDirectories(groups, known: &known, expanded: &expanded)
        XCTAssertEqual(expanded, ["ui", "infra"], "只有未分组会话的目录也属于非空目录")
        expanded.removeAll()
        TaskListPresentation.discoverDirectories(groups, known: &known, expanded: &expanded)
        XCTAssertTrue(expanded.isEmpty, "A refresh must not reopen the user's collapsed workspace")
        let fresh = TaskDirectoryGroup(workspaceId: "new", workspaceName: "New", workspaceCwd: "/new", synthetic: true,
            tasks: groups[0].tasks, standaloneSessions: [])
        TaskListPresentation.discoverDirectories(groups + [fresh], known: &known, expanded: &expanded)
        XCTAssertEqual(expanded, ["new"])
    }

    func testSyntheticDirectoryUsesRealTaskOwnerInsteadOfDisplayID() throws {
        let group = try searchGroups()[0], task = group.tasks[0]
        let synthetic = TaskDirectoryGroup(workspaceId: "cwd:/repo/ui", workspaceName: group.workspaceName,
            workspaceCwd: group.workspaceCwd, synthetic: true, tasks: [task], standaloneSessions: [])
        let owner = TaskListPresentation.workspaceForTask(task, group: synthetic, workspaces: [])
        XCTAssertEqual(owner.id, task.workspaceId)
        XCTAssertNotEqual(owner.id, synthetic.id)
        XCTAssertEqual(owner.cwd, group.workspaceCwd)
    }

    func testSidebarSearchSupportsWordsAcrossTaskAndEmployeeMetadata() throws {
        let groups = try searchGroups()
        let result = TaskListPresentation.filteredDirectoryGroups(groups, query: "wand payments codex")
        XCTAssertEqual(result.first?.tasks, [groups[0].tasks[0]])
        XCTAssertEqual(result.first?.tasks.first?.sessions.count, 2)
        XCTAssertTrue(TaskListPresentation.searchMatches("虎妞 修复", values: ["赛博虎妞", "界面修复"]))
    }

    func testRecentSidebarKeepsTaskAndStandaloneSessionsWithoutTruncationOrDuplicates() throws {
        let groups = try searchGroups()
        let recent = TaskListPresentation.recentGroups(groups, query: "", activeOnly: false, selectedSessionId: nil)
        XCTAssertEqual(Set(recent.flatMap(\.entries).map(\.id)), ["layout", "payment-review", "docs", "deploy"])
        let matched = TaskListPresentation.recentGroups(groups, query: "wand payments", activeOnly: false, selectedSessionId: nil)
        XCTAssertEqual(matched.flatMap(\.entries).map(\.id), ["payment-review"])
        let active = TaskListPresentation.recentGroups(groups, query: "", activeOnly: true, selectedSessionId: "payment-review")
        XCTAssertTrue(active.flatMap(\.entries).isEmpty, "Selection is not activity")
        let duplicate = TaskListPresentation.recentGroups(groups + groups, query: "", activeOnly: false, selectedSessionId: nil)
        XCTAssertEqual(duplicate.flatMap(\.entries).count, 4)
    }

    func testActiveSidebarDoesNotTreatAnIdleRunningProviderAsActive() throws {
        let sessions = try JSONDecoder().decode([WorkspaceSessionSummary].self, from: Data(#"""
        [
          {"id":"idle","sessionKind":"structured","provider":"pi","status":"running","inFlight":false},
          {"id":"working","sessionKind":"structured","provider":"pi","status":"running","inFlight":true},
          {"id":"attention","status":"permission-blocked"},
          {"id":"completed","status":"idle","completionRevision":2,"viewedCompletionRevision":1},
          {"id":"terminal","sessionKind":"pty","provider":"","status":"running","providerCliActive":true},
          {"id":"archived","archived":true,"inFlight":true}
        ]
        """#.utf8))
        XCTAssertFalse(TaskListPresentation.isActive(sessions[0], selectedSessionId: nil))
        for session in sessions[1...4] { XCTAssertTrue(TaskListPresentation.isActive(session, selectedSessionId: nil)) }
        XCTAssertFalse(TaskListPresentation.isActive(sessions[5], selectedSessionId: nil))
    }

    func testViewedCompletionLeavesActivityEvenWhileSelected() throws {
        func completed(_ viewed: Int, inFlight: Bool = false) throws -> WorkspaceSessionSummary {
            try JSONDecoder().decode(WorkspaceSessionSummary.self, from: Data("""
            {"id":"finished","status":"idle","completionRevision":2,"viewedCompletionRevision":\(viewed),"inFlight":\(inFlight)}
            """.utf8))
        }
        let unread = try completed(1), seen = try completed(2)
        XCTAssertTrue(TaskListPresentation.isActive(unread, selectedSessionId: unread.id))
        XCTAssertFalse(TaskListPresentation.isActive(seen, selectedSessionId: seen.id))
        XCTAssertTrue(TaskListPresentation.isActive(try completed(2, inFlight: true), selectedSessionId: seen.id))
        let group = TaskDirectoryGroup(workspaceId: "w", workspaceName: "W", workspaceCwd: "/tmp",
            synthetic: false, tasks: [], standaloneSessions: [seen])
        XCTAssertTrue(TaskListPresentation.recentGroups([group], query: "", activeOnly: true,
            selectedSessionId: seen.id).isEmpty)
        XCTAssertEqual(TaskListPresentation.recentGroups([group], query: "", activeOnly: false,
            selectedSessionId: seen.id).flatMap(\.entries).map(\.id), [seen.id])
    }

    func testGlobalGroupMetadataAndActiveDirectoryProjection() throws {
        let source = try searchGroups()
        let global = TaskDirectoryGroup(workspaceId: "global", workspaceName: "全局", workspaceCwd: "/tmp",
            synthetic: false, tasks: source[0].tasks, standaloneSessions: [], global: true)
        XCTAssertEqual(global.displayName, "未归属工作区")
        let groups = TaskListPresentation.sidebarDirectoryGroups([global] + source, workspaces: [], query: "",
            activeOnly: false, selectedSessionId: nil, selectedTaskId: nil)
        XCTAssertEqual(groups.last?.id, "global")
        XCTAssertEqual(groups.flatMap(\.tasks).count, 4)
        let active = TaskListPresentation.sidebarDirectoryGroups(source, workspaces: [], query: "",
            activeOnly: true, selectedSessionId: "layout", selectedTaskId: nil)
        XCTAssertTrue(active.flatMap(\.tasks).isEmpty)
        XCTAssertEqual(active.map(\.id), source.map(\.id), "Activity filtering retains directory roots")
    }

    func testSidebarKeepsUnboundDirectoryMembersAndDefaultGroupSearch() throws {
        let groups = try JSONDecoder().decode([TaskDirectoryGroup].self, from: Data(#"[{"workspaceId":"cwd:/repo/free","workspaceName":"Free","workspaceCwd":"/repo/free","synthetic":true,"tasks":[],"standaloneSessions":[{"id":"free","title":"独立工作","status":"idle"},{"id":"old","archived":true}]},{"workspaceId":"global","workspaceName":"全局","workspaceCwd":"/scratch","global":true,"tasks":[],"standaloneSessions":[{"id":"other","title":"全局工作","status":"idle"}]}]"#.utf8))
        let projected = TaskListPresentation.sidebarDirectoryGroups(groups, workspaces: [], query: "", activeOnly: false, selectedSessionId: nil, selectedTaskId: nil)
        XCTAssertEqual(Set(projected.map(\.id)), Set(groups.map(\.id)))
        XCTAssertEqual(Set(projected.flatMap(\.standaloneSessions).map(\.id)), ["free", "other"])
        let searched = TaskListPresentation.sidebarDirectoryGroups(groups, workspaces: [], query: "Free - 未分组任务", activeOnly: false, selectedSessionId: nil, selectedTaskId: nil)
        XCTAssertEqual(searched.flatMap(\.standaloneSessions).map(\.id), ["free"])
        var known = Set<String>(), expanded = Set<String>()
        TaskListPresentation.discoverDirectories(groups, known: &known, expanded: &expanded)
        XCTAssertTrue(expanded.contains("cwd:/repo/free"), "只有未分组会话的目录同样可发现和展开")
    }

    @MainActor
    func testNativeDefaultGroupExpandsAndOpensTheActualUnboundSession() async throws {
        let groups = try JSONDecoder().decode([TaskDirectoryGroup].self, from: Data(#"[{"workspaceId":"cwd:/repo/free","workspaceName":"Free","workspaceCwd":"/repo/free","synthetic":true,"tasks":[],"standaloneSessions":[{"id":"free","title":"独立工作","provider":"pi","sessionKind":"structured","cwd":"/repo/free","status":"idle"}]}]"#.utf8))
        let data = try JSONEncoder().encode(groups)
        let api = makeAPI { request in
            XCTAssertEqual(request.httpMethod, "GET")
            return request.url?.path == "/api/tasks" ? data : Data("[]".utf8)
        }
        let store = trackedStore(api: api, serverID: "sidebar-unbound-click")
        await store.loadTaskGroups()
        var opened: String?
        let host = NSHostingView(rootView: WorkspaceListView(store: store, api: api, selectedTaskId: nil, query: "",
            onOpenTask: { _, _ in XCTFail("默认组不是正式任务") }, onOpenSession: { _, session in opened = session.id }).frame(width: 260))
        host.frame = NSRect(x: 0, y: 0, width: 260, height: 680)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        host.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 220_000_000); host.layoutSubtreeIfNeeded()
        try clickSidebarMarker(host, window: window, id: "sidebar-default-task-cwd:/repo/free")
        try await Task.sleep(nanoseconds: 250_000_000); host.layoutSubtreeIfNeeded()
        XCTAssertNotNil(sidebarPresenceView(host, id: "sidebar-standalone-free"))
        try captureSidebar(host, name: "fixture-default-group-expanded")
        try clickSidebarMarker(host, window: window, id: "sidebar-standalone-free")
        XCTAssertEqual(opened, "free")
    }

    @MainActor
    func testNativeTaskClickUsesRealOwnerAndRefreshPreservesDirectoryFold() async throws {
        let source = try searchGroups()[0], task = source.tasks[0]
        let group = TaskDirectoryGroup(workspaceId: "cwd:/repo/ui", workspaceName: "UI", workspaceCwd: "/repo/ui",
            synthetic: true, tasks: [task], standaloneSessions: [])
        let data = try JSONEncoder().encode([group])
        let api = makeAPI { request in
            XCTAssertEqual(request.httpMethod, "GET")
            return request.url?.path == "/api/tasks" ? data : Data("[]".utf8)
        }
        let store = trackedStore(api: api, serverID: "sidebar-click")
        await store.loadTaskGroups()
        var opened: (String, String)?
        let host = NSHostingView(rootView: WorkspaceListView(store: store, api: api, selectedTaskId: nil, query: "",
            onOpenTask: { owner, task in opened = (owner.id, task.id) }).frame(width: 260))
        host.frame = NSRect(x: 0, y: 0, width: 260, height: 680)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        func settle() async throws {
            host.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 220_000_000); host.layoutSubtreeIfNeeded()
        }
        func click(_ id: String) throws {
            let marker = try XCTUnwrap(sidebarPresenceView(host, id: id))
            let rect = marker.convert(marker.bounds, to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: NSPoint(x: rect.midX, y: rect.midY),
                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
                window.sendEvent(event)
            }
        }
        try await settle()
        try click("sidebar-task-\(task.id)"); try await settle()
        XCTAssertEqual(opened?.0, task.workspaceId)
        XCTAssertEqual(opened?.1, task.id)
        try click("sidebar-group-\(group.id)"); try await settle()
        XCTAssertNil(sidebarPresenceView(host, id: "sidebar-task-\(task.id)"))
        await store.loadTaskGroups(force: true); try await settle()
        XCTAssertNil(sidebarPresenceView(host, id: "sidebar-task-\(task.id)"), "Refresh respects the native fold click")
        try click("sidebar-group-\(group.id)"); try await settle()
        XCTAssertNotNil(sidebarPresenceView(host, id: "sidebar-task-\(task.id)"))
    }

    @MainActor
    func testNativeSidebarRendersLoadedTasksAndRecentRowsAtDesktopWidth() async throws {
        let groups = try searchGroups()
        let data = try JSONEncoder().encode(groups)
        let api = makeAPI { request in
            XCTAssertEqual(request.httpMethod, "GET", "Rendering never writes business data")
            return request.url?.path == "/api/tasks" ? data : Data("[]".utf8)
        }
        let store = trackedStore(api: api, serverID: "sidebar-visual")
        await store.loadTaskGroups()
        for recent in [false, true] {
            for dark in [false, true] {
                let view = ScrollView {
                    WorkspaceListView(store: store, api: api, selectedTaskId: nil, query: "", recentOnly: recent,
                                      onOpenTask: { _, _ in }, onOpenSession: { _, _ in }, onOpenTaskSession: { _, _, _ in })
                }.frame(width: 260, height: 780).background(Theme.sidebarBackground)
                    .preferredColorScheme(dark ? .dark : .light)
                let host = NSHostingView(rootView: view)
                host.frame = NSRect(x: 0, y: 0, width: 260, height: 780)
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
                window.contentView = host
                host.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 200_000_000); host.layoutSubtreeIfNeeded()
                try captureSidebar(host, name: "fixture-\(recent ? "recent" : "directory")-\(dark ? "dark" : "light")")
                window.contentView = nil
            }
        }
    }

    private func searchGroups() throws -> [TaskDirectoryGroup] {
        try JSONDecoder().decode([TaskDirectoryGroup].self, from: Data(#"""
        [
          {
            "workspaceId": "ui", "workspaceName": "Wand UI", "workspaceCwd": "/repo/ui",
            "tasks": [
              {
                "id": "checkout", "workspaceId": "ui", "name": "界面清理", "status": "active",
                "createdAt": "2026-09-21", "cwd": "/repo/ui/.wand-worktrees/checkout",
                "isolated": true, "worktreeError": "fixture warning", "totalSessions": 6,
                "sessions": [
                  { "id": "layout", "provider": "claude", "title": "Layout review", "cwd": "/repo/ui" },
                  { "id": "payment-review", "provider": "codex", "title": "Payments review", "cwd": "/repo/ui" }
                ]
              },
              {
                "id": "backend", "workspaceId": "ui", "name": "Backend", "status": "active",
                "createdAt": "2026-09-21", "cwd": "/repo/ui", "sessions": []
              }
            ],
            "standaloneSessions": [
              { "id": "docs", "provider": "qoder", "title": "Documentation", "cwd": "/scratch/docs" }
            ]
          },
          {
            "workspaceId": "infra", "workspaceName": "Infrastructure", "workspaceCwd": "/repo/infra",
            "tasks": [],
            "standaloneSessions": [{ "id": "deploy", "provider": "codex", "title": "Deploy" }]
          },
          {
            "workspaceId": "empty", "workspaceName": "Empty", "workspaceCwd": "/repo/empty",
            "tasks": [], "standaloneSessions": []
          }
        ]
        """#.utf8))
    }

    func testStandaloneSessionsKeepWorkspaceMembershipAndExcludeTaskChildren() throws {
        let groups = try searchGroups()
        let sessions = try [
            sidebarSession("workspace-only", workspaceId: "ui"),
            sidebarSession("layout"),
            sidebarSession("payment-review", workspaceId: "ui", taskId: "checkout"),
            sidebarSession("no-directory"),
            sidebarSession("empty-task", workspaceId: "ui", taskId: " \n "),
        ]
        XCTAssertEqual(TaskListPresentation.standaloneSessions(
            sessions: sessions, groups: groups, groupsAvailable: true
        ).map(\.id), ["workspace-only", "no-directory", "empty-task"])
    }

    func testStandaloneSessionsRespectExplicitLooseMembershipAndKeepOrphanedBindings() throws {
        let groups = try searchGroups()
        let sessions = try [
            sidebarSession("docs", workspaceId: "ui", taskId: "checkout"),
            sidebarSession("orphan", workspaceId: "missing-workspace", taskId: "deleted-task"),
        ]
        XCTAssertEqual(TaskListPresentation.standaloneSessions(
            sessions: sessions, groups: groups, groupsAvailable: true
        ).map(\.id), ["docs", "orphan"])
    }

    func testStandaloneSessionsExcludeTruncatedTaskChildrenUsingTaskIdentity() throws {
        let groups = try searchGroups()
        XCTAssertGreaterThan(groups[0].tasks[0].listedSessionCount, groups[0].tasks[0].sessions.count)
        let sessions = try [
            sidebarSession("unlisted-child", workspaceId: "global", taskId: "checkout"),
            sidebarSession("independent", workspaceId: "ui"),
        ]
        XCTAssertEqual(TaskListPresentation.standaloneSessions(
            sessions: sessions, groups: groups, groupsAvailable: true
        ).map(\.id), ["independent"])
    }

    func testStandaloneSessionsFallBackToAllSessionsWhenGroupsAreUnavailable() throws {
        let sessions = try [sidebarSession("layout", taskId: "checkout"), sidebarSession("docs")]
        XCTAssertEqual(TaskListPresentation.standaloneSessions(
            sessions: sessions, groups: try searchGroups(), groupsAvailable: false
        ).map(\.id), sessions.map(\.id))
        XCTAssertEqual(TaskListPresentation.standaloneSessions(
            sessions: sessions, groups: [], groupsAvailable: true
        ).map(\.id), sessions.map(\.id))
    }

    func testStandaloneSessionsFollowNewTaskGroupsWithoutRefreshingCachedSessionMembership() throws {
        let groups = try searchGroups()
        let cached = try sidebarSession("docs", workspaceId: "ui", taskId: "checkout")
        XCTAssertEqual(TaskListPresentation.standaloneSessions(
            sessions: [cached], groups: groups, groupsAvailable: true
        ).map(\.id), ["docs"])

        let original = groups[0].tasks[0]
        let movedTask = WorkspaceTaskSummary(
            id: original.id, workspaceId: original.workspaceId, name: original.name,
            worktree: original.worktree, layout: original.layout, status: original.status,
            createdAt: original.createdAt, lastOpenedAt: original.lastOpenedAt, cwd: original.cwd,
            isolated: original.isolated, worktreeError: original.worktreeError,
            sessions: [WorkspaceSessionSummary(snapshot: cached)], totalSessions: 1
        )
        let movedGroup = TaskDirectoryGroup(
            workspaceId: "cwd:/repo/ui", workspaceName: "UI", workspaceCwd: "/repo/ui",
            synthetic: true, tasks: [movedTask], standaloneSessions: []
        )
        XCTAssertTrue(TaskListPresentation.standaloneSessions(
            sessions: [cached], groups: [movedGroup], groupsAvailable: true
        ).isEmpty)
        XCTAssertEqual(TaskListPresentation.standaloneSessions(
            sessions: [cached], groups: groups, groupsAvailable: true
        ).map(\.id), ["docs"])

        let conflictingGroup = TaskDirectoryGroup(
            workspaceId: movedGroup.workspaceId, workspaceName: movedGroup.workspaceName,
            workspaceCwd: movedGroup.workspaceCwd, synthetic: true,
            tasks: [movedTask], standaloneSessions: [WorkspaceSessionSummary(snapshot: cached)]
        )
        XCTAssertTrue(TaskListPresentation.standaloneSessions(
            sessions: [cached], groups: [conflictingGroup], groupsAvailable: true
        ).isEmpty, "An actually displayed task child must never appear twice")
    }

    private func sidebarSession(_ id: String, workspaceId: String? = nil, taskId: String? = nil) throws -> SessionSnapshot {
        var values: [String: Any] = ["id": id]
        if let workspaceId { values["workspaceId"] = workspaceId }
        if let taskId { values["workspaceTaskId"] = taskId }
        return try JSONDecoder().decode(SessionSnapshot.self, from: JSONSerialization.data(withJSONObject: values))
    }

    func testCreateTaskWorktreeFlagPreservesExplicitChoice() {
        // 缺省不传 worktree；当前服务端只在显式 true 时创建隔离目录。
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
        XCTAssertEqual(enabledTask.body["worktree"], .bool(true))

        // 显式 false 必须传 worktree:false，跳过隔离。
        let sharedTask = createWorkspaceTaskRequest(
            workspaceId: "ws-1",
            name: "共享目录任务",
            baseRef: nil,
            worktree: false
        )
        XCTAssertEqual(sharedTask.body["worktree"], .bool(false))
    }

    func testBothSessionKindsUseTaskDirectoryAndKeepExplicitModelOptions() async throws {
        let binding = WorkspaceBinding(
            workspaceId: "workspace-1",
            workspaceTaskId: "task-1",
            cwd: "/repo/.wand-worktrees/task-1"
        )
        let api = makeAPI { request in
            let body = try Self.requestBody(request)
            XCTAssertEqual(body["cwd"] as? String, binding.cwd)
            XCTAssertEqual(body["workspaceId"] as? String, binding.workspaceId)
            XCTAssertEqual(body["workspaceTaskId"] as? String, binding.workspaceTaskId)
            XCTAssertEqual(body["provider"] as? String, "qoder")
            XCTAssertEqual(body["model"] as? String, "chosen-model")
            XCTAssertEqual(body["mode"] as? String, "managed")
            XCTAssertEqual(body["thinkingEffort"] as? String, "high")
            if request.url?.path == "/api/structured-sessions" {
                XCTAssertEqual(body["runner"] as? String, "qoder-cli-print")
                XCTAssertEqual(body["prompt"] as? String, "Inspect the selected task")
                XCTAssertNil(body["command"])
            } else {
                XCTAssertEqual(request.url?.path, "/api/commands")
                XCTAssertEqual(body["command"] as? String, "qodercli")
                XCTAssertEqual(body["initialInput"] as? String, "Inspect the selected task")
                XCTAssertNil(body["runner"])
            }
            return Data(#"{"id":"new-session"}"#.utf8)
        }
        _ = try await api.createStructuredSession(
            provider: "qoder", cwd: "/wrong/project/root", mode: "managed",
            model: "chosen-model", thinkingEffort: "high", prompt: "Inspect the selected task",
            workspaceBinding: binding
        )
        _ = try await api.createPtySession(
            provider: "qoder", cwd: "/wrong/project/root", mode: "managed",
            model: "chosen-model", thinkingEffort: "high", initialInput: "Inspect the selected task",
            workspaceBinding: binding
        )
    }

    func testUnassignedSessionDoesNotSendTaskBindingOrOverrideServerModelDefaults() async throws {
        let message = "只检查当前目录\n保留第二行消息"
        let api = makeAPI { request in
            let body = try Self.requestBody(request)
            XCTAssertEqual(body["cwd"] as? String, "/repo")
            XCTAssertNil(body["workspaceId"])
            XCTAssertNil(body["workspaceTaskId"])
            XCTAssertNil(body["model"])
            XCTAssertNil(body["mode"])
            XCTAssertNil(body["thinkingEffort"])
            if request.url?.path == "/api/structured-sessions" {
                XCTAssertEqual(body["prompt"] as? String, message)
                XCTAssertNil(body["initialInput"])
            } else {
                XCTAssertEqual(request.url?.path, "/api/commands")
                XCTAssertEqual(body["initialInput"] as? String, message)
                XCTAssertNil(body["prompt"])
            }
            return Data(#"{"id":"new-session"}"#.utf8)
        }
        _ = try await api.createStructuredSession(
            provider: "codex", cwd: "/repo", mode: nil, model: "", prompt: message
        )
        _ = try await api.createPtySession(
            provider: "codex", cwd: "/repo", mode: nil, model: "", initialInput: message
        )
    }

    @MainActor
    func testOpeningTaskKeepsSessionKindAndWorkspaceProviderWinsOverServerDefault() async throws {
        let api = makeAPI { request in
            if request.url?.path == "/api/config" {
                return Data(#"{"defaultProvider":"codex","defaultSessionKind":"pty","defaultTaskWorktree":false}"#.utf8)
            }
            if request.url?.path == "/api/workspace-tasks/task-1/layout" {
                return Data(#"{"layout":null}"#.utf8)
            }
            XCTAssertEqual(request.url?.path, "/api/workspace-tasks/task-1")
            return Data(#"{"id":"task-1","workspaceId":"workspace-1","name":"Task","status":"active","createdAt":"","cwd":"/repo","sessions":[]}"#.utf8)
        }
        let store = WorkspaceStore(api: api, serverID: "test-defaults")
        await store.loadCreationDefaults()
        XCTAssertEqual(store.selectedKind, .pty)
        XCTAssertEqual(store.selectedTarget, .codex)
        XCTAssertFalse(store.defaultTaskWorktree)

        let task = WorkspaceTask(
            id: "task-1", workspaceId: "workspace-1", name: "Task", worktree: nil,
            layout: nil, status: "active", createdAt: "", lastOpenedAt: nil
        )
        let workspace = Workspace(
            id: "workspace-1", name: "Project", cwd: "/repo", defaultProvider: .qoder,
            layout: nil, createdAt: "", lastOpenedAt: nil
        )
        await store.openTask(workspace: workspace, task: task)
        XCTAssertEqual(store.selectedKind, .pty)
        XCTAssertEqual(store.selectedTarget, .qoder)
        await store.loadCreationDefaults()
        XCTAssertEqual(store.selectedKind, .pty)
        XCTAssertEqual(store.selectedTarget, .qoder)
    }

    @MainActor
    func testTaskCreationAppliesRememberedWorktreeDefaultAndKeepsScratchDirectoryUnisolated() async throws {
        let api = makeAPI { request in
            if request.httpMethod == "GET" { return Data("[]".utf8) }
            XCTAssertEqual(request.url?.path, "/api/tasks")
            let body = try Self.requestBody(request)
            let name = body["name"] as? String
            XCTAssertEqual(body["worktree"] as? Bool, name == "Isolated")
            if name == "Scratch" { XCTAssertNil(body["cwd"]) }
            return Data(#"{"id":"task-1","workspaceId":"global","name":"Task","status":"active","cwd":"/tmp/task"}"#.utf8)
        }
        let store = trackedStore(api: api, serverID: "test-worktree")
        _ = try await store.createTask(name: "Isolated", directory: "/repo", worktree: nil)
        _ = try await store.createTask(name: "Shared", directory: "/repo", worktree: false)
        _ = try await store.createTask(name: "Scratch", directory: "", worktree: nil)
    }

    @MainActor
    func testCachedCreationDraftRefreshesNewTasksWithoutReapplyingDefaults() async throws {
        let groups = try JSONEncoder().encode(searchGroups())
        let workspace = Workspace(id: "ui", name: "Updated project", cwd: "/repo/ui",
            defaultProvider: .codex, layout: nil, createdAt: "", lastOpenedAt: nil)
        let workspaces = try JSONEncoder().encode([workspace])
        let api = makeAPI { request in
            XCTAssertEqual(request.httpMethod, "GET")
            switch request.url?.path {
            case "/api/tasks": return groups
            case "/api/workspaces": return workspaces
            default:
                XCTFail("Refreshing destinations must not reload or save defaults")
                throw URLError(.unsupportedURL)
            }
        }
        let draft = SessionCreationDraft(context: .init(cwd: "/chosen/directory"),
                                         initialMessage: "  保留首页草稿\n以及第二行  ")
        draft.initialized = true
        draft.loading = false
        draft.provider = .pi
        draft.providerWasEdited = true
        draft.selectedModel = "chosen-model"
        draft.mode = .fullAccess
        draft.fullAccessAcknowledged = true
        draft.thinkingEffort = "high"
        draft.sessionType = .pty
        draft.taskName = "用户填写的名称"
        draft.worktree = false
        draft.tasks = [SessionTaskOption(id: "old-task", workspaceId: "ui", name: "Old",
                                        workspaceName: "Old project", cwd: "/old")]

        await draft.refreshOptions(api: api)

        XCTAssertEqual(draft.tasks.map(\.id), ["checkout", "backend"])
        XCTAssertEqual(draft.tasks.first?.cwd, "/repo/ui/.wand-worktrees/checkout")
        XCTAssertEqual(draft.workspaces, [workspace])
        XCTAssertEqual(draft.firstMessage, "  保留首页草稿\n以及第二行  ")
        XCTAssertEqual(draft.cwd, "/chosen/directory")
        XCTAssertEqual(draft.unboundCwd, "/chosen/directory")
        XCTAssertEqual(draft.destination, "none")
        XCTAssertEqual(draft.provider, .pi)
        XCTAssertTrue(draft.providerWasEdited)
        XCTAssertEqual(draft.selectedModel, "chosen-model")
        XCTAssertEqual(draft.mode, .fullAccess)
        XCTAssertTrue(draft.fullAccessAcknowledged)
        XCTAssertEqual(draft.thinkingEffort, "high")
        XCTAssertEqual(draft.sessionType, .pty)
        XCTAssertEqual(draft.taskName, "用户填写的名称")
        XCTAssertFalse(draft.worktree)
        XCTAssertNil(draft.optionsRefreshError)
        XCTAssertFalse(draft.refreshingOptions)
    }

    @MainActor
    func testCreationOptionsKeepSelectedTaskWhenFreshListOmitsIt() async {
        let api = makeAPI { _ in Data("[]".utf8) }
        let draft = SessionCreationDraft()
        draft.initialized = true
        draft.destination = "selected-task"
        draft.cwd = "/actual/worktree"
        let binding = WorkspaceBinding(workspaceId: "ui", workspaceTaskId: "selected-task",
                                       cwd: draft.cwd)
        draft.binding = binding
        draft.tasks = [
            SessionTaskOption(id: "selected-task", workspaceId: "ui", name: "Selected",
                              workspaceName: "Project", cwd: draft.cwd),
            SessionTaskOption(id: "removed-task", workspaceId: "ui", name: "Removed",
                              workspaceName: "Project", cwd: "/removed")
        ]

        await draft.refreshOptions(api: api)

        XCTAssertEqual(draft.tasks.map(\.id), ["selected-task"])
        XCTAssertEqual(draft.tasks.first?.label, "Project / Selected")
        XCTAssertEqual(draft.destination, "selected-task")
        XCTAssertEqual(draft.binding, binding)
        XCTAssertEqual(draft.cwd, binding.cwd)
    }

    @MainActor
    func testFailedCreationOptionsRefreshRetainsChoicesAndCanRetry() async {
        let offline = makeAPI { _ in throw URLError(.notConnectedToInternet) }
        let draft = SessionCreationDraft(initialMessage: "Keep this draft")
        draft.initialized = true
        draft.tasks = [SessionTaskOption(id: "cached", workspaceId: "ui", name: "Cached",
                                        workspaceName: "Project", cwd: "/repo")]

        await draft.refreshOptions(api: offline)

        XCTAssertEqual(draft.tasks.map(\.id), ["cached"])
        XCTAssertEqual(draft.firstMessage, "Keep this draft")
        XCTAssertNotNil(draft.optionsRefreshError)
        XCTAssertFalse(draft.refreshingOptions)
        XCTAssertNil(draft.loadError, "An options error must not invalidate the initialized form")

        await draft.refreshOptions(api: makeAPI { _ in Data("[]".utf8) })

        XCTAssertTrue(draft.tasks.isEmpty)
        XCTAssertNil(draft.optionsRefreshError)
    }

    @MainActor
    func testCreationOptionsCoalesceConcurrentRefreshAndRefetchAfterInvalidation() async throws {
        let started = expectation(description: "First options request started")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let lock = NSLock()
        var taskRequests = 0
        let updatedGroups = try JSONEncoder().encode(searchGroups())
        let api = makeAPI { request in
            guard request.url?.path == "/api/tasks" else { return Data("[]".utf8) }
            let requestNumber = lock.withLock {
                taskRequests += 1
                return taskRequests
            }
            if requestNumber == 1 {
                started.fulfill()
                XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
                return Data("[]".utf8)
            }
            return updatedGroups
        }
        let draft = SessionCreationDraft()
        draft.initialized = true
        let refresh = Task { await draft.refreshOptions(api: api) }
        await fulfillment(of: [started], timeout: 2)

        await draft.refreshOptions(api: api)
        await draft.refreshOptions(api: api, invalidated: true)
        await draft.refreshOptions(api: api, invalidated: true)
        release.signal()
        await refresh.value

        XCTAssertEqual(lock.withLock { taskRequests }, 2,
                       "Concurrent opens share the first request; mutations cause one fresh snapshot")
        XCTAssertEqual(draft.tasks.map(\.id), ["checkout", "backend"])
        XCTAssertFalse(draft.refreshingOptions)
    }

    @MainActor
    func testCreationOptionsSurviveCancelledPopoverAndReopenWithPendingInvalidation() async throws {
        let started = expectation(description: "Popover options request started")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let lock = NSLock()
        var taskRequests = 0
        let updatedGroups = try JSONEncoder().encode(searchGroups())
        let api = makeAPI { request in
            guard request.url?.path == "/api/tasks" else { return Data("[]".utf8) }
            let requestNumber = lock.withLock {
                taskRequests += 1
                return taskRequests
            }
            if requestNumber == 1 {
                started.fulfill()
                XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
                return Data("[]".utf8)
            }
            return updatedGroups
        }
        let draft = SessionCreationDraft(initialMessage: "保留快速切换前的草稿")
        draft.initialized = true
        let popover = Task { await draft.refreshOptions(api: api) }
        await fulfillment(of: [started], timeout: 2)

        popover.cancel()
        await draft.refreshOptions(api: api, invalidated: true)
        await draft.refreshOptions(api: api)
        XCTAssertTrue(draft.refreshingOptions)
        release.signal()
        await popover.value

        XCTAssertEqual(lock.withLock { taskRequests }, 2,
                       "Closing the initiating popover must not lose the pending fresh read")
        XCTAssertEqual(draft.tasks.map(\.id), ["checkout", "backend"])
        XCTAssertEqual(draft.firstMessage, "保留快速切换前的草稿")
        XCTAssertNil(draft.optionsRefreshError)
        XCTAssertFalse(draft.refreshingOptions)
    }


    @MainActor
    func testPromptCreationReturnsAcceptedRunningSessionWithoutWaitingForTurn() async throws {
        let api = makeAPI { request in
            XCTAssertEqual(request.url?.path, "/api/structured-sessions")
            let body = try Self.requestBody(request)
            XCTAssertEqual(body["respondImmediately"] as? Bool, true)
            XCTAssertEqual(body["prompt"] as? String, "fixture only")
            return Data(#"{"id":"accepted","provider":"pi","status":"running","structuredState":{"inFlight":true}}"#.utf8)
        }
        let session = try await api.createStructuredSession(provider: "pi", cwd: "/fixture", mode: "managed", prompt: "fixture only")
        XCTAssertEqual(session.id, "accepted")
        XCTAssertEqual(session.status, "running")
        XCTAssertEqual(session.structuredState?.inFlight, true)
    }

    @MainActor
    func testCreationPublishesReceiptWithoutWritingExecutionDefaults() async throws {
        var posts: [String] = []
        let api = makeAPI { request in
            posts.append(request.url?.path ?? "")
            switch request.url?.path {
            case "/api/tasks":
                return Data(#"{"id":"task-new","workspaceId":"global","name":"New task","status":"active","cwd":"/fixture"}"#.utf8)
            case "/api/structured-sessions":
                let body = try Self.requestBody(request)
                XCTAssertEqual(body["respondImmediately"] as? Bool, true)
                XCTAssertEqual(body["workspaceTaskId"] as? String, "task-new")
                return Data(#"{"id":"session-new","provider":"claude","status":"running","cwd":"/fixture","workspaceId":"global","workspaceTaskId":"task-new","structuredState":{"inFlight":true}}"#.utf8)
            default:
                XCTFail("Creation must not write employee or server defaults")
                throw URLError(.unsupportedURL)
            }
        }
        let store = trackedStore(api: api, serverID: "handoff")
        let draft = SessionCreationDraft(context: .init(startsNewTask: true), initialMessage: "fixture only")
        draft.loading = false; draft.cwd = "/fixture"
        var navigated = false
        await draft.create(api: api, workspaceStore: store) { snapshot in
            XCTAssertEqual(snapshot.id, "session-new")
            XCTAssertEqual(draft.submissionPhase, .accepted)
            navigated = true
        }
        XCTAssertTrue(navigated)
        XCTAssertEqual(draft.firstMessage, "")
        XCTAssertEqual(posts, ["/api/tasks", "/api/structured-sessions"])
    }

    @MainActor
    func testRejectedSessionRetainsCommittedTaskAndRetryNeverCreatesAnotherTask() async throws {
        let lock = NSLock()
        var taskCount = 0, sessionCount = 0
        let api = makeAPI { request in
            if request.url?.path == "/api/settings/config" { return Data("{}".utf8) }
            if request.url?.path == "/api/tasks" {
                lock.withLock { taskCount += 1 }
                return Data(#"{"id":"task-kept","workspaceId":"global","name":"Retained","status":"active","cwd":"/fixture"}"#.utf8)
            }
            XCTAssertEqual(request.url?.path, "/api/structured-sessions")
            let count = lock.withLock { sessionCount += 1; return sessionCount }
            if count == 1 { throw WandAPI.APIError.server(status: 403, message: "fixture rejection") }
            XCTAssertEqual(try Self.requestBody(request)["workspaceTaskId"] as? String, "task-kept")
            return Data(#"{"id":"session-retry","status":"running","workspaceId":"global","workspaceTaskId":"task-kept"}"#.utf8)
        }
        let store = trackedStore(api: api, serverID: "retry")
        let draft = SessionCreationDraft(context: .init(startsNewTask: true), initialMessage: "preserved fixture")
        backgroundDrafts.append(draft)
        draft.loading = false; draft.cwd = "/fixture"
        await draft.create(api: api, workspaceStore: store) { _ in XCTFail("A rejected session must not navigate") }
        XCTAssertFalse(draft.creating)
        XCTAssertEqual(draft.submissionPhase, .failed)
        XCTAssertEqual(draft.errorMessage, "fixture rejection")
        XCTAssertEqual(draft.firstMessage, "preserved fixture")
        XCTAssertEqual(draft.destination, "task-kept")
        XCTAssertEqual(store.taskGroups.first?.tasks.first?.id, "task-kept")
        var navigationCount = 0
        await draft.create(api: api, workspaceStore: store) { _ in navigationCount += 1 }
        XCTAssertEqual(navigationCount, 1)
        XCTAssertEqual(lock.withLock { taskCount }, 1)
        XCTAssertEqual(lock.withLock { sessionCount }, 2)
        XCTAssertEqual(store.taskGroups.first?.tasks.first?.sessions.count, 1)
    }

    @MainActor
    func testCreationSingleFlightAndLateReceiptCannotClearNewInputOrHijackNavigation() async throws {
        let started = expectation(description: "Session request started")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let api = makeAPI { request in
            if request.url?.path == "/api/settings/config" {
                XCTAssertEqual(try Self.requestBody(request)["defaultProvider"] as? String, "claude", "Save captured settings, not later edits")
                return Data("{}".utf8)
            }
            XCTAssertEqual(request.url?.path, "/api/structured-sessions")
            started.fulfill()
            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            return Data(#"{"id":"session-late","status":"running"}"#.utf8)
        }
        let draft = SessionCreationDraft(context: .init(cwd: "/fixture", startsNewTask: false), initialMessage: "old fixture")
        backgroundDrafts.append(draft)
        draft.loading = false
        let nextDraft = SessionCreationDraft()
        var callbacks = 0
        let submission = Task { await draft.create(api: api, workspaceStore: nil) { _ in
            callbacks += 1
            XCTAssertFalse(SessionCreationDraft.shouldOpenReceipt(originDraftID: draft.id, currentDraftID: nextDraft.id, creationVisible: true))
        } }
        await fulfillment(of: [started], timeout: 2)
        await draft.create(api: api, workspaceStore: nil) { _ in XCTFail("Double submission must not dispatch") }
        draft.firstMessage = "new input"
        draft.provider = .codex
        release.signal()
        await submission.value
        XCTAssertEqual(callbacks, 1)
        XCTAssertEqual(draft.firstMessage, "new input")
        XCTAssertFalse(SessionCreationDraft.shouldOpenReceipt(originDraftID: draft.id, currentDraftID: draft.id, creationVisible: false))
        XCTAssertTrue(SessionCreationDraft.shouldOpenReceipt(originDraftID: draft.id, currentDraftID: draft.id, creationVisible: true))
        XCTAssertFalse(SessionCreationDraft.creationIsVisible(showCreation: false, showCommunications: true,
            showTaskBoard: false, hasSelectedTask: false, hasSelectedSession: false), "Contacts/DM navigation must not be hijacked by a late creation receipt")
        XCTAssertFalse(SessionCreationDraft.creationIsVisible(showCreation: false, showCommunications: false,
            showTaskBoard: true, hasSelectedTask: false, hasSelectedSession: false))
        XCTAssertTrue(SessionCreationDraft.creationIsVisible(showCreation: true, showCommunications: false,
            showTaskBoard: false, hasSelectedTask: true, hasSelectedSession: false))
    }

    @MainActor
    func testAcceptedTaskAndDirectoryDeletionImmediatelyUpdatesSidebarEvenIfRefreshFails() async throws {
        for directory in [false, true] {
            let groups = try searchGroups(), group = groups[0], task = group.tasks[0]
            let data = try JSONEncoder().encode(groups)
            let lock = NSLock()
            var deleted = false
            let api = makeAPI { request in
                if request.httpMethod == "DELETE" {
                    XCTAssertEqual(request.url?.path, directory ? "/api/workspaces/\(group.workspaceId)" : "/api/workspace-tasks/\(task.id)")
                    if !directory { XCTAssertEqual(request.url?.query, "cascade=1") }
                    lock.withLock { deleted = true }
                    return Data("{}".utf8)
                }
                XCTAssertEqual(request.url?.path, "/api/tasks")
                if lock.withLock({ deleted }) { throw URLError(.notConnectedToInternet) }
                return data
            }
            let store = trackedStore(api: api, serverID: "deletion-receipt")
            await store.loadTaskGroups()
            if directory {
                try await store.deleteWorkspace(workspaceId: group.workspaceId)
                XCTAssertFalse(store.taskGroups.contains { $0.id == group.id })
            } else {
                try await store.deleteWorkspaceTask(workspaceId: task.workspaceId, taskId: task.id)
                XCTAssertFalse(store.taskGroups.flatMap(\.tasks).contains { $0.id == task.id })
                XCTAssertTrue(store.taskGroups.flatMap(\.tasks).contains { $0.id == group.tasks[1].id }, "Unrelated tasks remain")
            }
            await store.waitForTaskGroupsForTesting()
            XCTAssertNotNil(store.taskGroupsError, "A failed read does not undo the accepted deletion")
            XCTAssertFalse(store.taskGroups.flatMap(\.tasks).contains { $0.id == task.id })
            XCTAssertTrue(store.taskGroups.contains { $0.id == groups[1].id }, "Unrelated directories remain")
        }
    }

    @MainActor
    func testPartialSessionDeletionRefreshesActualMembershipAndReportsFailure() async throws {
        let groups = try searchGroups()
        let lock = NSLock()
        var listReads = 0
        let api = makeAPI { request in
            if request.url?.path == "/api/sessions/batch-delete" {
                XCTAssertEqual(request.httpMethod, "POST")
                let ids = try Self.requestBody(request)["sessionIds"] as? [String] ?? []
                XCTAssertEqual(Set(ids), Set(["deleted", "failed"]))
                return Data(#"{"ok":true,"deleted":1,"failed":["failed"]}"#.utf8)
            }
            XCTAssertEqual(request.url?.path, "/api/tasks")
            lock.withLock { listReads += 1 }
            return try JSONEncoder().encode(groups)
        }
        let store = trackedStore(api: api, serverID: "partial-deletion")
        do {
            try await store.deleteSessions(["deleted", "failed", "deleted", ""])
            XCTFail("A partially successful response is not full success")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("已删除 1 个会话"))
            XCTAssertTrue(error.localizedDescription.contains("1 个会话未删除"))
        }
        XCTAssertEqual(lock.withLock { listReads }, 1, "Refresh accepted deletions before reporting remaining failures")
        XCTAssertEqual(store.taskGroups, groups)
    }

    @MainActor
    func testRejectedTaskAndDirectoryDeletionPreservesSidebarMembership() async throws {
        for directory in [false, true] {
            let groups = try searchGroups(), group = groups[0], task = group.tasks[0]
            let data = try JSONEncoder().encode(groups)
            let api = makeAPI { request in
                if request.httpMethod == "DELETE" { throw URLError(.noPermissionsToReadFile) }
                return data
            }
            let store = trackedStore(api: api, serverID: "rejected-deletion")
            await store.loadTaskGroups()
            do {
                if directory { try await store.deleteWorkspace(workspaceId: group.workspaceId) }
                else { try await store.deleteWorkspaceTask(workspaceId: task.workspaceId, taskId: task.id) }
                XCTFail("Rejected deletion must propagate to the confirmation owner's error UI")
            } catch {
                XCTAssertEqual(store.taskGroups, groups, "Do not optimistically remove rows on failure")
            }
        }
    }

    @MainActor
    func testTaskGroupInvalidationDuringReadKeepsReceiptAndRefetchesAfterCallerLeaves() async throws {
        let started = expectation(description: "Old list request started")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let lock = NSLock()
        var requests = 0
        var currentGroups = Data("[]".utf8)
        let api = makeAPI { request in
            XCTAssertEqual(request.url?.path, "/api/tasks")
            let number = lock.withLock { requests += 1; return requests }
            if number == 1 {
                started.fulfill()
                XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
                return Data("[]".utf8)
            }
            return lock.withLock { currentGroups }
        }
        let store = trackedStore(api: api, serverID: "invalidation")
        let first = Task { await store.loadTaskGroups(force: true) }
        await fulfillment(of: [started], timeout: 2)
        let receipt = try JSONDecoder().decode(WorkspaceTaskCreation.self, from: Data(#"{"id":"committed","workspaceId":"global","name":"Visible immediately","status":"active","cwd":"/fixture"}"#.utf8))
        store.recordCreatedTask(receipt, workspace: nil)
        let session = try JSONDecoder().decode(SessionSnapshot.self, from: Data(#"{"id":"committed-session","status":"running","workspaceTaskId":"committed"}"#.utf8))
        store.recordCreatedSession(session)
        store.recordCreatedSession(session)
        XCTAssertEqual(store.taskGroups.first?.tasks.first?.listedSessionCount, 1)
        let encoded = try JSONEncoder().encode(store.taskGroups)
        lock.withLock { currentGroups = encoded }
        var lostReceipt = false
        let observation = store.$taskGroups.sink { groups in
            if !groups.flatMap(\.tasks).contains(where: { $0.id == receipt.id }) { lostReceipt = true }
        }
        defer { observation.cancel() }
        first.cancel()
        let invalidation = Task { await store.loadTaskGroups(force: true) }
        await Task.yield()
        release.signal()
        await first.value; await invalidation.value
        XCTAssertFalse(lostReceipt, "Old responses must never erase the committed local list row")
        XCTAssertEqual(lock.withLock { requests }, 2)
        XCTAssertTrue(store.taskGroupsLoaded)
        XCTAssertEqual(store.taskGroups.first?.tasks.first?.sessions.first?.id, session.id)
        XCTAssertNil(store.taskGroupsError)
    }

    @MainActor
    func testLostTaskOrSessionReceiptBlocksReplayUntilExplicitReview() async throws {
        for lostPath in ["/api/tasks", "/api/structured-sessions"] {
            let lock = NSLock()
            var taskRequests = 0, sessionRequests = 0
            let api = makeAPI { request in
                if request.url?.path == "/api/tasks" {
                    lock.withLock { taskRequests += 1 }
                    if lostPath == "/api/tasks" { return Data("accepted but response lost".utf8) }
                    return Data(#"{"id":"task-unknown","workspaceId":"global","name":"Committed","status":"active","cwd":"/fixture"}"#.utf8)
                }
                XCTAssertEqual(request.url?.path, "/api/structured-sessions")
                lock.withLock { sessionRequests += 1 }
                return Data("accepted but response lost".utf8)
            }
            let draft = SessionCreationDraft(context: .init(startsNewTask: true), initialMessage: "Do not replay this fixture")
            backgroundDrafts.append(draft)
            draft.loading = false; draft.cwd = "/fixture"
            await draft.create(api: api, workspaceStore: nil) { _ in XCTFail("Unknown identity must not be guessed") }
            XCTAssertTrue(draft.creationUnconfirmed)
            XCTAssertFalse(draft.creating)
            XCTAssertEqual(draft.firstMessage, "Do not replay this fixture")
            XCTAssertEqual(draft.destination, lostPath == "/api/tasks" ? "new" : "task-unknown")
            await draft.create(api: api, workspaceStore: nil) { _ in XCTFail("Unknown submission must never replay") }
            XCTAssertEqual(lock.withLock { taskRequests }, 1)
            XCTAssertEqual(lock.withLock { sessionRequests }, lostPath == "/api/tasks" ? 0 : 1)
            draft.allowRetryAfterReview()
            XCTAssertFalse(draft.creationUnconfirmed)
            XCTAssertEqual(draft.submissionPhase, .idle)
            XCTAssertEqual(lock.withLock { taskRequests }, 1, "Review only unlocks, never resends")
        }
    }

    func testCreationDeliveryClassificationUsesProtocolFactsNotErrorWords() {
        for status in [408, 409, 500, 503] {
            XCTAssertTrue(SessionCreationDraft.deliveryIsUncertain(WandAPI.APIError.server(status: status, message: "anything")))
        }
        for status in [400, 401, 403, 422] {
            XCTAssertFalse(SessionCreationDraft.deliveryIsUncertain(WandAPI.APIError.server(status: status, message: "anything")))
        }
        XCTAssertTrue(SessionCreationDraft.deliveryIsUncertain(WandAPI.APIError.network("unrelated wording")))
        XCTAssertFalse(SessionCreationDraft.deliveryIsUncertain(WandAPI.APIError.invalidURL))
    }

    @MainActor
    func testNativeCreationShortcutShowsLoadingAndFailureKeepsDraft() async throws {
        let started = expectation(description: "Native Command-Return creates a session")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let api = makeAPI { request in
            if request.httpMethod == "GET" { return Data("[]".utf8) }
            XCTAssertEqual(request.url?.path, "/api/structured-sessions")
            XCTAssertEqual(try Self.requestBody(request)["respondImmediately"] as? Bool, true)
            started.fulfill()
            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            throw WandAPI.APIError.server(status: 403, message: "本地夹具：启动被拒绝，未执行模型")
        }
        let draft = SessionCreationDraft(context: .init(cwd: "/fixture", startsNewTask: false), initialMessage: "仅用于本地界面验收的草稿")
        backgroundDrafts.append(draft)
        draft.loading = false; draft.initialized = true
        let host = NSHostingView(rootView: NewSessionView(api: api, draft: draft, embedded: true) { _ in XCTFail("Rejected creation cannot navigate") })
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 650)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        func settle() async throws { host.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 200_000_000); host.layoutSubtreeIfNeeded() }
        func capture(_ name: String) throws {
            guard let directory = ProcessInfo.processInfo.environment["WAND_CREATION_OUTPUT"] else { return }
            let output = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + ".png"))
        }
        host.appearance = NSAppearance(named: .aqua)
        try await settle(); try capture("creation-idle")
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let editor = try XCTUnwrap(descendants(host).compactMap { $0 as? ComposerNSTextView }.first)
        let idleEditorRect = editor.convert(editor.bounds, to: host)
        XCTAssertTrue(window.makeFirstResponder(editor))
        let commandReturn = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        XCTAssertTrue(editor.performKeyEquivalent(with: commandReturn))
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(draft.submissionPhase, .startingSession)
        try await settle(); try capture("creation-starting")
        release.signal()
        for _ in 0..<50 {
            if !draft.creating { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(draft.submissionPhase, .failed)
        XCTAssertEqual(draft.firstMessage, "仅用于本地界面验收的草稿")
        XCTAssertTrue(editor === descendants(host).compactMap { $0 as? ComposerNSTextView }.first)
        try await settle(); try capture("creation-failed-light")
        XCTAssertEqual(editor.convert(editor.bounds, to: host).midY, idleEditorRect.midY, accuracy: 1, "Failure feedback cannot move the input or send slot")
        host.appearance = NSAppearance(named: .darkAqua)
        try await settle(); try capture("creation-failed-dark")
        for (name, size) in [("creation-narrow", NSSize(width: 540, height: 680)), ("creation-short", NSSize(width: 900, height: 360))] {
            window.setContentSize(size); host.frame.size = size
            try await settle(); try capture(name)
            XCTAssertTrue(editor === descendants(host).compactMap { $0 as? ComposerNSTextView }.first, "Resizing retains the editor instance")
            XCTAssertEqual(draft.firstMessage, "仅用于本地界面验收的草稿")
            XCTAssertLessThanOrEqual(editor.convert(editor.bounds, to: host).maxX, host.bounds.maxX, "The editor fits a narrow window")
        }
    }

    @MainActor
    func testStandaloneTaskReceiptReturnsBeforeSlowOptionalListRead() async throws {
        let started = expectation(description: "Background list read started")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let api = makeAPI { request in
            if request.httpMethod == "GET" {
                started.fulfill()
                XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
                throw URLError(.notConnectedToInternet)
            }
            return Data(#"{"id":"task-immediate","workspaceId":"global","name":"Immediate","status":"active","cwd":"/fixture"}"#.utf8)
        }
        let store = trackedStore(api: api, serverID: "task-return")
        let result = try await store.createTask(name: "Immediate", directory: "/fixture", worktree: false)
        XCTAssertEqual(result.creation.id, "task-immediate")
        XCTAssertEqual(store.taskGroups.first?.tasks.first?.id, result.creation.id)
        await fulfillment(of: [started], timeout: 2)
        let join = Task { await store.loadTaskGroups() }
        await Task.yield()
        release.signal(); await join.value
        XCTAssertEqual(store.taskGroups.first?.tasks.first?.id, result.creation.id)
        XCTAssertNotNil(store.taskGroupsError)
    }

    private var testSessions: [URLSession] = []
    private var backgroundDrafts: [SessionCreationDraft] = []
    private var backgroundStores: [WorkspaceStore] = []

    @MainActor
    private func trackedStore(api: WandAPI, serverID: String) -> WorkspaceStore {
        let store = WorkspaceStore(api: api, serverID: serverID)
        backgroundStores.append(store)
        return store
    }

    override func tearDown() async throws {
        // Respect actual owner task completion before invalidating its mock transport.
        await Task.yield()
        for draft in backgroundDrafts { await draft.waitForBackgroundWorkForTesting() }
        for store in backgroundStores { await store.waitForTaskGroupsForTesting() }
        backgroundDrafts = []; backgroundStores = []
        testSessions.forEach { $0.invalidateAndCancel() }
        testSessions = []
        try await super.tearDown()
    }

    func testOrganizationAPIDefaultsAutoAndIncludesExplicitTarget() async throws {
        let api = makeAPI { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/sessions/auto-organize")
            let body = try Self.requestBody(request)
            XCTAssertEqual(body["mode"] as? String, "auto")
            XCTAssertEqual(body["target"] as? [String: String], ["kind": "workspace", "workspaceId": "w1"])
            XCTAssertEqual(body["action"] as? String, "preview")
            return Self.organizationPreview
        }
        let response = try await api.prepareConversationOrganization(target: .workspace("w1"))
        XCTAssertEqual(response.sessionCount, 1)
        XCTAssertEqual(response.manualSessionCount, 2)
        let all = makeAPI { request in
            let body = try Self.requestBody(request)
            XCTAssertEqual(body["mode"] as? String, "all")
            XCTAssertEqual(body["target"] as? [String: String], ["kind": "directory", "cwd": "/tmp/project"])
            return Self.organizationPreview
        }
        _ = try await all.prepareConversationOrganization(target: .directory("/tmp/project"), mode: .all)
    }

    @MainActor
    func testOrganizationActionKeepsResultAndClearsItWhenTargetChanges() async throws {
        let api = makeAPI { request in
            let body = try Self.requestBody(request)
            return body["action"] as? String == "preview" ? Self.organizationPreview : Self.organizationComplete
        }
        let action = WandTaskOrganizationAction()
        var refreshes = 0
        await action.run(api: api, target: .all, mode: .auto) { refreshes += 1 }
        XCTAssertFalse(action.busy)
        XCTAssertEqual(refreshes, 0, "preview must not start model work or change tasks")
        XCTAssertNotNil(action.preview)
        XCTAssertNil(action.result)
        action.confirm(api: api) { refreshes += 1 }
        await action.waitForBackgroundWorkForTesting()
        XCTAssertEqual(refreshes, 1)
        XCTAssertEqual(action.result?.label, "已新建 1 个任务、归入 1 个会话")
        XCTAssertTrue(action.result?.detail.contains("跳过 2 个人工任务会话") == true)
        action.reset()
        XCTAssertNil(action.result)
        XCTAssertNil(action.error)
        await action.run(api: api, target: .workspace("new-target"), mode: .all) {}
        action.confirm(api: api) {
            refreshes += 1
            action.reset() // 等待中的请求不能把旧范围的结果重新带回新范围。
        }
        await action.waitForBackgroundWorkForTesting()
        XCTAssertFalse(action.busy)
        XCTAssertEqual(refreshes, 2)
        XCTAssertNil(action.result)
    }

    @MainActor
    func testOrganizationRefreshMovesSidebarMembersFromDefaultGroupIntoCreatedTask() async throws {
        let lock = NSLock()
        var committed = false
        let initial = Data(#"[{"workspaceId":"w1","workspaceName":"wand","workspaceCwd":"/repo","tasks":[],"standaloneSessions":[{"id":"s1","title":"通知设置保存","cwd":"/repo","provider":"pi","sessionKind":"structured","status":"idle"}]}]"#.utf8)
        let classified = Data(#"[{"workspaceId":"w1","workspaceName":"wand","workspaceCwd":"/repo","tasks":[{"id":"new-task","workspaceId":"w1","name":"修复通知保存","cwd":"/repo","status":"active","createdAt":"2026-10-01","sessions":[{"id":"s1","title":"通知设置保存","cwd":"/repo","provider":"pi","sessionKind":"structured","status":"idle"}]}],"standaloneSessions":[]}]"#.utf8)
        let api = makeAPI { request in
            if request.url?.path == "/api/tasks" { return lock.withLock { committed } ? classified : initial }
            if request.url?.path == "/api/sessions/auto-organize" {
                if try Self.requestBody(request)["action"] as? String == "preview" { return Self.organizationPreview }
                lock.withLock { committed = true }
                return Self.organizationComplete
            }
            return Data("[]".utf8)
        }
        let store = trackedStore(api: api, serverID: "sidebar-content-organization")
        await store.loadTaskGroups()
        XCTAssertEqual(store.taskGroups.flatMap(\.standaloneSessions).map(\.id), ["s1"])
        let action = WandTaskOrganizationAction()
        await action.run(api: api, target: .workspace("w1"), mode: .auto, onChanged: {})
        XCTAssertEqual(store.taskGroups.flatMap(\.standaloneSessions).map(\.id), ["s1"], "预览不挪会话")
        action.confirm(api: api) { await store.loadTaskGroups(force: true) }
        await action.waitForBackgroundWorkForTesting()
        let projected = TaskListPresentation.sidebarDirectoryGroups(store.taskGroups, workspaces: [], query: "", activeOnly: false, selectedSessionId: "s1", selectedTaskId: nil)
        XCTAssertTrue(projected.flatMap(\.standaloneSessions).isEmpty)
        XCTAssertEqual(projected.flatMap(\.tasks).map(\.name), ["修复通知保存"])
        XCTAssertEqual(projected.flatMap(\.tasks).flatMap(\.sessions).map(\.id), ["s1"])
        let host = NSHostingView(rootView: WorkspaceListView(store: store, api: api, selectedTaskId: "new-task", selectedSessionId: "s1", query: "", onOpenTask: { _, _ in }).frame(width: 260))
        host.frame = NSRect(x: 0, y: 0, width: 260, height: 680)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 220_000_000); host.layoutSubtreeIfNeeded()
        XCTAssertNotNil(sidebarPresenceView(host, id: "sidebar-task-new-task"))
        XCTAssertNil(sidebarPresenceView(host, id: "sidebar-default-task-w1"))
        try captureSidebar(host, name: "fixture-created-task-after-organization")
    }

    @MainActor
    func testOrganizationActionShowsAPIFailureWithoutLosingRetryControls() async throws {
        let api = makeAPI { _ in throw NSError(domain: "organization-test", code: 503) }
        let action = WandTaskOrganizationAction()
        var refreshed = false
        await action.run(api: api, target: .all, mode: .auto) { refreshed = true }
        XCTAssertFalse(action.busy)
        XCTAssertFalse(refreshed)
        XCTAssertNil(action.result)
        XCTAssertNotNil(action.error)
        XCTAssertEqual(action.label, "归类未完成")
        action.reset()
        XCTAssertEqual(action.label, "会话自动归类")
    }

    private static let organizationPreview = Data(#"{"kind":"preview","preview":{"token":"confirm-token","sessionCount":1,"manualSessionCount":2,"skippedSessionCount":0,"existingTaskCount":0,"contentCharacters":100,"estimatedModelRequests":1,"unchanged":false}}"#.utf8)
    private static let organizationComplete = Data(#"{"kind":"job","job":{"id":"job-1","status":"completed","stage":"完成","processedSessions":1,"totalSessions":1,"modelRequests":1,"logSessionId":"log-1","result":{"eligibleSessions":1,"analyzedSessions":1,"skippedManualSessions":2,"skippedSessions":0,"createdTasks":[{"taskId":"new-task"}],"reusedTasks":[],"updatedTasks":[],"movedSessions":[{"sessionId":"s1"}],"unassignedSessions":[],"refused":[]}}}"#.utf8)

    func testOrganizationUnknownStartQueriesSameReceiptWithoutAnotherPost() async throws {
        var posts = 0
        let api = makeAPI { request in
            if request.httpMethod == "POST" {
                posts += 1
                XCTAssertEqual(try Self.requestBody(request)["token"] as? String, "confirm-token")
                throw NSError(domain: "unknown-receipt", code: 503)
            }
            XCTAssertEqual(request.url?.path, "/api/sessions/auto-organize/by-token/confirm-token")
            return Self.organizationComplete
        }
        let accepted = try await api.startConversationOrganization(token: "confirm-token")
        XCTAssertEqual(accepted.id, "job-1")
        XCTAssertEqual(posts, 1)
    }

    private func makeAPI(handler: @escaping (URLRequest) throws -> Data) -> WandAPI {
        let host = "\(UUID().uuidString.lowercased()).wand.test"
        WorkspaceContractURLProtocol.register(host: host, handler: handler)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WorkspaceContractURLProtocol.self]
        let session = URLSession(configuration: configuration)
        testSessions.append(session)
        return WandAPI(baseURL: URL(string: "https://\(host)")!, token: nil, session: session)
    }

    private static func requestBody(_ request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testStandaloneTaskRequestUsesGlobalTasksEndpoint() {
        let scratch = createStandaloneTaskRequest(name: "随口问问", cwd: nil, worktree: false)
        XCTAssertEqual(scratch.path, "/api/tasks")
        XCTAssertEqual(scratch.body["name"], .string("随口问问"))
        XCTAssertNil(scratch.body["cwd"])
        XCTAssertEqual(scratch.body["worktree"], .bool(false))

        let mounted = createStandaloneTaskRequest(name: "挂目录", cwd: "/tmp/work", worktree: true)
        XCTAssertEqual(mounted.body["cwd"], .string("/tmp/work"))
        XCTAssertEqual(mounted.body["worktree"], .bool(true))
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

/// Intercepts every request made by these tests; no request reaches a Wand server or AI tool.
private final class WorkspaceContractURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var handlers: [String: (URLRequest) throws -> Data] = [:]

    static func register(host: String, handler: @escaping (URLRequest) throws -> Data) {
        lock.lock()
        defer { lock.unlock() }
        handlers[host] = handler
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let handler = Self.handlers[request.url?.host ?? ""]
        Self.lock.unlock()
        do {
            guard let handler, let url = request.url else { throw URLError(.unsupportedURL) }
            let data = try handler(request)
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch WandAPI.APIError.server(let status, let message) {
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: ["error": message]))
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

/// The actual creation view loads installed-service defaults without starting any work.
final class NewSessionLiveTests: XCTestCase {
    @MainActor
    func testInstalledServiceCreationReferenceLayoutReadOnly() async throws {
        guard ProcessInfo.processInfo.environment["WAND_CREATION_LIVE"] == "1" else {
            throw XCTSkip("Installed-service creation acceptance is opt-in")
        }
        XCTAssertTrue(NativeAcceptance.enabled)
        let storage = NativeAcceptance.defaults
        defer { NativeAcceptance.cleanup() }
        let origin = try XCTUnwrap(URL(string: try XCTUnwrap(storage.string(forKey: "wand.serverURL"))))
        let api = WandAPI(baseURL: origin, token: try XCTUnwrap(storage.string(forKey: "wand.token")))
        let draft = SessionCreationDraft(context: .init(startsNewTask: false))
        let host = NSHostingView(rootView: NewSessionView(api: api, draft: draft, embedded: true) { _ in
            XCTFail("Read-only acceptance must never create a session")
        }.defaultAppStorage(storage))
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 840)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        for _ in 0..<200 {
            host.layoutSubtreeIfNeeded()
            if draft.initialized && !draft.loading { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(draft.initialized, "Installed defaults must finish loading")
        XCTAssertNil(draft.loadError)
        XCTAssertFalse(draft.employees.isEmpty)
        XCTAssertFalse(draft.creating)
        XCTAssertTrue(draft.firstMessage.isEmpty)
        let editor = try XCTUnwrap(sidebarDescendants(host).compactMap { $0 as? ComposerNSTextView }.first)
        for (name, size, appearance) in [
            ("installed-creation-light", NSSize(width: 900, height: 840), NSAppearance.Name.aqua),
            ("installed-creation-narrow-dark", NSSize(width: 540, height: 680), NSAppearance.Name.darkAqua)
        ] {
            host.appearance = NSAppearance(named: appearance)
            window.setContentSize(size); host.frame.size = size
            try await Task.sleep(nanoseconds: 250_000_000); host.layoutSubtreeIfNeeded()
            try captureSidebar(host, name: name)
            XCTAssertTrue(editor === sidebarDescendants(host).compactMap { $0 as? ComposerNSTextView }.first)
            XCTAssertLessThanOrEqual(editor.convert(editor.bounds, to: host).maxX, host.bounds.maxX)
        }
    }
}

/// Separate suite: the live read-only guard must never run mutation fixtures.
final class SidebarLiveTests: XCTestCase {
    @MainActor
    func testInstalledServiceSidebarLoadsEveryTaskAndSwitchesNativeProjectionsReadOnly() async throws {
        guard ProcessInfo.processInfo.environment["WAND_SIDEBAR_LIVE"] == "1" else {
            throw XCTSkip("Installed-service sidebar acceptance is opt-in")
        }
        XCTAssertTrue(NativeAcceptance.enabled, "Live UI must use the read-only request guard")
        let storage = NativeAcceptance.defaults
        defer { NativeAcceptance.cleanup() }
        let origin = try XCTUnwrap(URL(string: try XCTUnwrap(storage.string(forKey: "wand.serverURL"))))
        let token = try XCTUnwrap(storage.string(forKey: "wand.token"))
        let api = WandAPI(baseURL: origin, token: token)
        let groups = try await api.listTaskGroups()
        let tasks = groups.flatMap(\.tasks).filter { $0.status != "done" && $0.archived != true }
        XCTAssertFalse(tasks.isEmpty, "Live fixture needs at least one existing task; do not manufacture user data")
        var known = Set<String>(), expanded = Set<String>()
        TaskListPresentation.discoverDirectories(groups, known: &known, expanded: &expanded)
        let projected = TaskListPresentation.sidebarDirectoryGroups(groups, workspaces: [], query: "", activeOnly: false,
            selectedSessionId: nil, selectedTaskId: nil)
        XCTAssertEqual(Set(projected.flatMap(\.tasks).map(\.id)), Set(tasks.map(\.id)))
        XCTAssertTrue(projected.filter { !$0.tasks.isEmpty }.allSatisfy { expanded.contains($0.id) })
        let recent = TaskListPresentation.recentGroups(groups, query: "", activeOnly: false, selectedSessionId: nil)
        let expectedSessions = tasks.flatMap(\.sessions) + groups.flatMap(\.standaloneSessions)
        XCTAssertEqual(Set(recent.flatMap(\.entries).map(\.id)), Set(expectedSessions.filter { $0.archived != true }.map(\.id)))
        storage.set(false, forKey: "wand.desktop.sidebarRecent")
        storage.set(false, forKey: "wand.desktop.sidebarActiveOnly")
        let host = NSHostingView(rootView: MainShellView(serverURL: origin, token: token).defaultAppStorage(storage))
        host.frame = NSRect(x: 0, y: 0, width: 1280, height: 850)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host; window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        host.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 1_500_000_000); host.layoutSubtreeIfNeeded()
        try captureSidebar(host, name: "installed-directory")
        XCTAssertNotNil(sidebarPresenceView(host, id: "sidebar-task-\(tasks[0].id)"),
            "An actual loaded task must be rendered before any expand click")
        let searchButton = try XCTUnwrap(sidebarPresenceView(host, id: "sidebar-search-button"))
        let buttonFrame = searchButton.convert(searchButton.bounds, to: host)
        try clickSidebarMarker(host, window: window, id: "sidebar-search-button")
        try await Task.sleep(nanoseconds: 300_000_000); host.layoutSubtreeIfNeeded()
        let field = try XCTUnwrap(sidebarDescendants(host).compactMap { $0 as? NSTextField }
            .first { $0.placeholderString == "搜索工作区、任务或会话" })
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView, "Search focuses the native input immediately")
        editor.insertText("no-match-sidebar-acceptance", replacementRange: NSRange(location: 0, length: 0))
        try await Task.sleep(nanoseconds: 250_000_000); host.layoutSubtreeIfNeeded()
        XCTAssertNil(sidebarPresenceView(host, id: "sidebar-task-\(tasks[0].id)"))
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        window.sendEvent(escape)
        try await Task.sleep(nanoseconds: 350_000_000); host.layoutSubtreeIfNeeded()
        XCTAssertNotNil(sidebarPresenceView(host, id: "sidebar-task-\(tasks[0].id)"), "Escape clears the search and restores tasks")
        XCTAssertEqual(searchButton.convert(searchButton.bounds, to: host), buttonFrame, "Search never moves its trigger")
        storage.set(true, forKey: "wand.desktop.sidebarRecent")
        try await Task.sleep(nanoseconds: 400_000_000); host.layoutSubtreeIfNeeded()
        try captureSidebar(host, name: "installed-recent")
        XCTAssertNotNil(sidebarPresenceView(host, id: "sidebar-recent-\(try XCTUnwrap(recent.first?.entries.first).id)"))
        storage.set(true, forKey: "wand.desktop.sidebarActiveOnly")
        try await Task.sleep(nanoseconds: 400_000_000); host.layoutSubtreeIfNeeded()
        try captureSidebar(host, name: "installed-active")
        storage.set(false, forKey: "wand.desktop.sidebarActiveOnly")
        storage.set(false, forKey: "wand.desktop.sidebarRecent")
        try await Task.sleep(nanoseconds: 400_000_000); host.layoutSubtreeIfNeeded()
        XCTAssertNotNil(sidebarPresenceView(host, id: "sidebar-task-\(tasks[0].id)"), "Switching views never loses the task projection")
    }

}

@MainActor
private func captureSidebar(_ host: NSView, name: String) throws {
    guard let path = ProcessInfo.processInfo.environment["WAND_SIDEBAR_OUTPUT"] else { return }
    let directory = URL(fileURLWithPath: path, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name + ".png"))
}

@MainActor
private func sidebarPresenceView(_ root: NSView, id: String) -> NSView? {
    if root.identifier?.rawValue == id && root.bounds.width > 0 && root.bounds.height > 0 { return root }
    return root.subviews.compactMap { sidebarPresenceView($0, id: id) }.first
}

@MainActor
private func sidebarDescendants(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(sidebarDescendants) }

@MainActor
private func clickSidebarMarker(_ host: NSView, window: NSWindow, id: String) throws {
    let marker = try XCTUnwrap(sidebarPresenceView(host, id: id))
    let rect = marker.convert(marker.bounds, to: nil)
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: NSPoint(x: rect.midX, y: rect.midY),
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        window.sendEvent(event)
    }
}
