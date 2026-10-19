import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import Wand

final class TaskBoardTests: XCTestCase {
    func testDesktopPageLinksKeepStableTargetsAndStripCredentials() throws {
        let base = try XCTUnwrap(URL(string: "https://user:secret@wand.test:8443/?token=private#secret"))
        let url = try XCTUnwrap(DesktopPageLink.url(base: base, parameters: [
            "view": "taskboard", "task": "stable-id", "q": "URL & 刷新", "boardView": "list",
            "filters": DesktopPageLink.json(["statuses": ["doing"], "labels": ["a,b"]]),
            "token": "secret", "ticket": "secret", "unknown": "ignored",
            "sidebarMode": "folded", "display": "grid", "zoom": "150", "hideCompleted": "1",
            "queue": "1", "expandedTask": "private-local-state", "boardCollapsed": "1", "scheduleExpanded": "1"
        ]))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertNil(components.user); XCTAssertNil(components.password); XCTAssertNil(components.fragment)
        let params = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(params["task"], "stable-id")
        XCTAssertEqual(params["q"], "URL & 刷新")
        XCTAssertEqual(params["boardView"], "list")
        XCTAssertNil(params["token"]); XCTAssertNil(params["ticket"]); XCTAssertNil(params["unknown"])
        for key in ["sidebarMode", "display", "zoom", "hideCompleted", "queue", "expandedTask", "boardCollapsed", "scheduleExpanded"] {
            XCTAssertNil(params[key], "Local preferences must not be copied into shareable Web links")
        }
        XCTAssertNil(DesktopPageLink.url(base: URL(string: "file:///tmp")!, parameters: [:]))
    }

    func testTaskScopedEmployeeOverrideAndIdentityDecode() throws {
        let json = #"{"id":"task","executionSubject":{"type":"employee","id":"e1","agentOverride":{"provider":"pi","engine":"sdk","model":"fixture"}},"assignedExecutor":{"id":"e1","name":"员工一","avatar":"cat:0"},"sessions":[{"id":"s1","employeeId":"e1","employeeName":"员工一","employeeAvatar":"cat:0","provider":"pi"}]}"#
        let task = try JSONDecoder().decode(WandBoardTask.self, from: Data(json.utf8))
        XCTAssertEqual(task.executionSubject?.agentOverride?.engine, "sdk")
        XCTAssertEqual(task.assignedExecutor?.name, "员工一")
        XCTAssertEqual(task.sessions.first?.employeeId, "e1")
        XCTAssertEqual(task.sessions.first?.employeeAvatar, "cat:0")
    }

    func testPlanningParentPolicyCoversUnstartedAndAwaitingConfirmation() throws {
        let json = #"[{"id":"todo","status":"todo"},{"id":"doing","status":"doing"},{"id":"done","status":"done"},{"id":"archived","status":"archived"},{"id":"child","parentTaskId":"todo"},{"id":"other","workspaceId":"elsewhere"}]"#
        let tasks = try JSONDecoder().decode([WandBoardTask].self, from: Data(json.utf8))
        for candidate in tasks.prefix(3) {
            XCTAssertNil(wandBoardParentRejection(candidate, tasks: tasks, workspaceId: nil, childId: nil, currentParentId: nil))
            XCTAssertTrue(candidate.sessions.isEmpty)
        }
        XCTAssertNotNil(wandBoardParentRejection(tasks[3], tasks: tasks, workspaceId: nil, childId: nil, currentParentId: nil))
        XCTAssertNotNil(wandBoardParentRejection(tasks[4], tasks: tasks, workspaceId: nil, childId: nil, currentParentId: nil))
        XCTAssertNotNil(wandBoardParentRejection(tasks[5], tasks: tasks, workspaceId: nil, childId: nil, currentParentId: nil))
        XCTAssertNotNil(wandBoardParentRejection(tasks[0], tasks: tasks, workspaceId: nil, childId: "todo", currentParentId: nil))
        XCTAssertNotNil(wandBoardParentRejection(tasks[1], tasks: tasks, workspaceId: nil, childId: "todo", currentParentId: nil))
        XCTAssertNil(wandBoardParentRejection(tasks[0], tasks: tasks, workspaceId: nil, childId: "child", currentParentId: "todo"))
    }

    func testOrganizationNoChangesIsNotReportedAsAlreadyOrganized() throws {
        let json = #"{"foundTasks":5,"eligibleTasks":3,"skippedTasks":2,"movedSessions":[],"categorizedTasks":[],"refused":[]}"#.data(using: .utf8)!
        let result = try JSONDecoder().decode(WandTaskOrganizationResult.self, from: json)
        XCTAssertEqual(result.label, "未发现可安全归类的项")
        XCTAssertEqual(result.detail, "已检查 3 个任务；已跳过 2 个用户自定标题的任务")
        let unavailable = #"{"foundTasks":3,"eligibleTasks":3,"skippedTasks":0,"movedSessions":[],"categorizedTasks":[],"refused":[{"reason":"自动判断不可用"}]}"#.data(using: .utf8)!
        let refused = try JSONDecoder().decode(WandTaskOrganizationResult.self, from: unavailable)
        XCTAssertEqual(refused.label, "未调整任何任务或会话")
        XCTAssertEqual(refused.detail, "已检查 3 个任务；自动判断不可用")
    }

    func testTaskAgentEngineSurvivesClassificationAndNativeEditing() throws {
        let agent = try JSONDecoder().decode(WandBoardTaskAgent.self, from: Data(#"{"provider":"pi","model":"default","engine":"sdk"}"#.utf8))
        XCTAssertEqual(agent.engine, "sdk")
        XCTAssertEqual(agent.jsonObject()["engine"] as? String, "sdk")
        XCTAssertEqual(agent.withProvider("pi").engine, "sdk")
        XCTAssertNil(agent.withProvider("codex").engine)
        let sessions = try JSONDecoder().decode([WandBoardTaskSession].self, from: Data(#"[{"id":"cli","provider":"pi","engine":"cli"},{"id":"sdk","provider":"pi","engine":"core"}]"#.utf8))
        let groups = wandBoardSessionGroups(sessions: sessions, assigned: agent)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(Set(groups.map(\.id)).count, 2)
        XCTAssertEqual(groups.first(where: { $0.agent?.engine == "sdk" })?.sessions.map(\.id), ["sdk"])
        XCTAssertEqual(wandBoardProviderLabel("pi", engine: "sdk"), WandProvider.title(for: "pi", engine: "core"))
        let unknown = try JSONDecoder().decode([WandBoardTaskSession].self, from: Data(#"[{"id":"legacy","provider":""}]"#.utf8))
        XCTAssertEqual(wandBoardSessionGroups(sessions: unknown, assigned: nil).first?.sessions.map(\.id), ["legacy"])
    }

    func testOrganizationTargetsAndChangesMirrorServerContract() throws {
        XCTAssertEqual(WandTaskOrganizationMode.auto.label, "默认范围会话")
        XCTAssertEqual(WandTaskOrganizationMode.all.label, "所有工作会话")
        XCTAssertEqual(WandTaskOrganizationTarget.all.jsonObject, ["kind": "all"])
        XCTAssertEqual(WandTaskOrganizationTarget.workspace("w1").jsonObject, ["kind": "workspace", "workspaceId": "w1"])
        let synthetic = TaskDirectoryGroup(workspaceId: "cwd:/tmp/a", workspaceName: "A", workspaceCwd: "/tmp/a", synthetic: true, tasks: [], standaloneSessions: [])
        XCTAssertEqual(WandTaskOrganizationTarget.directoryGroup(synthetic), .directory("/tmp/a"))
        let project = TaskDirectoryGroup(workspaceId: "w1", workspaceName: "A", workspaceCwd: "/tmp/a", synthetic: false, tasks: [], standaloneSessions: [])
        XCTAssertEqual(WandTaskOrganizationTarget.directoryGroup(project), .workspace("w1"))
        let global = TaskDirectoryGroup(workspaceId: "wand-global", workspaceName: "全局", workspaceCwd: "/tmp/global", synthetic: false, tasks: [], standaloneSessions: [], global: true)
        XCTAssertEqual(WandTaskOrganizationTarget.directoryGroup(global), .directory("/tmp/global"))
        let json = #"{"foundTasks":3,"eligibleTasks":3,"skippedTasks":0,"movedSessions":[{"sessionId":"s1"}],"categorizedTasks":[{"taskId":"t1"}],"refused":[]}"#.data(using: .utf8)!
        let result = try JSONDecoder().decode(WandTaskOrganizationResult.self, from: json)
        XCTAssertEqual(result.label, "已归类 1 个任务、归属 1 个会话")
        XCTAssertEqual(result.detail, "已检查 3 个任务")
    }

    func testBoardTaskDecoderReadsWorkspaceAgentAndSessions() throws {
        let json = """
        {
          "id": "task-1",
          "workspaceId": "ws-1",
          "identifier": "TASK-1",
          "title": "修顶栏",
          "description": "对齐 macOS",
          "status": "doing",
          "priority": "high",
          "labels": ["ui"],
          "sortOrder": 2,
          "agent": { "provider": "codex", "model": "default", "thinkingEffort": "deep" },
          "sessionIds": ["sess-1"],
          "sessions": [{
            "id": "sess-1",
            "provider": "codex",
            "sessionKind": "structured",
            "title": "修顶栏",
            "status": "running",
            "cwd": "/repo",
            "model": "gpt-5",
            "thinkingEffort": "deep"
          }],
          "workspace": { "id": "ws-1", "name": "wand", "cwd": "/repo" }
        }
        """.data(using: .utf8)!
        let task = try JSONDecoder().decode(WandBoardTask.self, from: json)
        XCTAssertEqual(task.id, "task-1")
        XCTAssertEqual(task.workspaceId, "ws-1")
        XCTAssertEqual(task.status, "doing")
        XCTAssertEqual(task.agent?.provider, "codex")
        XCTAssertEqual(task.workspace?.name, "wand")
        XCTAssertEqual(task.sessions.first?.id, "sess-1")
        XCTAssertTrue(task.sessions.first?.isStructured == true)
        // 老服务端不返回 mode / kind 时按「provider 支持的默认值 + 结构化」兜底，
        // 不能让整条任务解码失败；Codex 只支持全限，所以这里落到 full-access。
        XCTAssertEqual(task.agent?.mode, WandBoardAgentMode.fullAccess.rawValue)
        XCTAssertEqual(task.agent?.kind, WandBoardAgentKind.structured.rawValue)
    }

    func testOrganizationRelationshipsUseBoardIDsAndKeepParentsAcrossFilters() throws {
        let json = #"[{"id":"card-parent","workspaceTaskId":"container-parent","identifier":"TASK-1","title":"主任务"},{"id":"card-child","workspaceTaskId":"container-child","parentTaskId":"card-parent","title":"子任务"},{"id":"wrong-id-kind","parentTaskId":"container-parent"},{"id":"self","parentTaskId":"self"},{"id":"orphan","parentTaskId":"not-loaded"}]"#.data(using: .utf8)!
        let tasks = try JSONDecoder().decode([WandBoardTask].self, from: json)
        let visibleChild = tasks[1]
        XCTAssertEqual(visibleChild.parentTaskId, "card-parent")
        XCTAssertEqual(wandBoardParent(of: visibleChild, in: tasks)?.id, "card-parent")
        XCTAssertNil(wandBoardParent(of: visibleChild, in: [visibleChild]), "筛选后的列表不能替代关系投影的完整列表")
        XCTAssertEqual(wandBoardChildren(of: tasks[0], in: tasks).map(\.id), ["card-child"])
        XCTAssertNil(wandBoardParent(of: tasks[2], in: tasks), "workspaceTaskId不是父卡片ID")
        XCTAssertNil(wandBoardParent(of: tasks[3], in: tasks), "坏数据中的自引用不呈现为父任务")
        XCTAssertTrue(wandBoardChildren(of: tasks[3], in: tasks).isEmpty)
        XCTAssertNil(wandBoardParent(of: tasks[4], in: tasks), "缺失父任务保持可读，不虚构名称")
    }

    func testBoardTaskDecoderToleratesMissingAndLegacyParentIDs() throws {
        for parent in ["", NSNull(), 42] as [Any] {
            let json = try JSONSerialization.data(withJSONObject: ["id": "legacy", "parentTaskId": parent])
            let task = try JSONDecoder().decode(WandBoardTask.self, from: json)
            XCTAssertNil(task.parentTaskId)
        }
    }

    @MainActor
    func testOrganizationUnknownReceiptSurvivesResetAndOnlyQueriesOriginalToken() async throws {
        let hostName = "\(UUID().uuidString.lowercased()).organization-recovery.test"
        let lock = NSLock()
        var previews = 0, starts = 0, tokenReads = 0
        var ready = false
        CommunicationsContractURLProtocol.register(host: hostName) { request in
            lock.lock(); defer { lock.unlock() }
            if request.url?.path == "/api/sessions/auto-organize/by-token/original-token" {
                tokenReads += 1
                guard ready else { throw URLError(.cannotConnectToHost) }
                return Data(#"{"job":{"id":"original-job","status":"completed","stage":"完成","processedSessions":2,"totalSessions":2,"modelRequests":1,"result":{"eligibleSessions":2,"analyzedSessions":2,"skippedManualSessions":0,"skippedSessions":0,"createdTasks":[{"taskId":"new"}],"reusedTasks":[],"updatedTasks":[],"movedSessions":[{"sessionId":"one"},{"sessionId":"two"}],"unassignedSessions":[],"refused":[]}}}"#.utf8)
            }
            guard previews == 0 else {
                starts += 1
                throw URLError(.networkConnectionLost)
            }
            previews += 1
            return Data(#"{"preview":{"token":"original-token","sessionCount":2,"manualSessionCount":0,"skippedSessionCount":0,"existingTaskCount":0,"contentCharacters":1888,"estimatedModelRequests":1,"unchanged":false}}"#.utf8)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CommunicationsContractURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); CommunicationsContractURLProtocol.unregister(host: hostName) }
        let api = WandAPI(baseURL: URL(string: "https://\(hostName)")!, token: nil, session: session)
        let action = WandTaskOrganizationAction()
        var refreshes = 0
        await action.run(api: api, target: .all, mode: .auto, onChanged: {})
        action.confirm(api: api) { refreshes += 1 }
        await action.waitForBackgroundWorkForTesting()
        XCTAssertTrue(action.unresolved)
        XCTAssertEqual(action.submittedToken, "original-token")
        XCTAssertNotNil(action.error)
        action.reset()
        await action.run(api: api, target: .workspace("another-directory"), mode: .all, onChanged: {})
        XCTAssertEqual(lock.withLock { previews }, 1)
        XCTAssertEqual(lock.withLock { starts }, 1)
        XCTAssertEqual(lock.withLock { tokenReads }, 1)
        lock.withLock { ready = true }
        action.query(api: api) { refreshes += 1 }
        await action.waitForBackgroundWorkForTesting()
        XCTAssertFalse(action.unresolved)
        XCTAssertNil(action.submittedToken)
        XCTAssertEqual(action.result?.movedSessions.count, 2)
        XCTAssertEqual(lock.withLock { starts }, 1)
        XCTAssertEqual(lock.withLock { tokenReads }, 2)
        XCTAssertEqual(refreshes, 1)
    }

    @MainActor
    func testOrganizationNativeRelationshipAndResultScreenshots() async throws {
        guard ProcessInfo.processInfo.environment["WAND_TASK_ORGANIZE_NATIVE_VISUAL"] == "1" else {
            throw XCTSkip("opt-in isolated native task-organization views; never calls a model")
        }
        let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["WAND_TASK_ORGANIZE_NATIVE_OUTPUT"] ?? NSTemporaryDirectory() + "wand-task-organization-visual")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let data = #"[{"id":"parent","identifier":"TASK-1","title":"修复客户端交互","status":"doing","description":"保留所有原任务和会话的历史"},{"id":"child","parentTaskId":"parent","identifier":"TASK-2","title":"修复登录弹窗","status":"doing","description":"验证归类后的父任务信息可见"}]"#.data(using: .utf8)!
        let tasks = try JSONDecoder().decode([WandBoardTask].self, from: data)
        let hostName = "\(UUID().uuidString.lowercased()).organization.test"
        CommunicationsContractURLProtocol.register(host: hostName) { request in
            var data = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var bytes = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&bytes, maxLength: bytes.count)
                    if count <= 0 { break }; data.append(bytes, count: count)
                }
            }
            let body = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            if body?["action"] as? String == "preview" {
                return Data(#"{"preview":{"token":"visual-confirm","sessionCount":2,"manualSessionCount":1,"skippedSessionCount":0,"existingTaskCount":0,"contentCharacters":1888,"estimatedModelRequests":1,"unchanged":false}}"#.utf8)
            }
            return Data(#"{"job":{"id":"visual-job","status":"completed","stage":"完成","processedSessions":2,"totalSessions":2,"modelRequests":1,"result":{"eligibleSessions":2,"analyzedSessions":2,"skippedManualSessions":1,"skippedSessions":0,"createdTasks":[{"taskId":"new"}],"reusedTasks":[],"updatedTasks":[],"movedSessions":[{"sessionId":"one"},{"sessionId":"two"}],"unassignedSessions":[],"refused":[]}}}"#.utf8)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CommunicationsContractURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); CommunicationsContractURLProtocol.unregister(host: hostName) }
        let api = WandAPI(baseURL: URL(string: "https://\(hostName)")!, token: nil, session: session)
        for dark in [false, true] {
            let suffix = dark ? "dark" : "light"
            for task in tasks {
                let detail = WandBoardDetailView(task: task, allTasks: tasks, onOpenTask: { _ in }, workspaces: [], milestones: [], catalog: nil, busy: false,
                    onPatch: { _ in }, onRemember: { _ in }, onDispatch: { _, _ in }, onArchive: {}, onOpenSession: { _ in },
                    onCreateMilestone: { _ in throw URLError(.unsupportedURL) })
                try await organizationSnapshot(detail, size: NSSize(width: 1200, height: 850), dark: dark,
                    path: output.appendingPathComponent("\(task.id)-detail-\(suffix).png"))
            }
            let action = WandTaskOrganizationAction()
            await action.run(api: api, target: .all, mode: .auto) {
                do {
                    try await organizationSnapshot(WandTaskOrganizationPanel(api: api, target: .all, action: action, onChanged: {}),
                        size: NSSize(width: 320, height: 300), dark: dark, path: output.appendingPathComponent("progress-\(suffix).png"))
                } catch { XCTFail("Native progress snapshot failed: \(error)") }
            }
            XCTAssertNotNil(action.preview)
            XCTAssertNil(action.result)
            try await organizationSnapshot(WandTaskOrganizationPanel(api: api, target: .all, action: action, onChanged: {}),
                size: NSSize(width: 320, height: 560), dark: dark, path: output.appendingPathComponent("preview-\(suffix).png"))
            action.confirm(api: api, onChanged: {})
            await action.waitForBackgroundWorkForTesting()
            XCTAssertEqual(action.result?.label, "已新建 1 个任务、归入 2 个会话")
            try await organizationSnapshot(WandTaskOrganizationPanel(api: api, target: .all, action: action, onChanged: {}),
                size: NSSize(width: 320, height: 330), dark: dark, path: output.appendingPathComponent("result-\(suffix).png"))
            let summary = VStack(alignment: .leading, spacing: 16) {
                WandBoardRelationshipSummary(parent: tasks[0], childCount: 0)
                WandBoardRelationshipSummary(parent: nil, childCount: 1)
            }.padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            try await organizationSnapshot(summary, size: NSSize(width: 320, height: 100), dark: dark,
                path: output.appendingPathComponent("relationship-summary-\(suffix).png"))
        }
    }

    @MainActor
    func testTaskDetailLongContentVisuals() async throws {
        guard let directory = ProcessInfo.processInfo.environment["WAND_TASK_DETAIL_VISUAL_OUTPUT"] else {
            throw XCTSkip("Set WAND_TASK_DETAIL_VISUAL_OUTPUT for native offscreen detail snapshots")
        }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let brief = "任务背景\n\n" + String(repeating: "完整描述应在主阅读区自然换行，而不是隐藏在限高编辑框里。\n", count: 12) + "描述末尾验收标记"
        let data = try JSONSerialization.data(withJSONObject: ["id": "detail-visual", "identifier": "TASK-VISUAL", "title": "评估 CLI / skill 获取一次性 Web 登录票据（暂不实施）", "description": brief])
        let task = try JSONDecoder().decode(WandBoardTask.self, from: data)
        for width in [640, 1200] {
            for dark in [false, true] {
                let detail = WandBoardDetailView(task: task, loadComments: { _ in [] }, workspaces: [], milestones: [], catalog: nil, busy: false,
                    onPatch: { _ in XCTFail("Read-only visual must not patch") }, onRemember: { _ in }, onDispatch: { _, _ in XCTFail("Read-only visual must not dispatch") }, onArchive: { XCTFail("Read-only visual must not archive") }, onOpenSession: { _ in }, onCreateMilestone: { _ in throw URLError(.unsupportedURL) })
                try await organizationSnapshot(detail, size: NSSize(width: width, height: 1050), dark: dark,
                    path: output.appendingPathComponent("detail-\(width)-\(dark ? "dark" : "light").png"))
            }
        }
    }

    @MainActor
    private func organizationSnapshot<Content: View>(_ content: Content, size: NSSize, dark: Bool, path: URL) async throws {
        let host = NSHostingView(rootView: content.preferredColorScheme(dark ? .dark : .light))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 250_000_000)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 1000)
        try png.write(to: path)
    }

    func testBoardTaskDecoderAllowsUnassignedProjectAndAgent() throws {
        let json = #"{"id":"task-2","title":"草稿"}"#.data(using: .utf8)!
        let task = try JSONDecoder().decode(WandBoardTask.self, from: json)
        XCTAssertNil(task.workspaceId)
        XCTAssertNil(task.parentTaskId)
        XCTAssertNil(task.agent)
        XCTAssertEqual(task.status, "todo")
        XCTAssertEqual(task.priority, "none")
        XCTAssertTrue(task.sessions.isEmpty)
        // 老服务端不返回 titleSource，按用户手写处理。
        XCTAssertEqual(task.titleSource, "user")
        XCTAssertNil(task.milestone)
        XCTAssertNil(task.dueDate)
    }

    func testBoardTaskDecoderKeepsUsableSessionsWhenOneIsMalformed() throws {
        // 真实服务端 payload 里会话可能缺 provider、甚至整个元素缺 id，
        // 坏元素只丢自己，不带踢同任务其它会话。
        let json = """
        {
          "id": "task-5",
          "status": "doing",
          "sessionIds": ["sess-1", "", "sess-3"],
          "sessions": [
            { "id": "sess-1", "provider": "", "sessionKind": "pty", "status": "running" },
            { "provider": "codex", "status": "running" },
            { "id": "sess-3", "provider": "pi", "sessionKind": "structured", "status": "running" }
          ]
        }
        """.data(using: .utf8)!
        let task = try JSONDecoder().decode(WandBoardTask.self, from: json)
        XCTAssertEqual(task.sessions.map(\.id), ["sess-1", "sess-3"])
        XCTAssertEqual(task.sessions.first?.provider, "")
        XCTAssertFalse(task.sessions[0].isStructured)
        XCTAssertTrue(task.sessions[1].isStructured)
    }

    func testBoardTaskDecoderReadsAutoGeneratedTitleSource() throws {
        let json = #"{"id":"task-3","title":"根据描述生成的标题","titleSource":"auto"}"#.data(using: .utf8)!
        let task = try JSONDecoder().decode(WandBoardTask.self, from: json)
        XCTAssertEqual(task.titleSource, "auto")
    }

    func testBoardTaskDecoderReadsMilestoneAndDueDate() throws {
        let json = """
        {
          "id": "task-4",
          "title": "带迭代的任务",
          "dueDate": "2026-09-30",
          "milestoneId": "ms-1",
          "milestone": { "id": "ms-1", "name": "v5.0 发布", "isDefault": false }
        }
        """.data(using: .utf8)!
        let task = try JSONDecoder().decode(WandBoardTask.self, from: json)
        XCTAssertEqual(task.dueDate, "2026-09-30")
        XCTAssertEqual(task.milestoneId, "ms-1")
        XCTAssertEqual(task.milestone?.name, "v5.0 发布")
        XCTAssertEqual(task.milestone?.isDefault, false)
    }

    func testBoardLabelsCoverColumns() {
        XCTAssertEqual(WandBoardStatus.columns.map(\.rawValue), ["todo", "doing", "done"])
        XCTAssertEqual(WandBoardStatus.todo.label, "等待认领")
        XCTAssertEqual(WandBoardStatus.doing.label, "处理中")
        XCTAssertEqual(WandBoardStatus.done.label, "等你确认")
        XCTAssertEqual(WandBoardStatus.archived.label, "归档任务")
        XCTAssertFalse(WandBoardStatus.todo.isClosed)
        XCTAssertTrue(WandBoardStatus.done.isClosed)
        XCTAssertTrue(WandBoardStatus.archived.isClosed)
        XCTAssertEqual(WandBoardPriority.urgent.label, "紧急")
        XCTAssertEqual(wandBoardProviderLabel("pi"), "Pi")
        XCTAssertEqual(wandBoardEffortLabel("deep"), "深入")
        XCTAssertEqual(wandBoardEffortLabel("off"), "关闭")
        // 未知值原样透出，别把服务端新加的档位显示成「关闭」。
        XCTAssertEqual(wandBoardEffortLabel("turbo"), "turbo")
        XCTAssertEqual(wandBoardProviderLabel("unknown"), "unknown")
        XCTAssertEqual(wandBoardSessionStatusLabel("running"), "进行中")
    }

    func testBoardViewLabelsMatchWeb() {
        XCTAssertEqual(WandBoardView.allCases.map(\.label), ["概览", "看板", "列表", "甘特图"])
        XCTAssertEqual(WandBoardGanttZoom.day.days, 14)
        XCTAssertEqual(WandBoardGanttZoom.week.days, 42)
        XCTAssertEqual(WandBoardGanttZoom.month.days, 90)
    }

    // MARK: 派发 Agent

    func testAgentModeIsClampedToWhatProviderSupports() {
        // Codex 只有「全限」一个有效值，其余 provider 三种都能用。
        XCTAssertEqual(WandBoardAgentMode.supported(provider: "codex"), [.fullAccess])
        XCTAssertEqual(WandBoardAgentMode.supported(provider: "claude").count, 3)
        XCTAssertEqual(WandBoardAgentMode.normalize(provider: "codex", value: "default"), "full-access")
        XCTAssertEqual(WandBoardAgentMode.normalize(provider: "claude", value: nil), "default")
        XCTAssertEqual(WandBoardAgentMode.normalize(provider: "claude", value: "乱值"), "default")
        XCTAssertEqual(WandBoardAgentMode.label(forValue: "managed"), "托管")
        XCTAssertEqual(WandBoardAgentMode.label(forValue: ""), "标准")
    }

    func testAgentWithProviderKeepsModelButFixesMode() {
        let agent = WandBoardTaskAgent(
            provider: "claude",
            model: "opus",
            thinkingEffort: "deep",
            mode: WandBoardAgentMode.managed.rawValue
        )
        let codex = agent.withProvider("codex")
        XCTAssertEqual(codex.provider, "codex")
        XCTAssertEqual(codex.model, "opus")
        XCTAssertEqual(codex.mode, "full-access")
        XCTAssertEqual(codex.thinkingEffort, "deep")
        XCTAssertEqual(codex.jsonObject()["kind"] as? String, "structured")
    }

    func testModelOptionsAlwaysIncludeDefault() {
        XCTAssertEqual(
            wandBoardModelOptions(from: nil, provider: "claude").first?.id,
            "default"
        )
        XCTAssertFalse(wandBoardModelOptions(from: nil, provider: "pi").isEmpty)
    }

    func testSessionsGroupByTheAgentsThatRan() {
        let json = """
        {
          "id": "task-9",
          "title": "多 Agent",
          "agent": { "provider": "claude", "model": "opus", "thinkingEffort": "deep" },
          "sessions": [
            { "id": "s1", "provider": "claude", "title": "修登录", "status": "running", "model": "opus", "thinkingEffort": "deep" },
            { "id": "s2", "provider": "claude", "title": "补测试", "status": "exited", "model": "sonnet", "thinkingEffort": "off" },
            { "id": "s3", "provider": "codex", "title": "实现 API", "status": "idle", "model": "gpt-5", "thinkingEffort": "standard" }
          ]
        }
        """.data(using: .utf8)!
        let task = try! JSONDecoder().decode(WandBoardTask.self, from: json)
        let groups = wandBoardSessionGroups(sessions: task.sessions, assigned: task.agent)
        XCTAssertEqual(groups.map(\.provider), ["claude", "codex"])
        XCTAssertEqual(groups[0].sessions.map(\.id), ["s1", "s2"])
        XCTAssertEqual(groups[1].sessions.map(\.id), ["s3"])
        let pending = wandBoardSessionGroups(
            sessions: [],
            assigned: WandBoardTaskAgent(provider: "pi", model: "default", thinkingEffort: "off")
        )
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.provider, "pi")
        XCTAssertTrue(pending.first?.sessions.isEmpty == true)
        // 卡片上的 Agent 胶囊：跑过或已指派的工具各一个。
        XCTAssertEqual(wandBoardListAgents(sessions: task.sessions, assigned: task.agent).map(\.provider), ["claude", "codex"])
    }

    // MARK: 拖拽与派发时机

    func testDropDispatchOnlyForTheFirstTripToDoing() {
        XCTAssertFalse(wandBoardCreateDispatches(status: "doing"))
        XCTAssertFalse(wandBoardCreateDispatches(status: "todo"))
        XCTAssertFalse(wandBoardDropDispatches(status: "doing", sessionCount: 0))
        // 已经跑过的卡再拖回来只改状态，避免拖一次就多开一个 session。
        XCTAssertFalse(wandBoardDropDispatches(status: "doing", sessionCount: 1))
        XCTAssertFalse(wandBoardDropDispatches(status: "done", sessionCount: 0))
    }

    func testDropDispatchPromptPrefersDescriptionThenTitle() {
        XCTAssertEqual(
            wandBoardDropDispatchPrompt(title: "标题", description: "  描述  "),
            "描述"
        )
        XCTAssertEqual(wandBoardDropDispatchPrompt(title: "标题", description: " "), "标题")
        XCTAssertEqual(wandBoardDropDispatchPrompt(title: " ", description: ""), "执行此任务")
    }

    // MARK: 筛选、搜索与分组

    func testFiltersAndSearchMatchWebSemantics() throws {
        let json = """
        [
          {"id":"a","title":"修登录","description":"OAuth","status":"todo","priority":"high",
           "labels":["缺陷"],"workspaceId":"ws-1","dueDate":"2026-09-01"},
          {"id":"b","title":"补测试","status":"doing","priority":"low","labels":["测试"],"workspaceId":"ws-2"},
          {"id":"c","title":"写文档","status":"archived","priority":"none"}
        ]
        """.data(using: .utf8)!
        let tasks = try JSONDecoder().decode([WandBoardTask].self, from: json)
        let all = WandBoardFilters.empty

        XCTAssertTrue(wandBoardMatches(task: tasks[0], query: "", workspaceId: "", filters: all))
        XCTAssertTrue(wandBoardMatches(task: tasks[0], query: "oauth", workspaceId: "", filters: all))
        XCTAssertFalse(wandBoardMatches(task: tasks[2], query: "缺陷", workspaceId: "", filters: all))
        XCTAssertTrue(wandBoardMatches(task: tasks[0], query: "缺陷", workspaceId: "", filters: all))
        XCTAssertFalse(wandBoardMatches(task: tasks[1], query: "", workspaceId: "ws-1", filters: all))

        var statuses = all
        statuses.statuses = ["archived"]
        XCTAssertTrue(wandBoardMatches(task: tasks[2], query: "", workspaceId: "", filters: statuses))
        XCTAssertFalse(wandBoardMatches(task: tasks[1], query: "", workspaceId: "", filters: statuses))

        var priorities = all
        priorities.priorities = ["high"]
        XCTAssertTrue(wandBoardMatches(task: tasks[0], query: "", workspaceId: "", filters: priorities))
        XCTAssertFalse(wandBoardMatches(task: tasks[1], query: "", workspaceId: "", filters: priorities))

        var labels = all
        labels.labels = ["测试"]
        XCTAssertTrue(wandBoardMatches(task: tasks[1], query: "", workspaceId: "", filters: labels))
        XCTAssertFalse(wandBoardMatches(task: tasks[0], query: "", workspaceId: "", filters: labels))
        XCTAssertEqual(labels.count, 1)
        XCTAssertTrue(labels.isActive)

        let grouped = wandBoardGroup(tasks: tasks)
        XCTAssertEqual(grouped["todo"]?.count, 1)
        XCTAssertEqual(grouped["doing"]?.count, 1)
        XCTAssertEqual(grouped["archived"]?.count, 1)
        XCTAssertEqual(grouped["done"]?.count, 0)
        XCTAssertEqual(Set(wandBoardCollectLabels(tasks: tasks)), ["测试", "缺陷"])
    }

    func testSearchScopeMatchesWebAndExcludesProjectName() throws {
        let json = """
        [
          {"id":"a","title":"修登录","identifier":"TASK-1","description":"OAuth","labels":["缺陷"],
           "workspaceId":"ws-1","workspace":{"id":"ws-1","name":"wand","cwd":"/repo"}}
        ]
        """.data(using: .utf8)!
        let task = try JSONDecoder().decode([WandBoardTask].self, from: json)[0]
        // 标题 / 编号 / 描述 / 标签命中（与 Web filterIssues 一致）。
        XCTAssertTrue(wandBoardMatches(task: task, query: "修登录", workspaceId: "", filters: .empty))
        XCTAssertTrue(wandBoardMatches(task: task, query: "task-1", workspaceId: "", filters: .empty))
        XCTAssertTrue(wandBoardMatches(task: task, query: "oauth", workspaceId: "", filters: .empty))
        XCTAssertTrue(wandBoardMatches(task: task, query: "缺陷", workspaceId: "", filters: .empty))
        // 项目名不在搜索范围内。
        XCTAssertEqual(task.workspace?.name, "wand")
        XCTAssertFalse(wandBoardMatches(task: task, query: "wand", workspaceId: "", filters: .empty))
    }

    func testNewTaskDefaultsToLowPriorityLikeWeb() {
        // Web `DEFAULT_WAND_TASK_PRIORITY`：没挑优先级时默认「低」。
        XCTAssertEqual(WandBoardDraft().priority, WandBoardPriority.low.rawValue)
    }

    func testCreateMoreKeepsOnlyProjectStatusAndAgent() {
        var draft = WandBoardDraft()
        draft.workspaceId = "ws-9"
        draft.status = WandBoardStatus.doing.rawValue
        draft.priority = WandBoardPriority.urgent.rawValue
        draft.milestoneId = "ms-1"
        draft.dueDate = "2026-09-30"
        draft.labels = "缺陷, 界面"
        draft.agent = WandBoardTaskAgent(provider: "pi", model: "default", thinkingEffort: "max", mode: "managed", kind: "structured")

        let next = wandBoardDraftAfterCreateMore(draft)
        XCTAssertEqual(next.workspaceId, "ws-9")
        XCTAssertEqual(next.status, WandBoardStatus.doing.rawValue)
        XCTAssertEqual(next.agent.provider, "pi")
        XCTAssertEqual(next.priority, WandBoardPriority.low.rawValue)
        XCTAssertEqual(next.milestoneId, "")
        XCTAssertEqual(next.dueDate, "")
        XCTAssertEqual(next.labels, "")
        XCTAssertTrue(next.isEmpty)
    }

    func testLabelTonesFollowWebConvention() {
        XCTAssertEqual(wandBoardLabelTone("缺陷"), .bug)
        XCTAssertEqual(wandBoardLabelTone("Bug"), .bug)
        XCTAssertEqual(wandBoardLabelTone("特性"), .feature)
        XCTAssertEqual(wandBoardLabelTone("测试"), .neutral)
        XCTAssertEqual(wandBoardLabelTone("特性"), .feature)
        XCTAssertEqual(wandBoardLabelName("缺陷"), "BUG")
        XCTAssertEqual(wandBoardLabelName("bug"), "BUG")
        XCTAssertEqual(wandBoardLabelName("特性"), "新功能")
        XCTAssertEqual(wandBoardLabelName("测试"), "测试")
    }

    // MARK: 日期与统计

    func testOverdueOnlyCountsOpenTasks() throws {
        let json = """
        [
          {"id":"a","title":"逾期","status":"todo","dueDate":"2020-01-01"},
          {"id":"b","title":"已确认","status":"done","dueDate":"2020-01-01"},
          {"id":"c","title":"已归档","status":"archived","dueDate":"2020-01-01"},
          {"id":"d","title":"没日期","status":"doing","priority":"urgent"}
        ]
        """.data(using: .utf8)!
        let tasks = try JSONDecoder().decode([WandBoardTask].self, from: json)
        XCTAssertTrue(wandBoardIsOverdue(tasks[0].dueDate, status: tasks[0].status))
        XCTAssertFalse(wandBoardIsOverdue(tasks[1].dueDate, status: tasks[1].status))
        XCTAssertFalse(wandBoardIsOverdue(tasks[2].dueDate, status: tasks[2].status))
        XCTAssertFalse(wandBoardIsOverdue(nil, status: "todo"))
        XCTAssertEqual(wandBoardDueStamp("2026-09-30"), "9/30")
        XCTAssertEqual(wandBoardDueStamp(nil), "")

        let stats = wandBoardStats(tasks: tasks)
        XCTAssertEqual(stats.total, 4)
        XCTAssertEqual(stats.todo, 1)
        XCTAssertEqual(stats.doing, 1)
        XCTAssertEqual(stats.done, 1)
        XCTAssertEqual(stats.remaining, 2)
        XCTAssertEqual(stats.overdue, 1)
        XCTAssertEqual(stats.high, 1)
    }

    func testGanttSpanStaysInsideTheRange() throws {
        let json = """
        [
          {"id":"a","title":"有截止","status":"doing","createdAt":"2026-09-20T10:00:00Z","dueDate":"2026-09-24"},
          {"id":"b","title":"没有截止","status":"todo","createdAt":"2026-09-21T10:00:00Z"},
          {"id":"c","title":"很久以前","status":"doing","createdAt":"2020-01-01T10:00:00Z"}
        ]
        """.data(using: .utf8)!
        let tasks = try JSONDecoder().decode([WandBoardTask].self, from: json)
        for zoom in WandBoardGanttZoom.allCases {
            let range = wandBoardGanttRange(zoom: zoom)
            XCTAssertEqual(range.days, zoom.days)
            XCTAssertEqual(range.columns.count, zoom.days)
            for task in tasks {
                let span = wandBoardGanttSpan(task: task, range: range)
                XCTAssertGreaterThanOrEqual(span.offset, 0)
                XCTAssertGreaterThanOrEqual(span.length, 1)
                XCTAssertLessThanOrEqual(span.offset + span.length, range.days)
            }
        }
    }

    func testProgressSeriesIsMonotonic() throws {
        let json = """
        [
          {"id":"a","title":"旧","status":"done","createdAt":"2026-08-01T00:00:00Z","updatedAt":"2026-08-10T00:00:00Z"},
          {"id":"b","title":"新","status":"todo","createdAt":"2026-09-01T00:00:00Z"}
        ]
        """.data(using: .utf8)!
        let tasks = try JSONDecoder().decode([WandBoardTask].self, from: json)
        let series = wandBoardProgressSeries(tasks: tasks)
        XCTAssertEqual(series.count, 13)
        for index in 1..<series.count {
            XCTAssertGreaterThanOrEqual(series[index].scope, series[index - 1].scope)
            XCTAssertGreaterThanOrEqual(series[index].started, series[index - 1].started)
            XCTAssertGreaterThanOrEqual(series[index].completed, series[index - 1].completed)
        }
        XCTAssertEqual(series.last?.scope, 2)
        XCTAssertEqual(series.last?.completed, 1)
    }

    func testMilestoneVisibilityFollowsWorkspaceScope() {
        let global = makeMilestone(["id": "ms-1", "name": "全局迭代"])
        let scoped = makeMilestone(["id": "ms-2", "name": "本项目迭代", "workspaceId": "ws-1"])
        let other = makeMilestone(["id": "ms-3", "name": "别的项目", "workspaceId": "ws-2"])
        XCTAssertTrue(global.isVisible(for: nil))
        XCTAssertTrue(global.isVisible(for: "ws-1"))
        XCTAssertTrue(scoped.isVisible(for: "ws-1"))
        XCTAssertFalse(scoped.isVisible(for: "ws-2"))
        XCTAssertFalse(other.isVisible(for: "ws-1"))
        // 不选工作区时全部可见。
        XCTAssertTrue(other.isVisible(for: ""))
    }

    // MARK: 视图状态持久化

    func testViewStateAndDisplayRoundTrip() {
        let suite = "WandBoardTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        var state = WandBoardViewState.default
        state.view = .gantt
        state.query = "登录"
        state.workspaceId = "ws-1"
        state.filters.statuses = ["doing"]
        state.filters.labels = ["缺陷"]
        wandBoardWriteViewState(state, defaults: defaults)
        let restored = wandBoardReadViewState(defaults: defaults)
        XCTAssertEqual(restored.view, .gantt)
        XCTAssertEqual(restored.query, "登录")
        XCTAssertEqual(restored.workspaceId, "ws-1")
        XCTAssertEqual(restored.filters.statuses, ["doing"])
        XCTAssertEqual(restored.filters.labels, ["缺陷"])

        var display = WandBoardDisplay.default
        display.body = true
        display.mainStatuses = ["todo", "doing"]
        wandBoardWriteDisplay(display, defaults: defaults)
        let restoredDisplay = wandBoardReadDisplay(defaults: defaults)
        XCTAssertTrue(restoredDisplay.body)
        XCTAssertEqual(restoredDisplay.mainStatuses, ["todo", "doing"])

        // 主列全被清空是脏数据：读回来时必须回落到默认三列，看板不能变空。
        defaults.set(
            try? JSONSerialization.data(withJSONObject: ["body": false, "mainStatuses": []]),
            forKey: "wand.desktop.taskBoard.display"
        )
        XCTAssertEqual(wandBoardReadDisplay(defaults: defaults).mainStatuses, Set(WandBoardStatus.columns.map(\.rawValue)))
    }
}

/// 测试里的便捷构造：走真正的解码路径，避免手写 init 绕过容错逻辑。
private func makeMilestone(_ json: [String: Any]) -> WandBoardMilestone {
    let data = try! JSONSerialization.data(withJSONObject: json)
    return try! JSONDecoder().decode(WandBoardMilestone.self, from: data)
}


extension TaskBoardTests {
    func testGoalProjectionKeepsParentForChildSearchAndPlanningDoesNotExecute() throws {
        let source = #"[{"id":"root","title":"目标","status":"todo"},{"id":"one","title":"交付一","parentTaskId":"root"},{"id":"two","title":"交付二","parentTaskId":"root"},{"id":"three","title":"交付三","parentTaskId":"root"}]"#
        let tasks = try JSONDecoder().decode([WandBoardTask].self, from: Data(source.utf8))
        XCTAssertEqual(wandBoardGoalProjection(all: tasks, matched: tasks).map(\.id), ["root"])
        XCTAssertEqual(wandBoardGoalProjection(all: tasks, matched: [tasks[2]]).map(\.id), ["root"])
        XCTAssertEqual(wandBoardChildren(of: tasks[0], in: tasks).count, 3)
        XCTAssertFalse(WandBoardDraft().saveAndDispatch)
        XCTAssertEqual(tasks[0].status, "todo")
    }

    func testMentionQueryFollowsTheCaretAndOnlyTheChosenTokenStaysBound() {
        XCTAssertEqual(TaskCommentMention.query(in: "literal @name", caret: "literal @name".count)?.text, "name")
        XCTAssertNil(TaskCommentMention.query(in: "mail@host", caret: 9))
        XCTAssertEqual(TaskCommentMention.query(in: "@瑞辰 已写完", caret: 2)?.text, "瑞")
        XCTAssertNil(TaskCommentMention.query(in: "@瑞辰 已写完", caret: 4))
        XCTAssertNil(TaskCommentMention.query(in: "@开头", caret: 0))
        let inserted = TaskCommentMention.insert(body: "请 @虎", caret: 5, name: "赛博虎妞")
        XCTAssertEqual(inserted.body, "请 @赛博虎妞 ")
        XCTAssertTrue(TaskCommentMention.holds(inserted.body, name: "赛博虎妞"))
        XCTAssertFalse(TaskCommentMention.holds("@赛博", name: "赛博虎妞"))
        XCTAssertFalse(TaskCommentMention.holds("@瑞辰同学", name: "瑞辰"))
        XCTAssertEqual(TaskCommentMention.caretOffset(from: "请", to: "请@"), 2)
    }
}
