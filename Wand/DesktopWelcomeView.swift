import SwiftUI

/// A quiet starting point with real destinations, shared by both sidebar modes.
struct DesktopWelcomeView: View {
    let onCommand: (DesktopCommand) -> Void
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    WandBrandMark(size: 38)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("今天，想完成什么？")
                            .font(.system(size: 30, weight: .semibold)).tracking(-0.7)
                            .foregroundColor(Theme.textPrimary)
                        Text("从一个问题开始，或把一个项目交给你的 AI 工具。")
                            .font(.system(size: 14)).foregroundColor(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button { onCommand(.newSession) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "square.and.pencil").font(.system(size: 18))
                            Text("开始一段新对话").font(.system(size: 15, weight: .medium))
                            Spacer()
                            Text("⌘N").font(.system(size: 12, design: .monospaced)).foregroundColor(Theme.textSecondary)
                        }.foregroundColor(Theme.textPrimary).padding(20)
                    }
                    .buttonStyle(DesktopNavigationButtonStyle(active: true))
                    VStack(spacing: 2) {
                        welcomeAction(.newTask, detail: "在一个目录中协作，使用独立工作树并行推进。")
                        welcomeAction(.taskBoard, detail: "安排待办、跟踪进度，再交给合适的 Agent。")
                        welcomeAction(.webTools, detail: "配置工具、连接器与通知，管理文件和 GitHub。")
                    }
                    HStack(spacing: 7) {
                        Button("使用入门") { onCommand(.onboarding) }
                        Text("·").accessibilityHidden(true)
                        Button("快捷键") { onCommand(.shortcuts) }
                        Spacer()
                        Text("⇧⌘P 搜索与命令")
                    }.font(.system(size: 11)).buttonStyle(.plain).foregroundColor(Theme.textSecondary)
                }
                .frame(maxWidth: 580)
                .padding(.horizontal, 32).padding(.vertical, 36)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .center)
            }
        }
    }
    private func welcomeAction(_ command: DesktopCommand, detail: String) -> some View {
        Button { onCommand(command) } label: {
            HStack(spacing: 14) {
                Image(systemName: command.symbol).font(.system(size: 17)).frame(width: 24)
                    .foregroundColor(Theme.textSecondary)
                VStack(alignment: .leading, spacing: 5) {
                    Text(command.title).font(.system(size: 13, weight: .medium)).foregroundColor(Theme.textPrimary)
                    Text(detail).font(.system(size: 12)).foregroundColor(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundColor(Theme.textTertiary)
            }.padding(14).contentShape(Rectangle())
        }.buttonStyle(DesktopNavigationButtonStyle())
    }
}

struct DesktopNavigationButtonStyle: ButtonStyle {
    var active = false
    func makeBody(configuration: Configuration) -> some View {
        DesktopNavigationButtonBody(configuration: configuration, active: active)
    }
    private struct DesktopNavigationButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let active: Bool
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled
        var body: some View {
            configuration.label
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Theme.textPrimary.opacity(configuration.isPressed ? 0.12 : (active ? 0.07 : (hovering ? 0.045 : 0)))))
                .opacity(isEnabled ? 1 : 0.45)
                .onHover { hovering = $0 }
        }
    }
}
