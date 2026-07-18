import SwiftUI
import AppKit

/// 品牌色与复用样式,对齐 web 端的 :root token(暖米色背景 + 暖珊瑚 accent)。
/// 颜色随系统明暗自适应；液态玻璃抽象在 macOS 26+ 走 SwiftUI 原生 Liquid Glass，
/// 老系统退化为半透明 surface + 暖色描边。
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
    static let wandAccent = Color(red: 0.773, green: 0.396, blue: 0.239)        // #C5653D
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

    // MARK: - 背景层(对齐 web --bg-*)

    /// 主背景:对齐 web --bg-primary 暖米色。暗色下走 web 没明确的暗色(纯 web 是亮色),
    /// 这里在暗色下用暖灰底,保留品牌识别。
    static let background = dynamic(
        light: rgb(0.965, 0.945, 0.910),  // #F6F1E8
        dark: rgb(0.122, 0.106, 0.090)    // #1F1B17
    )

    /// 二级背景,顶栏 / 侧栏 / 输入栏胶囊(对齐 web --bg-secondary)。
    static let surface = dynamic(
        light: rgbA(1.0, 0.984, 0.961, 0.92),     // rgba(255, 251, 245, 0.92)
        dark: rgbA(0.157, 0.137, 0.114, 0.85)      // 暖灰半透
    )

    /// 浮起层背景(对齐 web --bg-elevated)。
    static let surfaceElevated = dynamic(
        light: rgb(1.0, 0.980, 0.949),    // #FFFAF2
        dark: rgb(0.184, 0.165, 0.137)
    )

    // MARK: - 边框(对齐 web --border-*)

    static let borderSubtle = rgbA(0.588, 0.463, 0.333, 0.12)  // rgba(150,118,85,0.12)
    static let borderDefault = rgbA(0.490, 0.357, 0.224, 0.25)  // rgba(125,91,57,0.25)
    static let border = Color(nsColor: dynamicNS(light: borderDefault, dark: borderDefault))
    static let borderFocus = rgbA(0.773, 0.396, 0.239, 0.50)    // rgba(197,101,61,0.5)

    // MARK: - 文本(对齐 web --text-*)

    static let textPrimary = dynamic(
        light: rgb(0.165, 0.122, 0.086),   // #2A1F16
        dark: rgb(0.957, 0.953, 0.933)     // 暖白
    )
    static let textSecondary = dynamic(
        light: rgb(0.353, 0.271, 0.208),   // #5A4535
        dark: rgb(0.792, 0.769, 0.722)
    )
    static let textTertiary = dynamic(
        light: rgb(0.478, 0.388, 0.314),   // #7A6350
        dark: rgb(0.643, 0.580, 0.518)
    )
    static let textMuted = dynamic(
        light: rgb(0.549, 0.451, 0.373),   // #8C735F
        dark: rgb(0.514, 0.451, 0.388)
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

    // MARK: - 液态玻璃抽象

    /// 液态玻璃胶囊:顶栏 / 面板 / 会话头卡片背景。
    /// macOS 26+ 直接使用 SwiftUI Liquid Glass;老系统退化为半透明 surface。
    /// 视图层用 `View.wandGlass(...)` 直接挂即可。
    enum Glass {
        case chrome           // 顶栏 / 工具条(高不透明,放在最顶)
        case panel            // 侧栏 / 输入栏(中等不透明)

        var cornerRadius: CGFloat {
            switch self {
            case .chrome: return 0     // 顶栏贴窗口
            case .panel: return Radius.lg
            }
        }

        @available(macOS 26.0, *)
        var nativeEffect: SwiftUI.Glass {
            switch self {
            case .chrome:
                return .regular.tint(Theme.wandAccent.opacity(0.035))
            case .panel:
                return .regular.tint(Theme.wandAccent.opacity(0.06))
            }
        }
    }

    // MARK: - WKWebView 兜底底色

    /// WKWebView overscroll 区域底色,避免加载前/回弹时露出白底。
    static var nsBackground: NSColor {
        dynamicNS(light: rgb(0.965, 0.945, 0.910), dark: rgb(0.122, 0.106, 0.090))
    }

    // MARK: - 渐变背景(对齐 web body 径向渐变)

    /// 整个窗口的暖色径向渐变底,跟 web body 的多层渐变对齐。
    static var windowGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(nsColor: rgb(0.984, 0.969, 0.945)),  // #FBF7F1
                Color(nsColor: rgb(0.965, 0.945, 0.910))   // #F6F1E8
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

// MARK: - 液态玻璃修饰符

extension View {
    /// 挂原生 Liquid Glass；旧系统仅保留基本半透明背景。
    @ViewBuilder
    func wandGlass(_ kind: Theme.Glass) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(
                kind.nativeEffect,
                in: RoundedRectangle(cornerRadius: kind.cornerRadius, style: .continuous)
            )
        } else {
            self.background(
                RoundedRectangle(cornerRadius: kind.cornerRadius, style: .continuous)
                    .fill(Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: kind.cornerRadius, style: .continuous)
                    .stroke(Color(nsColor: Theme.borderSubtle), lineWidth: 0.5)
            )
        }
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
                color: focused && !highContrast ? Theme.wandAccent.opacity(0.12) : .clear,
                radius: 10,
                y: 4
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
                .opacity(configuration.isPressed ? 0.7 : 1)
                .contentShape(Rectangle())
        }
    }
}

/// 复用的品牌 logo:珊瑚渐变圆角方块 + 魔杖图标。
struct WandBrandMark: View {
    var size: CGFloat = 64

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Theme.wandAccent, Theme.wandAccentStrong],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: size, height: size)
                .shadow(color: Color(nsColor: Theme.wandAccentGlow), radius: size * 0.18, y: size * 0.06)
            Image(systemName: "wand.and.stars")
                .font(.system(size: size * 0.46, weight: .medium))
                .foregroundColor(.white)
        }
    }
}
