import SwiftUI

/// macOS 设置使用稳定的侧栏/详情结构：侧栏负责定位，详情区承载当前任务，
/// 避免把桌面宽度浪费在一条不断向下延伸的卡片列上。
struct SettingsView: View {
    let serverURL: URL
    let token: String?
    /// 请求打开网页版（由 NativeRootView 在当前 sheet 关闭后呈现）。
    let onOpenWeb: () -> Void

    @EnvironmentObject private var store: ServerStore
    @Environment(\.dismiss) private var dismiss

    @State private var serverVersion: String?
    @State private var confirmDisconnect = false
    @State private var selectedPane: SettingsPane = .connection

    private var api: WandAPI { WandAPI(baseURL: serverURL, token: token) }

    var body: some View {
        VStack(spacing: 0) {
            settingsHeader
            Divider().opacity(0.35)
            HSplitView {
                settingsSidebar
                detailPane
            }
        }
        .frame(minWidth: 700, idealWidth: 760, minHeight: 520, idealHeight: 560)
        .background(Theme.background)
        .task {
            serverVersion = (try? await api.serverConfig())?.currentVersion
        }
        .confirmationDialog(
            "断开后需要重新输入连接码才能连回来。",
            isPresented: $confirmDisconnect,
            titleVisibility: .visible
        ) {
            Button("断开连接", role: .destructive) {
                dismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    store.disconnect()
                }
            }
            Button("取消", role: .cancel) {}
        }
    }

    private var settingsHeader: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("设置")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                Text("此 Mac 上的 Wand")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textSecondary)
            }
            Spacer()
            Button("完成") { dismiss() }
                .buttonStyle(.borderedProminent)
                .tint(Theme.brand)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .wandGlass(.chrome)
    }

    private var settingsSidebar: some View {
        List {
            ForEach(SettingsPane.allCases) { pane in
                Button {
                    selectedPane = pane
                } label: {
                    Label(pane.title, systemImage: pane.systemImage)
                        .font(.system(size: 13, weight: .medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundColor(selectedPane == pane ? Theme.textPrimary : Theme.textSecondary)
                .padding(.vertical, 4)
                .listRowBackground(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(selectedPane == pane ? Theme.wandAccent.opacity(0.12) : Color.clear)
                )
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 190, idealWidth: 210, maxWidth: 240)
    }

    private var detailPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                detailHeader
                switch selectedPane {
                case .connection:
                    connectionContent
                case .permissions:
                    permissionsContent
                case .about:
                    aboutContent
                }
            }
            .frame(maxWidth: 620, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }

    private var detailHeader: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(selectedPane.title)
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
            Text(selectedPane.subtitle)
                .font(.system(size: 13))
                .foregroundColor(Theme.textSecondary)
        }
    }

    private var connectionContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingsCard("当前服务器", description: "Wand 正在通过这个地址同步会话。") {
                infoRow("地址", serverURL.absoluteString, mono: true)
                rowDivider
                infoRow("认证方式", (token?.isEmpty == false) ? "连接码" : "无密码")
                if let serverVersion {
                    rowDivider
                    infoRow("服务端版本", "v\(serverVersion)", mono: true)
                }
                rowDivider
                HStack(spacing: 10) {
                    Button {
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            NotificationCenter.default.post(name: .wandRequestSwitchServer, object: nil)
                        }
                    } label: {
                        Label("切换服务器", systemImage: "server.rack")
                    }
                    Button("断开连接", role: .destructive) {
                        confirmDisconnect = true
                    }
                    Spacer()
                }
                .font(.system(size: 13))
            }

            settingsCard("完整设置", description: "模型、更新通道和服务端配置在网页版集中管理。") {
                Button {
                    dismiss()
                    onOpenWeb()
                } label: {
                    Label("打开网页版", systemImage: "safari")
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.brand)
            }
        }
    }

    private var permissionsContent: some View {
        settingsCard("本地网络", description: localNetworkDescription) {
            HStack(spacing: 12) {
                Image(systemName: LocalNetworkPermission.isEnforced ? "network.badge.shield.half.filled" : "checkmark.shield")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(LocalNetworkPermission.isEnforced ? Theme.warning : Theme.success)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(LocalNetworkPermission.isEnforced ? "由系统管理" : "无需额外授权")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                    Text(LocalNetworkPermission.isEnforced ? "无法连接局域网服务器时，请检查系统权限。" : "当前 macOS 版本不会单独限制 Wand 的局域网访问。")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textSecondary)
                }
                Spacer()
                if LocalNetworkPermission.isEnforced {
                    Button("打开系统设置") {
                        LocalNetworkPermission.openSettings()
                    }
                }
            }
        }
    }

    private var aboutContent: some View {
        settingsCard("Wand") {
            HStack(spacing: 14) {
                WandBrandMark(size: 48)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Wand")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                    Text(appVersion)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(Theme.textSecondary)
                }
                Spacer()
            }
            rowDivider
            Link(destination: URL(string: "https://github.com/co0ontty/wand")!) {
                Label("GitHub 仓库", systemImage: "link")
                    .font(.system(size: 13))
            }
        }
    }

    private var localNetworkDescription: String {
        LocalNetworkPermission.isEnforced
            ? "控制 Wand 是否可以发现并连接同一网络中的服务器。"
            : "当前系统中的网络访问状态。"
    }

    private var rowDivider: some View {
        Divider().opacity(0.4)
    }

    private func settingsCard<Content: View>(
        _ title: String,
        description: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                if let description {
                    Text(description)
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textSecondary)
                }
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                .fill(Theme.surfaceElevated)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                        .stroke(Theme.border.opacity(0.72), lineWidth: 0.75)
                )
        )
    }

    private var appVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        guard let stamp = Bundle.main.object(forInfoDictionaryKey: "WandBuildStamp") as? String,
              !stamp.isEmpty else {
            return "v\(short)"
        }
        return "v\(short)+\(stamp)"
    }

    private func infoRow(_ label: String, _ value: String, mono: Bool = false) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 13))
                .foregroundColor(Theme.textSecondary)
            Spacer(minLength: 18)
            Text(value)
                .font(.system(size: 12, design: mono ? .monospaced : .default))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }
}

private enum SettingsPane: String, CaseIterable, Identifiable {
    case connection
    case permissions
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .connection: return "连接与服务"
        case .permissions: return "权限"
        case .about: return "关于"
        }
    }

    var subtitle: String {
        switch self {
        case .connection: return "管理当前服务器，并进入网页版完整设置。"
        case .permissions: return "查看 Wand 在这台 Mac 上使用的系统权限。"
        case .about: return "版本信息与项目链接。"
        }
    }

    var systemImage: String {
        switch self {
        case .connection: return "server.rack"
        case .permissions: return "hand.raised"
        case .about: return "info.circle"
        }
    }
}
