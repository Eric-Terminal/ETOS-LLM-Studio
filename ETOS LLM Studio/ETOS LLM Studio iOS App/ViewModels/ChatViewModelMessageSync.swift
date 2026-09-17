// ============================================================================
// ChatViewModelMessageSync.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件负责消息列表的显示同步、增量刷新、懒加载和工具/推理状态管理。
// ============================================================================

import Combine
import Foundation
import ETOSCore
import SwiftUI

extension ChatViewModel {
    func hasAutoOpenedPendingToolCall(_ toolCallID: String) -> Bool {
        autoOpenedPendingToolCallIDs.contains(toolCallID)
    }

    func isAutoReasoningPreview(for messageID: UUID) -> Bool {
        autoReasoningPreviewMessageIDs.contains(messageID)
    }

    func setReasoningExpanded(_ isExpanded: Bool, for messageID: UUID) {
        reasoningExpandedState[messageID] = isExpanded
        userControlledReasoningPreviewMessageIDs.insert(messageID)
        autoReasoningPreviewMessageIDs.remove(messageID)
    }

    func markPendingToolCallAutoOpened(_ toolCallID: String) {
        guard !toolCallID.isEmpty else { return }
        autoOpenedPendingToolCallIDs.insert(toolCallID)
    }

    func beginHistorySession(_ sessionID: UUID?) {
        guard historyWindowSessionID != sessionID else { return }
        historyWindowSessionID = sessionID
        historyWindow = nil
        allMessagesForSession = []
        preparedMessageSnapshot = nil
        latestMessageAllowsQuickRetry = false
        responseAttemptVersionIndex = [:]
        responseAttemptIndexPublishedRevision = -1
        visibleMessagesCache = []
        retainedRenderMessageIDs.removeAll(keepingCapacity: true)
        messageStateByID.removeAll(keepingCapacity: true)
        cleanupPreparedMarkdownCache(validIDs: [])
        cleanupStreamingMarkdownPreparation(validIDs: [])
        updateDisplayedStatesIfNeeded([])
        updateHistoryBoundaryState(for: ChatHistoryWindow(lowerBound: 0, upperBound: 0))
    }

    func applyMessagesUpdate(_ update: ChatMessageListSnapshot) {
        let sessionID = update.sessionID
        let didChangeSession = historyWindowSessionID != sessionID
        if didChangeSession {
            beginHistorySession(sessionID)
        }
        let canApplyChanges = !didChangeSession && update.baseRevision == preparedMessageSnapshot?.revision
            && preparedMessageSnapshot != nil
        let previousVisibleMessages = visibleMessagesCache
        let previousIndex = preparedMessageSnapshot?.historyIndex
        let previousHistoryWindow = historyWindow
        preparedMessageSnapshot = update
        messageRenderConfiguration = update.renderConfiguration
        allMessagesForSession = update.messages
        visibleMessagesCache = update.visibleMessages
        if latestMessageAllowsQuickRetry != update.canQuickRetry {
            latestMessageAllowsQuickRetry = update.canQuickRetry
        }
        if responseAttemptIndexPublishedRevision != update.versionRevision || !canApplyChanges {
            responseAttemptIndexPublishedRevision = update.versionRevision
            responseAttemptVersionIndex = update.versionIndex
        }
        if previousVisibleMessages.isEmpty, !visibleMessagesCache.isEmpty {
            historyWindow = nil
        } else if let previousHistoryWindow, historyWindow != nil,
                  update.historyStructureChanged || !canApplyChanges {
            if usesManualHistoryLoading {
                historyWindow = ChatHistoryWindowSupport.rebased(
                    previousHistoryWindow,
                    from: previousVisibleMessages,
                    to: visibleMessagesCache,
                    minimumTrailingWeightedCount: lazyLoadMessageCount,
                    previousIndex: previousIndex, index: update.historyIndex
                )
            } else if usesAutomaticHistoryWindow {
                historyWindow = ChatHistoryWindowSupport.rebased(
                    previousHistoryWindow,
                    from: previousVisibleMessages,
                    to: visibleMessagesCache,
                    minimumTrailingWeightedCount: automaticHistoryWindowSize,
                    previousIndex: previousIndex, index: update.historyIndex
                )
            } else {
                historyWindow = ChatHistoryWindowSupport.full(messageCount: visibleMessagesCache.count)
            }
        }
        let hasSameMessageIdentity = canApplyChanges && update.hasSameMessageIdentity
        if !hasSameMessageIdentity {
            allMessageIdentityVersion &+= 1
        }
        autoOpenedPendingToolCallIDs.formIntersection(update.existingToolCallIDs)
        updateAutoReasoningPreviewState()
        let needsDisplayRefilter = toolCallResultIDs != update.toolCallResultIDs
        if needsDisplayRefilter {
            toolCallResultIDs = update.toolCallResultIDs
        }
        if latestAssistantMessageID != update.latestAssistantMessage?.id {
            latestAssistantMessageID = update.latestAssistantMessage?.id
        }
        if latestAgentToolExecutionPreview != update.agentToolPreview {
            latestAgentToolExecutionPreview = update.agentToolPreview
        }
        if hasSameMessageIdentity, !update.historyStructureChanged, !messages.isEmpty, !update.forceRendering {
            applyIncrementalMessageUpdates(update.changes)
            if needsDisplayRefilter { updateDisplayMessagesIfNeeded() }
        } else {
            updateDisplayedMessages(forcePreparation: update.forceRendering)
        }
    }

    func updateDisplayedStatesIfNeeded(_ newMessages: [ChatMessage], forcePreparation: Bool = false) {
        let currentIDs = messages.map(\.id)
        let newIDs = newMessages.map(\.id)
        let visibleIDSet = Set(newIDs)
        if forcePreparation {
            retainedRenderMessageIDs.removeAll()
        } else {
            updateRetainedRenderMessageIDs(visibleIDs: visibleIDSet)
        }
        let retainedIDSet = visibleIDSet.union(retainedRenderMessageIDs)

        var newStates: [ChatMessageRenderState] = []
        newStates.reserveCapacity(newMessages.count)

        for message in newMessages {
            let state: ChatMessageRenderState
            if let existing = messageStateByID[message.id] {
                state = existing
                if !forcePreparation, !messageRenderConfiguration.hasRoleplay,
                   !messageRenderConfiguration.rendersHTML, existing.message == message {
                    newStates.append(existing)
                    continue
                }
            } else {
                let created = ChatMessageRenderState(message: message, defersUserContentPreparation: true)
                messageStateByID[message.id] = created
                state = created
            }
            state.update(with: message)
            if canUseStreamingMarkdownFastPath(for: message) {
                state.updateVisualMessage(message)
                state.updateRoleplayHTML(nil)
                scheduleStreamingMarkdownPreparationIfEligible(for: state, message: message)
            } else {
                scheduleVisualMessagePreparationIfNeeded(for: state, source: message)
                scheduleReasoningMarkdownPreparationIfNeeded(for: message)
            }
            newStates.append(state)
        }

        if !messageStateByID.isEmpty {
            messageStateByID = messageStateByID.filter { retainedIDSet.contains($0.key) }
        }
        cleanupPreparedMarkdownCache(validIDs: retainedIDSet)
        cleanupStreamingMarkdownPreparation(validIDs: retainedIDSet)

        if currentIDs != newIDs {
            messages = newStates
            updateDisplayMessagesIfNeeded(with: newStates)
        } else {
            updateDisplayMessagesIfNeeded()
        }
    }

    /// 最近离开窗口的渲染结果保留一小段，来回翻阅长 Markdown 时无需重复解析。
    func updateRetainedRenderMessageIDs(visibleIDs: Set<UUID>) {
        let validMessageIDs = preparedMessageSnapshot?.visibleIDs ?? Set(visibleMessagesCache.map(\.id))
        retainedRenderMessageIDs.removeAll {
            visibleIDs.contains($0) || !validMessageIDs.contains($0)
        }
        let newlyHiddenIDs = messages.map(\.id).filter {
            validMessageIDs.contains($0)
                && !visibleIDs.contains($0)
                && !retainedRenderMessageIDs.contains($0)
        }
        retainedRenderMessageIDs.append(contentsOf: newlyHiddenIDs)
        if retainedRenderMessageIDs.count > retainedRenderMessageCacheLimit {
            retainedRenderMessageIDs.removeFirst(
                retainedRenderMessageIDs.count - retainedRenderMessageCacheLimit
            )
        }
    }

    func scheduleMarkdownPreparationIfNeeded(for message: ChatMessage) {
        let messageID = message.id
        let sourceText = message.content

        // 截断的 Markdown 可能含有未闭合语法；预览统一显示纯文本，全文按需打开。
        if messageStateByID[messageID]?.isUserContentTruncated == true {
            markdownPrepareTasks.removeValue(forKey: messageID)?.cancel()
            markdownPrepareGenerations.removeValue(forKey: messageID)
            preparedMarkdownByMessageID.removeValue(forKey: messageID)
            return
        }

        if isActivelyStreaming(message) {
            markdownPrepareTasks[messageID]?.cancel()
            markdownPrepareTasks.removeValue(forKey: messageID)
            return
        }

        if preparedMarkdownByMessageID[messageID]?.sourceText == sourceText {
            markdownPrepareTasks[messageID]?.cancel()
            markdownPrepareTasks.removeValue(forKey: messageID)
            finishPreparedMarkdownHandoff(for: messageID, channel: .content)
            return
        }

        let generation = (markdownPrepareGenerations[messageID] ?? 0) &+ 1
        markdownPrepareGenerations[messageID] = generation
        markdownPrepareTasks[messageID]?.cancel()
        markdownPrepareTasks[messageID] = Task(priority: .utility) { [weak self, messageID, sourceText, generation] in
            let prepared = await ETMarkdownPrecomputeWorker.shared.prepare(source: sourceText)
            guard !Task.isCancelled, let self else { return }
            guard self.markdownPrepareGenerations[messageID] == generation else { return }
            guard self.messageStateByID[messageID]?.visualMessage.content == sourceText else { return }
            self.finishPreparedMarkdownHandoff(
                prepared,
                for: messageID,
                channel: .content
            )
            if self.markdownPrepareGenerations[messageID] == generation {
                self.markdownPrepareTasks[messageID] = nil
            }
        }
    }

    func scheduleVisualMessagePreparationIfNeeded(for state: ChatMessageRenderState, source message: ChatMessage) {
        let rules = MessageRegexRuleStore.shared.rules
        let previewCharacterLimit = AppConfigStore.shared.userMessagePreviewCharacterLimit
        let sessionID = currentSession?.id
        let sourceMessages = allMessagesForSession
        let renderConfiguration = messageRenderConfiguration
        let supportsRoleplayRendering = message.role == .assistant || message.role == .user
        let needsRoleplayPreparation = supportsRoleplayRendering
            && (messageRenderConfiguration.hasRoleplay || messageRenderConfiguration.rendersHTML)
        guard message.role == .user || Self.hasVisualRegexRule(in: rules, for: message) || needsRoleplayPreparation else {
            visualMessagePrepareTasks[message.id]?.cancel()
            visualMessagePrepareTasks.removeValue(forKey: message.id)
            visualMessagePrepareGenerations.removeValue(forKey: message.id)
            state.updateVisualMessage(message)
            state.updateRoleplayHTML(nil)
            scheduleMarkdownPreparationIfNeeded(for: message)
            return
        }

        let messageID = message.id
        if message.role != .user {
            state.updateVisualMessage(message)
        }
        let generation = (visualMessagePrepareGenerations[messageID] ?? 0) &+ 1
        visualMessagePrepareGenerations[messageID] = generation
        visualMessagePrepareTasks[messageID]?.cancel()
        visualMessagePrepareTasks[messageID] = Task(priority: .utility) { [weak self, messageID, sourceMessage = message, rules, generation, sessionID, sourceMessages, renderConfiguration] in
            let prepared = await Task.detached(priority: .utility) {
                var visualMessage = renderConfiguration.hasRoleplay ? ChatService.visualMessage(
                    from: sourceMessage,
                    sessionID: sessionID,
                    messages: sourceMessages,
                    rules: rules
                ) : ChatService.visualMessage(from: sourceMessage, rules: rules)
                let preview = sourceMessage.role == .user
                    ? ChatUserMessagePreview(content: visualMessage.content, characterLimit: previewCharacterLimit)
                    : nil
                if let preview {
                    visualMessage.content = preview.content
                }
                let htmlRenderingEnabled = renderConfiguration.rendersHTML
                let displayedHTML: String? = htmlRenderingEnabled ? sessionID.flatMap { sessionID in
                    let value = RoleplayStore.shared.variableSnapshot(sessionID: sessionID).value(
                        scope: .message,
                        path: RoleplayDisplayedMessageBridge.variableKey,
                        messageID: sourceMessage.id,
                        versionIndex: sourceMessage.getCurrentVersionIndex()
                    )
                    guard case .string(let html) = value else { return nil }
                    return html
                } : nil
                let html: RoleplayHTMLExtraction?
                let supportsRoleplayHTML = (sourceMessage.role == .assistant || sourceMessage.role == .user)
                    && preview?.isTruncated != true
                if supportsRoleplayHTML, htmlRenderingEnabled, let displayedHTML {
                    html = RoleplayHTMLExtraction(
                        remainingText: "",
                        documents: [RoleplayHTMLDocument(id: 0, source: displayedHTML)]
                    )
                } else {
                    html = supportsRoleplayHTML && htmlRenderingEnabled
                        ? RoleplayHTMLExtractor.extract(from: visualMessage.content)
                        : nil
                }
                return (visualMessage, html, preview?.isTruncated == true)
            }.value

            guard !Task.isCancelled, let self else { return }
            guard self.visualMessagePrepareGenerations[messageID] == generation else { return }
            guard let state = self.messageStateByID[messageID],
                  state.message == sourceMessage else {
                return
            }
            state.updateVisualMessage(prepared.0, isUserContentTruncated: prepared.2)
            state.updateRoleplayHTML(prepared.1?.containsHTML == true ? prepared.1 : nil)
            self.scheduleMarkdownPreparationIfNeeded(for: prepared.0)
            if self.visualMessagePrepareGenerations[messageID] == generation {
                self.visualMessagePrepareTasks[messageID] = nil
            }
        }
    }

    func scheduleReasoningMarkdownPreparationIfNeeded(for message: ChatMessage) {
        let messageID = message.id
        let isStreamingReasoningMessage = isActivelyStreaming(message)
        updateReasoningThinkingTitle(for: messageID, sourceText: message.reasoningContent)
        guard ChatReasoningRenderPolicy.shouldPrepareReasoningMarkdown(
            message: message,
            isStreaming: isStreamingReasoningMessage
        ), let sourceText = message.reasoningContent else {
            finishPreparedMarkdownHandoff(
                for: messageID,
                channel: .reasoning,
                removesPreparedPayload: true
            )
            reasoningMarkdownPrepareTasks[messageID]?.cancel()
            reasoningMarkdownPrepareTasks.removeValue(forKey: messageID)
            reasoningMarkdownPrepareGenerations.removeValue(forKey: messageID)
            return
        }

        if preparedReasoningMarkdownByMessageID[messageID]?.sourceText == sourceText {
            reasoningMarkdownPrepareTasks[messageID]?.cancel()
            reasoningMarkdownPrepareTasks.removeValue(forKey: messageID)
            finishPreparedMarkdownHandoff(for: messageID, channel: .reasoning)
            return
        }

        let generation = (reasoningMarkdownPrepareGenerations[messageID] ?? 0) &+ 1
        reasoningMarkdownPrepareGenerations[messageID] = generation
        reasoningMarkdownPrepareTasks[messageID]?.cancel()
        reasoningMarkdownPrepareTasks[messageID] = Task(priority: .utility) { [weak self, messageID, sourceText, generation] in
            let prepared = await ETMarkdownPrecomputeWorker.shared.prepare(source: sourceText)
            guard !Task.isCancelled, let self else { return }
            guard self.reasoningMarkdownPrepareGenerations[messageID] == generation else { return }
            guard self.messageStateByID[messageID]?.message.reasoningContent == sourceText else { return }
            self.finishPreparedMarkdownHandoff(
                prepared,
                for: messageID,
                channel: .reasoning
            )
            if self.reasoningMarkdownPrepareGenerations[messageID] == generation {
                self.reasoningMarkdownPrepareTasks[messageID] = nil
            }
        }
    }

    /// prepared payload、流式视图结束和布局 revision 必须在同一事务中发布，
    /// 防止 SwiftUI 在 UIKit/静态 Markdown 交接的中间状态缓存错误行高。
    func finishPreparedMarkdownHandoff(
        _ prepared: ETPreparedMarkdownRenderPayload? = nil,
        for messageID: UUID,
        channel: ETStreamingMarkdownChannel,
        removesPreparedPayload: Bool = false
    ) {
        let state = messageStateByID[messageID]
        let isAwaitingHandoff = state?.streamingMarkdownState.isAwaitingStaticHandoff(
            channel: channel
        ) == true
        let payloadNeedsUpdate: Bool
        switch channel {
        case .content:
            if removesPreparedPayload {
                payloadNeedsUpdate = preparedMarkdownByMessageID[messageID] != nil
            } else if let prepared {
                payloadNeedsUpdate = preparedMarkdownByMessageID[messageID]?.sourceText != prepared.sourceText
            } else {
                payloadNeedsUpdate = false
            }
        case .reasoning:
            if removesPreparedPayload {
                payloadNeedsUpdate = preparedReasoningMarkdownByMessageID[messageID] != nil
            } else if let prepared {
                payloadNeedsUpdate = preparedReasoningMarkdownByMessageID[messageID]?.sourceText != prepared.sourceText
            } else {
                payloadNeedsUpdate = false
            }
        }
        guard payloadNeedsUpdate || isAwaitingHandoff else { return }

        var transaction = Transaction()
        transaction.animation = nil
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            switch channel {
            case .content:
                if removesPreparedPayload {
                    preparedMarkdownByMessageID.removeValue(forKey: messageID)
                } else if let prepared {
                    preparedMarkdownByMessageID[messageID] = prepared
                }
            case .reasoning:
                if removesPreparedPayload {
                    preparedReasoningMarkdownByMessageID.removeValue(forKey: messageID)
                } else if let prepared {
                    preparedReasoningMarkdownByMessageID[messageID] = prepared
                }
            }
            if isAwaitingHandoff {
                state?.streamingMarkdownState.completeStaticHandoff(channel: channel)
            }
            state?.invalidateLayoutAfterRendererHandoff()
        }
    }

    func updateReasoningThinkingTitle(for messageID: UUID, sourceText: String?) {
        guard let sourceText,
              !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let thinkingTitle = ETPreparedMarkdownRenderPayload.extractThinkingTitle(from: sourceText),
              !thinkingTitle.isEmpty else {
            if reasoningThinkingTitleByMessageID[messageID] != nil {
                reasoningThinkingTitleByMessageID.removeValue(forKey: messageID)
            }
            return
        }

        if reasoningThinkingTitleByMessageID[messageID] != thinkingTitle {
            reasoningThinkingTitleByMessageID[messageID] = thinkingTitle
        }
    }

    func cleanupPreparedMarkdownCache(validIDs: Set<UUID>) {
        if !preparedMarkdownByMessageID.isEmpty {
            preparedMarkdownByMessageID = preparedMarkdownByMessageID.filter { validIDs.contains($0.key) }
        }
        if !preparedReasoningMarkdownByMessageID.isEmpty {
            preparedReasoningMarkdownByMessageID = preparedReasoningMarkdownByMessageID.filter { validIDs.contains($0.key) }
        }
        if !reasoningThinkingTitleByMessageID.isEmpty {
            reasoningThinkingTitleByMessageID = reasoningThinkingTitleByMessageID.filter { validIDs.contains($0.key) }
        }
        if !visualMessagePrepareGenerations.isEmpty {
            visualMessagePrepareGenerations = visualMessagePrepareGenerations.filter { validIDs.contains($0.key) }
        }
        if !markdownPrepareGenerations.isEmpty {
            markdownPrepareGenerations = markdownPrepareGenerations.filter { validIDs.contains($0.key) }
        }
        if !reasoningMarkdownPrepareGenerations.isEmpty {
            reasoningMarkdownPrepareGenerations = reasoningMarkdownPrepareGenerations.filter { validIDs.contains($0.key) }
        }
        if !visualMessagePrepareTasks.isEmpty {
            for (messageID, task) in visualMessagePrepareTasks where !validIDs.contains(messageID) {
                task.cancel()
            }
            visualMessagePrepareTasks = visualMessagePrepareTasks.filter { validIDs.contains($0.key) }
        }
        if !markdownPrepareTasks.isEmpty {
            for (messageID, task) in markdownPrepareTasks where !validIDs.contains(messageID) {
                task.cancel()
            }
            markdownPrepareTasks = markdownPrepareTasks.filter { validIDs.contains($0.key) }
        }
        if !reasoningMarkdownPrepareTasks.isEmpty {
            for (messageID, task) in reasoningMarkdownPrepareTasks where !validIDs.contains(messageID) {
                task.cancel()
            }
            reasoningMarkdownPrepareTasks = reasoningMarkdownPrepareTasks.filter { validIDs.contains($0.key) }
        }
    }

    func updateDisplayMessagesIfNeeded(with source: [ChatMessageRenderState]? = nil) {
        let base = source ?? messages
        let filtered = filterDisplayMessages(base)
        let newIDs = filtered.map(\.id)
        guard displayMessageIDs != newIDs else { return }
        displayMessageIDs = newIDs
        displayMessages = filtered
        displayMessageIdentityVersion &+= 1
    }

    func applyIncrementalMessageUpdates(_ changes: [ChatMessageListSnapshot.Change]) {
        let visibleIDs = Set(messages.map(\.id))
        for change in changes {
            let newMessage = change.message
            if visibleIDs.contains(newMessage.id) {
                if let state = messageStateByID[newMessage.id] {
                    let usesFastPath = canUseStreamingMarkdownFastPath(for: newMessage)
                        && change.isTextOnly
                    if usesFastPath {
                        state.updateWithoutPublishing(with: newMessage)
                        scheduleStreamingMarkdownPreparationIfEligible(for: state, message: newMessage)
                    } else {
                        state.update(with: newMessage)
                        if canUseStreamingMarkdownFastPath(for: newMessage) {
                            state.updateVisualMessage(newMessage)
                            state.updateRoleplayHTML(nil)
                            scheduleStreamingMarkdownPreparationIfEligible(for: state, message: newMessage)
                        } else {
                            scheduleVisualMessagePreparationIfNeeded(for: state, source: newMessage)
                            scheduleReasoningMarkdownPreparationIfNeeded(for: newMessage)
                        }
                    }
                }
            }
        }
    }

    func updateAutoReasoningPreviewState() {
        guard let latestAssistantMessage = preparedMessageSnapshot?.latestAssistantMessage else {
            autoReasoningPreviewMessageIDs.removeAll()
            userControlledReasoningPreviewMessageIDs.removeAll()
            return
        }
        autoReasoningPreviewMessageIDs.formIntersection([latestAssistantMessage.id])
        userControlledReasoningPreviewMessageIDs.formIntersection([latestAssistantMessage.id])

        let hasReasoning = Self.hasReasoningContent(latestAssistantMessage)
        let hasBodyContent = Self.hasVisibleAssistantBodyContent(latestAssistantMessage)
        let hasToolCalls = !(latestAssistantMessage.toolCalls ?? []).isEmpty
        let wasAutoExpanded = autoReasoningPreviewMessageIDs.contains(latestAssistantMessage.id)
        let isUserControlled = userControlledReasoningPreviewMessageIDs.contains(latestAssistantMessage.id)

        guard let targetExpandedState = Self.autoReasoningDisclosureTargetState(
            autoPreviewEnabled: enableAutoReasoningPreview,
            isUserControlled: isUserControlled,
            isSendingMessage: isSendingMessage,
            hasReasoning: hasReasoning,
            hasBodyContent: hasBodyContent,
            hasToolCalls: hasToolCalls,
            wasAutoExpanded: wasAutoExpanded
        ) else {
            if !hasReasoning {
                autoReasoningPreviewMessageIDs.remove(latestAssistantMessage.id)
                userControlledReasoningPreviewMessageIDs.remove(latestAssistantMessage.id)
            }
            return
        }

        reasoningExpandedState[latestAssistantMessage.id] = targetExpandedState
        if targetExpandedState {
            autoReasoningPreviewMessageIDs.insert(latestAssistantMessage.id)
        } else {
            autoReasoningPreviewMessageIDs.remove(latestAssistantMessage.id)
        }
    }

    func refreshCurrentSessionSendingState() {
        let wasSendingMessage = isSendingMessage
        guard let currentSessionID = currentSession?.id else {
            isSendingMessage = false
            if wasSendingMessage {
                finalizeStreamingMarkdownIfNeeded()
            }
            return
        }
        isSendingMessage = runningSessionIDs.contains(currentSessionID)
        if isSendingMessage {
            pendingSendSubmissionSessionIDs.remove(currentSessionID)
        }
        if wasSendingMessage, !isSendingMessage {
            finalizeStreamingMarkdownIfNeeded()
        }
    }

    func ensureHistoryWindowPrepared() {
        guard historyWindow == nil else {
            historyWindow = historyWindow?.clamped(to: visibleMessagesCache.count)
            return
        }

        if usesAutomaticHistoryWindow {
            historyWindow = ChatHistoryWindowSupport.trailing(
                in: visibleMessagesCache,
                weightedLimit: automaticHistoryWindowSize,
                index: preparedMessageSnapshot?.historyIndex
            )
        } else if usesManualHistoryLoading {
            historyWindow = ChatHistoryWindowSupport.trailing(
                in: visibleMessagesCache,
                weightedLimit: lazyLoadMessageCount,
                index: preparedMessageSnapshot?.historyIndex
            )
        } else {
            historyWindow = ChatHistoryWindowSupport.full(messageCount: visibleMessagesCache.count)
        }
    }

    func ensureVisibleMessagesCachePrepared() {
        if visibleMessagesCache.isEmpty, let preparedMessageSnapshot {
            visibleMessagesCache = preparedMessageSnapshot.visibleMessages
        }
    }

    func refreshVisualMessagesAfterRegexRulesChange() {
        messageRenderingRefreshSubject.send(())
    }

    nonisolated static func hasVisualRegexRule(in rules: [MessageRegexRule], for message: ChatMessage) -> Bool {
        let scope: MessageRegexRoleScope
        switch message.role {
        case .user:
            scope = .user
        case .assistant:
            scope = .assistant
        case .system, .tool, .error:
            return false
        }

        return rules.contains { rule in
            rule.isEnabled && rule.mode == .visualOnly && rule.scopes.contains(scope)
        }
    }

    func updateHistoryFullyLoadedIfNeeded(_ newValue: Bool) {
        guard isHistoryFullyLoaded != newValue else { return }
        isHistoryFullyLoaded = newValue
    }

    func updateLaterHistoryFullyLoadedIfNeeded(_ newValue: Bool) {
        guard isLaterHistoryFullyLoaded != newValue else { return }
        isLaterHistoryFullyLoaded = newValue
    }

    func updateHistoryBoundaryState(for window: ChatHistoryWindow) {
        let clamped = window.clamped(to: visibleMessagesCache.count)
        updateHistoryFullyLoadedIfNeeded(clamped.lowerBound == 0)
        updateLaterHistoryFullyLoadedIfNeeded(clamped.upperBound == visibleMessagesCache.count)
    }

    func filterDisplayMessages(_ source: [ChatMessageRenderState]) -> [ChatMessageRenderState] {
        guard !toolCallResultIDs.isEmpty else { return source }
        return source.filter {
            ChatJumpTargetSupport.isRenderedAsBubble(
                $0.message,
                hiddenToolCallResultIDs: toolCallResultIDs
            )
        }
    }

    /// 导航索引与真实消息栈使用同一套过滤规则，避免跳到已折叠进工具卡片的隐藏消息。
    func messageNavigationIDs() -> [UUID] {
        ensureVisibleMessagesCachePrepared()
        return ChatJumpTargetSupport.renderedMessageIDs(
            in: visibleMessagesCache,
            hiddenToolCallResultIDs: toolCallResultIDs
        )
    }

    nonisolated static func lazyLoadWeight(for message: ChatMessage) -> Int {
        message.role == .tool ? 0 : 1
    }

    nonisolated static func lazyLoadWeight(in messages: [ChatMessage], at index: Int) -> Int {
        let message = messages[index]
        if message.role == .tool {
            return 0
        }
        guard message.role == .error else {
            return 1
        }

        var cursor = index
        while cursor > messages.startIndex {
            cursor = messages.index(before: cursor)
            let previousMessage = messages[cursor]
            if previousMessage.role == .assistant {
                return 0
            }
            if previousMessage.role == .user {
                return 1
            }
        }

        return 1
    }

    nonisolated static func lazyLoadWeightedMessageCount(in messages: [ChatMessage]) -> Int {
        ChatHistoryWindowSupport.weightedCount(in: messages)
    }

    nonisolated static func suffixMessagesForLazyLoad(_ messages: [ChatMessage], weightedLimit: Int) -> [ChatMessage] {
        let window = ChatHistoryWindowSupport.trailing(in: messages, weightedLimit: weightedLimit)
        return ChatHistoryWindowSupport.messages(in: window, from: messages)
    }

    nonisolated static func autoReasoningDisclosureTargetState(
        autoPreviewEnabled: Bool,
        isUserControlled: Bool = false,
        isSendingMessage: Bool,
        hasReasoning: Bool,
        hasBodyContent: Bool,
        hasToolCalls: Bool = false,
        wasAutoExpanded: Bool
    ) -> Bool? {
        guard autoPreviewEnabled, !isUserControlled else { return nil }
        if isSendingMessage, hasReasoning, !hasBodyContent, !hasToolCalls {
            return true
        }
        if (!isSendingMessage || hasBodyContent || hasToolCalls), wasAutoExpanded {
            return false
        }
        return nil
    }

    nonisolated static func hasReasoningContent(_ message: ChatMessage) -> Bool {
        !(message.reasoningContent ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }

    nonisolated static func hasVisibleAssistantBodyContent(_ message: ChatMessage) -> Bool {
        let trimmedContent = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedContent.isEmpty else { return false }
        switch trimmedContent {
        case "[图片]", "[圖片]", "[Image]", "[画像]":
            return false
        default:
            return true
        }
    }
}
