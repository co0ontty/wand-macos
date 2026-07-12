import SwiftUI

/// 原生设置页：服务器信息 / 功能开关 / 网页版入口 / 关于。
/// 服务端的完整设置（更新通道、Android 下载等）仍在网页版里，这里聚焦客户端本身。
struct SettingsView: View {
    let serverURL: URL
    let token: String?
    /// 请求打开网页版（由 NativeRootView 在当前 sheet 关闭后呈现）。
    let onOpenWeb: () -> Void

    @EnvironmentObject private var store: ServerStore
    @Environment(\.dismiss) private var dismiss

    @State private var serverVersion: String?
    @State private var confirmDisconnect = false

    private var api: WandAPI { WandAPI(baseURL: serverURL, token: token) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("设置")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                Spacer()
                Button("完成") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundColor(Theme.brand)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .wandGlass(.chrome)
            Divider().opacity(0.35)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    settingsCard("服务器") {
                        infoRow("地址", serverURL.absoluteString, mono: true)
                        infoRow("认证方式", (token?.isEmpty == false) ? "连接码" : "无密码")
                        if let serverVersion {
                            infoRow("服务端版本", "v\(serverVersion)", mono: true)
                        }
                        Divider()
                        Button {
                            dismiss()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                NotificationCenter.default.post(name: .wandRequestSwitchServer, object: nil)
                            }
                        } label: {
                            Label("切换服务器", systemImage: "server.rack")
                                .font(.system(size: 15))
                        }
                        Button(role: .destructive) {
                            confirmDisconnect = true
                        } label: {
                            Label("断开连接", systemImage: "xmark.circle")
                                .font(.system(size: 15))
                                .foregroundColor(Theme.danger)
                        }
                    }
                    settingsCard("更多") {
                        Button {
                            dismiss()
                            onOpenWeb()
                        } label: {
                            Label("打开网页版（完整设置）", systemImage: "safari")
                                .font(.system(size: 15))
                        }
                        if LocalNetworkPermission.isEnforced {
                            Button {
                                LocalNetworkPermission.openSettings()
                            } label: {
                                Label("本地网络权限（系统设置）", systemImage: "lock.shield")
                                    .font(.system(size: 15))
                            }
                        }
                        Text(LocalNetworkPermission.isEnforced
                             ? "更新通道、模型配置等服务端设置在网页版里调整。连不上局域网服务器时，检查「本地网络」权限。"
                             : "更新通道、模型配置等服务端设置在网页版里调整。")
                            .font(.footnote)
                            .foregroundColor(Theme.textSecondary)
                    }
                    settingsCard("关于") {
                        infoRow("App 版本", appVersion, mono: true)
                        Link(destination: URL(string: "https://github.com/co0ontty/wand")!) {
                            Label("GitHub 仓库", systemImage: "link")
                                .font(.system(size: 15))
                        }
                    }
                }
                .padding(20)
            }
        }
        .frame(minWidth: 640, minHeight: 520)
        .task {
            serverVersion = (try? await api.serverConfig())?.currentVersion
        }
        .confirmationDialog("断开后需要重新输入连接码才能连回来。", isPresented: $confirmDisconnect, titleVisibility: .visible) {
            Button("断开连接", role: .destructive) {
                dismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    store.disconnect()
                }
            }
            Button("取消", role: .cancel) {}
        }
    }

    // MARK: - 小组件

    private func settingsCard<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Theme.textSecondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                .fill(Theme.surfaceElevated)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                        .stroke(Theme.border, lineWidth: 1)
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
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 14))
                .foregroundColor(Theme.textSecondary)
            Spacer()
            Text(value)
                .font(.system(size: 13, design: mono ? .monospaced : .default))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}
