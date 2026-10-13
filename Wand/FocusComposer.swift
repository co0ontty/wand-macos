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
    static let touch: CGFloat = 48
    static let icon: CGFloat = 34
    static let expandedRadius: CGFloat = 22
    static let collapsedRadius: CGFloat = 28
    static let maximumTextHeight: CGFloat = 112
    static let normalCompanionSize: CGFloat = 88
    static let normalCompanionClearance: CGFloat = 100
}

struct FocusComposerSurface<Editor: View, Add: View, Send: View, Settings: View>: View {
    let expanded: Bool
    let hasDraft: Bool
    var summary: String? = nil
    let onFocus: () -> Void
    @ViewBuilder let editor: () -> Editor
    @ViewBuilder let add: () -> Add
    @ViewBuilder let send: () -> Send
    @ViewBuilder let settings: () -> Settings
    @Environment(\.accessibilityReduceMotion) private var reduced
    var body: some View {
        VStack(spacing: 0) {
            editor().padding(.horizontal, 12).padding(.top, expanded ? 10 : 0)
                .frame(height: expanded ? nil : 0).clipped().opacity(expanded ? 1 : 0)
                .allowsHitTesting(expanded).accessibilityHidden(!expanded)
            HStack(spacing: 0) {
                add().frame(width: FocusComposerMetrics.touch, height: FocusComposerMetrics.touch)
                ZStack {
                    Button(action: onFocus) {
                        HStack(spacing: 5) {
                            Circle().fill(Theme.brand).frame(width: 6, height: 6).opacity(hasDraft ? 1 : 0)
                            Text(summary ?? (hasDraft ? "草稿 · 未发送" : "发消息…")).font(.system(size: 14)).lineLimit(1)
                        }.frame(maxWidth: .infinity, minHeight: FocusComposerMetrics.touch).contentShape(Rectangle())
                    }.buttonStyle(.plain).opacity(expanded ? 0 : 1).allowsHitTesting(!expanded).accessibilityHidden(expanded)
                }.frame(maxWidth: .infinity)
                send().frame(width: expanded ? FocusComposerMetrics.touch : 0).clipped()
                    .opacity(expanded ? 1 : 0).allowsHitTesting(expanded).accessibilityHidden(!expanded)
            }.padding(.horizontal, 4)
            settings().padding(.horizontal, 8)
                .frame(height: expanded ? nil : 0).clipped().opacity(expanded ? 1 : 0)
                .allowsHitTesting(expanded).accessibilityHidden(!expanded)
        }
        .foregroundColor(Theme.textSecondary)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: expanded ? FocusComposerMetrics.expandedRadius : FocusComposerMetrics.collapsedRadius))
        .overlay(RoundedRectangle(cornerRadius: expanded ? FocusComposerMetrics.expandedRadius : FocusComposerMetrics.collapsedRadius).stroke(Theme.border, lineWidth: 0.8))
        .animation(reduced ? nil : Theme.Motion.structure, value: expanded)
    }
}

enum NativeComposerPhase: Equatable { case idle, sending, sent, failed, unknown }

struct NativeComposerActionButton: View {
    let phase: NativeComposerPhase
    var turnRunning = false
    let hasDraft: Bool
    let canSubmit: Bool
    let onSend: () -> Void
    var onStop: () -> Void = {}
    @Environment(\.accessibilityReduceMotion) private var reduced
    private var stopping: Bool { phase == .idle && turnRunning && !hasDraft }
    private var tint: Color {
        switch phase {
        case .sent: return Theme.brand
        case .failed, .unknown: return Theme.danger
        case .sending: return Theme.brand
        case .idle: return canSubmit || stopping ? Theme.brand : Theme.textSecondary.opacity(0.16)
        }
    }
    var body: some View {
        Button { if stopping { onStop() } else { onSend() } } label: {
            ZStack {
                symbol("arrow.up", shown: phase == .idle && !stopping)
                symbol("stop.fill", shown: stopping)
                symbol("checkmark", shown: phase == .sent)
                symbol("exclamationmark", shown: phase == .failed)
                Text("核对").font(.system(size: 11, weight: .semibold)).opacity(phase == .unknown ? 1 : 0)
                ProgressView().controlSize(.small).tint(Theme.surface).opacity(phase == .sending ? 1 : 0)
            }
            .font(.system(size: 16, weight: .bold))
            .foregroundColor(phase == .idle && !canSubmit && !stopping ? Theme.textSecondary : Theme.surface)
            .frame(width: 34, height: 34).background(Circle().fill(tint))
            .frame(width: 48, height: 48).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(phase == .sending || (!canSubmit && !stopping))
            .accessibilityLabel(phase == .unknown ? "核对送达状态，不重发" : stopping ? "停止当前任务" : phase == .sending ? "发送中" : phase == .sent ? "已送达" : phase == .failed ? "发送异常" : "发送消息")
            .animation(reduced ? nil : Theme.Motion.structure, value: phase)
            .animation(reduced ? nil : Theme.Motion.structure, value: stopping)
    }
    private func symbol(_ name: String, shown: Bool) -> some View {
        Image(systemName: name).opacity(shown ? 1 : 0).scaleEffect(reduced || shown ? 1 : 0.9)
    }
}

struct ComposerSettingLabel: View {
    let title: String
    var body: some View {
        HStack(spacing: 3) {
            Text(title).font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
        }.frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
    }
}
