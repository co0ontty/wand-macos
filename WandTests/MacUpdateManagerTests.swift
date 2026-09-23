import Foundation
import XCTest
@testable import Wand

@MainActor
final class MacUpdateManagerTests: XCTestCase {

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
            defaults: defaults,
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
            defaults: defaults,
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
            defaults: defaults,
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

    func testFailedLaunchCheckDoesNotThrottleRetry() async {
        let defaults = makeDefaults()
        defer { clear(defaults) }
        var requests = 0
        let manager = MacUpdateManager(
            defaults: defaults,
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
            defaults: defaults,
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

    func testReminderDeferralIsScopedToVersion() {
        let defaults = makeDefaults()
        defer { clear(defaults) }
        var currentDate = Date(timeIntervalSince1970: 1_000)
        let manager = MacUpdateManager(
            defaults: defaults,
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
        let manager = MacUpdateManager(defaults: defaults, currentVersion: { "2.0.0" })
        let ack = staging.appendingPathComponent(".wand-update-ack")

        manager.completeLaunchedUpdateIfNeeded(arguments: [
            "Wand", "--wand-update-token", "transaction-1", "--wand-update-ack", ack.path,
        ])

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
