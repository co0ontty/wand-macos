import Foundation
import XCTest
@testable import Wand

final class EmployeeImTests: XCTestCase {
    func testDecodeKeepsOnlyConfiguredFlagsForSecrets() throws {
        let data = Data(#"{"events":["task_started","task_failed"],"telegram":{"enabled":true,"chatId":"123","botTokenConfigured":true},"dingtalk":{"enabled":false,"webhookConfigured":true,"secretConfigured":false}}"#.utf8)
        let config = try JSONDecoder().decode(EmployeeImConfig.self, from: data)
        XCTAssertEqual(config.events, ["task_started", "task_failed"])
        XCTAssertEqual(config.telegram.chatId, "123")
        XCTAssertTrue(config.telegram.botTokenConfigured == true)
        XCTAssertNil(config.telegram.webhookConfigured)
        XCTAssertTrue(config.dingtalk.webhookConfigured == true)
        XCTAssertFalse(config.dingtalk.secretConfigured == true)
    }

    func testInputPreservesEmptySecretsAndEncodesExplicitClearAsNull() throws {
        let body = makeImChannelInput(
            enabled: true, chatId: "123",
            botToken: "", clearBotToken: false,
            webhook: "https://example.test/hook", clearWebhook: false,
            secret: "", clearSecret: true
        )
        XCTAssertEqual(body["enabled"] as? Bool, true)
        XCTAssertEqual(body["chatId"] as? String, "123")
        XCTAssertNil(body["botToken"])
        XCTAssertEqual(body["webhook"] as? String, "https://example.test/hook")
        XCTAssertTrue(body["secret"] is NSNull)
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: body).isEmpty, false)
    }

    func testDraftLoadsConfiguredFlagsWithoutSecretsAndKeepsChannelsIndependent() {
        let channel = EmployeeImChannel(enabled: true, chatId: "42",
                                        botTokenConfigured: true, webhookConfigured: nil, secretConfigured: nil)
        var telegram = EmployeeImChannelDraft(channel: channel)
        let dingtalk = EmployeeImChannelDraft()
        XCTAssertTrue(telegram.botTokenConfigured)
        XCTAssertEqual(telegram.chatId, "42")
        XCTAssertTrue(telegram.botToken.isEmpty)
        XCTAssertNotEqual(telegram, dingtalk)
        telegram.enabled = false
        XCTAssertFalse(telegram.enabled)
        XCTAssertFalse(dingtalk.enabled)
    }

    func testAllEventsAppearExactlyOnceInSharedChoices() {
        let events = employeeImEventGroups.flatMap(\.events)
        XCTAssertEqual(Set(events), Set(employeeImEvents.map(\.value)))
        XCTAssertEqual(events.count, Set(events).count)
        XCTAssertEqual(events.count, 13)
    }

    func testPrimaryAndMoreChoicesContainEveryEventOnce() {
        let choices = employeeImPrimaryEvents + employeeImMoreEventGroups.flatMap(\.events)
        XCTAssertEqual(employeeImPrimaryEvents.count, 6)
        XCTAssertEqual(choices.count, 13)
        XCTAssertEqual(Set(choices), Set(employeeImEvents.map(\.value)))
    }

    func testExplicitClearWinsOverTypedCredential() {
        let input = makeImChannelInput(enabled: false, chatId: nil,
            botToken: "typed", clearBotToken: true, webhook: "typed", clearWebhook: true,
            secret: "typed", clearSecret: true)
        XCTAssertTrue(input["botToken"] is NSNull)
        XCTAssertTrue(input["webhook"] is NSNull)
        XCTAssertTrue(input["secret"] is NSNull)
    }

    func testAPIUsesDirectEmployeeImRoutesAndBodies() async throws {
        let host = "employee-im-\(UUID().uuidString).test"
        var requests: [(String, String, [String: Any])] = []
        CommunicationsContractURLProtocol.register(host: host) { request in
            let method = request.httpMethod ?? ""
            let path = request.url?.path ?? ""
            var bodyData = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    bodyData.append(buffer, count: count)
                }
            }
            let body = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any] ?? [:]
            requests.append((method, request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.percentEncodedPath } ?? path, body))
            if method == "GET" {
                return Data(#"{"events":["task_started"],"telegram":{"enabled":false,"chatId":""},"dingtalk":{"enabled":false}}"#.utf8)
            }
            if path.hasSuffix("/im/test") { return Data(#"{"ok":true}"#.utf8) }
            return Data(#"{"events":["task_started"],"telegram":{"enabled":true,"chatId":"7"},"dingtalk":{"enabled":false}}"#.utf8)
        }
        defer { CommunicationsContractURLProtocol.unregister(host: host) }

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [CommunicationsContractURLProtocol.self]
        let api = WandAPI(baseURL: URL(string: "https://\(host)/")!, token: nil,
                          session: URLSession(configuration: sessionConfiguration))
        _ = try await api.employeeImConfig(id: "employee/one")
        _ = try await api.saveEmployeeImConfig(id: "employee/one", events: ["task_started"], telegram: ["enabled": true], dingtalk: ["enabled": false])
        let result = try await api.testEmployeeIm(id: "employee/one", provider: "telegram")

        XCTAssertTrue(result.ok)
        XCTAssertEqual(requests.map { $0.0 }, ["GET", "PUT", "POST"])
        XCTAssertEqual(requests[0].1, "/api/silicon-employees/employee%2Fone/im")
        XCTAssertEqual(requests[1].1, "/api/silicon-employees/employee%2Fone/im")
        XCTAssertEqual(requests[1].2["events"] as? [String], ["task_started"])
        XCTAssertNil((requests[1].2["telegram"] as? [String: Any])?["events"])
        XCTAssertEqual(requests[2].1, "/api/silicon-employees/employee%2Fone/im/test")
        XCTAssertEqual(requests[2].2["provider"] as? String, "telegram")
    }
}
