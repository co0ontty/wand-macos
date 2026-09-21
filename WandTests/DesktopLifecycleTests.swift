import Foundation
import XCTest
@testable import Wand

final class DesktopLifecycleTests: XCTestCase {
    func testSameServerReconnectReplacesConnectionIdentityAndRestoresNewCredentials() {
        withStore { store, defaults in
            let server = URL(string: "https://desktop.example.test")!
            store.connect(serverURL: server, token: "test-old-token")
            let previousConnection = store.connectionID
            store.connect(serverURL: server, token: "test-new-token")

            XCTAssertNotEqual(store.connectionID, previousConnection)
            XCTAssertEqual(store.serverURL, server)
            XCTAssertEqual(store.token, "test-new-token")
            let restored = ServerStore(defaults: defaults)
            XCTAssertEqual(restored.serverURL, server)
            XCTAssertEqual(restored.token, "test-new-token")
            XCTAssertNotEqual(restored.connectionID, store.connectionID)
        }
    }

    func testCookieReconnectClearsOldTokenAndDisconnectClearsSavedConnection() {
        withStore { store, defaults in
            let server = URL(string: "https://desktop.example.test")!
            store.connect(serverURL: server, token: "test-token")
            let authenticatedConnection = store.connectionID
            store.connect(serverURL: server, token: nil)
            XCTAssertNotEqual(store.connectionID, authenticatedConnection)
            XCTAssertNil(ServerStore(defaults: defaults).token)

            let cookieConnection = store.connectionID
            store.disconnect()
            XCTAssertNotEqual(store.connectionID, cookieConnection)
            XCTAssertNil(store.serverURL)
            XCTAssertNil(store.token)
            XCTAssertNil(ServerStore(defaults: defaults).serverURL)
        }
    }

    func testWebProcessFailureCannotDiscardFileDraftsEvenWithStaleReadyValue() {
        let error = NSError(domain: "WKErrorDomain", code: 2)
        XCTAssertEqual(DesktopToolCloseDecision.resolve(value: nil, error: error), .retry)
        XCTAssertEqual(DesktopToolCloseDecision.resolve(value: "ready", error: error), .retry)
    }

    func testInvalidCloseStateRequiresRetryInsteadOfClaimingNoDrafts() {
        for value: Any? in [nil, NSNull(), false, "", "unknown", ["status": "ready"]] {
            XCTAssertEqual(DesktopToolCloseDecision.resolve(value: value, error: nil), .retry)
        }
    }

    func testCloseStatePreservesSavingAndUnsavedWorkAndSupportsOlderServers() {
        XCTAssertEqual(DesktopToolCloseDecision.resolve(value: "busy", error: nil), .waitForSave)
        XCTAssertEqual(DesktopToolCloseDecision.resolve(value: "unsaved", error: nil), .confirmDiscard)
        XCTAssertEqual(DesktopToolCloseDecision.resolve(value: "ready", error: nil), .close)
        XCTAssertEqual(DesktopToolCloseDecision.resolve(value: "unsupported", error: nil), .close)
    }

    private func withStore(_ body: (ServerStore, UserDefaults) -> Void) {
        let suite = "WandDesktopLifecycleTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        body(ServerStore(defaults: defaults), defaults)
    }
}
