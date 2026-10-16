import AppKit
import Combine
import SwiftUI
import UserNotifications

/// AppKit's native status item + popover work on the macOS 12 deployment target (MenuBarExtra needs 13).
@MainActor
final class DesktopActivitySurface: NSObject {
    private let monitor: DesktopActivityMonitor
    private let notifications: DesktopActivityNotifications
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let island: DesktopActivityIsland
    private var observation: AnyCancellable?
    private var preferenceObservation: NSObjectProtocol?

    init(monitor: DesktopActivityMonitor, notificationCenter: DesktopNotificationCenter = UNUserNotificationCenter.current(), statusItem: NSStatusItem? = nil) {
        self.monitor = monitor
        self.statusItem = statusItem ?? NSStatusBar.system.statusItem(withLength: 220)
        notifications = DesktopActivityNotifications(monitor: monitor, center: notificationCenter)
        island = DesktopActivityIsland(monitor: monitor)
        super.init()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 400, height: 520)
        popover.contentViewController = NSHostingController(rootView: DesktopActivityList(monitor: monitor, notifications: notifications) { [weak self] in
            self?.popover.performClose(nil)
        })
        self.statusItem.button?.target = self
        self.statusItem.button?.action = #selector(togglePopover)
        monitor.onEvents = { [weak self] events in self?.notifications.deliver(events) }
        monitor.onReset = { [weak self] in self?.notifications.reset(); self?.island.reset() }
        monitor.onOpenWindow = { [weak self] in
            self?.popover.performClose(nil)
            self?.island.collapse()
            Self.showMainWindow()
        }
        observation = monitor.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.update() }
        }
        preferenceObservation = NotificationCenter.default.addObserver(forName: .wandActivityNotificationPreference, object: nil, queue: .main) { [weak self] note in
            guard let enabled = note.object as? Bool else { return }
            Task { @MainActor in self?.notifications.setEnabled(enabled) }
        }
        notifications.refreshAuthorization()
        update()
    }

    deinit {
        if let preferenceObservation { NotificationCenter.default.removeObserver(preferenceObservation) }
    }

    private func update() {
        let running = monitor.activities.filter { $0.phase == .running }.count
        let waiting = monitor.activities.filter { $0.phase == .waiting }.count
        let symbol = !monitor.isFresh ? "network" : waiting > 0 ? "hand.raised.fill" : running > 0 ? "arrow.triangle.2.circlepath" : monitor.activities.first?.phase.symbol ?? "sparkles"
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Wand 任务状态")
        statusItem.button?.image?.isTemplate = true
        let primary = monitor.activities.first
        let detail: String
        if !monitor.isFresh { detail = monitor.connectionLabel }
        else if let primary {
            let steps = primary.progress.flatMap { progress -> String? in
                if let completed = progress.completedSteps, let total = progress.totalSteps { return "\(completed)/\(total)步" }
                return progress.hasMessages ? "调用\(progress.toolCalls)次" : nil
            }
            detail = [primary.providerLabel, steps, primary.phase.label].compactMap { $0 }.joined(separator: " · ")
        } else { detail = "Wand · 空闲" }
        let more = waiting + running > 1 ? " +\(waiting + running - 1)" : ""
        statusItem.button?.font = .systemFont(ofSize: 11)
        statusItem.button?.title = " \(detail)\(more)"
        statusItem.button?.toolTip = (["Wand · \(monitor.summary)", primary?.title, primary?.identityLabel,
            primary?.progressLabel, primary?.progress?.resultLabel, primary?.progress?.toolLabel].compactMap { $0 }).joined(separator: "\n")
        statusItem.button?.setAccessibilityLabel(statusItem.button?.toolTip)
        island.update()
    }

    var isPopoverShown: Bool { popover.isShown }
    var popoverContentView: NSView? { popover.contentViewController?.view }

    func close() {
        popover.performClose(nil)
        island.close()
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown { popover.performClose(nil) }
        else {
            notifications.refreshAuthorization()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    static func showMainWindow() {
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { !($0 is NSPanel) && $0.styleMask.contains(.titled) }) {
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
        } else {
            // LaunchServices reopens the existing SwiftUI WindowGroup, it doesn't spawn a second app.
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: .init()) { _, _ in }
        }
    }
}

private struct DesktopActivityList: View {
    @ObservedObject var monitor: DesktopActivityMonitor
    let notifications: DesktopActivityNotifications
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Wand").font(.headline)
                Spacer()
                Button("打开主窗口") { onOpen(); DesktopActivitySurface.showMainWindow() }
                    .buttonStyle(.link)
            }
            Text(monitor.summary).font(.caption).foregroundColor(Theme.textSecondary)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(monitor.activities) { activity in
                        Button { onOpen(); monitor.openSession(activity.id) } label: {
                            DesktopActivityRow(activity: activity)
                        }.buttonStyle(.plain)
                    }
                    if monitor.activities.isEmpty {
                        Text(monitor.isFresh ? "任务执行时会显示在这里。" : "恢复连接后自动同步；不会把断线当成完成。")
                            .font(.caption).foregroundColor(Theme.textSecondary)
                            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
                    }
                }
            }.frame(maxHeight: .infinity)
            Divider()
            DesktopActivityPreferences(monitor: monitor, notifications: notifications)
            HStack {
                Button("清除近期提示") { monitor.dismissRecent() }.buttonStyle(.link)
                Spacer()
                Button("退出 Wand") { NSApp.terminate(nil) }.buttonStyle(.link)
            }.font(.caption)
        }
        .padding(16)
        .frame(width: 400, height: 520)
        .background(Theme.surface)
    }
}

struct DesktopActivityPreferences: View {
    @ObservedObject var monitor: DesktopActivityMonitor
    /// The running app owns its notification delegate; tests/isolated previews never construct it implicitly.
    var notifications: DesktopActivityNotifications?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("顶部灵动岛式状态", isOn: Binding(get: { monitor.islandEnabled }, set: monitor.setIslandEnabled))
                .accessibilityIdentifier("desktop-activity-island-toggle")
            Toggle("关键节点系统通知", isOn: Binding(get: { monitor.notificationsEnabled }, set: { enabled in
                if let notifications { notifications.setEnabled(enabled) }
                else { NotificationCenter.default.post(name: .wandActivityNotificationPreference, object: enabled) }
            }))
                .accessibilityIdentifier("desktop-activity-notifications-toggle")
            Text(monitor.notificationMessage).font(.caption).foregroundColor(Theme.textSecondary)
            Text("步骤完成、执行完成、失败、停止与等待处理时提醒；仅在 Wand 运行且连接服务器时同步。")
                .font(.caption).foregroundColor(Theme.textSecondary)
        }.toggleStyle(.switch).font(.system(size: 12))
    }
}

private struct DesktopActivityRow: View {
    let activity: DesktopActivity
    var onDark = false
    private var secondary: Color { onDark ? .white.opacity(0.7) : Theme.textSecondary }
    private var accent: Color {
        if activity.phase == .failed { return Theme.danger }
        if activity.phase == .waiting { return Theme.warning }
        if activity.phase == .completed { return Theme.success }
        return Theme.wandAccent
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: activity.phase.symbol).foregroundColor(accent)
                Text(activity.title).font(.system(size: 12, weight: .semibold)).lineLimit(2)
                Spacer(minLength: 0)
                Text(activity.phase.label).font(.system(size: 10, weight: .medium))
                    .foregroundColor(accent).padding(.horizontal, 6).padding(.vertical, 3)
                    .background(accent.opacity(0.12)).clipShape(Capsule())
            }
            Text(activity.identityLabel).font(.system(size: 11)).foregroundColor(secondary).lineLimit(1)
            Text(activity.progressLabel).font(.system(size: 11, weight: .medium)).lineLimit(2)
            if let progress = activity.progress {
                if let completed = progress.completedSteps, let total = progress.totalSteps, total > 0 {
                    ProgressView(value: Double(completed), total: Double(total)).tint(accent)
                }
                if let step = progress.currentStep, !step.isEmpty {
                    Text(step).font(.caption).lineLimit(2)
                }
                HStack(spacing: 6) {
                    Text(progress.resultLabel)
                    Spacer(minLength: 0)
                    Text(progress.elapsed.map { "用时 \($0)" } ?? "耗时未提供")
                }.font(.system(size: 10)).foregroundColor(secondary)
                if let tool = progress.toolLabel {
                    Label(tool, systemImage: "wrench.and.screwdriver").font(.system(size: 10)).lineLimit(1)
                        .foregroundColor(secondary)
                }
                if Date().timeIntervalSince(progress.sampledAt) > 10 {
                    Text("进度采样于 \(progress.sampledAt, style: .relative)前").font(.system(size: 10)).foregroundColor(secondary)
                }
            }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// Screen geometry is independent of screen origin and respects the camera safe area.
enum DesktopActivityIslandGeometry {
    static func height(expanded: Bool, rowCount: Int) -> CGFloat {
        expanded ? 56 + min(CGFloat(rowCount) * 170 + 16, 340) : 56
    }

    static func frame(screen: CGRect, visible: CGRect, safeTop: CGFloat, expanded: Bool, rowCount: Int = 6) -> CGRect {
        let width = min(360, screen.width - 24)
        let height = height(expanded: expanded, rowCount: rowCount)
        let top = min(visible.maxY, screen.maxY - safeTop) - 8
        return CGRect(x: screen.midX - width / 2, y: top - height, width: width, height: height)
    }
}

private final class DesktopActivityPanel: NSPanel {
    // Nonactivating panels may receive keyboard focus after an explicit user expansion,
    // without activating Wand or requesting global keyboard-monitoring privileges.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class DesktopActivityIsland: NSObject, ObservableObject {
    @Published private(set) var expanded = false
    private let monitor: DesktopActivityMonitor
    private let observesOutsideEvents: Bool
    private let animates: Bool
    private var panel: NSPanel?
    private var dismissedSignature: [String]?
    private var localEvents: Any?
    private var globalEvents: Any?
    private var screenObservation: NSObjectProtocol?

    init(monitor: DesktopActivityMonitor, observesOutsideEvents: Bool = true, animates: Bool = true) {
        self.monitor = monitor
        self.observesOutsideEvents = observesOutsideEvents
        self.animates = animates
        super.init()
        screenObservation = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.update() }
        }
    }

    deinit {
        if let screenObservation { NotificationCenter.default.removeObserver(screenObservation) }
        if let localEvents { NSEvent.removeMonitor(localEvents) }
        if let globalEvents { NSEvent.removeMonitor(globalEvents) }
    }

    func close() {
        removeOutsideDismissal()
        panel?.contentView = nil
        panel?.close()
        panel = nil
    }

    func reset() { dismissedSignature = nil; collapse(); panel?.orderOut(nil) }

    func update() {
        guard monitor.islandEnabled, monitor.isFresh, !monitor.activities.isEmpty,
              monitor.activities.map(\.stateIdentity) != dismissedSignature else { collapse(); panel?.orderOut(nil); return }
        if panel == nil {
            let panel = DesktopActivityPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = "Wand 任务动态"
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: DesktopActivityIslandView(monitor: monitor, island: self))
            // AppKit owns the animated window frame; SwiftUI's compact intrinsic minimum must not
            // resize the panel back to 56pt during the expansion transaction.
            if #available(macOS 13, *) { host.sizingOptions = [] }
            panel.contentView = host
            self.panel = panel
        }
        position(animated: false)
        panel?.orderFrontRegardless()
    }

    private func position(animated: Bool) {
        guard let panel, let screen = NSScreen.screens.first else { return }
        // The system's primary display is stable across application activation and secondary-window moves.
        let frame = DesktopActivityIslandGeometry.frame(screen: screen.frame, visible: screen.visibleFrame,
            safeTop: screen.safeAreaInsets.top, expanded: expanded, rowCount: monitor.activities.count)
        if animated && animates && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Theme.Motion.structureDuration
                panel.animator().setFrame(frame, display: true)
            }
        } else { panel.setFrame(frame, display: true) }
    }

    func toggle() {
        expanded.toggle()
        position(animated: true)
        if expanded {
            panel?.makeKeyAndOrderFront(nil)
            installOutsideDismissal()
        } else {
            panel?.resignKey()
            removeOutsideDismissal()
        }
    }

    func collapse() {
        guard expanded else { return }
        expanded = false
        panel?.resignKey()
        position(animated: true)
        removeOutsideDismissal()
    }

    func dismiss() {
        dismissedSignature = monitor.activities.map(\.stateIdentity)
        collapse()
        panel?.orderOut(nil)
    }

    private func installOutsideDismissal() {
        guard observesOutsideEvents else { return }
        removeOutsideDismissal()
        localEvents = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown, event.keyCode == 53, event.window === self.panel {
                self.collapse()
                return nil
            }
            if event.type != .keyDown, self.panel?.frame.contains(NSEvent.mouseLocation) != true { self.collapse() }
            return event
        }
        // Mouse-only global monitoring does not require Accessibility or Input Monitoring permissions.
        globalEvents = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.panel?.frame.contains(NSEvent.mouseLocation) != true else { return }
                self.collapse()
            }
        }
    }

    private func removeOutsideDismissal() {
        if let localEvents { NSEvent.removeMonitor(localEvents); self.localEvents = nil }
        if let globalEvents { NSEvent.removeMonitor(globalEvents); self.globalEvents = nil }
    }
}

private struct DesktopActivityIslandView: View {
    @ObservedObject var monitor: DesktopActivityMonitor
    @ObservedObject var island: DesktopActivityIsland
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button(action: island.toggle) {
                    HStack(spacing: 10) {
                        Image(systemName: monitor.activities.first?.phase.symbol ?? "sparkles")
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(monitor.summary).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                            Text(monitor.activities.first?.title ?? "Wand").font(.caption).lineLimit(1).opacity(0.7)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.down").rotationEffect(.degrees(island.expanded ? 180 : 0))
                            .wandMotion(value: island.expanded)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel(island.expanded ? "收起任务动态" : "展开任务动态")
                Button(action: island.dismiss) { Image(systemName: "xmark").frame(width: 24, height: 28) }
                    .buttonStyle(.plain).accessibilityLabel("暂时隐藏任务动态")
            }.padding(.horizontal, 16).frame(height: 56)
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(monitor.activities) { activity in
                        Button { island.collapse(); monitor.openSession(activity.id) } label: {
                            DesktopActivityRow(activity: activity, onDark: true)
                        }.buttonStyle(.plain)
                    }
                }.padding(8)
            }
            .opacity(island.expanded ? 1 : 0)
            .allowsHitTesting(island.expanded)
            .accessibilityHidden(!island.expanded)
            .wandMotion(value: island.expanded)
        }
        .frame(maxWidth: .infinity)
        .frame(height: DesktopActivityIslandGeometry.height(expanded: island.expanded, rowCount: monitor.activities.count), alignment: .top)
        .foregroundColor(.white)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

extension Notification.Name {
    static let wandActivityNotificationPreference = Notification.Name("WandActivityNotificationPreference")
}
