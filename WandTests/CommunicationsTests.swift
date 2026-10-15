import Foundation
import XCTest
@testable import Wand

@MainActor
final class CommunicationsTests: XCTestCase {
    private var suites: [String] = []
    private func defaults() -> UserDefaults {
        let suite = "WandCommunicationsTests.\(UUID().uuidString)"; suites.append(suite)
        return UserDefaults(suiteName: suite)!
    }
    override func tearDown() {
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        suites = []; super.tearDown()
    }
    private func ledger(_ api: CommunicationsStub, defaults: UserDefaults? = nil) -> ConversationRequestLedger {
        ConversationRequestLedger(api: api, serverURL: URL(string: "https://fixture.example.test")!, defaults: defaults ?? self.defaults())
    }
    private func scope(_ id: String = "dm_e_first", target: ConversationTarget? = nil) -> ConversationScope {
        ConversationScope(conversationID: id, target: target)
    }

    func testConversationActivityAndArchiveFiltersAreIndependent() async throws {
        let api = CommunicationsStub()
        api.items = try JSONDecoder().decode([NativeConversation].self, from: JSONSerialization.data(withJSONObject: [
            ["id":"a", "kind":"dm", "peerEmployeeId":"a", "title":"活动"],
            ["id":"b", "kind":"dm", "peerEmployeeId":"b", "title":"空闲"],
            ["id":"c", "kind":"group", "dissolvedAt":"2026-10-01", "title":"归档", "tasks":[["task":["id":"t","title":"任务","status":"archived"],"runs":[]]]]
        ]))
        let storage = defaults()
        let store = CommunicationsStore(api: api, serverURL: URL(string: "https://fixture.example.test")!, defaults: storage)
        await store.refreshIndex()
        let sessions = try JSONDecoder().decode([WorkspaceSessionSummary].self, from: JSONSerialization.data(withJSONObject: [
            ["id":"s1", "employeeId":"a", "status":"running", "inFlight":true],
            ["id":"s2", "employeeId":"b", "status":"running", "provider":"pi", "providerCliActive":true]
        ]))
        XCTAssertEqual(store.conversationList(sessions: sessions).count, 3)
        store.activityOnly = true
        XCTAssertEqual(store.conversationList(sessions: sessions).map(\.id), ["a"])
        store.archiveFilter = .archived
        XCTAssertTrue(store.conversationList(sessions: sessions).isEmpty)
        store.activityOnly = false
        XCTAssertEqual(store.conversationList(sessions: sessions).map(\.id), ["c"])
        let restored = CommunicationsStore(api: api, serverURL: URL(string: "https://fixture.example.test")!, defaults: storage)
        XCTAssertEqual(restored.archiveFilter, .archived)
        XCTAssertFalse(restored.activityOnly)
    }

    func testGroupAndRunKeepTheirOwnLeaderModelPreferences() throws {
        let json = #"{"id":"g1","kind":"group","team":{"members":[{"id":"m1","name":"负责人","isLeader":true,"agent":{"provider":"pi","model":"openai/gpt-5.4-mini","thinkingEffort":"pi:xhigh"}}]},"tasks":[{"task":{"id":"t1","title":"任务"},"runs":[{"id":"r1","taskId":"t1","status":"idle","team":{"members":[{"id":"m2","name":"旧负责人","isLeader":true,"agent":{"provider":"pi","model":"anthropic/claude-opus-4-6","thinkingEffort":"deep"}}]}}]}]}"#
        let detail = try JSONDecoder().decode(NativeConversation.self, from: Data(json.utf8))
        XCTAssertEqual(detail.members.first?.agent?.model, "openai/gpt-5.4-mini")
        XCTAssertEqual(detail.runs.first?.team?.members.first?.agent?.model, "anthropic/claude-opus-4-6")
        XCTAssertEqual(detail.members.first?.agent?.thinkingEffort, "pi:xhigh")
    }

    func testOpeningEmployeeUsesStableVirtualDMAndNeverPosts() async throws {
        let api = CommunicationsStub()
        api.contacts = [try contact("e_first")]
        let store = CommunicationsStore(api: api, serverURL: URL(string: "https://fixture.example.test")!, defaults: defaults())
        await store.refreshIndex()
        store.selectEmployee(api.contacts[0]); await store.waitForDetailForTesting()
        XCTAssertEqual(store.selectedID, "dm_e_first")
        let composer = store.composer(for: scope())
        composer.edit("保留私聊草稿")
        store.selectEmployee(api.contacts[0]); await store.waitForDetailForTesting()
        XCTAssertTrue(composer === store.composer(for: scope()))
        XCTAssertEqual(composer.text, "保留私聊草稿")
        XCTAssertTrue(api.posts.isEmpty)
        XCTAssertEqual(store.detail?.id, "dm_e_first")
        XCTAssertEqual(composer.cwd, "/fixture/default")
    }

    func testReadErrorsAndOutOfOrderResponsesNeverShowAnotherConversation() async throws {
        let api = CommunicationsStub()
        let began = expectation(description: "first detail began")
        var delayed: CheckedContinuation<NativeConversation, Error>?
        api.detailHandler = { id in
            if id == "dm_e_first" {
                return try await withCheckedThrowingContinuation { delayed = $0; began.fulfill() }
            }
            return try conversation(id)
        }
        let store = CommunicationsStore(api: api, serverURL: URL(string: "https://fixture.example.test")!, defaults: defaults())
        store.select("dm_e_first"); await fulfillment(of: [began], timeout: 2)
        store.select("dm_e_second"); await store.waitForDetailForTesting()
        XCTAssertEqual(store.detail?.id, "dm_e_second")
        delayed?.resume(returning: try conversation("dm_e_first"))
        await Task.yield()
        XCTAssertEqual(store.detail?.id, "dm_e_second")
        api.detailHandler = { _ in try conversation("dm_e_wrong") }
        store.select("dm_e_third"); await store.waitForDetailForTesting()
        XCTAssertNil(store.detail)
        XCTAssertNotNil(store.detailError)
    }

    func testMissingOrEndedTargetBlocksSendRatherThanInferringTheNewestRun() async throws {
        let api = CommunicationsStub()
        api.detailHandler = { _ in try conversation("group", kind: "group", runs: ["r1": "done", "r2": "running"]) }
        let store = CommunicationsStore(api: api, serverURL: URL(string: "https://fixture.example.test")!, defaults: defaults())
        store.select("group"); await store.waitForDetailForTesting()
        let ended = scope("group", target: ConversationTarget(taskId: "task", runId: "r1"))
        let active = scope("group", target: ConversationTarget(taskId: "task", runId: "r2"))
        XCTAssertNotNil(store.sendBlockReason(for: ended))
        XCTAssertNil(store.sendBlockReason(for: active))
        store.composer(for: ended).edit("不要串到最新任务")
        await store.send(ended)
        XCTAssertTrue(api.posts.isEmpty)
        XCTAssertEqual(store.composer(for: ended).text, "不要串到最新任务")
    }

    func testSuccessfulAckKeepsNewInputAndCapturedDirectoryAndTarget() async throws {
        let api = CommunicationsStub()
        let began = expectation(description: "send began")
        var complete: CheckedContinuation<ConversationReceipt, Error>?
        var requestID = ""
        api.postHandler = { _, body in
            requestID = body["requestId"] as! String
            return try await withCheckedThrowingContinuation { complete = $0; began.fulfill() }
        }
        let owner = ConversationComposerState(scope: scope(), cwd: "/fixture/first")
        let requests = ledger(api)
        owner.edit("原始工作")
        let sending = Task { await owner.submit(ledger: requests) }
        await fulfillment(of: [began], timeout: 2)
        XCTAssertEqual(owner.text, "")
        owner.edit("期间新输入"); owner.editCwd("/fixture/second")
        complete?.resume(returning: try receipt(requestID, conversationID: "dm_e_first"))
        _ = await sending.value
        XCTAssertEqual(owner.text, "期间新输入")
        XCTAssertEqual(owner.cwd, "/fixture/second")
        XCTAssertEqual(api.posts[0].body["cwd"] as? String, "/fixture/first")
        XCTAssertEqual(api.posts[0].body["input"] as? String, "原始工作")
        XCTAssertTrue(api.posts[0].body["target"] is NSNull)
        XCTAssertEqual(owner.phase, .sent)
        XCTAssertTrue(requests.pending.isEmpty)
    }

    func testExplicitRejectionRestoresSubmittedDraftWithoutLosingNewInput() async throws {
        let api = CommunicationsStub()
        let began = expectation(description: "send began")
        var complete: CheckedContinuation<ConversationReceipt, Error>?
        api.postHandler = { _, _ in try await withCheckedThrowingContinuation { complete = $0; began.fulfill() } }
        let owner = ConversationComposerState(scope: scope(), cwd: "/fixture")
        let requests = ledger(api)
        owner.edit("被拒收的原文")
        let sending = Task { await owner.submit(ledger: requests) }
        await fulfillment(of: [began], timeout: 2)
        owner.edit("后来输入")
        complete?.resume(throwing: WandAPI.APIError.server(status: 400, message: "明确拒收"))
        _ = await sending.value
        XCTAssertEqual(owner.text, "被拒收的原文\n\n后来输入")
        XCTAssertTrue(requests.pending.isEmpty)
        XCTAssertEqual(owner.phase, .rejected("明确拒收"))
    }

    func testDiscardAndDeleteBlockLateRestoration() async throws {
        for explicitDiscard in [true, false] {
            let api = CommunicationsStub(), began = expectation(description: "send began")
            var complete: CheckedContinuation<ConversationReceipt, Error>?
            api.postHandler = { _, _ in try await withCheckedThrowingContinuation { complete = $0; began.fulfill() } }
            let owner = ConversationComposerState(scope: scope(), cwd: "/fixture")
            let requests = ledger(api); owner.edit("不可复活的原文")
            let sending = Task { await owner.submit(ledger: requests) }
            await fulfillment(of: [began], timeout: 2)
            if explicitDiscard { owner.discard() } else { owner.edit("新输入"); owner.edit("") }
            complete?.resume(throwing: WandAPI.APIError.server(status: 400, message: "明确拒收"))
            _ = await sending.value
            XCTAssertEqual(owner.text, "")
        }
    }

    func testUncertainDeliveryPersistsOnlyOpaqueIdentityAndBlocksDuplicateAfterRestart() async throws {
        let api = CommunicationsStub(), storage = defaults()
        api.postHandler = { _, _ in throw WandAPI.APIError.network("成功回执后 JSON 解析失败") }
        let first = ledger(api, defaults: storage)
        let owner = ConversationComposerState(scope: scope(), cwd: "/fixture")
        let secretText = "未确认正文-\(UUID().uuidString)"; owner.edit(secretText)
        _ = await owner.submit(ledger: first)
        let originalID = try XCTUnwrap(owner.unknownID)
        XCTAssertEqual(owner.text, "")
        XCTAssertEqual(first.pending.count, 1)
        let persisted = try XCTUnwrap(storage.persistentDomain(forName: suites.last!))
        let values = persisted.values.compactMap { $0 as? Data }.map { String(decoding: $0, as: UTF8.self) }
        XCTAssertFalse(values.joined().contains(secretText))
        let restored = ledger(api, defaults: storage)
        XCTAssertEqual(restored.pending.first?.id, originalID)
        do {
            _ = try await restored.perform(path: "/api/conversations/dm_e_first/messages", body: ["input": secretText, "target": NSNull(), "cwd": "/fixture"], scope: scope(), operation: "message")
            XCTFail("duplicate must be blocked")
        } catch let ConversationDeliveryError.uncertain(id, _) { XCTAssertEqual(id, originalID) }
        XCTAssertEqual(api.posts.count, 1)
    }

    func testHTTP408409And5xxRemainUnknownAnd404ReceiptDoesNotRestore() async throws {
        for status in [408, 409, 500, 503] {
            let api = CommunicationsStub()
            api.postHandler = { _, _ in throw WandAPI.APIError.server(status: status, message: "未知送达") }
            api.receiptHandler = { _ in throw WandAPI.APIError.server(status: 404, message: "暂无回执") }
            let requests = ledger(api), owner = ConversationComposerState(scope: scope(), cwd: "/fixture")
            owner.edit("不能自动重发")
            _ = await owner.submit(ledger: requests)
            let id = try XCTUnwrap(owner.unknownID)
            owner.edit("核对期间的新输入")
            _ = await owner.reconcile(ledger: requests)
            XCTAssertEqual(owner.unknownID, id)
            XCTAssertEqual(owner.text, "核对期间的新输入")
            XCTAssertEqual(requests.pending.count, 1)
            XCTAssertEqual(api.posts.count, 1)
        }
    }

    func testReceiptAcceptanceAndStartupFailureNeverRecoverAsUnsent() async throws {
        let api = CommunicationsStub()
        api.postHandler = { _, body in try receipt(body["requestId"] as! String, conversationID: "dm_e_first", startup: "failed", error: "已接受，但执行启动失败") }
        let requests = ledger(api), owner = ConversationComposerState(scope: scope(), cwd: "/fixture")
        owner.edit("已经被接受")
        _ = await owner.submit(ledger: requests)
        XCTAssertEqual(owner.text, "")
        XCTAssertEqual(owner.phase, .acceptedWithFailure("已接受，但执行启动失败"))
        XCTAssertTrue(owner.feedback.contains("启动失败"))
        XCTAssertTrue(requests.pending.isEmpty)
    }

    func testPendingAndWrongReceiptIDAreUnknownThenReconcilePreservesFreshText() async throws {
        for wrongID in [false, true] {
            let api = CommunicationsStub()
            api.postHandler = { _, body in try receipt(wrongID ? "wrong" : body["requestId"] as! String, conversationID: "dm_e_first", state: wrongID ? "accepted" : "pending") }
            let requests = ledger(api), owner = ConversationComposerState(scope: scope(), cwd: "/fixture")
            owner.edit("原始正文")
            _ = await owner.submit(ledger: requests)
            let id = try XCTUnwrap(owner.unknownID)
            api.receiptHandler = { requested in try receipt(requested, conversationID: "dm_e_first") }
            owner.edit("后来工作")
            _ = await owner.reconcile(ledger: requests)
            XCTAssertNil(owner.unknownID)
            XCTAssertEqual(owner.text, "后来工作")
            XCTAssertTrue(requests.pending.isEmpty)
            XCTAssertEqual(api.posts.count, 1)
            XCTAssertFalse(id.isEmpty)
        }
    }

    func testUnknownRejectionRestoresInMemoryButRestartCannotInventSubmittedText() async throws {
        let api = CommunicationsStub(), storage = defaults()
        api.postHandler = { _, _ in throw WandAPI.APIError.network("断线") }
        let requests = ledger(api, defaults: storage), owner = ConversationComposerState(scope: scope(), cwd: "/fixture")
        owner.edit("内存中的原文")
        _ = await owner.submit(ledger: requests)
        api.receiptHandler = { id in try receipt(id, conversationID: "dm_e_first", state: "rejected", error: "未接受") }
        _ = await owner.reconcile(ledger: requests)
        XCTAssertEqual(owner.text, "内存中的原文")
        owner.edit("第二次提交")
        _ = await owner.submit(ledger: requests)
        let restoredLedger = ledger(api, defaults: storage)
        let restored = ConversationComposerState(scope: scope(), cwd: "/fixture", pending: restoredLedger.pending.first)
        restored.edit("重启后的新输入")
        _ = await restored.reconcile(ledger: restoredLedger)
        XCTAssertEqual(restored.text, "重启后的新输入")
    }

    func testScopeDraftsTargetsAndUploadRevisionsStayIndependent() async throws {
        let api = CommunicationsStub()
        let store = CommunicationsStore(api: api, serverURL: URL(string: "https://fixture.example.test")!, defaults: defaults())
        store.select("dm_e_first"); await store.waitForDetailForTesting()
        let first = store.composer(for: scope())
        let second = store.composer(for: scope("dm_e_second"))
        first.edit("第一位员工的输入"); second.edit("第二位员工的输入")
        let r1 = store.composer(for: scope("group", target: ConversationTarget(taskId: "task", runId: "r1")))
        let r2 = store.composer(for: scope("group", target: ConversationTarget(taskId: "task", runId: "r2")))
        r1.edit("第一轮草稿"); XCTAssertEqual(r2.text, "")
        let began = expectation(description: "upload began")
        var delayed: CheckedContinuation<[UploadedFile], Error>?
        api.uploadHandler = { _, _ in try await withCheckedThrowingContinuation { delayed = $0; began.fulfill() } }
        let uploading = Task { await store.addAttachments([URL(fileURLWithPath: "/fixture/test.txt")], scope: self.scope()) }
        await fulfillment(of: [began], timeout: 2)
        first.edit("变化后的新输入")
        store.select("dm_e_second"); await store.waitForDetailForTesting()
        delayed?.resume(returning: [UploadedFile(originalName: "test.txt", savedPath: "/fixture/uploaded.txt", size: 1, mimeType: "text/plain")])
        await uploading.value
        XCTAssertTrue(first.attachments.isEmpty)
        XCTAssertTrue(second.attachments.isEmpty)
        XCTAssertEqual(first.text, "变化后的新输入")
        XCTAssertEqual(second.text, "第二位员工的输入")
    }

    func testGroupCreationAndInvitationUseExactMetadataAndMemberVersion() async throws {
        let api = CommunicationsStub(); api.contacts = [try contact("e_first"), try contact("e_second")]
        let store = CommunicationsStore(api: api, serverURL: URL(string: "https://fixture.example.test")!, defaults: defaults())
        await store.refreshIndex()
        let op = ConversationOperationState()
        let invalid = await store.createGroup(ConversationGroupDraft(), operation: op)
        XCTAssertNil(invalid)
        XCTAssertTrue(api.posts.isEmpty)
        var draft = ConversationGroupDraft(); draft.name = "测试群"; draft.toggle("e_first"); draft.toggle("e_second")
        let created = await store.createGroup(draft, operation: op)
        XCTAssertEqual(created?.conversationId, "new-group")
        XCTAssertEqual(api.posts[0].path, "/api/conversations")
        let group = api.posts[0].body["group"] as! [String: Any]
        XCTAssertEqual(Set(group.keys), ["name", "employeeIds", "leaderId"])
        XCTAssertEqual(group["employeeIds"] as? [String], ["e_first", "e_second"])
        let snapshot = try conversation("group", kind: "group", memberVersion: 7)
        _ = await store.invite(draft, into: snapshot, operation: ConversationOperationState())
        XCTAssertEqual(api.posts[1].body["memberVersion"] as? Int, 7)
        XCTAssertEqual(api.posts[1].path, "/api/conversations/group/invitations")
    }

    func testNativeAPIUsesConversationRoutesAndNeverRequestsKnowledge() async throws {
        let host = UUID().uuidString.lowercased() + ".wand.test"
        let lock = NSLock()
        var paths: [String] = []
        CommunicationsContractURLProtocol.register(host: host) { request in
            let path = request.url!.path
            lock.withLock { paths.append(path) }
            switch path {
            case "/api/silicon-employees":
                XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "1")
                return Data(#"{"employees":[{"id":"e_first","name":"测试员工","duty":"职责","prompt":"不会投影或缓存的角色提示","agents":[{"provider":"pi","engine":"sdk"}]}]}"#.utf8)
            case "/api/conversations":
                return Data(#"{"conversations":[]}"#.utf8)
            case "/api/conversations/dm_e_first":
                return Data(#"{"id":"dm_e_first","kind":"dm","messages":[]}"#.utf8)
            case "/api/conversations/dm_e_first/messages":
                let body = try Self.requestBody(request)
                XCTAssertEqual(body["input"] as? String, "fixture-only")
                XCTAssertTrue(body["target"] is NSNull)
                return try JSONSerialization.data(withJSONObject: ["state":"accepted","requestId":body["requestId"]!, "conversationId":"dm_e_first"])
            default: XCTFail("unexpected route: \(path)"); throw URLError(.unsupportedURL)
            }
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CommunicationsContractURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel(); CommunicationsContractURLProtocol.unregister(host: host) }
        let api = WandAPI(baseURL: URL(string: "https://" + host)!, token: nil, session: session)
        let contacts = try await api.employeeContacts()
        XCTAssertEqual(contacts.first?.id, "e_first")
        let conversations = try await api.conversations()
        XCTAssertTrue(conversations.isEmpty)
        let detail = try await api.conversation(id: "dm_e_first")
        XCTAssertEqual(detail.id, "dm_e_first")
        let receipts = ConversationRequestLedger(api: api, serverURL: api.baseURL, defaults: defaults())
        _ = try await receipts.perform(path: "/api/conversations/dm_e_first/messages", body: ["input":"fixture-only","target":NSNull()], scope: scope(), operation: "message")
        XCTAssertEqual(lock.withLock { paths.count }, 4)
        XCTAssertFalse(lock.withLock { paths.contains { $0.contains("/knowledge") } })
    }

    private static func requestBody(_ request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }; data.append(buffer, count: count)
            }
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testDTOMessageIdentityPreviewAndAuthorSurviveLegacyContent() throws {
        let data = Data(#"{"role":"assistant","content":[{"type":"text","text":"完整正文"},{"type":"future"}],"messageId":"m1","author":{"id":"e_first","name":"历史成员","engine":"sdk","provider":"pi"},"sessionLink":{"sessionId":"s1","title":"原工作"},"sessionPreview":{"status":"running","text":"预览"},"notice":false}"#.utf8)
        let turn = try JSONDecoder().decode(ConversationTurn.self, from: data)
        XCTAssertEqual(turn.messageId, "m1")
        XCTAssertEqual(turn.sessionLink?.sessionId, "s1")
        XCTAssertEqual(turn.author?.name, "历史成员")
        XCTAssertEqual(turn.sessionPreview?.status, "running")
        XCTAssertEqual(turn.content.count, 2)
        XCTAssertEqual(WandProvider.title(for: turn.author?.provider, engine: turn.author?.engine), "Wand Agent")
    }
}

@MainActor
final class CommunicationsStub: CommunicationsServing {
    struct Post { let path: String; let body: [String: Any] }
    var contacts: [EmployeeContact] = []
    var items: [NativeConversation] = []
    var posts: [Post] = []
    var detailHandler: ((String) async throws -> NativeConversation)?
    var postHandler: ((String, [String: Any]) async throws -> ConversationReceipt)?
    var receiptHandler: ((String) async throws -> ConversationReceipt)?
    var uploadHandler: ((String, [URL]) async throws -> [UploadedFile])?
    func employeeContacts() async throws -> [EmployeeContact] { contacts }
    func conversations() async throws -> [NativeConversation] { items }
    func conversation(id: String) async throws -> NativeConversation {
        if let detailHandler { return try await detailHandler(id) }
        return try CommunicationsTestsConversation(id)
    }
    func conversationReceipt(requestID: String) async throws -> ConversationReceipt {
        if let receiptHandler { return try await receiptHandler(requestID) }
        throw WandAPI.APIError.server(status: 404, message: "暂无回执")
    }
    func postConversation(path: String, body: [String: Any]) async throws -> ConversationReceipt {
        posts.append(Post(path: path, body: body))
        if let postHandler { return try await postHandler(path, body) }
        let id = path == "/api/conversations" ? "new-group" : path.split(separator: "/").dropFirst(2).first.map(String.init) ?? "dm_e_first"
        return try receipt(body["requestId"] as! String, conversationID: id, sessionID: "attachment-channel")
    }
    func communicationsDefaultCwd() async throws -> String { "/fixture/default" }
    func uploadAttachments(id: String, urls: [URL]) async throws -> [UploadedFile] { try await uploadHandler?(id, urls) ?? [] }
}

private func decode<T: Decodable>(_ json: [String: Any], as type: T.Type) throws -> T {
    try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: json))
}
private func receipt(_ id: String, conversationID: String, state: String = "accepted", startup: String? = nil, error: String? = nil, sessionID: String? = nil) throws -> ConversationReceipt {
    var body: [String: Any] = ["requestId": id, "conversationId": conversationID, "state": state]
    body["startup"] = startup; body["error"] = error; body["sessionId"] = sessionID
    return try decode(body, as: ConversationReceipt.self)
}
private func contact(_ id: String) throws -> EmployeeContact {
    try decode(["id": id, "name": "测试员工", "duty": "测试职责", "agents": [["provider": "pi", "engine": "sdk", "kind": "structured"]]], as: EmployeeContact.self)
}
private func conversation(_ id: String, kind: String = "dm", memberVersion: Int = 1, runs: [String: String] = [:]) throws -> NativeConversation {
    var body: [String: Any] = ["id": id, "kind": kind, "title": "测试对话", "memberVersion": memberVersion, "messages": []]
    body["tasks"] = [["task": ["id": "task", "title": "测试工作"], "runs": runs.map { ["id": $0.key, "taskId": "task", "status": $0.value] }]]
    return try decode(body, as: NativeConversation.self)
}
private func CommunicationsTestsConversation(_ id: String) throws -> NativeConversation { try conversation(id) }
