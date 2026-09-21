---
version: alpha
name: Wand for Mac
description: A focused native AI workspace with quiet navigation, readable conversations, and discoverable project tools
colors:
  primary: "rgb(77.3%, 39.6%, 23.9%)"
  primary-dark: "rgb(83.1%, 45.9%, 31.4%)"
  background: "rgb(95.3%, 95.3%, 94.9%)"
  background-dark: "rgb(9%, 9%, 8.6%)"
  sidebar: "rgb(94.1%, 94.1%, 93.7%)"
  sidebar-dark: "rgb(11.8%, 11.8%, 11.4%)"
  workspace: "rgb(99.2%, 99.2%, 98.8%)"
  workspace-dark: "rgb(7.5%, 7.5%, 7.3%)"
  surface: "rgba(97.6%, 97.6%, 97.3%, 0.94)"
  surface-dark: "rgba(14.5%, 14.5%, 14.1%, 0.94)"
  elevated: "rgb(100%, 100%, 99.6%)"
  elevated-dark: "rgb(13.7%, 13.7%, 13.3%)"
  foreground: "rgb(12.5%, 12.5%, 11.8%)"
  foreground-dark: "rgb(94.1%, 94.1%, 92.5%)"
  secondary: "rgb(36.5%, 36.5%, 34.9%)"
  secondary-dark: "rgb(74.5%, 74.5%, 72.2%)"
  border: "rgb(85.5%, 85.5%, 84.3%)"
  border-dark: "rgb(23.5%, 23.5%, 22.4%)"
  success: "rgb(31%, 47.8%, 34.5%)"
  warning: "rgb(66.3%, 41.6%, 18.4%)"
  danger: "rgb(69.8%, 31%, 27.1%)"
  info: "rgb(29%, 43.5%, 64.7%)"
typography:
  sans:
    fontFamily: '-apple-system, BlinkMacSystemFont, "PingFang SC", sans-serif'
  mono:
    fontFamily: '"SF Mono", Menlo, monospace'
rounded:
  control: "8px"
  md: "10px"
  lg: "12px"
omitted:
  - section: spacing
    reason: "SwiftUI views own native point geometry; the measured layout contract is recorded below."
  - section: components
    reason: "Theme.swift owns component rendering and state behavior; this document maps those owners rather than generating replacements."
---

# Wand macOS 设计规范

## Overview

Wand for Mac 服务于需要持续跟进 AI 会话、项目、终端和任务的使用者。它是高频桌面工具，
主要流程是找到上下文、开始工作、阅读过程、确认结果。当前产品语言为简体中文；工具、模型、
路径、代码和用户输入保留原文。没有由本次需求确认的日本市场或监管业务要求。

用户指定 ChatGPT 桌面客户端作为交互参考：安静的侧栏、以对话为中心的正文、清晰的输入区、
随时可达的搜索与设置。参考的是信息层级、桌面键盘习惯和克制的反馈；Wand 的工作空间、
终端和权限行为由自己的协议与业务模型决定，不复制其他产品的标识或无关功能。

原有 `Theme.swift` 已采用中性灰壳、近白工作区与少量珊瑚色动作。本次延续这套原生体系，
不把父仓库的 Web 暖纸色布局规范直接覆盖到 SwiftUI。Wand 像素猫标记只出现在欢迎、连接和
关于等识别位置；高频内容不重复放大品牌图案。界面不采用营销大标题、装饰性指标或全屏动态背景。

Token ownership 使用 Model B：`Wand/Theme.swift` 是原生颜色和共享外观的唯一运行时所有者。
本文件百分比颜色精确镜像源码 sRGB 小数，不另行生成 CSS 或 Swift 常量。
`Theme.LayoutMetrics` 位于 `Wand/MainShellView.swift`，拥有原生侧栏与检查器宽度。
Web 工具页面仍使用服务端自己的样式与行为契约，原生主题仅管理容器和背景。

## Colors

窗口、侧栏、工作区和浮层按信息角色区分；浅色与深色保留相同结构。
`wand.appearanceMode` 的 `system`、`light`、`dark` 由 `ContentView` 统一应用。
品牌珊瑚色用于主动作、关键图标与输入焦点，不作为所有分区的大面积底色。

| 文档角色 | 运行时所有者 | 主要使用位置 |
|---|---|---|
| primary / primary-dark | `Theme.wandAccent`，兼容别名 `brand` | 主按钮、焦点、引导步骤 |
| background / sidebar / workspace | 同名 `Theme` 背景属性 | 窗口、左侧导航、正文 |
| surface / elevated | `Theme.surface` / `surfaceElevated` | 输入、轻量分组、弹窗 |
| foreground / secondary | `Theme.textPrimary` / `textSecondary` | 标题、正文、辅助说明 |
| border | `Theme.border` | 细分隔线、输入边缘、分组 |
| success / warning / danger / info | 同名 `Theme` 属性 | 执行结果、等待、错误、信息 |

每个状态同时使用文字或图标，不能只靠颜色。选中行使用低透明度前景色底，避免和错误、警告混淆。
高对比度模式由共享输入和面板修饰符加粗描边；终端与代码保持自己的内容配色。
对比度需要在真实浅色、深色和提高对比度模式下检查；token 一致不等于可访问性已通过。

## Typography

使用系统字体，SwiftUI `.system` 负责原生中文回退与字体度量；路径、命令、版本、快捷键使用
`.monospaced`。不引入网络字体。常见侧栏与表单为 12–14 pt，辅助说明 11–12 pt，
设置标题 22 pt，使用指南标题 25 pt，连接欢迎标题 30 pt。标题使用 semibold；正文保持 regular。

标题通过字号、字重和间距建立层级，不能把所有标签加粗。中文说明允许换行，技术路径按需要
保留尾部或中间截断，并通过 help、可选文本或详情提供完整值。关键错误与主动作不得只靠截断文本表达。

## Layout

主窗口最小 900 × 600 pt，初始理想尺寸 1440 × 880 pt，可继续放大。
内容延伸到系统标题栏区域，交通灯旁保留安全距离与可拖拽空白。
左侧栏由 `SessionSidebarView.swift` 承载，主壳负责组合与路由。
左侧栏 272 pt，常驻检查器 320 pt；窗口宽度达到 1220 pt 才使用常驻右栏，
较窄时按需浮出。隐藏侧栏时仍提供恢复按钮和菜单快捷键。

聊天保持共同阅读轴，标题、消息与输入属于同一上下文；用户读历史时停止自动跟随，并提供回到最新。
工作空间及任务保持列表与详情关系。设置采用侧栏加独立滚动详情；使用指南采用步骤侧栏、
可滚动正文与固定底部动作。连接页在 860 pt 以下使用单栏，并允许最近连接和帮助说明整体滚动。

弹窗必须在最小窗口、全屏和缩放显示器上验证。正文可以滚动，关闭和提交按钮必须一直可达。
只给正文加 ScrollView 并不能解决整个 sheet 的固定高度超出显示区域的问题；
最终几何以 `UX-CONTRACT.md` 的验证要求与真实运行截图为准。

## Elevation & Depth

扁平表面与细边框建立主层级。`wandGlass` 与 `wandGlassCard` 是保留的兼容名称；
当前实现使用接近不透明或实色表面，不能因为命名就再叠加模糊材质。
侧栏、消息列表、设置分组不添加多层悬浮阴影。焦点输入可使用共享修饰符的轻微投影，
系统菜单和 sheet 使用系统呈现方式。

## Shapes

按钮共享样式为 8 pt 圆角，`Theme.Radius.md` 为 10 pt，`lg` 为 12 pt。
快捷键键帽为小圆角矩形；图标按钮使用 30 × 30 pt 命中区。
步骤进度与少量状态图标可以使用圆形，普通行、卡片和操作不统一改成胶囊。

## Components

按钮复用 `WandPrimaryButtonStyle`、`WandSecondaryButtonStyle`、`WandIconButtonStyle`；
原生 `Button` 保留键盘与辅助功能语义。主要动作与取消相邻，危险动作在语义和确认文案上明确区分。
异步提交期间禁止重复触发，忙碌状态要保留可辨认的标签与恢复路径。

输入表面统一使用 `wandInputSurface`；有焦点和错误时描边变化。消息编辑器使用原生 NSTextView，
保证中文组合输入、粘贴、撤销与选择行为；终端不复用聊天发送规则。
图标采用 SF Symbols，并以 text label、help 或 accessibilityLabel 补全含义。

`DesktopCommand` 是菜单栏、命令面板和快捷键参考的单一目录；不得在帮助页硬编码第二套快捷键。
命令面板同时检索操作、会话和工作空间。`DesktopWebTool` 是服务端工具目的地的单一目录；
完整控制台与特定设置都经同一 WebView 导航桥接进入。

`DesktopOnboardingView` 提供三步可重复指南，完成状态由壳管理。
连接前可以阅读，但不能执行需要服务器的操作。首次连接帮助解释服务器启动、获取连接码和端口，
不把复制命令误表述为已经启动服务。

结构变化使用约 160 ms 的短促 ease-out / ease-in-out；高频列表选择即时发生，
不添加连续跳动、装饰性弹簧或长时间阻止输入的过渡。开启 Reduce Motion 时取消相关空间动画。
这是参考桌面产品节奏后延续现有原生反馈的选择，不承诺重现某个参考 App 的内部动画参数。

中文文案使用直接动词，例如「新建会话」「连接」「打开服务端设置」「回到最新」。
失败消息说明当前问题并提供重试、诊断或重新连接入口。通知设置必须区分 Web 提示与 macOS 系统通知，
不能将服务端 Web 权限视为原生系统授权。

## Do's and Don'ts

- 保持当前会话、目录和服务器上下文清晰，切换功能使用共享命令与目的地目录。
- 新增偏好明确本机或服务器范围；原生设置不复制服务端校验与管理员权限逻辑。
- 为键盘、中文输入法、减弱动态和深色模式保留真实交互验证。
- 不把内嵌 Web 工具描述为全部原生实现，不将静态审计当作完整功能或无障碍证明。
- 不为单个页面重写 `Theme`，不让父仓库 Web 文档成为第二套原生 token 所有者。

当前有意保留的差异：原生 Theme 的中性工作区、10/12 pt 分组圆角和原生菜单几何
与父仓库 Web 的暖纸色、12/16 px 容器不同。本文件记录该平台边界；它不是静默修改 Web 设计规范。
