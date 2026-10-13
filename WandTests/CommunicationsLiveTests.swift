import Foundation
import XCTest
@testable import Wand

/// Opt-in metadata-only acceptance against the installed service. No model input or knowledge route.
@MainActor
final class CommunicationsLiveTests: XCTestCase {
    func testInstalledServiceMetadataVirtualDMGroupAndRejectedEmptyInput() async throws {
        guard ProcessInfo.processInfo.environment["WAND_COMMUNICATIONS_LIVE"] == "1" else {
            throw XCTSkip("installed-service metadata acceptance is opt-in")
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let connection = try JSONSerialization.jsonObject(with: Data(contentsOf: home.appendingPathComponent(".wand/acceptance-connection.json"))) as! [String: Any]
        let config = try JSONSerialization.jsonObject(with: Data(contentsOf: home.appendingPathComponent(".wand/config.json"))) as! [String: Any]
        let hosts = ["0.0.0.0", "::", "[::]", "127.0.0.1", "localhost", "::1"]
        guard let host = config["host"] as? String, hosts.contains(host), let port = config["port"] as? Int else { throw NSError(domain: "Acceptance", code: 1) }
        let origin = URL(string: "\((config["https"] as? Bool) == true ? "https" : "http")://127.0.0.1:\(port)")!
        let raw = (connection["connectionCode"] as! String).filter { !$0.isWhitespace }
        var encoded = raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        let decoded = String(data: try XCTUnwrap(Data(base64Encoded: encoded)), encoding: .utf8)!
        let token = String(decoded.suffix(from: decoded.index(after: decoded.lastIndex(of: "#")!)))
        let configuration = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var login = URLRequest(url: origin.appendingPathComponent("api/login"))
        login.httpMethod = "POST"; login.setValue("application/json", forHTTPHeaderField: "Content-Type")
        login.httpBody = try JSONSerialization.data(withJSONObject: ["appToken": token])
        let (_, response) = try await session.data(for: login)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw NSError(domain: "Acceptance", code: 2) }
        let api = WandAPI(baseURL: origin, token: nil, session: session)
        var ownGroup: String?
        let groupName = "macOS-native-acceptance-" + UUID().uuidString
        do {
            let contacts = try await api.employeeContacts()
            let peer = try XCTUnwrap(contacts.first { $0.id == "e_wand_default" })
            let dm = try await api.conversation(id: peer.conversationID)
            XCTAssertEqual(dm.id, peer.conversationID)
            XCTAssertEqual(dm.peerEmployeeId, peer.id)
            let before = Set(try await api.conversations().map(\.id))
            let created = try await api.postConversation(path: "/api/conversations", body: [
                "requestId": UUID().uuidString,
                "group": ["name": groupName, "employeeIds": [peer.id], "leaderId": peer.id]
            ])
            XCTAssertEqual(created.state, "accepted")
            XCTAssertFalse(before.contains(created.conversationId))
            ownGroup = created.conversationId
            let group = try await api.conversation(id: created.conversationId)
            XCTAssertEqual(group.displayTitle, groupName)
            XCTAssertTrue(group.isGroup)
            XCTAssertEqual(group.members.count, 1)
            XCTAssertEqual(group.memberVersion, 1)
            let emptyID = UUID().uuidString
            do {
                _ = try await api.postConversation(path: "/api/conversations/\(api.percentEncodePathComponent(group.id))/messages",
                    body: ["requestId": emptyID, "input": "", "target": NSNull()])
                XCTFail("empty input must be rejected before model execution")
            } catch let error as WandAPI.APIError {
                guard case let .server(status, _) = error else { throw error }
                XCTAssertEqual(status, 400)
            }
            let rejected = try await api.conversationReceipt(requestID: emptyID)
            XCTAssertEqual(rejected.state, "rejected")
            XCTAssertEqual(rejected.conversationId, group.id)
            XCTAssertNil(rejected.sessionId)
            let afterRejected = try await api.conversation(id: group.id)
            XCTAssertEqual(afterRejected.turns.count, 0)
            // Cleanup is limited to the exact fresh metadata record created by this test.
            let cleanup = try await api.conversation(id: group.id)
            XCTAssertEqual(cleanup.displayTitle, groupName)
            _ = try await api.requestData(method: "DELETE", path: "/api/conversations/\(api.percentEncodePathComponent(group.id))")
            ownGroup = nil
            _ = try await api.requestData(method: "POST", path: "/api/logout")
        } catch {
            if let id = ownGroup, let record = try? await api.conversation(id: id), record.displayTitle == groupName {
                _ = try? await api.requestData(method: "DELETE", path: "/api/conversations/\(api.percentEncodePathComponent(id))")
            }
            _ = try? await api.requestData(method: "POST", path: "/api/logout")
            throw error
        }
    }
}
