import AppKit
import Combine
import SwiftUI

/// iOS-compatible presentation only; draft and delivery stay with their current owner.
@MainActor final class ComposerFocusController: ObservableObject {
    @Published var focused = false
    @Published var editing = false
    private(set) var borrowers = Set<String>()
    private var restore = false
    private(set) var awaitingAck = false
    private(set) var recovery = false
    func focus() { editing = true; focused = true }
    func collapse() {
        restore = false; focused = false
        if !awaitingAck && !recovery { editing = false }
    }
    func submit() { awaitingAck = true; editing = true }
    func accepted(hasPendingContent: Bool) {
        if awaitingAck && !hasPendingContent { focused = false; editing = false }
        awaitingAck = false; recovery = false
    }
    func failed() { awaitingAck = false; recovery = true; editing = true }
    func resetPresentation() { awaitingAck = false; recovery = false; restore = false; borrowers = []; focused = false; editing = false }
    func collapseFromContent() { if borrowers.isEmpty { collapse() } }
    func borrow(_ owner: String, open: Bool = false) {
        restore = restore || focused || open
        if open { editing = true }
        borrowers.insert(owner); focused = false
    }
    func resume(_ owner: String) {
        guard borrowers.remove(owner) != nil, borrowers.isEmpty else { return }
        let shouldRestore = restore && editing; restore = false
        if shouldRestore { focused = true }
    }
    func lostFocus() { if borrowers.isEmpty { collapse() } }
}

enum FocusComposerMetrics {
    // Web --composer-control-height / --control-radius, at desktop pointer density.
    static let touch: CGFloat = 32
    static let controlRadius: CGFloat = 8
    static let maximumTextHeight: CGFloat = 112
    static let normalCompanionSize: CGFloat = 72
}

struct FocusComposerSurface<Editor: View, Add: View, Send: View>: View {
    let expanded: Bool
    let hasDraft: Bool
    var summary: String? = nil
    let onFocus: () -> Void
    @ViewBuilder let editor: () -> Editor
    @ViewBuilder let add: () -> Add
    @ViewBuilder let send: () -> Send
    var primaryVisible = true
    var isFocused = false
    var showsAdvancedSettings = false
    var accessory: AnyView? = nil
    @Environment(\.accessibilityReduceMotion) private var reduced
    var body: some View {
        VStack(spacing: 4) {
            if let accessory { accessory }
            // Same editor, full width. Web keeps the footer anchored while it grows up.
            editor()
                .frame(height: expanded ? nil : 0).clipped().opacity(expanded ? 1 : 0)
                .allowsHitTesting(expanded).accessibilityHidden(!expanded)
            HStack(spacing: 6) {
                add().frame(width: FocusComposerMetrics.touch, height: FocusComposerMetrics.touch)
                if showsAdvancedSettings, expanded {
                    Button {} label: { Image(systemName: "gearshape").font(.system(size: 14)) }
                        .buttonStyle(.plain).frame(width: 32, height: 32).disabled(true)
                        .help("Pi 会话级高级设置尚未接入 macOS；模型、权限与思考可在加号菜单修改")
                        .accessibilityLabel("Pi 高级设置，macOS 尚未接入")
                }
                Button(action: onFocus) {
                    Text(summary ?? (hasDraft ? "草稿 · 未发送" : "输入消息…"))
                        .font(.system(size: 14)).lineLimit(1).truncationMode(.tail)
                        .frame(maxWidth: .infinity, minHeight: FocusComposerMetrics.touch, alignment: .leading)
                        .padding(.horizontal, 8).contentShape(Rectangle())
                }
                .buttonStyle(.plain).opacity(expanded ? 0 : 1)
                .allowsHitTesting(!expanded).accessibilityHidden(expanded)
                send().frame(width: FocusComposerMetrics.touch, height: FocusComposerMetrics.touch)
                    .opacity(primaryVisible ? 1 : 0).allowsHitTesting(primaryVisible).accessibilityHidden(!primaryVisible)
                    .animation(reduced ? nil : Theme.Motion.feedback, value: primaryVisible)
                    .padding(.leading, 2)
            }
        }
        .padding(.top, 11)
        .frame(maxWidth: .infinity)
        .foregroundColor(Theme.textSecondary)
        .overlay(alignment: .top) {
            Rectangle().fill(isFocused ? Theme.brand : Theme.border)
                .frame(height: isFocused ? 2 : 1).allowsHitTesting(false)
        }
        .animation(reduced ? nil : Theme.Motion.structure, value: expanded)
    }
}

/// Mirrors Web's floating identity/runtime anchors relative to the top divider.
enum ComposerHeaderKind { case task, conversation }

struct ComposerIdentityHeader<Portrait: View, Identity: View, Runtime: View>: View {
    var hasPortrait = true
    var kind: ComposerHeaderKind = .task
    var progress: AnyView? = nil
    @ViewBuilder let portrait: () -> Portrait
    @ViewBuilder let identity: () -> Identity
    @ViewBuilder let runtime: () -> Runtime
    @State private var viewportWidth: CGFloat? = nil
    var body: some View {
        GeometryReader { geometry in
            let compact = (viewportWidth ?? geometry.size.width) <= 640
            let progressWidth = min(300, geometry.size.width * (compact ? 0.46 : 0.3))
            let sideWidth = max(0, (geometry.size.width - progressWidth) / 2 - 8)
            ZStack(alignment: .bottomLeading) {
                if hasPortrait {
                    portrait().frame(width: 72, height: 72).offset(y: kind == .task ? 7 : -4)
                    if (viewportWidth ?? geometry.size.width) > 640 {
                        identity().font(.system(size: 12, weight: .medium)).lineLimit(1)
                            .frame(maxWidth: progress == nil ? max(0, geometry.size.width - 320) : max(0, sideWidth - 84), minHeight: 24, alignment: .leading)
                            .padding(.leading, 84).offset(y: kind == .task ? 3 : -4)
                    }
                }
                runtime().frame(maxWidth: progress == nil || compact ? max(0, geometry.size.width - (hasPortrait ? 84 : 0)) : sideWidth, minHeight: kind == .task ? 32 : 24, alignment: .trailing)
                    .frame(maxWidth: .infinity, alignment: .trailing).offset(y: kind == .task ? 7 : -32)
                if let progress {
                    progress.frame(width: progressWidth)
                        .frame(maxWidth: .infinity, alignment: compact ? .trailing : .center)
                        .offset(y: compact ? -25 : 3)
                }
            }.frame(width: geometry.size.width, height: geometry.size.height, alignment: .bottomLeading)
        }
        .frame(height: hasPortrait ? (kind == .task ? 65 : 76) : 28)
        .background(ComposerViewportWidth { width in
            if viewportWidth != width { viewportWidth = width }
        }.frame(width: 0, height: 0))
        .zIndex(1)
    }
}

/// Web's breakpoint is the viewport, not the narrower chat column.
private struct ComposerViewportWidth: NSViewRepresentable {
    let onWidth: (CGFloat) -> Void
    func makeNSView(context: Context) -> WidthView { WidthView(onWidth: onWidth) }
    func updateNSView(_ view: WidthView, context: Context) { view.onWidth = onWidth; view.report() }
    final class WidthView: NSView {
        var onWidth: (CGFloat) -> Void
        private var observer: NSObjectProtocol?
        init(onWidth: @escaping (CGFloat) -> Void) { self.onWidth = onWidth; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
            if let window {
                observer = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in self?.report() }
                report()
            }
        }
        func report() {
            guard let width = window?.contentLayoutRect.width else { return }
            DispatchQueue.main.async { [weak self] in self?.onWidth(width) }
        }
        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    }
}

/// Shared Web-shaped 32pt controls; all hit/hover styling lives in this primitive.
struct ComposerControlStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.frame(width: 32, height: 32)
            .foregroundColor(Theme.textPrimary)
            .background(RoundedRectangle(cornerRadius: 8).fill(configuration.isPressed ? Theme.surfaceSoft : Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
            .contentShape(Rectangle())
    }
}

/// The portrait renderer deliberately ignores hits. A sibling native button owns input focus.
struct ComposerCompanion<Portrait: View>: View {
    let focus: () -> Void
    @ViewBuilder let portrait: () -> Portrait

    var body: some View {
        ZStack {
            portrait()
            Button(action: focus) {
                Color.clear.contentShape(Rectangle())
                    .frame(width: FocusComposerMetrics.normalCompanionSize, height: FocusComposerMetrics.normalCompanionSize)
            }.buttonStyle(.plain).accessibilityLabel("编辑消息")
        }
        .frame(width: FocusComposerMetrics.normalCompanionSize, height: FocusComposerMetrics.normalCompanionSize)
    }
}

/// Shared native popover chrome; Escape is scoped to its own window, not global input.
struct ComposerPopoverHeader: View {
    let title: String
    let close: () -> Void

    var body: some View {
        HStack {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundColor(Theme.textSecondary)
            Spacer(minLength: 8)
            Button(action: close) { Image(systemName: "xmark") }
                .buttonStyle(WandIconButtonStyle())
                .accessibilityLabel("关闭" + title)
        }
        .background(ComposerPopoverEscape(close: close).frame(width: 0, height: 0))
    }
}

/// SwiftUI onExitCommand does not reliably fire in an unfocused macOS popover.
/// A local AppKit adapter keeps nested windows and IME cancellation independent.
private struct ComposerPopoverEscape: NSViewRepresentable {
    let close: () -> Void
    func makeNSView(context: Context) -> EscapeRegion { EscapeRegion(close: close) }
    func updateNSView(_ view: EscapeRegion, context: Context) { view.close = close }

    final class EscapeRegion: NSView {
        var close: () -> Void
        private var monitor: Any?
        init(close: @escaping () -> Void) { self.close = close; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window,
                      event.keyCode == 53, event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                      (window.firstResponder as? NSTextInputClient)?.hasMarkedText() != true else { return event }
                self.close()
                return nil
            }
        }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}

enum NativeComposerPhase: Equatable { case idle, sending, sent, failed, unknown }

/// Shared mobile rule: execution wins over draft and submission feedback.
func nativeComposerPrimaryVisible(text: String, hasAttachments: Bool, turnRunning: Bool, phase: NativeComposerPhase) -> Bool {
    turnRunning || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || hasAttachments ||
        (phase != .idle && phase != .sent)
}

func nativeComposerActionPhase(phase: NativeComposerPhase, turnRunning: Bool) -> NativeComposerPhase {
    turnRunning ? .idle : phase
}

struct NativeComposerActionButton: View {
    let phase: NativeComposerPhase
    var turnRunning = false
    let canSubmit: Bool
    let onSend: () -> Void
    var onStop: () -> Void = {}
    @Environment(\.accessibilityReduceMotion) private var reduced
    private var stopping: Bool { turnRunning }
    private var displayedPhase: NativeComposerPhase { nativeComposerActionPhase(phase: phase, turnRunning: turnRunning) }
    private var tint: Color {
        switch displayedPhase {
        case .sent: return Theme.brand
        case .failed, .unknown: return Theme.danger
        case .sending: return Theme.brand
        case .idle: return stopping ? Theme.danger : canSubmit ? Theme.brand : Theme.surfaceSoft
        }
    }
    var body: some View {
        Button { if stopping { onStop() } else { onSend() } } label: {
            ZStack {
                symbol("arrow.up", shown: displayedPhase == .idle && !stopping)
                symbol("stop.fill", shown: stopping)
                symbol("checkmark", shown: displayedPhase == .sent)
                symbol("exclamationmark", shown: displayedPhase == .failed)
                Text("核对").font(.system(size: 11, weight: .semibold)).opacity(displayedPhase == .unknown ? 1 : 0)
                ProgressView().controlSize(.small).tint(Theme.surface).opacity(displayedPhase == .sending ? 1 : 0)
            }
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(displayedPhase == .idle && !canSubmit && !stopping ? Theme.textSecondary : Theme.surface)
            .frame(width: 32, height: 32)
            .background(RoundedRectangle(cornerRadius: FocusComposerMetrics.controlRadius).fill(tint))
            .contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(!stopping && (displayedPhase == .sending || !canSubmit))
            .accessibilityLabel(stopping ? "停止当前任务" : displayedPhase == .unknown ? "核对送达状态，不重发" : displayedPhase == .sending ? "发送中" : displayedPhase == .sent ? "已送达" : displayedPhase == .failed ? "发送异常" : "发送消息")
            .animation(reduced ? nil : Theme.Motion.feedback, value: displayedPhase)
            .animation(reduced ? nil : Theme.Motion.structure, value: stopping)
    }
    private func symbol(_ name: String, shown: Bool) -> some View {
        Image(systemName: name).opacity(shown ? 1 : 0).scaleEffect(reduced || shown ? 1 : 0.9)
    }
}

/// Stored preferences are not proof of a fallback model's actual execution.
func composerThinkingPreference(_ value: String) -> String {
    let native = value.split(separator: ":", maxSplits: 1).last.map(String.init) ?? value
    if !value.contains(":"), let stored = ["off": "自动（模型默认）", "standard": "标准", "deep": "深入", "max": "最大"][value] { return stored }
    return ["auto": "自动", "off": "关闭", "none": "关闭", "minimal": "最低", "low": "低", "medium": "中",
        "high": "高", "xhigh": "超高", "max": "极高", "ultra": "极限", "ultracode": "极限代码"][native] ?? native
}

struct ComposerSettingLabel: View {
    let title: String
    var icon: String? = nil
    var body: some View {
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon).font(.system(size: 11)) }
            Text(title).font(.system(size: 12))
                .lineLimit(1).truncationMode(.tail)
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .medium)).opacity(0.55)
        }
        .foregroundColor(Theme.textSecondary)
        .padding(.horizontal, 4).frame(minHeight: 32).contentShape(Rectangle())
    }
}

/// Display only; server permission values and confirmation boundaries stay unchanged.
func composerPermissionLabel(_ value: String) -> String {
    ["default": "标准", "auto-edit": "自动编辑", "full-access": "完全访问", "managed": "托管", "native": "原生"][value] ?? value
}
