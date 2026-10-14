import SwiftUI

/// 本机显示偏好：结构化会话、工作区会话和员工对话共用，不改变终端网格。
enum ChatContentWidth: String, CaseIterable, Identifiable {
    case full
    case column

    static let storageKey = "wand.desktop.chatContentWidth"
    static let columnMaxWidth: CGFloat = 840
    var id: String { rawValue }
    var title: String { self == .full ? "铺满" : "居中" }
    var maxWidth: CGFloat { self == .full ? .infinity : Self.columnMaxWidth }
}

/// 复用原生分段选择器；所有已打开的内容区通过 AppStorage 立即响应。
struct ChatContentWidthPicker: View {
    @AppStorage(ChatContentWidth.storageKey) private var width: ChatContentWidth = .full

    var body: some View {
        Picker("会话内容宽度", selection: $width) {
            ForEach(ChatContentWidth.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("chat-content-width")
    }
}

private struct ChatContentWidthModifier: ViewModifier {
    @AppStorage(ChatContentWidth.storageKey) private var width: ChatContentWidth = .full

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: width.maxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .wandMotion(value: width, layout: true)
    }
}

extension View {
    /// 消息、输入区和会话内工具行使用同一宽度；窄窗口不强制最小宽度。
    func chatContentWidth() -> some View {
        modifier(ChatContentWidthModifier())
    }
}
