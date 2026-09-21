import SwiftUI

/// A short, repeatable tour. Feature actions are handed back to the desktop shell so
/// opening a destination follows the same route as the sidebar and command palette.
struct DesktopOnboardingView: View {
    let onFinish: () -> Void
    var onOpenSettings: () -> Void = {}
    var onOpenFeature: (String) -> Void = { _ in }
    var isConnected = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("wand.sendWithCommandEnter") private var sendWithCommandEnter = false
    @State private var step = 0

    private let steps = ["开始对话", "组织工作", "顺手的桌面"]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            HStack(spacing: 0) {
                navigation
                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        pageHeader
                        Group {
                            switch step {
                            case 0: conversationsPage
                            case 1: workspacePage
                            default: desktopPage
                            }
                        }
                        .id(step)
                        .transition(.opacity)
                    }
                    .padding(30)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider().opacity(0.4)
            footer
        }
        .frame(width: 790, height: 540)
        .background(Theme.workspaceBackground)
    }

    private var header: some View {
        HStack(spacing: 12) {
            WandBrandMark(size: 28)
            Text("欢迎使用 Wand")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
            Spacer()
            Button("稍后再看", action: onFinish)
                .buttonStyle(.plain)
                .foregroundColor(Theme.textSecondary)
                .keyboardShortcut(.cancelAction)
                .help("关闭指南；可以从帮助菜单重新打开")
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 17)
    }

    private var navigation: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, title in
                Button { move(to: index) } label: {
                    HStack(spacing: 10) {
                        ZStack {
                            Circle().fill(index == step ? Theme.brand : Theme.border.opacity(0.5))
                            if index < step {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(Theme.textSecondary)
                            } else {
                                Text("\(index + 1)")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(index == step ? .white : Theme.textSecondary)
                            }
                        }
                        .frame(width: 24, height: 24)
                        Text(title).font(.system(size: 13, weight: index == step ? .semibold : .regular))
                        Spacer(minLength: 0)
                    }
                    .foregroundColor(index == step ? Theme.textPrimary : Theme.textSecondary)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 9).fill(
                        index == step ? Theme.textPrimary.opacity(0.05) : Color.clear
                    ))
                    .contentShape(RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("第 \(index + 1) 步，\(title)")
                .accessibilityValue(index == step ? "当前步骤" : "")
            }
            Spacer()
            Text("随时从「帮助」菜单\n重新打开这份指南。")
                .font(.system(size: 11))
                .lineSpacing(4)
                .foregroundColor(Theme.textTertiary)
                .padding(10)
        }
        .padding(14)
        .frame(width: 182)
        .background(Theme.sidebarBackground)
    }

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(pageTitle)
                .font(.system(size: 25, weight: .semibold))
                .tracking(-0.5)
                .foregroundColor(Theme.textPrimary)
            Text(pageDescription)
                .font(.system(size: 13))
                .lineSpacing(4)
                .foregroundColor(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var conversationsPage: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 0) {
                workflowRow(symbol: "folder", title: "选定工作目录", detail: "让 AI 在项目所在的目录中工作。", last: false)
                workflowRow(symbol: "cpu", title: "选择工具和模型", detail: "使用服务器上已配置的 AI 工具。", last: false)
                workflowRow(symbol: "bubble.left.and.bubble.right", title: "描述你想完成的事", detail: "在对话中跟进回复，或切换到终端查看执行过程。", last: true)
            }
            hint(symbol: "hand.raised", title: "需要你决定时，会话会等待", detail: "留意权限请求与待回复状态，确认后 AI 才会继续对应操作。")
            actionButton(isConnected ? "新建第一条会话" : "连接服务器后即可新建会话", symbol: "square.and.pencil", feature: "newSession")
        }
    }

    private var workspacePage: some View {
        VStack(alignment: .leading, spacing: 14) {
            featureRow(command: .workspaces, detail: "按项目整理会话，保留每项工作的上下文。")
            featureRow(command: .taskBoard, detail: "从待办到完成，跟踪任务和关联会话。")
            featureRow(command: .missions, detail: "查看任务执行进展与需要处理的事项。")
            featureRow(command: .webTools, detail: "在客户端内访问文件、自动化、供应商和完整服务端设置。")
            if !isConnected {
                Text("连接服务器后，可以从侧栏打开这些功能。")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textSecondary)
            }
        }
    }

    private var desktopPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach([DesktopCommand.search, .newSession, .toggleSidebar, .focusComposer]) { command in
                    HStack(spacing: 12) {
                        Image(systemName: command.symbol)
                            .frame(width: 18)
                            .foregroundColor(Theme.textSecondary)
                        Text(command.title)
                            .font(.system(size: 13))
                            .foregroundColor(Theme.textPrimary)
                        Spacer()
                        DesktopKeycap(label: command.shortcutLabel)
                    }
                }
            }
            .padding(18)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surface))

            VStack(alignment: .leading, spacing: 9) {
                Text("你习惯怎样发送消息？")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                Picker("发送方式", selection: $sendWithCommandEnter) {
                    Text("Return 发送").tag(false)
                    Text("⌘ Return 发送").tag(true)
                }
                .pickerStyle(.segmented)
                Text(sendWithCommandEnter ? "Return 换行，⌘ Return 发送。" : "Return 发送，⇧ Return 换行。")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textSecondary)
            }
            if isConnected {
                Button {
                    onFinish()
                    onOpenSettings()
                } label: {
                    Label("调整外观与更多偏好", systemImage: "slider.horizontal.3")
                }
                .buttonStyle(.link)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text("\(step + 1) / \(steps.count)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(Theme.textTertiary)
            Spacer()
            if step > 0 {
                Button("上一步") { move(to: step - 1) }
                    .buttonStyle(WandSecondaryButtonStyle())
            }
            Button(step == steps.count - 1 ? "开始使用" : "继续") {
                if step == steps.count - 1 { onFinish() }
                else { move(to: step + 1) }
            }
            .buttonStyle(WandPrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private func workflowRow(symbol: String, title: String, detail: String, last: Bool) -> some View {
        HStack(alignment: .top, spacing: 15) {
            VStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 15))
                    .foregroundColor(Theme.brand)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Theme.brand.opacity(0.09)))
                if !last { Rectangle().fill(Theme.border).frame(width: 1, height: 21) }
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.textPrimary)
                Text(detail).font(.system(size: 12)).foregroundColor(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 3)
            Spacer(minLength: 0)
        }
    }

    private func hint(symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).foregroundColor(Theme.textSecondary)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 12, weight: .medium)).foregroundColor(Theme.textPrimary)
                Text(detail).font(.system(size: 12)).foregroundColor(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface))
    }

    private func featureRow(command: DesktopCommand, detail: String) -> some View {
        Button { open(command.rawValue) } label: {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: command.symbol)
                    .font(.system(size: 20, weight: .regular))
                    .foregroundColor(Theme.brand)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 5) {
                    Text(command.title).font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.textPrimary)
                    Text(detail).font(.system(size: 12)).foregroundColor(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.right").font(.system(size: 11)).foregroundColor(Theme.textTertiary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 11).fill(Theme.surface))
            .contentShape(RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain)
        .disabled(!isConnected)
        .help(isConnected ? "打开\(command.title)" : "连接服务器后可打开")
    }

    private func actionButton(_ title: String, symbol: String, feature: String) -> some View {
        Button { open(feature) } label: { Label(title, systemImage: symbol) }
            .buttonStyle(WandSecondaryButtonStyle())
            .disabled(!isConnected)
    }

    private var pageTitle: String {
        switch step {
        case 0: return "从一个想法开始。"
        case 1: return "给每项工作一个位置。"
        default: return "让操作跟上思路。"
        }
    }

    private var pageDescription: String {
        switch step {
        case 0: return "在同一处使用服务器上的 AI 工具，继续已有会话，或开始一项新工作。"
        case 1: return "会话、任务与项目工具都在侧栏中。选定一个入口，就能继续工作。"
        default: return "用快捷键切换上下文；外观与输入习惯可以随时在设置中调整。"
        }
    }

    private func open(_ feature: String) {
        onFinish()
        onOpenFeature(feature)
    }

    private func move(to next: Int) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) { step = next }
    }
}

struct DesktopKeycap: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundColor(Theme.textSecondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 5).fill(Theme.workspaceBackground))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.border, lineWidth: 0.75))
            .fixedSize()
    }
}

struct DesktopShortcutList: View {
    var query: String = ""

    private var commands: [DesktopCommand] {
        DesktopCommand.allCases.filter {
            !$0.shortcutLabel.isEmpty && (query.isEmpty
                || $0.title.localizedCaseInsensitiveContains(query)
                || $0.subtitle.localizedCaseInsensitiveContains(query)
                || $0.shortcutLabel.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if commands.isEmpty {
                Text("没有匹配的快捷键。试试搜索“会话”或“侧栏”。")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.textSecondary)
                    .padding(.vertical, 20)
            }
            ForEach(commands) { command in
                HStack(spacing: 12) {
                    Image(systemName: command.symbol)
                        .font(.system(size: 13))
                        .foregroundColor(Theme.textSecondary)
                        .frame(width: 20)
                    Text(command.title)
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textPrimary)
                    Spacer()
                    DesktopKeycap(label: command.shortcutLabel)
                }
                .padding(.vertical, 9)
                if command.id != commands.last?.id { Divider().opacity(0.3) }
            }
        }
    }
}

struct DesktopShortcutsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("wand.sendWithCommandEnter") private var sendWithCommandEnter = false
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("键盘快捷键").font(.system(size: 20, weight: .semibold))
                    Text("更快地导航、查找和开始工作。")
                        .font(.system(size: 12)).foregroundColor(Theme.textSecondary)
                }
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(24)
            TextField("查找操作或快捷键", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 24)
                .padding(.bottom, 14)
                .accessibilityLabel("查找快捷键")
            Divider().opacity(0.4)
            ScrollView {
                DesktopShortcutList(query: query.trimmingCharacters(in: .whitespacesAndNewlines))
                    .padding(.horizontal, 24)
                    .padding(.vertical, 8)
            }
            Divider().opacity(0.4)
            HStack {
                Text(sendWithCommandEnter ? "⌘ Return 发送 · Return 换行" : "Return 发送 · ⇧ Return 换行")
                Spacer()
                Text("esc 关闭弹窗")
            }
            .font(.system(size: 11))
            .foregroundColor(Theme.textSecondary)
            .padding(18)
        }
        .foregroundColor(Theme.textPrimary)
        .frame(width: 520, height: 540)
        .background(Theme.workspaceBackground)
    }
}
