import Foundation
import XCTest
@testable import Wand

final class ClientFeedbackTests: XCTestCase {
    private let origin = URL(string: "https://feedback-client.test")!
    private func failure(_ message: String = "原始错误 /tmp/update failed") -> NSError {
        NSError(domain: "InstallerFailure", code: 73, userInfo: [NSLocalizedDescriptionKey: message])
    }

    func testOriginalNSErrorAndOnlyRecordedStackAreRetained() throws {
        let raw = failure()
        let report = try XCTUnwrap(ClientFeedbackReport.failure(raw, token: nil))
        XCTAssertEqual(report.name, raw.domain)
        XCTAssertEqual(report.code, "73")
        XCTAssertEqual(report.message, raw.localizedDescription)
        XCTAssertNil(report.stack, "The reporting thread is not the failing operation's stack")
        let recorded = NSError(domain: "Recorded", code: 1, userInfo: [NSLocalizedDescriptionKey: "original", "NSStackTraceKey": ["frame 1", "frame 2"]])
        XCTAssertEqual(ClientFeedbackReport.failure(recorded, token: nil)?.stack, "frame 1\nframe 2")
        XCTAssertNil(ClientFeedbackReport.failure(CancellationError(), token: nil))
        XCTAssertNil(ClientFeedbackReport.failure(URLError(.cancelled), token: nil))
    }

    func testCredentialFilteringPreservesOtherText() {
        let raw = "原文 /tmp/file\nAuthorization: Bearer private\nCookie: wand_session=hidden\npassword=secret token=abc api_key=def\n{\"appToken\":\"sensitive\"}\nhttps://alice:pass@example.com current-token 尾部"
        let filtered = ClientFeedbackReport.redact(raw, token: "current-token")
        for secret in ["private", "hidden", "secret", "abc", "def", "sensitive", "alice", "pass@", "current-token"] {
            XCTAssertFalse(filtered.contains(secret), secret)
        }
        XCTAssertTrue(filtered.hasPrefix("原文 /tmp/file\n"))
        XCTAssertTrue(filtered.hasSuffix(" 尾部"))
        XCTAssertEqual(ClientFeedbackReport.redact(#"{"Cookie":"wand_session=hidden","Authorization":"Basic private","app_token":"secret"}"#, token: nil),
                       #"{"Cookie":[REDACTED],"Authorization":[REDACTED],"app_token":[REDACTED]}"#)
    }

    func testOnlyHTTPSOrLiteralLoopbackAndKnownRouteFamilies() {
        for value in ["https://remote.test", "http://localhost:8443", "http://127.0.0.1", "http://127.2.3.4", "http://[::1]"] {
            XCTAssertTrue(ClientFeedback.isSafe(URL(string: value)!))
        }
        for value in ["http://192.168.1.1", "http://localhost.evil.test", "http://127.evil.test", "https://user:pass@host", "ftp://localhost"] {
            XCTAssertFalse(ClientFeedback.isSafe(URL(string: value)!))
        }
        XCTAssertEqual(ClientFeedbackReport.feature(path: "/api/wand-tasks/uuid/comments"), "tasks")
        XCTAssertEqual(ClientFeedbackReport.feature(path: "/api/conversations/uuid/messages"), "conversations")
        XCTAssertEqual(ClientFeedbackReport.feature(path: "/api/new-endpoint"), "api")
        XCTAssertEqual(ClientFeedbackReport.feature(path: ""), "api")
    }

    func testFeedbackSessionRejectsCrossOriginRedirectAndDiscardsResponseBody() {
        let delegate = ClientFeedbackSessionDelegate()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: origin)
        let response = HTTPURLResponse(url: origin, statusCode: 307, httpVersion: nil,
                                       headerFields: ["Location": "https://untrusted.test/collect"])!
        var redirect = URLRequest(url: URL(string: "https://untrusted.test/collect")!)
        redirect.setValue("Bearer private", forHTTPHeaderField: "Authorization")
        redirect.httpBody = Data("original diagnostic".utf8)
        var called = false
        delegate.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: redirect) { request in
            called = true
            XCTAssertNil(request, "Neither raw diagnostics nor authentication may follow a redirect")
        }
        XCTAssertTrue(called)
        delegate.urlSession(session, dataTask: task, didReceive: response) { disposition in
            XCTAssertEqual(disposition, .cancel, "A feedback response body is never collected")
        }
    }

    @MainActor
    func testSchemaAuthenticationDeduplicationCancellationAndNoRetry() async throws {
        var requests: [URLRequest] = []
        let connection = ClientFeedback.Connection(origin: origin, token: "current-token")
        let reporter = ClientFeedback(currentConnection: { connection }, transport: { requests.append($0) })
        for _ in 0..<4 { reporter.submit(failure("token=current-token 原始消息"), event: "update_failed", feature: "app_update", connection: connection) }
        reporter.submit(URLError(.cancelled), event: "update_failed", feature: "app_update", connection: connection)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.path, "/api/feedback/client")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer current-token")
        XCTAssertEqual(request.timeoutInterval, 4)
        XCTAssertFalse(request.httpShouldHandleCookies)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["schema", "source", "event", "version", "feature", "error"])
        XCTAssertEqual(json["schema"] as? Int, 1)
        XCTAssertEqual(json["source"] as? String, "macos")
        XCTAssertEqual(json["feature"] as? String, "app_update")
        let error = try XCTUnwrap(json["error"] as? [String: Any])
        XCTAssertEqual(error["message"] as? String, "token=[REDACTED] 原始消息")
        XCTAssertNil(error["stack"])
    }

    @MainActor
    func testRateLimitAndDedupeExpiry() async {
        var time = Date()
        var count = 0
        let connection = ClientFeedback.Connection(origin: origin, token: nil)
        let reporter = ClientFeedback(now: { time }, currentConnection: { connection }, transport: { _ in count += 1 })
        for n in 0..<8 {
            reporter.submit(failure("failure \(n)"), event: "update_failed", feature: "app_update", connection: connection)
            for _ in 0..<10 { await Task.yield() }
        }
        XCTAssertEqual(count, 5)
        time.addTimeInterval(61)
        reporter.submit(failure("failure 0"), event: "update_failed", feature: "app_update", connection: connection)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(count, 5)
        time.addTimeInterval(300)
        reporter.submit(failure("failure 0"), event: "update_failed", feature: "app_update", connection: connection)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(count, 6)
    }

    @MainActor
    func testBoundedConcurrencyNoQueueAndUnsafeOrOversizeDropped() async {
        var gates: [CheckedContinuation<Void, Never>] = []
        let connection = ClientFeedback.Connection(origin: origin, token: nil)
        let reporter = ClientFeedback(currentConnection: { connection }, transport: { _ in await withCheckedContinuation { gates.append($0) } })
        for n in 0..<8 { reporter.submit(failure("failure \(n)"), event: "update_failed", feature: "app_update", connection: connection) }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(gates.count, 2)
        let active = gates
        active.forEach { $0.resume() }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(gates.count, 2, "Dropped reports must not be queued or retried")
        reporter.submit(failure(String(repeating: "x", count: 8193)), event: "update_failed", feature: "app_update", connection: connection)
        reporter.submit(failure(), event: "update_failed", feature: "app_update", connection: .init(origin: URL(string: "http://remote.test")!, token: nil))
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(gates.count, 2)
    }

    @MainActor
    func testSameURLTokenRefreshAndServerSwitchDropLateOperationFeedback() async throws {
        let old = ClientFeedback.Connection(origin: origin, token: "old-secret")
        let refreshed = ClientFeedback.Connection(origin: origin, token: "new-secret")
        let other = ClientFeedback.Connection(origin: URL(string: "https://other.test")!, token: "other-secret")
        var current: ClientFeedback.Connection? = old
        var requests: [URLRequest] = []
        let reporter = ClientFeedback(currentConnection: { current }, transport: { requests.append($0) })
        // A failure that arrives after same-URL authentication refresh must not borrow the new token.
        current = refreshed
        reporter.submit(failure("old-secret failure"), event: "http_5xx", feature: "api", connection: old)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(requests.isEmpty)
        // Also cover a connection change after admission but before the async transport runs.
        current = old
        reporter.submit(failure("old-secret admitted failure"), event: "websocket_error", feature: "realtime", connection: old)
        current = other
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(requests.isEmpty)
        // Reconnecting to identical URL and credentials is still a new owner.
        current = ClientFeedback.Connection(origin: old.origin, token: old.token)
        reporter.submit(failure("old-secret previous generation"), event: "http_5xx", feature: "api", connection: old)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(requests.isEmpty)
        current = nil
        reporter.submit(failure("old-secret disconnected failure"), event: "update_failed", feature: "app_update", connection: old)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(requests.isEmpty)
        current = refreshed
        reporter.submit(failure("new-secret original text"), event: "update_failed", feature: "app_update", connection: refreshed)
        for _ in 0..<10 { await Task.yield() }
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(request.url?.host, origin.host)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer new-secret")
        let text = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertFalse(text.contains("new-secret"))
        XCTAssertFalse(text.contains("old-secret"))
        XCTAssertTrue(text.contains("[REDACTED] original text"))
    }

    @MainActor
    func testCookieAuthenticationIsSnapshottedAndNeverReadsNewSessionCookies() async throws {
        let original = ClientFeedback.Connection(origin: origin, token: nil, cookieHeader: "wand_session=original-cookie")
        var current: ClientFeedback.Connection? = original
        var requests: [URLRequest] = []
        let reporter = ClientFeedback(currentConnection: { current }, transport: { requests.append($0) })
        reporter.submit(failure("original-cookie diagnosis"), event: "http_5xx", feature: "api", connection: original)
        for _ in 0..<10 { await Task.yield() }
        let request = try XCTUnwrap(requests.first)
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "wand_session=original-cookie")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertFalse(String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self).contains("original-cookie"))
        current = .init(origin: origin, token: nil, generation: original.generation, cookieHeader: "wand_session=new-cookie")
        reporter.submit(failure("original-cookie late diagnosis"), event: "update_failed", feature: "app_update", connection: original)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(requests.count, 1)
    }

    func testAPI5xxReportsOriginalErrorWithoutReplayingBusinessOrFeedback() async throws {
        FeedbackURLProtocol.status = 503
        FeedbackURLProtocol.body = Data(#"{"error":"原始 server failure"}"#.utf8)
        FeedbackURLProtocol.paths = []
        FeedbackURLProtocol.urls = []
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FeedbackURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        var reported: [(Error, String)] = []
        let api = WandAPI(baseURL: origin, token: nil, session: session, reportServerFailure: { error, feature, _ in reported.append((error, feature)) })
        do { _ = try await api.requestData(method: "POST", path: "/api/wand-tasks") ; XCTFail("Expected 503") }
        catch { XCTAssertEqual(error.localizedDescription, "原始 server failure") }
        XCTAssertEqual(reported.count, 1)
        XCTAssertEqual(reported.first?.0.localizedDescription, "原始 server failure")
        XCTAssertEqual(reported.first?.1, "tasks")
        _ = try? await api.requestData(method: "POST", path: "/api/feedback/client")
        XCTAssertEqual(reported.count, 1)
        XCTAssertEqual(FeedbackURLProtocol.paths, ["/api/wand-tasks", "/api/feedback/client"])
    }

    func testSocketDecodingReportsTheOriginalErrorNotThePayloadOrReportingStack() throws {
        var captured: Error?
        let socket = WandSocket(baseURL: origin, reportFailure: { captured = $0 })
        socket.handle(Data("not-json PRIVATE-CHAT-CONTENT".utf8))
        let error = try XCTUnwrap(captured)
        XCTAssertTrue(error is DecodingError)
        let report = try XCTUnwrap(ClientFeedbackReport.failure(error, token: nil))
        XCTAssertEqual(report.message, error.localizedDescription)
        XCTAssertFalse(report.message.contains("PRIVATE-CHAT-CONTENT"))
        XCTAssertNil(report.stack)
    }

    func testCommentsContract404AndTaskIDFiltering() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FeedbackURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let api = WandAPI(baseURL: origin, token: nil, session: session)
        FeedbackURLProtocol.status = 404
        FeedbackURLProtocol.body = Data()
        let empty = try await api.boardTaskComments(id: "old")
        XCTAssertTrue(empty.comments.isEmpty)
        XCTAssertEqual(empty.totalCount, 0)
        FeedbackURLProtocol.status = 200
        FeedbackURLProtocol.body = Data(#"{"comments":[{"id":"c1","taskId":"a/b","authorName":"小王","body":"也遇到了相同的问题。","createdAt":"2026-10-16T01:02:03Z"},{"id":"c2","taskId":"other","authorName":"我","body":"other","createdAt":"now"}],"totalCount":7,"nextCursor":"opaque +/="}"#.utf8)
        let page = try await api.boardTaskComments(id: "a/b", before: "older +/=", limit: 17)
        XCTAssertEqual(page.comments.map(\.id), ["c1"])
        XCTAssertEqual(page.comments.first?.authorName, "小王")
        XCTAssertEqual(page.totalCount, 7)
        XCTAssertEqual(page.nextCursor, "opaque +/=")
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(FeedbackURLProtocol.urls.last), resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.path, "/api/wand-tasks/a/b/comments")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "limit" })?.value, "17")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "before" })?.value, "older +/=")
    }

    @MainActor
    func testCommentsRefreshFailurePreservesDataAndAllowsRetry() async {
        let store = TaskCommentsStore()
        let comment = WandTaskComment(id: "c1", taskId: "task", authorName: "我", body: String(repeating: "长评论", count: 200), createdAt: "now")
        await store.load(taskId: "task") { _, _, _ in WandTaskCommentsPage(comments: [comment], totalCount: 1, nextCursor: nil) }
        XCTAssertEqual(store.comments, [comment])
        XCTAssertFalse(store.loading)
        await store.load(taskId: "task") { _, _, _ in throw URLError(.notConnectedToInternet) }
        XCTAssertTrue(store.failed)
        XCTAssertFalse(store.loading)
        XCTAssertEqual(store.comments, [comment])
        await store.load(taskId: "task") { _, _, _ in WandTaskCommentsPage(comments: [], totalCount: 0, nextCursor: nil) }
        XCTAssertFalse(store.failed)
        XCTAssertEqual(store.comments, [comment], "an empty first page keeps older pages already loaded")
        await store.load(taskId: "other") { _, _, _ in throw URLError(.notConnectedToInternet) }
        XCTAssertTrue(store.failed)
        XCTAssertTrue(store.comments.isEmpty)
    }

    @MainActor
    func testLateCommentsCannotReplaceNewTask() async throws {
        let store = TaskCommentsStore()
        var old: CheckedContinuation<WandTaskCommentsPage, Error>?
        let first = Task { await store.load(taskId: "first") { _, _, _ in try await withCheckedThrowingContinuation { old = $0 } } }
        while old == nil { await Task.yield() }
        await store.load(taskId: "second") { _, _, _ in WandTaskCommentsPage(comments: [WandTaskComment(id: "new", taskId: "second", authorName: "我", body: "new", createdAt: "now")], totalCount: 1, nextCursor: nil) }
        old?.resume(returning: WandTaskCommentsPage(comments: [WandTaskComment(id: "old", taskId: "first", authorName: "我", body: "old", createdAt: "now")], totalCount: 1, nextCursor: nil))
        await first.value
        XCTAssertEqual(store.comments.map(\.id), ["new"])
    }
}

private final class FeedbackURLProtocol: URLProtocol {
    static var status = 200
    static var body = Data()
    static var paths: [String] = []
    static var urls: [URL] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.paths.append(request.url!.path)
        Self.urls.append(request.url!)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

extension ClientFeedbackTests {

    func testCommentStatusAPIEncodesIdsAndReturnsPartialProjection() async throws {
        FeedbackURLProtocol.status = 200
        FeedbackURLProtocol.body = Data(#"{"comments":[{"id":"c1","dispatch":null},{"id":"c2"}]}"#.utf8)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FeedbackURLProtocol.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        let api = WandAPI(baseURL: origin, token: nil, session: session)
        let payload = try await api.boardTaskCommentStatuses(taskId: "task / one", commentIds: ["c1", "c2"])
        XCTAssertEqual(payload.comments.map(\.id), ["c1", "c2"])
        XCTAssertTrue(payload.comments[0].includesDispatch)
        XCTAssertNil(payload.comments[0].dispatch)
        XCTAssertFalse(payload.comments[1].includesDispatch)
        let url = try XCTUnwrap(FeedbackURLProtocol.urls.last)
        XCTAssertEqual(Set(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "ids" })?.value?.split(separator: ",").map(String.init) ?? []), Set(["c1", "c2"]))
        XCTAssertTrue(url.absoluteString.contains("task%20%2F%20one"))
    }

    @MainActor func testStatusRefreshUpdatesOlderLoadedCommentWithoutChangingPaginationOrBody() async {
        let store = TaskCommentsStore()
        let fresh = WandTaskComment(id: "fresh", taskId: "task", authorName: "作者", body: "fresh body", createdAt: "2026-10-19", dispatch: nil)
        await store.load(taskId: "task") { _, _, _ in WandTaskCommentsPage(comments: [fresh], totalCount: 2, nextCursor: "opaque") }
        let older = WandTaskComment(id: "older", taskId: "task", authorName: "旧作者", body: "保留正文", createdAt: "2026-10-18")
        await store.loadOlder(taskId: "task") { _, _, _ in WandTaskCommentsPage(comments: [older], totalCount: 2, nextCursor: nil) }
        let dispatch = WandTaskCommentDispatch(employeeId: "e", employeeName: "员工", state: "accepted", sessionId: "s", resultAnchor: nil, status: "running", error: nil)
        await store.refreshStatuses(taskId: "task") { _, ids in
            XCTAssertEqual(ids, ["fresh", "older"])
            return WandTaskCommentStatuses(comments: [WandTaskCommentStatus(id: "older", dispatch: dispatch, includesDispatch: true)])
        }
        XCTAssertEqual(store.comments.first(where: { $0.id == "older" })?.body, "保留正文")
        XCTAssertEqual(store.comments.first(where: { $0.id == "older" })?.dispatch?.status, "running")
        XCTAssertNil(store.comments.first(where: { $0.id == "fresh" })?.dispatch)
        XCTAssertEqual(store.nextCursor, nil)
        XCTAssertEqual(store.totalCount, 2)
    }

    func testTaskCommentResultBlockWindowUsesAbsoluteIndicesAndLegacyHandles() throws {
        let json = #"{"turnOffset":12,"blockOffset":5,"blockTotal":8,"blocks":[{"blockIndex":5,"block":{"type":"text","text":"window"},"truncated":true}]}"#
        let window = try JSONDecoder().decode(WandTaskCommentBlockWindow.self, from: Data(json.utf8))
        XCTAssertEqual(window.turnOffset, 12)
        XCTAssertEqual(window.blockOffset, 5)
        XCTAssertEqual(window.blocks.first?.blockIndex, 5)
        XCTAssertTrue(window.blocks.first?.truncated == true)

        let olderShape = #"{"blocks":[{"type":"text","text":"older"}],"blockOffset":5,"blockTotal":8,"truncatedBlocks":[{"turnOffset":3,"blockIndex":5}]}"#
        let legacy = try JSONDecoder().decode(WandTaskCommentBlockWindow.self, from: Data(olderShape.utf8))
        XCTAssertFalse(legacy.hasExplicitTurnOffset)
        XCTAssertEqual(legacy.blockOffset, 5)
        XCTAssertEqual(legacy.blocks.first?.blockIndex, 5)
        XCTAssertTrue(legacy.blocks.first?.truncated == true)
    }

    func testJSONValuePrettyPrintedJSONPreservesNestedToolDetails() {
        let value = JSONValue.object(["nested": .array([.object(["answer": .string("complete")])])])
        XCTAssertTrue(value.prettyPrintedJSON.contains("complete"))
        XCTAssertTrue(value.prettyPrintedJSON.contains("nested"))
        XCTAssertFalse(value.prettyPrintedJSON.contains("{…}"))
    }

    func testTaskCommentDispatchDecodesTrustedIdentityAndStatus() throws {
        let data = Data(#"{"id":"c","taskId":"task","authorName":"用户","body":"@赛博虎妞 本轮","createdAt":"now","sourceCommentId":"source","dispatch":{"employeeId":"stable-id","employeeName":"赛博虎妞","state":"accepted","sessionId":"exact-session","status":"stopped","error":null,"resultAnchor":{"requestId":"req-1","fingerprint":"digest","startIndex":7,"endIndex":null,"outcome":null}}}"#.utf8)
        let comment = try JSONDecoder().decode(WandTaskComment.self, from: data)
        XCTAssertEqual(comment.sourceCommentId, "source")
        XCTAssertEqual(comment.dispatch?.employeeId, "stable-id")
        XCTAssertEqual(comment.dispatch?.sessionId, "exact-session")
        XCTAssertEqual(comment.dispatch?.label, "已停止")
        XCTAssertEqual(comment.dispatch?.resultAnchor?.requestId, "req-1")
        XCTAssertEqual(comment.dispatch?.resultAnchor?.startIndex, 7)
        XCTAssertNil(comment.dispatch?.resultAnchor?.endIndex)
        XCTAssertNil(comment.dispatch?.resultAnchor?.outcome)
        let misplacedAnchor = try JSONDecoder().decode(WandTaskComment.self, from: Data(#"{"id":"legacy","taskId":"task","authorName":"用户","body":"old","createdAt":"now","resultAnchor":{"requestId":"wrong","fingerprint":"digest","startIndex":0}}"#.utf8))
        XCTAssertNil(misplacedAnchor.dispatch?.resultAnchor, "anchor is nested under dispatch only")
        let plain = try JSONDecoder().decode(WandTaskComment.self, from: Data(#"{"id":"old","taskId":"task","authorName":"用户","body":"@文本不派发","createdAt":"now"}"#.utf8))
        XCTAssertNil(plain.dispatch)
    }
}

extension ClientFeedbackTests {

    func testUnknownReceiptRetainsIdentityAcrossRefreshAndEditingOtherDrafts() throws {
        let name = "task-comment-review-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let first = TaskCommentRequestIdentity(taskId: "task", body: "old instruction", employeeId: "stable", sourceCommentId: "source", defaults: defaults)
        let unknown = try JSONDecoder().decode(WandTaskComment.self, from: Data(#"{"id":"c","taskId":"task","authorName":"用户","body":"old instruction","createdAt":"now","dispatch":{"employeeId":"stable","employeeName":"员工","state":"unknown","sessionId":"exact","status":"unknown","error":null}}"#.utf8))
        first.settle(unknown)
        let refreshed = TaskCommentRequestIdentity(taskId: "task", body: "old instruction", employeeId: "stable", sourceCommentId: "source", defaults: defaults)
        XCTAssertEqual(first.requestId, refreshed.requestId)
        let other = TaskCommentRequestIdentity(taskId: "task", body: "new instruction", employeeId: "stable", sourceCommentId: "source", defaults: defaults)
        XCTAssertNotEqual(first.requestId, other.requestId)
        other.settle(WandTaskComment(id: "plain", taskId: "task", authorName: "用户", body: "new instruction", createdAt: "now"))
        XCTAssertNil(defaults.string(forKey: other.key))
        let returned = TaskCommentRequestIdentity(taskId: "task", body: "old instruction", employeeId: "stable", sourceCommentId: "source", defaults: defaults)
        XCTAssertEqual(first.requestId, returned.requestId, "a newer accepted draft must not release the older unknown identity")
        XCTAssertTrue(unknown.dispatch!.deliveryUncertain)
    }
}

extension ClientFeedbackTests {
    @MainActor func testCommentsRefreshKeepsOlderPagesAndUpdatesFreshCopies() async {
        let store = TaskCommentsStore()
        let fresh = WandTaskComment(id: "new", taskId: "same", authorName: "用户", body: "new", createdAt: "2026-10-19T00:00:00Z")
        await store.load(taskId: "same") { _, _, _ in WandTaskCommentsPage(comments: [fresh], totalCount: 3, nextCursor: "cursor-1") }
        var requestedCursor: String?
        let old = WandTaskComment(id: "old", taskId: "same", authorName: "用户", body: "old", createdAt: "2026-10-18T00:00:00Z")
        await store.loadOlder(taskId: "same") { _, before, _ in
            requestedCursor = before
            return WandTaskCommentsPage(comments: [old], totalCount: 3, nextCursor: "cursor-2")
        }
        XCTAssertEqual(requestedCursor, "cursor-1")
        XCTAssertEqual(Set(store.comments.map(\.id)), ["new", "old"])
        let updated = WandTaskComment(id: "new", taskId: "same", authorName: "用户", body: "new", createdAt: fresh.createdAt,
            dispatch: WandTaskCommentDispatch(employeeId: "e", employeeName: "员工", state: "accepted", sessionId: "s", resultAnchor: nil, status: "running", error: nil))
        await store.load(taskId: "same") { _, _, _ in WandTaskCommentsPage(comments: [updated], totalCount: 4, nextCursor: "cursor-reset") }
        XCTAssertEqual(store.comments.count, 2)
        XCTAssertEqual(store.comments.first(where: { $0.id == "new" })?.dispatch?.status, "running")
        XCTAssertEqual(store.totalCount, 4)
        XCTAssertTrue(store.hasOlderPage, "refresh does not lose the loaded pagination position")
        XCTAssertEqual(store.nextCursor, "cursor-2", "the cursor for the next older page remains authoritative")
        let oldest = WandTaskComment(id: "oldest", taskId: "same", authorName: "用户", body: "oldest", createdAt: "2026-10-17T00:00:00Z")
        var nextCursor: String?
        await store.loadOlder(taskId: "same") { _, before, _ in
            nextCursor = before
            return WandTaskCommentsPage(comments: [oldest], totalCount: 4, nextCursor: nil)
        }
        XCTAssertEqual(nextCursor, "cursor-2")
        XCTAssertEqual(Set(store.comments.map(\.id)), ["new", "old", "oldest"])
    }

    @MainActor func testSameTaskReversePollingResponsesCannotReplaceNewerState() async {
        let store = TaskCommentsStore()
        var complete: CheckedContinuation<WandTaskCommentsPage, Error>?
        let slow = Task { await store.load(taskId: "same") { _, _, _ in try await withCheckedThrowingContinuation { complete = $0 } } }
        while complete == nil { await Task.yield() }
        let latest = WandTaskComment(id: "new", taskId: "same", authorName: "用户", body: "newer", createdAt: "now")
        await store.load(taskId: "same") { _, _, _ in WandTaskCommentsPage(comments: [latest], totalCount: 1, nextCursor: nil) }
        complete?.resume(returning: WandTaskCommentsPage(comments: [WandTaskComment(id: "old", taskId: "same", authorName: "用户", body: "stale", createdAt: "before")], totalCount: 1, nextCursor: nil))
        await slow.value
        XCTAssertEqual(store.comments.map(\.id), [latest.id])
    }
}
