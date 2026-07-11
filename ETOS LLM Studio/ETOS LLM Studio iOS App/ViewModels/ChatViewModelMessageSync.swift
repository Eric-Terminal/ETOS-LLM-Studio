// ============================================================================
// ChatViewModelMessageSync.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件负责消息列表的显示同步、增量刷新、懒加载和工具/推理状态管理。
// ============================================================================

import Foundation
import ETOSCore

extension ChatViewModel {
    var usesAutomaticHistoryWindow: Bool {
        lazyLoadMessageCount == 0
    }

    var usesManualHistoryLoading: Bool {
        lazyLoadMessageCount > 0
    }

    func updateDisplayedMessages() {
        ensureVisibleMessagesCachePrepared()

        if lastSessionID != currentSession?.id {
            lastSessionID = currentSession?.id
            additionalHistoryLoaded = 0
        }

        let lazyCount = lazyLoadMessageCount
        let filtered = visibleMessagesCache
        let weightedCount = visibleMessagesWeightedCount
        if lazyCount > 0 && weightedCount > lazyCount {
            let limit = lazyCount + additionalHistoryLoaded
            if weightedCount > limit {
                let subset = Self.suffixMessagesForLazyLoad(filtered, weightedLimit: limit)
                updateDisplayedStatesIfNeeded(subset)
                updateHistoryFullyLoadedIfNeeded(false)
            } else {
                updateDisplayedStatesIfNeeded(filtered)
                updateHistoryFullyLoadedIfNeeded(true)
                additionalHistoryLoaded = max(additionalHistoryLoaded, max(0, weightedCount - lazyCount))
            }
        } else if usesAutomaticHistoryWindow && weightedCount > automaticHistoryWindowSize {
            let limit = automaticHistoryWindowSize + additionalHistoryLoaded
            if weightedCount > limit {
                let subset = Self.suffixMessagesForLazyLoad(filtered, weightedLimit: limit)
                updateDisplayedStatesIfNeeded(subset)
                updateHistoryFullyLoadedIfNeeded(false)
            } else {
                updateDisplayedStatesIfNeeded(filtered)
                updateHistoryFullyLoadedIfNeeded(true)
                additionalHistoryLoaded = max(additionalHistoryLoaded, max(0, weightedCount - automaticHistoryWindowSize))
            }
        } else {
            updateDisplayedStatesIfNeeded(filtered)
            updateHistoryFullyLoadedIfNeeded(true)
            additionalHistoryLoaded = 0
        }
    }

    func loadEntireHistory() {
        additionalHistoryLoaded = max(0, visibleMessagesWeightedCount - lazyLoadMessageCount)
        updateDisplayedStatesIfNeeded(visibleMessagesCache)
        updateHistoryFullyLoadedIfNeeded(true)
    }

    func loadMoreHistoryChunk(count: Int? = nil) {
        guard !isHistoryFullyLoaded else { return }
        let increment = count ?? incrementalHistoryBatchSize
        additionalHistoryLoaded += increment
        updateDisplayedMessages()
    }

    @discardableResult
    func loadMoreAutomaticHistoryIfNeeded(count: Int? = nil) -> Bool {
        guard usesAutomaticHistoryWindow, !isHistoryFullyLoaded else { return false }
        let previousLoaded = additionalHistoryLoaded
        let increment = count ?? automaticHistoryBatchSize
        additionalHistoryLoaded += increment
        updateDisplayedMessages()
        return additionalHistoryLoaded != previousLoaded
    }

    func resetLazyLoadState() {
        additionalHistoryLoaded = 0
        updateDisplayedMessages()
    }

    @discardableResult
    func resetAutomaticHistoryWindowIfNeeded() -> Bool {
        guard usesAutomaticHistoryWindow, additionalHistoryLoaded > 0 else { return false }
        resetLazyLoadState()
        return true
    }

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

    func applyMessagesUpdate(_ incomingMessages: [ChatMessage]) {
        let previousMessages = allMessagesForSession
        allMessagesForSession = incomingMessages
        refreshVisibleMessagesCache()
        let hasSameMessageIdentity = hasMatchingMessageIdentity(previousMessages, incomingMessages)
        if !hasSameMessageIdentity {
            allMessageIdentityVersion &+= 1
        }
        syncAutoOpenedPendingToolCallIDs(with: incomingMessages)
        updateAutoReasoningPreviewState(with: incomingMessages)

        if hasSameMessageIdentity {
            applyIncrementalMessageUpdates(previousMessages: previousMessages, incomingMessages: incomingMessages)
            return
        }

        let metadata = collectMessageMetadata(from: incomingMessages)
        if toolCallResultIDs != metadata.toolCallResultIDs {
            toolCallResultIDs = metadata.toolCallResultIDs
        }
        if latestAssistantMessageID != metadata.latestAssistantID {
            latestAssistantMessageID = metadata.latestAssistantID
        }

        updateDisplayedMessages()
    }

    func updateDisplayedStatesIfNeeded(_ newMessages: [ChatMessage]) {
        let currentIDs = messages.map(\.id)
        let newIDs = newMessages.map(\.id)
        let visibleIDSet = Set(newIDs)

        var newStates: [ChatMessageRenderState] = []
        newStates.reserveCapacity(newMessages.count)

        for message in newMessages {
            let state: ChatMessageRenderState
            if let existing = messageStateByID[message.id] {
                state = existing
            } else {
                let created = ChatMessageRenderState(message: message)
                messageStateByID[message.id] = created
                state = created
            }
            state.update(with: message)
            scheduleVisualMessagePreparationIfNeeded(for: state, source: message)
            scheduleReasoningMarkdownPreparationIfNeeded(for: message)
            newStates.append(state)
        }

        if !messageStateByID.isEmpty {
            messageStateByID = messageStateByID.filter { visibleIDSet.contains($0.key) }
        }
        cleanupPreparedMarkdownCache(validIDs: visibleIDSet)

        if currentIDs != newIDs {
            messages = newStates
            updateDisplayMessagesIfNeeded(with: newStates)
        } else {
            updateDisplayMessagesIfNeeded()
        }
    }

    func scheduleMarkdownPreparationIfNeeded(for message: ChatMessage) {
        let messageID = message.id
        let sourceText = message.content

        if preparedMarkdownByMessageID[messageID]?.sourceText == sourceText {
            markdownPrepareTasks[messageID]?.cancel()
            markdownPrepareTasks.removeValue(forKey: messageID)
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
            self.preparedMarkdownByMessageID[messageID] = prepared
            if self.markdownPrepareGenerations[messageID] == generation {
                self.markdownPrepareTasks[messageID] = nil
            }
        }
    }

    func scheduleVisualMessagePreparationIfNeeded(for state: ChatMessageRenderState, source message: ChatMessage) {
        let rules = MessageRegexRuleStore.shared.rules
        let sessionID = currentSession?.id
        let sourceMessages = messages
        let needsRoleplayPreparation = message.role == .assistant && sessionID != nil
        guard Self.hasVisualRegexRule(in: rules, for: message) || needsRoleplayPreparation else {
            visualMessagePrepareTasks[message.id]?.cancel()
            visualMessagePrepareTasks.removeValue(forKey: message.id)
            visualMessagePrepareGenerations.removeValue(forKey: message.id)
            state.updateVisualMessage(message)
            state.updateRoleplayHTML(nil)
            scheduleMarkdownPreparationIfNeeded(for: message)
            return
        }

        let messageID = message.id
        state.updateVisualMessage(message)
        let generation = (visualMessagePrepareGenerations[messageID] ?? 0) &+ 1
        visualMessagePrepareGenerations[messageID] = generation
        visualMessagePrepareTasks[messageID]?.cancel()
        visualMessagePrepareTasks[messageID] = Task(priority: .utility) { [weak self, messageID, sourceMessage = message, rules, generation, sessionID, sourceMessages] in
            let prepared = await Task.detached(priority: .utility) {
                let visualMessage = ChatService.visualMessage(
                    from: sourceMessage,
                    sessionID: sessionID,
                    messages: sourceMessages,
                    rules: rules
                )
                let htmlRenderingEnabled = sessionID.flatMap {
                    RoleplayStore.shared.binding(sessionID: $0)?.htmlRenderingEnabled
                } == true
                let html = sourceMessage.role == .assistant && htmlRenderingEnabled
                    ? RoleplayHTMLExtractor.extract(from: visualMessage.content)
                    : nil
                return (visualMessage, html)
            }.value

            guard !Task.isCancelled, let self else { return }
            guard self.visualMessagePrepareGenerations[messageID] == generation else { return }
            guard let state = self.messageStateByID[messageID],
                  state.message == sourceMessage else {
                return
            }
            state.updateVisualMessage(prepared.0)
            state.updateRoleplayHTML(prepared.1?.containsHTML == true ? prepared.1 : nil)
            self.scheduleMarkdownPreparationIfNeeded(for: prepared.0)
            if self.visualMessagePrepareGenerations[messageID] == generation {
                self.visualMessagePrepareTasks[messageID] = nil
            }
        }
    }

    func scheduleReasoningMarkdownPreparationIfNeeded(for message: ChatMessage) {
        let messageID = message.id
        let isStreamingReasoningMessage = isSendingMessage && latestAssistantMessageID == messageID
        updateReasoningThinkingTitle(for: messageID, sourceText: message.reasoningContent)
        guard ChatReasoningRenderPolicy.shouldPrepareReasoningMarkdown(
            message: message,
            isStreaming: isStreamingReasoningMessage
        ), let sourceText = message.reasoningContent else {
            preparedReasoningMarkdownByMessageID.removeValue(forKey: messageID)
            reasoningMarkdownPrepareTasks[messageID]?.cancel()
            reasoningMarkdownPrepareTasks.removeValue(forKey: messageID)
            reasoningMarkdownPrepareGenerations.removeValue(forKey: messageID)
            return
        }

        if preparedReasoningMarkdownByMessageID[messageID]?.sourceText == sourceText {
            reasoningMarkdownPrepareTasks[messageID]?.cancel()
            reasoningMarkdownPrepareTasks.removeValue(forKey: messageID)
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
            self.preparedReasoningMarkdownByMessageID[messageID] = prepared
            if self.reasoningMarkdownPrepareGenerations[messageID] == generation {
                self.reasoningMarkdownPrepareTasks[messageID] = nil
            }
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

    func applyIncrementalMessageUpdates(previousMessages: [ChatMessage], incomingMessages: [ChatMessage]) {
        guard !previousMessages.isEmpty, !messages.isEmpty else {
            let metadata = collectMessageMetadata(from: incomingMessages)
            if toolCallResultIDs != metadata.toolCallResultIDs {
                toolCallResultIDs = metadata.toolCallResultIDs
            }
            if latestAssistantMessageID != metadata.latestAssistantID {
                latestAssistantMessageID = metadata.latestAssistantID
            }
            updateDisplayedMessages()
            return
        }

        let visibleIDs = Set(messages.map(\.id))
        var updatedToolCallResultIDs = toolCallResultIDs
        var updatedLatestAssistantID = latestAssistantMessageID
        var needsDisplayRefilter = false
        var needsFullDisplayRefresh = false
        var shouldBumpStreamingScrollAnchor = false

        for (oldMessage, newMessage) in zip(previousMessages, incomingMessages) where oldMessage != newMessage {
            if oldMessage.selectedResponseAttemptID != newMessage.selectedResponseAttemptID
                || oldMessage.responseGroupID != newMessage.responseGroupID
                || oldMessage.responseAttemptID != newMessage.responseAttemptID
                || oldMessage.responseAttemptIndex != newMessage.responseAttemptIndex {
                needsFullDisplayRefresh = true
            }

            if visibleIDs.contains(newMessage.id) {
                messageStateByID[newMessage.id]?.update(with: newMessage)
                if let state = messageStateByID[newMessage.id] {
                    scheduleVisualMessagePreparationIfNeeded(for: state, source: newMessage)
                }
                scheduleReasoningMarkdownPreparationIfNeeded(for: newMessage)
                if oldMessage.content != newMessage.content
                    || oldMessage.reasoningContent != newMessage.reasoningContent
                    || oldMessage.toolCalls != newMessage.toolCalls {
                    shouldBumpStreamingScrollAnchor = true
                }
            }

            let oldResultIDs = toolCallResultIDs(for: oldMessage)
            let newResultIDs = toolCallResultIDs(for: newMessage)
            if oldResultIDs != newResultIDs {
                updatedToolCallResultIDs.subtract(oldResultIDs)
                updatedToolCallResultIDs.formUnion(newResultIDs)
                needsDisplayRefilter = true
            }

            if updatedLatestAssistantID == oldMessage.id {
                if newMessage.role != .assistant {
                    updatedLatestAssistantID = incomingMessages.last(where: { $0.role == .assistant })?.id
                }
            } else if oldMessage.role != .assistant && newMessage.role == .assistant {
                updatedLatestAssistantID = newMessage.id
            } else if updatedLatestAssistantID == nil && newMessage.role == .assistant {
                updatedLatestAssistantID = newMessage.id
            }
        }

        if toolCallResultIDs != updatedToolCallResultIDs {
            toolCallResultIDs = updatedToolCallResultIDs
        }
        if latestAssistantMessageID != updatedLatestAssistantID {
            latestAssistantMessageID = updatedLatestAssistantID
        }
        if shouldBumpStreamingScrollAnchor {
            streamingScrollAnchorVersion &+= 1
        }
        if needsFullDisplayRefresh {
            updateDisplayedMessages()
            return
        }
        if needsDisplayRefilter {
            updateDisplayMessagesIfNeeded()
        }
    }

    func hasMatchingMessageIdentity(_ lhs: [ChatMessage], _ rhs: [ChatMessage]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { $0.id == $1.id }
    }

    func collectMessageMetadata(from messages: [ChatMessage]) -> (toolCallResultIDs: Set<String>, latestAssistantID: UUID?) {
        var resultIDs = Set<String>()
        var latestAssistantID: UUID?

        for message in ChatResponseAttemptSupport.visibleMessages(from: messages) {
            resultIDs.formUnion(toolCallResultIDs(for: message))
            if message.role == .assistant {
                latestAssistantID = message.id
            }
        }

        return (resultIDs, latestAssistantID)
    }

    func toolCallResultIDs(for message: ChatMessage) -> Set<String> {
        guard message.role != .tool, let toolCalls = message.toolCalls, !toolCalls.isEmpty else {
            return []
        }
        return Set(
            toolCalls.compactMap { call in
                let trimmedResult = (call.result ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmedResult.isEmpty ? nil : call.id
            }
        )
    }

    func syncAutoOpenedPendingToolCallIDs(with messages: [ChatMessage]) {
        guard !autoOpenedPendingToolCallIDs.isEmpty else { return }
        let existingToolCallIDs = Set(
            messages
                .compactMap(\.toolCalls)
                .flatMap { $0.map(\.id) }
        )
        let filteredIDs = autoOpenedPendingToolCallIDs.intersection(existingToolCallIDs)
        if filteredIDs != autoOpenedPendingToolCallIDs {
            autoOpenedPendingToolCallIDs = filteredIDs
        }
    }

    func updateAutoReasoningPreviewState(with messages: [ChatMessage]) {
        guard let latestAssistantMessage = messages.last(where: { $0.role == .assistant }) else {
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
        guard let currentSessionID = currentSession?.id else {
            isSendingMessage = false
            return
        }
        isSendingMessage = runningSessionIDs.contains(currentSessionID)
    }

    func visibleMessages(from source: [ChatMessage]) -> [ChatMessage] {
        ChatResponseAttemptSupport.visibleMessages(from: source)
    }

    func refreshVisibleMessagesCache() {
        visibleMessagesCache = visibleMessages(from: allMessagesForSession)
        visibleMessagesWeightedCount = Self.lazyLoadWeightedMessageCount(in: visibleMessagesCache)
    }

    func ensureVisibleMessagesCachePrepared() {
        if visibleMessagesCache.isEmpty, !allMessagesForSession.isEmpty {
            refreshVisibleMessagesCache()
        }
    }

    func refreshVisualMessagesAfterRegexRulesChange() {
        for state in messages {
            scheduleVisualMessagePreparationIfNeeded(for: state, source: state.message)
        }
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

    func filterDisplayMessages(_ source: [ChatMessageRenderState]) -> [ChatMessageRenderState] {
        guard !toolCallResultIDs.isEmpty else { return source }
        return source.filter { state in
            let message = state.message
            guard message.role == .tool else { return true }
            guard let toolCalls = message.toolCalls, !toolCalls.isEmpty else { return true }
            return toolCalls.allSatisfy { !toolCallResultIDs.contains($0.id) }
        }
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
        messages.indices.reduce(0) { partialResult, index in
            partialResult + lazyLoadWeight(in: messages, at: index)
        }
    }

    nonisolated static func suffixMessagesForLazyLoad(_ messages: [ChatMessage], weightedLimit: Int) -> [ChatMessage] {
        guard weightedLimit > 0, !messages.isEmpty else { return [] }

        var remaining = weightedLimit
        var startIndex = messages.endIndex

        while startIndex > messages.startIndex {
            guard remaining > 0 else { break }
            let candidateIndex = messages.index(before: startIndex)
            let weight = lazyLoadWeight(in: messages, at: candidateIndex)
            if weight > remaining {
                break
            }
            remaining -= weight
            startIndex = candidateIndex
        }

        return Array(messages[startIndex...])
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
