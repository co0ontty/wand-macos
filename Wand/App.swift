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
                .frame(
                    // 横屏布局:ideal 1440 × 880,最小 900 × 600;
                    // maxWidth / maxHeight 显式设 .infinity 让窗口可自由拖大/缩。
                    minWidth: 900, idealWidth: 1440, maxWidth: .infinity,
                    minHeight: 600, idealHeight: 880, maxHeight: .infinity
                )
        }
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("切换服务器…") {
                    NotificationCenter.default.post(name: .wandRequestSwitchServer, object: nil)
                }
                .keyboardShortcut(",", modifiers: [.command, .shift])
            }
        }
    }
}

final class WandAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
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
