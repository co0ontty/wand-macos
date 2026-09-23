import AppKit
import SwiftUI

@main
struct WandApp: App {
    @NSApplicationDelegateAdaptor(WandAppDelegate.self) private var appDelegate
    @StateObject private var store = ServerStore.shared

    var body: some Scene {
        WindowGroup("Wand") {
            ContentView()
                .environmentObject(store)
                .extendContentUnderTitleBar()
                .frame(
                    minWidth: DesktopWindowGeometry.minimumSize.width,
                    idealWidth: DesktopWindowGeometry.preferredSize.width, maxWidth: .infinity,
                    minHeight: DesktopWindowGeometry.minimumSize.height,
                    idealHeight: DesktopWindowGeometry.preferredSize.height, maxHeight: .infinity
                )
        }
        .windowStyle(.hiddenTitleBar)
        // Menu bar, command palette and the shortcut guide share one catalog.
        .commands {
            CommandGroup(replacing: .newItem) {
                DesktopCommandMenuItem(command: .newSession)
                DesktopCommandMenuItem(command: .newTask)
            }
            CommandGroup(replacing: .appSettings) {
                DesktopCommandMenuItem(command: .settings)
            }
            CommandGroup(after: .appInfo) {
                Button("检查更新…") {
                    Task { @MainActor in await UpdateFlowController.shared.checkManually() }
                }
                Button("切换服务器…") {
                    // A tool/editor sheet must finish its own close checks first.
                    guard NSApp.keyWindow?.sheetParent == nil else { return }
                    NotificationCenter.default.post(name: .wandRequestSwitchServer, object: nil)
                }.keyboardShortcut(",", modifiers: [.command, .shift])
            }
            CommandGroup(after: .textEditing) {
                Divider()
                DesktopCommandMenuItem(command: .search)
                DesktopCommandMenuItem(command: .findConversation)
                DesktopCommandMenuItem(command: .focusComposer)
            }
            CommandGroup(after: .sidebar) {
                DesktopCommandMenuItem(command: .toggleSidebar)
                DesktopCommandMenuItem(command: .toggleInspector)
                Divider()
                Menu("前往") {
                    ForEach([DesktopCommand.sessions, .workspaces, .taskBoard]) {
                        DesktopCommandMenuItem(command: $0)
                    }
                }
                DesktopCommandMenuItem(command: .reconnect)
            }
            CommandGroup(replacing: .help) {}
        }
    }
}

final class WandAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // helper 只有收到新版启动确认后才删除旧版备份；必须在其他启动任务前确认。
        let launchedAfterUpdate = MacUpdateManager.shared.completeLaunchedUpdateIfNeeded()

        // XCTest 会启动完整 App 宿主。测试期间不应弹本地网络权限或访问真实 GitHub API；
        // 更新检查本身由注入 DataLoader 的测试覆盖。
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil {
            return
        }

        // 等应用完成激活、主窗口可见后再触发；在 SwiftUI App.init 阶段访问网络时，
        // 系统权限 UI 还没有可靠的呈现上下文，新安装的 App 可能完全不弹框。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            LocalNetworkPermission.triggerPromptIfNeeded()
        }
        if launchedAfterUpdate,
           LocalNetworkPermission.shouldCheckForServer(ServerStore.shared.serverURL?.host) {
            // 连接域名也可能解析到局域网地址，不能只根据 host 字面值跳过检查。
            // 未决定时上面的访问会触发系统申请；
            // 已被拒绝时 macOS 不再弹申请，确认 PolicyDenied 后引导到系统设置。
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                LocalNetworkPermission.offerRecoveryIfDenied()
            }
        }

        // SwiftUI WindowGroup 可能先恢复多个旧窗口；等首个主窗口完成创建后再去重，
        // 避免在启动过渡阶段误判临时窗口。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            self.closeDuplicateMainWindows()
        }

        // 主窗口建立后后台查一次；24 小时内已成功检查会自动跳过。发现新版时以
        // 原生提醒呈现，不依赖用户是否已连接某一台 Wand 服务。
        DispatchQueue.main.asyncAfter(deadline: .now() + (launchedAfterUpdate ? 5 : 3)) {
            Task { @MainActor in
                guard let result = await MacUpdateManager.shared.check(.launch),
                      case let .updateAvailable(update) = result else {
                    return
                }
                UpdateFlowController.shared.presentLaunchReminder(for: update)
            }
        }
    }

    func applicationShouldSaveSecureApplicationState(_ app: NSApplication) -> Bool {
        false
    }

    func applicationShouldRestoreSecureApplicationState(_ app: NSApplication) -> Bool {
        false
    }

    private func closeDuplicateMainWindows() {
        let mainWindows = NSApp.windows.filter {
            $0.title == "Wand" && $0.sheetParent == nil && $0.styleMask.contains(.titled)
        }
        guard mainWindows.count > 1 else { return }

        let retainedWindow = mainWindows.first(where: { $0 === NSApp.keyWindow })
            ?? mainWindows.first(where: { $0 === NSApp.mainWindow })
            ?? mainWindows[0]
        for window in mainWindows where window !== retainedWindow {
            window.close()
        }
    }

}

extension Notification.Name {
    static let wandRequestSwitchServer = Notification.Name("WandRequestSwitchServer")
}
