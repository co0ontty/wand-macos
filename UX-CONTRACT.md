# Wand macOS 交互契约

## Product context

这是 SwiftUI / AppKit 桌面客户端，最低支持 macOS 12。主要工作包括 AI 会话、PTY 终端、
工作空间任务和服务端工具。界面使用简体中文，时间显示遵循设备区域设置；模型名、代码和路径保留原文。
目标是可用键盘完成核心流程、正确处理中文组合输入，并在浅色、深色和辅助功能设置下保持可读。
无障碍目标参考 WCAG 2.2 AA 的相关原则与 macOS 原生辅助功能语义；尚不能据此声明已完成合规认证。

## Business-context sources

| Domain / scope | Authoritative source | Source type | Reviewed date |
|---|---|---|---|
| PTY、结构化会话、输入与权限 | 父仓库 `AGENTS.md`、`docs/client-logic-analysis.md`、`src/session-transport.ts` | 操作约定与协议实现 | 2026-09-21 |
| 原生 API 和会话数据 | `Wand/WandAPI.swift`、`Wand/WandModels.swift`、`Wand/ChatStore.swift` | 客户端契约实现 | 2026-09-21 |
| 项目、任务与工作窗口 | `Wand/WorkspaceStore.swift`、`Wand/WorkspaceTaskView.swift` | 状态与业务实现 | 2026-09-21 |
| 登录与网络权限 | `Wand/WandAuth.swift`、`Wand/ServerStore.swift`、`Wand/LocalNetworkPermission.swift` | 认证与系统集成 | 2026-09-21 |
| 更新、完整性验证与恢复 | `Wand/MacUpdateManager.swift`、`Wand/UpdateInstaller.swift` | 更新事务实现 | 2026-09-21 |
| 服务端工具授权与表单 | `Wand/DesktopWebToolsView.swift`、父仓库 `src/web-ui/react/settings/` | 导航目录与服务器 UI | 2026-09-21 |

数据删除、权限和会话所有权遵循对应服务端 API。原生界面不能通过模拟页面点击或更改身份来绕过授权。
父仓库 SQLite 迁移只加不删的约定不等于客户端可任意删除用户数据。

## Visual contract

视觉意图与原生 token 映射见 [DESIGN.md](DESIGN.md)。`Wand/Theme.swift` 为运行时所有者，
`ContentView` 应用本机外观模式。父仓库 Web 页面继续使用 Web 主题及行为契约。
变更共享色彩或几何时同时更新运行时所有者、本文相关行为和验证证据。

## Canonical UI Map

| Capability | Canonical owner | Source of truth | Allowed variants | Verification |
|---|---|---|---|---|
| Select/Listbox | SwiftUI Picker/Menu；服务端工具使用原有 Web 控件 | `SettingsView.swift`、`NewSessionView.swift` | 原生设置、模型选择、Web 工具 | 键盘选择、选中值、菜单关闭与重开 |
| Form | SwiftUI 表单加 WandAPI；聊天使用 IMEAwareComposerTextView | API 契约及 `NewSessionView.swift`、`ChatView.swift` | 连接、新建、聊天、服务端 Web 表单 | 校验、中文输入、重复提交、失败保留 |
| Scrollbar | AppKit NSScrollView / SwiftUI ScrollView；Web 保留服务端滚动契约 | 系统滚动偏好及各视图的滚动范围 | 消息、列表、sheet 正文、终端 | 触控板、始终显示滚动条、末尾可达 |
| Toast | 聊天的 ChatStore.toast 与 ChatView.toastView；Web 使用服务端通知层 | `Wand/ChatStore.swift`、`Wand/ChatView.swift` | 聊天轻提示、服务端 Web 提示；其他流程使用既有行内错误或 alert | 发送、复制、失败提示不遮挡主操作 |
| CRUD | WandAPI 与对应 store；Web 工具调用已有页面控制器 | 会话、WorkspaceStore、TaskBoardView.mutate 及服务端契约 | 原生列表详情、内嵌 Web 完整功能 | 创建后进入、编辑后保留上下文、删除确认与失败恢复 |

本次没有新增批量表格选择或日期输入控件，所以未为它们建立平行实现。
原生选择器由操作系统拥有弹出几何与键盘语义，这是桌面产品的明确选择；不能据此豁免标签和焦点检查。

## Navigation and commands

`DesktopCommand` 统一应用菜单、命令面板和快捷键文档，壳使用同一个命令路由处理动作。
帮助菜单在未连接时仍可打开指南和快捷键；需要服务器的操作只能在连接后进入。
`DesktopWebTool` 统一完整控制台、文件编辑、GitHub Issues、连接器及服务端设置目的地。
切换工具保留同一 WebView 的登录和页面上下文；未保存表单阻止离开时，应解释原因并留在当前操作。

快捷键只在 Wand 应用内有效。聊天发送默认 Return，Shift-Return 换行；
`wand.sendWithCommandEnter` 为 true 时 Command-Return 发送、Return 换行。
中文输入法的候选确认不得触发提交。PTY 键盘输入维持终端语义，文本与单独回车包的协议不变。
系统菜单的切换服务器快捷键也遵守弹窗隔离，不能越过文件编辑工具的草稿关闭检查。
Command-F 查找当前已加载的对话，不能声称搜索全部服务器历史；旧消息可先加载再检索。

命令面板展示最近会话、工作空间与操作；查询结果为本次载入的数据集。
加载失败时命令仍可使用，并提供重试；空结果给出修改关键词的方向。
上/下箭头选择，Return 打开，Escape 关闭；中文组合输入时不拦截候选按键。

## Flow ledger

| Operation | Trigger | Pending | Success destination | Success feedback | Failure recovery | Focus outcome | Source ref |
|---|---|---|---|---|---|---|---|
| 连接服务器 | 地址或连接码后「连接」 | 禁止重复提交，显示连接中 | 原生主壳 | 已连接状态、最近记录 | 就地错误、故障排查、本地网络引导 | 失败后输入仍保留 | `ConnectView.swift` |
| 新建会话 | 菜单、侧栏、命令或指南 | 保留创建上下文，避免重复触发 | 新会话 | 会话列表与正文更新 | 表单错误与重试 | 转入新会话 | `NewSessionView.swift` |
| 发送聊天 | 按偏好发送或点击按钮 | 清空已提交草稿并保留恢复副本 | 当前会话 | 新消息、运行或排队状态 | 合并恢复失败提交与其后新输入 | 输入框继续可编辑 | `ChatView.swift`、`ChatStore.swift` |
| 添加附件 | 文件选择、拖入或粘贴图片 | 上传状态和数量限制 | 当前输入草稿 | 可移除的附件预览 | 错误提示，可再次选择 | 留在会话 | `ChatView.swift` |
| 创建工作任务 | 工作空间中的新建入口 | store 拥有请求状态 | 新任务与工作窗口 | 任务组更新 | 保留表单并显示错误 | 新任务上下文 | `WorkspaceTaskView.swift` |
| 编辑或删除看板项 | 看板卡片及详情 | API 请求中禁止重复操作 | 对应看板列 | 刷新后的任务状态 | 错误提示、重试 | 回到看板或详情 | `TaskBoardView.swift` |
| 打开服务端工具 | 工具目录 | 等待页面控制器可用 | 对应功能或设置页 | 原生目的地标签 | 超时、旧服务端不支持、未保存阻挡均可恢复 | 页面拥有后续输入焦点 | `DesktopWebToolsView.swift` |
| 修改本机偏好 | 设置或指南中的选择 | 同步写入 AppStorage | 留在当前界面 | 选中状态即时变化 | 不依赖网络 | 保留当前控件 | `SettingsView.swift` |
| 检查与安装更新 | 应用菜单、设置或后台检查 | 检查、下载、验证、待重启 | 当前应用或新版本 | 版本与待重启状态 | 完整性错误、安装限制、自动恢复 | 更新控制保持可达 | `MacUpdateManager.swift` |

## State, drafts and resilience

服务器数据以 API 与 WebSocket 状态为准，不能在请求失败后显示成功。
每次成功连接都会创建新的进程内连接标识；即使服务器 URL 不变，也重建会话、工作空间和
WebSocket 状态，使它们使用本次连接凭据。该标识不包含凭据，不持久化。
首次加载、空列表、无搜索结果与加载失败应分别表达；已有内容可用时保留它。
重复提交由当前操作的 busy 状态阻止；本契约不额外声称服务端所有写接口都支持幂等。

聊天草稿按服务器 URL 和会话 ID 保存在进程内 `ConversationDraftCache`，包括已上传附件引用。
切换会话可以恢复；退出 App 后不承诺恢复，也不将草稿明文另写到 UserDefaults。
发送失败时合并恢复提交内容和之后的新输入，避免覆盖用户在等待期间继续编辑的文字。
附件已上传不代表已发送，必须保留可移除状态和明确说明。

阅读历史或搜索结果时暂停流式滚动跟随；「回到最新」恢复跟随。切换会话与首次载入后定位末尾。
本机偏好与服务器偏好分开：外观、发送方式、指南版本及客户端更新通道属于本机；
模型、通知、默认目录、安全与 CLI 更新设置属于当前服务器。

服务端工具导航在切换目的地或关闭面板时取消旧导航任务，不让过时结果覆盖新目的地。
等待、失败、旧服务器缺少桥接、未保存表单阻挡均显示明确结果，不静默宣告打开成功。
工具关闭检查遇到脚本异常或未知状态时保留窗口，提供重试与明确的放弃修改确认。
只有明确返回无草稿或明确缺少旧服务器桥接时才直接关闭；保存中继续阻止关闭。

## Overlays, permissions and recovery

使用 SwiftUI sheet、alert、confirmationDialog 和原生菜单。一个操作完成或取消后应回到其发起上下文；
从设置进入指南或工具时先结束原 sheet，避免两个独立模态操作互相竞争。
断开服务器必须确认，并解释重新连接需要凭据；删除和危险操作沿用既有业务确认流程。
普通复制、切换偏好、打开指南等可逆动作不新增确认。

连接码属于认证信息，最近连接只显示解码后的地址，不把 token 写进提示或诊断报告。
「复制启动命令」只复制固定命令，不自动运行服务器。系统本地网络权限诊断不伪造确定授权状态：
只能报告探测结果并提供系统设置或故障排查入口。服务器安全设置继续遵守管理员权限。
Web 通知配置不自动赋予 macOS 系统通知权限。

## Window geometry and accessibility

最低主窗口为 900 × 600 pt。侧栏和检查器都可收起，1220 pt 以下不强制常驻右侧检查器。
内容区承担滚动，长表单及帮助不能把底部动作推到不可达区域。
指南为 790 × 540 pt，快捷键为 520 × 540 pt，已为最低窗口保留垂直余量。
设置最小 700 × 540 pt、理想高度 620 pt；服务端工具最小 880 × 540 pt。
sheet 的理想尺寸并不代表在所有显示器上都能容纳；必须核对实际 sheet chrome、菜单栏和 Dock 可用高度。
连接页在短窗口中整体滚动；设置和指南固定动作区、滚动正文。

键盘检查覆盖 Tab 顺序、Return、Escape、菜单快捷键、命令箭头导航和恢复侧栏。
VoiceOver 检查覆盖图标标签、选中状态、加载与错误、附件数量及输入帮助。
开启 Reduce Motion 后取消新增结构位移；提高对比度时检查共享描边；始终显示滚动条时不得遮挡内容。
中文 IME 的换候选与确认，以及长中文标题、路径、混合中英文和多行输入必须单独验证。

## Verification

静态契约检查使用 frontend-design-premium 的 `audit_project.py`，对 `macos` 单独运行 strict 模式，
通过临时 manifest 指定本文件与原生目录。该审计器只解析 Web 源码后缀，**不会解析 SwiftUI 视图**；
结果仅证明已声明文档与所有者可定位，不能证明本机界面、键盘、CRUD 或无障碍正确。

原生编译与测试使用完整 Xcode：

```bash
xcodebuild -project Wand.xcodeproj -scheme Wand -configuration Debug -destination 'platform=macOS' build
xcodebuild -project Wand.xcodeproj -scheme Wand -destination 'platform=macOS' test
```

需要可分发构建时运行 `./build.sh <版本>`；它构建 Universal Binary 并保留既有签名与更新完整性流程。
仅有 Command Line Tools 时，脚本会在已安装 Xcode 中选择可用版本，不修改全局 xcode-select。
`WandTests` 的现有合同与更新测试用于针对性回归；原生运行检查不能由单元测试代替。

运行验证矩阵包含 1440 × 880 和 900 × 600、全屏、浅色/深色、Reduce Motion、提高对比度、
键盘与中文 IME。必须检查首次连接、指南全部步骤、设置各页、命令面板、消息发送及失败草稿恢复、
历史滚动、附件、PTY 回车、工作空间、任务看板和服务端工具导航。
失败路径至少覆盖连接失败、服务端工具不可达或不支持、上传/发送失败和权限不足。
每次变更记录实际执行结果；本文是要求与实现边界，不是已完成测试的报告。

本次验证边界：原生 UI 自动化环境无法获取 App 与 Chrome 的 CGWindow（`cgWindowNotFound`）。
离屏 NSHostingView 渲染可用于检查真实 SwiftUI 的布局，但不覆盖系统 sheet 几何、焦点、
菜单、中文输入法、网络操作或完整用户流程。这些项目仍需在可交互的 macOS 桌面补验。

## 2026-09-21 实机窗口修正

- 窗口初始几何由 `DesktopWindowGeometry` 负责：1440 × 880 pt，上限为显示器可用区域，
  独立保存尺寸位置并恢复；新几何键使旧版 900 × 600 的隐式默认尺寸不继续影响首次打开。
- 主窗口在 Scene 创建阶段使用 hiddenTitleBar；保留系统菜单、交通灯与窗口管理。
  标题行空白交给所属 NSWindow 原生拖拽，禁止整片正文背景移动窗口；attached sheet 不独立拖离主窗。
- 侧栏设置一点击达；主标题行复用当前会话标题，避免第二条重复标题栏。
  检查器在窄/宽布局之间保留打开状态。
- 401 登录失效使用重新登录入口，打开可取消的连接 sheet，不先断开或清除原会话。
  网络失败保留重试与切换服务器入口；重试成功刷新侧栏列表。
- 切换/重新登录 sheet 的取消支持 Escape，最小高度 540 pt，长内容内部滚动。

- 原生聊天输入的焦点由 `ComposerNSTextView` 的 first responder 回调驱动，
  SwiftUI 只保存状态，不使用未绑定控件的 FocusState。点击与 Command-L 均可聚焦；
  中文粘贴、输入与会话切换草稿恢复需在真实窗口验收。新建会话和快捷提交移除触屏式收键盘手势。
