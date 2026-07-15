// ============================================================================
// ContextCompressionViews.swift
// ============================================================================
// ETOS LLM Studio
//
// iOS 续聊上下文气泡与压缩选项界面。
// ============================================================================

import SwiftUI
import ETOSCore
import UIKit

struct ContextCompressionReminderRefreshKey: Hashable {
    let sessionID: UUID?
    let messageVersion: Int
    let isSending: Bool
    let continuationID: UUID?
    let reminderEnabled: Bool
    let tokenThreshold: Int
}

struct ContextCompressionReminderNotificationKey: Hashable {
    let sessionID: UUID
    let continuationID: UUID?
    let tokenThreshold: Int
}

enum ConversationContinuationExpansionState: Hashable {
    case collapsed
    case preview
    case full

    var isExpanded: Bool {
        self != .collapsed
    }
}

struct ConversationContinuationBubble: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var appearanceProfileManager = ChatAppearanceProfileManager.shared

    let context: ConversationContinuationContext
    @Binding var expansionState: ConversationContinuationExpansionState
    let enableAdvancedRenderer: Bool
    let enableBackground: Bool
    let enableLiquidGlass: Bool
    let enableNoBubbleUI: Bool
    let sourceSessionAvailable: Bool
    let onExpansionStateChange: (ConversationContinuationExpansionState) -> Void
    let onOpenSource: () -> Void

    @State private var displayContent: ConversationContinuationDisplayContent?
    @State private var preparedPreview: [String: ETPreparedMarkdownRenderPayload] = [:]
    @State private var preparedFull: [String: ETPreparedMarkdownRenderPayload] = [:]
    @State private var expandedToolIDs: Set<String> = []
    @State private var isPreparingFull = false

    var body: some View {
        VStack(alignment: .leading) {
            Button {
                setExpansionState(expansionState.isExpanded ? .collapsed : .preview)
            } label: {
                HStack {
                    Image(systemName: "rectangle.compress.vertical")
                        .foregroundStyle(.tint)

                    VStack(alignment: .leading) {
                        Text(NSLocalizedString("续聊上下文", comment: "Continuation context bubble title"))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(assistantPrimaryTextColor)
                        Text(contextSubtitle)
                            .font(.caption)
                            .foregroundStyle(assistantSecondaryTextColor)
                            .lineLimit(2)
                    }

                    Spacer()

                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(assistantSecondaryTextColor)
                        .rotationEffect(.degrees(expansionState.isExpanded ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expansionState.isExpanded {
                Divider()
                    .overlay(assistantSecondaryTextColor.opacity(0.35))

                VStack(alignment: .leading) {
                    renderedContent

                    Button(action: onOpenSource) {
                        Label(
                            sourceSessionAvailable
                                ? NSLocalizedString("打开原会话", comment: "Open continuation source session action")
                                : NSLocalizedString("原会话已删除", comment: "Continuation source session deleted state"),
                            systemImage: sourceSessionAvailable ? "arrow.up.backward.circle" : "trash"
                        )
                        .font(.footnote)
                    }
                    .buttonStyle(.borderless)
                    .disabled(!sourceSessionAvailable)
                    .padding(.top)

                    HStack {
                        Spacer()

                        if expansionState == .preview,
                           displayContent?.isPreviewTruncated == true {
                            Button(NSLocalizedString(
                                "完全展开",
                                comment: "Fully expand continuation context action"
                            )) {
                                setExpansionState(.full)
                            }
                            .buttonStyle(.borderless)
                        }

                        Button(NSLocalizedString(
                            "收起",
                            comment: "Collapse continuation context action"
                        )) {
                            setExpansionState(.collapsed)
                        }
                        .buttonStyle(.borderless)
                    }
                    .font(.footnote)
                    .padding(.top)
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, enableNoBubbleUI ? 2 : 16)
        .padding(.vertical, enableNoBubbleUI ? 6 : 16)
        .background(assistantBubbleBackground)
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(
                    enableNoBubbleUI ? Color.clear : Color.accentColor.opacity(0.28),
                    lineWidth: 1
                )
        }
        .shadow(
            color: enableNoBubbleUI ? .clear : Color.black.opacity(0.08),
            radius: 3,
            y: 1
        )
        .accessibilityElement(children: .contain)
        .task(id: context.id) {
            await preparePreview()
        }
        .task(id: expansionState) {
            guard expansionState == .full else { return }
            await prepareFullContent()
        }
    }

    @ViewBuilder
    private var renderedContent: some View {
        if let displayContent {
            let segments = expansionState == .full
                ? displayContent.full
                : displayContent.preview
            let prepared = expansionState == .full ? preparedFull : preparedPreview
            VStack(alignment: .leading) {
                ForEach(segments) { segment in
                    switch segment {
                    case .markdown(let id, let content):
                        continuationMarkdown(
                            content,
                            prepared: prepared[id]
                        )
                    case .tool(let tool):
                        ConversationContinuationToolDisclosure(
                            content: tool,
                            isExpanded: toolExpansionBinding(for: tool.id),
                            primaryTextColor: assistantPrimaryTextColor,
                            secondaryTextColor: assistantSecondaryTextColor
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 44)
        }
    }

    @ViewBuilder
    private func continuationMarkdown(
        _ content: String,
        prepared: ETPreparedMarkdownRenderPayload?
    ) -> some View {
        if let prepared, prepared.sourceText == content {
            ETAdvancedMarkdownRenderer(
                content: content,
                preparedContent: prepared,
                enableMarkdown: true,
                isOutgoing: false,
                enableAdvancedRenderer: enableAdvancedRenderer,
                enableMathRendering: enableAdvancedRenderer,
                customTextColor: assistantTextColorOverride,
                customTextStyleColors: assistantTextStyleColors
            )
            .textSelection(.enabled)
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 44)
        }
    }

    private func toolExpansionBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { expandedToolIDs.contains(id) },
            set: { isExpanded in
                if isExpanded {
                    expandedToolIDs.insert(id)
                } else {
                    expandedToolIDs.remove(id)
                }
            }
        )
    }

    private var contextSubtitle: String {
        String(
            format: NSLocalizedString(
                "来自“%@” · 摘要 %d 条 · 保留 %d 轮原文",
                comment: "Continuation context bubble subtitle"
            ),
            context.sourceSessionNameSnapshot,
            context.summarizedMessageCount,
            context.retainedRoundCount
        )
    }

    private var activeAppearanceProfile: ChatAppearanceProfile {
        appearanceProfileManager.activeProfile
    }

    private var assistantBubbleFill: Color {
        let slot = activeAppearanceProfile.assistantBubble
        if slot.isEnabled {
            let color = ChatAppearanceColorCodec.color(
                from: slot.hex,
                fallback: Color(uiColor: .secondarySystemBackground)
            )
            return color.opacity(enableBackground ? 0.75 : 1)
        }
        return enableBackground
            ? Color(uiColor: .secondarySystemBackground).opacity(0.75)
            : Color(uiColor: .systemBackground)
    }

    private var assistantTextColorOverride: Color? {
        let slot = colorScheme == .dark
            ? activeAppearanceProfile.assistantDarkText
            : activeAppearanceProfile.assistantLightText
        guard slot.isEnabled else { return nil }
        return ChatAppearanceColorCodec.color(
            from: slot.hex,
            fallback: colorScheme == .dark ? .white : .primary
        )
    }

    private var assistantTextStyleColors: ChatAppearanceTextStyleColors {
        colorScheme == .dark
            ? activeAppearanceProfile.assistantDarkTextStyles
            : activeAppearanceProfile.assistantLightTextStyles
    }

    private var assistantPrimaryTextColor: Color {
        assistantTextColorOverride ?? .primary
    }

    private var assistantSecondaryTextColor: Color {
        assistantTextColorOverride?.opacity(0.78) ?? .secondary
    }

    @ViewBuilder
    private var assistantBubbleBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        if enableNoBubbleUI {
            shape.fill(Color.clear)
        } else if enableLiquidGlass {
            if #available(iOS 26.0, *) {
                shape
                    .fill(assistantBubbleFill)
                    .glassEffect(.clear, in: shape)
                    .clipShape(shape)
            } else {
                shape.fill(assistantBubbleFill)
            }
        } else {
            shape.fill(assistantBubbleFill)
        }
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

    private func setExpansionState(_ newState: ConversationContinuationExpansionState) {
        if newState == .collapsed {
            expandedToolIDs.removeAll()
        }
        if reduceMotion {
            expansionState = newState
        } else {
            withAnimation(.spring(response: 0.34, dampingFraction: 1)) {
                expansionState = newState
            }
        }
        onExpansionStateChange(newState)
    }

    @MainActor
    private func preparePreview() async {
        displayContent = nil
        preparedPreview = [:]
        preparedFull = [:]
        expandedToolIDs.removeAll()
        isPreparingFull = false

        let contextID = context.id
        let context = context
        let summaryHeading = NSLocalizedString(
            "较早对话摘要",
            comment: "Continuation context summary heading"
        )
        let retainedHeading = NSLocalizedString(
            "最近对话原文",
            comment: "Continuation context retained messages heading"
        )
        let roleTitles = Dictionary(
            uniqueKeysWithValues: [
                MessageRole.system,
                .user,
                .assistant,
                .tool,
                .error
            ].map { ($0.rawValue, roleTitle($0)) }
        )
        let content = await Task.detached(priority: .utility) {
            ConversationContinuationDisplayContent.make(
                context: context,
                summaryHeading: summaryHeading,
                retainedHeading: retainedHeading,
                roleTitles: roleTitles
            )
        }.value
        guard !Task.isCancelled, self.context.id == contextID else { return }

        displayContent = content
        let prepared = await prepareMarkdownSegments(content.preview)
        guard !Task.isCancelled, self.context.id == contextID else { return }
        preparedPreview = prepared
        if !content.isPreviewTruncated {
            preparedFull = prepared
        } else if expansionState == .full {
            await prepareFullContent()
        }
    }

    @MainActor
    private func prepareFullContent() async {
        guard preparedFull.isEmpty,
              !isPreparingFull,
              let displayContent else { return }
        isPreparingFull = true
        defer { isPreparingFull = false }
        let contextID = context.id
        let prepared = await prepareMarkdownSegments(displayContent.full)
        guard !Task.isCancelled, context.id == contextID else { return }
        preparedFull = prepared
    }

    @MainActor
    private func prepareMarkdownSegments(
        _ segments: [ConversationContinuationContentSegment]
    ) async -> [String: ETPreparedMarkdownRenderPayload] {
        var prepared: [String: ETPreparedMarkdownRenderPayload] = [:]
        for segment in segments {
            guard case .markdown(let id, let content) = segment else { continue }
            prepared[id] = await ETMarkdownPrecomputeWorker.shared.prepare(source: content)
            try? Task.checkCancellation()
            if Task.isCancelled { return [:] }
        }
        return prepared
    }
}

struct ContextCompressionOneTapView: View {
    typealias ProgressHandler = @MainActor @Sendable (ContextCompressionProgress) -> Void

    @Environment(\.dismiss) private var dismiss

    let session: ChatSession
    let onCompress: (@escaping ProgressHandler) async throws -> ChatSession

    @State private var progress = ContextCompressionProgress(phase: .preparing)
    @State private var compressionTask: Task<Void, Never>?
    @State private var hasStarted = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack {
                Spacer()

                ProgressView()
                    .controlSize(.large)

                Text(NSLocalizedString(
                    "正在压缩为续聊",
                    comment: "One-tap context compression progress title"
                ))
                .font(.headline)

                Text(progressText(progress))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Text(String(
                    format: NSLocalizedString(
                        "原会话“%@”会完整保留。",
                        comment: "One-tap context compression source preservation"
                    ),
                    session.name
                ))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

                Spacer()
            }
            .padding()
            .navigationTitle(NSLocalizedString(
                "压缩为续聊",
                comment: "One-tap context compression navigation title"
            ))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString(
                        "停止",
                        comment: "Stop one-tap context compression action"
                    )) {
                        compressionTask?.cancel()
                    }
                    .disabled(compressionTask == nil)
                }
            }
            .onAppear(perform: startIfNeeded)
            .onDisappear {
                compressionTask?.cancel()
            }
            .interactiveDismissDisabled(compressionTask != nil)
            .alert(NSLocalizedString(
                "压缩失败",
                comment: "One-tap context compression failure title"
            ), isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button(NSLocalizedString("关闭", comment: "Close one-tap compression error")) {
                    dismiss()
                }
            } message: {
                Text(errorMessage ?? "")
            }
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
            return NSLocalizedString("正在准备完整对话与附件…", comment: "One-tap compression preparing progress")
        case .summarizing:
            return NSLocalizedString("正在生成续聊摘要…", comment: "One-tap compression summary progress")
        case .saving:
            return NSLocalizedString("正在保存并切换到新会话…", comment: "One-tap compression saving progress")
        }
    }
}

struct ContextCompressionOptionsView: View {
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
        NavigationStack {
            Form {
                Section {
                    Label {
                        Text(NSLocalizedString(
                            "系统会创建并切换到一个新的独立会话；原会话和全部消息保持不变，之后仍可继续。",
                            comment: "Context compression options introduction"
                        ))
                    } icon: {
                        Image(systemName: "arrow.triangle.branch")
                            .foregroundStyle(.tint)
                    }
                }

                Section {
                    Picker(
                        NSLocalizedString("保留最近原文", comment: "Context compression retained rounds picker"),
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
                            Text("\(model.model.displayName) · \(model.provider.name)")
                                .tag(Optional(model.id))
                        }
                    }
                } footer: {
                    Text(NSLocalizedString(
                        "最近轮次会保留原文，其余历史将一次性生成续聊摘要，原会话不会改变。",
                        comment: "Context compression retention explanation"
                    ))
                }

                Section {
                    TextEditor(text: $focusInstruction)
                        .frame(minHeight: 88)
                } header: {
                    Text(NSLocalizedString("额外侧重点（可选）", comment: "Context compression focus section"))
                } footer: {
                    Text(NSLocalizedString(
                        "例如需要特别保留的人物关系、术语、写作风格或未完成事项。留空时会均衡保留全部续聊信息。",
                        comment: "Context compression focus explanation"
                    ))
                }

                if let progress {
                    Section {
                        HStack {
                            ProgressView()
                            Text(progressText(progress))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
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
                        .frame(maxWidth: .infinity)
                    }
                    .disabled(compressionTask != nil || models.isEmpty)
                } footer: {
                    if models.isEmpty {
                        Text(NSLocalizedString(
                            "请先激活一个聊天模型。",
                            comment: "Context compression missing model hint"
                        ))
                    }
                }
            }
            .navigationTitle(NSLocalizedString("压缩为续聊", comment: "Context compression options title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(compressionTask == nil
                        ? NSLocalizedString("取消", comment: "")
                        : NSLocalizedString("停止", comment: "Stop context compression action")) {
                        if let compressionTask {
                            compressionTask.cancel()
                        } else {
                            dismiss()
                        }
                    }
                }
            }
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
            return NSLocalizedString("正在准备完整对话与附件…", comment: "Context compression preparing progress")
        case .summarizing:
            return NSLocalizedString("正在生成续聊摘要…", comment: "Context compression summary progress")
        case .saving:
            return NSLocalizedString("正在保存并切换到新会话…", comment: "Context compression saving progress")
        }
    }
}

extension ChatView {
    var contextCompressionReminderRefreshKey: ContextCompressionReminderRefreshKey {
        ContextCompressionReminderRefreshKey(
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
        guard ContextCompressionReminderPolicy.shouldEvaluateReminder(
            messageCount: messages.count,
            currentSessionID: sessionID,
            continuationContext: context
        ) else {
            return
        }
        let estimate = await Task.detached(priority: .utility) {
            ContextCompressionReminderEstimator.estimate(
                messages: messages,
                continuationContext: context
            )
        }.value
        try? Task.checkCancellation()
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
        let notificationKey = ContextCompressionReminderNotificationKey(
            sessionID: session.id,
            continuationID: context?.id,
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
    func presentPendingContextCompressionNotification() async {
        guard let sessionID = localNotificationCenter.pendingContextCompressionSessionID,
              let session = viewModel.chatSessions.first(where: { $0.id == sessionID }),
              !session.isTemporary else {
            return
        }
        _ = viewModel.setCurrentSessionIfExists(sessionID: sessionID)
        contextCompressionReminderSourceSession = session
        _ = localNotificationCenter.consumePendingContextCompressionSessionID()
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
