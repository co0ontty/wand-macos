import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import Wand

/// Opt-in metadata-only acceptance against the installed service. No model input or knowledge route.
@MainActor
final class CommunicationsLiveTests: XCTestCase {
    private func verifyNativeImagePaste(api: WandAPI, origin: URL, group: NativeConversation) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wand-paste-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "WandPasteLive.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suite)
        }
        let store = CommunicationsStore(api: api, serverURL: origin, defaults: defaults)
        store.select(group.id); await store.waitForDetailForTesting()
        let scope = ConversationScope(conversationID: group.id, target: nil)
        let owner = store.composer(for: scope)
        owner.editCwd(directory.path); owner.edit("未发送的图片草稿")
        let focus = ComposerFocusController(); focus.focus()
        let host = NSHostingView(rootView: ConversationComposerSurface(owner: owner, store: store, conversation: group, focus: focus))
        host.frame = NSRect(x: 0, y: 0, width: 740, height: 280)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded(); await Task.yield()
        func editor(in view: NSView) -> ComposerNSTextView? {
            if let found = view as? ComposerNSTextView { return found }
            return view.subviews.compactMap { editor(in: $0) }.first
        }
        let input = try XCTUnwrap(editor(in: host))
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let image = NSImage(size: NSSize(width: 8, height: 8))
        image.lockFocus(); NSColor.orange.setFill(); NSRect(x: 0, y: 0, width: 8, height: 8).fill(); image.unlockFocus()
        board.writeObjects([image])
        XCTAssertTrue(input.pasteAttachment(from: board))
        for _ in 0..<200 {
            if !owner.uploading { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertFalse(owner.uploading)
        let file = try XCTUnwrap(owner.attachments.first, "Installed service must accept the pasted image")
        XCTAssertEqual(owner.attachments.count, 1)
        XCTAssertEqual(file.mimeType, "image/png")
        XCTAssertEqual(owner.text, "未发送的图片草稿")
        XCTAssertTrue(file.savedPath.hasPrefix(directory.path + "/"))
        XCTAssertNotNil(NSImage(contentsOfFile: file.savedPath))
        let loaded = try await api.conversation(id: group.id)
        XCTAssertEqual(loaded.turns.count, 0, "Upload is not a model submission")
        host.layoutSubtreeIfNeeded()
        if let output = ProcessInfo.processInfo.environment["WAND_COMPOSER_PASTE_VISUAL_DIR"],
           let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: output).appendingPathComponent("installed-paste.png"))
        }
    }

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
            if ProcessInfo.processInfo.environment["WAND_COMPOSER_PASTE_LIVE"] == "1" {
                try await verifyNativeImagePaste(api: api, origin: origin, group: group)
            }
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
