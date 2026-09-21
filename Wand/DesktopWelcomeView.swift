import Combine
import SwiftUI

/// The starting screen owns a real draft; continuing opens the existing session setup.
struct DesktopWelcomeView: View {
    @Binding var draft: String
    let onContinue: () -> Void
    let onCommand: (DesktopCommand) -> Void
    @State private var focused = false
    @State private var composing = false
    @State private var inputHeight: CGFloat = 66

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 28) {
                    VStack(spacing: 16) {
                        WandBrandMark(size: 44).accessibilityHidden(true)
                        Text("今天，想完成什么？")
                            .font(.system(size: 32, weight: .medium)).tracking(-0.8)
                            .foregroundColor(Theme.textPrimary)
                        Text("写代码、理清思路，或开始一个新项目。")
                            .font(.system(size: 14)).foregroundColor(Theme.textSecondary)
                    }
                    VStack(spacing: 14) {
                        IMEAwareComposerTextView(
                            text: $draft, placeholder: "描述你想做的事…",
                            isFocused: focused, sendWithCommandEnter: true,
                            onFocusChange: { focused = $0 },
                            onCompositionChange: { composing = $0 },
                            onSubmit: continueDraft,
                            onHeightChange: { inputHeight = $0 },
                            submitActionName: "继续配置会话"
                        )
                        .frame(height: max(66, min(160, inputHeight)))
                        HStack(spacing: 12) {
                            Text("下一步选择 AI 工具与工作目录")
                                .font(.system(size: 11)).foregroundColor(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            Button(action: continueDraft) {
                                HStack(spacing: 7) {
                                    Text(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "新建会话" : "继续")
                                    Image(systemName: "arrow.up")
                                }
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(Theme.surfaceElevated)
                                .padding(.horizontal, 14).frame(height: 34)
                                .background(Capsule().fill(Theme.textPrimary))
                            }
                            .buttonStyle(.plain).disabled(composing)
                            .help("选择 AI 工具与工作目录 · ⌘↵")
                        }
                    }
                    .padding(20)
                    .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.surfaceElevated))
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(focused ? Theme.textSecondary.opacity(0.45) : Theme.border, lineWidth: 1))
                    .shadow(color: .black.opacity(0.025), radius: 12, y: 4)
                    HStack(spacing: 12) {
                        quickAction(.newTask, title: "从项目开始")
                        quickAction(.taskBoard, title: "查看任务")
                    }
                }
                .frame(maxWidth: 720)
                .padding(.horizontal, 36).padding(.vertical, 40)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .center)
            }
        }
        .onAppear { focused = true }
        .onReceive(NotificationCenter.default.publisher(for: .wandDesktopCommand)) { note in
            if let command = note.object as? DesktopCommand, (command == .focusComposer || command == .newSession) {
                focused = true
            }
        }
    }

    private func continueDraft() {
        guard !composing else { return }
        onContinue()
    }

    private func quickAction(_ command: DesktopCommand, title: String) -> some View {
        Button { onCommand(command) } label: {
            Label(title, systemImage: command.symbol)
                .font(.system(size: 12)).foregroundColor(Theme.textSecondary)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .overlay(Capsule().stroke(Theme.border.opacity(0.8), lineWidth: 0.7))
                .contentShape(Capsule())
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
