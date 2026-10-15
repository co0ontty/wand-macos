import Combine
import Foundation
import XCTest
@testable import Wand

private final class UpdateChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
}

@MainActor
final class MacUpdateManagerTests: XCTestCase {
    private let testUpdatesDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("Wand-update-tests-\(UUID().uuidString)", isDirectory: true)

    override func tearDown() {
        try? FileManager.default.removeItem(at: testUpdatesDirectory)
        super.tearDown()
    }

    func testPermissionRecoveryChecksDomainsButNeverLoopback() {
        XCTAssertFalse(LocalNetworkPermission.shouldCheckForServer("localhost"))
        XCTAssertFalse(LocalNetworkPermission.shouldCheckForServer("127.0.0.2"))
        XCTAssertFalse(LocalNetworkPermission.shouldCheckForServer("::1"))
        XCTAssertFalse(LocalNetworkPermission.shouldCheckForServer(nil))
        if LocalNetworkPermission.isEnforced {
            XCTAssertTrue(LocalNetworkPermission.shouldCheckForServer("home.example.test"))
            XCTAssertTrue(LocalNetworkPermission.shouldCheckForServer("192.168.0.4"))
        }
        XCTAssertTrue(LocalNetworkPermission.isLikelyLanHost("192.168.0.4"))
        XCTAssertFalse(LocalNetworkPermission.isLikelyLanHost("home.example.test"))
    }

    func testInstallOrderTreatsSameBaseBetaAsNewerThanStable() {
        XCTAssertGreaterThan(
            MacUpdateManager.compareInstallOrder("4.38.0-beta.202608081200.10.gabcdef", "4.38.0"),
            0
        )
        XCTAssertGreaterThan(
            MacUpdateManager.compareInstallOrder("4.39.0", "4.38.0-beta.202608081200.10.gabcdef"),
            0
        )
        XCTAssertLessThan(MacUpdateManager.compareInstallOrder("4.38.0-rc.1", "4.38.0"), 0)
        XCTAssertEqual(MacUpdateManager.compareInstallOrder("4.38.0+123", "4.38.0+456"), 0)
    }

    func testStableCheckUsesStrictAssetNameAndAppliesManifest() async throws {
        let defaults = makeDefaults()
        defer { clear(defaults) }
        var requestedPaths: [String] = []
        let release = """
        {
          "tag_name": "v2.0.0",
          "html_url": "https://github.com/co0ontty/wand/releases/tag/v2.0.0",
          "draft": false,
          "prerelease": false,
          "published_at": "2026-08-08T00:00:00Z",
          "body": "changes",
          "assets": [
            {"name":"another.zip","browser_download_url":"https://example.test/another.zip","size":42},
            {"name":"wand-v2.0.0+202608081200.zip","browser_download_url":"https://example.test/wand.zip","size":42},
            {"name":"wand-v2.0.0.update.json","browser_download_url":"https://example.test/manifest","size":10}
          ]
        }
        """
        let manifest = """
        {
          "version":"2.0.0",
          "assets":[
            {"fileName":"wand-v2.0.0+202608081200.zip","size":42,"sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}
          ]
        }
        """
        let manager = MacUpdateManager(
            defaults: defaults, updatesDirectory: testUpdatesDirectory,
            currentVersion: { "1.0.0" },
            dataLoader: { request in
                requestedPaths.append(request.url?.absoluteString ?? "")
                let body = request.url?.host == "example.test" ? manifest : release
                return Self.response(for: request, body: body)
            }
        )

        let result = await manager.check(.manual)
        guard case let .updateAvailable(update) = result else {
            return XCTFail("expected updateAvailable, got \(String(describing: result))")
        }
        XCTAssertEqual(update.latestVersion, "2.0.0")
        XCTAssertEqual(update.preferredAsset?.name, "wand-v2.0.0+202608081200.zip")
        XCTAssertEqual(update.preferredAsset?.sha256, String(repeating: "a", count: 64))
        XCTAssertTrue(requestedPaths.first?.hasSuffix("/releases/latest") == true)
        XCTAssertEqual(requestedPaths.count, 2)
    }

    func testBetaUsesConnectedServerAndInvalidatesUpdateAfterSwitch() async {
        let defaults = makeDefaults()
        defer { clear(defaults) }
        defaults.set("beta", forKey: "wand.macUpdate.channel")
        let first = URL(string: "https://one.example.test:8443")!
        let second = URL(string: "https://two.example.test:8443")!
        var connected: URL? = first
        var requested: [URL] = []
        let metadata = """
        {
          "updateAvailable":true,"latestVersion":"4.38.0-debug.08081230",
          "downloadUrl":"/macos/update-download?fileName=wand-v4.38.0-debug.08081230.zip",
          "fileName":"wand-v4.38.0-debug.08081230.zip","size":42,
          "sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          "source":"local","channel":"beta"
        }
        """
        let manager = MacUpdateManager(
            defaults: defaults, updatesDirectory: testUpdatesDirectory,
            currentVersion: { "4.38.0" },
            dataLoader: { _ in XCTFail("Beta must not request GitHub"); throw URLError(.badURL) },
            betaDataLoader: { request in
                requested.append(request.url!)
                return Self.response(for: request, body: metadata)
            },
            connectedServer: { connected }
        )
        guard case let .updateAvailable(update) = await manager.check(.launch) else {
            return XCTFail("expected server beta update")
        }
        XCTAssertEqual(update.channel, .beta)
        XCTAssertEqual(update.latestVersion, "4.38.0-debug.08081230")
        XCTAssertEqual(update.preferredAsset?.downloadURL.host, first.host)
        XCTAssertEqual(update.preferredAsset?.sha256, String(repeating: "a", count: 64))
        XCTAssertEqual(requested[0].path, "/api/macos-app-update")
        let throttled = await manager.check(.launch)
        XCTAssertNil(throttled) // 同一服务器的启动检查被防抖

        connected = second
        XCTAssertNotNil(manager.installAvailableUpdate()) // 旧服务器包不得跨连接安装
        _ = await manager.check(.launch) // 切换服务器后不得用旧检查时间防抖
        XCTAssertEqual(requested.count, 2)
        XCTAssertEqual(requested[1].host, second.host)
        XCTAssertEqual(manager.availableUpdate?.preferredAsset?.downloadURL.host, second.host)
        connected = nil
        guard case .failed = await manager.check(.manual) else {
            return XCTFail("disconnected beta must fail rather than fall back to GitHub")
        }
    }

    func testBetaRejectsCrossOriginAndMissingIntegrity() async {
        let defaults = makeDefaults()
        defer { clear(defaults) }
        defaults.set("beta", forKey: "wand.macUpdate.channel")
        let server = URL(string: "http://127.0.0.1:8443")!
        var link = "https://evil.example.test/macos/update-download?fileName=wand-v2.0.0.zip"
        let manager = MacUpdateManager(
            defaults: defaults, updatesDirectory: testUpdatesDirectory,
            currentVersion: { "1.0.0" },
            betaDataLoader: { request in
                let body = """
                {"updateAvailable":true,"latestVersion":"2.0.0","fileName":"wand-v2.0.0.zip",
                "downloadUrl":"\(link)","size":20,"sha256":null,"source":"local","channel":"beta"}
                """
                return Self.response(for: request, body: body)
            },
            connectedServer: { server }
        )
        guard case .failed = await manager.check(.manual) else { return XCTFail("foreign URL must fail") }
        link = "/macos/update-download?fileName=wand-v2.0.0.zip"
        guard case .failed = await manager.check(.manual) else { return XCTFail("missing hash must fail") }
    }

    func testCustomBetaAddressIsNormalizedPersistedAndDoesNotChangeStable() async throws {
        let defaults = makeDefaults()
        defer { clear(defaults) }
        let connected = URL(string: "https://connected.example.test:8443")!
        var stableRequests = 0, betaRequests = 0
        let manager = MacUpdateManager(
            defaults: defaults, updatesDirectory: testUpdatesDirectory,
            currentVersion: { "1.0.0" },
            dataLoader: { request in
                stableRequests += 1
                XCTAssertEqual(request.url?.host, "api.github.com")
                return Self.response(for: request, body: Self.installableRelease)
            },
            betaDataLoader: { request in betaRequests += 1; return Self.response(for: request, body: Self.installableBeta) },
            connectedServer: { connected }
        )
        XCTAssertEqual(manager.betaServerURL, connected)
        XCTAssertFalse(manager.betaUsesCustomServer)
        let saved = try await manager.setBetaServerAddress("  HTTPS://Updates.Example.Test:443/\n")
        XCTAssertNil(saved)
        XCTAssertEqual(manager.betaServerAddress, "https://updates.example.test")
        XCTAssertEqual(manager.betaServerURL?.host, "updates.example.test")
        XCTAssertEqual(stableRequests, 0)
        XCTAssertEqual(betaRequests, 0)
        _ = await manager.check(.manual)
        XCTAssertEqual(stableRequests, 1)
        XCTAssertEqual(betaRequests, 0)
        XCTAssertEqual(manager.availableUpdate?.channel, .stable)

        let restored = MacUpdateManager(defaults: defaults, updatesDirectory: testUpdatesDirectory, connectedServer: { connected })
        XCTAssertEqual(restored.betaServerAddress, manager.betaServerAddress)
        XCTAssertTrue(restored.betaUsesCustomServer)
        _ = try await restored.setBetaServerAddress(" \n ")
        XCTAssertEqual(restored.betaServerURL, connected)
        XCTAssertFalse(restored.betaUsesCustomServer)
        XCTAssertNil(defaults.object(forKey: "wand.macUpdate.beta.customServerURL"))
    }

    func testBetaAddressRejectsInvalidInputBeforeChangingTheSource() async throws {
        let defaults = makeDefaults()
        defer { clear(defaults) }
        let manager = MacUpdateManager(defaults: defaults, updatesDirectory: testUpdatesDirectory)
        _ = try await manager.setBetaServerAddress("https://updates.example.test:8443")
        for address in [
            "updates.example.test", "file:///tmp/update", "ftp://updates.example.test",
            "https://user:password@updates.example.test", "https://@updates.example.test",
            "https://updates.example.test/path", "https://updates.example.test?token=private",
            "https://updates.example.test#fragment", "https://updates.example.test:0",
            "http://updates.example.test:65536", "https://up dates.example.test"
        ] {
            do {
                _ = try await manager.setBetaServerAddress(address)
                XCTFail("Expected invalid update server address to be rejected")
            } catch {
                XCTAssertFalse(error.localizedDescription.contains(address), "Validation must not echo potentially sensitive input")
            }
            XCTAssertEqual(manager.betaServerAddress, "https://updates.example.test:8443")
        }
        XCTAssertEqual(try MacUpdateManager.normalizedBetaServerAddress("http://[::1]:8181/"), "http://[::1]:8181")
    }

    func testCustomBetaUsesOnlySelectedServerWithoutConnectionOrFallback() async throws {
        let defaults = makeDefaults()
        defer { clear(defaults) }
        defaults.set("beta", forKey: "wand.macUpdate.channel")
        var connected: URL? = URL(string: "https://connected.example.test")!
        var requested: [URLRequest] = []
        var fails = false
        let manager = MacUpdateManager(
            defaults: defaults, updatesDirectory: testUpdatesDirectory,
            currentVersion: { "1.0.0" },
            dataLoader: { _ in XCTFail("Custom Beta must never request GitHub"); throw URLError(.badURL) },
            betaDataLoader: { request in
                requested.append(request)
                if fails { throw URLError(.notConnectedToInternet) }
                return Self.response(for: request, body: Self.installableBeta)
            },
            connectedServer: { connected }
        )
        _ = try await manager.setBetaServerAddress("http://custom.example.test:8181")
        XCTAssertEqual(manager.availableUpdate?.releaseURL, manager.betaServerURL)
        XCTAssertEqual(manager.availableUpdate?.preferredAsset?.downloadURL.host, "custom.example.test")
        XCTAssertEqual(manager.availableUpdate?.preferredAsset?.sha256, String(repeating: "a", count: 64))
        XCTAssertEqual(requested.count, 1)
        XCTAssertFalse(requested[0].httpShouldHandleCookies)
        XCTAssertNil(requested[0].value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(requested[0].value(forHTTPHeaderField: "Authorization"))
        connected = nil
        let throttled = await manager.check(.launch)
        XCTAssertNil(throttled, "Disconnected chat must not invalidate a custom source or its check throttle")
        XCTAssertEqual(requested.count, 1)
        fails = true
        guard case .failed = await manager.check(.manual) else { return XCTFail("Custom source failure must surface") }
        XCTAssertTrue(requested.allSatisfy { $0.url?.host == "custom.example.test" })
        XCTAssertEqual(manager.betaServerAddress, "http://custom.example.test:8181")
        connected = URL(string: "https://connected.example.test")!
        fails = false
        _ = try await manager.setBetaServerAddress("")
        XCTAssertEqual(requested.last?.url?.host, "connected.example.test")
        XCTAssertEqual(manager.availableUpdate?.releaseURL, connected)
    }

    func testInvalidSavedCustomBetaAddressNeverFallsBackToConnectedServer() async {
        let defaults = makeDefaults()
        defer { clear(defaults) }
        defaults.set("beta", forKey: "wand.macUpdate.channel")
        defaults.set("file:///tmp/old-update", forKey: "wand.macUpdate.beta.customServerURL")
        let manager = MacUpdateManager(
            defaults: defaults, updatesDirectory: testUpdatesDirectory,
            betaDataLoader: { _ in XCTFail("Invalid custom source must not fall back"); throw URLError(.badURL) },
            connectedServer: { URL(string: "https://connected.example.test") }
        )
        XCTAssertTrue(manager.betaUsesCustomServer)
        XCTAssertNil(manager.betaServerURL)
        guard case .failed = await manager.check(.manual) else { return XCTFail("Invalid persisted source must surface") }
    }

    func testCustomSourceChangeIgnoresLateMetadataAndClearsOldCheckThrottle() async throws {
        let defaults = makeDefaults()
        defer { clear(defaults) }
        defaults.set("beta", forKey: "wand.macUpdate.channel")
        let firstStarted = expectation(description: "first source check started")
        var continuation: CheckedContinuation<Void, Never>?
        var requested: [String] = []
        let manager = MacUpdateManager(
            defaults: defaults, updatesDirectory: testUpdatesDirectory,
            currentVersion: { "1.0.0" },
            betaDataLoader: { request in
                requested.append(request.url!.host!)
                if request.url?.host == "first.example.test" {
                    await withCheckedContinuation { continuation = $0; firstStarted.fulfill() }
                }
                return Self.response(for: request, body: Self.installableBeta)
            },
            connectedServer: { nil }
        )
        let first = Task { try await manager.setBetaServerAddress("https://first.example.test") }
        await fulfillment(of: [firstStarted], timeout: 2)
        _ = try await manager.setBetaServerAddress("https://second.example.test")
        let secondState = manager.state
        continuation?.resume()
        let staleResult = try await first.value
        XCTAssertNil(staleResult, "Superseded checks must not surface a reminder for the old source")
        XCTAssertEqual(manager.state, secondState)
        XCTAssertEqual(manager.availableUpdate?.releaseURL.host, "second.example.test")
        XCTAssertEqual(defaults.string(forKey: "wand.macUpdate.beta.serverURL"), "https://second.example.test")
        XCTAssertEqual(requested, ["first.example.test", "second.example.test"])
    }

    func testCustomSourceKeepsDownloadAcrossChatDisconnectAndRevokesItOnSourceChange() async throws {
        let defaults = makeDefaults()
        defer { clear(defaults) }
        defaults.set("beta", forKey: "wand.macUpdate.channel")
        var connected: URL? = URL(string: "https://connected.example.test")
        var callbacks: [UpdateInstaller.ProgressHandler] = []
        var cancellations = 0
        let manager = MacUpdateManager(
            defaults: defaults, updatesDirectory: testUpdatesDirectory,
            currentVersion: { "1.0.0" },
            betaDataLoader: { request in Self.response(for: request, body: Self.installableBeta) },
            connectedServer: { connected },
            startInstallation: { _, callback in callbacks.append(callback) },
            cancelInstallation: { cancellations += 1 }
        )
        _ = try await manager.setBetaServerAddress("https://first.example.test")
        XCTAssertNil(manager.installAvailableUpdate())
        connected = nil
        _ = await manager.check(.channelChanged)
        XCTAssertTrue(manager.isInstalling)
        XCTAssertEqual(cancellations, 0)
        _ = try await manager.setBetaServerAddress("https://second.example.test")
        XCTAssertEqual(cancellations, 1)
        XCTAssertEqual(manager.availableUpdate?.releaseURL.host, "second.example.test")
        let state = manager.state
        let staleApp = testUpdatesDirectory.appendingPathComponent("staging-old-custom/Wand.app")
        try FileManager.default.createDirectory(at: staleApp, withIntermediateDirectories: true)
        callbacks[0](.readyToRelaunch(stagedAppPath: staleApp.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleApp.path))
        XCTAssertNil(manager.pendingInstall)
        XCTAssertEqual(manager.state, state)
    }

    func testPreparedInstallRejectsCustomSourceEditsWithoutLosingTransaction() async throws {
        let defaults = makeDefaults()
        defer { clear(defaults) }
        let manager = MacUpdateManager(defaults: defaults, updatesDirectory: testUpdatesDirectory)
        _ = try await manager.setBetaServerAddress("https://first.example.test")
        let app = testUpdatesDirectory.appendingPathComponent("staging-pending-source/Wand.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        manager.handleInstallerStage(.readyToRelaunch(stagedAppPath: app.path), update: makeUpdate(version: "99.0.0"))
        let pending = try XCTUnwrap(manager.pendingInstall)
        do {
            _ = try await manager.setBetaServerAddress("https://second.example.test")
            XCTFail("Prepared updates must keep their source and transaction")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("更新包已准备好"))
        }
        XCTAssertEqual(manager.pendingInstall, pending)
        XCTAssertEqual(manager.betaServerAddress, "https://first.example.test")
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.path))
    }

    func testBetaMetadataAndDownloadsRejectRedirectsAndCredentialsOffline() throws {
        let configuration = BetaUpdateSession.configuration()
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertNil(configuration.urlCache)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.httpCookieAcceptPolicy, .never)
        let source = URL(string: "https://updates.example.test:8443")!
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: source)
        let metadata = BetaUpdateSession(serverURL: source)
        let download = UpdateDownloadDelegate(fileExtension: "zip", trustedBetaServer: source, onProgress: { _, _ in }, onFinish: { _ in })
        for target in [source, URL(string: "https://foreign.example.test")!] {
            let redirect = HTTPURLResponse(url: source, statusCode: 302, httpVersion: nil, headerFields: ["Location": target.absoluteString])!
            let request = URLRequest(url: target)
            metadata.urlSession(session, task: task, willPerformHTTPRedirection: redirect, newRequest: request) { XCTAssertNil($0) }
            download.urlSession(session, task: task, willPerformHTTPRedirection: redirect, newRequest: request) { XCTAssertNil($0) }
            let challenge = URLAuthenticationChallenge(
                protectionSpace: URLProtectionSpace(host: target.host!, port: target.port ?? 443, protocol: "https", realm: nil, authenticationMethod: NSURLAuthenticationMethodHTTPBasic),
                proposedCredential: nil, previousFailureCount: 0, failureResponse: nil, error: nil,
                sender: UpdateChallengeSender()
            )
            metadata.urlSession(session, task: task, didReceive: challenge) { disposition, credential in
                XCTAssertEqual(disposition, .cancelAuthenticationChallenge)
                XCTAssertNil(credential)
            }
            download.urlSession(session, task: task, didReceive: challenge) { disposition, credential in
                XCTAssertEqual(disposition, .cancelAuthenticationChallenge)
                XCTAssertNil(credential)
            }
        }
    }

    private static let installableBeta = """
    {"updateAvailable":true,"latestVersion":"2.0.0","source":"local","channel":"beta",
     "fileName":"wand-v2.0.0.zip","downloadUrl":"/macos/update-download?fileName=wand-v2.0.0.zip",
     "size":42,"sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}
    """

    func testFailedLaunchCheckDoesNotThrottleRetry() async {
        let defaults = makeDefaults()
        defer { clear(defaults) }
        var requests = 0
        let manager = MacUpdateManager(
            defaults: defaults, updatesDirectory: testUpdatesDirectory,
            currentVersion: { "1.0.0" },
            dataLoader: { _ in
                requests += 1
                throw URLError(.notConnectedToInternet)
            }
        )

        _ = await manager.check(.launch)
        _ = await manager.check(.launch)
        XCTAssertEqual(requests, 2)
        XCTAssertNil(manager.lastSuccessfulCheck)
    }

    func testSuccessfulLaunchCheckThrottlesButManualCheckBypassesThrottle() async {
        let defaults = makeDefaults()
        defer { clear(defaults) }
        var requests = 0
        let release = """
        {
          "tag_name":"v1.0.0",
          "html_url":"https://github.com/co0ontty/wand/releases/tag/v1.0.0",
          "draft":false,
          "prerelease":false,
          "published_at":"2026-08-08T00:00:00Z",
          "body":null,
          "assets":[]
        }
        """
        let manager = MacUpdateManager(
            defaults: defaults, updatesDirectory: testUpdatesDirectory,
            currentVersion: { "1.0.0" },
            dataLoader: { request in
                requests += 1
                return Self.response(for: request, body: release)
            }
        )

        _ = await manager.check(.launch)
        let throttledResult = await manager.check(.launch)
        XCTAssertNil(throttledResult)
        _ = await manager.check(.manual)
        XCTAssertEqual(requests, 2)
    }

    func testManualCheckCannotOverwriteDownloadProgress() async {
        let defaults = makeDefaults()
        defer { clear(defaults) }
        var requests = 0
        let manager = MacUpdateManager(
            defaults: defaults, updatesDirectory: testUpdatesDirectory,
            currentVersion: { "1.0.0" },
            dataLoader: { _ in requests += 1; throw URLError(.notConnectedToInternet) }
        )
        let update = makeUpdate(version: "2.0.0")
        manager.handleInstallerStage(.downloading(received: 10, total: 42), update: update)
        let before = manager.state
        let result = await manager.check(.manual)
        XCTAssertNil(result)
        XCTAssertEqual(manager.state, before)
        XCTAssertEqual(requests, 0)
    }

    func testOldChannelInstallerStageCannotCreatePendingInstall() async throws {
        let defaults = makeDefaults()
        defer { clear(defaults) }
        let server = URL(string: "http://127.0.0.1:8181")!
        let manager = MacUpdateManager(
            defaults: defaults, updatesDirectory: testUpdatesDirectory,
            currentVersion: { "1.0.0" },
            betaDataLoader: { request in
                Self.response(for: request, body: """
                {"updateAvailable":false,"latestVersion":"1.0.0","source":"local","channel":"beta"}
                """)
            },
            connectedServer: { server }
        )
        let oldUpdate = makeUpdate(version: "2.0.0")
        manager.handleInstallerStage(.downloading(received: 10, total: 42), update: oldUpdate)
        _ = await manager.setChannel(.beta)
        let stagedApp = testUpdatesDirectory.appendingPathComponent("staging-late/Wand.app")
        try FileManager.default.createDirectory(at: stagedApp, withIntermediateDirectories: true)
        manager.handleInstallerStage(.readyToRelaunch(stagedAppPath: stagedApp.path), update: oldUpdate)
        XCTAssertNil(manager.pendingInstall)
        XCTAssertNil(defaults.data(forKey: "wand.macUpdate.pendingInstall"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedApp.path))
    }

    func testReminderDeferralIsScopedToVersion() {
        let defaults = makeDefaults()
        defer { clear(defaults) }
        var currentDate = Date(timeIntervalSince1970: 1_000)
        let manager = MacUpdateManager(
            defaults: defaults, updatesDirectory: testUpdatesDirectory,
            now: { currentDate },
            currentVersion: { "1.0.0" }
        )
        let first = makeUpdate(version: "2.0.0")
        let second = makeUpdate(version: "2.1.0")

        XCTAssertTrue(manager.shouldPresentReminder(for: first))
        manager.deferReminder(for: first)
        XCTAssertFalse(manager.shouldPresentReminder(for: first))
        XCTAssertTrue(manager.shouldPresentReminder(for: second))
        currentDate = currentDate.addingTimeInterval(24 * 60 * 60)
        XCTAssertTrue(manager.shouldPresentReminder(for: first))
    }

    func testReadyNotificationCanRelaunchAfterStateIsCommitted() async throws {
        let defaults = makeDefaults()
        defer { clear(defaults) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let stagedApp = root.appendingPathComponent("staging-test/Wand.app", isDirectory: true)
        try FileManager.default.createDirectory(at: stagedApp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let manager = MacUpdateManager(defaults: defaults, updatesDirectory: testUpdatesDirectory, currentVersion: { "1.0.0" })
        let ready = expectation(description: "ready notification after state commit")
        let observation = manager.committedStates.sink { state in
            guard case let .readyToRelaunch(pending) = state else { return }
            XCTAssertEqual(manager.pendingInstall, pending)
            XCTAssertNotNil(defaults.data(forKey: "wand.macUpdate.pendingInstall"))
            guard case let .failure(error) = manager.relaunchPendingUpdate() else {
                return XCTFail("incomplete staged app must not be installed")
            }
            XCTAssertEqual((error as NSError).domain, "Wand.UpdateInstaller")
            ready.fulfill()
        }

        manager.handleInstallerStage(.readyToRelaunch(stagedAppPath: stagedApp.path), update: makeUpdate(version: "2.0.0"))
        await fulfillment(of: [ready], timeout: 5)
        observation.cancel()
    }

    func testPendingInstallAcknowledgementClearsTransaction() throws {
        let defaults = makeDefaults()
        defer { clear(defaults) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let staging = root.appendingPathComponent("staging-test", isDirectory: true)
        let stagedApp = staging.appendingPathComponent("Wand.app", isDirectory: true)
        try FileManager.default.createDirectory(at: stagedApp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let pending = MacUpdateManager.PendingInstall(
            transactionID: "transaction-1",
            version: "2.0.0",
            stagedAppPath: stagedApp.path,
            releaseURL: URL(string: "https://example.test/release")!,
            preparedAt: Date()
        )
        defaults.set(try JSONEncoder().encode(pending), forKey: "wand.macUpdate.pendingInstall")
        let manager = MacUpdateManager(defaults: defaults, updatesDirectory: testUpdatesDirectory, currentVersion: { "2.0.0" })
        let ack = staging.appendingPathComponent(".wand-update-ack")

        XCTAssertFalse(manager.completeLaunchedUpdateIfNeeded(arguments: ["Wand"]))
        XCTAssertFalse(manager.completeLaunchedUpdateIfNeeded(arguments: [
            "Wand", "--wand-update-token", "wrong-token", "--wand-update-ack", ack.path,
        ]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ack.path))
        XCTAssertTrue(manager.completeLaunchedUpdateIfNeeded(arguments: [
            "Wand", "--wand-update-token", "transaction-1", "--wand-update-ack", ack.path,
        ]))

        XCTAssertEqual(try String(contentsOf: ack, encoding: .utf8), "ok\n")
        XCTAssertNil(defaults.data(forKey: "wand.macUpdate.pendingInstall"))
    }

    func testHelperRestoresBackupWhenReplacementCannotLaunch() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Wand update quote's \(UUID().uuidString)", isDirectory: true)
        let staging = root.appendingPathComponent("staging-test", isDirectory: true)
        let stagedApp = staging.appendingPathComponent("Wand.app", isDirectory: true)
        let installedParent = root.appendingPathComponent("Installed", isDirectory: true)
        let destination = installedParent.appendingPathComponent("Wand.app", isDirectory: true)
        try FileManager.default.createDirectory(at: stagedApp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try "new".write(to: stagedApp.appendingPathComponent("new-marker"), atomically: true, encoding: .utf8)
        try "old".write(to: destination.appendingPathComponent("old-marker"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let scriptPath = try UpdateInstaller.shared.makeHelperScriptForTesting(
            parentPID: Int32.max,
            stagedAppPath: stagedApp.path,
            destinationAppPath: destination.path,
            transactionID: "test-transaction",
            expectedVersion: "2.0.0",
            logPath: root.appendingPathComponent("helper.log").path
        )
        let helper = try String(contentsOfFile: scriptPath, encoding: .utf8)
        XCTAssertFalse(helper.contains("/usr/bin/pkill"), "回滚不能误杀其他路径运行的 Wand")
        XCTAssertTrue(helper.contains("OPEN_COMMAND='/usr/bin/open'"))
        XCTAssertTrue(helper.contains("\"$OPEN_COMMAND\" -n \"$DEST\""))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptPath]
        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 14)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("old-marker").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("new-marker").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        let result = try String(contentsOf: root.appendingPathComponent("last-result.txt"), encoding: .utf8)
        XCTAssertTrue(result.contains("已恢复旧版"))
    }

    func testCancelAndRestartRejectCallbacksFromThePreviousInstall() async throws {
        let defaults = makeDefaults()
        defer { clear(defaults) }
        var callbacks: [UpdateInstaller.ProgressHandler] = []
        var cancellations = 0
        let manager = MacUpdateManager(
            defaults: defaults, updatesDirectory: testUpdatesDirectory,
            currentVersion: { "1.0.0" },
            dataLoader: { request in Self.response(for: request, body: Self.installableRelease) },
            startInstallation: { _, callback in callbacks.append(callback) },
            cancelInstallation: { cancellations += 1 }
        )
        _ = await manager.check(.manual)
        XCTAssertNil(manager.installAvailableUpdate())
        XCTAssertNotNil(manager.installAvailableUpdate(), "同一事务不能重复启动")
        XCTAssertEqual(callbacks.count, 1)
        manager.cancelInstall()
        XCTAssertEqual(cancellations, 1)
        let cancelledState = manager.state
        callbacks[0](.downloading(received: 20, total: 42))
        XCTAssertEqual(manager.state, cancelledState)
        let lateApp = testUpdatesDirectory.appendingPathComponent("staging-cancelled/Wand.app")
        try FileManager.default.createDirectory(at: lateApp, withIntermediateDirectories: true)
        callbacks[0](.readyToRelaunch(stagedAppPath: lateApp.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: lateApp.path))
        XCTAssertNil(manager.pendingInstall)

        XCTAssertNil(manager.installAvailableUpdate())
        XCTAssertEqual(callbacks.count, 2)
        callbacks[0](.failed("迟到失败"))
        XCTAssertTrue(manager.isInstalling)
        let app = testUpdatesDirectory.appendingPathComponent("staging-current/Wand.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        callbacks[1](.readyToRelaunch(stagedAppPath: app.path))
        let pending = try XCTUnwrap(manager.pendingInstall)
        XCTAssertEqual(pending.stagedAppPath, app.path)
        let result = await manager.setChannel(.beta)
        XCTAssertNil(result, "已校验的待重启事务不能被通道切换覆盖")
        XCTAssertEqual(manager.pendingInstall, pending)
        XCTAssertEqual(manager.channel, .stable)
    }

    func testServerSwitchAndDisconnectRevokeTheDownloadingTransaction() async throws {
        let defaults = makeDefaults()
        defer { clear(defaults) }
        defaults.set("beta", forKey: "wand.macUpdate.channel")
        var connected: URL? = URL(string: "http://first.example.test:8181")!
        let second = URL(string: "http://second.example.test:8181")!
        var callbacks: [UpdateInstaller.ProgressHandler] = []
        var cancellations = 0
        let manager = MacUpdateManager(
            defaults: defaults, updatesDirectory: testUpdatesDirectory,
            currentVersion: { "1.0.0" },
            dataLoader: { _ in XCTFail("Beta 不允许切到 GitHub"); throw URLError(.badURL) },
            betaDataLoader: { request in Self.response(for: request, body: """
            {"updateAvailable":true,"latestVersion":"2.0.0","source":"local","channel":"beta",
             "fileName":"wand-v2.0.0.zip","downloadUrl":"/macos/update-download?fileName=wand-v2.0.0.zip",
             "size":42,"sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}
            """) },
            connectedServer: { connected },
            startInstallation: { _, callback in callbacks.append(callback) },
            cancelInstallation: { cancellations += 1 }
        )
        _ = await manager.check(.manual)
        XCTAssertNil(manager.installAvailableUpdate())
        connected = second
        _ = await manager.check(.channelChanged)
        XCTAssertEqual(cancellations, 1)
        XCTAssertEqual(manager.availableUpdate?.preferredAsset?.downloadURL.host, second.host)
        let currentState = manager.state
        let lateApp = testUpdatesDirectory.appendingPathComponent("staging-old-server/Wand.app")
        try FileManager.default.createDirectory(at: lateApp, withIntermediateDirectories: true)
        callbacks[0](.readyToRelaunch(stagedAppPath: lateApp.path))
        XCTAssertEqual(manager.state, currentState)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lateApp.path))
        XCTAssertNil(manager.pendingInstall)

        XCTAssertNil(manager.installAvailableUpdate())
        connected = nil
        _ = await manager.check(.channelChanged)
        XCTAssertEqual(cancellations, 2)
        XCTAssertFalse(manager.isInstalling)
        XCTAssertNil(manager.availableUpdate)
        XCTAssertNotNil(manager.lastError)
        callbacks[1](.failed("已断开的服务器"))
        XCTAssertNil(manager.availableUpdate)
    }

    func testFailedTransactionWriteDoesNotPersistAGhostPendingInstall() {
        let defaults = makeDefaults()
        defer { clear(defaults) }
        let manager = MacUpdateManager(defaults: defaults, updatesDirectory: testUpdatesDirectory)
        manager.handleInstallerStage(
            .readyToRelaunch(stagedAppPath: testUpdatesDirectory.appendingPathComponent("staging-missing/Wand.app").path),
            update: makeUpdate(version: "2.0.0")
        )
        XCTAssertNil(manager.pendingInstall)
        XCTAssertNil(defaults.data(forKey: "wand.macUpdate.pendingInstall"))
        XCTAssertNotNil(manager.lastError)
    }

    func testHelperCompletesReplacementOnlyAfterAcknowledgement() throws {
        try assertHelperTransaction(acknowledges: true, expectedStatus: 0)
    }

    func testHelperRollsBackWhenLaunchedAppDoesNotAcknowledge() throws {
        try assertHelperTransaction(acknowledges: false, expectedStatus: 15)
    }

    private func assertHelperTransaction(acknowledges: Bool, expectedStatus: Int32) throws {
        let root = testUpdatesDirectory.appendingPathComponent("quote's helper \(UUID().uuidString)")
        let staging = root.appendingPathComponent("staging-test")
        let staged = staging.appendingPathComponent("Wand.app")
        let installed = root.appendingPathComponent("Installed")
        let destination = installed.appendingPathComponent("Wand.app")
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try "new".write(to: staged.appendingPathComponent("new-marker"), atomically: true, encoding: .utf8)
        try "old".write(to: destination.appendingPathComponent("old-marker"), atomically: true, encoding: .utf8)
        let launcher = root.appendingPathComponent("isolated-launcher.sh")
        let script = """
        #!/bin/bash
        set -eu
        if [ "$1" != '-n' ]; then exit 0; fi
        /usr/bin/printf '%s\\n' "$@" > "$2.launch-args"
        shift 3
        [ "$1" = '--wand-update-token' ]
        [ "$2" = 'test-transaction' ]
        [ "$3" = '--wand-update-ack' ]
        \(acknowledges ? "/usr/bin/printf 'ok\\n' > \"$4\"" : "true")
        """
        try script.write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcher.path)
        let helper = try UpdateInstaller.shared.makeHelperScriptForTesting(
            parentPID: Int32.max, stagedAppPath: staged.path, destinationAppPath: destination.path,
            transactionID: "test-transaction", expectedVersion: "2.0.0",
            logPath: root.appendingPathComponent("helper.log").path,
            launchCommandPath: launcher.path, acknowledgementAttempts: 2
        )
        defer { try? FileManager.default.removeItem(atPath: helper) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [helper]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, expectedStatus)
        XCTAssertEqual(FileManager.default.fileExists(atPath: destination.appendingPathComponent("new-marker").path), acknowledges)
        XCTAssertEqual(FileManager.default.fileExists(atPath: destination.appendingPathComponent("old-marker").path), !acknowledges)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: helper))
        let siblings = try FileManager.default.contentsOfDirectory(atPath: installed.path)
        XCTAssertEqual(siblings.filter { $0.contains("wand-update-backup") }, [])
        let arguments = try String(contentsOfFile: destination.path + ".launch-args", encoding: .utf8)
        XCTAssertTrue(arguments.contains("--wand-update-token\ntest-transaction\n--wand-update-ack\n"))
        XCTAssertEqual(FileManager.default.fileExists(atPath: root.appendingPathComponent("last-result.txt").path), !acknowledges)
    }

    nonisolated private static let installableRelease = """
    {"tag_name":"v2.0.0","html_url":"https://example.test/release","draft":false,"prerelease":false,
     "assets":[{"name":"wand-v2.0.0.zip","browser_download_url":"https://example.test/wand.zip","size":42}]}
    """

    func testSweepRemovesOrphanedStagingButKeepsPendingAndUnrelatedEntries() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let updates = root.appendingPathComponent("Updates", isDirectory: true)
        let orphan = updates.appendingPathComponent("staging-\(UUID().uuidString)", isDirectory: true)
        let keep = updates.appendingPathComponent("staging-\(UUID().uuidString)", isDirectory: true)
        let keepApp = keep.appendingPathComponent("Wand.app", isDirectory: true)
        let unrelated = updates.appendingPathComponent("not-staging", isDirectory: true)
        let marker = updates.appendingPathComponent("last-result.txt")
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: keepApp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        try "ok".write(to: marker, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        MacUpdateManager.sweepOrphanedStagingDirectories(
            in: updates,
            keepingStagedAppPath: keepApp.path
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: keep.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "WandTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(suite, forKey: "WandTests.suiteName")
        return defaults
    }

    private func clear(_ defaults: UserDefaults) {
        guard let suite = defaults.string(forKey: "WandTests.suiteName") else { return }
        defaults.removePersistentDomain(forName: suite)
    }

    private func makeUpdate(version: String) -> MacUpdateManager.Update {
        MacUpdateManager.Update(
            channel: .stable,
            currentVersion: "1.0.0",
            latestVersion: version,
            releaseURL: URL(string: "https://example.test/release")!,
            releaseNotes: nil,
            zipAsset: nil,
            dmgAsset: nil
        )
    }

    nonisolated private static func response(
        for request: URLRequest,
        body: String,
        status: Int = 200
    ) -> (Data, URLResponse) {
        let url = request.url ?? URL(string: "https://example.test")!
        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (Data(body.utf8), response)
    }
}
