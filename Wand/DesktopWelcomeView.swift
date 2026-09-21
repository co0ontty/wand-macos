import SwiftUI

/// The home page and contextual Add actions share one complete creation form.
struct DesktopWelcomeView: View {
    let api: WandAPI
    let draft: SessionCreationDraft
    let workspaceStore: WorkspaceStore
    let onCreated: (SessionSnapshot) -> Void

    var body: some View {
        NewSessionView(api: api, draft: draft, workspaceStore: workspaceStore,
                       embedded: true, onCreated: onCreated)
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
        @Environment(\.colorSchemeContrast) private var contrast
        var body: some View {
            configuration.label
                .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(Theme.textPrimary.opacity(isEnabled && configuration.isPressed ? 0.12 : (active ? 0.075 : (isEnabled && hovering ? 0.045 : 0)))))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                        .stroke(contrast == .increased && active ? Theme.textSecondary : .clear, lineWidth: 1)
                        .allowsHitTesting(false)
                }
                .opacity(isEnabled ? 1 : 0.45)
                .onHover { hovering = $0 }
                .wandMotion(value: hovering)
        }
    }
}
