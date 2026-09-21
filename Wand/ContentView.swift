import SwiftUI

/// 横屏 native 主壳入口:已连接 → MainShellView(三栏 + 顶栏);
/// 未连接 → ConnectView。切换服务器通过 sheet 触发 ConnectView。
struct ContentView: View {
    @EnvironmentObject var store: ServerStore
    @State private var showSwitchSheet = false
    @AppStorage("wand.appearanceMode") private var appearanceMode = "system"
    @State private var showGuide = false
    @State private var showShortcuts = false

    var body: some View {
        ZStack {
            // 全窗口背景,避免 ConnectView/加载中状态留下空白
            WandAmbientBackground()
            if let serverURL = store.serverURL {
                MainShellView(serverURL: serverURL, token: store.token)
                    .id(serverURL.absoluteString)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ConnectView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .preferredColorScheme(appearanceMode == "dark" ? .dark : appearanceMode == "light" ? .light : nil)
        .sheet(isPresented: $showGuide) { DesktopOnboardingView(onFinish: { showGuide = false }, isConnected: false) }
        .sheet(isPresented: $showShortcuts) { DesktopShortcutsView() }
        .onReceive(NotificationCenter.default.publisher(for: .wandDesktopCommand)) { note in
            guard store.serverURL == nil, let command = note.object as? DesktopCommand else { return }
            if command == .onboarding { showGuide = true }
            if command == .shortcuts { showShortcuts = true }
        }
        .sheet(isPresented: $showSwitchSheet) {
            ConnectView(isPresentedAsSheet: true) { showSwitchSheet = false }
                .environmentObject(store)
        }
        .onReceive(NotificationCenter.default.publisher(for: .wandRequestSwitchServer)) { _ in
            showSwitchSheet = true
        }
    }
}
