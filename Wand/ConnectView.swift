import SwiftUI

/// 连接界面：输入服务器地址（host:port，自动判别 http/https）或 wand 设置页生成的"连接码"。
/// 解析与可达性探测统一收敛到 `WandAuth.resolve`，错误就地内联展示，不再依赖弹窗。
struct ConnectView: View {
    @EnvironmentObject var store: ServerStore

    var isPresentedAsSheet: Bool = false
    var reconnectingServerURL: URL? = nil
    var onDismiss: (() -> Void)? = nil

    @State private var input: String = ""
    @State private var error: String? = nil
    @State private var isConnecting = false
    @State private var inputVisible = false
    @State private var showTroubleshooting = false
    @FocusState private var inputFocused: Bool

    /// 「本地网络」权限引导：nil = 不展示；false = 提示性引导（无法确定是否被拒）；
    /// true = 已探测到被系统拒绝。仅 macOS 15+ 且目标地址像局域网时出现。
    @State private var localNetworkDenied: Bool? = nil
    private let sheetHeaderHeight: CGFloat = 68

    private var trimmedInput: String {
        input.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                WandAmbientBackground()
                VStack(spacing: 0) {
                    if isPresentedAsSheet {
                        sheetHeader
                    }
                    ScrollView {
                        card(wide: geometry.size.width >= 860)
                            .frame(maxWidth: isPresentedAsSheet ? 520 : 900)
                            .padding(.horizontal, 28)
                            .padding(.vertical, isPresentedAsSheet ? 28 : 48)
                            .frame(minHeight: max(0, geometry.size.height - (isPresentedAsSheet ? sheetHeaderHeight : 0)))
                            .frame(maxWidth: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(
            minWidth: isPresentedAsSheet ? 520 : nil,
            minHeight: isPresentedAsSheet ? 540 : nil
        )
        .wandMotion(value: error != nil, layout: true)
        .wandMotion(value: localNetworkDenied, layout: true)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { inputFocused = true }
        }
        .sheet(isPresented: $showTroubleshooting) {
            TroubleshootingView(
                context: TroubleshootingContext(
                    serverURL: troubleshootingURL,
                    errorMessage: error,
                    source: "连接服务器"
                ),
                onRetry: connect
            )
        }
    }

    // MARK: - 区块

    private var sheetHeader: some View {
        HStack {
            Text(reconnectingServerURL == nil ? "切换服务器" : "重新登录")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
            Spacer()
            Button("取消") { onDismiss?() }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(WandSecondaryButtonStyle())
        }
        .padding(.horizontal, 24)
        .frame(height: sheetHeaderHeight)
        .background(Theme.background)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: Theme.borderSubtle))
                .frame(height: 0.5)
        }
    }

    @ViewBuilder
    private func card(wide: Bool) -> some View {
        if isPresentedAsSheet || !wide {
            compactCard
                .frame(maxWidth: 500)
        } else {
            desktopCard
        }
    }

    private var desktopCard: some View {
        HStack(alignment: .center, spacing: 52) {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 14) {
                    WandBrandMark(size: 42)
                    Text("Wand")
                        .font(.system(size: 32, weight: .medium))
                        .tracking(-0.8)
                        .foregroundColor(Theme.textPrimary)
                }
                Text("连接已有的 Wand 服务，\n继续你的会话与任务。")
                    .font(.system(size: 15))
                    .lineSpacing(6)
                    .foregroundColor(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 252, alignment: .leading)
            Rectangle()
                .fill(Theme.border.opacity(0.65))
                .frame(width: 0.5, height: 220)
            connectionCard
                .frame(maxWidth: 390)
        }
    }

    private var compactCard: some View {
        VStack(alignment: .leading, spacing: 28) {
            if !isPresentedAsSheet {
                WandBrandMark(size: 40)
            }
            connectionCard
        }
    }

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 28) {
            if !isPresentedAsSheet {
                intro
            }
            formContent
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("连接服务器")
                .font(.system(size: 24, weight: .semibold))
                .tracking(-0.4)
                .foregroundColor(Theme.textPrimary)
            Text("使用连接码，或输入服务器地址。")
                .font(.system(size: 13))
                .foregroundColor(Theme.textSecondary)
        }
    }

    private var formContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            inputField

            if let error {
                errorBanner(error).transition(.opacity)
            }

            if let denied = localNetworkDenied {
                localNetworkHint(denied: denied).transition(.opacity)
            }

            connectButton

            if !store.recentInputs.isEmpty {
                recentSection
            }

            footerHint
        }
    }

    private var inputField: some View {
        VStack(alignment: .leading, spacing: 7) {
            if reconnectingServerURL != nil {
                Text("登录已失效，请从服务器设置获取新的连接码并粘贴到下方。原来的会话和内容会保留。")
                    .font(.system(size: 12)).foregroundColor(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("连接码或地址")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Theme.textSecondary)

            HStack(spacing: 8) {
                Image(systemName: "link")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.textSecondary)
                Group {
                    if inputVisible {
                        TextField("粘贴连接码或输入地址", text: $input)
                    } else {
                        SecureField("粘贴连接码或输入地址", text: $input)
                    }
                }
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(Theme.textPrimary)
                    .focused($inputFocused)
                    .accessibilityLabel("连接码或服务器地址")
                    .accessibilityHint(error ?? "连接码可在服务器设置的连接 App 中获取")
                    .onSubmit { connect() }
                    .disabled(isConnecting)
                    .onChange(of: input) { _ in
                        error = nil
                        localNetworkDenied = nil
                    }
                Button(action: toggleInputVisibility) {
                    Image(systemName: inputVisible ? "eye.slash" : "eye")
                        .font(.system(size: 13))
                }
                .buttonStyle(WandIconButtonStyle())
                .help(inputVisible ? "隐藏连接信息" : "显示连接信息")
                .accessibilityLabel(inputVisible ? "隐藏连接信息" : "显示连接信息")
                .disabled(isConnecting)
                if !input.isEmpty {
                    Button { input = ""; error = nil; inputFocused = true } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundColor(Theme.textSecondary)
                    }
                    .buttonStyle(WandIconButtonStyle())
                    .help("清除地址")
                    .accessibilityLabel("清除连接码或地址")
                    .disabled(isConnecting)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .wandInputSurface(focused: inputFocused, invalid: error != nil, cornerRadius: Theme.Radius.control)
        }
    }

    private func toggleInputVisibility() {
        let selection = (NSApp.keyWindow?.firstResponder as? NSTextView)?.selectedRange()
        inputVisible.toggle()
        DispatchQueue.main.async {
            inputFocused = true
            // SecureField and TextField use separate field editors. Restore the old
            // selection after SwiftUI attaches the new editor and focuses it.
            DispatchQueue.main.async {
                guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView,
                      editor.isFieldEditor else { return }
                let length = editor.string.utf16.count
                let location = min(selection?.location ?? length, length)
                let selectedLength = min(selection?.length ?? 0, length - location)
                editor.setSelectedRange(NSRange(location: location, length: selectedLength))
            }
        }
    }

    private func errorBanner(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.danger)
                Text(message)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            Button { showTroubleshooting = true } label: {
                Label("打开故障排查", systemImage: "stethoscope")
            }
            .buttonStyle(.link)
            .font(.system(size: 12, weight: .medium))
        }
        .padding(.vertical, 4)
    }

    private var troubleshootingURL: URL? {
        if let decoded = WandAuth.decodeConnectCode(trimmedInput) { return decoded.url }
        return WandAuth.candidateURLs(from: trimmedInput).first
    }

    /// macOS 15+「本地网络」权限引导卡片。denied = 已确认被系统拒绝。
    private func localNetworkHint(denied: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.brand)
                Text(denied ? "「本地网络」权限已被拒绝" : "可能是「本地网络」权限问题")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
            }
            Text(denied
                 ? "macOS 不允许 Wand 访问局域网。请在 系统设置 → 隐私与安全性 → 本地网络 中打开 Wand 的开关后重试。"
                 : "macOS 15 起访问局域网需要授权。若设置列表里没有 Wand：请确认 Wand.app 在「应用程序」文件夹中，然后重新打开 App，并在弹窗中选择「允许」。重启 Mac 后权限偶尔会失效（系统已知问题），把开关关掉再打开即可恢复。")
                .font(.system(size: 11))
                .foregroundColor(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("打开「本地网络」设置") {
                LocalNetworkPermission.openSettings()
            }
            .buttonStyle(.link)
            .font(.system(size: 12))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .stroke(Theme.border.opacity(0.65), lineWidth: 0.5)
        )
    }

    private var connectButton: some View {
        Button(action: connect) {
            ZStack {
                Text("连接服务器").opacity(isConnecting ? 0 : 1)
                if isConnecting {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small).tint(.white)
                        Text("正在连接…")
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 24)
        }
        .buttonStyle(WandPrimaryButtonStyle())
        .disabled(isConnecting || trimmedInput.isEmpty)
        .accessibilityLabel(isConnecting ? "正在连接服务器" : "连接服务器")
        .wandMotion(value: isConnecting)
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().opacity(0.5).padding(.bottom, 6)
            Text("最近连接")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Theme.textSecondary)
            VStack(spacing: 6) {
                ForEach(store.recentInputs, id: \.self) { raw in
                    recentRow(raw)
                }
            }
        }
    }

    private func recentRow(_ raw: String) -> some View {
        let info = recentDisplay(raw)
        return HStack(spacing: 8) {
            Button { useRecent(raw) } label: {
                HStack(spacing: 8) {
                    Image(systemName: info.isCode ? "qrcode" : "network")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textSecondary)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(info.text)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(Theme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if info.isCode {
                            Label("已绑定连接码", systemImage: "key.fill")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(Theme.textTertiary)
                        }
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(DesktopNavigationButtonStyle())
            .disabled(isConnecting)
            .help("连接到 \(info.text)")
            Button {
                store.removeRecent(raw)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
                    .padding(6)
            }
            .buttonStyle(WandIconButtonStyle())
            .accessibilityLabel("移除最近连接 \(info.text)")
            .help("从最近连接中移除")
            .disabled(isConnecting)
        }
        .padding(.vertical, 4)
    }

    private var footerHint: some View {
        Label(
            "在电脑端 Wand 的“设置 → 连接 App”中获取连接码",
            systemImage: "info.circle"
        )
            .font(.system(size: 11))
            .foregroundColor(Theme.textSecondary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 2)
    }

    // MARK: - 逻辑

    private func connect() {
        let raw = trimmedInput
        guard !raw.isEmpty, !isConnecting else { return }
        isConnecting = true
        error = nil
        localNetworkDenied = nil
        inputFocused = false

        WandAuth.resolve(rawInput: raw) { result in
            DispatchQueue.main.async {
                isConnecting = false
                switch result {
                case .success(let target):
                    store.addRecent(raw)
                    store.connect(serverURL: target.url, token: target.token)
                    onDismiss?()
                case .failure(let err):
                    inputFocused = true
                    error = err.userMessage
                    maybeShowLocalNetworkHint(for: err, rawInput: raw)
                }
            }
        }
    }

    /// 网络层连接失败 + 目标像局域网地址 → 探测「本地网络」权限并展示引导。
    /// 认证类失败（401/429 等）说明网络通了，不掺和。
    private func maybeShowLocalNetworkHint(for err: WandAuth.Failure, rawInput: String) {
        guard LocalNetworkPermission.isEnforced else { return }
        guard case .network = err else { return }
        let host: String? = WandAuth.decodeConnectCode(rawInput)?.url.host
            ?? WandAuth.candidateURLs(from: rawInput).first?.host
        guard LocalNetworkPermission.isLikelyLanHost(host) else { return }
        LocalNetworkPermission.probeDenied { denied in
            localNetworkDenied = denied
        }
    }

    private func useRecent(_ raw: String) {
        guard !isConnecting else { return }
        input = raw
        connect()
    }

    private func recentDisplay(_ raw: String) -> (text: String, isCode: Bool) {
        if let decoded = WandAuth.decodeConnectCode(raw) {
            return (decoded.url.absoluteString, true)
        }
        return (raw, false)
    }
}
