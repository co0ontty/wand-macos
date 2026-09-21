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

    func testFirstLaunchUsesComfortableDesktopSize() {
        let screen = CGRect(x: 0, y: 40, width: 1920, height: 1040)
        let frame = DesktopWindowGeometry.initialFrame(in: screen)
        XCTAssertEqual(frame.size, CGSize(width: 1600, height: 960))
        XCTAssertEqual(frame.midX, screen.midX)
        XCTAssertEqual(frame.midY, screen.midY)
    }

    func testUltrawideDisplayGetsLargerWorkspaceWithoutSpanningEntireScreen() {
        let screen = CGRect(x: 1920, y: -360, width: 3440, height: 1410)
        let frame = DesktopWindowGeometry.initialFrame(in: screen)
        XCTAssertEqual(frame.size, CGSize(width: 1920, height: 1120))
        XCTAssertTrue(screen.contains(frame))
        XCTAssertEqual(frame.midX, screen.midX)
    }

    func testFirstLaunchFitsLaptopVisibleAreaWithoutCoveringMenuBarOrDock() {
        let screen = CGRect(x: 0, y: 80, width: 1280, height: 695)
        let frame = DesktopWindowGeometry.initialFrame(in: screen)
        XCTAssertEqual(frame.size, CGSize(width: 1232, height: 647))
        XCTAssertTrue(screen.contains(frame))
    }

    func testRestoredWindowIsRecoveredFromDisconnectedDisplay() {
        let screen = CGRect(x: -1440, y: 80, width: 1440, height: 800)
        let oldFrame = CGRect(x: 2200, y: -300, width: 1600, height: 1000)
        XCTAssertEqual(DesktopWindowGeometry.fittedFrame(oldFrame, in: screen), screen)
        let compact = CGRect(x: -1400, y: 120, width: 960, height: 650)
        XCTAssertEqual(DesktopWindowGeometry.fittedFrame(compact, in: screen), compact)
    }

    func testExpiredLoginRequiresCredentialsButNetworkFailureCanRetry() {
        XCTAssertTrue(ShellConnectionState.failure(WandAPI.APIError.unauthorized).requiresAuthentication)
        XCTAssertFalse(ShellConnectionState.failure(WandAPI.APIError.network("offline")).requiresAuthentication)
        XCTAssertFalse(ShellConnectionState.failure(WandAPI.APIError.server(status: 403, message: "forbidden")).requiresAuthentication)
    }

    private func withStore(_ body: (ServerStore, UserDefaults) -> Void) {
        let suite = "WandDesktopLifecycleTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        body(ServerStore(defaults: defaults), defaults)
    }
}
