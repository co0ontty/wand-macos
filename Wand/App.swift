import SwiftUI

@main
struct WandApp: App {
    @StateObject private var store = ServerStore.shared

    init() {
        // macOS 15+：主动把「本地网络」授权弹窗钓出来。系统设置的本地网络列表
        // 没有手动添加入口，必须由应用先发起一次本地网络访问；不触发的话，
        // URLSession 直连局域网 IP 会被静默拒绝（连接超时），用户既看不到弹窗、
        // 也没法在设置里找到 Wand 来授权。详见 LocalNetworkPermission.swift。
        LocalNetworkPermission.triggerPromptIfNeeded()
    }

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

extension Notification.Name {
    static let wandRequestSwitchServer = Notification.Name("WandRequestSwitchServer")
}
