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
    @State private var showTroubleshooting = false
    @State private var permissionDenied: Bool?
    @ObservedObject private var releaseUpdater = GitHubReleaseUpdater.shared
    private let dmgInstaller = DmgInstaller()

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
        .background(WandAmbientBackground())
        .task {
            serverVersion = (try? await api.serverConfig())?.currentVersion
            LocalNetworkPermission.probeDenied { permissionDenied = $0 }
        }
        .sheet(isPresented: $showTroubleshooting) {
            TroubleshootingView(
                context: TroubleshootingContext(
                    serverURL: serverURL,
                    errorMessage: nil,
                    source: "设置"
                )
            )
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
            WandBrandMark(size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text("系统设置")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                Text("连接、设备和工作流偏好")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textSecondary)
            }
            Spacer()
            Text(appVersion)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Theme.textSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Capsule().fill(Theme.surface.opacity(0.75)))
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
                settingsOverview
                detailHeader
                switch selectedPane {
                case .connection:
                    connectionContent
                case .permissions:
                    permissionsContent
                case .troubleshooting:
                    troubleshootingContent
                case .about:
                    aboutContent
                }
            }
            .frame(maxWidth: 620, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WandAmbientBackground())
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

    /// 与 Android 的 SettingsOverview 对齐：任何设置子页都先能判断这台设备的状态。
    private var settingsOverview: some View {
        HStack(spacing: 12) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(Theme.brand)
                .frame(width: 36, height: 36)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.brand.opacity(0.13)))
            VStack(alignment: .leading, spacing: 3) {
                Text("此 Mac 上的 Wand")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                Text(serverURL.host ?? serverURL.absoluteString)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 10)
            settingsStatePill(token?.isEmpty == false ? "已安全连接" : "已连接", color: Theme.success)
            settingsStatePill("macOS", color: Theme.brand)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                .fill(Theme.surfaceElevated)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                        .stroke(Theme.border.opacity(0.72), lineWidth: 0.75)
                )
        )
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
                    Text(permissionTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                    Text(permissionMessage)
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

    private var troubleshootingContent: some View {
        settingsCard("连接与权限诊断", description: "检测服务器可达性、安装位置与本地网络权限，并生成可复制的脱敏报告。") {
            Button { showTroubleshooting = true } label: {
                Label("打开故障排查", systemImage: "stethoscope")
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.brand)
        }
    }

    private var aboutContent: some View {
        VStack(alignment: .leading, spacing: 16) {
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

            updateControlDeck
        }
    }

    /// 桌面端直接查询官方 GitHub Release，而不是依赖当前连接的 Wand 服务。
    /// 这样即使服务离线或切换服务器，更新入口仍然可用。
    private var updateControlDeck: some View {
        settingsCard("保持在最新版本", description: "每天自动从 GitHub Release 检查；强制检查会忽略间隔立即请求。") {
            HStack(spacing: 11) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(Theme.success)
                    .frame(width: 36, height: 36)
                    .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.success.opacity(0.13)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(releaseUpdater.isChecking ? "正在检查 GitHub Release" : "当前 \(appVersion)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                    Text(releaseUpdater.availableUpdate != nil
                        ? "新版本已准备好下载"
                        : "通过 GitHub Release 安装新版客户端")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textSecondary)
                }
                Spacer()
            }
            if releaseUpdater.isChecking {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("正在检查更新…") }
                    .font(.system(size: 12)).foregroundColor(Theme.textSecondary)
            } else if let update = releaseUpdater.availableUpdate {
                Text("发现 v\(update.latestVersion)")
                    .font(.system(size: 13, weight: .semibold))
                if let asset = update.dmgAsset {
                    Text("GitHub Release · \(ByteCountFormatter.string(fromByteCount: asset.size, countStyle: .file))")
                        .font(.system(size: 11)).foregroundColor(Theme.textSecondary)
                } else {
                    Text("该 Release 未附带 macOS DMG，可在 GitHub 页面手动下载。")
                        .font(.system(size: 11)).foregroundColor(Theme.warning)
                }
                if let updateError = releaseUpdater.lastError {
                    Text(updateError).font(.system(size: 12)).foregroundColor(Theme.danger)
                }
            } else if let updateError = releaseUpdater.lastError {
                Text(updateError).font(.system(size: 12)).foregroundColor(Theme.danger)
            } else {
                Text(releaseUpdater.lastSuccessfulCheck == nil ? "将自动检查 GitHub Release" : "当前已是最新版本")
                    .font(.system(size: 12)).foregroundColor(Theme.textSecondary)
            }
            HStack(spacing: 8) {
                Button("强制检查更新") { Task { _ = await releaseUpdater.checkManually() } }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.brand)
                    .disabled(releaseUpdater.isChecking)
                if let update = releaseUpdater.availableUpdate {
                    if update.dmgAsset != nil {
                        Button("下载并打开 DMG") { downloadUpdate(update) }
                            .buttonStyle(.bordered)
                    }
                    Button("查看 Release") { NSWorkspace.shared.open(update.releaseURL) }
                        .buttonStyle(.bordered)
                }
            }
        }
    }

    private var permissionTitle: String {
        if !LocalNetworkPermission.isEnforced { return "无需额外授权" }
        if permissionDenied == true { return "检测到已拒绝" }
        if permissionDenied == false { return "未检测到明确拒绝" }
        return "正在检测"
    }

    private var permissionMessage: String {
        if !LocalNetworkPermission.isEnforced { return "当前 macOS 版本不会单独限制 Wand 的局域网访问。" }
        if permissionDenied == true { return "系统正在阻止 Wand 访问局域网，请打开权限后重新检测。" }
        return "macOS 不提供可直接读取的授权状态；连接异常时可用故障排查进一步检测。"
    }

    private func downloadUpdate(_ update: GitHubReleaseUpdater.Update) {
        guard let asset = update.dmgAsset else { return }
        dmgInstaller.downloadAndMount(
            urlString: asset.downloadURL.absoluteString,
            fileName: asset.name,
            presentingWindow: NSApp.keyWindow
        )
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

    private func settingsStatePill(_ label: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).lineLimit(1)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundColor(Theme.textPrimary)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Capsule().fill(color.opacity(0.10)))
        .overlay(Capsule().stroke(color.opacity(0.18), lineWidth: 0.6))
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
    case troubleshooting
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .connection: return "连接与服务"
        case .permissions: return "权限"
        case .troubleshooting: return "故障排查"
        case .about: return "关于"
        }
    }

    var subtitle: String {
        switch self {
        case .connection: return "管理当前服务器，并进入网页版完整设置。"
        case .permissions: return "查看 Wand 在这台 Mac 上使用的系统权限。"
        case .troubleshooting: return "诊断连接与本地网络权限问题。"
        case .about: return "版本信息与项目链接。"
        }
    }

    var systemImage: String {
        switch self {
        case .connection: return "server.rack"
        case .permissions: return "hand.raised"
        case .troubleshooting: return "stethoscope"
        case .about: return "info.circle"
        }
    }
}
