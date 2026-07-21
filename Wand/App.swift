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
                // 原生工具栏已经呈现 Wand 品牌；隐藏系统重复的窗口标题，
                // 避免顶部同时出现两个 “Wand”。
                .hideNativeWindowTitle()
                .frame(
                    // 横屏布局:ideal 1440 × 880,最小 900 × 600;
                    // maxWidth / maxHeight 显式设 .infinity 让窗口可自由拖大/缩。
                    minWidth: 900, idealWidth: 1440, maxWidth: .infinity,
                    minHeight: 600, idealHeight: 880, maxHeight: .infinity
                )
        }
        // 常规 unified 工具栏给状态、文件与会话操作足够的呼吸空间；紧凑样式会把
        // 这些不同层级的控件压进同一条窄带，降低扫描与点击效率。
        .windowToolbarStyle(.unified(showsTitle: false))
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
    private let updateInstaller = DmgInstaller()
    private var remindedVersion: String?

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

        // 主窗口建立后后台查一次；24 小时内已查过会自动跳过。发现新版时以
        // 原生提醒呈现，不依赖用户是否已连接某一台 Wand 服务。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            Task { @MainActor in
                guard let self,
                      let result = await GitHubReleaseUpdater.shared.checkOnLaunchIfNeeded(),
                      case let .updateAvailable(update) = result else {
                    return
                }
                self.presentUpdateReminder(for: update)
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

    private func presentUpdateReminder(for update: GitHubReleaseUpdater.Update) {
        guard remindedVersion != update.latestVersion else { return }
        remindedVersion = update.latestVersion

        let alert = NSAlert()
        alert.messageText = "发现 Wand 新版本 v\(update.latestVersion)"
        alert.alertStyle = .informational

        if let asset = update.dmgAsset {
            let size = ByteCountFormatter.string(fromByteCount: asset.size, countStyle: .file)
            alert.informativeText = "当前版本 v\(update.currentVersion)。\n\n新版已发布到 GitHub Release（\(size)）。下载后会自动挂载 DMG，按提示将 Wand.app 拖入 Applications 即可。"
            alert.addButton(withTitle: "下载并打开 DMG")
            alert.addButton(withTitle: "查看 Release")
            alert.addButton(withTitle: "稍后提醒")
        } else {
            alert.informativeText = "当前版本 v\(update.currentVersion)。\n\n该 GitHub Release 未包含 macOS DMG，请在 Release 页面手动下载。"
            alert.addButton(withTitle: "查看 Release")
            alert.addButton(withTitle: "稍后提醒")
        }

        let handleResponse: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            if update.dmgAsset != nil {
                switch response {
                case .alertFirstButtonReturn:
                    guard let asset = update.dmgAsset else { return }
                    self.updateInstaller.downloadAndMount(
                        urlString: asset.downloadURL.absoluteString,
                        fileName: asset.name,
                        presentingWindow: NSApp.keyWindow
                    )
                case .alertSecondButtonReturn:
                    NSWorkspace.shared.open(update.releaseURL)
                default:
                    break
                }
            } else if response == .alertFirstButtonReturn {
                NSWorkspace.shared.open(update.releaseURL)
            }
        }

        if let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeKey }) {
            alert.beginSheetModal(for: window, completionHandler: handleResponse)
        } else {
            handleResponse(alert.runModal())
        }
    }
}

extension Notification.Name {
    static let wandRequestSwitchServer = Notification.Name("WandRequestSwitchServer")
}
