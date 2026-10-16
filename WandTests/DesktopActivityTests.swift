import AppKit
import CoreGraphics
import UserNotifications
import XCTest
@testable import Wand

@MainActor
final class DesktopActivityTests: XCTestCase {
    private func snapshot(_ changes: [String: Any] = [:]) throws -> SessionSnapshot {
        var json: [String: Any] = ["id": "s1", "title": "测试任务", "sessionKind": "structured", "status": "idle", "completionRevision": 0]
        json.merge(changes) { _, new in new }
        return try JSONDecoder().decode(SessionSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func richSnapshot(completedSteps: Int = 1, finished: Bool = false) throws -> SessionSnapshot {
        let formatter = ISO8601DateFormatter()
        let ended = Date()
        let started = formatter.string(from: ended.addingTimeInterval(-130))
        var state: [String: Any] = ["inFlight": !finished, "engine": "core", "model": "gpt-test"]
        if !finished { state["activeRequestId"] = "request-1"; state["turnStartedAt"] = started }
        let tasks: [[String: Any]] = (0..<3).map { index in
            ["content": "步骤\(index + 1)", "status": index < completedSteps ? "completed" : index == completedSteps ? "in_progress" : "pending", "activeForm": "正在处理步骤\(index + 1)"]
        }
        var blocks: [[String: Any]] = [
            ["type": "tool_use", "id": "todo", "name": "todo", "input": ["__wandTasks": tasks]],
            ["type": "tool_result", "tool_use_id": "todo", "content": "ok", "is_error": false],
            ["type": "tool_use", "id": "shell", "name": "bash", "input": ["command": "PRIVATE-ARGUMENT"]],
            ["type": "tool_result", "tool_use_id": "shell", "content": "PRIVATE-RESULT", "is_error": false],
            ["type": "tool_use", "id": "read", "name": "Read", "input": ["path": "/PRIVATE-PATH"]]
        ]
        if finished { blocks.append(["type": "tool_result", "tool_use_id": "read", "content": "PRIVATE-ERROR", "is_error": true]) }
        var assistant: [String: Any] = ["role": "assistant", "content": blocks]
        if finished { assistant["completedAt"] = formatter.string(from: ended) }
        return try snapshot(["provider": "pi", "engine": "core", "selectedModel": "configured-model",
            "structuredState": state, "status": "idle", "completionRevision": finished ? 1 : 0,
            "messages": [["role": "user", "createdAt": started, "content": [["type": "text", "text": "fixture"]]], assistant],
            "messageOffset": 0, "messageTotal": 2])
    }

    func testRichProgressUsesRealStepsToolsResultsAndActualEngine() throws {
        let snapshot = try richSnapshot()
        let activity = DesktopActivity(snapshot)
        let progress = try XCTUnwrap(activity.progress)
        XCTAssertEqual(activity.providerLabel, "Wand Agent")
        XCTAssertEqual(activity.model, "gpt-test", "Actual execution model wins over the configured preference")
        XCTAssertEqual(progress.completedSteps, 1)
        XCTAssertEqual(progress.totalSteps, 3)
        XCTAssertEqual(progress.currentStep, "正在处理步骤2")
        XCTAssertEqual(progress.toolCalls, 3)
        XCTAssertEqual(progress.successfulCalls, 2)
        XCTAssertEqual(progress.failedCalls, 0)
        XCTAssertEqual(progress.pendingCalls, 1)
        XCTAssertEqual(progress.currentTool, "Read")
        XCTAssertTrue(progress.progressLabel.contains("1/3"))
        XCTAssertTrue(activity.notificationBody.contains("Wand Agent"))
        XCTAssertTrue(activity.notificationBody.contains("Read"))
        XCTAssertFalse(activity.notificationBody.contains("PRIVATE"))
    }

    func testExecutionCompletionDoesNotPretendAllStepsOrToolsSucceeded() throws {
        let activity = DesktopActivity(try richSnapshot(completedSteps: 2, finished: true))
        XCTAssertEqual(activity.phase, .completed)
        XCTAssertEqual(activity.progress?.completedSteps, 2)
        XCTAssertEqual(activity.progress?.totalSteps, 3)
        XCTAssertEqual(activity.progress?.failedCalls, 1)
        XCTAssertEqual(activity.progress?.elapsed, "02:10")
        XCTAssertTrue(activity.notificationBody.contains("工具成功 2 · 失败 1"))
        XCTAssertFalse(activity.notificationBody.contains("PRIVATE-ERROR"))
    }

    func testToolCountsAreTurnScopedAndWindowedCountsAreExplicitSamples() throws {
        let old: [String: Any] = ["role": "assistant", "content": [["type": "tool_use", "id": "old", "name": "OldTool", "input": [:]]]]
        let current: [String: Any] = ["role": "assistant", "content": [["type": "tool_use", "id": "new", "name": "NewTool", "input": [:]]]]
        let snapshot = try snapshot(["messages": [old, ["role": "user", "content": []], current]])
        let progress = DesktopExecutionProgress(snapshot: snapshot)
        XCTAssertEqual(progress.toolCalls, 1)
        XCTAssertEqual(progress.lastTool, "NewTool")
        XCTAssertTrue(progress.coversCurrentTurn)
        let suffix = DesktopExecutionProgress(snapshot: try self.snapshot(["messages": [current], "messageOffset": 20]))
        XCTAssertFalse(suffix.coversCurrentTurn)
        XCTAssertTrue(suffix.progressLabel.contains("近期采样"))
        XCTAssertNil(suffix.totalSteps)
        let unknown = DesktopExecutionProgress(snapshot: try self.snapshot())
        XCTAssertTrue(unknown.progressLabel.contains("未提供"))
        XCTAssertEqual(unknown.resultLabel, "工具结果未提供")
    }

    func testMonitorEnrichesMenuAndMilestoneNotificationsWithoutReplayingSteps() async throws {
        let monitor = DesktopActivityMonitor(defaults: UserDefaults(suiteName: "DesktopActivityTests.\(UUID())")!)
        let api = ActivityAPI()
        api.snapshots = [try richSnapshot()]
        var events: [DesktopActivityEvent] = []
        monitor.onEvents = { events += $0 }
        monitor.connect(id: UUID(), api: api, poll: false)
        await monitor.refresh(waitForProgress: true)
        XCTAssertEqual(monitor.activities.first?.progress?.completedSteps, 1)
        XCTAssertTrue(events.isEmpty, "Initial step history isn't a new milestone")
        api.snapshots = [try richSnapshot(completedSteps: 2)]
        await monitor.refresh(waitForProgress: true)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.kind, .stepCompleted)
        XCTAssertTrue(events.first?.activity.notificationBody.contains("2/3") == true)
        await monitor.refresh(waitForProgress: true)
        XCTAssertEqual(events.count, 1)
        api.snapshots = [try richSnapshot(completedSteps: 2, finished: true)]
        await monitor.refresh(waitForProgress: true)
        XCTAssertEqual(events.last?.activity.phase, .completed)
        XCTAssertTrue(events.last?.activity.notificationBody.contains("工具成功 2 · 失败 1") == true)
    }

    func testProgressFailureDoesNotHideAuthoritativeExecutionStateOrInventZeroSteps() async throws {
        let monitor = DesktopActivityMonitor(defaults: UserDefaults(suiteName: "DesktopActivityTests.\(UUID())")!)
        let api = ActivityAPI()
        api.snapshots = [try richSnapshot()]
        api.failDetails = true
        monitor.connect(id: UUID(), api: api, poll: false)
        await monitor.refresh(waitForProgress: true)
        XCTAssertTrue(monitor.isFresh)
        XCTAssertEqual(monitor.activities.first?.phase, .running)
        XCTAssertTrue(monitor.activities.first?.progressUnavailable == true)
        XCTAssertNil(monitor.activities.first?.progress)
        XCTAssertEqual(monitor.activities.first?.progressLabel, "进度暂不可用")
    }

    func testSystemNotificationUsesTaskOutcomeAgentStepsAndToolResultsInNativeFields() async throws {
        let monitor = DesktopActivityMonitor(defaults: UserDefaults(suiteName: "DesktopActivityTests.\(UUID())")!)
        monitor.setNotificationsEnabled(true)
        let center = ActivityNotificationCenter()
        let notifications = DesktopActivityNotifications(monitor: monitor, center: center)
        let activity = DesktopActivity(try richSnapshot(completedSteps: 2, finished: true))
        notifications.deliver([DesktopActivityEvent(activity: activity, sequence: 1)])
        let content = try XCTUnwrap(center.requests.first?.content)
        XCTAssertEqual(content.title, "执行完成 · 测试任务")
        XCTAssertEqual(content.subtitle, "Wand Agent · gpt-test")
        XCTAssertTrue(content.body.contains("2/3"))
        XCTAssertTrue(content.body.contains("调用 3 次"))
        XCTAssertTrue(content.body.contains("Read"))
        XCTAssertTrue(content.body.contains("成功 2 · 失败 1"))
        XCTAssertTrue(content.body.contains("02:10"))
        XCTAssertFalse(content.body.contains("PRIVATE"))
    }

    func testIdleProviderIsNotRunningOrCompleted() throws {
        let pty = try snapshot(["sessionKind": "pty", "provider": "pi", "status": "running", "ptyBusy": false])
        XCTAssertEqual(DesktopActivity(pty).phase, .idle)
        XCTAssertEqual(DesktopActivity(try snapshot(["sessionKind": "pty", "status": "running"])).phase, .idle)
        XCTAssertEqual(DesktopActivity(try snapshot(["sessionKind": "pty", "status": "running", "ptyCommandRunning": true])).phase, .running)
        XCTAssertEqual(DesktopActivity(try snapshot(["status": "exited", "exitCode": 0])).phase, .idle)
    }

    func testExecutionPermissionFailureAndCancellationPriority() throws {
        XCTAssertEqual(DesktopActivity(try snapshot(["structuredState": ["inFlight": true]])).phase, .running)
        XCTAssertEqual(DesktopActivity(try snapshot(["permissionBlocked": true, "structuredState": ["inFlight": true]])).phase, .waiting)
        XCTAssertEqual(DesktopActivity(try snapshot(["status": "failed"])).phase, .failed)
        XCTAssertEqual(DesktopActivity(try snapshot(["status": "failed", "permissionBlocked": true, "structuredState": ["inFlight": true]])).phase, .failed)
        XCTAssertEqual(DesktopActivity(try snapshot(["structuredState": ["lastError": "upstream failure"]])).phase, .failed)
        XCTAssertEqual(DesktopActivity(try snapshot(["status": "stopped", "exitCode": 130])).phase, .stopped)
        XCTAssertEqual(DesktopActivity(try snapshot(["completionRevision": 2])).phase, .completed)
        XCTAssertEqual(DesktopActivity(try snapshot(["completionRevision": 2, "structuredState": ["inFlight": true]])).phase, .running)
    }

    func testInitialHistoryAndReconnectDoNotNotify() throws {
        var ledger = DesktopActivityLedger()
        XCTAssertTrue(ledger.apply([try snapshot(["completionRevision": 8])]).isEmpty)
        XCTAssertTrue(ledger.visible.isEmpty)
        ledger.loseConnection()
        XCTAssertTrue(ledger.apply([try snapshot(["completionRevision": 9])]).isEmpty)
        XCTAssertTrue(ledger.visible.isEmpty)
    }

    func testCompletionRevisionDetectsFastTurnsAndDeduplicates() throws {
        var ledger = DesktopActivityLedger()
        _ = ledger.apply([try snapshot()])
        let completed = try snapshot(["completionRevision": 1])
        XCTAssertEqual(ledger.apply([completed]).map(\.activity.phase), [.completed])
        XCTAssertTrue(ledger.apply([completed]).isEmpty)
        XCTAssertEqual(ledger.apply([try snapshot(["completionRevision": 2])]).count, 1)
        XCTAssertEqual(ledger.recent.count, 1)
        ledger.dismissRecent()
        XCTAssertTrue(ledger.visible.isEmpty)
    }

    func testPermissionRequestIdentityAndResolution() throws {
        var ledger = DesktopActivityLedger()
        _ = ledger.apply([try snapshot()])
        func waiting(_ id: String) throws -> SessionSnapshot {
            try snapshot(["pendingEscalation": ["requestId": id, "scope": "run_command", "reason": "approval"]])
        }
        XCTAssertEqual(ledger.apply([try waiting("p1")]).map(\.activity.phase), [.waiting])
        XCTAssertTrue(ledger.apply([try waiting("p1")]).isEmpty)
        XCTAssertEqual(ledger.apply([try waiting("p2")]).count, 1)
        XCTAssertEqual(ledger.visible.count, 1)
        XCTAssertTrue(ledger.apply([try snapshot()]).isEmpty)
        XCTAssertTrue(ledger.visible.isEmpty)
    }

    func testRemovedAndArchivedRowsNeverBecomeCompleted() throws {
        var ledger = DesktopActivityLedger()
        _ = ledger.apply([try snapshot(["structuredState": ["inFlight": true]])])
        XCTAssertTrue(ledger.apply([]).isEmpty)
        XCTAssertTrue(ledger.visible.isEmpty)
        XCTAssertTrue(ledger.apply([try snapshot(["archived": true, "completionRevision": 1])]).isEmpty)
    }

    func testNewHistoricalRowsAreSuppressedButFreshFastExecutionIsNotLost() throws {
        let now = Date()
        let formatter = ISO8601DateFormatter()
        var ledger = DesktopActivityLedger()
        _ = ledger.apply([], now: now.addingTimeInterval(-5))
        XCTAssertTrue(ledger.apply([try snapshot(["completionRevision": 4, "startedAt": formatter.string(from: now.addingTimeInterval(-300))])]).isEmpty)
        let fresh = try snapshot(["id": "new", "completionRevision": 1, "startedAt": formatter.string(from: now)])
        XCTAssertEqual(ledger.apply([fresh]).count, 1)
    }

    func testRecentBoundAndActiveTasksSurviveDismissal() throws {
        var ledger = DesktopActivityLedger()
        let idle = try (0..<25).map { try snapshot(["id": "s\($0)"]) }
        _ = ledger.apply(idle)
        let completed = try (0..<25).map { try snapshot(["id": "s\($0)", "completionRevision": 1]) }
        _ = ledger.apply(completed + [try snapshot(["id": "active", "structuredState": ["inFlight": true]])])
        XCTAssertEqual(ledger.recent.count, 12)
        XCTAssertEqual(ledger.visible.count, 13)
        ledger.dismissRecent()
        XCTAssertEqual(ledger.visible.map(\.id), ["active"])
    }

    func testIslandUsesDisplayOriginAndAvoidsCameraAndMenuBar() {
        let display = CGRect(x: -1920, y: 300, width: 1920, height: 1080)
        let visible = CGRect(x: -1920, y: 350, width: 1920, height: 1000)
        let small = DesktopActivityIslandGeometry.frame(screen: display, visible: visible, safeTop: 32, expanded: false)
        let large = DesktopActivityIslandGeometry.frame(screen: display, visible: visible, safeTop: 32, expanded: true)
        XCTAssertEqual(small.midX, display.midX)
        XCTAssertEqual(small.maxY, large.maxY)
        XCTAssertLessThan(small.maxY, display.maxY - 32)
        XCTAssertTrue(visible.contains(large))
        let noNotch = DesktopActivityIslandGeometry.frame(screen: display, visible: visible, safeTop: 0, expanded: false)
        XCTAssertLessThan(noNotch.maxY, visible.maxY)
    }

    func testMonitorDisconnectAndReconnectDoNotInventCompletion() async throws {
        let defaults = UserDefaults(suiteName: "DesktopActivityTests.\(UUID())")!
        let monitor = DesktopActivityMonitor(defaults: defaults)
        let api = ActivityAPI()
        var events: [DesktopActivityEvent] = []
        monitor.onEvents = { events += $0 }
        monitor.connect(id: UUID(), api: api, poll: false)
        api.snapshots = [try snapshot(["structuredState": ["inFlight": true]])]
        await monitor.refresh()
        XCTAssertTrue(monitor.isFresh)
        XCTAssertEqual(monitor.activities.count, 1)
        api.fail = true
        await monitor.refresh()
        XCTAssertFalse(monitor.isFresh)
        XCTAssertTrue(monitor.activities.isEmpty)
        api.fail = false
        api.snapshots = [try snapshot(["completionRevision": 1])]
        await monitor.refresh()
        XCTAssertTrue(events.isEmpty)
        monitor.connect(id: UUID(), api: nil, poll: false)
        XCTAssertFalse(monitor.isFresh)
        XCTAssertTrue(monitor.activities.isEmpty)
    }

    func testLateOldServerResponseCannotOverwriteNewConnection() async throws {
        let defaults = UserDefaults(suiteName: "DesktopActivityTests.\(UUID())")!
        let monitor = DesktopActivityMonitor(defaults: defaults)
        let api = SuspendedActivityAPI()
        monitor.connect(id: UUID(), api: api, poll: false)
        let old = Task { await monitor.refresh() }
        while api.continuation == nil { await Task.yield() }
        let newer = ActivityAPI()
        newer.snapshots = [try snapshot(["id": "new-server", "structuredState": ["inFlight": true]])]
        monitor.connect(id: UUID(), api: newer, poll: false)
        await monitor.refresh()
        api.continuation?.resume(returning: [try snapshot(["id": "old-server"])])
        await old.value
        XCTAssertEqual(monitor.activities.map(\.id), ["new-server"])
    }

    func testPreferencesStayLocalAndNotificationClickUsesExactSession() async throws {
        let suite = "DesktopActivityTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let monitor = DesktopActivityMonitor(defaults: defaults)
        XCTAssertFalse(monitor.notificationsEnabled)
        XCTAssertFalse(monitor.islandEnabled)
        monitor.setNotificationsEnabled(true)
        monitor.setIslandEnabled(false)
        let restored = DesktopActivityMonitor(defaults: defaults)
        XCTAssertTrue(restored.notificationsEnabled)
        XCTAssertFalse(restored.islandEnabled)
        let api = ActivityAPI()
        api.snapshots = [try snapshot(["structuredState": ["inFlight": true]])]
        monitor.connect(id: UUID(), api: api, poll: false)
        await monitor.refresh()
        monitor.openSession("unknown")
        XCTAssertNil(monitor.pendingOpenSessionID)
        monitor.openSession("s1")
        XCTAssertEqual(monitor.pendingOpenSessionID, "s1")
        monitor.consumeOpenSession("s1")
        XCTAssertNil(monitor.pendingOpenSessionID)
    }

    func testSystemNotificationsRequireExplicitGrantAndContainNoExecutionPayload() async throws {
        let defaults = UserDefaults(suiteName: "DesktopActivityTests.\(UUID())")!
        let monitor = DesktopActivityMonitor(defaults: defaults)
        let center = ActivityNotificationCenter()
        let notifications = DesktopActivityNotifications(monitor: monitor, center: center)
        let event = DesktopActivityEvent(activity: DesktopActivity(try snapshot(["status": "failed", "command": "private command", "cwd": "/private/path"])), sequence: 1)
        notifications.deliver([event])
        XCTAssertTrue(center.requests.isEmpty)
        XCTAssertEqual(center.authorizationRequests, 0)
        notifications.setEnabled(true)
        XCTAssertEqual(center.authorizationRequests, 1)
        center.authorizationReply?(true, nil)
        await Task.yield()
        notifications.deliver([event])
        XCTAssertEqual(center.requests.count, 1)
        XCTAssertEqual(center.requests.first?.content.title, "执行失败 · 测试任务")
        XCTAssertTrue(center.requests.first?.content.subtitle.contains("Claude") == true)
        XCTAssertTrue(center.requests.first?.content.body.contains("进度") == true)
        XCTAssertFalse(center.requests.first?.content.body.contains("private") == true)
        XCTAssertTrue(center.requests.first?.content.userInfo.isEmpty == true)
        notifications.reset()
        XCTAssertEqual(center.removed.count, 1)
        notifications.setEnabled(false)
        notifications.deliver([event])
        XCTAssertEqual(center.requests.count, 1)
    }

    func testRealSystemMenuBarButtonReflectsTaskCountAndOpensNativePopover() async throws {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        try XCTSkipIf(session?["CGSSessionScreenIsLocked"] as? Bool == true,
                      "System menu-bar popovers require an unlocked graphical session")
        let monitor = DesktopActivityMonitor(defaults: UserDefaults(suiteName: "DesktopActivityTests.\(UUID())")!)
        let api = ActivityAPI()
        let center = ActivityNotificationCenter()
        let item = NSStatusBar.system.statusItem(withLength: 64)
        let surface = DesktopActivitySurface(monitor: monitor, notificationCenter: center, statusItem: item)
        defer { surface.close() }
        let width = item.length
        monitor.connect(id: UUID(), api: api, poll: false)
        api.snapshots = [try snapshot(["structuredState": ["inFlight": true]]), try snapshot(["id": "needs-approval", "permissionBlocked": true])]
        await monitor.refresh()
        for _ in 0..<200 {
            if item.button?.title.contains("等待处理") == true { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(item.button?.title.contains("Claude") == true)
        XCTAssertTrue(item.button?.title.contains("等待处理") == true)
        XCTAssertTrue(item.button?.title.contains("+1") == true)
        XCTAssertEqual(item.length, width, "State updates must not move or resize the menu-bar trigger")
        XCTAssertTrue(item.button?.toolTip?.contains("Wand · 1 待处理 · 1 执行中") == true)
        item.button?.performClick(nil)
        for _ in 0..<100 {
            if surface.isPopoverShown { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(surface.isPopoverShown)
        if let output = ProcessInfo.processInfo.environment["WAND_ACTIVITY_VISUAL_DIR"], let view = surface.popoverContentView {
            let directory = URL(fileURLWithPath: output, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("system-menu.png"))
        }
        item.button?.performClick(nil)
        for _ in 0..<100 {
            if !surface.isPopoverShown { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(surface.isPopoverShown)
        XCTAssertEqual(center.authorizationRequests, 0, "Opening the system menu must not prompt for permission")
    }

    func testPersistedNotificationRoutingIsBoundToServerNotLaunchIdentity() async throws {
        let first = DesktopActivityMonitor.sourceIdentifier(URL(string: "https://example.test")!)
        let same = DesktopActivityMonitor.sourceIdentifier(URL(string: "https://example.test:443?private=ignored")!)
        let other = DesktopActivityMonitor.sourceIdentifier(URL(string: "https://other.test")!)
        XCTAssertEqual(first, same)
        XCTAssertNotEqual(first, other)
        XCTAssertEqual(first.count, 64)
        let monitor = DesktopActivityMonitor(defaults: UserDefaults(suiteName: "DesktopActivityTests.\(UUID())")!)
        monitor.connect(id: UUID(), api: ActivityAPI(), poll: false, sourceID: first)
        monitor.openNotificationSession("exact-session", source: other)
        XCTAssertNil(monitor.pendingOpenSessionID)
        monitor.openNotificationSession("exact-session", source: first)
        XCTAssertEqual(monitor.pendingOpenSessionID, "exact-session")
        monitor.connect(id: UUID(), api: ActivityAPI(), poll: false, sourceID: other)
        monitor.openNotificationSession("exact-session", source: first)
        XCTAssertNil(monitor.pendingOpenSessionID)
    }

    func testLateAuthorizationCannotReenableAfterUserDisables() async {
        let monitor = DesktopActivityMonitor(defaults: UserDefaults(suiteName: "DesktopActivityTests.\(UUID())")!)
        let center = ActivityNotificationCenter()
        let notifications = DesktopActivityNotifications(monitor: monitor, center: center)
        notifications.setEnabled(true)
        notifications.setEnabled(false)
        center.authorizationReply?(true, nil)
        await Task.yield()
        XCTAssertFalse(monitor.notificationsEnabled)
    }

    func testNativeIslandExpansionDismissalAndScreenChanges() async throws {
        let monitor = DesktopActivityMonitor(defaults: UserDefaults(suiteName: "DesktopActivityTests.\(UUID())")!)
        let api = ActivityAPI()
        api.snapshots = [try snapshot(["structuredState": ["inFlight": true]])]
        monitor.connect(id: UUID(), api: api, poll: false)
        await monitor.refresh()
        monitor.setIslandEnabled(true)
        // Geometry/visual fixture must not consume or react to the user's real desktop clicks.
        let island = DesktopActivityIsland(monitor: monitor, observesOutsideEvents: false, animates: false)
        defer { island.close() }
        island.update()
        let window = try XCTUnwrap(NSApp.windows.first { $0.title == "Wand 任务动态" && $0.contentView != nil })
        XCTAssertTrue(window.isVisible)
        let top = window.frame.maxY
        island.toggle()
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertTrue(island.expanded)
        XCTAssertEqual(window.frame.maxY, top, accuracy: 1)
        XCTAssertEqual(window.frame.height, 242, accuracy: 1)
        if let output = ProcessInfo.processInfo.environment["WAND_ACTIVITY_VISUAL_DIR"], let view = window.contentView {
            let url = URL(fileURLWithPath: output, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url.appendingPathComponent("island-expanded.png"))
        }
        island.collapse()
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(window.frame.maxY, top, accuracy: 1)
        XCTAssertEqual(window.frame.height, 56, accuracy: 1)
        island.dismiss()
        island.update()
        XCTAssertFalse(window.isVisible)
        api.snapshots = [try snapshot(["permissionBlocked": true])]
        await monitor.refresh()
        island.update()
        XCTAssertTrue(window.isVisible, "A new state reopens a temporarily dismissed island")
        monitor.setIslandEnabled(false)
        island.update()
        XCTAssertFalse(window.isVisible)
    }

    func testIslandKeyboardDismissalIsLocalToItsPanel() async throws {
        let monitor = DesktopActivityMonitor(defaults: UserDefaults(suiteName: "DesktopActivityTests.\(UUID())")!)
        let api = ActivityAPI()
        api.snapshots = [try snapshot(["structuredState": ["inFlight": true]])]
        monitor.connect(id: UUID(), api: api, poll: false)
        await monitor.refresh()
        monitor.setIslandEnabled(true)
        let island = DesktopActivityIsland(monitor: monitor)
        defer { island.close() }
        island.update()
        island.toggle()
        let panel = try XCTUnwrap(NSApp.windows.first { $0.title == "Wand 任务动态" && $0.contentView != nil })
        XCTAssertTrue(panel.canBecomeKey)
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        defer { other.close() }
        func escape(_ window: NSWindow) throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
            NSApp.sendEvent(event)
        }
        try escape(other)
        XCTAssertTrue(island.expanded, "Another window's keyboard event must remain local to that window")
        try escape(panel)
        XCTAssertFalse(island.expanded)
    }

    /// Read-only installed-service acceptance; no permissions, notifications or model execution.
    func testInstalledServiceActivityProjection() async throws {
        guard ProcessInfo.processInfo.environment["WAND_ACTIVITY_LIVE"] == "1" else { throw XCTSkip("installed service opt-in") }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let connection = try JSONSerialization.jsonObject(with: Data(contentsOf: home.appendingPathComponent(".wand/acceptance-connection.json"))) as! [String: Any]
        var encoded = (connection["connectionCode"] as! String).filter { !$0.isWhitespace }.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        let decoded = String(data: try XCTUnwrap(Data(base64Encoded: encoded)), encoding: .utf8)!
        let split = try XCTUnwrap(decoded.lastIndex(of: "#"))
        let config = try JSONSerialization.jsonObject(with: Data(contentsOf: home.appendingPathComponent(".wand/config.json"))) as! [String: Any]
        let localHosts = ["0.0.0.0", "::", "[::]", "127.0.0.1", "localhost", "::1"]
        guard let host = config["host"] as? String, localHosts.contains(host), let port = config["port"] as? Int else {
            throw NSError(domain: "ActivityAcceptance", code: 1)
        }
        let scheme = (config["https"] as? Bool) == true ? "https" : "http"
        let origin = try XCTUnwrap(URL(string: "\(scheme)://127.0.0.1:\(port)"))
        let token = String(decoded[decoded.index(after: split)...])
        let api = WandAPI(baseURL: origin, token: token)
        let snapshots = try await api.listSessions()
        let activities = snapshots.filter { $0.archived != true }.map(DesktopActivity.init)
        XCTAssertEqual(Set(activities.map(\.id)).count, activities.count)
        var ledger = DesktopActivityLedger()
        XCTAssertTrue(ledger.apply(snapshots).isEmpty)
        XCTAssertTrue(ledger.apply(snapshots).isEmpty)
        XCTAssertTrue(ledger.visible.allSatisfy { $0.phase.isActive })
    }
}

private final class ActivityAPI: DesktopActivityServing {
    var snapshots: [SessionSnapshot] = []
    var details: [String: SessionSnapshot] = [:]
    var fail = false
    var failDetails = false
    func listSessions() async throws -> [SessionSnapshot] {
        if fail { throw URLError(.notConnectedToInternet) }
        return snapshots
    }
    func getSession(id: String, blockBudget: Int) async throws -> SessionSnapshot {
        guard !fail, !failDetails, let snapshot = details[id] ?? snapshots.first(where: { $0.id == id }) else { throw URLError(.resourceUnavailable) }
        return snapshot
    }
}

private final class SuspendedActivityAPI: DesktopActivityServing {
    var continuation: CheckedContinuation<[SessionSnapshot], Error>?
    func getSession(id: String, blockBudget: Int) async throws -> SessionSnapshot { throw URLError(.resourceUnavailable) }
    func listSessions() async throws -> [SessionSnapshot] {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
}

private final class ActivityNotificationCenter: DesktopNotificationCenter {
    weak var delegate: UNUserNotificationCenterDelegate?
    var authorizationRequests = 0
    var authorizationReply: (@Sendable (Bool, Error?) -> Void)?
    var requests: [UNNotificationRequest] = []
    var removed: [String] = []
    func requestAuthorization(options: UNAuthorizationOptions, completionHandler: @escaping @Sendable (Bool, Error?) -> Void) {
        authorizationRequests += 1
        authorizationReply = completionHandler
    }
    func getNotificationSettings(completionHandler: @escaping @Sendable (UNNotificationSettings) -> Void) {}
    func add(_ request: UNNotificationRequest, withCompletionHandler completionHandler: (@Sendable (Error?) -> Void)?) {
        requests.append(request)
        completionHandler?(nil)
    }
    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {}
    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) { removed += identifiers }
}
