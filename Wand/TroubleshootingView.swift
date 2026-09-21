import AppKit
import SwiftUI

struct TroubleshootingContext: Equatable {
    var serverURL: URL?
    var errorMessage: String?
    var source: String
}

@MainActor
final class TroubleshootingModel: ObservableObject {
    enum State: Equatable {
        case idle
        case running
        case reachable
        case unreachable(String)
    }

    @Published var networkState: State = .idle
    @Published var localNetworkDenied: Bool?
    @Published var lastCheckedAt: Date?

    let context: TroubleshootingContext

    init(context: TroubleshootingContext) {
        self.context = context
    }

    var isInstalledInApplications: Bool {
        Bundle.main.bundleURL.path.hasPrefix("/Applications/")
    }

    var isLanTarget: Bool {
        LocalNetworkPermission.isLikelyLanHost(context.serverURL?.host)
    }

    func run() {
        guard networkState != .running else { return }
        networkState = .running
        localNetworkDenied = nil
        Task {
            async let denied = probeLocalNetworkPermission()
            let reachability = await probeServer()
            localNetworkDenied = await denied
            networkState = reachability
            lastCheckedAt = Date()
        }
    }

    private func probeLocalNetworkPermission() async -> Bool {
        guard LocalNetworkPermission.isEnforced, isLanTarget else { return false }
        return await withCheckedContinuation { continuation in
            LocalNetworkPermission.probeDenied { continuation.resume(returning: $0) }
        }
    }

    private func probeServer() async -> State {
        guard let base = context.serverURL,
              let url = URL(string: "/api/session-check", relativeTo: base)?.absoluteURL else {
            return .unreachable("还没有可检测的服务器地址")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (_, response) = try await SelfSignedSession.shared.session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .unreachable("服务器返回了无法识别的响应")
            }
            return (http.statusCode == 200 || http.statusCode == 401)
                ? .reachable
                : .unreachable("探测端点返回 HTTP \(http.statusCode)")
        } catch {
            return .unreachable(error.localizedDescription)
        }
    }

    var report: String {
        let permission: String
        if !LocalNetworkPermission.isEnforced { permission = "当前系统无需单独授权" }
        else if !isLanTarget { permission = "目标不是局域网地址" }
        else if localNetworkDenied == true { permission = "已检测到拒绝" }
        else if localNetworkDenied == false { permission = "未检测到拒绝（系统不提供精确授权状态）" }
        else { permission = "尚未检测" }

        let network: String
        switch networkState {
        case .idle: network = "尚未检测"
        case .running: network = "检测中"
        case .reachable: network = "服务器可达"
        case .unreachable(let detail): network = "不可达：\(detail)"
        }

        return """
        Wand macOS 故障排查报告
        来源：\(context.source)
        App 版本：\(appVersion)
        macOS：\(ProcessInfo.processInfo.operatingSystemVersionString)
        安装位置：\(isInstalledInApplications ? "Applications" : "非 Applications")
        服务器：\(context.serverURL?.absoluteString ?? "未设置")
        服务器探测：\(network)
        本地网络权限：\(permission)
        原始错误：\(context.errorMessage ?? "无")
        """
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"
    }
}

struct TroubleshootingView: View {
    let context: TroubleshootingContext
    var onRetry: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: TroubleshootingModel
    @State private var copied = false

    init(context: TroubleshootingContext, onRetry: (() -> Void)? = nil) {
        self.context = context
        self.onRetry = onRetry
        _model = StateObject(wrappedValue: TroubleshootingModel(context: context))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.35)
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if let error = context.errorMessage, !error.isEmpty {
                        errorSummary(error)
                    }
                    checks
                    recommendedActions
                }
                .padding(32)
            }
        }
        .frame(minWidth: 620, idealWidth: 680, minHeight: 540, idealHeight: 620)
        .background(WandAmbientBackground())
        .foregroundColor(Theme.textPrimary)
        .tint(Theme.accentSolid)
        .wandMotion(value: model.networkState)
        .task { model.run() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("故障排查").font(.system(size: 17, weight: .semibold))
                Text("连接、安装位置与系统权限")
                    .font(.system(size: 12)).foregroundColor(Theme.textSecondary)
            }
            Spacer(minLength: 12)
            Button { copyReport() } label: {
                ZStack {
                    Text("复制报告").opacity(copied ? 0 : 1)
                    Text("已复制").opacity(copied ? 1 : 0)
                }
            }
            .buttonStyle(WandSecondaryButtonStyle())
            .accessibilityLabel(copied ? "诊断报告已复制" : "复制诊断报告")
            .wandMotion(value: copied)
            Button("完成") { dismiss() }
                .buttonStyle(WandSecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(Theme.background)
    }

    private func errorSummary(_ error: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.circle")
                .foregroundColor(Theme.danger)
            VStack(alignment: .leading, spacing: 4) {
                Text("当前错误").font(.system(size: 13, weight: .semibold))
                Text(error).font(.system(size: 12)).foregroundColor(Theme.textSecondary)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }

    private var checks: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("检测结果").font(.system(size: 13, weight: .semibold))
                Spacer()
                if let checkedAt = model.lastCheckedAt {
                    Text(checkedAt, style: .time)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Theme.textTertiary)
                        .accessibilityLabel("最近检测时间")
                }
            }
            .padding(.bottom, 14)
            diagnosticRow(
                title: "服务器连接",
                detail: networkDetail,
                symbol: networkSymbol,
                tint: networkTint,
                working: model.networkState == .running
            )
            diagnosticRow(
                title: "本地网络权限",
                detail: permissionDetail,
                symbol: permissionSymbol,
                tint: permissionTint,
                working: LocalNetworkPermission.isEnforced && model.isLanTarget
                    && model.localNetworkDenied == nil && model.networkState == .running
            )
            diagnosticRow(
                title: "App 安装位置",
                detail: model.isInstalledInApplications ? "已安装在 Applications" : "当前不在 Applications；macOS 可能不会显示本地网络授权弹窗",
                symbol: model.isInstalledInApplications ? "checkmark.circle.fill" : "externaldrive.badge.exclamationmark",
                tint: model.isInstalledInApplications ? Theme.success : Theme.warning
            )
            if let url = context.serverURL {
                diagnosticRow(
                    title: "当前服务器",
                    detail: url.absoluteString,
                    symbol: model.isLanTarget ? "network" : "server.rack",
                    tint: Theme.textSecondary
                )
            }
        }
    }

    private func diagnosticRow(title: String, detail: String, symbol: String, tint: Color, working: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if working { ProgressView().controlSize(.small) }
                else { Image(systemName: symbol).foregroundColor(tint) }
            }
            .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundColor(Theme.textSecondary)
                    .textSelection(.enabled)
            }
            Spacer()
        }
        .padding(.vertical, 16)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.border.opacity(0.6)).frame(height: 0.5)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(detail)
    }

    private var recommendedActions: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("下一步").font(.system(size: 13, weight: .semibold))
            Text(actionHint)
                .font(.system(size: 12))
                .foregroundColor(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button { model.run() } label: {
                    ZStack {
                        Label("重新检测", systemImage: "arrow.clockwise")
                            .opacity(model.networkState == .running ? 0 : 1)
                        Text("正在检测…")
                            .opacity(model.networkState == .running ? 1 : 0)
                    }
                }
                .buttonStyle(WandPrimaryButtonStyle())
                .disabled(model.networkState == .running)
                .accessibilityLabel(model.networkState == .running ? "正在检测" : "重新检测")
                if let onRetry {
                    Button("重试原操作") { dismiss(); onRetry() }
                        .buttonStyle(WandSecondaryButtonStyle())
                }
            }
            HStack(spacing: 18) {
                if LocalNetworkPermission.isEnforced && model.isLanTarget {
                    Button("打开本地网络权限") { LocalNetworkPermission.openSettings() }
                        .buttonStyle(.link)
                }
                Button("切换服务器") {
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        NotificationCenter.default.post(name: .wandRequestSwitchServer, object: nil)
                    }
                }
                .buttonStyle(.link)
            }
            .font(.system(size: 12))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 22)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.border.opacity(0.6)).frame(height: 0.5)
        }
    }

    private var networkDetail: String {
        switch model.networkState {
        case .idle: return "等待检测"
        case .running: return "正在检查服务器连接…"
        case .reachable: return "服务器可达；若仍报错，请检查连接码是否过期"
        case .unreachable(let detail): return detail
        }
    }

    private var networkSymbol: String {
        if case .reachable = model.networkState { return "checkmark.circle" }
        if case .idle = model.networkState { return "clock" }
        return "xmark.circle"
    }

    private var networkTint: Color {
        if case .reachable = model.networkState { return Theme.success }
        if case .idle = model.networkState { return Theme.textSecondary }
        return Theme.danger
    }

    private var permissionDetail: String {
        if !LocalNetworkPermission.isEnforced { return "当前 macOS 版本无需单独授权" }
        if !model.isLanTarget { return "当前目标不是局域网地址，不受此权限影响" }
        if model.localNetworkDenied == true { return "系统已拒绝 Wand 访问本地网络" }
        if model.localNetworkDenied == false { return "未检测到明确拒绝；macOS 不提供可直接读取的授权状态" }
        return "正在检查系统是否明确拒绝访问…"
    }

    private var permissionSymbol: String {
        if model.localNetworkDenied == true { return "hand.raised.slash" }
        if !LocalNetworkPermission.isEnforced || !model.isLanTarget { return "checkmark.shield" }
        return "shield"
    }

    private var permissionTint: Color {
        model.localNetworkDenied == true ? Theme.danger : Theme.textSecondary
    }

    private var actionHint: String {
        if !model.isInstalledInApplications { return "先把 Wand.app 移到 Applications，再重新打开以触发系统权限弹窗。" }
        if model.localNetworkDenied == true { return "在系统设置中打开 Wand 的本地网络权限，然后回到这里重新检测。" }
        if case .reachable = model.networkState { return "网络已经连通。认证错误通常需要从服务端设置页重新复制连接码。" }
        return "确认服务端正在运行、地址和端口正确，并检查防火墙或 VPN 是否拦截连接。"
    }

    private func copyReport() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.report, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { copied = false }
    }
}
