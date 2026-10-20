import AppKit
import Foundation
import SwiftUI

/// Web and native desktop share stable IDs and query semantics, never connection tokens.
enum DesktopPageLink {
    static let keys: Set<String> = [
        "view", "session", "workspace", "workspaceTask", "window", "tab", "task", "run", "team", "settings", "range",
        "sidebar", "sidebarQuery", "workspaceView", "conversation", "conversationTask", "conversationRun",
        "chatFilter", "chatActivity", "chatQuery", "directoryTab", "directoryQuery", "boardView", "q", "directory",
        "sort", "filters", "scheduleView", "scheduleQuery", "scheduleFilter", "scheduleRange", "scheduleDate",
        "teamQuery", "teamFilter", "teamPage", "settingsNested"
    ]

    static func url(base: URL, parameters: [String: String]) -> URL? {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false),
              ["https", "http"].contains(components.scheme?.lowercased() ?? ""), components.host != nil else { return nil }
        components.user = nil
        components.password = nil
        components.path = "/"
        components.fragment = nil
        components.queryItems = parameters.keys.sorted().filter { keys.contains($0) && parameters[$0] != "" }
            .map { URLQueryItem(name: $0, value: parameters[$0]) }
        return components.url
    }

    static func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }
}

struct DesktopCopyPageLinkButton: View {
    let url: URL?
    var label = "复制当前页面链接"
    @State private var copied = false
    @State private var failed = false

    var body: some View {
        Button {
            guard let url else { return }
            NSPasteboard.general.clearContents()
            copied = NSPasteboard.general.setString(url.absoluteString, forType: .string)
            failed = !copied
        } label: {
            Label(copied ? "链接已复制" : failed ? "复制失败，请重试" : label, systemImage: "link")
                .frame(minWidth: 132)
        }
        .buttonStyle(WandSecondaryButtonStyle())
        .disabled(url == nil)
        .accessibilityLabel(copied ? "链接已复制" : failed ? "复制失败，请重试" : label)
        .help("复制不含凭据的 Web 精确定位链接；打开时仍需登录对应服务器")
        .onChange(of: url) { _ in copied = false; failed = false }
    }
}
