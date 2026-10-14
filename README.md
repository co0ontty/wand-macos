# macOS 客户端

Wand 的原生 SwiftUI / AppKit 桌面客户端。可收起的连续侧栏、专注阅读区、
按需文件与 Git 检查器，配合原生命令面板和操作快捷键。交互参考 ChatGPT 桌面端，
核心流程围绕七种 CLI 工具、聊天、PTY、工作任务和工作树展开。已有会话按实际 engine 区分 Pi CLI 与 Wand Agent，不把 SDK 执行标成 Pi；员工/团队会话保留服务端身份标记。

视觉延续 Web 登录页的暖纸底色、墨色文字与赤陶主动作。连接、聊天、任务、文件、Git 和设置
共用输入、按钮与轻量分组；悬停与焦点反馈为 120 ms，手动面板展开为 180 ms，遵循 Reduce Motion。
聊天内容与状态文字保持静态，流式消息不添加列表入场动效。

首页、会话、工作空间、任务看板、员工通讯录与对话共用主窗口。输入框底部按需配置工具、模型、目录与任务归属；
设置保留外观、会话内容宽度、发送方式、连接、系统权限、故障排查和客户端更新。
「设置 → 通用 → 会话内容宽度」可选铺满/居中：默认铺满可用区域，居中保留 840pt 阅读栏。
结构化会话、工作区会话和私聊/群聊的正文与输入区同步生效；窄窗口自动适应，偏好只保存在这台 Mac，终端不受影响。
原生附加的并行任务/收件箱、网页工具目录、完整控制台包装层、入门页与快捷键说明页已移除；
服务端与 Web 的功能及已有数据保持原状。

侧栏沿用 Web 的「执行会话」入口与紧凑层级，用原生分段控件切换「按工作区 / 最近会话」。
按工作区：上方工作区 → 任务 → 任务会话，下方单独会话和旧服务器可恢复历史，共用一个滚动区域。
有任务的目录首次发现自动展开；手动收起后刷新不重新展开，选择任务会定位对应路径。
最近会话：任务内和单独会话合并，按员工 / 团队 / PTY 终端 / 空白终端 / CLI 的稳定身份分组，
不截断条目，点击任务内会话仍打开其真实任务。合成目录 ID 只用于展示，执行绑定使用任务的真实 workspaceId。
「活动」只筛选在跑、待处理、刚完成与当前查看的会话，不把常驻但空闲的 provider 当作正在执行。
搜索按钮原位展开并聚焦，返回按钮或 Escape 收起；支持跨工作区、任务、会话与身份信息的多词查询，
任务命中保留完整子会话及管理动作范围。筛选暂时展开，清除后恢复；列表选项提供刷新与新建工作区。
工作区标题的加号新建任务；目录和任务内的加号仍带入对应上下文与默认值。组织方式和活动筛选仅存在本机。

## 桌面快捷键

| 操作 | 快捷键 |
| --- | --- |
| 新建会话 / 工作任务 | ⌘N / ⇧⌘N |
| 搜索与命令 | ⇧⌘P |
| 定位单独会话 / 定位工作空间 / 打开看板 | ⌘1 / ⌘2 / ⌘3 |
| 员工对话 / 通讯录 | ⌘4 / ⌘5 |
| 显示侧栏 / 检查器 | ⌃⌘S / ⌥⌘I |
| 聚焦输入 / 查找对话 | ⌘L / ⌘F |
| 设置 / 切换服务器 | ⌘, / ⇧⌘, |
| 刷新连接 | ⇧⌘R |

⌘1 / ⌘2 显示侧栏并定位下方 / 上方分区，保留主内容区当前打开的任务或会话。
操作快捷键由 `DesktopCommand` 统一提供给系统菜单和命令面板。Return 默认发送，Shift-Return
换行；设置中可改为 Command-Return 发送。中文输入法选词不提交；候选经 AppKit `insertText` 确认后同步结束组字状态，恢复鼠标发送门禁；PTY 保留终端按键行为。
草稿只在本次 App 运行期间按服务器和会话恢复，不承诺退出后恢复。
结构化聊天的发送/停止圆钮位置固定：收起时独立在胶囊右侧，展开时输入框外框延伸包住圆钮，
按钮位于输入框内，展开与收起不改变位置或尺寸；空闲无正文/附件时隐藏，
有内容时发送，运行中始终显示停止（不因新草稿切回发送），点击停止仍需确认。发送中的重复提交、
中文组字与附件上传沿用原有门禁；Return / Command-Return 的排队发送行为不变。
首页发送由 Shell 保留的创建草稿持有：带首条消息的新会话请求接受后立即返回，AI 执行继续走实时事件。
任务/会话的真实创建回执先加入本地列表并打开新会话，不等待列表刷新或默认配置保存；旧刷新结果不覆盖
新条目，期间的失效会补一次新读取。启动被明确拒绝时保留草稿和已创建任务，重试复用任务；离开创建页后
迟到回执只更新列表，不抢回页面，也不清除后来输入。网络超时、成功回包解析失败及5xx/408/409
视为创建结果未知：刷新列表核对，不自动猜会话或重发；只有用户明确确认未创建后才解除重试门禁。

## 约定

- 工程代码放在 `macos/Wand/`
- `.app` 与 `.dmg` 构建产物**不要提交到仓库**（已在 `.gitignore`）
- Stable 更新查询官方 GitHub Release；Beta 更新只查询当前连接服务端的本地 macOS 更新包，不回退 GitHub
- 原生界面与 iOS 共用协议模型：会话列表、新建会话、聊天、权限审批、恢复与快捷提交

## 原生客户端协议

- 登录：`POST /api/login` 获取 session cookie
- 会话：`GET /api/sessions`、`GET /api/sessions/:id?format=chat`
- 新建：`POST /api/structured-sessions` 或 `POST /api/commands`
- 输入与权限：`POST /api/sessions/:id/input` 及 escalation / permission 端点
- 实时更新：连接 `/ws`，订阅会话并合并 `init` / `output` / `status` / `ended`
- PTY：SwiftTerm AppKit 原生终端直接发送 `pty_input` / `pty_resize` / `pty_ack`，不加载网页
- 终端快捷键：⌘L 聚焦、⌘F 查找回滚、⌘± 缩放、⌘0 重置、⌘K 仅清除本地回滚历史

## 原生员工与对话

- 通讯录读取员工身份、职责、标签和候选，资料原位展开；不读取知识端点，也不投影/缓存角色提示词。
- 私聊固定为服务端 `dm_<employeeId>`，打开空白私聊只读详情，不反复创建执行会话。每条新消息是独立执行；跟进原工作从该条 `sessionLink` 打开现有 ChatView，不猜最新任务或旧沟通通道。
- 对话/群聊使用 `/api/conversations` 的列表、详情、messages、channel、invitations、actions 与 requests 回执。建群/邀请只改元数据，不自动开工；群沟通不自动跟随任务，选择明确 taskId/runId 才跟进。@ 插入精确成员 ID，避免同名误派。
- 同一 `server + conversation + target` 的输入/附件/revision/发送归 `ConversationComposerState`，UI 只投影；草稿只在 App 内存保留。已提交正文不持久化；未知请求只存 ID/指纹/归属，核对 404 不能当未接受，也不自动重发。
- 202 接受与启动成功不同；startup failed 保留“已接受但执行异常”，不能当未发送恢复。迟到读取/上传/ACK 不覆盖新会话或新输入，明确拒收合并恢复，用户清除阻止复活。
- 消息/Markdown/工具复用 TurnView，输入复用 IMEAwareComposerTextView；只读消息里的工具交互禁用，需打开精确执行会话处理。⌘F 原位查找已加载正文、工具输出与预览，⌘L 聚焦输入；通讯页面不提供不相关的文件检查器。
- 群创建、邀请、原会话链接、选定轮次沟通与审批/停止/明确 +10 步入口已接入。员工 CRUD、团队模板/直接开工、群解散/删除管理、统一看板派发与完整设置仍待补齐。应用不为验证隐式调用真实付费模型。

协议样本：父仓 `tests/fixtures/native-communications.json` 与子仓 `WandTests/Fixtures/communications.json` 在检出时比对。`CommunicationsTests` 用独立偏好/假服务覆盖状态，`CommunicationsVisualTests` 复用真实原生编辑和组件；`WAND_COMMUNICATIONS_LIVE=1` 开启安装服务元数据验收（仅自身默认员工、临时群与空输入拒收，清理本次创建的精确记录）。真实模型执行和完整安装客户端鼠标/升级必须另获授权，不以截图或条件跳过冒称通过。

## 本地构建（仅 macOS）

```bash
./build.sh 1.16.0
# 产物：build/Wand.app + ZIP + DMG + wand-v1.16.0.update.json
# 隔离验收可设置 WAND_BUILD_DIR / WAND_DIST_DIR（尚不存在的绝对路径），保留已有产物。
```

单测：`xcodebuild test` 在 testmanagerd 不可达的环境会失败，此时用
`./scripts/run-tests.sh [测试名过滤]`（先 `build-for-testing`，再把本次测试 bundle 注入隔离宿主 App 运行 XCTest）。
`DERIVED_DATA` 可指定派生数据目录；构建失败立即退出，不搜旧产物。测试宿主不挂载生产主壳、不连接用户服务器或触碰真实更新缓存。

协议增量以服务端为事实源：父仓 `tests/fixtures/native-session-identity.json` 与本子仓独立可测试的 `WandTests/Fixtures/session-identity.json` 镜像由 Swift 的 `ProviderCatalogTests` 和父仓 `tests/macos-session-contract.test.ts` 校验 provider、实际 engine、员工与团队身份。父仓测试在镜像检出时断言两份完全一致，服务端单独检出不依赖初始化原生子模块。新增身份字段/执行工具时同步此契约；这不是 SwiftUI/React 界面代码的自动双向同步。原生通讯录与私聊/群聊纵切已接入下述通讯协议；AI 团队管理、看板统一派发与完整 AI 设置仍需独立纵切，不能把通讯入口当作全部功能对齐。

要求：

- macOS 12+
- 安装完整 Xcode（仅 Command Line Tools 不足以构建）；系统新材质需要 Xcode 26+
- 不需要 Apple Developer 账号（ad-hoc 自签名）
- SwiftTerm 含 Metal shader，Xcode 26+ 首次构建需下载官方 Metal Toolchain；build/debug 脚本自动检查，直接 xcodebuild 前运行 `bash scripts/ensure-metal-toolchain.sh`

## 部署 macOS 包供更新

服务端通过 `config.macos.dmgDir`（相对于 config 目录）查找 ZIP / DMG。原生 Beta
优先使用同版本 ZIP、缺 ZIP 时使用 DMG；按 Wand 安装版本顺序选最新。旧版 DMG 下载接口仍保留。

| 环境 | Config 目录 | DMG 目录 | 端口 |
|------|------------|---------|------|
| 生产 | `~/.wand/` | `~/.wand/macos/` | 8443 |
| 开发 | `/tmp/wand-dev/` | `/tmp/wand-dev/macos/` | 9443 |

文件名必须包含语义化版本号（如 `wand-v1.16.0.dmg`），服务端正则 `(\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.-]+)?)` 抽取版本号。

## DMG 下载来源优先级

1. 本地文件（`dmgDir` 中最新的 `.dmg`）→ `source: "local"`
2. GitHub Release 回退 → `source: "github"`

设置页面会显示来源标签（本地/线上），等同 Android APK 的逻辑。

## 签名

ad-hoc 签名（`codesign --sign -`），等同 Android 的自签名 keystore。**用户首次打开 Wand.app 时：**

> 右键 → 打开 → 在系统弹"无法验证开发者"时点"打开"。之后双击即可正常使用。

也可以在终端跑：

```bash
xattr -dr com.apple.quarantine /Applications/Wand.app
```

去掉 quarantine 标签。

**不要换签名身份。**一旦换了，已安装的旧版升级时会被 macOS 拒绝（"签名变化"）。当前签名是 ad-hoc，不需要 Apple Developer 账号。

## 本地网络权限（macOS 15+）

macOS 15 (Sequoia) 起，原生 URLSession 直连局域网 IP 需要用户授权「本地网络」权限；未授权时连接会**静默超时**（旧 WebView 壳不受影响——WKWebView 流量豁免该权限，TN3179）。系统设置的「本地网络」列表**没有手动添加入口**，应用必须自己触发一次本地网络访问才会出现在列表里。

应对（`LocalNetworkPermission.swift`）：

1. **启动时主动触发授权弹窗**——TN3179 官方技巧：应用完成启动后 UDP connect 到私有 IPv4 地址的 9 端口，不产生真实流量，且避免无 scope 的 IPv6 link-local 地址在进入权限检查前直接失败。
2. **被拒检测**——NWBrowser 浏览 Bonjour 服务，被拒时进入 `.waiting(.dns(-65570 PolicyDenied))`；首次 start 可能误报 `.ready`，所以探测跑两轮以第二轮为准。ConnectView 在「网络失败 + 目标像局域网地址」时探测并展示引导卡片。
3. **设置深链**——`x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork`（含回退链）。设置页与会话列表加载失败处都有入口。

用户侧已知坑（均为系统行为）：

- 弹窗只出现在「未决定」状态；**Wand.app 不在 /Applications 里时弹窗可能永远不出现**（FB16077972）。
- ad-hoc 签名的 designated requirement 随二进制 cdhash 变化，系统跟踪应用身份不稳定：**即使原位更新，授权也可能丢失**。新版启动时会主动触发系统申请，并探测 PolicyDenied；已拒绝时 macOS 不允许应用再次弹申请，Wand 会显示前往「本地网络」系统设置的按钮。若要保证授权始终连续，仍需稳定的 Developer ID 签名身份（当前构建环境无此证书）。
- **重启 Mac 后授权偶尔失效**（开关显示打开但实际被拒，FB16512666）：在设置里把 Wand 的开关关掉再打开即可恢复；macOS 15.6+ 已修部分场景。
- macOS 上**没有**重置本地网络权限状态的官方手段（TN3179 明确说明，`tccutil` 管不到它）。

## 更新

客户端启动 3 秒后检查所选更新源；成功检查后 24 小时防抖，失败不写检查时间。
应用菜单和原生设置均可强制检查。下载/准备期间不重复检查或启动安装；取消、切换通道/服务器或断开连接撤销旧下载事务，迟到结果不能创建待安装包。已校验的待重启事务保持独立，不被检查/通道切换覆盖。更新通道是本机偏好，不跟随当前连接服务的 Web 更新通道：

- Stable：只使用官方 GitHub 稳定 Release。
- Beta：**只使用当前连接的 Wand 服务端** `macos.dmgDir` 中本地 ZIP/DMG，绝不回退 GitHub；切换服务器会重新检查。`X.Y.Z-debug.*` 按 Wand 安装顺序视为同版本正式版之后的构建。未连接或服务端未提供包时提示原因。
- 从 Beta 切回 Stable 不自动降级，等待下一个更高的 Stable 版本。

发现新版本后：

1. Stable 只匹配 `wand-v<Release 版本>[+构建时间].zip|dmg`；Beta 从服务端 `/api/macos-app-update?currentVersion=...` 读取版本、固定文件名、大小和 SHA-256，通过 `/macos/update-download?fileName=...` 同源下载。ZIP 优先、DMG 兜底。
2. Stable 新 Release 读取 `.update.json` 校验大小与 SHA-256（旧 Release 兼容签名校验）；Beta 必须验证服务端 SHA-256 和大小，拒绝跨源地址/跳转或 HTTP 错误页。
3. 解包后校验 bundle id、`CFBundleShortVersionString`、主可执行文件与代码签名。
4. 下载完成后写入可恢复事务；选择“稍后”时，设置页会保留“重启完成更新”入口 7 天。
5. helper 备份并替换当前 `Wand.app`，只有新版写入启动确认后才删除备份。
6. 复制、启动或确认失败时 helper 自动恢复旧应用；诊断日志写入 `~/Library/Logs/Wand/update.log`。新版确认启动后重新触发本地网络权限申请，并在检测到已拒绝时引导到系统设置；以后局域网连接失败也会再检测。

因此日常更新不再需要重新挂载 DMG 或拖拽安装。当前 app 所在目录必须可写；若从只读 DMG
直接运行，先将 `Wand.app` 拖到 Applications。Release 同时保留 DMG，供首次安装或自动更新失败时兜底。

当前客户端不再包含 WebView 更新桥。服务端 `/api/macos-dmg-update` 和 `/macos/download`
仍保留，供旧客户端和浏览器手动下载兼容。原位替换沿用相同 bundle id / 安装路径，
无须用户重新拖动安装或重输连接信息；但 ad-hoc 签名下无法保证系统授权不重新弹窗。

## 工程结构

```
macos/Wand/
├── ContentView.swift          # 已连接进入 MainShellView，未连接进入 ConnectView
├── MainShellView.swift        # 主导航、模态路由、稳定阅读区与检查器
├── SessionSidebarView.swift   # 单独会话、旧服务器历史兼容与删除流程
├── DesktopCommands.swift     # 菜单/命令/快捷键共用目录与搜索面板
├── DesktopWelcomeView.swift   # 包装共享首页输入区与导航按钮样式
├── WorkspaceListView.swift    # 工作空间、任务与任务会话分区
├── WorkspaceTaskView.swift    # 任务工作窗口与标签条
├── TaskBoardView.swift        # 看板宿主：视图切换、搜索/筛选/显示、轮询与写操作
├── TaskBoardModels.swift      # 看板状态、筛选、里程碑、日期与统计口径
├── TaskBoardComponents.swift  # 状态图标、胶囊、卡片、会话列表与归档目录
├── TaskBoardBoardView.swift   # 看板列、归档区与拖拽
├── TaskBoardViews.swift       # 概览、列表、甘特图
├── TaskBoardDetailView.swift  # 任务详情：描述、派发与会话列表
├── TaskBoardCreateView.swift  # 新建任务面板
├── TaskBoardPickers.swift     # 里程碑/标签/截止日期/Agent 选择器
├── ChatView.swift             # 原生消息、输入、权限审批与快捷提交入口
├── ChatStore.swift            # REST 快照与 WebSocket 增量状态机
├── CommunicationsModels.swift # 员工、对话、群成员、任务/会话链接与回执 DTO
├── CommunicationsRepository.swift # 只读目录与唯一 mutation receipt ledger
├── CommunicationsComposer.swift # 会话/目标级草稿、revision、提交与未知核对
├── CommunicationsStore.swift  # 请求代次、选择与 API 状态投影
├── CommunicationsViews.swift  # 通讯录、私聊/群聊、原生消息与输入表面
├── NewSessionView.swift       # 首页输入、底部配置入口、默认值与创建草稿
├── GitQuickCommitView.swift   # 原生快捷提交面板
├── MacUpdateManager.swift     # 唯一更新状态源、Stable/Beta、缓存与待重启事务
├── UpdateInstaller.swift      # 下载、校验、原位替换、失败回滚与自动重启
├── WandAPI.swift              # REST 客户端
├── WandSocket.swift           # WebSocket 订阅、重连与 resync
├── WandModels.swift           # 服务端协议 Codable 模型
├── LocalNetworkPermission.swift # macOS 15+ 本地网络权限：触发弹窗/被拒探测/设置深链
├── NativeTerminalView.swift   # SwiftTerm AppKit 终端、中文输入、选区与查找
└── PtyTerminalStore.swift     # PTY 快照回放、输入、ACK、尺寸和权限
```

## 验收环境

功能验收、真机验收与最终端到端验收统一连接这台机器已安装运行的 Wand 服务。
连接信息从 `~/.wand/acceptance-connection.json` 读取，遵循父仓库 `AGENTS.md`；
连接码不得写入仓库、提交、日志或截图。独立环境仅用于单元测试和开发期检查，不能代替最终验收。
此前的桌面和首页截图属于历史记录，不能作为当前连续侧栏的验收证据。
此前连续侧栏验收时指定 HTTPS 入口拒绝连接；原生终端已使用同一私密连接文件指定的服务完成接口与窗口验收。系统剪贴板和完整中文候选交互仍待正常桌面手工复核。

历史验收记录（原生终端、桌面清理、连续侧栏）已随仓库文档整理一并移除；本节与源码是当前约定。
