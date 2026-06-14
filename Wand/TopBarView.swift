import SwiftUI
import AppKit

/// 横屏 native 应用的顶部 chrome。44pt 高,液态玻璃材质,顶部贴窗口。
/// 左:品牌 + 服务器地址;中:连接状态点 + 当前会话标题(可选);
/// 右:菜单按钮(设置 / 网页版 / 切换服务器 / 关于)。
///
/// 视觉对齐 web 端 `.main-header-row`，macOS 26+ 使用原生 Liquid Glass。
struct TopBarView: View {
    let serverURL: URL
    let connectionState: ConnectionState
    /// 当前会话标题(可选);为 nil 时只渲染「未选中会话」占位。
    var sessionTitle: String? = nil
    var sessionSubtitle: String? = nil

    let onSettings: () -> Void
    let onOpenWeb: () -> Void
    let onSwitchServer: () -> Void
    /// 右侧文件面板的开关状态与切换回调(折叠后唯一的重新打开入口)。
    var filePanelOpen: Bool = true
    var onToggleFilePanel: (() -> Void)? = nil

    enum ConnectionState {
        case connecting
        case connected
        case disconnected(String)
    }

    var body: some View {
        HStack(spacing: 12) {
            brand
            Spacer(minLength: 8)
            if let sessionTitle {
                sessionBadge(title: sessionTitle, subtitle: sessionSubtitle)
            } else {
                placeholderBadge
            }
            Spacer(minLength: 8)
            if let onToggleFilePanel {
                filePanelToggle(onToggleFilePanel)
            }
            menuButton
        }
        .padding(.leading, 84)
        .padding(.trailing, 16)
        .frame(height: 44)
        .wandGlass(.chrome)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: Theme.borderSubtle))
                .frame(height: 0.5)
        }
    }

    // MARK: - 区块

    private var brand: some View {
        HStack(spacing: 8) {
            WandBrandMark(size: 24)
            VStack(alignment: .leading, spacing: 0) {
                Text("Wand")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                Text(displayHost)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private var displayHost: String {
        if let host = serverURL.host {
            if let port = serverURL.port { return "\(host):\(port)" }
            return host
        }
        return serverURL.absoluteString
    }

    private var placeholderBadge: some View {
        HStack(spacing: 6) {
            connectionDot
            Text("未选择会话")
                .font(.system(size: 12))
        }
        .foregroundColor(Theme.textSecondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .wandGlass(.capsule)
        .help(connectionHelp)
    }

    private var connectionHelp: String {
        switch connectionState {
        case .connecting: return "正在连接服务器"
        case .connected: return "服务器已连接"
        case .disconnected(let message): return "服务器连接失败：\(message)"
        }
    }

    private func sessionBadge(title: String, subtitle: String?) -> some View {
        HStack(spacing: 8) {
            connectionDot
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .wandGlass(.capsule)
    }

    @ViewBuilder private var connectionDot: some View {
        switch connectionState {
        case .connecting:
            ProgressView()
                .controlSize(.small)
                .tint(Theme.textSecondary)
                .scaleEffect(0.7)
        case .connected:
            Circle()
                .fill(Theme.success)
                .frame(width: 7, height: 7)
                .overlay(
                    Circle()
                        .stroke(Color(nsColor: Theme.successGlow), lineWidth: 2)
                        .blur(radius: 1)
                )
        case .disconnected:
            Circle()
                .fill(Theme.danger)
                .frame(width: 7, height: 7)
        }
    }

    private func filePanelToggle(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: filePanelOpen ? "sidebar.right" : "sidebar.squares.right")
                .font(.system(size: 16))
                .foregroundColor(filePanelOpen ? Theme.wandAccent : Theme.textSecondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .wandGlassButton()
        .help(filePanelOpen ? "折叠文件面板" : "展开文件面板")
    }

    private var menuButton: some View {
        Menu {
            Button {
                onSettings()
            } label: {
                Label("设置", systemImage: "gearshape")
            }
            Button {
                onOpenWeb()
            } label: {
                Label("打开网页版", systemImage: "safari")
            }
            Divider()
            Button {
                onSwitchServer()
            } label: {
                Label("切换服务器", systemImage: "server.rack")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 18))
                .foregroundColor(Theme.textSecondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .wandGlassButton()
        .fixedSize()
    }
}

#Preview {
    VStack(spacing: 0) {
        TopBarView(
            serverURL: URL(string: "https://192.168.1.10:7777")!,
            connectionState: .connected,
            sessionTitle: "重构会话列表 tile",
            sessionSubtitle: "/Users/co0ontty/work/wand",
            onSettings: {},
            onOpenWeb: {},
            onSwitchServer: {}
        )
        Spacer()
    }
    .frame(width: 1280, height: 200)
    .background(Theme.windowGradient)
}
