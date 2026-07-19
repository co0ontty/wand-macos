import SwiftUI

/// 连接界面：输入服务器地址（host:port，自动判别 http/https）或 wand 设置页生成的"连接码"。
/// 解析与可达性探测统一收敛到 `WandAuth.resolve`，错误就地内联展示，不再依赖弹窗。
struct ConnectView: View {
    @EnvironmentObject var store: ServerStore

    var isPresentedAsSheet: Bool = false
    var onDismiss: (() -> Void)? = nil

    @State private var input: String = ""
    @State private var error: String? = nil
    @State private var isConnecting = false
    @FocusState private var inputFocused: Bool

    /// 「本地网络」权限引导：nil = 不展示；false = 提示性引导（无法确定是否被拒）；
    /// true = 已探测到被系统拒绝。仅 macOS 15+ 且目标地址像局域网时出现。
    @State private var localNetworkDenied: Bool? = nil

    private var trimmedInput: String {
        input.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        ZStack {
            WandAmbientBackground()

            VStack(spacing: 0) {
                if isPresentedAsSheet {
                    sheetHeader
                }
                Spacer(minLength: 0)
                card
                    .frame(maxWidth: isPresentedAsSheet ? 520 : 900)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 24)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(
            minWidth: isPresentedAsSheet ? 520 : nil,
            minHeight: isPresentedAsSheet ? 580 : nil
        )
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { inputFocused = true }
        }
    }

    // MARK: - 区块

    private var sheetHeader: some View {
        HStack {
            Text("切换服务器")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
            Spacer()
            Button("取消") { onDismiss?() }
                .buttonStyle(.plain)
                .foregroundColor(Theme.textSecondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .wandGlass(.chrome)
    }

    @ViewBuilder
    private var card: some View {
        if isPresentedAsSheet {
            compactCard
        } else {
            desktopCard
        }
    }

    private var desktopCard: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                WandBrandMark(size: 72)
                VStack(alignment: .leading, spacing: 8) {
                    Text("连接到 Wand")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundColor(Theme.textPrimary)
                    Text("连接你的开发主机，在桌面端并排管理会话、聊天、文件与 Git 状态。")
                        .font(.system(size: 14))
                        .foregroundColor(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 24)
                Label("连接码会安全绑定服务器地址与认证信息", systemImage: "lock.shield")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 280, alignment: .leading)
            .padding(32)
            .background(Theme.wandAccent.opacity(0.07))

            Rectangle()
                .fill(Theme.border)
                .frame(width: 1)

            formContent
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(32)
        }
        .frame(minHeight: 430)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .wandGlassCard(cornerRadius: 20)
    }

    private var compactCard: some View {
        VStack(spacing: 22) {
            intro
            formContent
        }
        .padding(28)
        .wandGlassCard(cornerRadius: 20)
    }

    private var intro: some View {
        VStack(spacing: 14) {
            WandBrandMark(size: 64)
            VStack(spacing: 6) {
                Text("连接到 Wand")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(Theme.textPrimary)
                Text("粘贴设置页的连接码，或直接输入服务器地址")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var formContent: some View {
        VStack(spacing: 18) {
            inputField

            if let error {
                errorBanner(error)
            }

            if let denied = localNetworkDenied {
                localNetworkHint(denied: denied)
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
            Text("连接码 / 服务器地址")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Theme.textSecondary)

            HStack(spacing: 8) {
                Image(systemName: "link")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.textSecondary)
                TextField("例如 192.168.1.10:7777 或粘贴连接码", text: $input)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(Theme.textPrimary)
                    .focused($inputFocused)
                    .onSubmit { connect() }
                    .disabled(isConnecting)
                if !input.isEmpty {
                    Button { input = ""; error = nil } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundColor(Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .wandInputSurface(focused: inputFocused, invalid: error != nil, cornerRadius: 10)
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundColor(Theme.danger)
            Text(message)
                .font(.system(size: 12))
                .foregroundColor(Theme.danger)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.danger.opacity(0.1))
        )
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
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.brand.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Theme.brand.opacity(0.35), lineWidth: 1)
        )
    }

    private var connectButton: some View {
        Button(action: connect) {
            HStack(spacing: 8) {
                if isConnecting {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                }
                Text(isConnecting ? "连接中…" : "连接")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(WandPrimaryButtonStyle())
        .disabled(isConnecting || trimmedInput.isEmpty)
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
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
                    Text("🔑 已绑定连接码")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.textSecondary)
                }
            }
            Spacer(minLength: 4)
            Button {
                store.removeRecent(raw)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
                    .padding(6)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Theme.border, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { useRecent(raw) }
    }

    private var footerHint: some View {
        Text("在电脑端 Wand 的「设置 → 连接 App」里获取连接码")
            .font(.system(size: 11))
            .foregroundColor(Theme.textSecondary)
            .multilineTextAlignment(.center)
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
