import SwiftUI

/// 桌面固定左侧导航；窄窗口回退目录/详情，访问过的表单保持挂载。
struct SettingsView: View {
    let serverURL: URL
    let token: String?
    let onClose: () -> Void
    let titlebarLeadingInset: CGFloat
    @Environment(\.desktopPageActive) private var pageActive

    @EnvironmentObject private var store: ServerStore

    @State private var serverVersion: String?
    @State private var confirmDisconnect = false
    @State private var selectedPane: SettingsPane?
    @State private var wideNavigation = false
    @State private var visitedPanes: Set<SettingsPane>
    @State private var showTroubleshooting = false
    @State private var permissionDenied: Bool?
    @State private var observationRevision = 0
    @State private var observationGeneration = UUID()
    @State private var betaServerDraft: String
    @State private var betaSourceError: String?
    @State private var savingBetaSource = false
    @FocusState private var focusedPane: SettingsPane?
    @FocusState private var headerFocused: Bool
    @ObservedObject private var updateManager: MacUpdateManager
    private let loadServerVersion: () async -> String?
    private let loadIdentities: () async throws -> (NativeUserProfile, [EmployeeContact])
    private let probePermission: (@escaping (Bool) -> Void) -> Void
    @AppStorage("wand.appearanceMode") private var appearanceMode = "system"
    @AppStorage("wand.sendWithCommandEnter") private var sendWithCommandEnter = false

    init(
        serverURL: URL,
        token: String?,
        onClose: @escaping () -> Void,
        titlebarLeadingInset: CGFloat = 20,
        initialPane: String? = nil,
        updateManager: MacUpdateManager? = nil,
        loadServerVersion: (() async -> String?)? = nil,
        probePermission: @escaping (@escaping (Bool) -> Void) -> Void = LocalNetworkPermission.probeDenied,
        loadIdentities: (() async throws -> (NativeUserProfile, [EmployeeContact]))? = nil
    ) {
        self.serverURL = serverURL
        self.token = token
        self.onClose = onClose
        self.titlebarLeadingInset = titlebarLeadingInset
        let updateManager = updateManager ?? .shared
        let pane = initialPane.flatMap(SettingsPane.init(rawValue:)) ?? .employees
        _selectedPane = State(initialValue: pane)
        _visitedPanes = State(initialValue: Set([pane]))
        _updateManager = ObservedObject(wrappedValue: updateManager)
        _betaServerDraft = State(initialValue: updateManager.betaServerAddress)
        self.loadServerVersion = loadServerVersion ?? {
            (try? await WandAPI(baseURL: serverURL, token: token).serverConfig())?.currentVersion
        }
        self.probePermission = probePermission
        self.loadIdentities = loadIdentities ?? {
            let api = WandAPI(baseURL: serverURL, token: token)
            async let profile = api.communicationsUserProfile()
            async let contacts = api.employeeContacts()
            return try await (profile, contacts)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            settingsHeader
            Divider().overlay(Theme.border)
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    if geometry.size.width >= 720 {
                        settingsDirectory.frame(width: 224)
                        Divider().overlay(Theme.border)
                    }
                    ZStack {
                        if geometry.size.width < 720 {
                            settingsDirectory
                                .opacity(selectedPane == nil ? 1 : 0)
                                .allowsHitTesting(selectedPane == nil)
                                .accessibilityHidden(selectedPane != nil)
                        }
                        ForEach(SettingsPane.allCases.filter { visitedPanes.contains($0) }) { pane in
                            detailPane(pane)
                                .opacity(selectedPane == pane ? 1 : 0)
                                .allowsHitTesting(selectedPane == pane)
                                .accessibilityHidden(selectedPane != pane)
                                .disabled(selectedPane != pane)
                        }
                    }.wandMotion(value: selectedPane)
                }
                .onAppear { wideNavigation = geometry.size.width >= 720 }
                .onChange(of: geometry.size.width) { width in
                    wideNavigation = width >= 720
                    if wideNavigation && selectedPane == nil { visitedPanes.insert(.employees); selectedPane = .employees }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .tint(Theme.accentSolid)
        .onAppear { if pageActive { headerFocused = true } }
        .onChange(of: pageActive) { active in
            observationGeneration = UUID()
            focusedPane = nil
            headerFocused = active
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if pageActive { observationRevision += 1 }
        }
        .background {
            Button(action: navigateBack) { EmptyView() }
                .keyboardShortcut(.cancelAction)
                .disabled(!pageActive || showTroubleshooting || confirmDisconnect)
                .accessibilityHidden(true)
        }
        .task(id: "\(pageActive)-\(observationRevision)") {
            guard pageActive else { return }
            let generation = UUID()
            observationGeneration = generation
            let version = await loadServerVersion()
            guard !Task.isCancelled, observationGeneration == generation else { return }
            serverVersion = version
            probePermission { denied in
                guard observationGeneration == generation else { return }
                permissionDenied = denied
            }
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
                onClose()
                store.disconnect()
            }
            Button("取消", role: .cancel) {}
        }
    }

    private var settingsHeader: some View {
        HStack(spacing: 12) {
            Button(action: navigateBack) {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(WandIconButtonStyle())
            .help(wideNavigation || selectedPane == nil ? "返回工作页" : "返回设置")
            .accessibilityLabel(wideNavigation || selectedPane == nil ? "返回工作页" : "返回设置")
            .accessibilityIdentifier("settings-back")
            .sidebarPresence("settings-back")
            .focused($headerFocused)
            .keyboardShortcut("[", modifiers: .command)
            Text(selectedPane?.title ?? "设置")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
                .accessibilityAddTraits(.isHeader)
            WindowDragRegion().frame(maxWidth: .infinity)
            if selectedPane != nil && !wideNavigation {
                Button("返回工作页", action: onClose)
                    .buttonStyle(WandSecondaryButtonStyle())
                    .accessibilityIdentifier("settings-close-page")
                    .sidebarPresence("settings-close-page")
            }
        }
        .padding(.leading, titlebarLeadingInset).padding(.trailing, 20)
        .frame(height: 56)
        .background(Theme.surface)
        .windowDrag()
    }

    private var settingsDirectory: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                directoryGroup("个人偏好", panes: [.employees, .general])
                directoryGroup("连接与诊断", panes: [.connection, .permissions, .troubleshooting])
                directoryGroup("应用", panes: [.about])
            }
            .frame(maxWidth: 1120, alignment: .leading)
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("settings-directory")
    }

    private func directoryGroup(_ title: String, panes: [SettingsPane]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Theme.textSecondary)
                .padding(.leading, 12)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                ForEach(panes, id: \.id) { pane in
                    if let firstPane = panes.first, pane != firstPane {
                        Divider().padding(.leading, 48)
                    }
                    Button {
                        visitedPanes.insert(pane)
                        selectedPane = pane
                        focusedPane = nil
                        headerFocused = true
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: pane.systemImage)
                                .font(.system(size: 17))
                                .foregroundColor(Theme.textSecondary)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(pane.title)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(Theme.textPrimary)
                                if !wideNavigation { Text(pane.subtitle)
                                    .font(.system(size: 12))
                                    .foregroundColor(Theme.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true) }
                            }
                            Spacer(minLength: 12)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(Theme.textSecondary)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(DesktopNavigationButtonStyle())
                    .background(selectedPane == pane ? Theme.surfaceSoft : Color.clear, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                    .focused($focusedPane, equals: pane)
                    .accessibilityIdentifier("settings-open-\(pane.rawValue)")
                    .sidebarPresence("settings-open-\(pane.rawValue)")
                }
            }
            .background(RoundedRectangle(cornerRadius: Theme.Radius.md).fill(Theme.surface))
        }
    }

    private func navigateBack() {
        guard pageActive, !showTroubleshooting, !confirmDisconnect else { return }
        if selectedPane != nil && !wideNavigation { returnToDirectory() }
        else { onClose() }
    }

    private func returnToDirectory() {
        let previous = selectedPane
        selectedPane = nil
        headerFocused = false
        focusedPane = previous
    }

    private func detailPane(_ pane: SettingsPane) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                switch pane {
                case .employees:
                    SettingsEmployeeIdentities(api: WandAPI(baseURL: serverURL, token: token), loadData: loadIdentities)
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
            .frame(maxWidth: 840, alignment: .leading)
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("settings-detail-\(pane.rawValue)")
    }

    private var generalContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            preferenceRow("外观") {
                Picker("外观", selection: $appearanceMode) {
                    Text("跟随系统").tag("system")
                    Text("浅色").tag("light")
                    Text("深色").tag("dark")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityIdentifier("settings-appearance")
                Text("应用于这台 Mac，切换后立即生效。")
            }
            rowDivider
            preferenceRow("会话内容宽度") {
                ChatContentWidthPicker().labelsHidden()
                Text("默认居中，正文与输入区最多 940pt；铺满使用全部可用区域。窄窗口自动适应。")
                Text("结构化会话、工作区会话与私聊/群聊共用。立即生效并自动保存在这台 Mac，不影响其他设备或终端。")
            }
            rowDivider
            preferenceRow("任务动态与通知") {
                DesktopActivityPreferences(monitor: .shared)
                Text("菜单栏显示所有任务的执行状态；顶部浮层可原位展开，也可临时隐藏。")
            }
            rowDivider
            preferenceRow("消息输入") {
                Picker("发送消息", selection: $sendWithCommandEnter) {
                    Text("Return 发送").tag(false)
                    Text("⌘ Return 发送").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityIdentifier("settings-send-shortcut")
                Text(sendWithCommandEnter
                    ? "Return 换行；按 ⌘ Return 发送。"
                    : "Return 发送；按 ⇧ Return 换行。")
                Text("新建会话页固定用 ⌘ Return 启动，这里的 Return 换行不受影响。")
                Text("终端保留命令行原本的按键行为。")
            }
        }
    }

    private func preferenceRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 24) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Theme.textPrimary)
                .frame(width: 112, alignment: .leading)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 8, content: content)
                .font(.system(size: 12))
                .foregroundColor(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var connectionContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingsSection("当前服务器", description: "Wand 正在通过这个地址同步会话。") {
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
                        onClose()
                        NotificationCenter.default.post(name: .wandRequestSwitchServer, object: nil)
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
        settingsSection("本地网络", description: localNetworkDescription) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: LocalNetworkPermission.isEnforced ? "network.badge.shield.half.filled" : "checkmark.shield")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(LocalNetworkPermission.isEnforced ? Theme.warning : Theme.success)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 6) {
                    Text(permissionTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                    Text(permissionMessage)
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if LocalNetworkPermission.isEnforced {
                Button("打开系统设置") {
                    LocalNetworkPermission.openSettings()
                }
                .buttonStyle(WandSecondaryButtonStyle())
            }
        }
    }

    private var troubleshootingContent: some View {
        settingsSection("连接与权限诊断", description: "检测服务器可达性、安装位置与本地网络权限，并生成可复制的脱敏报告。") {
            Button { showTroubleshooting = true } label: {
                Label("打开故障排查", systemImage: "stethoscope")
            }
            .buttonStyle(WandPrimaryButtonStyle())
        }
    }

    private var aboutContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            settingsSection("应用") {
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

            rowDivider
            updateControlDeck
        }
    }

    /// macOS 客户端更新通道是本机偏好，不跟随当前连接服务的 Web 更新通道。
    private var updateControlDeck: some View {
        settingsSection("客户端更新", description: "检查新版本，选择适合你的更新通道。") {
            HStack(spacing: 11) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
                    .frame(width: 24, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(updateManager.isChecking
                        ? (updateManager.channel == .beta ? "正在检查 Beta 更新服务器" : "正在检查 GitHub Release")
                        : "当前 \(appVersion)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                    Text(updateManager.pendingInstall != nil
                        ? "新版本已准备好，等待重启"
                        : updateManager.availableUpdate != nil
                            ? "新版本可以自动更新"
                            : (updateManager.channel == .beta
                                ? (updateManager.betaUsesCustomServer ? "从自定义服务器获取 Beta 包" : "从连接的服务器获取 Beta 包")
                                : "通过 GitHub Release 保持最新"))
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textSecondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            preferenceRow("更新通道") {
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
                .frame(maxWidth: 240, alignment: .leading)
                .accessibilityIdentifier("settings-update-channel")
                .disabled(updateManager.isChecking || updateManager.isInstalling || updateManager.pendingInstall != nil || savingBetaSource)
            }
            if updateManager.channel == .beta {
                betaSourceEditor
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
                    Text("\(update.channel == .beta ? "Beta 更新服务器" : "GitHub Release") · \(asset.fileExtension.uppercased()) · \(ByteCountFormatter.string(fromByteCount: asset.size, countStyle: .file)) · \(integrity)")
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
                    ? (updateManager.channel == .beta ? "使用所选服务器检查 Beta 更新" : "启动后将自动检查 GitHub Release")
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
                        .disabled(updateManager.isChecking || updateManager.isInstalling)
                }
                if let update = updateManager.availableUpdate {
                    if update.preferredAsset != nil, UpdateInstaller.canInstallInPlace {
                        Button("立即更新") { installUpdate() }
                            .buttonStyle(WandSecondaryButtonStyle())
                            .disabled(updateManager.isInstalling)
                    }
                    Button(update.channel == .beta ? "打开服务器" : "查看 Release") { NSWorkspace.shared.open(update.releaseURL) }
                        .buttonStyle(WandSecondaryButtonStyle())
                } else if let pending = updateManager.pendingInstall {
                    Button("打开更新源") { NSWorkspace.shared.open(pending.releaseURL) }
                        .buttonStyle(WandSecondaryButtonStyle())
                }
            }
            Text(updateManager.channel == .beta
                ? "Beta 仅使用所选 Wand 服务器的本地 ZIP（DMG 兜底）；留空使用当前连接，切回 Stable 不会自动降级。"
                : "Stable 通道不会接收 GitHub prerelease。")
                .font(.system(size: 12))
                .foregroundColor(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var betaSourceEditor: some View {
        preferenceRow("Beta 更新地址") {
            TextField("留空使用当前连接的服务器", text: $betaServerDraft)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Beta 更新服务器地址")
                .accessibilityIdentifier("settings-beta-server")
                .onSubmit { saveBetaSource() }
                .disabled(betaSourceLocked)
            Text("可填写另一台 Wand Server 的 http:// 或 https:// 地址。仅用于 Beta 检查和下载，不改变当前连接，也不会发送当前连接的凭据。")
            if let betaSourceError {
                Text(betaSourceError)
                    .foregroundColor(Theme.danger)
                    .accessibilityIdentifier("settings-beta-source-error")
            }
            HStack(spacing: 8) {
                Button(savingBetaSource ? "正在检查…" : "保存并检查") { saveBetaSource() }
                    .buttonStyle(WandSecondaryButtonStyle())
                    .accessibilityIdentifier("settings-beta-source-save")
                    .disabled(betaSourceLocked || !betaSourceHasChanges)
                if updateManager.betaUsesCustomServer || !betaServerDraft.isEmpty {
                    Button("使用当前连接") {
                        betaServerDraft = ""
                        saveBetaSource()
                    }
                    .buttonStyle(.link)
                    .disabled(betaSourceLocked)
                }
            }
            if updateManager.pendingInstall != nil {
                Text("已校验的待安装包保留原更新来源；完成更新后可修改地址。")
            } else if betaSourceHasChanges {
                Text("地址尚未保存；下方检查与更新仍使用已保存的来源。")
            } else {
                Text(updateManager.betaUsesCustomServer ? "已保存 · 使用自定义服务器" : "使用当前连接的服务器")
            }
            if let source = updateManager.betaServerURL {
                Text(source.absoluteString)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .accessibilityLabel("当前 Beta 更新来源：\(source.absoluteString)")
            } else {
                Text("尚未连接服务器，可填写自定义地址。")
            }
        }
    }

    private var betaSourceHasChanges: Bool {
        betaServerDraft.trimmingCharacters(in: .whitespacesAndNewlines) != updateManager.betaServerAddress
    }

    private var betaSourceLocked: Bool {
        savingBetaSource || updateManager.isChecking || updateManager.isInstalling || updateManager.pendingInstall != nil
    }

    private func saveBetaSource() {
        guard updateManager.channel == .beta, !betaSourceLocked else { return }
        let submitted = betaServerDraft
        savingBetaSource = true
        betaSourceError = nil
        Task { @MainActor in
            defer { savingBetaSource = false }
            do {
                _ = try await updateManager.setBetaServerAddress(submitted)
                if betaServerDraft == submitted { betaServerDraft = updateManager.betaServerAddress }
            } catch {
                betaSourceError = error.localizedDescription
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

    private func installUpdate() {
        UpdateFlowController.shared.start()
    }

    private var localNetworkDescription: String {
        LocalNetworkPermission.isEnforced
            ? "控制 Wand 是否可以发现并连接同一网络中的服务器。"
            : "当前系统中的网络访问状态。"
    }

    private var rowDivider: some View {
        Divider().overlay(Theme.border)
    }

    private func settingsSection<Content: View>(
        _ title: String,
        description: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                    .accessibilityAddTraits(.isHeader)
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
        HStack(alignment: .firstTextBaseline, spacing: 24) {
            Text(label)
                .font(.system(size: 13))
                .foregroundColor(Theme.textSecondary)
                .frame(width: 112, alignment: .leading)
            Text(value)
                .font(.system(size: 12, design: mono ? .monospaced : .default))
                .foregroundColor(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }
}

/// Directory and details occupy the same content column, never a third navigation rail.
private struct SettingsEmployeeIdentities: View {
    let api: WandAPI
    let loadData: () async throws -> (NativeUserProfile, [EmployeeContact])
    @State private var profile = NativeUserProfile()
    @State private var employees: [EmployeeContact] = []
    @State private var selectedID: String? = "user"
    @State private var name = ""
    @State private var avatar = ""
    @State private var savedName = ""
    @State private var savedAvatar = ""
    @State private var loading = true
    @State private var busy = false
    @State private var error: String?
    @State private var result: String?
    @State private var discard = false
    @State private var needsAdmin = false
    @State private var adminPassword = ""
    @State private var imDirty = false
    @State private var imBusy = false
    private var selected: EmployeeContact? { employees.first { $0.id == selectedID } }
    private var dirty: Bool { name != savedName || avatar != savedAvatar }
    private var locked: Bool { selected?.systemKey != nil && PlushAvatarIdentity.fixedAsset(id: selectedID ?? "") == nil }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if loading { ProgressView("正在读取资料…") }
            if let error { Text(error).foregroundColor(Theme.danger); Button("重新加载") { Task { await load() } }.disabled(busy) }
            if needsAdmin {
                Text("修改资料需要管理员登录；当前草稿已保留，连接应用权限不会自动扩大。")
                    .font(.system(size: 12)).foregroundColor(Theme.textSecondary)
                SecureField("管理员密码", text: $adminPassword).textFieldStyle(.roundedBorder).disabled(busy)
                Button(busy ? "登录中…" : "登录管理设置") { Task { await authenticate() } }
                    .buttonStyle(WandSecondaryButtonStyle()).disabled(busy || adminPassword.isEmpty)
            }
            if selectedID == nil {
                identityRow(id: "user", name: profile.displayName + " · 我", avatar: profile.avatar, subtitle: "我的资料 · 消息署名与头像")
                ForEach(employees.filter { !$0.isArchived }) { employee in
                    identityRow(id: employee.id, name: employee.name, avatar: employee.avatar ?? "", subtitle: employee.duty)
                }
            } else {
                Button("返回员工列表") { if dirty || imDirty { discard = true } else { selectedID = nil } }
                    .buttonStyle(WandSecondaryButtonStyle()).disabled(busy || imBusy).accessibilityIdentifier("settings-employee-directory")
                Text(selectedID == "user" ? "我的资料" : selected?.name ?? "员工").font(.system(size: 20, weight: .semibold))
                Text(selectedID == "user" ? "消息署名与头像；只影响显示，不改变执行身份或权限。名字留空时显示「我」。" : "员工身份与群聊显示使用同一份资料。")
                    .font(.system(size: 12)).foregroundColor(Theme.textSecondary)
                TextField("显示名字", text: $name).textFieldStyle(.roundedBorder).disabled(loading || busy || locked)
                    .accessibilityIdentifier("settings-profile-name")
                IdentityAvatarPicker(id: selectedID ?? "user", name: name, avatar: $avatar, disabled: loading || busy || locked || PlushAvatarIdentity.fixedAsset(id: selectedID ?? "") != nil)
                if let selected {
                    Text(selected.duty).textSelection(.enabled)
                    ForEach(Array(selected.candidates.enumerated()), id: \.offset) { candidate in
                        Text("\(candidate.offset == 0 ? "首选" : "候选") · \(candidate.element.toolLabel) · \(candidate.element.model ?? "默认模型")")
                            .font(.system(size: 12)).foregroundColor(Theme.textSecondary)
                    }
                    if locked { Text("内置员工身份固定；保留其现有执行配置。").font(.system(size: 12)).foregroundColor(Theme.textSecondary) }
                    if selectedID != "user" {
                        Divider().padding(.vertical, 4)
                        EmployeeImConfigEditor(api: api, employeeID: selected.id, onNeedsAdmin: { needsAdmin = true },
                            onDirtyChange: { imDirty = $0 }, onBusyChange: { imBusy = $0 })
                            .disabled(busy)
                            .id(selected.id)
                    }
                }
                Button { Task { await save() } } label: {
                    ZStack {
                        Text("保存资料").opacity(busy || result != nil ? 0 : 1)
                        if busy { ProgressView().controlSize(.small) }
                        if let result { Text(result).lineLimit(1) }
                    }.frame(width: 160, height: 20)
                }.buttonStyle(WandPrimaryButtonStyle()).disabled(loading || busy || needsAdmin || locked || name.count > (selectedID == "user" ? 24 : 80))
                .accessibilityIdentifier("settings-profile-save")
            }
        }
        .task { await load() }
        .onChange(of: name) { _ in if !busy { result = nil } }
        .onChange(of: avatar) { _ in if !busy { result = nil } }
        .confirmationDialog("放弃尚未保存的修改？", isPresented: $discard, titleVisibility: .visible) {
            Button("放弃修改", role: .destructive) { selectedID = nil; imDirty = false }
            Button("继续编辑", role: .cancel) {}
        }
    }
    private func identityRow(id: String, name: String, avatar: String, subtitle: String) -> some View {
        Button {
            selectedID = id; imDirty = false; imBusy = false
            let employee = employees.first { $0.id == id }
            self.name = id == "user" ? profile.name : employee?.name ?? ""
            self.avatar = id == "user" ? profile.avatar : employee?.avatar ?? ""
            savedName = self.name; savedAvatar = self.avatar; result = nil
        } label: {
            HStack(spacing: 12) {
                ContactAvatar(id: id, avatar: avatar, name: name, size: 48)
                VStack(alignment: .leading, spacing: 4) {
                    Text(name).font(.system(size: 14, weight: .medium))
                    Text(subtitle).font(.system(size: 12)).foregroundColor(Theme.textSecondary).lineLimit(2)
                }
                Spacer(); Image(systemName: "chevron.right")
            }.padding(12).contentShape(Rectangle())
        }.buttonStyle(DesktopNavigationButtonStyle())
    }
    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let (profile, employees) = try await loadData()
            guard !Task.isCancelled else { return }
            self.profile = profile; self.employees = employees; error = nil
            if selectedID == "user" && !dirty { name = profile.name; avatar = profile.avatar; savedName = name; savedAvatar = avatar }
        } catch { self.error = "资料读取失败，请重试。" }
    }
    private func save() async {
        guard !busy, !loading else { return }
        let id = selectedID ?? "user", submittedName = name, submittedAvatar = avatar
        busy = true; error = nil; result = nil
        defer { busy = false }
        do {
            if id == "user" { profile = try await api.saveUserProfile(NativeUserProfile(name: submittedName, avatar: submittedAvatar)); name = profile.name; avatar = profile.avatar }
            else {
                let employee = try await api.saveEmployeeIdentity(id: id, name: submittedName, avatar: submittedAvatar)
                employees = employees.map { $0.id == id ? employee : $0 }; name = employee.name; avatar = employee.avatar ?? ""
            }
            savedName = name; savedAvatar = avatar; result = "已保存"
            NotificationCenter.default.post(name: .wandIdentitySaved, object: nil)
        } catch {
            result = "保存失败，请重试"; self.error = error.localizedDescription
            if let failure = error as? WandAPI.APIError, case .server(status: 403, message: _) = failure { needsAdmin = true }
        }
    }
    private func authenticate() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            _ = try await api.requestData(method: "POST", path: "/api/login", body: ["password": adminPassword])
            // Recheck the authoritative permission; never treat a non-admin login as an unlock.
            _ = try await api.requestData(method: "GET", path: "/api/settings")
            adminPassword = ""; needsAdmin = false; error = nil; result = nil
        } catch { self.error = "管理员登录失败；草稿已保留。" }
    }
}

private enum SettingsPane: String, CaseIterable, Identifiable {
    case employees
    case general
    case connection
    case permissions
    case troubleshooting
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .employees: return "员工"
        case .general: return "通用"
        case .connection: return "连接与服务"
        case .permissions: return "权限"
        case .troubleshooting: return "故障排查"
        case .about: return "关于"
        }
    }

    var subtitle: String {
        switch self {
        case .employees: return "我的资料与员工配置。"
        case .general: return "让 Wand 适合你的工作习惯。"
        case .connection: return "查看当前服务器，或切换连接。"
        case .permissions: return "查看 Wand 在这台 Mac 上使用的系统权限。"
        case .troubleshooting: return "诊断连接与本地网络权限问题。"
        case .about: return "版本信息、客户端更新与 Beta 更新地址。"
        }
    }

    var systemImage: String {
        switch self {
        case .employees: return "person.2"
        case .general: return "slider.horizontal.3"
        case .connection: return "server.rack"
        case .permissions: return "hand.raised"
        case .troubleshooting: return "stethoscope"
        case .about: return "info.circle"
        }
    }
}
