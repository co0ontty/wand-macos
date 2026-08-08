# macOS 客户端

Wand 的 macOS 原生 SwiftUI 客户端。连接后默认进入原生会话列表与聊天界面，
直连 wand 服务端 REST + WebSocket 协议；PTY 的 ANSI/TUI 终端画布由精简
WKWebView 渲染，侧栏、会话头和输入栏保持原生，另保留完整网页版兜底入口。

## 约定

- 工程代码放在 `macos/Wand/`
- `.app` 与 `.dmg` 构建产物**不要提交到仓库**（已在 `.gitignore`）
- 原生客户端更新始终查询官方 GitHub Release，不依赖当前连接的 wand 服务
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
# 产物：build/Wand.app + ZIP + DMG + wand-v1.16.0.update.json
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

1. **启动时主动触发授权弹窗**——TN3179 官方技巧：应用完成启动后 UDP connect 到私有 IPv4 地址的 9 端口，不产生真实流量，且避免无 scope 的 IPv6 link-local 地址在进入权限检查前直接失败。
2. **被拒检测**——NWBrowser 浏览 Bonjour 服务，被拒时进入 `.waiting(.dns(-65570 PolicyDenied))`；首次 start 可能误报 `.ready`，所以探测跑两轮以第二轮为准。ConnectView 在「网络失败 + 目标像局域网地址」时探测并展示引导卡片。
3. **设置深链**——`x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork`（含回退链）。设置页与会话列表加载失败处都有入口。

用户侧已知坑（均为系统行为）：

- 弹窗只出现在「未决定」状态；**Wand.app 不在 /Applications 里时弹窗可能永远不出现**（FB16077972）。
- ad-hoc 签名导致系统跟踪应用身份不稳定：**重装/升级后授权可能丢失、需要重新弹窗**。
- **重启 Mac 后授权偶尔失效**（开关显示打开但实际被拒，FB16512666）：在设置里把 Wand 的开关关掉再打开即可恢复；macOS 15.6+ 已修部分场景。
- macOS 上**没有**重置本地网络权限状态的官方手段（TN3179 明确说明，`tccutil` 管不到它）。

## 更新

客户端启动 3 秒后检查官方 GitHub Release；成功检查后 24 小时防抖，失败不写检查时间。
应用菜单和原生设置均可强制检查。更新通道是本机偏好，不跟随当前连接服务的 Web 更新通道：

- Stable：只使用公开稳定 Release。
- Beta：同时考虑 Stable 与 prerelease；同基础版本的 `-beta.*` 按 Wand 安装顺序视为正式版之后的构建。
- 从 Beta 切回 Stable 不自动降级，等待下一个更高的 Stable 版本。

发现新版本后：

1. 只匹配 `wand-v<Release 版本>[+构建时间].zip|dmg`，ZIP 优先、DMG 兜底。
2. 新 Release 先读取 `.update.json` 清单，校验文件大小与 SHA-256；旧 Release 兼容签名校验。
3. 解包后校验 bundle id、`CFBundleShortVersionString`、主可执行文件与代码签名。
4. 下载完成后写入可恢复事务；选择“稍后”时，设置页会保留“重启完成更新”入口 7 天。
5. helper 备份并替换当前 `Wand.app`，只有新版写入启动确认后才删除备份。
6. 复制、启动或确认失败时 helper 自动恢复旧应用；诊断日志写入 `~/Library/Logs/Wand/update.log`。

因此日常更新不再需要重新挂载 DMG 或拖拽安装。当前 app 所在目录必须可写；若从只读 DMG
直接运行，先将 `Wand.app` 拖到 Applications。Release 同时保留 DMG，供首次安装或自动更新失败时兜底。

嵌入网页版发来的旧 `downloadUpdate` 消息只会触发原生官方检查，不再接受连接服务器提供的
DMG 地址。服务端 `/api/macos-dmg-update` 暂时保留，供旧客户端和浏览器手动下载兼容。

## 工程结构

```
macos/Wand/
├── ContentView.swift          # 已连接进入 MainShellView，未连接进入 ConnectView
├── MainShellView.swift        # 原生三栏主界面、会话列表、设置与网页版入口
├── ChatView.swift             # 原生消息、输入、权限审批与快捷提交入口
├── ChatStore.swift            # REST 快照与 WebSocket 增量状态机
├── NewSessionView.swift       # 五个 Provider、会话类型、目录与权限模式
├── GitQuickCommitView.swift   # 原生快捷提交面板
├── MacUpdateManager.swift     # 唯一更新状态源、Stable/Beta、缓存与待重启事务
├── UpdateInstaller.swift      # 下载、校验、原位替换、失败回滚与自动重启
├── WandAPI.swift              # REST 客户端
├── WandSocket.swift           # WebSocket 订阅、重连与 resync
├── WandModels.swift           # 服务端协议 Codable 模型
├── LocalNetworkPermission.swift # macOS 15+ 本地网络权限：触发弹窗/被拒探测/设置深链
└── WebContainerView.swift     # PTY 终端画布与完整网页版兜底
```
