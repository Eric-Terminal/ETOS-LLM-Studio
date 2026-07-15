// ============================================================================
// WatchContextCompressionViews.swift
// ============================================================================
// ETOS LLM Studio
//
// watchOS 续聊上下文卡片、详情与压缩选项界面。
// ============================================================================

import SwiftUI
import ETOSCore

struct WatchContextCompressionReminderRefreshKey: Hashable {
    let sessionID: UUID?
    let messageVersion: Int
    let isSending: Bool
    let continuationID: UUID?
    let reminderEnabled: Bool
    let tokenThreshold: Int
}

struct WatchContextCompressionReminderNotificationKey: Hashable {
    let sessionID: UUID
    let continuationID: UUID?
    let tokenThreshold: Int
}

private struct WatchConversationContinuationTextPreview: Sendable {
    let full: String
    let displayed: String
    let characterCount: Int
    let isTruncated: Bool

    nonisolated init(text: String, limit: Int) {
        let characterCount = text.count
        self.full = text
        self.displayed = characterCount > limit
            ? String(text.prefix(limit))
            : text
        self.characterCount = characterCount
        self.isTruncated = characterCount > limit
    }
}

private struct WatchConversationContinuationToolContent: Identifiable, Sendable {
    let tool: ConversationContinuationRetainedTool
    let arguments: WatchConversationContinuationTextPreview
    let result: WatchConversationContinuationTextPreview

    var id: String { tool.id }

    nonisolated init(tool: ConversationContinuationRetainedTool) {
        self.tool = tool
        self.arguments = WatchConversationContinuationTextPreview(
            text: tool.arguments,
            limit: WatchToolCallTextPreviewConstants.previewLimit
        )
        self.result = WatchConversationContinuationTextPreview(
            text: tool.result,
            limit: WatchToolCallTextPreviewConstants.previewLimit
        )
    }
}

private enum WatchConversationContinuationRetainedDisplayItem: Identifiable, Sendable {
    case message(ConversationContinuationRetainedMessage)
    case tool(WatchConversationContinuationToolContent)

    var id: String {
        switch self {
        case .message(let message):
            return "message:\(message.id.uuidString)"
        case .tool(let tool):
            return tool.id
        }
    }

    nonisolated static func make(
        from messages: [ChatMessage]
    ) -> [WatchConversationContinuationRetainedDisplayItem] {
        ConversationContinuationRetainedContentPlanner.makeItems(from: messages).map { item in
            switch item {
            case .message(let message):
                return .message(message)
            case .tool(let tool):
                return .tool(WatchConversationContinuationToolContent(tool: tool))
            }
        }
    }
}

struct WatchConversationContinuationCard: View {
    @ObservedObject private var appearanceProfileManager = ChatAppearanceProfileManager.shared

    let context: ConversationContinuationContext
    let enableBackground: Bool
    let enableLiquidGlass: Bool
    let enableNoBubbleUI: Bool

    var body: some View {
        HStack {
            Image(systemName: "rectangle.compress.vertical")
                .foregroundStyle(.tint)

            VStack(alignment: .leading) {
                Text(NSLocalizedString("续聊上下文", comment: "Continuation context card title"))
                    .etFont(.footnote.weight(.semibold))
                    .foregroundStyle(assistantPrimaryTextColor)
                Text(context.sourceSessionNameSnapshot)
                    .etFont(.caption2)
                    .foregroundStyle(assistantSecondaryTextColor)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(assistantContentInsets)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(assistantBubbleBackground)
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(
                    enableNoBubbleUI ? Color.clear : Color.accentColor.opacity(0.28),
                    lineWidth: 1
                )
        }
        .contentShape(Rectangle())
    }

    private var activeAppearanceProfile: ChatAppearanceProfile {
        appearanceProfileManager.activeProfile
    }

    private var assistantBubbleColorOverride: Color? {
        let slot = activeAppearanceProfile.assistantBubble
        guard slot.isEnabled else { return nil }
        let fallback = Color(.sRGB, red: 0.949, green: 0.949, blue: 0.969, opacity: 1)
        return ChatAppearanceColorCodec.color(from: slot.hex, fallback: fallback)
    }

    private var assistantTextColorOverride: Color? {
        let slot = activeAppearanceProfile.assistantLightText
        guard slot.isEnabled else { return nil }
        return ChatAppearanceColorCodec.color(from: slot.hex, fallback: .primary)
    }

    private var assistantPrimaryTextColor: Color {
        assistantTextColorOverride ?? .primary
    }

    private var assistantSecondaryTextColor: Color {
        assistantTextColorOverride?.opacity(0.78) ?? .secondary
    }

    private var assistantContentInsets: EdgeInsets {
        enableNoBubbleUI
            ? EdgeInsets(top: 6, leading: 2, bottom: 6, trailing: 2)
            : EdgeInsets(top: 10, leading: 8, bottom: 10, trailing: 8)
    }

    private var assistantFallbackBackground: Color {
        if let assistantBubbleColorOverride {
            return enableBackground
                ? assistantBubbleColorOverride.opacity(0.7)
                : assistantBubbleColorOverride
        }
        return enableBackground ? Color.black.opacity(0.3) : Color(white: 0.3)
    }

    private var assistantLiquidGlassBackground: Color {
        assistantBubbleColorOverride.map { enableBackground ? $0.opacity(0.5) : $0 }
            ?? Color.clear
    }

    @ViewBuilder
    private var assistantBubbleBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        if enableNoBubbleUI {
            shape.fill(Color.clear)
        } else if enableLiquidGlass {
            if #available(watchOS 26.0, *) {
                shape
                    .fill(assistantLiquidGlassBackground)
                    .glassEffect(.clear, in: shape)
                    .clipShape(shape)
            } else {
                shape.fill(assistantFallbackBackground)
            }
        } else {
            shape.fill(assistantFallbackBackground)
        }
    }
}

struct WatchConversationContinuationDetailView: View {
    @ObservedObject private var appearanceProfileManager = ChatAppearanceProfileManager.shared

    let context: ConversationContinuationContext
    let enableAdvancedRenderer: Bool
    let sourceSessionAvailable: Bool
    let onOpenSource: () -> Void
    let onInsertText: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var retainedDisplayItems: [WatchConversationContinuationRetainedDisplayItem]?

    var body: some View {
        List {
            Section(NSLocalizedString("来源", comment: "Continuation context source section")) {
                Text(context.sourceSessionNameSnapshot)
                    .etFont(.footnote)

                Button {
                    onOpenSource()
                    dismiss()
                } label: {
                    Label(
                        sourceSessionAvailable
                            ? NSLocalizedString("打开原会话", comment: "Open continuation source session action")
                            : NSLocalizedString("原会话已删除", comment: "Continuation source session deleted state"),
                        systemImage: sourceSessionAvailable ? "arrow.up.backward.circle" : "trash"
                    )
                }
                .disabled(!sourceSessionAvailable)
            }

            Section(NSLocalizedString("较早对话摘要", comment: "Continuation context summary heading")) {
                NavigationLink {
                    WatchMessageTextSelectionView(message: summaryMessage) { text in
                        onInsertText(text)
                        dismiss()
                    }
                } label: {
                    WatchContinuationMarkdownView(
                        contentID: context.id,
                        content: context.summary,
                        enableAdvancedRenderer: enableAdvancedRenderer,
                        customTextColor: assistantTextColorOverride,
                        customTextStyleColors: assistantTextStyleColors
                    )
                }
                .accessibilityHint(NSLocalizedString(
                    "选定文字",
                    comment: "Open continuation summary text selection"
                ))
            }

            if !context.retainedMessages.isEmpty {
                Section(NSLocalizedString("最近对话原文", comment: "Continuation context retained messages heading")) {
                    if let retainedDisplayItems {
                        ForEach(retainedDisplayItems) { item in
                            switch item {
                            case .message(let message):
                                NavigationLink {
                                    WatchMessageTextSelectionView(
                                        message: ChatMessage(
                                            id: message.id,
                                            role: message.role,
                                            content: message.content
                                        )
                                    ) { text in
                                        onInsertText(text)
                                        dismiss()
                                    }
                                } label: {
                                    VStack(alignment: .leading) {
                                        Text(roleTitle(message.role))
                                            .etFont(.caption2)
                                            .foregroundStyle(assistantSecondaryTextColor)
                                        WatchContinuationMarkdownView(
                                            contentID: message.id,
                                            content: message.content,
                                            enableAdvancedRenderer: enableAdvancedRenderer,
                                            customTextColor: assistantTextColorOverride,
                                            customTextStyleColors: assistantTextStyleColors
                                        )
                                    }
                                }
                                .accessibilityHint(NSLocalizedString(
                                    "选定文字",
                                    comment: "Open retained message text selection"
                                ))
                            case .tool(let tool):
                                NavigationLink {
                                    WatchConversationContinuationToolDetailView(
                                        content: tool,
                                        secondaryTextColor: assistantSecondaryTextColor
                                    )
                                } label: {
                                    WatchConversationContinuationToolRow(
                                        content: tool,
                                        primaryTextColor: assistantPrimaryTextColor,
                                        secondaryTextColor: assistantSecondaryTextColor
                                    )
                                }
                            }
                        }
                    } else {
                        ProgressView()
                    }
                }
            }

            Section(NSLocalizedString("详细信息", comment: "Continuation context details section")) {
                Text(String(
                    format: NSLocalizedString("摘要消息：%d", comment: "Continuation summarized message count"),
                    context.summarizedMessageCount
                ))
                Text(String(
                    format: NSLocalizedString("保留原文：%d 轮", comment: "Continuation retained round count"),
                    context.retainedRoundCount
                ))
            }
        }
        .navigationTitle(NSLocalizedString("续聊上下文", comment: "Continuation context detail title"))
        .task(id: context.id) {
            let messages = context.retainedMessages
            retainedDisplayItems = await Task.detached(priority: .utility) {
                WatchConversationContinuationRetainedDisplayItem.make(from: messages)
            }.value
        }
    }

    private var summaryMessage: ChatMessage {
        ChatMessage(id: context.id, role: .system, content: context.summary)
    }

    private var assistantTextColorOverride: Color? {
        let slot = appearanceProfileManager.activeProfile.assistantLightText
        guard slot.isEnabled else { return nil }
        return ChatAppearanceColorCodec.color(from: slot.hex, fallback: .primary)
    }

    private var assistantTextStyleColors: ChatAppearanceTextStyleColors {
        appearanceProfileManager.activeProfile.assistantLightTextStyles
    }

    private var assistantSecondaryTextColor: Color {
        assistantTextColorOverride?.opacity(0.78) ?? .secondary
    }

    private var assistantPrimaryTextColor: Color {
        assistantTextColorOverride ?? .primary
    }

    private func roleTitle(_ role: MessageRole) -> String {
        switch role {
        case .system:
            return NSLocalizedString("系统", comment: "Continuation retained message role")
        case .user:
            return NSLocalizedString("用户", comment: "Continuation retained message role")
        case .assistant:
            return NSLocalizedString("助手", comment: "Continuation retained message role")
        case .tool:
            return NSLocalizedString("工具", comment: "Continuation retained message role")
        case .error:
            return NSLocalizedString("错误", comment: "Continuation retained message role")
        }
    }
}

private struct WatchConversationContinuationToolRow: View {
    let content: WatchConversationContinuationToolContent
    let primaryTextColor: Color
    let secondaryTextColor: Color

    var body: some View {
        HStack {
            Image(systemName: "wrench.and.screwdriver")
                .foregroundStyle(.tint)

            VStack(alignment: .leading) {
                Text(toolDisplayLabel)
                    .etFont(.footnote.weight(.semibold))
                    .foregroundStyle(primaryTextColor)
                Text(statusTitle)
                    .etFont(.caption2)
                    .foregroundStyle(secondaryTextColor)
            }
        }
    }

    private var toolDisplayLabel: String {
        continuationToolDisplayLabel(content.tool.toolName)
    }

    private var statusTitle: String {
        content.result.full.isEmpty
            ? NSLocalizedString("工具调用", comment: "Continuation tool call without a stored result")
            : NSLocalizedString("已完成", comment: "Completed continuation tool call")
    }
}

private struct WatchConversationContinuationToolDetailView: View {
    let content: WatchConversationContinuationToolContent
    let secondaryTextColor: Color

    var body: some View {
        List {
            if !content.arguments.full.isEmpty {
                Section(NSLocalizedString("参数", comment: "Tool arguments section title")) {
                    WatchToolCallLongTextPreview(
                        title: NSLocalizedString("参数", comment: "Tool arguments section title"),
                        text: content.arguments.full,
                        usesMonospacedFont: true,
                        displayedText: content.arguments.displayed,
                        textCharacterCount: content.arguments.characterCount,
                        needsExpansion: content.arguments.isTruncated,
                        customTextColor: secondaryTextColor
                    )
                }
            }

            if !content.result.full.isEmpty {
                Section(NSLocalizedString("工具结果", comment: "Tool result section title")) {
                    WatchToolCallLongTextPreview(
                        title: NSLocalizedString("工具结果", comment: "Tool result section title"),
                        text: content.result.full,
                        usesMonospacedFont: true,
                        displayedText: content.result.displayed,
                        textCharacterCount: content.result.characterCount,
                        needsExpansion: content.result.isTruncated,
                        customTextColor: secondaryTextColor
                    )
                }
            }
        }
        .navigationTitle(continuationToolDisplayLabel(content.tool.toolName))
    }
}

private func continuationToolDisplayLabel(_ toolName: String?) -> String {
    guard let toolName, !toolName.isEmpty else {
        return NSLocalizedString("工具结果", comment: "Standalone continuation tool result title")
    }
    if toolName == "save_memory" {
        return NSLocalizedString("添加记忆", comment: "Tool label for saving memory.")
    }
    if let label = MCPManager.shared.displayLabel(for: toolName) {
        return label
    }
    if let label = ShortcutToolManager.shared.displayLabel(for: toolName) {
        return label
    }
    if let label = SkillManager.shared.displayLabel(for: toolName) {
        return label
    }
    if let label = AppToolManager.shared.displayLabel(for: toolName) {
        return label
    }
    return toolName
}

private struct WatchContinuationMarkdownView: View {
    let contentID: UUID
    let content: String
    let enableAdvancedRenderer: Bool
    let customTextColor: Color?
    let customTextStyleColors: ChatAppearanceTextStyleColors

    @State private var preparedContent: ETPreparedMarkdownRenderPayload?

    var body: some View {
        Group {
            if let preparedContent,
               preparedContent.sourceText == content {
                ETAdvancedMarkdownRenderer(
                    content: content,
                    preparedContent: preparedContent,
                    enableMarkdown: true,
                    isOutgoing: false,
                    enableAdvancedRenderer: enableAdvancedRenderer,
                    enableMathRendering: enableAdvancedRenderer,
                    customTextColor: customTextColor,
                    customTextStyleColors: customTextStyleColors
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 32)
            }
        }
        .task(id: contentID) {
            preparedContent = await ETMarkdownPrecomputeWorker.shared.prepare(source: content)
        }
    }
}

struct WatchContextCompressionOneTapView: View {
    typealias ProgressHandler = @MainActor @Sendable (ContextCompressionProgress) -> Void

    @Environment(\.dismiss) private var dismiss

    let session: ChatSession
    let onCompress: (@escaping ProgressHandler) async throws -> ChatSession

    @State private var progress = ContextCompressionProgress(phase: .preparing)
    @State private var compressionTask: Task<Void, Never>?
    @State private var hasStarted = false
    @State private var errorMessage: String?

    var body: some View {
        VStack {
            Spacer()

            ProgressView()

            Text(NSLocalizedString(
                "正在压缩为续聊",
                comment: "Watch one-tap context compression progress title"
            ))
            .etFont(.headline)
            .multilineTextAlignment(.center)

            Text(progressText(progress))
                .etFont(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Text(String(
                format: NSLocalizedString(
                    "原会话“%@”会完整保留。",
                    comment: "Watch one-tap context compression source preservation"
                ),
                session.name
            ))
            .etFont(.caption2)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)

            Spacer()

            Button(role: .destructive) {
                compressionTask?.cancel()
            } label: {
                Label(NSLocalizedString(
                    "停止",
                    comment: "Stop watch one-tap context compression action"
                ), systemImage: "stop.fill")
            }
            .disabled(compressionTask == nil)
        }
        .navigationTitle(NSLocalizedString(
            "压缩为续聊",
            comment: "Watch one-tap context compression navigation title"
        ))
        .onAppear(perform: startIfNeeded)
        .onDisappear {
            compressionTask?.cancel()
        }
        .interactiveDismissDisabled(compressionTask != nil)
        .alert(NSLocalizedString(
            "压缩失败",
            comment: "Watch one-tap context compression failure title"
        ), isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button(NSLocalizedString("关闭", comment: "Close watch one-tap compression error")) {
                dismiss()
            }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func startIfNeeded() {
        guard !hasStarted else { return }
        hasStarted = true
        compressionTask = Task {
            do {
                _ = try await onCompress { newProgress in
                    progress = newProgress
                }
                compressionTask = nil
                dismiss()
            } catch is CancellationError {
                compressionTask = nil
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                compressionTask = nil
            }
        }
    }

    private func progressText(_ progress: ContextCompressionProgress) -> String {
        switch progress.phase {
        case .preparing:
            return NSLocalizedString("正在准备对话与附件…", comment: "Watch one-tap compression preparing progress")
        case .summarizing:
            return NSLocalizedString("正在生成续聊摘要…", comment: "Watch one-tap compression summary progress")
        case .saving:
            return NSLocalizedString("正在保存新会话…", comment: "Watch one-tap compression saving progress")
        }
    }
}

struct WatchContextCompressionOptionsView: View {
    typealias ProgressHandler = @MainActor @Sendable (ContextCompressionProgress) -> Void

    @Environment(\.dismiss) private var dismiss

    let session: ChatSession
    let models: [RunnableModel]
    let selectedModelID: String?
    let onCompress: (ContextCompressionOptions, @escaping ProgressHandler) async throws -> ChatSession

    @State private var retainedRoundCount = ContextCompressionOptions.defaultRetainedRoundCount
    @State private var compressionModelID: String?
    @State private var focusInstruction = ""
    @State private var progress: ContextCompressionProgress?
    @State private var compressionTask: Task<Void, Never>?
    @State private var errorMessage: String?

    private let retainedRoundChoices = [0, 2, 4, 6, 10]

    var body: some View {
        Form {
            Section {
                Text(NSLocalizedString(
                    "创建新的独立会话，原会话会完整保留。",
                    comment: "Watch context compression introduction"
                ))
                .etFont(.footnote)
                .foregroundStyle(.secondary)
            }

            Section {
                Picker(
                    NSLocalizedString("保留原文", comment: "Watch context compression retained rounds picker"),
                    selection: $retainedRoundCount
                ) {
                    ForEach(retainedRoundChoices, id: \.self) { count in
                        Text(String(
                            format: NSLocalizedString("%d 轮", comment: "Context compression retained round count"),
                            count
                        ))
                        .tag(count)
                    }
                }

                Picker(
                    NSLocalizedString("压缩模型", comment: "Context compression model picker"),
                    selection: $compressionModelID
                ) {
                    Text(NSLocalizedString("自动选择", comment: "Automatic context compression model choice"))
                        .tag(String?.none)
                    ForEach(models) { model in
                        Text(model.model.displayName)
                            .tag(Optional(model.id))
                    }
                }
            } footer: {
                Text(NSLocalizedString(
                    "最近轮次会保留原文，其余历史将一次性生成续聊摘要，原会话不会改变。",
                    comment: "Watch context compression retention explanation"
                ))
            }

            Section(NSLocalizedString("额外侧重点（可选）", comment: "Context compression focus section")) {
                TextField(
                    NSLocalizedString("需要特别保留的内容", comment: "Watch context compression focus placeholder"),
                    text: $focusInstruction
                )
            }

            if let progress {
                Section {
                    ProgressView()
                    Text(progressText(progress))
                        .etFont(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button {
                    startCompression()
                } label: {
                    Label(
                        NSLocalizedString("创建续聊会话", comment: "Start context compression action"),
                        systemImage: "rectangle.compress.vertical"
                    )
                }
                .disabled(compressionTask != nil || models.isEmpty)

                if compressionTask != nil {
                    Button(role: .destructive) {
                        compressionTask?.cancel()
                    } label: {
                        Label(NSLocalizedString("停止", comment: "Stop context compression action"), systemImage: "stop.fill")
                    }
                }
            }
        }
        .navigationTitle(NSLocalizedString("压缩为续聊", comment: "Context compression options title"))
        .interactiveDismissDisabled(compressionTask != nil)
        .onAppear {
            compressionModelID = models.contains { $0.id == selectedModelID }
                ? selectedModelID
                : nil
        }
        .alert(NSLocalizedString("压缩失败", comment: "Context compression failure title"), isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button(NSLocalizedString("好的", comment: ""), role: .cancel) { }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func startCompression() {
        let trimmedFocus = focusInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        let options = ContextCompressionOptions(
            retainedRoundCount: retainedRoundCount,
            focusInstruction: trimmedFocus.isEmpty ? nil : trimmedFocus,
            compressionModelIdentifier: compressionModelID
        )
        compressionTask = Task {
            do {
                _ = try await onCompress(options) { newProgress in
                    progress = newProgress
                }
                compressionTask = nil
                dismiss()
            } catch is CancellationError {
                progress = nil
                compressionTask = nil
            } catch {
                errorMessage = error.localizedDescription
                progress = nil
                compressionTask = nil
            }
        }
    }

    private func progressText(_ progress: ContextCompressionProgress) -> String {
        switch progress.phase {
        case .preparing:
            return NSLocalizedString("正在准备对话与附件…", comment: "Watch context compression preparing progress")
        case .summarizing:
            return NSLocalizedString("正在生成续聊摘要…", comment: "Watch context compression summary progress")
        case .saving:
            return NSLocalizedString("正在保存新会话…", comment: "Watch context compression saving progress")
        }
    }
}

extension ContentView {
    var contextCompressionReminderRefreshKey: WatchContextCompressionReminderRefreshKey {
        WatchContextCompressionReminderRefreshKey(
            sessionID: viewModel.currentSession?.id,
            messageVersion: viewModel.allMessageIdentityVersion,
            isSending: viewModel.isSendingMessage,
            continuationID: continuationContext?.id,
            reminderEnabled: appConfig.enableContextCompressionReminder,
            tokenThreshold: appConfig.contextCompressionReminderTokenThreshold
        )
    }

    @MainActor
    func refreshContextCompressionReminderEstimate() async {
        guard appConfig.enableContextCompressionReminder,
              let sessionID = viewModel.currentSession?.id,
              viewModel.currentSession?.isTemporary == false else {
            return
        }
        let messages = viewModel.allMessagesForSession
        let context = continuationContext
        let estimate = await Task.detached(priority: .utility) {
            ContextCompressionReminderEstimator.estimate(
                messages: messages,
                continuationContext: context
            )
        }.value
        guard !Task.isCancelled, viewModel.currentSession?.id == sessionID else { return }

        guard let session = viewModel.currentSession,
              !viewModel.isSendingMessage,
              !viewModel.activatedChatModels.isEmpty,
              ContextCompressionReminderPolicy.shouldRemind(
                estimatedTokens: estimate,
                isEnabled: appConfig.enableContextCompressionReminder,
                tokenThreshold: appConfig.contextCompressionReminderTokenThreshold
              ) else {
            return
        }
        let notificationKey = WatchContextCompressionReminderNotificationKey(
            sessionID: session.id,
            continuationID: continuationContext?.id,
            tokenThreshold: appConfig.contextCompressionReminderTokenThreshold
        )
        guard contextCompressionReminderNotificationKeys.insert(notificationKey).inserted else { return }
        _ = await AppLocalNotificationCenter.shared.postContextCompressionReminder(
            sessionID: session.id,
            sessionName: session.name,
            estimatedTokens: estimate,
            tokenThreshold: appConfig.contextCompressionReminderTokenThreshold
        )
    }

    @MainActor
    func reloadContinuationContext() async {
        guard let sessionID = viewModel.currentSession?.id else {
            continuationContext = nil
            isContinuationSourceSessionAvailable = false
            return
        }
        do {
            let loadedContext = try await viewModel.loadConversationContinuationContext(for: sessionID)
            try Task.checkCancellation()
            guard viewModel.currentSession?.id == sessionID else { return }
            continuationContext = loadedContext
            isContinuationSourceSessionAvailable = loadedContext.map { context in
                viewModel.chatSessions.contains { $0.id == context.sourceSessionID }
            } ?? false
        } catch is CancellationError {
            return
        } catch {
            continuationContext = nil
            isContinuationSourceSessionAvailable = false
        }
    }
}
