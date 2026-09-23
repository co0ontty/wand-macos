---
version: alpha
name: Wand for Mac
description: A focused native AI workspace with quiet navigation, readable conversations, and contextual file and Git inspection
colors:
  primary: "rgb(66.3%, 31%, 16.9%)"
  primary-dark: "rgb(87.8%, 60.8%, 47.1%)"
  action: "rgb(72.2%, 33.7%, 18.4%)"
  action-hover: "rgb(61.6%, 27.5%, 13.7%)"
  background: "rgb(98%, 96.9%, 94.9%)"
  background-dark: "rgb(10.2%, 9.4%, 8.6%)"
  sidebar: "rgb(94.9%, 92.9%, 89.8%)"
  sidebar-dark: "rgb(12.5%, 11.4%, 10.2%)"
  workspace: "rgb(98%, 96.9%, 94.9%)"
  workspace-dark: "rgb(10.2%, 9.4%, 8.6%)"
  surface: "rgb(94.9%, 92.9%, 89.8%)"
  surface-dark: "rgb(14.9%, 13.7%, 12.5%)"
  elevated: "rgb(100%, 99.2%, 98%)"
  elevated-dark: "rgb(16.5%, 15.3%, 14.1%)"
  foreground: "rgb(12.2%, 10.6%, 9.4%)"
  foreground-dark: "rgb(95.3%, 92.5%, 88.6%)"
  secondary: "rgb(34.1%, 31.4%, 29%)"
  secondary-dark: "rgb(76.9%, 72.9%, 67.8%)"
  tertiary: "rgb(43.5%, 40%, 36.1%)"
  tertiary-dark: "rgb(69%, 64.7%, 59.2%)"
  border: "rgb(89.8%, 87.1%, 82.7%)"
  border-dark: "rgb(27.5%, 25.1%, 22.4%)"
  success: "rgb(29%, 45.5%, 32.5%)"
  success-dark: "rgb(58%, 74.9%, 60%)"
  warning: "rgb(58.4%, 36.5%, 15.3%)"
  warning-dark: "rgb(87.1%, 69.4%, 43.9%)"
  danger: "rgb(67.8%, 29%, 25.5%)"
  danger-dark: "rgb(89%, 56.5%, 52.5%)"
  info: "rgb(27.5%, 41.6%, 62.4%)"
  info-dark: "rgb(58%, 70.6%, 86.3%)"
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

用户进一步指定已安装 Web 登录页作为全客户端视觉参考。实际观察后统一为暖纸底色、墨色文字、
细分隔线与赤陶主动作；连接页的开放排版延续该参考，工作页面保持原生桌面的阅读密度。Wand 像素猫标记只出现在欢迎、连接和
关于等识别位置；高频内容不重复放大品牌图案。界面不采用营销大标题、装饰性指标或全屏动态背景。

Token ownership 使用 Model B：`Wand/Theme.swift` 是原生颜色和共享外观的唯一运行时所有者。
本文件百分比颜色精确镜像源码 sRGB 小数，不另行生成 CSS 或 Swift 常量。
`Theme.LayoutMetrics` 位于 `Wand/MainShellView.swift`，拥有原生侧栏与检查器宽度。
PTY 终端由 SwiftTerm AppKit 原生视图呈现，直连服务端 WebSocket，保留终端内容配色与 ANSI/TUI 语义。服务端 Web 产品继续独立维护。

## Colors

窗口、侧栏、工作区和浮层按信息角色区分；浅色与深色保留相同结构。
`wand.appearanceMode` 的 `system`、`light`、`dark` 由 `ContentView` 统一应用。
赤陶色用于主动作、关键图标与输入焦点，不作为所有分区的大面积底色。

| 文档角色 | 运行时所有者 | 主要使用位置 |
|---|---|---|
| primary / primary-dark | `Theme.wandAccent`，兼容别名 `brand` | 文字动作、图标、焦点 |
| action / action-hover | `Theme.accentSolid` / `accentSolidHover` | 白字主按钮与发送按钮 |
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
设置与内容页标题 24 pt，连接标题 24 pt，侧栏正文 13 pt、辅助信息 11 pt。标题使用 semibold；正文保持 regular。

标题通过字号、字重和间距建立层级，不能把所有标签加粗。中文说明允许换行，技术路径按需要
保留尾部或中间截断，并通过 help、可选文本或详情提供完整值。关键错误与主动作不得只靠截断文本表达。

## Layout

主窗口最小 900 × 600 pt，首次打开以 1600 × 960 pt 为基准，较大显示器扩展到最多 1920 × 1120 pt；较小屏幕按可用区域缩小，
为菜单栏和 Dock 留出空间。独立保存窗口尺寸与位置，重新打开保留用户调整，并将离屏窗口移回可用显示器。
使用 SwiftUI hiddenTitleBar 在创建窗口时设置外观，不在创建后插入标题栏样式。系统菜单保留原生编辑与窗口管理，将「前往」合并到「显示」菜单的子菜单；
窗口内仅保留一行标题与操作，侧栏可见时不重复显示收起按钮。设置按钮直接打开设置。
侧栏保留新会话、搜索、任务看板三个主动作。这三个动作和下面的树之间留出分段，
不与目录行共用同一种行高。下方用一个滚动容器连续呈现两个分区：
上方为工作空间 → 任务 → 任务会话，下方为「单独会话」及旧服务器的可恢复历史。
两个分区用分段标题和一条分隔线切开。工作空间名是 13pt semibold，左侧有展开钮和文件夹；
展开后的任务、会话落在浅色分组里，并用竖线连到目录。任务标题比目录名再缩进一档，
会话图标与任务标题对齐，会话文字因此再低一档、用次要色。当前行使用淡选中底和左侧短强调线。
运行中的任务会话保留状态点。工作空间/会话的分段切换和原会话/目录模式均已取消；
分区内部不再嵌套滚动或撑满窗口高度。
工作空间标题旁提供新建任务加号，各分区共用上方筛选框。目录默认收起任务层级，让上下分区
容易同时看到；单个目录也保留展开控件。打开已有任务或任务会话时展开对应路径，搜索临时展开，
清除搜索后恢复原展开集合；每 10 秒刷新不能重新展开用户已收起的分组。
侧栏底部只保留连接身份、状态与设置。首页以输入区为中心，主内容只有标题与多行输入框。
工具、模型、目录和归属任务收在输入框底部的低强调小按钮（chips），点击后才展开配置。
权限、思考强度、会话类型归入「更多」popover；任务名称和 worktree 只出现在任务 popover 中。
全局新建、目录加号、任务加号与任务标签加号复用这一输入区，并带入发起位置的上下文。
任务看板也在主内容区显示，保留侧栏导航。
只有标题区域空白可拖动，列表、聊天与表单背景不会拖着整个窗口移动。
内容延伸到系统标题栏区域，交通灯旁保留安全距离与可拖拽空白。
`MainShellView` 拥有侧栏滚动容器与路由，`WorkspaceListView` 和 `SessionSidebarView` 分别承载上、下分区。
任务所有权使用完整任务数据判断，再对各分区筛选；上方不匹配或收起的任务会话不能因此出现在下方。
加载、空结果和错误限制在对应分区内，不以整栏空态遮盖另一个仍可用的分区。
左侧栏 260 pt，常驻检查器 320 pt；窗口宽度达到 1220 pt 才使用常驻右栏，
较窄时按需浮出；调整窗口宽度不会自动关闭已经打开的检查器。隐藏侧栏时仍提供恢复按钮和菜单快捷键。

聊天保持共同阅读轴，标题、消息与输入属于同一上下文；用户读历史时停止自动跟随，并提供回到最新。
工作空间及任务保持列表与详情关系。设置采用侧栏加独立滚动详情，保留外观、消息输入、
连接、系统权限、故障排查和更新。连接页在 860 pt 以下使用单栏，短窗口中整体滚动。

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
图标按钮使用 30 × 30 pt 命中区。
少量状态图标可以使用圆形，普通行、卡片和操作不统一改成胶囊。

## Components

按钮复用 `WandPrimaryButtonStyle`、`WandSendButtonStyle`、`WandSecondaryButtonStyle`、`WandIconButtonStyle`；
原生 `Button` 保留键盘与辅助功能语义。主要动作与取消相邻，危险动作在语义和确认文案上明确区分。
异步提交期间禁止重复触发，忙碌状态要保留可辨认的标签与恢复路径。

输入表面统一使用 `wandInputSurface`；有焦点和错误时描边变化。消息编辑器使用原生 NSTextView，
保证中文组合输入、粘贴、撤销与选择行为；终端不复用聊天发送规则。
图标采用 SF Symbols，并以 text label、help 或 accessibilityLabel 补全含义。

首页由 `DesktopWelcomeView` 包装共享的 `NewSessionView`，后者拥有输入、配置与创建校验。
输入区底部的工具、模型、目录、任务按钮显示当前值，使用中性文字与轻量悬停反馈；
它们是输入框的辅助操作，不做成独立配置卡片、整行表单或醒目的彩色标签。
目录可以缩略显示，完整路径在对应 popover 中可读。启动按钮与这些入口共享输入框底部操作区。

工具、模型、目录与任务各自按需展开。任务 popover 提供「新建任务」「已有任务」「不归属任务」；
选择新建任务后，名称和 worktree 设置仅在该 popover 内出现。权限、思考强度与会话类型放入
「更多」popover，首页默认不铺开这些控件。已有任务使用任务详情返回的实际工作目录。
目录加号预选该目录和工作空间，任务加号预选对应任务；空任务也直接进入同一输入区。

默认值只在初始化时填入，已有草稿中的用户选择保持不变。普通目录按入口上下文、服务端默认目录、
最近目录的顺序回退；工具优先项目默认，其次服务器全局默认。模型按所选工具读取对应默认值，
会话类型、权限模式、思考强度和新任务 worktree 偏好沿用服务器配置。绑定已有任务后以任务详情
实际 cwd 为准，不能用项目根目录覆盖独立 worktree。

`MainShellView` 按首页、目录、工作空间或任务上下文保存进程内 `SessionCreationDraft`。
离开页面再返回继续填写；完成创建后清除对应草稿。异步完成只在原草稿仍为当前页面时进入新会话，
用户已经切换目的地时刷新列表并保留当前页面。等待、错误和重试在输入区或相关配置浮层中表达，
不另开第二步配置窗口。关闭配置 popover 不清空输入或已选值。

最新首页设计以输入区和底部紧凑配置入口为准。此前将全部配置铺开的大表单截图只记录历史状态，
不再作为当前首页的布局参考；新界面的实机验收结果应单独记录。

`DesktopCommand` 是系统菜单与命令面板的单一操作目录，实际快捷键在系统菜单中可见。
命令面板同时检索操作、会话和工作空间。「工作空间」⌘2 与「单独会话」⌘1 显示并定位
同一侧栏的上、下分区，保留主区当前任务或会话；任务看板仍是主内容目的地。
设置通过侧栏底部或应用菜单进入。首页承担开始工作的入口，连接页专注输入连接信息。
旧 `wand.sidebar.section` 与 `wand.sidebar.view-mode` 不再控制或保存侧栏模式。

原生并行任务/收件箱、网页工具目录、完整控制台包装层、入门页和快捷键说明页已移除。
取消功能的入口不能残留在侧栏更多菜单、任务右键菜单、系统菜单、命令面板或设置中。
保留会话、工作树、文件与 Git 检查器的原有能力；此次清理不删除服务端/Web 功能或用户数据。

悬停和焦点使用 `Theme.Motion.feedback` 的 120 ms ease-out；手动面板展开使用
`Theme.Motion.structure` 的 180 ms ease-in-out。共享 `wandMotion(value:layout:)` 尊重 Reduce Motion，
开启后取消这些自定义动画。按钮按下、高频选择与流式消息即时响应。移除聊天状态文字的常驻
30 fps 扫光，不添加循环跳动、装饰性弹簧或页面进入时的整页位移。
这是参考桌面产品节奏后延续现有原生反馈的选择，不承诺重现某个参考 App 的内部动画参数。

中文文案使用直接动词，例如「新建会话」「连接」「打开设置」「回到最新」。
失败消息说明当前问题并提供重试、诊断或重新连接入口。系统权限仅报告实际探测结果，
不能将服务端权限视为本机系统授权。

## Do's and Don'ts

- 保持当前会话、目录和服务器上下文清晰，切换功能使用共享命令与目的地目录。
- 新增偏好明确本机或服务器范围；原生设置不复制服务端校验与管理员权限逻辑。
- 为键盘、中文输入法、减弱动态和深色模式保留真实交互验证。
- PTY 使用 AppKit 原生终端；不得将静态审计当作真实键盘、输入法或无障碍验证。
- 不为单个页面重写 `Theme`，不让父仓库 Web 文档成为第二套原生 token 所有者。

原生 Theme 与 Web 登录页共享暖纸与赤陶的视觉方向；原生的 8/10/12 pt 圆角、菜单几何和键盘
行为仍由 SwiftUI / AppKit 负责。本次仅更新 macOS 运行时与设计契约，不修改 Web 的 token 所有权。

当前功能验收以这台机器已安装运行的 Wand 服务为准，连接信息按父仓库 `AGENTS.md`
从本机私密文件读取。旧指南、工具目录、宽表单和分段侧栏截图仅作历史记录。
附加功能清理结果见 `docs/desktop-cleanup-2026-09-21/verification.md`；连续侧栏检查另记于
`docs/desktop-continuous-sidebar-2026-09-21/verification.md`。本轮指定 HTTPS 入口仍拒绝连接，
不能据编译、单元测试或旧截图宣称真实任务交互已验收通过。

全客户端暖纸视觉、真实参考与本轮实际验证范围见
`docs/desktop-paper-design-2026-09-21/verification.md`；其中明确区分已验证的本地界面与HTTPS故障阻塞的真实会话流程。
