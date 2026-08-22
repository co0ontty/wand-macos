import AppKit
import SwiftUI

@main
struct WandApp: App {
    @NSApplicationDelegateAdaptor(WandAppDelegate.self) private var appDelegate
    @StateObject private var store = ServerStore.shared

    var body: some Scene {
        // 用 minWidth + idealWidth + maxWidth=.infinity 让窗口可自由拖大/缩小。
        // 只写 .frame(minWidth:minHeight:) 时 macOS 13+ 的 .windowResizability(.contentSize)
        // 会把窗口的最大尺寸钉死在 min 上，看起来就是"窗口大小无法修改"。
        // 通过显式声明 maxWidth/maxHeight 为 .infinity，内容的尺寸约束就允许任意放大。
        WindowGroup("Wand") {
            ContentView()
                .environmentObject(store)
                // 隐藏原生标题栏：自绘 WandTopBar 铺到窗口上沿，红绿灯浮在顶栏左侧。
                .extendContentUnderTitleBar()
                .frame(
                    // 横屏布局:ideal 1440 × 880,最小 900 × 600;
                    // maxWidth / maxHeight 显式设 .infinity 让窗口可自由拖大/缩。
                    minWidth: 900, idealWidth: 1440, maxWidth: .infinity,
                    minHeight: 600, idealHeight: 880, maxHeight: .infinity
                )
        }
        // 顶部不再使用系统统一工具栏；应用顶栏完全由 MainShellView 内的
        // WandTopBar 自绘，与暖米色主题和扁平面板统一。
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("检查更新…") {
                    Task { @MainActor in
                        await UpdateFlowController.shared.checkManually()
                    }
                }
                Button("切换服务器…") {
                    NotificationCenter.default.post(name: .wandRequestSwitchServer, object: nil)
                }
                .keyboardShortcut(",", modifiers: [.command, .shift])
                Button("显示会话") {
                    NotificationCenter.default.post(name: .wandRequestSidebarSection, object: SidebarSection.sessions)
                }
                .keyboardShortcut("1", modifiers: .command)
                Button("显示项目") {
                    NotificationCenter.default.post(name: .wandRequestSidebarSection, object: SidebarSection.workspaces)
                }
                .keyboardShortcut("2", modifiers: .command)
                Button("并行任务") {
                    NotificationCenter.default.post(name: .wandRequestOpenMissions, object: nil)
                }
                .keyboardShortcut("2", modifiers: [.command, .shift])
            }
        }
    }
}

final class WandAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // helper 只有收到新版启动确认后才删除旧版备份；必须在其他启动任务前确认。
        MacUpdateManager.shared.completeLaunchedUpdateIfNeeded()

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

        // SwiftUI WindowGroup 可能先恢复多个旧窗口；等首个主窗口完成创建后再去重，
        // 避免在启动过渡阶段误判临时窗口。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            self.closeDuplicateMainWindows()
        }

        // 主窗口建立后后台查一次；24 小时内已成功检查会自动跳过。发现新版时以
        // 原生提醒呈现，不依赖用户是否已连接某一台 Wand 服务。
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
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
    static let wandRequestOpenMissions = Notification.Name("WandRequestOpenMissions")
    static let wandRequestSidebarSection = Notification.Name("WandRequestSidebarSection")
}
