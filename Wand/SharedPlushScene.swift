import AppKit
import SwiftUI
import WebKit

enum AvatarFileActivity: String { case idle, reading, writing }

func avatarIsThinking(messages: [ConversationTurn], executing: Bool) -> Bool {
    guard executing else { return false }
    let start = messages.lastIndex { $0.role == "user" }.map { $0 + 1 } ?? 0
    guard let turn = messages.dropFirst(start).last(where: { $0.role == "assistant" }), turn.completedAt == nil,
          let block = turn.content.last else { return false }
    if case .thinking = block { return true }
    return false
}
func avatarFileActivity(messages: [ConversationTurn], executing: Bool) -> AvatarFileActivity {
    guard executing else { return .idle }
    let start = messages.lastIndex { $0.role == "user" }.map { $0 + 1 } ?? 0
    var calls: [(String, AvatarFileActivity)] = []
    var completed = Set<String>()
    for turn in messages.dropFirst(start) {
        for block in turn.content {
            switch block {
            case let .toolResult(id, _, _, _, _, subagent): if subagent == nil { completed.insert(id) }
            case let .toolUse(id, _, _, input, subagent):
                guard subagent == nil, turn.completedAt == nil,
                      let activity = input["__wandToolActivity"]?.objectValue,
                      let kind = activity["kind"]?.stringValue, ["read_file", "edit_file"].contains(kind) else { continue }
                let value: AvatarFileActivity = kind == "read_file" ? .reading : .writing
                if let index = calls.firstIndex(where: { $0.0 == id }) { calls[index].1 = value }
                else { calls.append((id, value)) }
            default: break
            }
        }
    }
    return calls.reversed().first(where: { !completed.contains($0.0) })?.1 ?? .idle
}

/// Offline avatar scene only. No HTTP, cookies, model tools, or authentication bridge.
struct SharedPlushScene: NSViewRepresentable {
    let id: String
    let name: String
    let avatar: String
    var activity: AvatarFileActivity = .idle
    var thinking = false
    var paused = false
    var reduced = false
    var size: CGFloat = 88
    @Binding var rendered: Bool
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.underPageBackgroundColor = .clear
        view.setValue(false, forKey: "drawsBackground")
        view.setAccessibilityElement(false)
        view.navigationDelegate = context.coordinator
        context.coordinator.update = payload
        context.coordinator.onRendered = { rendered = $0 }
        context.coordinator.titleObservation = view.observe(\.title, options: [.new]) { [weak coordinator = context.coordinator] view, _ in
            DispatchQueue.main.async { coordinator?.onRendered(view.title == "scene-ready") }
        }
        if let url = Bundle.main.url(forResource: "scene", withExtension: "html", subdirectory: "PlushScene") {
            context.coordinator.sceneURL = url
            view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return view
    }
    private var payload: String {
        guard let asset = PlushAvatarIdentity.asset(id: id, name: name, avatar: avatar),
              let config = plushSceneConfig(asset) else { return "{}" }
        let value: [String: Any] = ["config": config, "size": size, "interactive": false,
            "speaking": false, "thinking": thinking && !paused, "fileActivity": paused ? "idle" : activity.rawValue,
            "reducedMotion": reduced || paused]
        return String(data: (try? JSONSerialization.data(withJSONObject: value)) ?? Data("{}".utf8), encoding: .utf8) ?? "{}"
    }
    func updateNSView(_ view: WKWebView, context: Context) {
        guard context.coordinator.update != payload else { return }
        context.coordinator.update = payload; context.coordinator.render(view)
    }
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.generation &+= 1
        view.evaluateJavaScript("window.disposeScene?.()")
        view.stopLoading(); view.navigationDelegate = nil; coordinator.titleObservation?.invalidate()
        coordinator.onRendered = { _ in }
    }
    final class Coordinator: NSObject, WKNavigationDelegate {
        var update = "{}"
        var loaded = false
        var sceneURL: URL?
        var generation: UInt64 = 0
        var titleObservation: NSKeyValueObservation?
        var onRendered: (Bool) -> Void = { _ in }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded = true; render(webView) }
        func render(_ view: WKWebView) {
            guard loaded else { return }
            generation &+= 1; let current = generation
            view.evaluateJavaScript("window.setScene(\(update));document.title") { [weak self, weak view] value, error in
                guard let self, let view, self.generation == current else { return }
                if error != nil || (value as? String) == "scene-fallback" { view.isHidden = true; self.onRendered(false) }
                else { view.isHidden = false; self.onRendered(view.title == "scene-ready") }
            }
        }
        func webView(_ view: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(action.request.url == sceneURL ? .allow : .cancel)
        }
        func webViewWebContentProcessDidTerminate(_ view: WKWebView) { generation &+= 1; loaded = false; view.isHidden = true; onRendered(false) }
    }
}

func plushSceneConfig(_ asset: String) -> [String: Any]? {
    if asset == "plush_dog_shiba_red" { return ["version": 1, "kind": "dog", "breed": "shiba", "scarf": "red"] }
    if ["plush_cat_silver", "plush_cat_orange"].contains(asset) { return ["version": 1, "kind": "cat", "coat": String(asset.dropFirst("plush_cat_".count))] }
    let fields = String(asset.dropFirst("plush_".count)).components(separatedBy: "_")
    guard asset.hasPrefix("plush_"), fields.count == 4 else { return nil }
    return ["version": 1, "shape": fields[0], "color": fields[1], "glasses": fields[2], "hat": fields[3]]
}

struct WorkingAvatar: View {
    let id: String
    let name: String
    var avatar: String = ""
    var activity: AvatarFileActivity = .idle
    var thinking = false
    var size: CGFloat = 88
    @Environment(\.scenePhase) private var scene
    @Environment(\.accessibilityReduceMotion) private var reduced
    @State private var visible = false
    @State private var rendered = false
    var body: some View {
        ZStack {
            ContactAvatar(id: id, avatar: avatar, name: name, size: size).opacity(rendered ? 0 : 1)
            if PlushAvatarIdentity.asset(id: id, name: name, avatar: avatar) != nil {
                SharedPlushScene(id: id, name: name, avatar: avatar, activity: activity, thinking: thinking,
                    paused: !visible || scene != .active, reduced: reduced, size: size, rendered: $rendered)
            }
        }.frame(width: size, height: size).accessibilityHidden(true).allowsHitTesting(false)
            .onAppear { visible = true }.onDisappear { visible = false }
    }
}
