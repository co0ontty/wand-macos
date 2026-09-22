# macOS 原生终端

macOS PTY 使用 SwiftTerm 1.18.0 的 AppKit `TerminalView`，不是 WKWebView、网页 xterm，
也不是把 ANSI 去掉后塞进 TextView。选择固定版本是为了可重现构建；1.19+ 的构建插件需要额外授权，
当前不引入，也不关闭 Xcode 的插件验证。依赖版本及 revision 记录在 `Package.resolved`。

## 所有者与协议

- `Wand/NativeTerminalView.swift`：原生字形/ANSI/TUI、NSTextInputClient、选区、查找、粘贴、滚动。
- `Wand/PtyTerminalStore.swift`：PTY 生命周期、权限、缩放偏好、尺寸去抖和 ACK。
- `Wand/WandSocket.swift`：原生 URLSession `/ws`，顺序发送、序号缺口检测、心跳、退避重连。
- `Wand/ChatView.swift` 的 `PtySessionView`：原生连接/结束状态、权限卡片和底栏。

连接前通过 WandAPI 读取会话，既验证权限/存在性，也复用 401 的 cookie 更新；不传 URL token，
不访问首页，不向 WebKit 注入 cookie。`SessionRegistry` / terminal daemon 继续拥有服务器 PTY。
聊天仍使用独立的原生 ChatStore，但同一 PTY 页面只开一个原生 WebSocket，不再额外订阅 ChatStore。

`subscribe` 声明 `capabilities.ptyAck=true`。初始 `init.data.terminalState` 是版本化 ANSI 快照，
按 `cols/rows` 写入 `data` 后，严格依次重放 `pending` 中的 data/resize，再 fit 当前原生尺寸。
不能直接按本机宽度播放所有历史，也不能用会 soft-reset 的视图 resize 丢掉粘贴/备用屏幕模式。
旧服务器缺少快照或版本不支持时，reset 后使用 `output` 兼容回放；其历史可能已被服务器截断。

`output.data.chunk` 消费后确认 `ptyBytes`。output 中的标题/聊天元数据不触发全量终端重画。
序号缺口、`resync_required` 和重连均通过新快照重建；等待期间丢弃并 ACK 旧增量，避免背压锁死。
回滚上限 5,000 行；原生 WS 单帧上限 16 MiB，待发送队列上限 2 MiB，输入按 UTF-8 标量拆成至多 16 KiB 的帧。
窗口尺寸发送去抖 80 ms，SwiftTerm 内部合并显示刷新，不把每个字符变成一次 SwiftUI 重建。

## 输入与安全

- 键盘/中文提交/控制键走 `pty_input`，普通 Return 是单独的 `"\r"` 并标 `enter_text`。
- 用户粘贴由终端自己的 bracketed-paste 模式决定，不自动附回车，不改变空白或换行。
- 终端设备状态回复标 `userInput=false`；历史快照重放产生的回复不发送。
- 断线、同步和结束期间不发送输入，不保留到重连后执行；写入失败不重试用户字节。
- Command-K 仅调用本地 `clearScrollback`，不把 ANSI 清屏串当作用户命令写给 shell。
- OSC 52 读/写系统剪贴板默认禁止；主动复制/粘贴使用 AppKit。链接只允许用户点击 http/https/mailto。
- 终端由服务端执行；不引入客户端本地 PTY、任意本地命令或新的鉴权接口。

## 构建与验证

SwiftTerm 含 Metal shader 资源（即便使用 CoreGraphics 渲染）。Xcode 26+ 首次构建需要
`xcodebuild -downloadComponent MetalToolchain`；`build.sh` / `debug.sh` 会通过
`scripts/ensure-metal-toolchain.sh` 检查并下载 Apple 官方组件。直接 xcodebuild 前也需准备此组件。
保留 Universal Binary 和既有 ad-hoc 签名。SwiftTerm 为 MIT 协议，见 `THIRD-PARTY-NOTICES.md`。

`NativeTerminalTests` 覆盖回放顺序、备用屏幕/粘贴模式、中文预编辑/提交、输入分包、ACK、
序号缺口、重连隔离、尺寸去抖和 OSC 52 边界。
`testInstalledServiceNativeTerminalRoundTrip` 默认跳过；显式设置
`WAND_INSTALLED_TERMINAL_ACCEPTANCE=1` 后，只读取 `~/.wand/acceptance-connection.json` 指定服务，
新建一个临时 shell 做中文/ANSI、Return、stty 尺寸、resync、重连与备用屏幕验证，结束删除该测试会话。
测试不能把凭据写入输出。此接口验证不等同于所有 provider TUI 或完整中文候选/VoiceOver 人工验收。
