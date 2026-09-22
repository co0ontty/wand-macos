import SwiftUI
import AppKit

/// macOS 客户端的视觉 token。
/// 沿用 Web 登录页的暖纸、墨色与赤陶色，保留原生桌面控件和阅读密度。
/// 颜色与交互反馈在此统一，内容页面不再各自复制一套表面和动效。
enum Theme {
    private static func rgb(_ r: Double, _ g: Double, _ b: Double) -> NSColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }

    private static func rgbA(_ r: Double, _ g: Double, _ b: Double, _ a: Double) -> NSColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    /// 按当前外观(aqua / darkAqua)返回 light/dark 两套之一。
    /// 入参是 NSColor,内部包成 Color 给 SwiftUI 用。
    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }

    private static func dynamicNS(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }

    // MARK: - 品牌色(对齐 web --accent #C5653D)

    /// 新品牌主色,对齐 web --accent。暖珊瑚,深一档更接近 web。
    static let wandAccent = dynamic(
        light: rgb(0.663, 0.310, 0.169),
        dark: rgb(0.878, 0.608, 0.471)
    ) // #A94F2B / #E09B78; foreground contrast on paper and charcoal.
    /// Solid actions retain enough contrast for white labels in both appearances.
    static let accentSolid = Color(red: 0.722, green: 0.337, blue: 0.184)
    static let accentSolidHover = Color(red: 0.616, green: 0.275, blue: 0.137)
    /// 加深版:active / pressed 状态。
    static let wandAccentStrong = Color(red: 0.686, green: 0.325, blue: 0.188)  // #AF5330
    /// 0.12 透明,卡片背景用。
    static let wandAccentMuted = rgbA(0.773, 0.396, 0.239, 0.12)
    /// 0.25 透明,glow 阴影用。
    static let wandAccentGlow = rgbA(0.773, 0.396, 0.239, 0.25)

    // 旧 brand(供老引用方继续工作,iOS 端同步保留,后续统一)
    static let brand = wandAccent
    static let brandStrong = wandAccentStrong

    /// Codex provider 徽标色(对齐 web --info #4A6FA5)。
    static let codex = dynamic(
        light: rgb(0.290, 0.435, 0.647),
        dark: rgb(0.494, 0.612, 0.769)
    ) // #4A6FA5 / #7E9CC4
    static let openCode = dynamic(
        light: rgb(0.333, 0.408, 0.655),
        dark: rgb(0.518, 0.584, 0.824)
    )
    static let grok = dynamic(
        light: rgb(0.318, 0.337, 0.365),
        dark: rgb(0.722, 0.737, 0.757)
    )
    static let qoder = dynamic(
        light: rgb(0.365, 0.455, 0.400),
        dark: rgb(0.529, 0.675, 0.576)
    )

    static func providerColor(_ provider: String?) -> Color {
        switch provider {
        case "codex": return codex
        case "opencode": return openCode
        case "grok": return grok
        case "qoder": return qoder
        default: return wandAccent
        }
    }

    // MARK: - 背景层(对齐 web --bg-*)

    /// 与 Web 登录页同源的暖纸底色。
    static let background = dynamic(
        light: rgb(0.980, 0.969, 0.949),  // #FAF7F2
        dark: rgb(0.102, 0.094, 0.086)    // #1A1816
    )

    /// 侧栏只比正文深一档，靠留白和细线区分结构。
    static let sidebarBackground = dynamic(
        light: rgb(0.949, 0.929, 0.898),  // #F2EDE5
        dark: rgb(0.125, 0.114, 0.102)    // #201D1A
    )

    /// 聊天、终端和空状态所在的主工作区。
    static let workspaceBackground = dynamic(
        light: rgb(0.980, 0.969, 0.949),
        dark: rgb(0.102, 0.094, 0.086)
    )

    /// 二级背景：输入栏、静态控件和轻量卡片。
    static let surface = dynamic(
        light: rgb(0.949, 0.929, 0.898),
        dark: rgb(0.149, 0.137, 0.125)
    )

    /// 浮起层背景。
    static let surfaceElevated = dynamic(
        light: rgb(1.0, 0.992, 0.980),
        dark: rgb(0.165, 0.153, 0.141)
    )

    // MARK: - 边框(对齐 web --border-*)

    static let borderSubtle = dynamicNS(
        light: rgb(0.898, 0.871, 0.827), dark: rgb(0.239, 0.220, 0.196)
    )
    static let borderDefault = dynamicNS(
        light: rgb(0.812, 0.776, 0.722), dark: rgb(0.341, 0.310, 0.275)
    )
    static let border = dynamic(
        light: rgb(0.898, 0.871, 0.827),
        dark: rgb(0.275, 0.251, 0.224)
    )
    static let borderFocus = rgbA(0.773, 0.396, 0.239, 0.50)    // rgba(197,101,61,0.5)
    /// 玻璃表面的受光边缘。只用于结构性面板，避免每个控件都抢视觉注意力。
    static let glassHighlight = dynamic(
        light: rgbA(1.0, 1.0, 1.0, 0.72),
        dark: rgbA(1.0, 0.960, 0.910, 0.17)
    )

    // MARK: - 文本(对齐 web --text-*)

    static let textPrimary = dynamic(
        light: rgb(0.122, 0.106, 0.094),
        dark: rgb(0.953, 0.925, 0.886)
    )
    static let textSecondary = dynamic(
        light: rgb(0.341, 0.314, 0.290),
        dark: rgb(0.769, 0.729, 0.678)
    )
    static let textTertiary = dynamic(
        light: rgb(0.435, 0.400, 0.361),
        dark: rgb(0.690, 0.647, 0.592)
    )
    static let textMuted = dynamic(
        light: rgb(0.435, 0.400, 0.361),
        dark: rgb(0.690, 0.647, 0.592)
    )
    // MARK: - 语义色(对齐 web --success/--warning/--danger/--info)

    static let success = dynamic(light: rgb(0.290, 0.455, 0.325), dark: rgb(0.580, 0.749, 0.600))
    static let warning = dynamic(light: rgb(0.584, 0.365, 0.153), dark: rgb(0.871, 0.694, 0.439))
    static let danger = dynamic(light: rgb(0.678, 0.290, 0.255), dark: rgb(0.890, 0.565, 0.525))
    static let info = dynamic(light: rgb(0.275, 0.416, 0.624), dark: rgb(0.580, 0.706, 0.863))
    static let infoMuted = rgbA(0.290, 0.435, 0.647, 0.14)

    // MARK: - 圆角(对齐 web --radius-*)

    enum Radius {
        static let control: CGFloat = 8
        static let md: CGFloat = 10
        static let lg: CGFloat = 12
    }

    enum Motion {
        static let feedback = Animation.easeOut(duration: 0.12)
        static let structure = Animation.easeInOut(duration: 0.18)
    }

    // MARK: - 阴影(对齐 web --shadow-*,暖色调)
    // 暖色调阴影统一用 rgba(89, 58, 32, *) 透明度梯度。
    // 浮起卡片用 .md，浮起最高的弹窗用 .lg。

    enum ShadowToken {
        case md, lg

        var color: Color {
            switch self {
            case .md: return Color(nsColor: rgbA(0.349, 0.227, 0.125, 0.08))
            case .lg: return Color(nsColor: rgbA(0.349, 0.227, 0.125, 0.12))
            }
        }

        var radius: CGFloat {
            switch self {
            case .md: return 16
            case .lg: return 32
            }
        }

        var yOffset: CGFloat {
            switch self {
            case .md: return 4
            case .lg: return 8
            }
        }
    }

    // MARK: - 面板表面抽象

    /// 扁平面板:顶栏 / 侧栏 / 输入栏 / 会话头卡片背景。
    /// 统一走实色 surface + 暖色细描边,不再依赖 Liquid Glass / 毛玻璃 material,
    /// 各 macOS 版本外观一致,也与整体扁平简约风格保持协调。
    /// 视图层用 `View.wandGlass(...)` 直接挂即可。
    enum Glass: Equatable {
        case chrome           // 顶栏 / 工具条(不透明实色)
        case panel            // 侧栏 / 输入栏(接近不透明实色)

        var cornerRadius: CGFloat {
            switch self {
            case .chrome: return 0     // 顶栏贴窗口
            case .panel: return Radius.lg
            }
        }
    }

    // MARK: - 渐变背景(对齐 web body 径向渐变)

    /// 整个窗口的暖色径向渐变底,跟 web body 的多层渐变对齐。
    static var windowGradient: LinearGradient {
        LinearGradient(
            colors: [
                background,
                background
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

// MARK: - 液态玻璃修饰符

extension View {
    /// Quiet surface shared by native toolbars and panels.
    func wandGlass(_ kind: Theme.Glass) -> some View {
        modifier(WandGlassModifier(kind: kind))
    }

    func wandGlassCard(cornerRadius: CGFloat = 16) -> some View {
        modifier(WandGlassCardModifier(cornerRadius: cornerRadius))
    }

    func wandSelectionSurface(
        isSelected: Bool,
        isHovered: Bool,
        cornerRadius: CGFloat = 12
    ) -> some View {
        modifier(
            WandSelectionSurfaceModifier(
                isSelected: isSelected,
                isHovered: isHovered,
                cornerRadius: cornerRadius
            )
        )
    }

    /// Animate only the named interaction state; streamed content stays immediate.
    func wandMotion<Value: Equatable>(value: Value, layout: Bool = false) -> some View {
        modifier(WandMotionModifier(value: value, layout: layout))
    }
}

private struct WandMotionModifier<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let value: Value
    let layout: Bool

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : (layout ? Theme.Motion.structure : Theme.Motion.feedback), value: value)
    }
}

struct WandAmbientBackground: View {
    var body: some View {
        Theme.workspaceBackground
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }
}

struct WandPathText: View {
    let path: String
    var fontSize: CGFloat = 10
    var color: Color = Theme.textMuted

    var body: some View {
        let normalizedPath = path.replacingOccurrences(of: "\\", with: "/")
        Text(normalizedPath)
            .font(.system(size: fontSize, weight: .regular, design: .monospaced))
            .foregroundColor(color)
            .lineLimit(1)
            .truncationMode(.head)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(normalizedPath)
            .accessibilityLabel(path)
            .frame(height: ceil(fontSize * 1.45))
    }
}

private struct WandGlassModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    let kind: Theme.Glass

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: kind.cornerRadius, style: .continuous)
        let highContrast = contrast == .increased

        if kind == .chrome {
            // 工具栏与标题栏保持平面，只由相邻内容自己的细分隔线建立层级。
            content.background(Theme.workspaceBackground)
        } else {
            content
                .background(shape.fill(Theme.surfaceElevated))
                .overlay(
                    shape.stroke(
                        Theme.border,
                        lineWidth: highContrast ? 1.5 : 0.8
                    )
                )
        }
    }
}

private struct WandGlassCardModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    let cornerRadius: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let highContrast = contrast == .increased

        // 内容卡片与工作区同处一个平面，只用实色和细描边分组。
        content
            .background(shape.fill(Theme.surfaceElevated))
            .overlay(
                shape.stroke(
                    Theme.border,
                    lineWidth: highContrast ? 1.5 : 0.8
                )
            )
    }
}

/// 会话列表这类位于结构性玻璃面板内的高频行，不再嵌套一层玻璃。
/// 只用色彩、描边与非常轻的阴影表达焦点，保持列表快速、易扫读。
private struct WandSelectionSurfaceModifier: ViewModifier {
    let isSelected: Bool
    let isHovered: Bool
    let cornerRadius: CGFloat

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let highContrast = contrast == .increased
        let fill: Color = {
            if isSelected { return Theme.textPrimary.opacity(highContrast ? 0.15 : 0.075) }
            if isHovered { return Theme.textPrimary.opacity(0.045) }
            return .clear
        }()

        content
            .background(shape.fill(fill))
            .overlay(
                shape.stroke(
                    highContrast && isSelected
                        ? Theme.textPrimary.opacity(0.55)
                        : .clear,
                    lineWidth: highContrast && isSelected ? 1 : 0
                )
            )
            .wandMotion(value: isHovered)
    }
}

// MARK: - 兼容旧 API

extension View {
    /// Wand 文本输入表面：系统字体与原生编辑行为保持不变，只统一安静的静态态、
    /// 清晰的聚焦态和无过冲反馈。高对比度下改用实底与更粗描边。
    func wandInputSurface(
        focused: Bool,
        invalid: Bool = false,
        cornerRadius: CGFloat = 12
    ) -> some View {
        modifier(
            WandInputSurfaceModifier(
                focused: focused,
                invalid: invalid,
                cornerRadius: cornerRadius
            )
        )
    }

    /// 隐藏当前 sheet/window 的原生标题栏。
    /// SwiftUI 的 .sheet 在 macOS 上会自带一个 NSWindow 标题栏(sheetHeader 又自己画一个标题)，
    /// 视觉上「两层标题」很丑。挂这个修饰符后只保留我们自己的内容头部。
    /// 老 SDK 不支持 NSWindow.titlebarAppearsTransparent/titleVisibility 时静默降级。
    func hideNativeTitleBar() -> some View {
        background(NativeTitleBarHider())
    }

    /// 主窗口用：隐藏原生标题栏并让内容铺满整个窗口（fullSizeContentView），
    /// 自绘顶栏顶到窗口上沿，红绿灯浮在侧栏首行左侧；侧栏首行需自行留出红绿灯安全区。
    func extendContentUnderTitleBar() -> some View {
        background(MainWindowTitleBarConfigurator())
    }

    /// 标题区域的空白使用原生窗口拖拽，按钮与输入仍保留自己的命中和焦点。
    func windowDrag() -> some View {
        background(WindowDragRegion())
    }
}

private struct WandInputSurfaceModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    let focused: Bool
    let invalid: Bool
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let highContrast = contrast == .increased
        let stroke = invalid ? Theme.danger : (focused ? Theme.wandAccent : Theme.border)

        content
            .background {
                shape.fill(
                    reduceTransparency || highContrast
                        ? Theme.surfaceElevated
                        : Theme.surfaceElevated
                )
            }
            .overlay {
                shape.stroke(
                    stroke,
                    lineWidth: highContrast ? 2 : (focused || invalid ? 1.5 : 1)
                )
            }
            .shadow(
                color: focused && !highContrast ? Theme.wandAccent.opacity(0.05) : .clear,
                radius: 6,
                y: 2
            )
            .wandMotion(value: focused)
            .wandMotion(value: invalid)
    }
}

struct WindowDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { WindowDragNSView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class WindowDragNSView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
    // Match native title bars: dragging an inactive window works on the first press.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window, window.sheetParent == nil else { return }
        if event.clickCount == 2 {
            switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
            case "Minimize": window.miniaturize(nil)
            case "None": break
            default: window.zoom(nil)
            }
        } else {
            window.performDrag(with: event)
        }
    }
}

/// 找当前视图所在的 NSWindow,把标题栏改成透明且不显示标题。
/// SwiftUI 没有原生 API 关掉 sheet 的标题栏,只能从 AppKit 这一层做。
private struct NativeTitleBarHider: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = SheetTitleBarNSView()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? SheetTitleBarNSView)?.applyToWindow()
    }
}

private final class SheetTitleBarNSView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyToWindow()
    }

    func applyToWindow() {
        guard let window else { return }
        // 不要从 styleMask 里硬 remove(.titled),那样会同时干掉关闭/最小化按钮;
        // 只把标题栏变成透明 + 隐藏文字标题,关闭/缩放/最小化按钮都还在,
        // 用户拖窗口也能继续拖(可拖区域是标题栏以外的 contentLayoutRect)。
        if window.styleMask.contains(.titled) {
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = false
        }
    }
}

/// Scene 在创建窗口时配置标题栏；这里仅负责首次几何与跨启动恢复。
private struct MainWindowTitleBarConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        MainWindowTitleBarNSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? MainWindowTitleBarNSView)?.applyToWindow()
    }
}

enum DesktopWindowGeometry {
    static let minimumSize = CGSize(width: 900, height: 600)
    static let preferredSize = CGSize(width: 1600, height: 960)
    static let frameKey = "wand.desktop.windowFrame.v2"

    static func initialFrame(in visibleFrame: CGRect) -> CGRect {
        let size = CGSize(
            width: min(max(preferredSize.width, min(1920, visibleFrame.width * 0.82)),
                       max(minimumSize.width, visibleFrame.width - 48)),
            height: min(max(preferredSize.height, min(1120, visibleFrame.height * 0.86)),
                        max(minimumSize.height, visibleFrame.height - 48))
        )
        return fittedFrame(CGRect(origin: CGPoint(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.midY - size.height / 2
        ), size: size), in: visibleFrame)
    }

    static func fittedFrame(_ frame: CGRect, in visibleFrame: CGRect) -> CGRect {
        let size = CGSize(width: min(frame.width, visibleFrame.width),
                          height: min(frame.height, visibleFrame.height))
        return CGRect(x: min(max(frame.minX, visibleFrame.minX), visibleFrame.maxX - size.width),
                      y: min(max(frame.minY, visibleFrame.minY), visibleFrame.maxY - size.height),
                      width: size.width, height: size.height)
    }
}

private final class MainWindowTitleBarNSView: NSView {
    private weak var configuredWindow: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private var transitioningFullScreen = false

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyToWindow()
    }

    func applyToWindow() {
        guard let window, window.sheetParent == nil, configuredWindow !== window else { return }
        configuredWindow = window
        window.isMovableByWindowBackground = false
        window.tabbingMode = .disallowed
        // Defer until SwiftUI has applied its initial content constraints.
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.window === window,
                  let screen = window.screen ?? NSScreen.main else { return }
            let saved = UserDefaults.standard.string(forKey: DesktopWindowGeometry.frameKey)
                .map(NSRectFromString)
            let restored = saved.flatMap { frame -> CGRect? in
                guard frame.width >= DesktopWindowGeometry.minimumSize.width,
                      frame.height >= DesktopWindowGeometry.minimumSize.height,
                      [frame.minX, frame.minY, frame.width, frame.height].allSatisfy({ $0.isFinite }) else { return nil }
                return frame
            }
            let targetScreen = restored.flatMap { frame in
                NSScreen.screens.max {
                    let left = $0.visibleFrame.intersection(frame)
                    let right = $1.visibleFrame.intersection(frame)
                    return left.width * left.height < right.width * right.height
                }
            } ?? screen
            let frame = restored.map { DesktopWindowGeometry.fittedFrame($0, in: targetScreen.visibleFrame) }
                ?? DesktopWindowGeometry.initialFrame(in: screen.visibleFrame)
            window.setFrame(frame, display: true)
            self.observeGeometry(of: window)
            self.saveGeometry(of: window)
        }
    }

    private func observeGeometry(of window: NSWindow) {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        let names: [Notification.Name] = [NSWindow.didMoveNotification, NSWindow.didResizeNotification]
        for name in names + [NSWindow.willCloseNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self, weak window] _ in
                guard let self, let window else { return }
                self.saveGeometry(of: window)
            })
        }
        for name in [NSWindow.willEnterFullScreenNotification, NSWindow.willExitFullScreenNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                self?.transitioningFullScreen = true
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) { [weak self, weak window] _ in
            guard let self, let window else { return }
            self.transitioningFullScreen = false
            self.saveGeometry(of: window)
        })
    }

    private func saveGeometry(of window: NSWindow) {
        guard !transitioningFullScreen, !window.styleMask.contains(.fullScreen),
              !window.isMiniaturized else { return }
        UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: DesktopWindowGeometry.frameKey)
    }

}

// MARK: - 按钮样式

/// 实心珊瑚色主按钮,禁用态自动变淡。
struct WandPrimaryButtonStyle: ButtonStyle {
    @MainActor
    func makeBody(configuration: Configuration) -> Body {
        Body(configuration: configuration)
    }

    struct Body: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
                .padding(.vertical, 9)
                .padding(.horizontal, 14)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                        .fill(isEnabled && hovering ? Theme.accentSolidHover : Theme.accentSolid)
                )
                .brightness(isEnabled && configuration.isPressed ? -0.06 : 0)
                .opacity(isEnabled ? 1 : 0.45)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .wandMotion(value: hovering)
        }
    }
}

/// Compact primary action shared by the home and conversation composers.
struct WandSendButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SendButtonBody(configuration: configuration)
    }

    private struct SendButtonBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .foregroundColor(.white)
                .background(Circle().fill(isEnabled && hovering ? Theme.accentSolidHover : Theme.accentSolid))
                .brightness(isEnabled && configuration.isPressed ? -0.06 : 0)
                .opacity(isEnabled ? 1 : 0.4)
                .contentShape(Circle())
                .onHover { hovering = $0 }
                .wandMotion(value: hovering)
        }
    }
}

/// 描边次按钮,用于「重新连接 / 取消」等次要动作。
struct WandSecondaryButtonStyle: ButtonStyle {
    @MainActor
    func makeBody(configuration: Configuration) -> Body {
        Body(configuration: configuration)
    }

    struct Body: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false
        @Environment(\.colorSchemeContrast) private var contrast

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Theme.textPrimary)
                .padding(.vertical, 9)
                .padding(.horizontal, 14)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                        .fill(Theme.surfaceElevated)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                        .fill(Theme.textPrimary.opacity(isEnabled ? (configuration.isPressed ? 0.10 : (hovering ? 0.045 : 0)) : 0))
                        .allowsHitTesting(false)
                }
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                        .stroke(contrast == .increased ? Theme.textSecondary : Theme.border, lineWidth: 1)
                )
                .opacity(isEnabled ? 1 : 0.45)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .wandMotion(value: hovering)
        }
    }
}

/// Toolbar actions share a quiet hover and immediate pressed state.
struct WandIconButtonStyle: ButtonStyle {
    var isActive: Bool = false

    @MainActor
    func makeBody(configuration: Configuration) -> Body {
        Body(configuration: configuration, isActive: isActive)
    }

    struct Body: View {
        let configuration: ButtonStyleConfiguration
        let isActive: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .foregroundColor(
                    isActive
                        ? Theme.textPrimary
                        : (isEnabled ? Theme.textSecondary : Theme.textMuted)
                )
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                        .fill(
                            isEnabled && configuration.isPressed
                                ? Theme.textPrimary.opacity(0.10)
                                : Theme.textPrimary.opacity(isActive ? 0.075 : (isEnabled && hovering ? 0.045 : 0))
                        )
                )
                .opacity(isEnabled ? 1 : 0.45)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .wandMotion(value: hovering)
        }
    }
}

/// 与 Android 启动图标同源的像素猫；保留原色，不随按钮 tint 改色。
struct WandBrandMark: View {
    var size: CGFloat = 64

    var body: some View {
        Image("WandLogo")
            .renderingMode(.original)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
