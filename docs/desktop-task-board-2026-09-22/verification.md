# 任务看板对齐 Web · 验收 · 2026-09-22

最终版本：`4.72.0-debug.09220703`，Universal（`x86_64 arm64`），ad-hoc 签名，已放入本机已安装服务的 macOS 更新目录 `~/.wand/macos/`。

## 行为

任务面板从「轻量三列」改成与 Web `task-board-*` 同口径的看板，保留 macOS 原有的详情描述编辑与侧栏入口。

- 四个视图：概览 / 看板 / 列表 / 甘特图，切换后持久化到 `wand.desktop.taskBoard.viewState`；筛选与显示设置持久化到 `wand.desktop.taskBoard.display`。
- 看板三列 `等待认领 / 处理中 / 等你确认`，列头状态色与 Web 一致；`归档任务` 是「等你确认」下的独立目录，
  折叠状态下搜索或筛选归档时自动展开（对齐 Web `!collapsed || query || filters.statuses.includes("archived")`）。
- 卡片带优先级、里程碑、工作空间、会话（provider / 状态 / 模型 / 模式）与标签；标签配色与 Web 同款
  （bug `#b24f45`、feature `#4a6fa5`、其余用同一套 32 位散列），同标签跨端同色。
- 拖拽用自定义 UTI：卡片拖到列换状态，拖进「处理中」且该任务还没派发过才顺带派发（`sessionCount == 0`），
  已跑过 / 正在跑的卡拖回来只改状态，不会每拖一次多开一个 session；会话拖到卡片完成绑定。
- 新建面板落在当前列：在「处理中」列创建且填了描述才立刻派发；标题留空由服务端按描述生成，客户端轮询补齐。
- 筛选（里程碑 / 工作空间 / 状态 / 优先级 / 标签）+ 搜索 + 显示设置（密度、字段开关），结果摘要与空态文案按列区分。
- 6 秒轮询，失败保留旧列表静默重试；标题失焦即存，描述保留独立保存按钮。

## 验证

- macOS 完整 XCTest：**84/84 通过**（`TaskBoardTests` 20 项：解码容错、agent 模式夹取、模型选项含 `default` 回落、
  会话分组、拖拽 / 创建派发时机、派发提示词回落、筛选与搜索语义、逾期统计、甘特越界、进度折线单调、里程碑可见性、
  视图状态往返）。本机沙箱内 `xcodebuild test` 因 `testmanagerd` 不可达（`error 3 - No such process`）改用
  `macos/scripts/run-tests.sh` 注入式运行，CI（`macos-release.yml`）仍走标准 `xcodebuild test`。
- 真实服务只读契约核验（本机已安装服务 + 用户指定连接码，仅 GET）：
  `GET /api/wand-tasks?includeArchived=1` 返回裸数组 88 条，逐字段与解码器对齐 ——
  `status` ∈ {todo, doing, done, archived}、`priority` ∈ {none, low, medium, high}（`urgent` 与 Web 同集合保留）、
  `agent.{provider,model,thinkingEffort,mode,kind}`（provider codex/pi、mode default/full-access/managed、
  effort standard/deep/max）、`titleSource` ∈ {auto, user}、`sessions[]`（provider 含空串、`sessionKind` pty/structured、
  单任务最多 4 个会话）、`milestone.{id,name,isDefault}`（88/88 命中）、`workspace`（77 条）、`dueDate`/`labels` 本轮为空。
  会话状态文案与 Web `issueSessionStatusLabel` 逐值一致（running/idle/exited/failed/空）。
- 这轮真实 payload 暴露一处容错缺口并已修：`sessions` 数组原先整体解码，单个坏元素会连坐丢掉同任务其它会话；
  现在逐元素容错并丢弃无 `id` 条目，新增用例 `testBoardTaskDecoderKeepsUsableSessionsWhenOneIsMalformed`。
- 构建产物校验：`codesign --verify --strict` 通过、`hdiutil verify` CRC32 有效、`lipo -info` 为 `x86_64 arm64`、
  `CFBundleVersion` = `47200`、`git diff --check` 干净。
- 分发校验：`/api/macos-dmg-update?currentVersion=0.0.0` 返回
  `latestVersion=4.72.0-debug.09220703`、`size=11886117`、`source=local`；`/macos/download` 的 206 range 请求
  报 `0-1023/11886117`，整包下载 11886117 字节、SHA-256 与 `update.json` 清单逐字节一致。

## 真机证据与限制

连接地址始终是用户指定的本机已安装服务，没有切换到隔离服务或另建模拟服务；连接码未写入仓库、日志或截图。

**本轮未做界面 / 交互端到端人工验收**，原因是环境限制，不是跳过：

- 本机没有可用的 GUI 会话：新启动的 GUI 进程拿不到窗口。本轮用当前构建做了两次独立复现
  （`/tmp/wand-macos-taskboard-qa/WandTaskBoardQA.app`、改过 `CFBundleIdentifier` 的
  `/tmp/wand-macos-taskboard-qa2/WandTaskBoardQA.app`），AppKit 日志只有
  `No windows open yet` → `has no restoredWindow, skipping ordering`，AX 查询 `count of windows` 恒为 0；
  `screencapture` 也不可用，因此没有截图或 AX 交互证据。
- 本机 `/Applications/Wand.app` 正在运行且仍是上一版 `4.71.2-debug.09220151`；换成待验收构建需要退出用户
  正在使用的客户端，本轮没有替代用户做这件事。
- 因此四视图渲染、拖拽落位、筛选 / 显示菜单、详情与新建面板、键盘与 VoiceOver 可达性**尚未端到端验收**；
  单元测试与真实数据契约只证明数据层与映射逻辑，不能代替界面验收。

更新到 `4.72.0-debug.09220703` 后建议人工点一遍：四视图切换与视图状态记忆、卡片拖到「处理中」是否自动派发、
拖进归档目录、直接拖到列表视图行、筛选 / 显示菜单、详情改标题（失焦即存）与描述（保存按钮）、
新建面板选 provider / model / 模式后创建。

## 产物

| 文件 | 字节 | SHA-256 |
| --- | ---: | --- |
| wand-v4.72.0-debug.09220703.dmg | 11886117 | 11d10fc44fb1136d45b4bce8aaa85842664a86d25cc1584d252b98b755c72549 |
| wand-v4.72.0-debug.09220703.zip | 9242925 | 8d4f5dec6791b2d503faa3781d8d239bced6873b8315796850a8d05bed709d3b |
| wand-v4.72.0-debug.09220703.update.json | 396 | 1652171c8c8cdebf4ce6da3bcf91549c73b96c63b18943b3e3a6ca86fe5d3103 |
