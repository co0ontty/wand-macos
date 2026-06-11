# macOS 客户端

Wand 的 macOS 原生 SwiftUI 客户端。连接后默认进入原生会话列表与聊天界面，
直连 wand 服务端 REST + WebSocket 协议；WKWebView 仅保留为完整网页版兜底入口。

## 约定

- 工程代码放在 `macos/Wand/`
- `.app` 与 `.dmg` 构建产物**不要提交到仓库**（已在 `.gitignore`）
- 设置页里的下载入口指向 wand 运行时配置目录中的 DMG（默认 `~/.wand/macos/`），不是仓库下的产物
- 原生界面与 iOS 共用协议模型：会话列表、新建会话、聊天、权限审批、恢复与快捷提交

## 原生客户端协议

- 登录：`POST /api/login` 获取 session cookie
- 会话：`GET /api/sessions`、`GET /api/sessions/:id?format=chat`
- 新建：`POST /api/structured-sessions` 或 `POST /api/commands`
- 输入与权限：`POST /api/sessions/:id/input` 及 escalation / permission 端点
- 实时更新：连接 `/ws`，订阅会话并合并 `init` / `output` / `status` / `ended`
- 网页版：原生菜单中的「打开网页版」，用于尚未原生覆盖的完整设置和文件功能

## 本地构建（仅 macOS）

```bash
./build.sh 1.16.0
# 产物：build/Wand.app + dist/wand-v1.16.0.dmg
```

要求：

- macOS 12+
- 安装了 Xcode 15+（命令行工具足够）
- 不需要 Apple Developer 账号（ad-hoc 自签名）

## 部署 DMG 供下载

服务端通过 `config.macos.dmgDir`（相对于 config 目录）查找 DMG，按修改时间取最新的。

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

1. **启动时主动触发授权弹窗**——TN3179 官方技巧：UDP connect 到随机 link-local IPv6 地址（fe80::/10）的 9 端口，不产生真实流量，且能绕开 15.x 部分场景"正常访问不弹窗"的系统 bug（`WandApp.init` 调用）。
2. **被拒检测**——NWBrowser 浏览 Bonjour 服务，被拒时进入 `.waiting(.dns(-65570 PolicyDenied))`；首次 start 可能误报 `.ready`，所以探测跑两轮以第二轮为准。ConnectView 在「网络失败 + 目标像局域网地址」时探测并展示引导卡片。
3. **设置深链**——`x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork`（含回退链）。设置页与会话列表加载失败处都有入口。

用户侧已知坑（均为系统行为）：

- 弹窗只出现在「未决定」状态；**Wand.app 不在 /Applications 里时弹窗可能永远不出现**（FB16077972）。
- ad-hoc 签名导致系统跟踪应用身份不稳定：**重装/升级后授权可能丢失、需要重新弹窗**。
- **重启 Mac 后授权偶尔失效**（开关显示打开但实际被拒，FB16512666）：在设置里把 Wand 的开关关掉再打开即可恢复；macOS 15.6+ 已修部分场景。
- macOS 上**没有**重置本地网络权限状态的官方手段（TN3179 明确说明，`tccutil` 管不到它）。

## 自动更新

原生首页启动 5 秒后异步调 `/api/macos-dmg-update?currentVersion=<当前版本>`，如果有新版：

1. 弹原生对话框（NSAlert）："立即更新 / 稍后提醒 / 跳过此版本"
2. 点"立即更新"→ URLSession 下载 DMG（进度对话框，throttle 50ms）
3. 下载完调 `hdiutil attach` 挂载，然后用 `NSWorkspace.open` 在 Finder 中显示挂载点
4. 用户拖拽 Wand.app 到 Applications 完成升级

对称 Android 的 `Intent.ACTION_VIEW` APK：把"实际安装"交回系统/用户决策，比"自动替换 /Applications/Wand.app + helper script 重启"更稳。

## 工程结构

```
macos/Wand/
├── ContentView.swift          # 已连接进入 NativeRootView，未连接进入 ConnectView
├── NativeRootView.swift       # 原生根导航、认证、设置、网页版兜底、更新检查
├── SessionListView.swift      # 会话列表与新建入口
├── ChatView.swift             # 原生消息、输入、权限审批与快捷提交入口
├── ChatStore.swift            # REST 快照与 WebSocket 增量状态机
├── NewSessionView.swift       # Claude/Codex、会话类型、目录与权限模式
├── GitQuickCommitView.swift   # 原生快捷提交面板
├── WandAPI.swift              # REST 客户端
├── WandSocket.swift           # WebSocket 订阅、重连与 resync
├── WandModels.swift           # 服务端协议 Codable 模型
├── LocalNetworkPermission.swift # macOS 15+ 本地网络权限：触发弹窗/被拒探测/设置深链
└── WebContainerView.swift     # 完整网页版兜底
```
