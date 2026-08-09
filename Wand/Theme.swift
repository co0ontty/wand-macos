import SwiftUI
import AppKit

/// 品牌色与复用样式,对齐 web 端的 :root token(暖米色背景 + 暖珊瑚 accent)。
/// 颜色随系统明暗自适应；面板/卡片走扁平实色 surface + 暖色细描边的简约风格,
/// 不再使用系统 Liquid Glass / 毛玻璃 material,保证各 macOS 版本外观一致。
///
/// 暖米色背景取 web 端 --bg-primary #F6F1E8,品牌主色取 web 端 --accent #C5653D。
/// 旧 `Theme.brand`(#D97757, iOS / macOS 沿用)保留做兼容 — 引用方暂未迁移过来之前不破坏。
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
        light: rgb(0.773, 0.396, 0.239),
        dark: rgb(0.831, 0.459, 0.314)
    ) // #C5653D / #D47550
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

    /// 主背景:对齐 web --bg-primary 暖米色。暗色下走 web 没明确的暗色(纯 web 是亮色),
    /// 这里在暗色下用暖灰底,保留品牌识别。
    static let background = dynamic(
        light: rgb(0.961, 0.953, 0.933),  // #F5F3EE
        dark: rgb(0.075, 0.067, 0.059)    // #13110F
    )

    /// 二级背景,顶栏 / 侧栏 / 输入栏胶囊(对齐 web --bg-secondary)。
    static let surface = dynamic(
        light: rgbA(1.0, 0.992, 0.976, 0.86),      // #FFFDF9
        dark: rgbA(0.129, 0.118, 0.102, 0.86)      // #211E1A
    )

    /// 浮起层背景(对齐 web --bg-elevated)。
    static let surfaceElevated = dynamic(
        light: rgb(0.988, 0.980, 0.965),  // #FCFAF6
        dark: rgb(0.114, 0.102, 0.090)    // #1D1A17
    )

    // MARK: - 边框(对齐 web --border-*)

    static let borderSubtle = rgbA(0.424, 0.345, 0.282, 0.10)
    static let borderDefault = rgbA(0.424, 0.345, 0.282, 0.18)
    static let border = dynamic(
        light: rgb(0.851, 0.824, 0.788),
        dark: rgb(0.239, 0.216, 0.188)
    ) // #D9D2C9 / #3D3730
    static let borderFocus = rgbA(0.773, 0.396, 0.239, 0.50)    // rgba(197,101,61,0.5)
    /// 玻璃表面的受光边缘。只用于结构性面板，避免每个控件都抢视觉注意力。
    static let glassHighlight = dynamic(
        light: rgbA(1.0, 1.0, 1.0, 0.72),
        dark: rgbA(1.0, 0.960, 0.910, 0.17)
    )

    // MARK: - 文本(对齐 web --text-*)

    static let textPrimary = dynamic(
        light: rgb(0.157, 0.137, 0.122),   // #28231F
        dark: rgb(0.953, 0.933, 0.906)     // #F3EEE7
    )
    static let textSecondary = dynamic(
        light: rgb(0.384, 0.353, 0.325),   // #625A53
        dark: rgb(0.780, 0.745, 0.706)     // #C7BEB4
    )
    static let textTertiary = dynamic(
        light: rgb(0.478, 0.443, 0.408),
        dark: rgb(0.659, 0.620, 0.580)
    )
    static let textMuted = dynamic(
        light: rgb(0.545, 0.510, 0.475),   // #8B8279
        dark: rgb(0.584, 0.545, 0.506)     // #958B81
    )
    // MARK: - 语义色(对齐 web --success/--warning/--danger/--info)

    static let success = Color(red: 0.310, green: 0.478, blue: 0.345)       // #4F7A58
    static let warning = Color(red: 0.663, green: 0.416, blue: 0.184)       // #A96A2F

    static let danger = Color(red: 0.698, green: 0.310, blue: 0.271)        // #B24F45

    static let info = Color(red: 0.290, green: 0.435, blue: 0.647)          // #4A6FA5
    static let infoMuted = rgbA(0.290, 0.435, 0.647, 0.14)

    // MARK: - 圆角(对齐 web --radius-*)

    enum Radius {
        static let md: CGFloat = 14
        static let lg: CGFloat = 20
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

    // MARK: - WKWebView 兜底底色

    /// WKWebView overscroll 区域底色,避免加载前/回弹时露出白底。
    static var nsBackground: NSColor {
        dynamicNS(light: rgb(0.961, 0.953, 0.933), dark: rgb(0.075, 0.067, 0.059))
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
    /// 挂原生 Liquid Glass；旧系统和辅助功能模式使用实色描边表面。
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
}

struct WandAmbientBackground: View {
    var body: some View {
        GeometryReader { proxy in
            let canvas = max(proxy.size.width, proxy.size.height)
            ZStack {
                Theme.background
                // 极淡的环境光给扁平实色面板留一丝暖色基调，不做环境呼吸动画：
                // 这块背景会始终存在于高频生产力界面中，安静比显眼更重要。
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Theme.wandAccent.opacity(0.06), Theme.wandAccent.opacity(0)],
                            center: .center,
                            startRadius: 0,
                            endRadius: canvas * 0.48
                        )
                    )
                    .frame(width: canvas * 1.18, height: canvas * 1.18)
                    .offset(x: -proxy.size.width * 0.37, y: -proxy.size.height * 0.46)
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Theme.codex.opacity(0.04), Theme.codex.opacity(0)],
                            center: .center,
                            startRadius: 0,
                            endRadius: canvas * 0.37
                        )
                    )
                    .frame(width: canvas * 0.90, height: canvas * 0.90)
                    .offset(x: proxy.size.width * 0.43, y: -proxy.size.height * 0.12)
                LinearGradient(
                    colors: [Color.white.opacity(0.04), .clear, Color.black.opacity(0.018)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
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

        // 扁平实色表面：chrome 顶栏完全不透明，panel 接近不透明；统一暖色细描边。
        // 高对比度下描边加粗；reduceTransparency 与普通路径一致(本就是实色)。
        let fillOpacity: Double = kind == .chrome ? 1.0 : 0.92
        content
            .background(shape.fill(Theme.surfaceElevated.opacity(fillOpacity)))
            .overlay(
                shape.stroke(
                    Theme.border,
                    lineWidth: highContrast ? 1.5 : 0.8
                )
            )
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

        // 扁平卡片：实色 elevated 表面 + 暖色细描边 + 极轻阴影表达浮起,
        // 不再使用 thin material / glassEffect。
        content
            .background(shape.fill(Theme.surfaceElevated))
            .overlay(
                shape.stroke(
                    Theme.border,
                    lineWidth: highContrast ? 1.5 : 0.8
                )
            )
            .shadow(color: Theme.ShadowToken.md.color.opacity(0.5), radius: 8, y: 3)
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
            if isSelected { return Theme.wandAccent.opacity(highContrast ? 0.20 : 0.13) }
            if isHovered { return Theme.surfaceElevated.opacity(reduceTransparency ? 1 : 0.76) }
            return .clear
        }()

        content
            .background(shape.fill(fill))
            .overlay(
                shape.stroke(
                    isSelected
                        ? Theme.wandAccent.opacity(highContrast ? 0.9 : 0.48)
                        : Color(nsColor: Theme.borderSubtle).opacity(isHovered ? 1 : 0),
                    lineWidth: isSelected || highContrast && isHovered ? 1 : 0.5
                )
            )
            .shadow(
                color: isSelected && !highContrast ? Theme.wandAccent.opacity(0.10) : .clear,
                radius: 8,
                y: 3
            )
    }
}

// MARK: - 兼容旧 API

extension View {
    func dismissKeyboardOnTap() -> some View {
        onTapGesture {
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
    }

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

    /// 挂载后整块 view 都变成可拖动区,拖动时通过 NSWindow.setFrameOrigin 移动窗口。
    /// 配合 hideNativeTitleBar() 一起用:原生标题栏关掉后,这个修饰符给用户提供替代拖拽入口。
    func windowDrag() -> some View {
        modifier(WindowDragModifier())
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
                        : Theme.surface.opacity(focused ? 0.98 : 0.86)
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
    }
}

/// SwiftUI 版 window drag:用 DragGesture 拿到 cumulative translation,
/// 再找到当前 NSWindow 改 frame.origin;比 NSView mouseDown 拦截更可靠——
/// 不会被 HStack 子视图抢事件,只要挂的层级有 contentShape(Rectangle()) 就生效。
private struct WindowDragModifier: ViewModifier {
    @State private var dragOrigin: CGPoint?
    func body(content: Content) -> some View {
        content.gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    // sheet 是个独立 NSWindow(由 SwiftUI 创建),不在 NSApp.keyWindow 上。
                    // 走「最后一个有 sheet 的 window」的启发式;SwiftUI sheet 是最后一个
                    // opened sheet,直接拿 NSApp.windows.last 通常就是它。
                    guard let window = WindowDragModifier.targetWindow() else { return }
                    if dragOrigin == nil {
                        dragOrigin = window.frame.origin
                    }
                    let start = dragOrigin ?? window.frame.origin
                    let newOrigin = CGPoint(
                        x: start.x + value.translation.width,
                        y: start.y - value.translation.height
                    )
                    window.setFrameOrigin(newOrigin)
                }
                .onEnded { _ in
                    dragOrigin = nil
                }
        )
    }

    /// 找当前 SwiftUI 弹窗对应的 NSWindow:sheet 是 attachedSheet 类型,普通 window
    /// 走 keyWindow;两个都取不到就退到 mainWindow。
    private static func targetWindow() -> NSWindow? {
        for w in NSApp.windows.reversed() {
            if w.isKind(of: NSWindow.self) && !w.isMainWindow {
                // sheet 是 attached sheet(通过 -[NSWindow beginSheet:]),SwiftUI 里
                // 走 NSPanel style 也有可能,这里按 attachedSheet != nil 判定
                if w.sheetParent != nil || w.styleMask.contains(.titled) {
                    return w
                }
            }
        }
        return NSApp.keyWindow ?? NSApp.mainWindow
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
            window.isMovableByWindowBackground = true
        }
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

        var body: some View {
            configuration.label
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
                .padding(.vertical, 11)
                .padding(.horizontal, 18)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isEnabled ? Theme.wandAccent : Theme.wandAccent.opacity(0.45))
                )
                .brightness(configuration.isPressed ? -0.06 : 0)
                .shadow(
                    color: isEnabled && !configuration.isPressed ? Theme.wandAccent.opacity(0.16) : .clear,
                    radius: 8,
                    y: 3
                )
                .contentShape(Rectangle())
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

        var body: some View {
            configuration.label
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(Theme.textPrimary)
                .padding(.vertical, 11)
                .padding(.horizontal, 18)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Theme.surfaceElevated)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Theme.border, lineWidth: 1)
                )
                .opacity(configuration.isPressed ? 0.78 : 1)
                .contentShape(Rectangle())
        }
    }
}

/// 工具栏和面板标题里的图标按钮。按下时立即出现像玻璃受压后的暖色高光；
/// 高频操作的反馈只发生在按住期间，不引入切换页或延迟。
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

        var body: some View {
            configuration.label
                .foregroundColor(
                    isActive
                        ? Theme.wandAccent
                        : (isEnabled ? Theme.textSecondary : Theme.textMuted)
                )
                .frame(width: 30, height: 30)
                .background(
                    Circle()
                        .fill(
                            configuration.isPressed
                                ? Theme.wandAccent.opacity(0.17)
                                : (isActive ? Theme.wandAccent.opacity(0.10) : .clear)
                        )
                )
                .overlay(
                    Circle()
                        .stroke(
                            configuration.isPressed ? Theme.wandAccent.opacity(0.36) : .clear,
                            lineWidth: 0.7
                        )
                )
                .contentShape(Circle())
        }
    }
}

/// 复用的品牌 logo:克制的品牌色圆角方块 + 魔杖图标。
struct WandBrandMark: View {
    var size: CGFloat = 64

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(Theme.wandAccent)
                .frame(width: size, height: size)
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                        .stroke(Color.white.opacity(0.18), lineWidth: 0.7)
                )
                .shadow(color: Theme.wandAccent.opacity(0.10), radius: 1, y: 1)
            Image(systemName: "wand.and.stars")
                .font(.system(size: size * 0.46, weight: .medium))
                .foregroundColor(.white)
        }
    }
}
