import Combine
import SwiftUI
import UniformTypeIdentifiers

/// 原生聊天视图：结构化消息渲染 + 原生输入栏 + 权限审批卡片。
/// 输入栏放在 safeAreaInset(edge: .bottom)。
struct ChatView: View {
    private let sessionId: String
    private let api: WandAPI

    @StateObject private var store: ChatStore
    @StateObject private var speech = SpeechRecognizerService()
    @State private var draft = ""
    @State private var showQuickCommit = false
    @State private var followsLatest = true
    @State private var historyExpanded = false
    @State private var expandedCurrentReplyAbsoluteIndex = -1
    @State private var observedLastUserAbsoluteIndex = Int.min
    @State private var observedLatestAssistantAbsoluteIndex = Int.min
    @State private var voicePressed = false
    @State private var voiceCanceling = false
    @State private var showFileImporter = false
    @State private var showModelThinkingPanel = false
    @State private var showSessionSettingsPanel = false
    @State private var uploadingAttachments = false
    @State private var gitStatus: GitStatusResult?
    /// 轻点 vs 按住的计时器：按满阈值才开始录音，阈值内松手按轻点处理。
    @State private var voiceHoldWork: DispatchWorkItem?
    /// 停止任务二次确认弹窗开关：点停止按钮先弹确认，避免误触中断正在跑的任务。
    @State private var showStopConfirm = false
    @FocusState private var inputFocused: Bool

    init(sessionId: String, api: WandAPI) {
        self.sessionId = sessionId
        self.api = api
        _store = StateObject(wrappedValue: ChatStore(sessionId: sessionId, api: api))
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            if store.loading {
                ProgressView().tint(Theme.brand)
            } else if let error = store.loadError {
                VStack(spacing: 12) {
                    Text("加载失败").font(.headline).foregroundColor(Theme.textPrimary)
                    Text(error).font(.footnote).foregroundColor(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .padding(32)
            } else if store.isStructured && store.messages.isEmpty && !store.isResponding {
                sessionLaunchPanel
            } else {
                messageList
            }
        }
        // 点消息区任意空白处收起键盘；输入栏在 safeAreaInset 里不受影响，
        // 点发送 / 权限按钮不会误收。
        .dismissKeyboardOnTap()
        .navigationTitle("")
        .toolbar {
            ToolbarItem(placement: .principal) {
                navigationStatus
            }
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 12) {
                    gitChangesButton
                    if store.isStructured {
                        sessionSettingsMenu
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) { bottomBar }
        .sheet(isPresented: $showQuickCommit) {
            GitQuickCommitView(sessionId: sessionId, api: api)
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true,
            onCompletion: handlePickedAttachments
        )
        .onAppear {
            store.start()
            refreshGitStatus()
        }
        .onChange(of: showQuickCommit) { showing in
            if !showing { refreshGitStatus() }
        }
        .onDisappear { store.shutdown() }
        .overlay(alignment: .top) { toastView }
    }

    // MARK: - 消息列表

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if store.canLoadEarlier {
                        Button(action: { store.loadEarlier() }) {
                            loadingEarlierRow(store.loadingEarlier ? "正在加载更早消息…" : "加载更早的消息")
                        }
                        .buttonStyle(.plain)
                        .disabled(store.loadingEarlier)
                    }
                    ForEach(Array(groupedMessageItems.enumerated()), id: \.offset) { _, item in
                        messageItemView(item, proxy: proxy)
                    }
                    if store.isResponding {
                        respondingIndicator
                    }
                    Color.clear.frame(height: 1).id("chat-bottom")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 6)
            }
                .simultaneousGesture(
                    DragGesture(minimumDistance: 8)
                        .onChanged { value in
                            // 仅用户明确向下拖动、准备查看更早消息时暂停跟随。
                            // 旧逻辑任何轻微拖动都会永久关掉跟随，收键盘或触摸
                            // 列表后，新回复就只能靠右下角按钮才能看到。
                            if value.translation.height > 18 {
                                followsLatest = false
                            }
                        }
                )
                .overlay(alignment: .bottomTrailing) {
                    if !followsLatest {
                        jumpToLatestButton(proxy)
                    }
                }
                .onAppear {
                    syncReplyFoldState(force: true)
                    pinToBottom(proxy)
                }
                .onReceive(store.$messages.dropFirst()) { _ in
                    syncReplyFoldState()
                    scrollToLatestIfFollowing(proxy)
                }
                .onChange(of: store.isResponding) { _ in
                    scrollToLatestIfFollowing(proxy)
                }
                .onChange(of: store.loading) { loading in
                    if !loading { pinToBottom(proxy) }
                }
        }
    }

    @ViewBuilder private func messageItemView(_ item: MessageDisplayItem, proxy: ScrollViewProxy) -> some View {
        switch item {
        case .turn(let index, let turn):
            let absoluteIndex = store.loadedOffset + index
            let controlsCurrentReplyExpansion = turn.role != "user"
                && index == latestAssistantTurnIndex
                && absoluteIndex == absoluteLatestAssistantTurnIndex
            TurnView(
                turn: turn,
                isLastTurn: index == store.messages.count - 1,
                isResponding: store.isResponding,
                currentReplyExpandedOverride: controlsCurrentReplyExpansion
                    ? (expandedCurrentReplyAbsoluteIndex == absoluteIndex)
                    : nil,
                turnIndex: index,
                historyBoundary: lastUserTurnIndex,
                onUserExpand: {
                    followsLatest = false
                },
                onCurrentReplyExpandedChange: { expanded in
                    if controlsCurrentReplyExpansion {
                        expandedCurrentReplyAbsoluteIndex = expanded ? absoluteIndex : -1
                    }
                },
                onCurrentReplyExpandToBottom: {
                    if controlsCurrentReplyExpansion {
                        expandCurrentReplyToBottom(proxy, absoluteIndex: absoluteIndex)
                    }
                },
                askSelections: store.askUserSelections,
                onAskToggle: { toolUseId, qIdx, optIdx, multi in
                    store.toggleAskOption(
                        toolUseId: toolUseId, questionIndex: qIdx,
                        optionIndex: optIdx, multiSelect: multi
                    )
                },
                onAskSubmit: { toolUseId, answerText in
                    followsLatest = true
                    store.submitAskUser(toolUseId: toolUseId, answerText: answerText)
                }
            )
        case .explorationGroup(let tools, let lastTurnIndex):
            ExplorationGroupCard(
                tools: tools,
                running: store.isResponding
                    && lastTurnIndex == store.messages.count - 1
                    && tools.contains { $0.result == nil }
            )
        }
    }

    private var groupedMessageItems: [MessageDisplayItem] {
        groupExplorationTurns(store.messages)
    }

    private var lastUserTurnIndex: Int {
        store.messages.lastIndex { $0.role == "user" } ?? -1
    }

    private var absoluteLastUserTurnIndex: Int {
        lastUserTurnIndex >= 0 ? store.loadedOffset + lastUserTurnIndex : -1
    }

    private var latestAssistantTurnIndex: Int {
        store.messages.last?.role == "user" ? -1 : store.messages.indices.last ?? -1
    }

    private var absoluteLatestAssistantTurnIndex: Int {
        latestAssistantTurnIndex >= 0 ? store.loadedOffset + latestAssistantTurnIndex : -1
    }

    private var historyItems: [MessageDisplayItem] {
        guard lastUserTurnIndex > 0 else { return [] }
        return groupedMessageItems.filter { messageItemTurnIndex($0) < lastUserTurnIndex }
    }

    private var currentItems: [MessageDisplayItem] {
        guard lastUserTurnIndex >= 0 else { return groupedMessageItems }
        return groupedMessageItems.filter { messageItemTurnIndex($0) >= lastUserTurnIndex }
    }

    private var unloadedHistoryCount: Int {
        absoluteLastUserTurnIndex > 0 ? min(store.loadedOffset, absoluteLastUserTurnIndex) : 0
    }

    private var hasCollapsedHistory: Bool {
        !historyItems.isEmpty || unloadedHistoryCount > 0
    }

    private var collapsedHistoryCount: Int {
        historyItems.count + unloadedHistoryCount
    }

    private var historyPreview: String {
        guard lastUserTurnIndex > 0 else { return "" }
        for turn in store.messages.prefix(lastUserTurnIndex).reversed() {
            let text = turn.content.compactMap { block -> String? in
                guard case .text(let value, _) = block else { return nil }
                return value
            }
            .joined(separator: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            if !text.isEmpty { return text }
        }
        return ""
    }

    private func jumpToLatestButton(_ proxy: ScrollViewProxy) -> some View {
        Button {
            followsLatest = true
            historyExpanded = false
            pinToBottom(proxy, animated: true)
        } label: {
            Image(systemName: "arrow.down")
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 42, height: 42)
                .background(Circle().fill(Theme.brand))
                .overlay(Circle().stroke(Color.white.opacity(0.2), lineWidth: 1))
                .shadow(color: Color.black.opacity(0.22), radius: 8, y: 3)
        }
        .accessibilityLabel("回到最新消息并继续跟随")
        .padding(.trailing, 16)
        .padding(.bottom, 12)
        .transition(.scale(scale: 0.85).combined(with: .opacity))
    }

    private func toggleHistory(_ proxy: ScrollViewProxy) {
        let next = !historyExpanded
        historyExpanded = next
        if next {
            followsLatest = false
            expandedCurrentReplyAbsoluteIndex = -1
            store.loadEarlier()
        } else {
            followsLatest = true
            pinToBottom(proxy, animated: true)
        }
    }

    private func expandCurrentReplyToBottom(_ proxy: ScrollViewProxy, absoluteIndex: Int) {
        expandedCurrentReplyAbsoluteIndex = absoluteIndex
        historyExpanded = false
        followsLatest = true
        for delay in [0.05, 0.15, 0.35, 0.7] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard expandedCurrentReplyAbsoluteIndex == absoluteIndex else { return }
                proxy.scrollTo("chat-bottom", anchor: .bottom)
            }
        }
    }

    private func syncReplyFoldState(force: Bool = false) {
        let boundary = absoluteLastUserTurnIndex
        let latest = absoluteLatestAssistantTurnIndex
        if force || observedLastUserAbsoluteIndex != boundary {
            observedLastUserAbsoluteIndex = boundary
            observedLatestAssistantAbsoluteIndex = latest
            historyExpanded = false
            expandedCurrentReplyAbsoluteIndex = latest
        } else if observedLatestAssistantAbsoluteIndex != latest {
            observedLatestAssistantAbsoluteIndex = latest
            if latest > boundary {
                expandedCurrentReplyAbsoluteIndex = latest
            }
        }
    }

    private func scrollToLatestIfFollowing(_ proxy: ScrollViewProxy) {
        guard followsLatest else { return }
        // 流式更新会原地增高最后一条消息，首个 scrollTo 可能早于
        // LazyVStack 完成新高度布局；补一次短延迟即可稳定贴住底部。
        for delay in [0.0, 0.08] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard followsLatest else { return }
                proxy.scrollTo("chat-bottom", anchor: .bottom)
            }
        }
    }

    /// 打开会话时把列表钉到底部。LazyVStack 首帧尚未完成布局，单次 scrollTo
    /// 常停在半中间——立即滚一次，再按递增延迟补几次，直到布局稳定。
    private func pinToBottom(_ proxy: ScrollViewProxy, animated: Bool = false) {
        if animated {
            withAnimation(.easeOut(duration: 0.22)) {
                proxy.scrollTo("chat-bottom", anchor: .bottom)
            }
        } else {
            proxy.scrollTo("chat-bottom", anchor: .bottom)
        }
        for delay in [0.05, 0.15, 0.35, 0.7] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard followsLatest else { return }
                proxy.scrollTo("chat-bottom", anchor: .bottom)
            }
        }
    }

    private var respondingIndicator: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small).tint(Theme.brand)
            Text(store.currentTaskTitle ?? "正在思考…")
                .font(.system(size: 13))
                .foregroundColor(Theme.textSecondary)
                .lineLimit(1)
        }
        .padding(.vertical, 4)
    }

    private func loadingEarlierRow(_ title: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small).tint(Theme.brand)
            Text(title)
                .font(.system(size: 12))
                .foregroundColor(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    // MARK: - 顶部状态

    private var sessionLaunchPanel: some View {
        VStack(spacing: 18) {
            WandBrandMark(size: 52)
            Text(store.snapshot?.providerLabel ?? "结构化会话")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(Theme.textPrimary)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 24)
        .frame(maxWidth: 340)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Theme.surface)
                .shadow(color: Color.black.opacity(0.07), radius: 18, y: 7)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Theme.border, lineWidth: 1)
        )
        .padding(.horizontal, 24)
    }

    private func modelButton(id: String?, label: String) -> some View {
        Button {
            store.setModel(id)
        } label: {
            if store.selectedModel == id {
                Label(label, systemImage: "checkmark")
            } else {
                Text(label)
            }
        }
    }

    private var thinkingLevels: [ThinkingEffortOption] {
        thinkingEffortOptions(
            provider: store.snapshot?.provider ?? "claude",
            selectedModel: store.selectedModel,
            defaultModel: store.defaultModel,
            models: store.availableModels
        )
    }

    private func thinkingShortLabel(_ id: String) -> String {
        thinkingLevels.first { $0.id == id }?.shortLabel ?? "关"
    }

    private var navigationStatus: some View {
        VStack(spacing: 0) {
            Text(latestUserMessage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 190)
            Text(store.snapshot?.cwd ?? "未设置工作目录")
                .font(.system(size: 8, design: .monospaced))
                .foregroundColor(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 190)
        }
        .accessibilityElement(children: .combine)
    }

    private var latestUserMessage: String {
        for turn in store.messages.reversed() where turn.role == "user" {
            let text = turn.content.compactMap { block -> String? in
                guard case .text(let value, _) = block else { return nil }
                return value
            }
            .joined(separator: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            if !text.isEmpty { return text }
        }
        return store.snapshot?.displayTitle ?? "对话详情"
    }

    // MARK: - 底部栏（权限卡 + 队列 + 输入框）

    /// 输入栏上方悬浮的待办进度条数据：当前 turn 的 todos，全部完成后隐藏（对齐 Web）。
    /// 同时在会话不再 running（turn 已结束 / idle / exited）时隐藏——模型常忘了发最后
    /// 一条全 completed 的更新，否则进度条会卡在「5/6」干瞪眼（对齐 Web sessionActive）。
    private var visibleTodos: [TodoItem] {
        guard store.status == "running" else { return [] }
        let todos = TodoItem.currentTodos(in: store.messages)
        guard !todos.isEmpty else { return [] }
        let completed = todos.filter { $0.status == "completed" }.count
        return completed == todos.count ? [] : todos
    }

    private var bottomBar: some View {
        VStack(spacing: 0) {
            if voicePressed || speech.isRecording {
                voiceBubble
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
                    .transition(.opacity)
            }
            if !visibleTodos.isEmpty {
                TodoProgressBar(todos: visibleTodos)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            }
            if store.pendingEscalation != nil || store.legacyPermissionPrompt != nil {
                PermissionCard(
                    escalation: store.pendingEscalation,
                    legacy: store.legacyPermissionPrompt,
                    onResolve: { store.resolvePermission($0) }
                )
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if !store.queuedMessages.isEmpty {
                QueueBar(store: store)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            }
            inputBar
        }
        .background(
            Theme.background
                .opacity(0.97)
                .ignoresSafeArea(edges: .bottom)
        )
        .animation(.easeInOut(duration: 0.2), value: store.pendingEscalation)
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            composerActionsMenu
            if store.isStructured {
                modelThinkingChip
            }
            composerField
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .confirmationDialog(
            "确定要停止当前正在运行的任务吗？",
            isPresented: $showStopConfirm,
            titleVisibility: .visible
        ) {
            Button("停止", role: .destructive) { store.stopResponding() }
            Button("取消", role: .cancel) {}
        }
    }

    private var composerField: some View {
        HStack(alignment: .bottom, spacing: 4) {
            growingTextField
                .focused($inputFocused)
                .padding(.leading, 10)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity)

            if store.isResponding {
                Button(action: { showStopConfirm = true }) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(Theme.danger))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("停止任务")
            }
            composerVoiceButton
            Button(action: sendDraft) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 38, height: 38)
                    .background(
                        Circle().fill(canSend ? Theme.brand : Theme.brand.opacity(0.4))
                    )
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .accessibilityLabel("发送")
            .padding(.trailing, 3)
        }
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Theme.border, lineWidth: 1)
        )
        .frame(maxWidth: .infinity)
    }

    private var composerVoiceButton: some View {
        Image(systemName: voicePressed ? "waveform" : "mic")
            .font(.system(size: 18, weight: .semibold))
            .foregroundColor(voiceCanceling ? Theme.danger : (voicePressed ? Theme.brand : Theme.textSecondary))
            .frame(width: 38, height: 38)
            .background(Circle().fill(Theme.brand.opacity(0.10)))
            .frame(width: 44, height: 44)
            .contentShape(Circle())
            .gesture(voiceTapOrHoldGesture(onTap: { inputFocused = true }))
            .accessibilityLabel("语音输入")
            .accessibilityValue(voicePressed ? "正在录音" : "长按录音")
    }

    private var modelThinkingChip: some View {
        Button {
            showModelThinkingPanel = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "cpu")
                    .font(.system(size: 11, weight: .semibold))
                Text(modelThinkingText)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 116)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .opacity(0.65)
            }
            .foregroundColor(thinkingTint)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(Capsule().fill(thinkingTint.opacity(0.10)))
            .overlay(Capsule().stroke(thinkingTint.opacity(0.22), lineWidth: 1))
        }
        .accessibilityLabel("模型与思考深度")
        .buttonStyle(.plain)
        .popover(isPresented: $showModelThinkingPanel, arrowEdge: .bottom) {
            modelThinkingPanel
        }
    }

    private var modelThinkingText: String {
        "\(shortModelLabel) · \(thinkingShortLabel(store.thinkingEffort))"
    }

    private var shortModelLabel: String {
        guard let selected = store.selectedModel, !selected.isEmpty, selected != "default" else {
            return "默认"
        }
        let full = store.availableModels.first(where: { $0.id == selected })?.label ?? selected
        let base: String
        if let idx = full.firstIndex(where: { $0 == "（" || $0 == "(" }) {
            base = String(full[..<idx]).trimmingCharacters(in: .whitespaces)
        } else {
            base = full
        }
        let leaf = base.split(separator: "/").last.map(String.init) ?? base
        let lower = leaf.lowercased()
        if lower.contains("opus") { return "Opus" }
        if lower.contains("sonnet") { return "Sonnet" }
        if lower.contains("haiku") { return "Haiku" }
        if lower.contains("gpt-5") { return "GPT-5" }
        if lower.contains("gpt-4") { return "GPT-4" }
        return leaf.count > 12 ? String(leaf.prefix(10)) + "…" : leaf
    }

    private var thinkingTint: Color {
        switch store.thinkingEffort {
        case "standard": return .green
        case "deep": return .orange
        case "max": return Theme.danger
        default: return Theme.brand
        }
    }

    private var sessionSettingsMenu: some View {
        Button {
            showSessionSettingsPanel = true
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Theme.brand)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("会话设置")
        .popover(isPresented: $showSessionSettingsPanel, arrowEdge: .bottom) {
            modelThinkingPanel
        }
    }

    private var modelThinkingPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Menu {
                modelButton(id: nil, label: "默认")
                ForEach(store.availableModels.filter { $0.id != "default" }) { model in
                    modelButton(id: model.id, label: model.label)
                }
            } label: {
                HStack {
                    Label("模型", systemImage: "cpu")
                    Spacer()
                    Text(shortModelLabel).font(.system(.caption, design: .monospaced))
                    Image(systemName: "chevron.up.chevron.down").font(.caption2)
                }
                .foregroundColor(Theme.textPrimary)
                .contentShape(Rectangle())
            }
            Divider()
            ThinkingEffortSlider(
                options: thinkingLevels,
                selection: store.thinkingEffort,
                accent: thinkingTint,
                onSelect: store.setThinkingEffort
            )
        }
        .padding(14)
        .frame(width: 286)
    }

    private var gitChangesButton: some View {
        Button {
            showQuickCommit = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.branch")
                Text("~\(gitChangeCounts.modified)")
                Text("-\(gitChangeCounts.deleted)")
                    .foregroundColor(Theme.danger)
                Text("+\(gitChangeCounts.added)")
                    .foregroundColor(.green)
            }
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundColor(Theme.textSecondary)
        }
        .accessibilityLabel(
            "Git 修改 \(gitChangeCounts.modified)，删除 \(gitChangeCounts.deleted)，新增 \(gitChangeCounts.added)"
        )
    }

    private var gitChangeCounts: (modified: Int, deleted: Int, added: Int) {
        var counts = (modified: 0, deleted: 0, added: 0)
        for file in gitStatus?.files ?? [] {
            let status = file.status.uppercased()
            if status.contains("?") || status.contains("A") {
                counts.added += 1
            } else if status.contains("D") {
                counts.deleted += 1
            } else {
                counts.modified += 1
            }
        }
        return counts
    }

    private func refreshGitStatus() {
        Task {
            gitStatus = try? await api.gitStatus(sessionId: sessionId)
        }
    }

    private var composerActionsMenu: some View {
        Menu {
            Button {
                showFileImporter = true
            } label: {
                Label("上传附件", systemImage: "paperclip")
            }
            .disabled(uploadingAttachments)
        } label: {
            if uploadingAttachments {
                ProgressView()
                    .controlSize(.small)
                    .tint(Theme.textSecondary)
                    .frame(width: 38, height: 38)
            } else {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(Theme.surface))
                    .overlay(Circle().stroke(Theme.border, lineWidth: 1))
            }
        }
        .accessibilityLabel("更多操作")
    }

    private func handlePickedAttachments(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, !urls.isEmpty else {
            if case .failure(let error) = result { store.toast = error.localizedDescription }
            return
        }
        uploadingAttachments = true
        Task {
            defer { uploadingAttachments = false }
            do {
                let files = try await api.uploadAttachments(id: sessionId, urls: urls)
                let paths = files.map(\.savedPath).joined(separator: "\n")
                let prefix = "[附件已上传，请查看以下文件:\n\(paths)\n]\n\n"
                draft = prefix + draft
                store.toast = "已上传 \(files.count) 个附件"
            } catch {
                store.toast = error.localizedDescription
            }
        }
    }

    /// iOS 16+ / macOS 13+ 用多行自增高输入框；旧系统退化为单行。
    /// Enter 发送(走 onSubmit),Shift+Enter 走 multi-line newline 行为(由 TextField axis
    /// 默认处理:macOS 14+ 区分 Enter 提交 / Shift+Enter 换行,这里再显式做一次修饰键判定,
    /// 避免老系统回车直接清空草稿但没发出去)。
    @ViewBuilder private var growingTextField: some View {
        if #available(iOS 16.0, macOS 13.0, *) {
            TextField(composerPlaceholder, text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .font(.system(size: 16))
                .onSubmit { handleReturnKey(shift: false) }
        } else {
            TextField(composerPlaceholder, text: $draft)
                .font(.system(size: 16))
                .onSubmit { handleReturnKey(shift: false) }
        }
    }

    private var composerPlaceholder: String {
        if voicePressed {
            return voiceCanceling ? "松开手指，取消输入" : "松开结束 · 上滑取消"
        }
        return "输入消息"
    }

    /// 拦截回车:无修饰键 → 发送;带 Shift → 插入换行(老系统回退路径)。
    /// 用 NSApp.currentEvent 读 modifier,因为 onSubmit 回调里没有直接拿到事件。
    private func handleReturnKey(shift: Bool) {
        if shift {
            // Shift+Enter 期望换行;TextField 在多行模式下默认会插入,这里不进 sendDraft。
            return
        }
        sendDraft()
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func sendDraft() {
        guard canSend else { return }
        // 多行 TextField 触发的 onSubmit 可能在草稿末尾多带一个换行(回车字符先于 onSubmit
        // 提交落进 draft),trim 一下避免发出去的消息带尾换行。
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        followsLatest = true
        expandedCurrentReplyAbsoluteIndex = -1
        store.send(text: text)
    }

    // MARK: - 按住说话（端侧语音识别）

    /// 上滑超过该距离进入「松开取消」态（对齐 Web 端 VOICE_CANCEL_THRESHOLD）。
    private static let voiceCancelThreshold: CGFloat = 60

    /// 轻点 vs 按住的分界：按住超过该时长进入录音，否则按轻点处理。
    private static let voiceHoldThreshold: TimeInterval = 0.3

    /// 轻点 / 按住二分手势：按满阈值 → 开始录音（移动驱动上滑取消、松手提交）；
    /// 阈值内松手 → onTap()。
    private func voiceTapOrHoldGesture(onTap: @escaping () -> Void) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if voiceHoldWork == nil && !voicePressed {
                    // 手指刚按下：起计时，按满阈值才真正开始录音。
                    let work = DispatchWorkItem {
                        voiceHoldWork = nil
                        startVoiceRecording()
                    }
                    voiceHoldWork = work
                    DispatchQueue.main.asyncAfter(
                        deadline: .now() + Self.voiceHoldThreshold, execute: work
                    )
                }
                if voicePressed {
                    voiceCanceling = value.translation.height < -Self.voiceCancelThreshold
                }
            }
            .onEnded { _ in
                if let work = voiceHoldWork {
                    // 阈值内松手 → 轻点。
                    work.cancel()
                    voiceHoldWork = nil
                    onTap()
                    return
                }
                let cancelled = voiceCanceling
                voicePressed = false
                voiceCanceling = false
                speech.stop(cancelled: cancelled) { text in
                    appendTranscriptToDraft(text)
                }
            }
    }

    /// 按满阈值进入录音态（原「按下立即录音」交互的主体）。
    private func startVoiceRecording() {
        guard !voicePressed else { return }
        voicePressed = true
        voiceCanceling = false
        speech.start { message in
            store.toast = message
            voicePressed = false
            voiceCanceling = false
        }
    }

    /// 识别文本追加进草稿（不覆盖已有内容，对齐 Web 端 commitVoiceTranscript）。
    private func appendTranscriptToDraft(_ text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        var existing = draft
        while let last = existing.unicodeScalars.last,
              CharacterSet.whitespacesAndNewlines.contains(last) {
            existing.unicodeScalars.removeLast()
        }
        draft = existing.isEmpty ? clean : existing + " " + clean
    }

    /// 输入栏上方的实时转写气泡。
    private var voiceBubble: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: voiceCanceling ? "xmark.circle.fill" : "waveform.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(voiceCanceling ? Theme.danger : Theme.brand)
                Text(voiceCanceling
                     ? "松开手指，取消输入"
                     : (speech.transcript.isEmpty ? "正在聆听…" : speech.transcript))
                    .font(.system(size: 14))
                    .foregroundColor(
                        voiceCanceling
                            ? Theme.danger
                            : (speech.transcript.isEmpty ? Theme.textSecondary : Theme.textPrimary)
                    )
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            if !voiceCanceling {
                HStack(spacing: 6) {
                    Text(speech.usingOnDevice ? "端侧识别" : "在线识别")
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Theme.brand.opacity(0.12)))
                        .foregroundColor(Theme.brand)
                    Text("松开填入输入框 · 上滑取消")
                        .foregroundColor(Theme.textSecondary)
                }
                .font(.system(size: 11, weight: .medium))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.surface)
                .shadow(color: Color.black.opacity(0.1), radius: 6, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(voiceCanceling ? Theme.danger.opacity(0.55) : Theme.border, lineWidth: 1)
        )
    }

    // MARK: - Toast

    @ViewBuilder private var toastView: some View {
        if let toast = store.toast {
            Text(toast)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Capsule().fill(Color.black.opacity(0.78)))
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) {
                        if store.toast == toast { store.toast = nil }
                    }
                }
        }
    }
}

// MARK: - 单条消息

private struct HistorySummaryStrip: View {
    let count: Int
    let preview: String
    let expanded: Bool
    let onToggle: () -> Void

    var body: some View {
        Button {
            onToggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .rotationEffect(.degrees(expanded ? 90 : -90))
                    .foregroundColor(Theme.textSecondary)
                Text("已收起 \(count) 段上文")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
                if !preview.isEmpty {
                    Text(preview)
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
                Text(expanded ? "收起" : "展开")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Theme.brand)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Capsule().fill(Theme.surface))
            .overlay(Capsule().stroke(Theme.border, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// 工具调用与结果在渲染层配成一张卡片（对齐 Web 端 buildToolResultMap / Android pairToolBlocks）。
private enum DisplayItem {
    case plain(ContentBlock)
    case tool(
        id: String, name: String, description: String?,
        input: [String: JSONValue], subagent: SubagentMeta?,
        result: ToolResultInfo?
    )
    case explorationGroup([ExplorationToolItem])
}

private struct ActivityGroup: Identifiable {
    let id: String
    let summary: String
    let items: [DisplayItem]
    let running: Bool
}

private enum SegmentRenderItem {
    case item(Int, DisplayItem)
    case activity(ActivityGroup)
}

private enum MessageDisplayItem {
    case turn(index: Int, ConversationTurn)
    case explorationGroup(tools: [ExplorationToolItem], lastTurnIndex: Int)
}

private func messageItemTurnIndex(_ item: MessageDisplayItem) -> Int {
    switch item {
    case .turn(let index, _): return index
    case .explorationGroup(_, let lastTurnIndex): return lastTurnIndex
    }
}

private struct ExplorationToolItem {
    let id: String
    let name: String
    let description: String?
    let input: [String: JSONValue]
    let subagent: SubagentMeta?
    let result: ToolResultInfo?
}

/// 将相邻、且内容完全由只读探索工具组成的 assistant turn 跨消息合并。
/// 用户消息、正式文本、编辑/命令等操作都会立即终止分组。
private func groupExplorationTurns(_ turns: [ConversationTurn]) -> [MessageDisplayItem] {
    var items: [MessageDisplayItem] = []
    var pendingTools: [ExplorationToolItem] = []
    var pendingLastIndex = -1

    func flushPending() {
        guard !pendingTools.isEmpty else { return }
        items.append(.explorationGroup(tools: pendingTools, lastTurnIndex: pendingLastIndex))
        pendingTools.removeAll(keepingCapacity: true)
        pendingLastIndex = -1
    }

    for (index, turn) in turns.enumerated() {
        if let tools = explorationToolsOnly(in: turn) {
            pendingTools.append(contentsOf: tools)
            pendingLastIndex = index
        } else {
            flushPending()
            items.append(.turn(index: index, turn))
        }
    }
    flushPending()
    return items
}

private func explorationToolsOnly(in turn: ConversationTurn) -> [ExplorationToolItem]? {
    guard turn.role == "assistant" else { return nil }
    var tools: [ExplorationToolItem] = []
    for item in pairToolBlocks(turn.content) {
        switch item {
        case .explorationGroup(let group):
            tools.append(contentsOf: group)
        case .tool(let id, let name, let description, let input, let subagent, let result)
            where isExplorationTool(name):
            tools.append(ExplorationToolItem(
                id: id, name: name, description: description,
                input: input, subagent: subagent, result: result
            ))
        default:
            return nil
        }
    }
    return tools.isEmpty ? nil : tools
}

/// 配对后挂在工具卡上的结果。
struct ToolResultInfo {
    let text: String
    let isError: Bool
    let truncated: Bool
}

/// 优先按 tool_use_id 精确配对（并行工具调用时顺序会交错）；
/// id 缺失时退回「紧随其后的第一个结果」邻接兜底；没配上的 ToolResult 原样透传。
private func pairToolBlocks(_ content: [ContentBlock]) -> [DisplayItem] {
    var paired: [DisplayItem] = []
    var consumed = Set<Int>()
    for (i, block) in content.enumerated() {
        if consumed.contains(i) { continue }
        guard case .toolUse(let id, let name, let description, let input, let subagent) = block else {
            paired.append(.plain(block))
            continue
        }
        var resultIndex = -1
        if !id.isEmpty {
            // 1) 全局按 tool_use_id 精确配对
            for j in (i + 1)..<content.count where !consumed.contains(j) {
                if case .toolResult(let rid, _, _, _, _) = content[j], rid == id {
                    resultIndex = j
                    break
                }
            }
        }
        if resultIndex < 0 {
            // 2) 邻接兜底：中间隔着下一个 ToolUse 视为无结果；id 双方都有但不匹配时不抢配。
            for j in (i + 1)..<content.count where !consumed.contains(j) {
                if case .toolUse = content[j] { break }
                if case .toolResult(let rid, _, _, _, _) = content[j] {
                    if rid.isEmpty || id.isEmpty { resultIndex = j }
                    break
                }
            }
        }
        var result: ToolResultInfo?
        if resultIndex >= 0, case .toolResult(_, let text, let isError, let truncated, _) = content[resultIndex] {
            consumed.insert(resultIndex)
            result = ToolResultInfo(text: text, isError: isError, truncated: truncated)
        }
        paired.append(.tool(
            id: id, name: name, description: description,
            input: input, subagent: subagent, result: result
        ))
    }
    return collapseConsecutiveExplorationTools(paired)
}

/// 连续读取、搜索、网页获取通常只是模型探索上下文，不需要逐张占满对话流。
/// 至少连续两次才合并，单次操作仍保留完整工具卡。
private func collapseConsecutiveExplorationTools(_ paired: [DisplayItem]) -> [DisplayItem] {
    var items: [DisplayItem] = []
    var exploration: [ExplorationToolItem] = []

    func flushExploration() {
        if exploration.count >= 2 {
            items.append(.explorationGroup(exploration))
        } else if let tool = exploration.first {
            items.append(.tool(
                id: tool.id, name: tool.name, description: tool.description,
                input: tool.input, subagent: tool.subagent, result: tool.result
            ))
        }
        exploration.removeAll(keepingCapacity: true)
    }

    for item in paired {
        if case .tool(let id, let name, let description, let input, let subagent, let result) = item,
           isExplorationTool(name) {
            exploration.append(ExplorationToolItem(
                id: id, name: name, description: description,
                input: input, subagent: subagent, result: result
            ))
        } else {
            flushExploration()
            items.append(item)
        }
    }
    flushExploration()
    return items
}

private func isExplorationTool(_ name: String) -> Bool {
    let lower = name.lowercased()
    return lower.hasPrefix("read")
        || lower.hasPrefix("grep")
        || lower.hasPrefix("glob")
        || lower.hasPrefix("search")
        || lower.hasPrefix("find")
        || lower.contains("websearch")
        || lower.contains("webfetch")
        || lower == "todoread"
}

private func collapseActivityItems(
    _ items: [DisplayItem],
    isLastTurn: Bool,
    isResponding: Bool
) -> [SegmentRenderItem] {
    var renderItems: [SegmentRenderItem] = []
    var pending: [DisplayItem] = []
    var pendingStartIndex = -1

    func flushPending() {
        guard !pending.isEmpty else { return }
        let groupItems = pending
        let running = groupItems.contains { isDisplayItemRunning($0, isLastTurn: isLastTurn, isResponding: isResponding) }
        renderItems.append(.activity(ActivityGroup(
            id: activityGroupKey(groupItems, startIndex: pendingStartIndex),
            summary: activitySummary(groupItems, running: running),
            items: groupItems,
            running: running
        )))
        pending.removeAll(keepingCapacity: true)
        pendingStartIndex = -1
    }

    for (index, item) in items.enumerated() {
        if isCollapsibleActivityItem(item) {
            if pending.isEmpty { pendingStartIndex = index }
            pending.append(item)
        } else {
            flushPending()
            renderItems.append(.item(index, item))
        }
    }
    flushPending()
    return renderItems
}

private func activityGroupKey(_ items: [DisplayItem], startIndex: Int) -> String {
    let first = items.first.map(displayItemStableKey) ?? "empty"
    return "\(startIndex):\(first)"
}

private func displayItemStableKey(_ item: DisplayItem) -> String {
    switch item {
    case .tool(let id, let name, _, _, _, _):
        return "tool:\(id.isEmpty ? name : id)"
    case .explorationGroup(let tools):
        return "explore:\(tools.first?.id ?? "\(tools.count)")"
    case .plain(let block):
        switch block {
        case .thinking(let text, let subagent):
            return "thinking:\(subagent?.taskId ?? String(text.prefix(24)))"
        case .toolResult(let id, let text, _, _, _):
            return "result:\(id.isEmpty ? String(text.prefix(24)) : id)"
        case .text(let text, _):
            return "text:\(String(text.prefix(24)))"
        case .toolUse(let id, let name, _, _, _):
            return "plain-tool:\(id.isEmpty ? name : id)"
        case .unknown:
            return "unknown"
        }
    }
}

private func isCollapsibleActivityItem(_ item: DisplayItem) -> Bool {
    switch item {
    case .plain(let block):
        if case .text = block { return false }
        if case .unknown = block { return false }
        return true
    case .explorationGroup:
        return true
    case .tool(_, let name, _, _, _, _):
        return name != "AskUserQuestion"
    }
}

private func isDisplayItemRunning(_ item: DisplayItem, isLastTurn: Bool, isResponding: Bool) -> Bool {
    guard isLastTurn && isResponding else { return false }
    switch item {
    case .tool(_, _, _, _, _, let result):
        return result == nil
    case .explorationGroup(let tools):
        return tools.contains { $0.result == nil }
    case .plain(let block):
        if case .thinking = block { return true }
        return false
    }
}

private func activityTools(_ items: [DisplayItem]) -> [ExplorationToolItem] {
    items.flatMap { item -> [ExplorationToolItem] in
        switch item {
        case .tool(let id, let name, let description, let input, let subagent, let result):
            return [ExplorationToolItem(
                id: id, name: name, description: description,
                input: input, subagent: subagent, result: result
            )]
        case .explorationGroup(let tools):
            return tools
        case .plain:
            return []
        }
    }
}

private func activitySummary(_ items: [DisplayItem], running: Bool) -> String {
    let tools = activityTools(items)
    if items.count == 1, let tool = tools.first, tools.count == 1 {
        let prefix = running && tool.result == nil ? "正在" : "已"
        let detail = toolInputSummary(tool.description, tool.input)
        let label = activityVerb(tool.name)
        return detail.isEmpty ? "\(prefix)\(label)" : "\(prefix)\(label) \(detail)"
    }
    if items.count == 1, case .plain(let block)? = items.first {
        switch block {
        case .thinking:
            return running ? "正在思考" : "已思考"
        case .toolResult(_, _, let isError, _, _):
            return isError ? "有 1 条执行错误" : "已生成 1 条执行结果"
        default:
            return "已完成 1 项活动"
        }
    }

    let readCount = tools.filter { activityKind($0.name) == "read" }.count
    let commandCount = tools.filter { activityKind($0.name) == "command" }.count
    let searchCount = tools.filter { activityKind($0.name) == "search" }.count
    let editCount = tools.filter { activityKind($0.name) == "edit" }.count
    let webCount = tools.filter { activityKind($0.name) == "web" }.count
    let todoCount = tools.filter { activityKind($0.name) == "todo" }.count
    let otherToolCount = tools.count - readCount - commandCount - searchCount - editCount - webCount - todoCount
    let thinkingCount = items.filter {
        if case .plain(.thinking(_, _)) = $0 { return true }
        return false
    }.count
    let resultCount = items.filter {
        if case .plain(.toolResult(_, _, _, _, _)) = $0 { return true }
        return false
    }.count

    var parts: [String] = []
    if readCount > 0 { parts.append("浏览 \(readCount) 个文件") }
    if commandCount > 0 { parts.append("运行 \(commandCount) 条命令") }
    if searchCount > 0 { parts.append("搜索 \(searchCount) 次") }
    if editCount > 0 { parts.append("修改 \(editCount) 个文件") }
    if webCount > 0 { parts.append("访问 \(webCount) 个网页") }
    if todoCount > 0 { parts.append("更新 \(todoCount) 次待办") }
    if thinkingCount > 0 { parts.append("思考 \(thinkingCount) 段") }
    if resultCount > 0 { parts.append("生成 \(resultCount) 条结果") }
    if otherToolCount > 0 { parts.append("调用 \(otherToolCount) 个工具") }

    let prefix = running ? "正在" : "已"
    return parts.isEmpty ? "\(prefix)完成 \(items.count) 项活动" : prefix + parts.joined(separator: "，")
}

private func activityVerb(_ name: String) -> String {
    switch activityKind(name) {
    case "read": return "浏览"
    case "command": return "运行"
    case "search": return "搜索代码"
    case "edit": return "修改"
    case "web": return "访问网页"
    case "todo": return "更新待办"
    default: return toolLabel(name)
    }
}

private func activityKind(_ name: String) -> String {
    let lower = name.lowercased()
    if lower.hasPrefix("read") || lower.contains("notebook") { return "read" }
    if lower == "bash" || lower.contains("command") || lower.contains("shell") { return "command" }
    if lower.contains("grep") || lower.contains("glob") || lower.contains("search") || lower.contains("find") { return "search" }
    if lower.contains("edit") || lower.contains("write") { return "edit" }
    if lower.contains("web") || lower.contains("fetch") || lower.contains("http") { return "web" }
    if lower.contains("todo") { return "todo" }
    return "other"
}

private func toolInputSummary(_ description: String?, _ input: [String: JSONValue]) -> String {
    if let description, !description.isEmpty { return description }
    for key in ["command", "file_path", "path", "pattern", "query", "prompt", "url", "description"] {
        if let value = input[key] {
            let text = value.summaryText
            if !text.isEmpty { return text }
        }
    }
    if let first = input.first {
        return "\(first.key): \(first.value.summaryText)"
    }
    return ""
}

private struct AssistantReplyHeader: View {
    let collapsed: Bool
    let preview: String
    let onToggle: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button {
                onToggle()
            } label: {
                HStack(spacing: 8) {
                    ZStack {
                        Circle().fill(Theme.brand.opacity(0.14))
                        Image(systemName: "sparkles")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Theme.brand)
                    }
                    .frame(width: 24, height: 24)
                    Text("Wand")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                    if collapsed, !preview.isEmpty {
                        Text(preview)
                            .font(.system(size: 12))
                            .foregroundColor(Theme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(Theme.textSecondary)
                        .rotationEffect(.degrees(collapsed ? 0 : 180))
                }
                .padding(.vertical, 3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Rectangle()
                .fill(Theme.border.opacity(0.65))
                .frame(height: 0.5)
        }
    }
}

private func replyPreview(_ content: [ContentBlock]) -> String {
    let text = content.compactMap { block -> String? in
        guard case .text(let value, _) = block else { return nil }
        return value
    }
    .joined(separator: " ")
    .components(separatedBy: .whitespacesAndNewlines)
    .filter { !$0.isEmpty }
    .joined(separator: " ")
    if !text.isEmpty { return text }
    let toolCount = content.reduce(0) { total, block in
        if case .toolUse = block { return total + 1 }
        return total
    }
    return toolCount > 0 ? "\(toolCount) 个工具调用" : ""
}

private struct ActivitySummaryRow: View {
    let group: ActivityGroup
    let onClick: () -> Void

    var body: some View {
        Button {
            onClick()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: activityIconName(group.items))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(group.running ? Theme.brand : Theme.textSecondary)
                    .frame(width: 18)
                Text(group.summary)
                    .font(.system(size: 14))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(Theme.textSecondary)
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func activityIconName(_ items: [DisplayItem]) -> String {
        if let first = activityTools(items).first {
            let lower = first.name.lowercased()
            if lower.contains("bash") || lower.contains("command") { return "terminal" }
            if lower.contains("edit") || lower.contains("write") { return "pencil" }
            if lower.contains("read") { return "doc.text.magnifyingglass" }
            if lower.contains("grep") || lower.contains("glob") || lower.contains("search") { return "magnifyingglass" }
            if lower.contains("web") || lower.contains("fetch") { return "globe" }
            if lower.contains("task") || lower.contains("agent") { return "person.2" }
            return "wrench.and.screwdriver"
        }
        if case .plain(.thinking(_, _))? = items.first {
            return "brain"
        }
        return "doc.text"
    }
}

private struct ActivityDetailSheet<Content: View>: View {
    let group: ActivityGroup
    @ViewBuilder let itemView: (DisplayItem) -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("执行详情")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                Spacer()
                Text(group.summary)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Theme.surface))
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(group.items.enumerated()), id: \.offset) { _, item in
                        itemView(item)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 8)
            }
        }
        .padding(16)
        .frame(minWidth: 520, minHeight: 420)
        .background(Theme.background)
    }
}

private struct TurnView: View {
    let turn: ConversationTurn
    var isLastTurn: Bool
    var isResponding: Bool
    var currentReplyExpandedOverride: Bool?
    var turnIndex: Int
    var historyBoundary: Int
    var showHeader: Bool
    var showContent: Bool
    var onUserExpand: () -> Void
    var onCurrentReplyExpandedChange: (Bool) -> Void
    var onCurrentReplyExpandToBottom: () -> Void
    var askSelections: [String: AskUserSelectionState]
    var onAskToggle: (String, Int, Int, Bool) -> Void
    var onAskSubmit: (String, String) -> Void

    @State private var localCollapsed: Bool
    @State private var openActivityGroup: ActivityGroup?

    init(
        turn: ConversationTurn,
        isLastTurn: Bool = false,
        isResponding: Bool = false,
        currentReplyExpandedOverride: Bool? = nil,
        turnIndex: Int = -1,
        historyBoundary: Int = -1,
        showHeader: Bool = true,
        showContent: Bool = true,
        onUserExpand: @escaping () -> Void = {},
        onCurrentReplyExpandedChange: @escaping (Bool) -> Void = { _ in },
        onCurrentReplyExpandToBottom: @escaping () -> Void = {},
        askSelections: [String: AskUserSelectionState] = [:],
        onAskToggle: @escaping (String, Int, Int, Bool) -> Void = { _, _, _, _ in },
        onAskSubmit: @escaping (String, String) -> Void = { _, _ in }
    ) {
        self.turn = turn
        self.isLastTurn = isLastTurn
        self.isResponding = isResponding
        self.currentReplyExpandedOverride = currentReplyExpandedOverride
        self.turnIndex = turnIndex
        self.historyBoundary = historyBoundary
        self.showHeader = showHeader
        self.showContent = showContent
        self.onUserExpand = onUserExpand
        self.onCurrentReplyExpandedChange = onCurrentReplyExpandedChange
        self.onCurrentReplyExpandToBottom = onCurrentReplyExpandToBottom
        self.askSelections = askSelections
        self.onAskToggle = onAskToggle
        self.onAskSubmit = onAskSubmit
        _localCollapsed = State(initialValue: turnIndex >= 0 && historyBoundary >= 0 && turnIndex < historyBoundary)
        _openActivityGroup = State(initialValue: nil)
    }

    var body: some View {
        if turn.role == "user" {
            userBubble
        } else {
            assistantReply
        }
    }

    private var userText: String {
        var pieces: [String] = []
        for block in turn.content {
            if case .text(let text, _) = block { pieces.append(text) }
        }
        return pieces.joined(separator: "\n")
    }

    private var userBubble: some View {
        HStack {
            Spacer(minLength: 48)
            Text(userText)
                .font(.system(size: 16))
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Theme.brand)
                )
                .textSelection(.enabled)
        }
    }

    private var defaultCollapsed: Bool {
        turnIndex >= 0 && historyBoundary >= 0 && turnIndex < historyBoundary
    }

    private var shouldFoldCurrentReply: Bool {
        isLastTurn && turnIndex > historyBoundary
    }

    private var collapsed: Bool {
        if let currentReplyExpandedOverride {
            return !currentReplyExpandedOverride
        }
        return localCollapsed
    }

    private func setCollapsed(_ next: Bool) {
        if currentReplyExpandedOverride == nil {
            localCollapsed = next
        }
        onCurrentReplyExpandedChange(!next)
    }

    private var assistantReply: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showHeader {
                AssistantReplyHeader(
                    collapsed: collapsed,
                    preview: replyPreview(turn.content),
                    onToggle: {
                        let next = !collapsed
                        setCollapsed(next)
                        if !next {
                            if shouldFoldCurrentReply {
                                onCurrentReplyExpandToBottom()
                            } else {
                                onUserExpand()
                            }
                        }
                    }
                )
            }
            if showContent && (!showHeader || !collapsed) {
                assistantBlocks
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeInOut(duration: 0.16), value: collapsed)
        .onChange(of: historyBoundary) { _ in
            if currentReplyExpandedOverride == nil {
                localCollapsed = defaultCollapsed
            }
        }
    }

    private var assistantBlocks: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(renderItems.enumerated()), id: \.offset) { _, renderItem in
                switch renderItem {
                case .item(_, let item):
                    itemView(item)
                case .activity(let group):
                    ActivitySummaryRow(group: group) {
                        openActivityGroup = group
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(item: $openActivityGroup) { group in
            ActivityDetailSheet(group: group) { item in
                itemView(item)
            }
        }
    }

    private var pairedItems: [DisplayItem] {
        pairToolBlocks(turn.content)
    }

    private var renderItems: [SegmentRenderItem] {
        collapseActivityItems(pairedItems, isLastTurn: isLastTurn, isResponding: isResponding)
    }

    @ViewBuilder private func itemView(_ item: DisplayItem) -> some View {
        switch item {
        case .plain(let block):
            BlockView(block: block)
        case .tool(let id, let name, let description, let input, let subagent, let result):
            VStack(alignment: .leading, spacing: 4) {
                subagentTag(subagent)
                toolView(
                    id: id, name: name, description: description,
                    input: input, result: result
                )
            }
        case .explorationGroup(let tools):
            ExplorationGroupCard(
                tools: tools,
                running: isLastTurn && isResponding && tools.contains { $0.result == nil }
            )
        }
    }

    /// 工具卡分流（对齐 Web 端 renderToolUseCard）：
    /// AskUserQuestion → 交互卡；Edit/Write/MultiEdit → diff 卡；Bash → 终端卡；其余 → 通用卡。
    @ViewBuilder private func toolView(
        id: String, name: String, description: String?,
        input: [String: JSONValue], result: ToolResultInfo?
    ) -> some View {
        let questions = name == "AskUserQuestion" ? AskUserQuestion.parse(input: input) : []
        if !questions.isEmpty {
            AskUserQuestionCard(
                toolUseId: id,
                questions: questions,
                result: result,
                selection: askSelections[id] ?? AskUserSelectionState(),
                onToggle: { qIdx, optIdx, multi in onAskToggle(id, qIdx, optIdx, multi) },
                onSubmit: { answerText in onAskSubmit(id, answerText) }
            )
        } else if name == "Edit" || name == "Write" || name == "MultiEdit" {
            DiffCard(toolName: name, input: input, result: result)
        } else if name == "Bash" {
            TerminalCard(input: input, result: result, running: result == nil && isLastTurn && isResponding)
        } else {
            ToolUseCard(
                name: name, description: description, input: input,
                result: result, running: result == nil && isLastTurn && isResponding
            )
        }
    }

    @ViewBuilder private func subagentTag(_ meta: SubagentMeta?) -> some View {
        if let meta {
            HStack(spacing: 4) {
                Image(systemName: "person.2").font(.system(size: 10))
                Text(meta.taskDescription ?? meta.agentType ?? "子任务")
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundColor(Theme.brandStrong)
        }
    }
}

// MARK: - 内容块渲染

private struct BlockView: View {
    let block: ContentBlock

    var body: some View {
        switch block {
        case .text(let text, let subagent):
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    subagentTag(subagent)
                    MarkdownText(text: text)
                }
            }
        case .thinking(let thinking, _):
            if !thinking.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                CollapsibleSection(
                    icon: "brain",
                    title: "思考过程",
                    tint: Theme.textSecondary
                ) {
                    Text(thinking)
                        .font(.system(size: 13))
                        .italic()
                        .foregroundColor(Theme.textSecondary)
                        .textSelection(.enabled)
                }
            }
        case .toolUse(_, let name, let description, let input, let subagent):
            // 兜底：正常路径已在 TurnView 配对分流，这里处理极端的落单 ToolUse。
            VStack(alignment: .leading, spacing: 4) {
                subagentTag(subagent)
                ToolUseCard(name: name, description: description, input: input, result: nil, running: false)
            }
        case .toolResult(_, let text, let isError, let truncated, _):
            if !text.isEmpty {
                CollapsibleSection(
                    icon: isError ? "xmark.octagon" : "doc.text",
                    title: isError ? "执行出错" : "执行结果",
                    tint: isError ? Theme.danger : Theme.textSecondary
                ) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(text.count > 4000 ? String(text.prefix(4000)) + "\n…（已截断）" : text)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(isError ? Theme.danger : Theme.textPrimary)
                            .textSelection(.enabled)
                    }
                    if truncated {
                        Text("内容过长，已截断")
                            .font(.system(size: 11))
                            .foregroundColor(Theme.textSecondary)
                    }
                }
            }
        case .unknown:
            EmptyView()
        }
    }

    @ViewBuilder private func subagentTag(_ meta: SubagentMeta?) -> some View {
        if let meta {
            HStack(spacing: 4) {
                Image(systemName: "person.2").font(.system(size: 10))
                Text(meta.taskDescription ?? meta.agentType ?? "子任务")
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundColor(Theme.brandStrong)
        }
    }
}

/// 原生 Markdown 渲染：块级结构独立布局，内联标记交给 AttributedString。
private struct MarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    private enum Block {
        case paragraph(String)
        case heading(Int, String)
        case listItem(marker: String, text: String, indent: Int, checked: Bool?)
        case quote(String)
        case code(String, String?)
        case table(headers: [String], rows: [[String]])
        case divider
    }

    @ViewBuilder private func blockView(_ block: Block) -> some View {
        switch block {
        case .paragraph(let content):
            inlineText(content, size: 16)
        case .heading(let level, let content):
            inlineText(content, size: headingSize(level), weight: .semibold)
                .padding(.top, level <= 2 ? 3 : 1)
        case .listItem(let marker, let content, let indent, let checked):
            HStack(alignment: .top, spacing: 7) {
                Text(checked.map { $0 ? "☑" : "☐" } ?? marker)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(checked == true ? .green : Theme.brand)
                    .padding(.top, 2)
                inlineText(content, size: 16)
            }
            .padding(.leading, CGFloat(indent * 14))
        case .quote(let content):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Theme.brand)
                    .frame(width: 3)
                inlineText(content, size: 15, color: Theme.textSecondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.surface))
        case .code(let content, let language):
            VStack(alignment: .leading, spacing: 2) {
                if let language, !language.isEmpty {
                    Text(language)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Theme.textSecondary)
                        .padding(.leading, 10)
                        .padding(.top, 6)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(content)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(Theme.textPrimary)
                        .textSelection(.enabled)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                }
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
        case .table(let headers, let rows):
            markdownTable(headers: headers, rows: rows)
        case .divider:
            Divider().overlay(Theme.border).padding(.vertical, 3)
        }
    }

    private func markdownTable(headers: [String], rows: [[String]]) -> some View {
        ScrollView(.horizontal, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                tableRow(headers, header: true)
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    tableRow(normalizedRow(row, count: headers.count), header: false)
                        .background(index.isMultiple(of: 2) ? Theme.surface : Theme.background.opacity(0.45))
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Theme.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func tableRow(_ cells: [String], header: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { index, cell in
                Text(attributed(cell))
                    .font(.system(size: header ? 13 : 12, weight: header ? .semibold : .regular))
                    .foregroundColor(header ? Theme.textPrimary : Theme.textSecondary)
                    .tint(Theme.brand)
                    .textSelection(.enabled)
                    .frame(minWidth: 110, maxWidth: 190, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                    .background(header ? Theme.brand.opacity(0.09) : Color.clear)
                    .overlay(alignment: .trailing) {
                        if index < cells.count - 1 {
                            Divider().overlay(Theme.border)
                        }
                    }
            }
        }
        .overlay(alignment: .bottom) { Divider().overlay(Theme.border) }
    }

    private func normalizedRow(_ row: [String], count: Int) -> [String] {
        if row.count >= count { return Array(row.prefix(count)) }
        return row + Array(repeating: "", count: count - row.count)
    }

    private func inlineText(
        _ content: String,
        size: CGFloat,
        weight: Font.Weight = .regular,
        color: Color = Theme.textPrimary
    ) -> some View {
        Text(attributed(content))
            .font(.system(size: size, weight: weight))
            .foregroundColor(color)
            .tint(Theme.brand)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 21
        case 2: return 19
        case 3: return 17
        default: return 16
        }
    }

    private var blocks: [Block] {
        var result: [Block] = []
        var paragraph: [String] = []
        var code: [String] = []
        var fence: String?
        var language: String?

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            result.append(.paragraph(paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)))
            paragraph.removeAll()
        }
        func flushCode() {
            result.append(.code(code.joined(separator: "\n").trimmingCharacters(in: .newlines), language))
            code.removeAll()
            fence = nil
            language = nil
        }

        let lines = text.components(separatedBy: .newlines)
        var lineIndex = 0
        while lineIndex < lines.count {
            let rawLine = lines[lineIndex]
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if let fence {
                if trimmed.hasPrefix(fence) { flushCode() } else { code.append(rawLine) }
                lineIndex += 1
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                fence = String(trimmed.prefix(3))
                let suffix = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                language = suffix.isEmpty ? nil : suffix
                lineIndex += 1
                continue
            }
            if trimmed.isEmpty {
                flushParagraph()
                lineIndex += 1
                continue
            }
            if lineIndex + 1 < lines.count,
               let headers = tableCells(rawLine),
               isTableSeparator(lines[lineIndex + 1], columnCount: headers.count) {
                flushParagraph()
                var rows: [[String]] = []
                lineIndex += 2
                while lineIndex < lines.count, let row = tableCells(lines[lineIndex]), !row.isEmpty {
                    rows.append(row)
                    lineIndex += 1
                }
                result.append(.table(headers: headers, rows: rows))
                continue
            }
            let level = trimmed.prefix { $0 == "#" }.count
            if (1...6).contains(level), trimmed.dropFirst(level).hasPrefix(" ") {
                flushParagraph()
                result.append(.heading(level, String(trimmed.dropFirst(level + 1))))
                lineIndex += 1
                continue
            }
            let rule = trimmed.replacingOccurrences(of: " ", with: "")
            if ["---", "***", "___"].contains(rule) {
                flushParagraph()
                result.append(.divider)
                lineIndex += 1
                continue
            }
            if trimmed.hasPrefix(">") {
                flushParagraph()
                result.append(.quote(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)))
                lineIndex += 1
                continue
            }
            if let item = listItem(rawLine) {
                flushParagraph()
                result.append(item)
                lineIndex += 1
                continue
            }
            paragraph.append(rawLine)
            lineIndex += 1
        }
        if fence != nil { flushCode() } else { flushParagraph() }
        return result
    }

    private func tableCells(_ line: String) -> [String]? {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|") else { return nil }
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        let cells = trimmed.split(separator: "|", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
        return cells.count >= 2 ? cells : nil
    }

    private func isTableSeparator(_ line: String, columnCount: Int) -> Bool {
        guard let cells = tableCells(line), cells.count == columnCount else { return false }
        return cells.allSatisfy { cell in
            let marker = cell.replacingOccurrences(of: ":", with: "")
            return marker.count >= 3 && marker.allSatisfy { $0 == "-" }
        }
    }

    private func listItem(_ rawLine: String) -> Block? {
        let leading = rawLine.prefix { $0 == " " || $0 == "\t" }.count
        let indent = leading / 2
        let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
        var marker: String?
        var content: String?
        for prefix in ["- ", "* ", "+ "] where trimmed.hasPrefix(prefix) {
            marker = "•"
            content = String(trimmed.dropFirst(2))
        }
        if marker == nil, let end = trimmed.firstIndex(where: { $0 == "." || $0 == ")" }) {
            let digits = trimmed[..<end]
            let after = trimmed.index(after: end)
            if !digits.isEmpty, digits.allSatisfy({ $0.isNumber }), after < trimmed.endIndex, trimmed[after] == " " {
                marker = String(trimmed[...end])
                content = String(trimmed[trimmed.index(after: after)...])
            }
        }
        guard let marker, var content else { return nil }
        var checked: Bool?
        if content.lowercased().hasPrefix("[x] ") {
            checked = true
            content = String(content.dropFirst(4))
        } else if content.hasPrefix("[ ] ") {
            checked = false
            content = String(content.dropFirst(4))
        }
        return .listItem(marker: marker, text: content, indent: indent, checked: checked)
    }

    private func attributed(_ raw: String) -> AttributedString {
        if let parsed = try? AttributedString(
            markdown: raw,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        ) {
            return parsed
        }
        return AttributedString(raw)
    }
}

/// 工具名 → 中文标签；未识别的工具显示原名（对齐 Web 端 toolDisplayName）。
private func toolLabel(_ name: String) -> String {
    let lower = name.lowercased()
    if lower.contains("todo") { return "更新待办" }
    if lower.contains("websearch") { return "网页搜索" }
    if lower.contains("webfetch") || lower.contains("fetch") { return "网页获取" }
    if lower.contains("notebook") { return "编辑笔记本" }
    if lower.hasPrefix("multiedit") || lower.hasPrefix("edit") { return "编辑文件" }
    if lower.hasPrefix("write") { return "写入文件" }
    if lower.hasPrefix("read") { return "读取文件" }
    if lower.hasPrefix("grep") { return "搜索内容" }
    if lower.hasPrefix("glob") { return "查找文件" }
    if lower == "bash" || lower.contains("command") || lower.contains("shell") { return "执行命令" }
    if lower.hasPrefix("task") || lower.contains("agent") { return "子任务" }
    return name
}

/// 连续只读探索操作的紧凑进度卡。默认折叠，避免探索阶段淹没对话。
private struct ExplorationGroupCard: View {
    let tools: [ExplorationToolItem]
    let running: Bool

    @State private var expanded = false

    private var completedCount: Int { tools.filter { $0.result != nil }.count }
    private var failedCount: Int { tools.filter { $0.result?.isError == true }.count }
    private var progress: Double {
        guard !tools.isEmpty else { return 0 }
        return Double(completedCount) / Double(tools.count)
    }
    private var tint: Color {
        if failedCount > 0 { return Theme.danger }
        if running { return Theme.brand }
        return chatSuccess
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 11) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(tint.opacity(0.11))
                        if running {
                            ProgressView()
                                .controlSize(.small)
                                .tint(tint)
                        } else {
                            Image(systemName: "magnifyingglass.circle")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(tint)
                        }
                    }
                    .frame(width: 34, height: 34)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("探索上下文")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(Theme.textPrimary)
                            Spacer(minLength: 8)
                            Text("\(completedCount)/\(tools.count)")
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundColor(tint)
                        }
                        Text(activitySummary)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(Theme.textSecondary)
                            .lineLimit(1)
                        ProgressView(value: progress)
                            .tint(tint)
                    }

                    if failedCount > 0 {
                        Text("失败 \(failedCount)")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(Theme.danger)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Theme.danger.opacity(0.10)))
                    }
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(Theme.textSecondary)
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                Divider()
                    .overlay(Theme.border.opacity(0.7))
                    .padding(.horizontal, 12)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(tools.enumerated()), id: \.offset) { _, tool in
                        HStack(spacing: 8) {
                            Image(systemName: toolStatusIcon(tool))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(toolStatusColor(tool))
                                .frame(width: 14)
                            Text(toolLabel(tool.name))
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(Theme.textPrimary)
                                .frame(width: 54, alignment: .leading)
                            Text(toolSummary(tool))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(Theme.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(tint.opacity(failedCount > 0 ? 0.42 : 0.16), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.035), radius: 7, y: 2)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var activitySummary: String {
        var counts: [String: Int] = [:]
        for tool in tools {
            counts[activityLabel(tool.name), default: 0] += 1
        }
        return ["读取", "搜索", "网页", "待办"]
            .compactMap { label in counts[label].map { "\(label) \($0)" } }
            .joined(separator: " · ")
    }

    private func activityLabel(_ name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("web") { return "网页" }
        if lower == "todoread" { return "待办" }
        if lower.hasPrefix("read") { return "读取" }
        return "搜索"
    }

    private func toolSummary(_ tool: ExplorationToolItem) -> String {
        for key in ["file_path", "path", "pattern", "query", "url", "file", "filename"] {
            if let value = tool.input[key] {
                let text = value.summaryText
                if !text.isEmpty { return text }
            }
        }
        return tool.description
            ?? tool.input.first.map { "\($0.key): \($0.value.summaryText)" }
            ?? "无参数"
    }

    private func toolStatusIcon(_ tool: ExplorationToolItem) -> String {
        if tool.result?.isError == true { return "xmark.circle.fill" }
        if tool.result != nil { return "checkmark.circle.fill" }
        return "circle.dotted"
    }

    private func toolStatusColor(_ tool: ExplorationToolItem) -> Color {
        if tool.result?.isError == true { return Theme.danger }
        if tool.result != nil { return chatSuccess }
        return Theme.brand
    }
}

/// 工具调用卡片：图标 + 中文工具名 + 参数摘要 + 可折叠结果区。
/// 三态对齐 Web：运行中（转圈）/ 成功（左侧绿竖线）/ 失败（红弱底 + 红边框）。
private struct ToolUseCard: View {
    let name: String
    let description: String?
    let input: [String: JSONValue]
    var result: ToolResultInfo?
    var running = false

    @State private var expanded = false

    private var isError: Bool { result?.isError == true }
    private var isSuccess: Bool { result != nil && !isError }
    private var hasBody: Bool { !(result?.text.isEmpty ?? true) }
    private var statusColor: Color {
        if isError { return Theme.danger }
        if running { return Theme.brand }
        if isSuccess { return chatSuccess }
        return Theme.textSecondary
    }
    private var statusText: String {
        if isError { return "失败" }
        if running { return "处理中" }
        if isSuccess { return "完成" }
        return "待执行"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if expanded, let result, hasBody {
                Divider()
                    .overlay(Theme.border.opacity(0.7))
                    .padding(.horizontal, 12)
                ToolResultBody(result: result)
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 12)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(statusColor.opacity(isError ? 0.42 : 0.16), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.035), radius: 7, y: 2)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var header: some View {
        Button {
            guard hasBody else { return }
            withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
        } label: {
            HStack(spacing: 11) {
                if running {
                    ZStack {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(statusColor.opacity(0.12))
                        ProgressView()
                            .controlSize(.small)
                            .tint(statusColor)
                    }
                    .frame(width: 34, height: 34)
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(statusColor.opacity(isSuccess ? 0.10 : 0.12))
                        Image(systemName: iconName)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(statusColor)
                    }
                    .frame(width: 34, height: 34)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(toolLabel(name))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(isError ? Theme.danger : Theme.textPrimary)
                    if !summary.isEmpty {
                        Text(summary)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(Theme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
                Text(statusText)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(statusColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(statusColor.opacity(0.10)))
                if hasBody {
                    ZStack {
                        Circle().fill(Theme.background)
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(Theme.textSecondary)
                    }
                    .frame(width: 24, height: 24)
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var iconName: String {
        let lower = name.lowercased()
        if lower.contains("bash") || lower.contains("command") { return "terminal" }
        if lower.contains("edit") || lower.contains("write") { return "pencil" }
        if lower.contains("read") { return "doc.text.magnifyingglass" }
        if lower.contains("grep") || lower.contains("glob") || lower.contains("search") { return "magnifyingglass" }
        if lower.contains("web") || lower.contains("fetch") { return "globe" }
        if lower.contains("task") || lower.contains("agent") { return "person.2" }
        return "wrench.and.screwdriver"
    }

    /// 摘要优先级：description > 常见关键参数 > 第一个参数。
    private var summary: String {
        if let d = description, !d.isEmpty { return d }
        let preferredKeys = ["command", "file_path", "path", "pattern", "query", "prompt", "url", "description"]
        for key in preferredKeys {
            if let value = input[key] {
                let text = value.summaryText
                if !text.isEmpty { return text }
            }
        }
        if let first = input.first {
            return "\(first.key): \(first.value.summaryText)"
        }
        return ""
    }
}

/// 工具结果正文：次级底色代码框 + 4000 字截断。
private struct ToolResultBody: View {
    let result: ToolResultInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                Text(result.text.count > 4000 ? String(result.text.prefix(4000)) + "\n…（已截断）" : result.text)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(result.isError ? Theme.danger : Theme.textPrimary)
                    .textSelection(.enabled)
                    .padding(10)
            }
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.background.opacity(0.6))
            )
            if result.truncated {
                Text("内容过长，已截断")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textSecondary)
            }
        }
    }
}

/// 可折叠区块（thinking / tool_result 共用），默认折叠。
private struct CollapsibleSection<Content: View>: View {
    let icon: String
    let title: String
    let tint: Color
    @ViewBuilder let content: () -> Content

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: icon).font(.system(size: 12))
                    Text(title).font(.system(size: 12, weight: .medium))
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
                .foregroundColor(tint)
            }
            .buttonStyle(.plain)
            if expanded {
                content()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Theme.surface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Theme.border, lineWidth: 1)
                    )
            }
        }
    }
}

// MARK: - 权限审批卡片

private struct PermissionCard: View {
    let escalation: EscalationRequest?
    let legacy: PermissionRequestInfo?
    let onResolve: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.orange)
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                Spacer()
            }
            if !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let target, !target.isEmpty {
                Text(target)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Theme.background)
                    )
            }
            HStack(spacing: 8) {
                Button { onResolve("approve_once") } label: {
                    Text("允许").frame(maxWidth: .infinity)
                }
                .buttonStyle(PermissionButtonStyle(kind: .primary))
                if escalation != nil {
                    Button { onResolve("approve_turn") } label: {
                        Text("本轮均允许").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PermissionButtonStyle(kind: .secondary))
                }
                Button { onResolve("deny") } label: {
                    Text("拒绝").frame(maxWidth: .infinity)
                }
                .buttonStyle(PermissionButtonStyle(kind: .destructive))
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.orange.opacity(0.55), lineWidth: 1.5)
        )
    }

    private var title: String {
        if let esc = escalation { return esc.scopeTitle }
        return "权限请求"
    }

    private var detail: String {
        if let esc = escalation { return esc.reason }
        return legacy?.prompt ?? ""
    }

    private var target: String? {
        escalation?.target ?? legacy?.target
    }
}

// MARK: - 共享语义色（Web 端 --success 同款 #4F7A58）

private let chatSuccess = Color(red: 0.310, green: 0.478, blue: 0.345)

// MARK: - AskUserQuestion 交互卡片（对齐 Web 端 ask-user 卡）

/// 提问卡：头部「? 提问 · header」，body 是题目 + 选项列表 + 确认提交。
/// 未答可交互（单选/多选），已答（配对到 tool_result）转只读并高亮用户选过的项。
private struct AskUserQuestionCard: View {
    let toolUseId: String
    let questions: [AskUserQuestion]
    let result: ToolResultInfo?
    let selection: AskUserSelectionState
    let onToggle: (Int, Int, Bool) -> Void
    let onSubmit: (String) -> Void

    @State private var expanded = true

    private var isAnswered: Bool { result != nil }
    /// 已答时按行拆答案：每道题一行，行内 ", " 分隔多选 label（对齐 Web 的解析）。
    private var answerLines: [String] {
        guard let text = result?.text.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return [] }
        return text.components(separatedBy: "\n")
    }
    private var headerLabel: String? {
        questions.first(where: { !($0.header ?? "").isEmpty })?.header
    }
    private var allAnswered: Bool {
        (0..<questions.count).allSatisfy { !(selection.selected[$0] ?? []).isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerView
            if expanded {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(questions.enumerated()), id: \.offset) { qIdx, question in
                        questionGroup(qIdx: qIdx, question: question)
                    }
                    if !isAnswered {
                        submitRow
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.brand.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isAnswered ? chatSuccess.opacity(0.55) : Theme.brand.opacity(0.35), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onAppear { expanded = !isAnswered }
        .onChange(of: isAnswered) { answered in
            // 回答送达后自动折叠（对齐 Web 已答默认折叠）。
            if answered { withAnimation(.easeInOut(duration: 0.15)) { expanded = false } }
        }
    }

    private var headerView: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isAnswered ? "checkmark.circle.fill" : "questionmark.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(isAnswered ? chatSuccess : Theme.brand)
                    .frame(width: 22)
                Text("提问")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                if let headerLabel {
                    Text(headerLabel)
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(1)
                }
                if isAnswered {
                    Text(answerLines.joined(separator: ", "))
                        .font(.system(size: 12))
                        .foregroundColor(chatSuccess)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private func questionGroup(qIdx: Int, question: AskUserQuestion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !question.question.isEmpty {
                Text(question.question)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(question.options.enumerated()), id: \.offset) { optIdx, option in
                    optionRow(qIdx: qIdx, optIdx: optIdx, option: option, multiSelect: question.multiSelect)
                }
            }
        }
    }

    @ViewBuilder private func optionRow(
        qIdx: Int, optIdx: Int, option: AskUserQuestion.Option, multiSelect: Bool
    ) -> some View {
        let chosen: Bool = {
            if isAnswered {
                // 只读态：答案第 qIdx 行（缺行回落第一行），按 "," 拆出已选 label。
                let line = qIdx < answerLines.count ? answerLines[qIdx] : (answerLines.first ?? "")
                return line.components(separatedBy: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .contains(option.label)
            }
            return (selection.selected[qIdx] ?? []).contains(optIdx)
        }()

        Button {
            guard !isAnswered, !selection.submitted else { return }
            onToggle(qIdx, optIdx, multiSelect)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                indicator(chosen: chosen, multiSelect: multiSelect)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let desc = option.description, !desc.isEmpty {
                        Text(desc)
                            .font(.system(size: 12))
                            .foregroundColor(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(optionFill(chosen: chosen))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(optionBorder(chosen: chosen), lineWidth: chosen ? 1.5 : 1)
            )
            .opacity(isAnswered && !chosen ? 0.55 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isAnswered || selection.submitted)
    }

    private func optionFill(chosen: Bool) -> Color {
        if isAnswered {
            return chosen ? chatSuccess.opacity(0.08) : Theme.surface
        }
        return chosen ? Theme.brand.opacity(0.16) : Theme.surface
    }

    private func optionBorder(chosen: Bool) -> Color {
        if isAnswered {
            return chosen ? chatSuccess : Theme.border
        }
        return chosen ? Theme.brand : Theme.border
    }

    /// 单选圆形 / 多选圆角方形 indicator，选中实底白点/白勾（对齐 Web）。
    @ViewBuilder private func indicator(chosen: Bool, multiSelect: Bool) -> some View {
        let tint = isAnswered ? chatSuccess : Theme.brand
        ZStack {
            if multiSelect {
                RoundedRectangle(cornerRadius: 3)
                    .fill(chosen ? tint : Color.clear)
                RoundedRectangle(cornerRadius: 3)
                    .stroke(chosen ? tint : Theme.border, lineWidth: 2)
                if chosen {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white)
                }
            } else {
                Circle().fill(chosen ? tint : Color.clear)
                Circle().stroke(chosen ? tint : Theme.border, lineWidth: 2)
                if chosen {
                    Circle().fill(Color.white).frame(width: 6, height: 6)
                }
            }
        }
        .frame(width: 16, height: 16)
        .padding(.top, 1)
    }

    private var submitRow: some View {
        HStack {
            Spacer()
            Button {
                guard allAnswered, !selection.submitted else { return }
                var lines: [String] = []
                for (qIdx, question) in questions.enumerated() {
                    let chosen = (selection.selected[qIdx] ?? []).sorted()
                    lines.append(chosen.map { question.options[$0].label }.joined(separator: ", "))
                }
                onSubmit(lines.joined(separator: "\n"))
            } label: {
                Text(selection.submitted ? "已提交…" : "确认提交")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill((allAnswered && !selection.submitted) ? Theme.brand : Theme.brand.opacity(0.4))
                    )
            }
            .buttonStyle(.plain)
            .disabled(!allAnswered || selection.submitted)
        }
    }
}

// MARK: - Diff 卡片（Edit / Write / MultiEdit，对齐 Web 端 inline-diff）

private struct DiffCard: View {
    let toolName: String
    let input: [String: JSONValue]
    let result: ToolResultInfo?

    @State private var expanded = false
    @State private var initialized = false

    private var path: String {
        input["file_path"]?.stringValue ?? input["path"]?.stringValue ?? ""
    }
    private var fileName: String {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }
    private var isWrite: Bool { toolName == "Write" || toolName == "MultiEdit" }
    private var oldText: String { input["old_string"]?.stringValue ?? "" }
    private var newText: String {
        input["new_string"]?.stringValue ?? input["content"]?.stringValue ?? ""
    }

    private var statusText: String {
        guard let result else { return "执行中" }
        if result.isError {
            let text = result.text
            return (text.contains("haven't granted") || text.contains("permission")) ? "等待授权" : "失败"
        }
        return "已修改"
    }
    private var statusColor: Color {
        guard let result else { return Theme.brand }
        return result.isError ? Theme.danger : chatSuccess
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    if !isWrite && !oldText.isEmpty {
                        diffColumn(label: "旧", text: oldText, prefix: "- ", tint: Theme.danger)
                    }
                    if !newText.isEmpty {
                        diffColumn(label: isWrite ? "" : "新", text: newText, prefix: "+ ", tint: chatSuccess)
                    }
                    if let result, result.isError, !result.text.isEmpty {
                        Text(result.text.count > 600 ? String(result.text.prefix(600)) + "…" : result.text)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(Theme.danger)
                            .textSelection(.enabled)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Theme.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onAppear {
            // 默认展开态对齐 Web：执行中展开，已完成折叠。只在首次出现时定初值。
            if !initialized {
                expanded = result == nil
                initialized = true
            }
        }
        .onChange(of: result != nil) { hasResult in
            // 结果到达后自动收起（对齐 Android / Web 行为；手动点开不受影响）。
            if hasResult { withAnimation(.easeInOut(duration: 0.15)) { expanded = false } }
        }
    }

    private var header: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "doc.text")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Theme.brand)
                    .frame(width: 22)
                Text(fileName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                Text(path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 0)
                Text(statusText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(statusColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(statusColor.opacity(0.12)))
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private func diffColumn(label: String, text: String, prefix: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if !label.isEmpty {
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(prefix + (text.count > 2000 ? String(text.prefix(2000)) + "\n…（已截断）" : text))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(tint)
                    .textSelection(.enabled)
                    .padding(8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(tint.opacity(0.08))
            )
        }
    }
}

// MARK: - 终端卡片（Bash，对齐 Web 端 inline-terminal）

private struct TerminalCard: View {
    let input: [String: JSONValue]
    let result: ToolResultInfo?
    var running = false

    @State private var expanded = false

    private var command: String {
        input["command"]?.stringValue ?? input["cmd"]?.stringValue ?? ""
    }
    private var statusColor: Color {
        guard let result else { return Theme.brand }
        return result.isError ? Theme.danger : chatSuccess
    }
    // 终端卡固定深色，亮暗主题一致（对齐 Web）。
    private let termBg = Color(red: 0.118, green: 0.118, blue: 0.118)
    private let termText = Color(red: 0.85, green: 0.85, blue: 0.83)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text("$ " + command)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(termText)
                            .textSelection(.enabled)
                    }
                    if let result, !result.text.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            Text(result.text.count > 4000 ? String(result.text.prefix(4000)) + "\n…（已截断）" : result.text)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(result.isError ? Color(red: 0.95, green: 0.55, blue: 0.5) : termText.opacity(0.85))
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
        }
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(termBg))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var header: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
        } label: {
            HStack(spacing: 8) {
                if running {
                    ProgressView().controlSize(.small).tint(termText)
                } else {
                    Circle().fill(statusColor).frame(width: 8, height: 8)
                }
                Text("$ " + (command.count > 80 ? String(command.prefix(77)) + "…" : command))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(termText)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(termText.opacity(0.6))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 待办进度条（TodoWrite，对齐 Web 端 todo-progress）

/// 输入栏上方的悬浮进度条：环形进度 + N/M + 当前任务，点击展开任务列表。
struct TodoProgressBar: View {
    let todos: [TodoItem]

    @State private var expanded = false

    private var completed: Int { todos.filter { $0.status == "completed" }.count }
    /// 1-indexed「正在干第 N 个」：completed+1 封顶（对齐 Web currentStep）。
    private var currentStep: Int { min(completed + 1, todos.count) }
    /// 右侧当前步骤描述：优先取首个 in_progress 的 activeForm / content；
    /// 没有进行中项时（模型已标完上一步、还没标下一步 in_progress，此时 N/M 靠
    /// completed+1 仍显示「正在干第 N 个」），回退到首个 pending 任务的描述；
    /// 都没有再兜底「准备中…」——保证右侧空白区始终有内容（对齐 Web fallback）。
    private var activeTask: String {
        if let active = todos.first(where: { $0.status == "in_progress" }) {
            let label = (active.activeForm?.isEmpty == false) ? active.activeForm! : active.content
            if !label.isEmpty { return label }
        }
        if let pending = todos.first(where: { $0.status == "pending" }) {
            let label = (pending.activeForm?.isEmpty == false) ? pending.activeForm! : pending.content
            if !label.isEmpty { return label }
        }
        return "准备中…"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    progressRing
                    Text("\(currentStep)/\(todos.count)")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundColor(Theme.brand)
                    Text(activeTask)
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(-1)
                    Spacer(minLength: 8)
                    Image(systemName: expanded ? "chevron.down" : "chevron.up")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Theme.textSecondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(todos.enumerated()), id: \.offset) { _, todo in
                        todoRow(todo)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.surface)
                .shadow(color: Color.black.opacity(0.08), radius: 6, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Theme.border, lineWidth: 1)
        )
    }

    private var progressRing: some View {
        ZStack {
            Circle()
                .stroke(Theme.border, lineWidth: 3)
            Circle()
                .trim(from: 0, to: CGFloat(currentStep) / CGFloat(max(todos.count, 1)))
                .stroke(Theme.brand, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 18, height: 18)
    }

    @ViewBuilder private func todoRow(_ todo: TodoItem) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Group {
                switch todo.status {
                case "completed":
                    Text("✓").foregroundColor(chatSuccess)
                case "in_progress":
                    Text("›").foregroundColor(Theme.brand)
                default:
                    Text("○").foregroundColor(Theme.textSecondary)
                }
            }
            .font(.system(size: 12, weight: .bold, design: .monospaced))
            .frame(width: 14)
            Text(todo.content)
                .font(.system(size: 12))
                .foregroundColor(todo.status == "in_progress" ? Theme.textPrimary : Theme.textSecondary)
                .strikethrough(todo.status == "completed", color: Theme.textSecondary.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

private struct QueueBar: View {
    @ObservedObject var store: ChatStore
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "tray.full")
                        .font(.system(size: 12, weight: .semibold))
                    Text("已排队 \(store.queuedMessages.count) 条消息")
                        .font(.system(size: 12))
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .foregroundColor(Theme.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(store.queuedMessages.enumerated()), id: \.offset) { index, text in
                        QueueItemRow(
                            index: index,
                            text: text,
                            onPromote: { store.promoteQueued(index: index) },
                            onDelete: { store.deleteQueued(index: index) }
                        )
                    }
                    HStack {
                        Spacer()
                        Button {
                            store.clearQueued()
                        } label: {
                            Label("全部清空", systemImage: "trash")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(Theme.danger)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 2)
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Theme.border, lineWidth: 1)
        )
        .animation(.easeInOut(duration: 0.16), value: expanded)
    }
}

private struct QueueItemRow: View {
    let index: Int
    let text: String
    let onPromote: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text("\(index + 1)")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(Theme.brand)
                .frame(width: 18)
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(2)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            Button(action: onPromote) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.brand)
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .help("立即发送")
            Button(action: onDelete) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(Theme.danger)
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .help("删除")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.background.opacity(0.55))
        )
    }
}

private struct PermissionButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, destructive }
    let kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(kind == .primary ? .white : (kind == .destructive ? Theme.danger : Theme.textPrimary))
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(kind == .primary ? Theme.brand : Theme.background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(kind == .primary ? Color.clear : Theme.border, lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
