import SwiftUI

/// 横屏 native 主壳入口:已连接 → MainShellView(三栏 + 顶栏);
/// 未连接 → ConnectView。切换服务器通过 sheet 触发 ConnectView。
struct ContentView: View {
    @EnvironmentObject var store: ServerStore
    private struct ConnectionRequest: Identifiable {
        let id = UUID()
        let reconnectingServerURL: URL?
    }
    @State private var connectionRequest: ConnectionRequest?
    @AppStorage("wand.appearanceMode") private var appearanceMode = "system"

    var body: some View {
        ZStack {
            // 全窗口背景,避免 ConnectView/加载中状态留下空白
            WandAmbientBackground()
            if let serverURL = store.serverURL {
                MainShellView(serverURL: serverURL, token: store.token)
                    .id(store.connectionID)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ConnectView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .preferredColorScheme(appearanceMode == "dark" ? .dark : appearanceMode == "light" ? .light : nil)
        .sheet(item: $connectionRequest) { request in
            ConnectView(isPresentedAsSheet: true, reconnectingServerURL: request.reconnectingServerURL) {
                connectionRequest = nil
            }
            .environmentObject(store)
        }
        .onChange(of: store.connectionID) { _ in
            guard store.serverURL != nil, MacUpdateManager.shared.channel == .beta else { return }
            Task { @MainActor in
                guard let result = await MacUpdateManager.shared.check(.channelChanged),
                      case let .updateAvailable(update) = result else { return }
                UpdateFlowController.shared.presentLaunchReminder(for: update)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .wandRequestSwitchServer)) { note in
            connectionRequest = ConnectionRequest(reconnectingServerURL: note.object as? URL)
        }
    }
}
