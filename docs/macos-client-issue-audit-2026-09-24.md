# Wand macOS 客户端问题清单

写给接手修这些问题的人。不需要先熟悉整仓。每条都写了：用户会看到什么、代码在哪、怎么自己找到、建议怎么改、改完怎么验收。

检查日期：2026-09-24。对象是本仓库 `macos/` 里的原生 macOS 客户端（SwiftUI）。没有名为 “Back OS” 的模块；这份清单对应的就是这个 macOS 客户端。

证据来自阅读当前源码，不是猜测。本机不能截取正在运行的窗口，所以下面的复现步骤需要你在本机打开 Wand 再走一遍。改完后用真机点一遍，不要只看编译通过。

行号会随改动漂移。每条都给了可以搜索的函数名和原文，找不到行号时用搜索，不要按过期行号硬改。

## 处理结果（2026-09-24，同一轮修完）

| 编号 | 结果 |
| --- | --- |
| 1 | 已修：筛选期间标题改成静态标签（不再是假按钮），旁边显示「筛选时保持展开」；任务行同类的会话数量控件也一起改了。 |
| 2 | 已修：任务加号始终可见可点，命中区 30 × 30（`WandIconButtonStyle`），VoiceOver 可读；多选时隐藏。 |
| 3 | 已修：`openTask` 不再先清空可见会话；侧栏点开会话时用摘要里的 cwd 先填文件栏；文件树在「会话已定、cwd 未到」时显示「正在读取工作目录」并等待；`WorkspaceTaskView` 只渲染属于当前任务详情的会话。 |
| 4 | 按第二种方案处理（产品决策）：新建页保持 ⌘ Return 启动，改掉设置页里把它说成全局的文案，并在 `UX-CONTRACT.md` 写明作用范围。原方案（新建页也读 `wand.sendWithCommandEnter`）仍是一处小改动，需要时再换。 |
| 5 | 已修：拖进「处理中」且卡片没有会话时先弹确认（列出将要发送的说明），可选「启动执行」「只移入不派发」「取消」；失败提示仍在 reload 之后展示。 |
| 6 | 已修：说明为空时提交不再直接落库，改为先生成并回填说明与 Tag，再点一次才提交；小字与 Tag 占位文案同步说明。 |
| 7 | 已修（实际影响范围比原文小）：已有任务的目录栏在等待详情时显示「正在读取任务的工作目录」，不再把入口目录当成任务目录；任务详情返回时只在用户没动过该栏的情况下写入 cwd。 |
| 8 | 已修：排序改用 `endedAt ?? startedAt`，与行上显示的时间同口径；`SessionSidebarSortTests` 固定这条规则。 |
| 9 | 已修：侧栏这些按钮改用 `WandIconButtonStyle` / 30 pt 命中区。 |

列表里「核对过、这次没有写成问题的地方」那些结论本轮复核仍然成立，未改动。

## 先知道这几个词

| 词 | 意思 |
| --- | --- |
| 工作空间 | 侧栏上方的一个目录。里面有任务。 |
| 任务 | 工作空间下面的一行。里面可以有多个会话。 |
| 会话 | 一次聊天或一个终端。可以挂在任务下，也可以出现在下方「单独会话」。 |
| 单独会话 | 侧栏下方那一段，不挂在任务里的会话，以及旧服务器上可恢复的历史。 |
| 检查器 | 窗口右边的文件 / Git / 详情栏。 |
| 任务看板 | 主区域里的待办看板，不是侧栏里的任务树。 |

## 功能在哪个文件

修某一块时只打开对应文件，不要全仓搜索。

| 用户看到的功能 | 先打开 |
| --- | --- |
| 窗口、侧栏滚动、命令菜单 | `macos/Wand/MainShellView.swift` |
| 侧栏上方：工作空间 → 任务 → 会话 | `macos/Wand/WorkspaceListView.swift` |
| 侧栏下方：单独会话 | `macos/Wand/SessionSidebarView.swift` |
| 菜单和快捷键名称 | `macos/Wand/DesktopCommands.swift` |
| 首页 / 新建会话表单 | `macos/Wand/NewSessionView.swift` |
| 已经打开的聊天 | `macos/Wand/ChatView.swift`、`macos/Wand/ChatStore.swift` |
| 终端 | `macos/Wand/NativeTerminalView.swift`、`macos/Wand/PtyTerminalStore.swift` |
| 打开某个任务后的主区域 | `macos/Wand/WorkspaceTaskView.swift`、`macos/Wand/WorkspaceStore.swift` |
| 右边文件树 | `macos/Wand/FilePanelView.swift`、`macos/Wand/FileTreeView.swift` |
| 快捷提交 | `macos/Wand/GitQuickCommitView.swift` |
| 任务看板 | `macos/Wand/TaskBoardView.swift`、`macos/Wand/TaskBoardModels.swift` |
| 设置里的发送方式 | `macos/Wand/SettingsView.swift` |
| 连接页 | `macos/Wand/ConnectView.swift` |

## 问题总表

| 编号 | 严重程度 | 一句话 |
| --- | --- | --- |
| 1 | 高 | 筛选时，点工作空间标题不会收起，也没有任何可见反馈 |
| 2 | 高 | 任务上的「新建会话」加号平时看不见，辅助功能也找不到 |
| 3 | 高 | 从侧栏打开任务里的会话时，右边文件树会先打开错误目录 |
| 4 | 高 | 新建会话的回车规则不听设置，和聊天里的回车规则不是同一套 |
| 5 | 高 | 把没有会话的看板卡片拖进「处理中」，会立刻启动 Agent，没有确认 |
| 6 | 高 | 快捷提交允许空的提交说明，点下去才开始让服务器生成说明 |
| 7 | 中 | 打开已有任务时，用户刚改过的目录会被稍后返回的任务详情盖掉 |
| 8 | 低 | 单独会话的排序用开始时间，行上显示的时间却优先用结束时间 |
| 9 | 低 | 侧栏里新加的加号和展开钮只有约 22 点，比这个客户端自己的图标按钮小 |

---

## 1. 筛选时，点工作空间标题没有反应

严重程度：高。用户会以为程序卡了。

### 用户看到什么

1. 侧栏顶部搜索框里输入任意文字，例如一个工作空间的名字。
2. 匹配的工作空间会展开，标题左边的箭头朝下。
3. 再点这个标题，或点那个箭头。列表不收起，箭头也不变。
4. 按钮仍然有悬停变色，所以它看起来是可以点的。

清空搜索之后，同一个标题又可以正常收起。

### 代码在做什么

文件：`macos/Wand/WorkspaceListView.swift`  
函数：`taskGroupHeader`

筛选时 `collapsible` 被算成 `false`（搜索要临时展开结果，这是原设计）。但标题按钮没有 `.disabled`，点击处理却直接 return：

```swift
Button {
    guard collapsible else { return }
    toggleCollapsedTaskGroup(group.id)
} label: {
    // 箭头、文件夹、名称
}
.buttonStyle(.plain)
.accessibilityHint(collapsible ? (expanded ? "收起任务" : "展开任务") : "筛选时保持展开")
```

VoiceOver 能读到「筛选时保持展开」。只用鼠标的人看不到这句话，也看不到禁用状态。

同一文件里，任务右边的会话数量按钮在筛选时是 `.disabled(isFiltering)`。工作空间标题没有同样处理。两处行为不一致。

### 怎么定位

1. 打开 `WorkspaceListView.swift`。
2. 搜索 `guard collapsible else { return }`。
3. 往上看这个 `collapsible` 是在 `taskGroupBlock` 里算出来的：`!isFiltering && ...`。
4. `isFiltering` 就是搜索框不是空白。

### 建议改法

二选一，不要两个都做一半：

- 筛选期间把这个标题按钮 `.disabled(true)`，并把箭头或标题旁用普通文字写上「筛选时保持展开」；或
- 允许筛选期间手动收起，同时保证清空搜索后恢复用户原来的展开集合。现有注释要求「搜索只是临时展开」。如果选择允许收起，先读 `expandedTaskGroups` 和 `revealSelection()`，不要把临时收起写进用户的长期折叠集合。

### 改完怎么验收

1. 搜索一个工作空间名字。点它的标题。要么收起，要么明确显示不能收起，不能是「点了没反应」。
2. 清空搜索。之前手动收起的工作空间必须还是收起的。后台大约每 10 秒刷新一次，刷新后也不能把它重新展开。
3. 用 VoiceOver 读这个标题，读出来的提示和屏幕上看到的状态一致。

---

## 2. 任务上的「新建会话」加号平时不存在

严重程度：高。这是当前侧栏里新建任务会话的主按钮。

### 用户看到什么

1. 展开一个工作空间，看到任务行。
2. 不把鼠标放上去时，任务行右边没有加号。
3. 打开这个任务下面的某个会话后，加号仍然不出现。因为这时被标成「当前行」的是会话，不是任务。
4. 只有鼠标悬停在任务行上，或者当前打开的就是任务本身、没有选中子会话时，加号才出现。
5. VoiceOver 按顺序读侧栏时，读不到这个加号。
6. 加号的可点区域大约是 22×22 点。这个客户端其它图标按钮是 30×30 点（`WandIconButtonStyle`）。

右键菜单里还有「新建会话」，所以功能没有删掉，但主路径藏起来了。

### 代码在做什么

文件：`macos/Wand/WorkspaceListView.swift`  
函数：`taskSummaryRow`

当前行是这样算的：子会话被选中时，任务行自己不算选中。

```swift
let childSessionSelected = summary.sessions.contains { $0.id == selectedSessionId }
let selected = selectedTaskId == summary.id && !childSessionSelected
```

加号接着写成：

```swift
.opacity(hovering || selected ? 1 : 0)
.allowsHitTesting(hovering || selected)
.accessibilityHidden(!(hovering || selected))
```

`opacity 0` 让它看不见。`allowsHitTesting(false)` 让鼠标点不到。`accessibilityHidden(true)` 让 VoiceOver 跳过它。三者同时成立时，这个按钮对键盘和读屏用户不存在。

按钮图片本身是 `.frame(width: 22, height: 22)`。旁边会话数量按钮是 `.frame(height: 22)`。工作空间标题上的加号同样是 22×22，见同一个文件的 `taskGroupHeader`。

多选还有一个连带问题：进入「多选任务和终端」后，如果鼠标还停在任务行上，这个加号可以点，并且会去新建会话，把人带离多选。加号没有在 `isSelecting == true` 时禁用。

### 怎么定位

1. 打开 `WorkspaceListView.swift`。
2. 搜索 `accessibilityHidden(!(hovering || selected))`。
3. 搜索 `private enum TreeIndent`，确认缩进常量还在。加号即使透明，22 点的空位仍然占着，所以长任务名会被提前截断。

### 建议改法

- 加号恢复为始终可见、可点、可被 VoiceOver 读到。可以保持颜色较淡，不要用透明度 0 把它拿掉。
- 点击区域至少做到和 `WandIconButtonStyle` 一样的 30×30 点。不要只把图标画大，命中区域也要大。
- `isSelecting == true` 时禁用这个加号，避免多选过程中误开新建页。
- 右键菜单里的「新建会话」保留。

### 改完怎么验收

1. 不悬停也能看到加号，点它会进入「在这个任务里新建会话」，并且目录和任务已经预选。
2. 打开该任务下的一个会话后，加号仍然在。
3. 打开 VoiceOver，光标能停在「在某某任务中新建会话」上。
4. 进入多选，加号不能点。
5. 侧栏宽度仍是 260 点。长中文任务名可以截断，但不要比改之前更早被截断一截却只是为了留一个空位。

---

## 3. 打开任务里的会话时，文件树会先显示错误目录

严重程度：高。检查器开着的时候，用户可能点到不属于这个任务的文件。

### 用户看到什么

1. 打开右边检查器，停在「文件」。
2. 在侧栏点某个任务下面的一个会话。
3. 文件树面包屑有一段时间显示「服务器默认目录」，列出的是服务器默认工作目录，不是这个会话的目录。
4. 任务详情加载完后，树再跳到正确目录。刚才展开的文件夹会丢掉。
5. 如果加载失败，检查器会停在「选择一个会话以查看详情」或默认目录，而主区域其实已经在这个任务里。

### 代码在做什么

有三处接在一起。

第一处，侧栏点任务会话时故意把会话对象清空。  
文件：`macos/Wand/MainShellView.swift`  
函数：`workspaceSidebar` 里的 `onOpenTaskSession`

```swift
selectedSessionId = session.id
selectedSession = nil
selectedWorkspaceTask = WorkspaceTaskSelection(workspace: workspace, task: task)
Task { await workspaceStore.openTask(...) }
```

第二处，打开任务的第一步就把当前快照清掉。  
文件：`macos/Wand/WorkspaceStore.swift`  
函数：`openTask`

```swift
visibleSessionID = nil
visibleSnapshot = nil
```

第三处，快照一旦变成空，壳层把选中的会话 id 也清掉。  
文件：`macos/Wand/MainShellView.swift`  
函数：`body` 上的 `onChange(of: workspaceStore.visibleSnapshot?.id)`

```swift
guard let snapshot = workspaceStore.visibleSnapshot else {
    selectedSessionId = nil
    selectedSession = nil
    return
}
```

检查器用的是这个已经被清空的值。  
文件：`macos/Wand/FilePanelView.swift`，`body` 的 `.files` 分支把 `session?.cwd` 传给文件树。  
文件：`macos/Wand/FileTreeView.swift`

```swift
private var displayPath: String {
    effectiveRootPath.isEmpty ? "服务器默认目录" : effectiveRootPath
}
private var effectiveRootPath: String {
    rootPath ?? ""
}
```

空路径不是「先别加载」，而是「向服务器要默认目录」。文件树用 `.task(id: rootLoadKey)` 监听这个路径，所以会真的发请求。

### 怎么定位

1. 在 `MainShellView.swift` 搜索 `onOpenTaskSession`。
2. 在 `WorkspaceStore.swift` 搜索 `func openTask`。
3. 在 `MainShellView.swift` 搜索 `visibleSnapshot?.id`。
4. 在 `FileTreeView.swift` 搜索 `服务器默认目录`。

### 建议改法

- 加载新快照之前，不要把壳层的 `selectedSessionId` 清成 nil。可以保留上一个会话，直到新的 `getSession` 成功后再替换。
- 文件树在「会话 id 已知、但 cwd 还没到」时显示「正在读取工作目录」，不要用空字符串去请求默认目录。
- `openTask` 仍然可以在 store 内部把 `visibleSnapshot` 置空，但壳层不要把「快照暂时为空」理解成「用户没有会话」。

不要改文件树的搜索和预览协议。问题只在根路径被换成空。

### 改完怎么验收

1. 先打开检查器的「文件」，再点另一个任务里的会话。面包屑不能出现「服务器默认目录」，也不能列出别的项目的文件。
2. 加载完成后，面包屑是这个会话自己的 cwd。
3. 断网或让任务详情失败。文件树显示错误或保持上一个正确目录，不能改去浏览默认目录。
4. 从「单独会话」打开一个会话时，文件树仍然直接用该会话的 cwd。这条旧路径不能坏。

---

## 4. 新建会话的回车不听「发送消息」设置

严重程度：高。这是用户每天第一次输入会碰到的规则。

### 用户看到什么

1. 打开设置，找到「消息输入」。
2. 说明写的是「选择你在对话输入框中使用的发送方式」。
3. 选「Return 发送」。回到聊天里，Return 确实发送，Shift-Return 换行。
4. 回到首页或点「新建会话」。在大输入框里按 Return，只是换行，不会启动。
5. 必须按 ⌘Return。输入框旁边的启动按钮提示也写着 ⌘↵。

所以设置看起来是全局的，实际只对已经打开的聊天生效。新建页永远是另一套。

### 代码在做什么

设置存在 `wand.sendWithCommandEnter`。  
文件：`macos/Wand/SettingsView.swift`，函数 `generalContent`。文案是「对话输入框」。

聊天读取这个值。  
文件：`macos/Wand/ChatView.swift`，`IMEAwareComposerTextView` 的 `sendWithCommandEnter` 参数来自 `@AppStorage("wand.sendWithCommandEnter")`。  
真正判断在同文件的 `ConversationSendPolicy.shouldSubmit`：`commandEnter == false` 时，没有按住 Command 也会发送。

新建页把这个参数写死为 `true`。  
文件：`macos/Wand/NewSessionView.swift`，函数 `firstMessageCard`

```swift
IMEAwareComposerTextView(
    text: $draft.firstMessage, placeholder: "描述你想完成的事…",
    isFocused: composerFocused, sendWithCommandEnter: true,
    ...
)
```

同文件 `startButton` 还有 `.keyboardShortcut(.return, modifiers: .command)` 和 `.help("启动会话 · ⌘↵")`。

### 怎么定位

1. 在 `NewSessionView.swift` 搜索 `sendWithCommandEnter: true`。
2. 在 `SettingsView.swift` 搜索 `发送消息`。
3. 在 `ChatView.swift` 搜索 `ConversationSendPolicy`。

### 建议改法

新建页使用和聊天相同的 `@AppStorage("wand.sendWithCommandEnter")`。  
按钮提示改成跟设置一致：Return 发送时提示 Return，⌘Return 发送时提示 ⌘Return。  
中文输入法正在组字时仍然不能启动会话。这个保护已经在 `ConversationSendPolicy` 里，不要删。

如果产品故意要让「第一句话」永远用 ⌘Return，以便 Return 换行，那就要改设置文案，写明「只影响已打开的聊天，新建会话始终是 ⌘Return」。不要让现在这两处文案互相矛盾。

### 改完怎么验收

1. 设置选「Return 发送」。新建页按 Return 会启动；按 Shift-Return 只换行。
2. 设置选「⌘Return 发送」。新建页按 Return 只换行；按 ⌘Return 启动。
3. 用中文输入法，候选词还在时按 Return，不能启动会话。
4. 已经打开的聊天保持原来的规则。终端里的 Return 仍然是终端回车，不要改终端。

---

## 5. 拖看板卡片到「处理中」会直接启动 Agent

严重程度：高。会创建真实会话。

### 用户看到什么

1. 打开主区域的「任务看板」。
2. 找一张还没有任何会话、停在「等待认领」或其它列的卡片。
3. 把它拖进「处理中」。
4. 卡片换列之后，客户端立刻用这张卡片的描述（没有描述就用标题，再没有就用「执行此任务」）去派发 Agent。
5. 没有确认框。
6. 如果派发失败，列已经改成「处理中」，不会自动拖回去。只在重新加载列表之后显示一条错误。

已经有会话的卡片再拖进「处理中」不会再派发。这个区别界面上看不出来。

### 代码在做什么

文件：`macos/Wand/TaskBoardModels.swift`

```swift
func wandBoardDropDispatches(status: String, sessionCount: Int) -> Bool {
    status == WandBoardStatus.doing.rawValue && sessionCount == 0
}
```

文件：`macos/Wand/TaskBoardView.swift`，函数 `dropTask`

```swift
_ = try await api.updateBoardTask(id: taskId, body: ["status": status])
if dispatches {
    let result = try await api.dispatchBoardTask(...)
} catch {
    // 状态已经改好，派发失败只提示、不回滚
    dispatchError = error.localizedDescription
}
await reload(showProgress: false)
if !dispatchError.isEmpty { errorMessage = dispatchError }
```

提示词来自同文件调用的 `wandBoardDropDispatchPrompt`：描述，否则标题，否则「执行此任务」。

### 怎么定位

1. 搜索 `wandBoardDropDispatches`。
2. 搜索 `func dropTask`。
3. 看板的拖放入口在 `macos/Wand/TaskBoardBoardView.swift` 的 `onDrop`，它把状态和任务 id 交给 `onDropTask`。

### 建议改法

拖进「处理中」时，如果 `sessionCount == 0`，先问一句「要用当前说明启动执行吗？」。取消则只改状态，或连状态也不改，两种里选一种并写进确认文案。  
派发失败时，不要留在一个已经显示「处理中」但其实没有会话的状态里不说明原因。现在的错误条会被 `reload` 清掉，所以代码故意把错误放到 reload 之后。修的时候保留这个顺序，否则错误会闪一下就没了。

不要改「已经有会话的卡片只改状态」这条，它是为了避免拖一次多开一个会话。

### 改完怎么验收

1. 拖一张没有会话的卡片到「处理中」。必须先看到确认。取消后不能出现新会话。
2. 确认后，会话真的创建，卡片在「处理中」。
3. 把派发接口弄失败（断网即可）。用户能看到失败原因，并且知道卡片现在算不算「处理中」。
4. 拖一张已经有会话的卡片到「处理中」。只换列，不新建会话。

---

## 6. 快捷提交允许空说明，而且提交前看不到将要使用的说明

严重程度：高。这会在 git 仓库里产生一次真实提交。

### 用户看到什么

1. 在一个有未提交改动的会话里打开「快捷提交」。
2. 标题写着「检查改动，确认提交信息与后续操作」。
3. 提交说明留空。「提交」按钮仍然可以点。按钮旁边的小字是「执行前会使用上方提交信息」。
4. 点「提交」之后，按钮区域才变成「AI 生成 + 提交中…」。
5. 用户没有机会先看到生成出来的说明再决定是否提交。
6. 成功且不需要处理推送失败时，窗口直接关闭。

界面上另有一个 AI 按钮，用来预先把说明填进输入框。那条路径是安全的。危险的是空着说明直接点「提交」。

### 代码在做什么

文件：`macos/Wand/GitQuickCommitView.swift`  
函数：`standardCommitActions` 和 `submit`

按钮只检查有没有改动，不检查说明是不是空的：

```swift
.disabled(!hasChanges || committing)
```

旁边的字：

```swift
Text(hasChanges ? "执行前会使用上方提交信息" : "工作区干净")
```

`submit` 里：

```swift
let msg = message.trimmingCharacters(in: .whitespacesAndNewlines)
autoGenerating = msg.isEmpty || (withTag && userTag.isEmpty)
let r = try await api.quickCommit(
    sessionId: sessionId,
    customMessage: msg.isEmpty ? nil : msg,
    ...
)
```

空说明会把 `customMessage` 传成 `nil`，由服务端生成。`autoGenerating` 只影响正在提交时的文字，不会先把说明填回输入框让用户确认。

成功且没有推送错误时会 `dismiss()`。

### 怎么定位

1. 打开 `GitQuickCommitView.swift`。
2. 搜索 `func submit(action: String`。
3. 搜索 `执行前会使用上方提交信息`。

### 建议改法

空说明时不要直接提交。可以：

- 禁用「提交」，提示先填写或先点 AI 生成；或
- 点「提交」时如果说明为空，先只生成说明并填进输入框，第二次点击才真正提交。

小字不要再说「会使用上方提交信息」，除非上方确实有文字。  
带 Tag 且 Tag 为空时，现在同样会在提交过程中自动生成 Tag（`autoTag: withTag && userTag.isEmpty`）。如果改提交说明的确认方式，Tag 用同一套，避免一个要确认、一个悄悄生成。

### 改完怎么验收

1. 有改动、说明为空时，不能在用户没看到说明的情况下产生新的 git commit。
2. 用 AI 按钮生成说明后，用户可以改字，再点提交。提交信息是用户看到的那一段。
3. 工作区干净时，按钮仍然不可用；有待推送 commit 时，「推送 N 个待推 commit」仍然可用。
4. 推送失败时，窗口不要关掉，现有的失败结果面板要还在。

---

## 7. 读取任务目录的结果会盖掉用户刚改的路径

严重程度：中。只在「从任务上新建会话」并且网络慢时出现。

### 用户看到什么

1. 在某个任务上点「新建会话」。
2. 表单先出现。目录一栏一开始是工作空间根目录，不是这个任务自己的 worktree。
3. 如果任务详情还没返回，用户已经把目录改成别的路径。
4. 详情返回后，目录被改回任务的真实 cwd。用户没有看到「你的修改被替换了」。

启动按钮在详情返回前是禁用的，所以不会用错误目录启动。问题是返回之后把用户已经键入的路径冲掉。

### 代码在做什么

入口先放进工作空间根目录。  
文件：`macos/Wand/MainShellView.swift`，函数 `beginTaskSession`

```swift
beginCreation(context: SessionCreationContext(
    cwd: workspace.cwd,
    ...
    taskId: task.id,
    startsNewTask: false
))
```

表单加载完，如果目的地是已有任务，会再请求任务详情。  
文件：`macos/Wand/NewSessionView.swift`，函数 `loadInitial` 末尾调用 `selectDestination`。  
函数 `selectDestination`：

```swift
draft.loadingTask = true
Task {
    let detail = try await api.getWorkspaceTask(taskId: destination)
    guard draft.taskGeneration == generation, draft.destination == destination else { return }
    draft.cwd = detail.cwd
}
```

这里没有判断「等待期间用户是否改过 `draft.cwd`」。目录输入框也没有在 `loadingTask` 时禁止编辑。  
`readyToStart` 在 `loadingTask` 时为 false，所以启动按钮是关的。这只保护了启动，不保护输入。

### 怎么定位

1. 搜索 `func beginTaskSession`。
2. 搜索 `func selectDestination`。
3. 搜索 `if isExistingTask { selectDestination`。

### 建议改法

在发出 `getWorkspaceTask` 之前记下当时的 cwd。返回时只有 cwd 仍然等于那个旧值，才写入 `detail.cwd`。用户已经改过就不覆盖，并在目录旁说明「任务目录是……，你当前用的是另一条路径」。  
等待期间也可以把目录框设成只读，加载完成后再允许改。两种都可以，不要既允许编辑又无声覆盖。

任务详情请求失败时，现有的 `draft.taskError` 要保留，启动按钮必须继续禁用。不能带着工作空间根目录启动一个隔离任务。

### 改完怎么验收

1. 给任务详情接口加延迟。打开「在此任务新建会话」，在目录返回前改掉路径。返回后，用户改的路径还在。
2. 不改路径。返回后，目录变成任务详情里的 cwd，而不是仓库根目录。
3. 详情请求失败。能看到错误，启动按钮不能按。

---

## 8. 单独会话的顺序和行上的时间不是同一个时间

严重程度：低。列表不会丢会话，但「最近」看起来是错的。

### 用户看到什么

一个早就开始、刚刚才结束或更新过的会话，行右侧或副标题显示「刚刚」。它在列表里的位置却按开始时间排，可能沉在很下面。用户按看到的时间去找，找不到预期的位置。

### 代码在做什么

文件：`macos/Wand/SessionSidebarView.swift`  
类型：`SidebarColumn.ListEntry`

排序：

```swift
case .session(let session):
    return Self.parseISO8601(session.startedAt)?.timeIntervalSince1970 ?? 0
```

同一文件里 `SessionTile.recentTime`：

```swift
SessionListDateLabel.relative(iso: session.endedAt ?? session.startedAt)
```

显示优先 `endedAt`，排序只用 `startedAt`。没有 `startedAt` 的会话排序值是 0，会沉到底部。

可恢复历史用的是 `mtimeMs`，和上面这条规则也不相同。这是故意的：历史没有 Wand 的开始时间。不要把两条合成一个错误。

### 怎么定位

1. 搜索 `var sortTimestamp`。
2. 搜索 `var recentTime`。

### 建议改法

排序使用和副标题相同的时间：有 `endedAt` 用 `endedAt`，否则用 `startedAt`。  
改之前先看一条真实会话 JSON，确认 `endedAt` 在运行中的会话上是空的。如果运行中的会话也会写 `endedAt`，先问清这个字段的含义，不要把「正在跑」的会话排到旧位置。

### 改完怎么验收

造两条会话：A 昨天开始且没有更新，B 上周开始但刚刚结束。副标题更近的那条必须排在上面。筛选后再清空，顺序不变。

---

## 9. 侧栏新按钮比客户端自己的最小点击区域小

严重程度：低。和问题 2 是同一处控件，如果问题 2 把加号恢复成 30×30，这一条的加号部分就一起解决了。展开箭头还要单独看。

### 用户看到什么

工作空间标题右侧加号、任务行加号、任务行「会话数量 + 箭头」都不好点，尤其是触控板不太准时。箭头的可点高度大约 22 点。

### 代码在做什么

`macos/Wand/Theme.swift` 的 `WandIconButtonStyle` 把图标按钮固定成 30×30 点。  
`macos/DESIGN.md` 写着图标按钮使用 30×30 点命中区。

`WorkspaceListView.swift` 的 `taskGroupHeader` 和 `taskSummaryRow` 改用了 `.buttonStyle(.plain)`，尺寸是 22。它们不再走 `WandIconButtonStyle`。

### 怎么定位

搜索 `frame(width: 22, height: 22)` 和 `frame(height: 22)`，范围限制在 `WorkspaceListView.swift`。

### 建议改法

这些按钮改回 `WandIconButtonStyle`，或者保留 plain 样式但把 `contentShape` 做到至少 30×30。不要为了行高好看把命中区留在 22。

### 改完怎么验收

点加号边缘和箭头边缘都能触发。不要误触相邻的那一行。

---

## 核对过、这次没有写成问题的地方

下面这些看过代码，没有发现一份足够确定的缺陷。接手的人不要为了「清单里没写」就去改它们。

| 区域 | 看过的结论 |
| --- | --- |
| 终端输入 | `PtyTerminalStore.sendInput` 在终端未就绪时直接丢掉输入，并给 toast「连接恢复后请重新输入」。`WandSocket` 重连时清空发送队列，不把旧输入补发出去。 |
| 终端剪贴板 | `NativeTerminalView.clipboardCopy` / `clipboardRead` 是空实现，程序不能用 OSC 52 读写系统剪贴板。用户自己的粘贴走 `pasteText`。 |
| ⌘L / ⌘F | `MainShellView.handle` 对这两个命令 `break`，是因为聊天和终端各自听了同一条通知。不是没接上。聊天在 `ChatView`，终端在 `PtySessionView` 那段。 |
| 看板「删除」文案 | 客户端 `deleteBoardTask` 走 `DELETE /api/wand-tasks/:id`。服务端 `src/server-task-routes.ts` 里这个 DELETE 调用的是 `archiveBoardTask`，会话保留。界面说「已归档」和服务器一致。 |
| 更新包 | `UpdateInstaller` 会做 codesign `--verify --strict --deep`，有 sha256 时也会核对。这次没有看到跳过校验的路径。 |
| 新建任务的启动保护 | 已有任务在详情返回前，`readyToStart` 要求 `binding` 对得上，启动按钮是关的。问题 7 只覆盖「等待时改了路径又被盖掉」，不是「会用错目录启动」。 |

## 不在这份清单里的事

- 没有逐个点击已安装的 Wand 窗口。复现步骤需要接手的人在本机做。
- 没有改这些缺陷。这份文件只记录问题和改法。
- 侧栏视觉层级（分段标题、缩进、当前行强调线）是上一轮刚做的界面调整，不是上面这些缺陷的修复。修问题 2 和 9 时不要把三级缩进重新拉成同一列。`TreeIndent` 上面的注释写了这个约束。
