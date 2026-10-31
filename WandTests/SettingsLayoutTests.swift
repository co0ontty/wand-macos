import AppKit
import CryptoKit
import SwiftUI
import XCTest
@testable import Wand

@MainActor
final class SettingsLayoutTests: XCTestCase {
    private var suites: [String] = []
    private let updatesDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("WandSettingsTests-\(UUID().uuidString)", isDirectory: true)

    override func tearDown() {
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        suites = []
        try? FileManager.default.removeItem(at: updatesDirectory)
        super.tearDown()
    }

    private func defaults() -> UserDefaults {
        let name = "WandSettingsTests.\(UUID().uuidString)"
        suites.append(name)
        return UserDefaults(suiteName: name)!
    }

    private func manager(_ storage: UserDefaults) -> MacUpdateManager {
        MacUpdateManager(
            defaults: storage, updatesDirectory: updatesDirectory,
            dataLoader: { _ in throw URLError(.notConnectedToInternet) },
            betaDataLoader: { _ in throw URLError(.notConnectedToInternet) },
            connectedServer: { nil },
            startInstallation: { _, _ in XCTFail("Layout tests must not install an update") },
            cancelInstallation: {}
        )
    }

    private func makeHost(
        pane: String? = nil,
        width: CGFloat = 720,
        height: CGFloat = 620,
        dark: Bool = false,
        storage: UserDefaults,
        updater: MacUpdateManager? = nil,
        onClose: @escaping () -> Void = {}
    ) -> (NSHostingView<AnyView>, NSWindow) {
        let view = SettingsView(
            serverURL: URL(string: "https://wand-settings-layout.example.test:8443/" + String(repeating: "long-path/", count: 8))!,
            token: nil, onClose: onClose, initialPane: pane,
            updateManager: updater ?? manager(storage),
            loadServerVersion: { "4.92.0-debug.settings-layout" },
            probePermission: { $0(false) },
            loadIdentities: { (NativeUserProfile(name: "我的测试资料"), []) }
        )
        .environmentObject(ServerStore(defaults: storage))
        .defaultAppStorage(storage)
        .preferredColorScheme(dark ? .dark : .light)
        let host = NSHostingView(rootView: AnyView(view))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        return (host, window)
    }

    func testEmployeeDetailsSettingsSelectsCurrentEmployeeAndShowsRetentionWithoutDirectory() async throws {
        let hostName = "employee-settings-\(UUID().uuidString).example.test"
        CommunicationsContractURLProtocol.register(host: hostName) { _ in Data("{}".utf8) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CommunicationsContractURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel(); CommunicationsContractURLProtocol.unregister(host: hostName) }
        let api = WandAPI(baseURL: URL(string: "https://\(hostName)")!, token: nil, session: session)
        let employee = try JSONDecoder().decode(EmployeeContact.self, from: Data(#"{"id":"e_target","name":"当前员工","duty":"测试","systemSessionLimit":7}"#.utf8))
        let host = NSHostingView(rootView: SettingsEmployeeIdentities(api: api, loadData: {
            (NativeUserProfile(name: "不是当前员工"), [employee])
        }, initialEmployeeID: employee.id))
        host.frame = NSRect(x: 0, y: 0, width: 720, height: 1000)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        await settle(host)
        let fields = descendants(host).compactMap { $0 as? NSTextField }
        XCTAssertTrue(fields.contains { $0.stringValue == "当前员工" })
        XCTAssertTrue(fields.contains { $0.stringValue == "7" && $0.isEditable }, "Retention is editable directly in this employee's settings")
        // SwiftUI TextField exposes its accessibility ID through AX, not NSView.identifier.
        XCTAssertEqual(fields.filter { $0.stringValue == "7" && $0.isEditable }.count, 1)
        XCTAssertFalse(descendants(host).contains { $0.identifier?.rawValue == "settings-employee-directory" })
    }

    func testNativePreferencePickersKeepStorageKeysAndFitMinimumWindow() async throws {
        let storage = defaults()
        let (host, window) = makeHost(pane: "general", width: 540, height: 500, storage: storage)
        defer { window.contentView = nil }
        await settle(host)
        let pickers = descendants(host).compactMap { $0 as? NSSegmentedControl }
        XCTAssertEqual(pickers.count, 3)
        let appearance = try XCTUnwrap(pickers.first { $0.segmentCount == 3 })
        let width = try XCTUnwrap(pickers.first { $0.label(forSegment: 0) == "铺满" })
        let send = try XCTUnwrap(pickers.first { $0.label(forSegment: 0) == "Return 发送" })
        for picker in pickers {
            let frame = picker.convert(picker.bounds, to: host)
            XCTAssertGreaterThanOrEqual(frame.minX, 20)
            XCTAssertLessThanOrEqual(frame.maxX, 520)
            XCTAssertGreaterThanOrEqual(frame.width, picker.intrinsicContentSize.width - 1)
            XCTAssertEqual(frame.minX, 156, accuracy: 1, "Preference controls share the same leading edge")
            XCTAssertTrue(picker.isEnabled)
        }
        for (picker, key, value) in [
            (appearance, "wand.appearanceMode", "light"),
            (width, ChatContentWidth.storageKey, "column")
        ] {
            picker.selectedSegment = 1
            XCTAssertTrue(picker.sendAction(picker.action, to: picker.target))
            await settle(host)
            XCTAssertEqual(storage.string(forKey: key), value)
        }
        send.selectedSegment = 1
        XCTAssertTrue(send.sendAction(send.action, to: send.target))
        await settle(host)
        XCTAssertTrue(storage.bool(forKey: "wand.sendWithCommandEnter"))
        XCTAssertEqual(descendants(host).compactMap { $0 as? NSSegmentedControl }.count, 3)
    }

    func testPersistedPreferencesRestoreWithoutWritingDefaultsOnOpen() async throws {
        let storage = defaults()
        storage.set("dark", forKey: "wand.appearanceMode")
        storage.set("column", forKey: ChatContentWidth.storageKey)
        storage.set(true, forKey: "wand.sendWithCommandEnter")
        let (host, window) = makeHost(pane: "general", storage: storage)
        defer { window.contentView = nil }
        await settle(host)
        let pickers = descendants(host).compactMap { $0 as? NSSegmentedControl }
        XCTAssertEqual(pickers.first { $0.segmentCount == 3 }?.selectedSegment, 2)
        XCTAssertEqual(pickers.first { $0.label(forSegment: 0) == "铺满" }?.selectedSegment, 1)
        XCTAssertEqual(pickers.first { $0.label(forSegment: 0) == "Return 发送" }?.selectedSegment, 1)
        XCTAssertNil(storage.object(forKey: "wand.settings.selectedPane"))
    }

    func testDirectoryReturnsToSameMountedDetailsAndHidesInactiveControls() async throws {
        let storage = defaults()
        let (host, window) = makeHost(width: 540, height: 500, storage: storage)
        defer { window.orderOut(nil); window.contentView = nil }
        await settle(host)
        XCTAssertFalse(descendants(host).contains { $0 is NSSegmentedControl })
        XCTAssertEqual(descendants(host).compactMap { $0 as? NSTextField }.first { $0.isEditable }?.stringValue, "我的测试资料", "首次进入默认打开自己的资料")
        try clickMarker("settings-back", host: host, window: window)
        await settle(host)
        for pane in ["employees", "general", "connection", "permissions", "troubleshooting", "about"] {
            _ = try marker("settings-open-\(pane)", in: host)
        }
        try clickMarker("settings-open-general", host: host, window: window)
        await settle(host)
        let picker = try XCTUnwrap(descendants(host).compactMap { $0 as? NSSegmentedControl }.first)
        try clickMarker("settings-back", host: host, window: window)
        await settle(host)
        XCTAssertTrue(descendants(host).contains { $0 === picker })
        XCTAssertFalse(picker.isEnabled)
        try clickMarker("settings-open-general", host: host, window: window)
        await settle(host)
        XCTAssertTrue(descendants(host).contains { $0 === picker })
        XCTAssertTrue(picker.isEnabled)
        window.sendEvent(try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53
        )))
        await settle(host)
        XCTAssertFalse(picker.isEnabled, "Escape returns to the directory before closing settings")
    }

    func testWideSettingsKeepOneVerticalRailAndCloseDirectly() async throws {
        let storage = defaults()
        var closed = false
        let (host, window) = makeHost(width: 1000, storage: storage, onClose: { closed = true })
        defer { window.contentView = nil }
        await settle(host)
        let employee = try marker("settings-open-employees", in: host)
        let general = try marker("settings-open-general", in: host)
        XCTAssertLessThan(employee.convert(employee.bounds, to: host).minY, general.convert(general.bounds, to: host).minY)
        try clickMarker("settings-open-general", host: host, window: window)
        await settle(host)
        _ = try marker("settings-open-employees", in: host)
        XCTAssertTrue(descendants(host).compactMap { $0 as? NSSegmentedControl }.contains { $0.isEnabled })
        try clickMarker("settings-back", host: host, window: window)
        XCTAssertTrue(closed, "宽窗口不再返回三列目录")
    }

    func testUserIdentityDecodingAndAvatarSeedRemainStable() throws {
        let config = try JSONDecoder().decode(ServerConfigInfo.self, from: Data("{\"userProfile\":{\"avatar\":\"cat:3\"}}".utf8))
        XCTAssertEqual(config.userProfile?.displayName, "我")
        XCTAssertEqual(config.userProfile?.avatar, "cat:3")
        XCTAssertEqual(PlushAvatarIdentity.asset(id: "user", name: "旧名字", avatar: ""), PlushAvatarIdentity.asset(id: "user", name: "新名字", avatar: ""))
    }

    func testUpdateChannelUsesSameManagerAndDoesNotCheckOnLayout() async throws {
        let storage = defaults()
        var requests = 0
        let updater = MacUpdateManager(
            defaults: storage, updatesDirectory: updatesDirectory,
            betaDataLoader: { _ in requests += 1; throw URLError(.notConnectedToInternet) },
            connectedServer: { URL(string: "https://updates.example.test") }
        )
        let (host, window) = makeHost(pane: "about", width: 540, height: 500, storage: storage, updater: updater)
        defer { window.contentView = nil }
        await settle(host)
        XCTAssertEqual(requests, 0)
        let picker = try XCTUnwrap(descendants(host).compactMap { $0 as? NSSegmentedControl }.first)
        XCTAssertEqual(picker.label(forSegment: 0), "Stable")
        picker.selectedSegment = 1
        XCTAssertTrue(picker.sendAction(picker.action, to: picker.target))
        await settle(host)
        XCTAssertEqual(updater.channel, .beta)
        XCTAssertEqual(requests, 1)
        XCTAssertNotNil(updater.lastError)
        XCTAssertTrue(picker.isEnabled, "Failed checks leave the channel control usable")
    }

    func testBetaAddressFieldIsExclusiveToBetaAndKeepsInvalidDraft() async throws {
        let storage = defaults()
        let updater = manager(storage)
        let (host, window) = makeHost(pane: "about", storage: storage, updater: updater)
        defer { window.contentView = nil }
        await settle(host)
        XCTAssertFalse(descendants(host).compactMap { $0 as? NSTextField }.contains { $0.isEditable })
        _ = await updater.setChannel(.beta)
        await settle(host)
        let field = try XCTUnwrap(descendants(host).compactMap { $0 as? NSTextField }.first { $0.isEditable })
        XCTAssertEqual(field.placeholderString, "留空使用当前连接的服务器")
        field.stringValue = "file:///tmp/not-a-server"
        NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: field)
        XCTAssertTrue(field.sendAction(field.action, to: field.target))
        await settle(host)
        XCTAssertEqual(field.stringValue, "file:///tmp/not-a-server")
        XCTAssertEqual(updater.betaServerAddress, "")
        XCTAssertTrue(field.isEnabled)
        _ = await updater.setChannel(.stable)
        await settle(host)
        XCTAssertFalse(descendants(host).compactMap { $0 as? NSTextField }.contains { $0.isEditable })
        _ = await updater.setChannel(.beta)
        await settle(host)
        let restored = try XCTUnwrap(descendants(host).compactMap { $0 as? NSTextField }.first { $0.isEditable })
        XCTAssertEqual(restored.stringValue, "file:///tmp/not-a-server")
        restored.stringValue = "https://updates.example.test:8443/"
        NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: restored)
        XCTAssertTrue(restored.sendAction(restored.action, to: restored.target))
        await settle(host)
        XCTAssertEqual(updater.betaServerAddress, "https://updates.example.test:8443")
        XCTAssertEqual(restored.stringValue, updater.betaServerAddress)
        XCTAssertNotNil(updater.lastError, "The saved source remains selected even when the offline check fails")
    }

    func testCustomBetaSourceReadsInstalledServiceWithoutChangingConnection() async throws {
        guard ProcessInfo.processInfo.environment["WAND_SETTINGS_LIVE"] == "1" else {
            throw XCTSkip("installed-service read-only Beta source acceptance is opt-in")
        }
        let connectionFile = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".wand/acceptance-connection.json")
        let connection = try JSONSerialization.jsonObject(with: Data(contentsOf: connectionFile)) as? [String: Any]
        guard let address = connection?["serverURL"] as? String, let origin = URL(string: address) else {
            throw NSError(domain: "SettingsLiveAcceptance", code: 1)
        }
        let storage = defaults()
        let connected = URL(string: "https://not-the-update-server.invalid")!
        let updater = MacUpdateManager(
            defaults: storage, updatesDirectory: updatesDirectory,
            currentVersion: { "0.0.0" },
            dataLoader: { _ in XCTFail("Beta must not contact GitHub"); throw URLError(.unsupportedURL) },
            connectedServer: { connected },
            startInstallation: { _, _ in XCTFail("Acceptance never installs the app") },
            cancelInstallation: {}
        )
        _ = try await updater.setBetaServerAddress(address)
        let result = await updater.setChannel(.beta)
        guard case let .updateAvailable(update) = result else {
            return XCTFail("Installed service did not return a Beta update")
        }
        XCTAssertTrue(updater.betaUsesCustomServer)
        XCTAssertTrue(updater.betaServerURL?.host == origin.host)
        XCTAssertTrue(update.releaseURL.host == origin.host)
        let asset = try XCTUnwrap(update.preferredAsset)
        XCTAssertTrue(asset.downloadURL.host == origin.host)
        XCTAssertEqual(asset.sha256?.count, 64)
        XCTAssertGreaterThan(asset.size, 0)
        XCTAssertEqual(updater.channel, .beta)
        let (host, window) = makeHost(pane: "about", storage: storage, updater: updater)
        defer { window.contentView = nil }
        await settle(host)
        let field = try XCTUnwrap(descendants(host).compactMap { $0 as? NSTextField }.first { $0.isEditable })
        XCTAssertTrue(field.stringValue == updater.betaServerAddress)
        XCTAssertTrue(field.isEnabled)
        let payload = try await BetaUpdateSession.data(for: URLRequest(url: asset.downloadURL))
        XCTAssertEqual((payload.1 as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(Int64(payload.0.count), asset.size)
        let hash = SHA256.hash(data: payload.0).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hash, asset.sha256)
    }

    func testSettingsNativeScreenshotMatrix() async throws {
        guard let path = ProcessInfo.processInfo.environment["WAND_SETTINGS_VISUAL_DIR"] else {
            throw XCTSkip("opt-in native settings screenshot matrix")
        }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let storage = defaults()
        for pane in [nil, "general", "connection", "permissions", "troubleshooting", "about", "beta"] as [String?] {
            for dark in [false, true] {
                for width: CGFloat in [540, 720] {
                    let updater = manager(storage)
                    if pane == "beta" {
                        _ = try await updater.setBetaServerAddress("https://updates.example.test:8443")
                        _ = await updater.setChannel(.beta)
                    }
                    let (host, window) = makeHost(pane: pane == "beta" ? "about" : pane, width: width, height: width == 540 ? 500 : 620, dark: dark, storage: storage, updater: updater)
                    defer { window.contentView = nil }
                    await settle(host)
                    for scroll in descendants(host).compactMap({ $0 as? NSScrollView }) {
                        XCTAssertFalse(scroll.hasHorizontalScroller)
                        if let document = scroll.documentView {
                            XCTAssertLessThanOrEqual(document.frame.width, scroll.contentSize.width + 1)
                        }
                    }
                    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(
                        to: output.appendingPathComponent("\(pane ?? "directory")-\(dark ? "dark" : "light")-\(Int(width)).png")
                    )
                    if pane == "beta" {
                        let field = try XCTUnwrap(descendants(host).compactMap { $0 as? NSTextField }.first { $0.isEditable })
                        let scroll = try XCTUnwrap(field.enclosingScrollView)
                        let document = try XCTUnwrap(scroll.documentView)
                        let bottom = document.isFlipped ? max(0, document.bounds.maxY - scroll.contentSize.height) : 0
                        scroll.contentView.scroll(to: NSPoint(x: 0, y: bottom))
                        scroll.reflectScrolledClipView(scroll.contentView)
                        await settle(host)
                        XCTAssertEqual(scroll.contentView.bounds.minY, bottom, accuracy: 1, "Beta actions remain reachable at the bottom of the page")
                        let scrolled = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                        host.cacheDisplay(in: host.bounds, to: scrolled)
                        try XCTUnwrap(scrolled.representation(using: .png, properties: [:])).write(
                            to: output.appendingPathComponent("beta-bottom-\(dark ? "dark" : "light")-\(Int(width)).png")
                        )
                    }
                }
            }
        }
    }

    func testPageStackKeepsDraftAndTerminalMountedButDisablesHiddenInput() async throws {
        let state = PageFixtureState()
        let host = NSHostingView(rootView: PageFixture(state: state))
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        await settle(host)
        let editor = try XCTUnwrap(descendants(host).compactMap { $0 as? ComposerNSTextView }.first)
        XCTAssertEqual(state.appearances, 1)
        XCTAssertEqual(state.settingsAppearances, 0, "Settings has no eager lifecycle or network work")
        editor.insertText("保留草稿", replacementRange: NSRange(location: 0, length: 0))
        await settle(host)
        let terminalSize = state.terminal.frame.size
        let terminalColumns = state.terminal.getTerminal().cols
        var terminalResizes = 0
        state.terminal.onSizeChange = { _, _ in terminalResizes += 1 }
        state.settingsPresented = true
        window.setContentSize(NSSize(width: 1160, height: 600))
        await settle(host)
        XCTAssertEqual(state.terminal.frame.size, terminalSize, "Borrowing the sidebar's width cannot reflow the retained terminal")
        XCTAssertEqual(state.terminal.getTerminal().cols, terminalColumns)
        XCTAssertEqual(terminalResizes, 0)
        XCTAssertNil(window.attachedSheet)
        XCTAssertEqual(state.disappearances, 0)
        XCTAssertEqual(state.settingsAppearances, 1)
        XCTAssertTrue(descendants(host).contains { $0 === editor })
        XCTAssertFalse(editor.isEditable)
        window.makeFirstResponder(editor)
        XCTAssertFalse(window.firstResponder === editor, "Hidden composer must reject AppKit focus, not just typing")
        XCTAssertFalse(state.terminal.inputEnabled)
        XCTAssertFalse(state.terminal.canBecomeKeyView, "Hidden terminal is excluded from AppKit traversal")
        window.makeFirstResponder(nil)
        for _ in 0..<8 {
            window.selectNextKeyView(nil)
            XCTAssertFalse(window.firstResponder === editor)
            XCTAssertFalse(window.firstResponder === state.terminal)
        }
        state.terminal.focusTerminal()
        XCTAssertFalse(window.firstResponder === state.terminal)
        state.terminal.pasteText("must not send\r")
        XCTAssertTrue(state.inputs.isEmpty)
        state.terminal.feedOutput("still connected")
        XCTAssertEqual(state.terminal.getTerminal().getLine(row: 0)?.translateToString(trimRight: true), "still connected")
        state.settingsPresented = false
        await settle(host)
        XCTAssertTrue(editor.isEditable)
        XCTAssertTrue(state.terminal.inputEnabled)
        XCTAssertEqual(editor.string, "保留草稿")
        XCTAssertEqual(state.draft, "保留草稿")
        XCTAssertEqual(state.appearances, 1)
        XCTAssertEqual(state.disappearances, 0)
        state.terminal.pasteText("allowed")
        XCTAssertEqual(state.inputs.joined(), "allowed")
        state.settingsPresented = true
        await settle(host)
        XCTAssertEqual(state.settingsAppearances, 1, "Visited settings keeps its own draft and scroll state")
    }

    func testRetainedSettingsRefreshOnlyWhenActiveAndIgnoreLateLoads() async throws {
        let storage = defaults()
        let updater = manager(storage)
        _ = await updater.setChannel(.beta)
        let state = PageFixtureState()
        state.settingsPresented = true
        var loads = 0, probes = 0
        var pending: CheckedContinuation<String?, Never>?
        let settings = SettingsView(serverURL: URL(string: "https://settings.example.test")!, token: nil,
            onClose: {}, initialPane: "about", updateManager: updater,
            loadServerVersion: {
                loads += 1
                if loads == 1 { return await withCheckedContinuation { pending = $0 } }
                return "4.92.0-test.\(loads)"
            }, probePermission: { completion in probes += 1; completion(false) })
            .environmentObject(ServerStore(defaults: storage)).defaultAppStorage(storage)
        let host = NSHostingView(rootView: SettingsVisibilityFixture(state: state, content: settings))
        host.frame = NSRect(x: 0, y: 0, width: 720, height: 620)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        defer { pending?.resume(returning: nil); window.contentView = nil }
        await settle(host)
        XCTAssertEqual(loads, 1)
        let field = try XCTUnwrap(descendants(host).compactMap { $0 as? NSTextField }.first { $0.isEditable })
        field.stringValue = "unfinished update source"
        NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: field)
        state.settingsPresented = false
        await settle(host)
        pending?.resume(returning: "stale")
        pending = nil
        await settle(host)
        XCTAssertEqual(probes, 0, "A hidden page's late metadata result cannot continue its observation chain")
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await settle(host)
        XCTAssertEqual(loads, 1, "Application activation does not refresh an inactive settings page")
        state.settingsPresented = true
        await settle(host)
        XCTAssertEqual(loads, 2)
        XCTAssertEqual(probes, 1)
        XCTAssertTrue(descendants(host).contains { $0 === field })
        XCTAssertEqual(field.stringValue, "unfinished update source")
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await settle(host)
        XCTAssertEqual(loads, 3)
        XCTAssertEqual(probes, 2)
        XCTAssertEqual(field.stringValue, "unfinished update source")
    }

    func testSettingsCloseIsPageCallbackAndDoesNotDismissWindow() async throws {
        var closed = 0
        let (host, window) = makeHost(storage: defaults(), onClose: { closed += 1 })
        defer { window.orderOut(nil); window.contentView = nil }
        await settle(host)
        try clickMarker("settings-back", host: host, window: window)
        await settle(host)
        XCTAssertEqual(closed, 1)
        XCTAssertNil(window.attachedSheet)
        XCTAssertTrue(window.contentView === host)
    }

    func testSidebarHeaderAndRailKeepListIdentityWhenTemporarilyHidden() async throws {
        let state = PageFixtureState()
        let host = NSHostingView(rootView: SidebarFixture(state: state))
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        await settle(host)
        let header = try marker("desktop-sidebar-header", in: host)
        let body = try marker("desktop-sidebar-body", in: host)
        let list = try marker("fixture-sidebar-list", in: host)
        let settings = try marker("desktop-navigation-settings", in: host)
        let headerFrame = header.convert(header.bounds, to: host)
        let bodyFrame = body.convert(body.bounds, to: host)
        let settingsFrame = settings.convert(settings.bounds, to: host)
        XCTAssertEqual(headerFrame.height, 52, accuracy: 1)
        XCTAssertEqual(bodyFrame.minY, headerFrame.maxY, accuracy: 1, "No second brand/header row")
        XCTAssertEqual(headerFrame.width, 336, accuracy: 1)
        XCTAssertEqual(settingsFrame.minX, 16, accuracy: 1)
        XCTAssertEqual(settingsFrame.maxY, 588, accuracy: 1)
        state.settingsPresented = true
        await settle(host)
        XCTAssertTrue(descendants(host).contains { $0 === list })
        XCTAssertEqual(header.convert(header.bounds, to: host).width, 76, accuracy: 1)
        XCTAssertEqual(settings.convert(settings.bounds, to: host), settingsFrame)
        state.settingsPresented = false
        await settle(host)
        XCTAssertTrue(descendants(host).contains { $0 === list })
        XCTAssertEqual(header.convert(header.bounds, to: host), headerFrame)
    }

    func testInstalledShellOpensSettingsAsPageAndRestoresListAndDraft() async throws {
        guard ProcessInfo.processInfo.environment["WAND_SETTINGS_SHELL_LIVE"] == "1" else {
            throw XCTSkip("Installed-service shell page acceptance is opt-in and read-only")
        }
        XCTAssertTrue(NativeAcceptance.enabled)
        let storage = NativeAcceptance.defaults
        defer { NativeAcceptance.cleanup() }
        let origin = try XCTUnwrap(URL(string: try XCTUnwrap(storage.string(forKey: "wand.serverURL"))))
        let token = try XCTUnwrap(storage.string(forKey: "wand.token"))
        storage.set(true, forKey: "wand.desktop.sidebarVisible")
        storage.set(false, forKey: "wand.desktop.sidebarRecent")
        storage.set(false, forKey: "wand.desktop.sidebarActiveOnly")
        let updater = manager(storage)
        let api = WandAPI(baseURL: origin, token: token)
        let view = MainShellView(serverURL: origin, token: token) { close in
            SettingsView(serverURL: origin, token: token, onClose: close, titlebarLeadingInset: 40,
                updateManager: updater, loadServerVersion: { (try? await api.serverConfig())?.currentVersion },
                probePermission: { $0(false) })
        }.environmentObject(ServerStore(defaults: storage)).defaultAppStorage(storage)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 1280, height: 850)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.orderOut(nil); window.contentView = nil }
        try await Task.sleep(nanoseconds: 1_500_000_000)
        await settle(host)
        try await captureShellMatrix(host, window: window, name: "sidebar")
        let input = try XCTUnwrap(descendants(host).compactMap { $0 as? ComposerNSTextView }.first)
        input.insertText("仅本机设置页面验收草稿，不发送", replacementRange: NSRange(location: 0, length: 0))
        await settle(host)
        let originalText = input.string
        let list = try marker("sidebar-search-slot", in: host)
        let rail = try marker("desktop-navigation-settings", in: host)
        let railFrame = rail.convert(rail.bounds, to: host)
        try clickMarker("desktop-navigation-settings", host: host, window: window)
        await settle(host)
        XCTAssertNil(window.attachedSheet)
        XCTAssertNotNil(try marker("settings-open-general", in: host))
        XCTAssertTrue(descendants(host).contains { $0 === input })
        XCTAssertFalse(input.isEditable)
        XCTAssertTrue(descendants(host).contains { $0 === list })
        XCTAssertTrue(storage.bool(forKey: "wand.desktop.sidebarVisible"), "Settings must not change the user's list preference")
        XCTAssertEqual(rail.convert(rail.bounds, to: host), railFrame)
        NotificationCenter.default.post(name: .wandDesktopCommand, object: DesktopCommand.focusComposer)
        await settle(host)
        XCTAssertFalse(window.firstResponder === input, "Hidden composer must ignore global focus commands")
        try await captureShellMatrix(host, window: window, name: "settings")
        try clickMarker("settings-open-general", host: host, window: window)
        await settle(host)
        let picker = try XCTUnwrap(descendants(host).compactMap { $0 as? NSSegmentedControl }.first { $0.segmentCount == 3 })
        XCTAssertTrue(picker.isEnabled)
        try clickMarker("settings-close-page", host: host, window: window)
        await settle(host)
        XCTAssertFalse(picker.isEnabled)
        XCTAssertTrue(input.isEditable)
        XCTAssertEqual(input.string, originalText)
        XCTAssertTrue(descendants(host).contains { $0 === list })
        XCTAssertEqual(try marker("desktop-sidebar-header", in: host).bounds.width, 316, accuracy: 1)
        try clickMarker("desktop-navigation-settings", host: host, window: window)
        await settle(host)
        XCTAssertTrue(descendants(host).contains { $0 === picker })
        XCTAssertTrue(picker.isEnabled, "Reopening settings preserves the visited page")
        for _ in 0..<2 {
            window.sendEvent(try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)))
            await settle(host)
        }
        XCTAssertTrue(input.isEditable, "Escape returns through the directory to the original work page")
        XCTAssertEqual(input.string, originalText)
    }

    private func captureShellMatrix(_ host: NSView, window: NSWindow, name: String) async throws {
        guard let path = ProcessInfo.processInfo.environment["WAND_SETTINGS_VISUAL_DIR"] else { return }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for dark in [false, true] {
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            for size in [NSSize(width: 900, height: 600), NSSize(width: 1280, height: 850)] {
                window.setContentSize(size)
                await settle(host)
                let header = try marker("desktop-sidebar-header", in: host)
                let body = try marker("desktop-sidebar-body", in: host)
                XCTAssertEqual(header.bounds.height, 52, accuracy: 1)
                XCTAssertEqual(body.convert(body.bounds, to: host).minY, header.convert(header.bounds, to: host).maxY, accuracy: 1)
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(
                    to: output.appendingPathComponent("shell-\(name)-\(dark ? "dark" : "light")-\(Int(size.width)).png"))
            }
        }
    }

    private func marker(_ id: String, in host: NSView) throws -> NSView {
        try XCTUnwrap(descendants(host).first { $0.identifier?.rawValue == id })
    }

    private func clickMarker(_ id: String, host: NSView, window: NSWindow) throws {
        window.makeKeyAndOrderFront(nil)
        let view = try marker(id, in: host)
        let frame = view.convert(view.bounds, to: nil)
        // AppKit may track mouse-down synchronously; queue mouse-up first.
        let clickTime = ProcessInfo.processInfo.systemUptime
        for type in [NSEvent.EventType.leftMouseUp, .leftMouseDown] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: NSPoint(x: frame.midX, y: frame.midY),
                modifierFlags: [], timestamp: clickTime + (type == .leftMouseUp ? 0.01 : 0), windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            if type == .leftMouseUp { NSApp.postEvent(event, atStart: false) }
            else { window.sendEvent(event) }
        }
    }

    private func settle(_ host: NSView) async {
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(nanoseconds: 250_000_000)
        host.layoutSubtreeIfNeeded()
    }

    private func descendants(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(descendants) }

}

@MainActor
private final class PageFixtureState: ObservableObject {
    @Published var settingsPresented = false
    @Published var draft = ""
    let terminal = NativeTerminalView()
    var appearances = 0
    var disappearances = 0
    var settingsAppearances = 0
    var inputs: [String] = []
    init() {
        terminal.onInput = { [weak self] text, userInput in if userInput { self?.inputs.append(text) } }
    }
}

private struct SettingsVisibilityFixture<Content: View>: View {
    @ObservedObject var state: PageFixtureState
    let content: Content
    var body: some View { content.desktopPage(active: state.settingsPresented) }
}

private struct PageFixture: View {
    @ObservedObject var state: PageFixtureState
    var body: some View {
        DesktopPageStack(settingsPresented: state.settingsPresented, workspaceWidth: 900) {
            VStack {
                IMEAwareComposerTextView(text: $state.draft, placeholder: "草稿", isFocused: false,
                    sendWithCommandEnter: true, onFocusChange: { _ in }, onCompositionChange: { _ in },
                    onSubmit: {}, onHeightChange: { _ in }).frame(height: 60)
                NativeTerminalSurface(terminal: state.terminal)
            }
            .onAppear { state.appearances += 1 }
            .onDisappear { state.disappearances += 1 }
        } settings: {
            Text("设置").frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear { state.settingsAppearances += 1 }
        }
    }
}

private struct SidebarFixture: View {
    @ObservedObject var state: PageFixtureState
    var body: some View {
        HStack(spacing: 0) {
            DesktopSidebarLayout(listVisible: !state.settingsPresented, onToggle: {}) {
                DesktopNavigationRail(selection: state.settingsPresented ? .settings : .conversations, onCommand: { _ in }) { EmptyView() }
            } list: {
                ScrollView {
                    VStack(alignment: .leading) {
                        ForEach(0..<30) { Text("工作任务 \($0)").frame(height: 32) }
                    }.frame(maxWidth: .infinity)
                }.sidebarPresence("fixture-sidebar-list")
            }
            Color.clear
        }
    }
}
