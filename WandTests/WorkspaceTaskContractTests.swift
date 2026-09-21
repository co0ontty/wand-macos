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
        let api = makeAPI { request in
            let body = try Self.requestBody(request)
            XCTAssertEqual(body["cwd"] as? String, "/repo")
            XCTAssertNil(body["workspaceId"])
            XCTAssertNil(body["workspaceTaskId"])
            XCTAssertNil(body["model"])
            XCTAssertNil(body["mode"])
            XCTAssertNil(body["thinkingEffort"])
            return Data(#"{"id":"new-session"}"#.utf8)
        }
        _ = try await api.createStructuredSession(
            provider: "codex", cwd: "/repo", mode: nil, model: "", prompt: nil
        )
        _ = try await api.createPtySession(
            provider: "codex", cwd: "/repo", mode: nil, model: "", initialInput: nil
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
        let store = WorkspaceStore(api: api, serverID: "test-worktree")
        _ = try await store.createTask(name: "Isolated", directory: "/repo", worktree: nil)
        _ = try await store.createTask(name: "Shared", directory: "/repo", worktree: false)
        _ = try await store.createTask(name: "Scratch", directory: "", worktree: nil)
    }

    private var testSessions: [URLSession] = []

    override func tearDown() {
        testSessions.forEach { $0.invalidateAndCancel() }
        testSessions = []
        super.tearDown()
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
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
