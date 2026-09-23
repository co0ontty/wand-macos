import SwiftUI

/// macOS 设置使用稳定的侧栏/详情结构：侧栏负责定位，详情区承载当前任务，
/// 避免把桌面宽度浪费在一条不断向下延伸的卡片列上。
struct SettingsView: View {
    let serverURL: URL
    let token: String?

    @EnvironmentObject private var store: ServerStore
    @Environment(\.dismiss) private var dismiss

    @State private var serverVersion: String?
    @State private var confirmDisconnect = false
    @State private var selectedPane: SettingsPane
    @State private var showTroubleshooting = false
    @State private var permissionDenied: Bool?
    @ObservedObject private var updateManager = MacUpdateManager.shared
    @AppStorage("wand.appearanceMode") private var appearanceMode = "system"
    @AppStorage("wand.sendWithCommandEnter") private var sendWithCommandEnter = false

    init(
        serverURL: URL,
        token: String?,
        initialPane: String = "general"
    ) {
        self.serverURL = serverURL
        self.token = token
        _selectedPane = State(initialValue: SettingsPane(rawValue: initialPane) ?? .general)
    }

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
        .frame(minWidth: 700, idealWidth: 800, minHeight: 540, idealHeight: 620)
        .background(WandAmbientBackground())
        .tint(Theme.accentSolid)
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
            Text("设置")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
            Spacer()
            Button("完成") { dismiss() }
                .buttonStyle(WandSecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(Theme.background)
    }

    private var settingsSidebar: some View {
        ScrollView {
            VStack(spacing: 4) {
                ForEach(SettingsPane.allCases) { pane in
                    Button {
                        selectedPane = pane
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: pane.systemImage)
                                .font(.system(size: 13, weight: .regular))
                                .frame(width: 18)
                            Text(pane.title)
                                .font(.system(size: 13, weight: selectedPane == pane ? .medium : .regular))
                            Spacer(minLength: 0)
                        }
                        .foregroundColor(selectedPane == pane ? Theme.textPrimary : Theme.textSecondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 11)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(DesktopNavigationButtonStyle(active: selectedPane == pane))
                    .accessibilityValue(selectedPane == pane ? "已选择" : "")
                }
            }
            .padding(12)
        }
        .frame(minWidth: 176, idealWidth: 190, maxWidth: 220)
        .background(Theme.sidebarBackground)
        .wandMotion(value: selectedPane)
    }

    private var detailPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                detailHeader
                switch selectedPane {
                case .general:
                    generalContent
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
            .padding(.horizontal, 32)
            .padding(.vertical, 30)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .id(selectedPane)
    }

    private var generalContent: some View {
        VStack(alignment: .leading, spacing: 28) {
            settingsCard("外观", description: "应用于这台 Mac，切换后立即生效。") {
                HStack(spacing: 12) {
                    appearanceOption("system", title: "跟随系统", symbol: "circle.lefthalf.filled")
                    appearanceOption("light", title: "浅色", symbol: "sun.max")
                    appearanceOption("dark", title: "深色", symbol: "moon")
                }
            }

            settingsCard("消息输入", description: "选择你在对话输入框中使用的发送方式。") {
                Picker("发送消息", selection: $sendWithCommandEnter) {
                    Text("Return 发送").tag(false)
                    Text("⌘ Return 发送").tag(true)
                }
                .pickerStyle(.segmented)
                Text(sendWithCommandEnter
                    ? "Return 换行；按 ⌘ Return 发送。"
                    : "Return 发送；按 ⇧ Return 换行。")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textSecondary)
                Text("终端保留命令行原本的按键行为。")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textTertiary)
            }
        }
    }

    private func appearanceOption(_ value: String, title: String, symbol: String) -> some View {
        let isSelected = appearanceMode == value
        return Button { appearanceMode = value } label: {
            VStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 23, weight: .regular))
                    .frame(height: 34)
                HStack(spacing: 5) {
                    Text(title).font(.system(size: 12, weight: .medium))
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.brand)
                        .opacity(isSelected ? 1 : 0)
                }
            }
            .foregroundColor(isSelected ? Theme.textPrimary : Theme.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.md).fill(
                isSelected ? Theme.surfaceElevated : Theme.surface
            ))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md).stroke(
                isSelected ? Theme.brand : Theme.border.opacity(0.7), lineWidth: isSelected ? 1 : 0.5
            ))
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
        }
        .buttonStyle(DesktopNavigationButtonStyle())
        .wandMotion(value: isSelected)
        .accessibilityLabel("\(title)外观")
        .accessibilityValue(isSelected ? "已选择" : "未选择")
    }

    private var detailHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(selectedPane.title)
                .font(.system(size: 24, weight: .semibold))
                .tracking(-0.4)
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
                    .buttonStyle(WandSecondaryButtonStyle())
                    Spacer(minLength: 8)
                    Button("断开连接", role: .destructive) {
                        confirmDisconnect = true
                    }
                    .buttonStyle(.link)
                    .foregroundColor(Theme.danger)
                }
                .font(.system(size: 13))
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
                    .buttonStyle(WandSecondaryButtonStyle())
                }
            }
        }
    }

    private var troubleshootingContent: some View {
        settingsCard("连接与权限诊断", description: "检测服务器可达性、安装位置与本地网络权限，并生成可复制的脱敏报告。") {
            Button { showTroubleshooting = true } label: {
                Label("打开故障排查", systemImage: "stethoscope")
            }
            .buttonStyle(WandPrimaryButtonStyle())
        }
    }

    private var aboutContent: some View {
        VStack(alignment: .leading, spacing: 28) {
            settingsCard("应用") {
                HStack(spacing: 14) {
                    WandBrandMark(size: 36)
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

    /// macOS 客户端更新通道是本机偏好，不跟随当前连接服务的 Web 更新通道。
    private var updateControlDeck: some View {
        settingsCard("客户端更新", description: "检查新版本，选择适合你的更新通道。") {
            HStack(spacing: 11) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
                    .frame(width: 24, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(updateManager.isChecking
                        ? (updateManager.channel == .beta ? "正在检查连接的服务器" : "正在检查 GitHub Release")
                        : "当前 \(appVersion)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                    Text(updateManager.pendingInstall != nil
                        ? "新版本已准备好，等待重启"
                        : updateManager.availableUpdate != nil
                            ? "新版本可以自动更新"
                            : (updateManager.channel == .beta ? "从连接的服务器获取 Beta 包" : "通过 GitHub Release 保持最新"))
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textSecondary)
                }
                Spacer()
                Picker("更新通道", selection: Binding(
                    get: { updateManager.channel },
                    set: { channel in
                        Task { _ = await updateManager.setChannel(channel) }
                    }
                )) {
                    ForEach(MacUpdateManager.Channel.allCases) { channel in
                        Text(channel.title).tag(channel)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 150)
                .disabled(updateManager.isChecking || updateManager.pendingInstall != nil)
            }
            if updateManager.isChecking {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("正在检查更新…") }
                    .font(.system(size: 12)).foregroundColor(Theme.textSecondary)
            } else if let pending = updateManager.pendingInstall {
                Text("v\(pending.version) 已下载并通过校验")
                    .font(.system(size: 13, weight: .semibold))
                Text("待安装包最多保留 7 天；重启后会自动替换并验证新版是否成功启动。")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textSecondary)
            } else if let update = updateManager.availableUpdate {
                Text("发现 v\(update.latestVersion)")
                    .font(.system(size: 13, weight: .semibold))
                if let asset = update.preferredAsset {
                    let integrity = asset.sha256 == nil ? "签名校验" : "SHA-256 + 签名校验"
                    Text("\(update.channel == .beta ? "连接的服务器" : "GitHub Release") · \(asset.fileExtension.uppercased()) · \(ByteCountFormatter.string(fromByteCount: asset.size, countStyle: .file)) · \(integrity)")
                        .font(.system(size: 11)).foregroundColor(Theme.textSecondary)
                    if let reason = UpdateInstaller.installBlockReason {
                        Text(reason)
                            .font(.system(size: 11)).foregroundColor(Theme.warning)
                    }
                } else {
                    Text("更新源未附带匹配版本的 macOS ZIP 或 DMG。")
                        .font(.system(size: 11)).foregroundColor(Theme.warning)
                }
                if let updateError = updateManager.lastError {
                    Text(updateError).font(.system(size: 12)).foregroundColor(Theme.danger)
                }
            } else if let updateError = updateManager.lastError {
                Text(updateError).font(.system(size: 12)).foregroundColor(Theme.danger)
            } else {
                Text(updateManager.lastSuccessfulCheck == nil
                    ? (updateManager.channel == .beta ? "连接服务器后自动检查 Beta 更新" : "启动后将自动检查 GitHub Release")
                    : "当前已是最新版本")
                    .font(.system(size: 12)).foregroundColor(Theme.textSecondary)
            }
            HStack(spacing: 8) {
                if updateManager.pendingInstall != nil {
                    Button("重启完成更新") { UpdateFlowController.shared.relaunchPending() }
                        .buttonStyle(WandPrimaryButtonStyle())
                } else {
                    Button("强制检查更新") { Task { _ = await updateManager.check(.manual) } }
                        .buttonStyle(WandPrimaryButtonStyle())
                        .disabled(updateManager.isChecking)
                }
                if let update = updateManager.availableUpdate {
                    if update.preferredAsset != nil, UpdateInstaller.canInstallInPlace {
                        Button("立即更新") { installUpdate() }
                            .buttonStyle(WandSecondaryButtonStyle())
                    }
                    Button(update.channel == .beta ? "打开服务器" : "查看 Release") { NSWorkspace.shared.open(update.releaseURL) }
                        .buttonStyle(WandSecondaryButtonStyle())
                } else if let pending = updateManager.pendingInstall {
                    Button("打开更新源") { NSWorkspace.shared.open(pending.releaseURL) }
                        .buttonStyle(WandSecondaryButtonStyle())
                }
            }
            Text(updateManager.channel == .beta
                ? "Beta 仅使用当前连接服务器的本地 ZIP（DMG 兜底）；切回 Stable 不会自动降级。"
                : "Stable 通道不会接收 GitHub prerelease。")
                .font(.system(size: 10))
                .foregroundColor(Theme.textSecondary)
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

    private func installUpdate() {
        UpdateFlowController.shared.start()
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
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                if let description {
                    Text(description)
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 20)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.border.opacity(0.6)).frame(height: 0.5)
        }
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
    case general
    case connection
    case permissions
    case troubleshooting
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "通用"
        case .connection: return "连接与服务"
        case .permissions: return "权限"
        case .troubleshooting: return "故障排查"
        case .about: return "关于"
        }
    }

    var subtitle: String {
        switch self {
        case .general: return "让 Wand 适合你的工作习惯。"
        case .connection: return "查看当前服务器，或切换连接。"
        case .permissions: return "查看 Wand 在这台 Mac 上使用的系统权限。"
        case .troubleshooting: return "诊断连接与本地网络权限问题。"
        case .about: return "版本信息与项目链接。"
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .connection: return "server.rack"
        case .permissions: return "hand.raised"
        case .troubleshooting: return "stethoscope"
        case .about: return "info.circle"
        }
    }
}
