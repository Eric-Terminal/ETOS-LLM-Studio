// ============================================================================
// ChatServiceRetryPlanning.swift
// ============================================================================
// ETOS LLM Studio
//
// 将任意气泡重试转换为“当前轮次内的精确分叉”或“异常中断后的原地续接”。
// ============================================================================

import Foundation

extension ChatService {
    struct ResumedToolCallRequest {
        let messages: [ChatMessage]
        let shouldContinueRequest: Bool
    }

    struct PreparedMessageRetry {
        let storedMessages: [ChatMessage]
        let requestMessages: [ChatMessage]
        let loadingMessage: ChatMessage
        let representativeUserMessage: ChatMessage?
        let pendingToolCallMessageID: UUID?
        let createsNewVersion: Bool
    }

    func prepareMessageRetry(
        targetMessage: ChatMessage,
        in sourceMessages: [ChatMessage],
        requestedAt: Date = Date()
    ) -> PreparedMessageRetry? {
        let visibleMessages = ChatResponseAttemptSupport.visibleMessages(from: sourceMessages)
        guard let targetIndex = visibleMessages.firstIndex(where: { $0.id == targetMessage.id }),
              let turn = ChatConversationTurnSupport.turn(
                containingMessageID: targetMessage.id,
                in: visibleMessages
              ) else {
            return nil
        }

        let responseGroupID = retryResponseGroupID(
            targetMessage: targetMessage,
            turn: turn,
            visibleMessages: visibleMessages
        )
        let requestEndIndex = retryRequestEndIndex(
            targetIndex: targetIndex,
            turn: turn,
            visibleMessages: visibleMessages
        )
        let continuesCurrentVersion = shouldContinueCurrentRetryVersion(
            targetMessage: targetMessage,
            targetIndex: targetIndex,
            turn: turn,
            visibleMessages: visibleMessages
        )

        var storedMessages = sourceMessages
        let originalAttempt = ensureCurrentRetryAttempt(
            groupID: responseGroupID,
            turn: turn,
            visibleMessages: visibleMessages,
            storedMessages: &storedMessages
        )
        let representativeUserMessage = turn.userRange
            .map { visibleMessages[$0.index(before: $0.endIndex)] }

        if continuesCurrentVersion {
            let activeAttempt = originalAttempt ?? ResponseAttemptMetadata(
                groupID: responseGroupID,
                attemptID: UUID(),
                attemptIndex: 0
            )
            let removesBrokenTarget = shouldRemoveBrokenRetryTarget(targetMessage)
            if removesBrokenTarget {
                storedMessages.removeAll { $0.id == targetMessage.id }
            }

            var loadingMessage = ChatMessage(
                role: .assistant,
                content: "",
                requestedAt: requestedAt
            )
            applyResponseAttemptMetadata(activeAttempt, to: &loadingMessage)
            let insertionIndex = retryAttemptInsertionIndex(
                turn: turn,
                visibleMessages: visibleMessages,
                storedMessages: storedMessages
            )
            storedMessages.insert(loadingMessage, at: insertionIndex)
            storedMessages = ChatResponseAttemptSupport.selectAttempt(
                attemptID: activeAttempt.attemptID,
                groupID: responseGroupID,
                in: storedMessages
            )

            guard let requestMessages = retryRequestPrefix(
                through: loadingMessage.id,
                in: storedMessages
            ) else {
                return nil
            }
            return PreparedMessageRetry(
                storedMessages: storedMessages,
                requestMessages: requestMessages,
                loadingMessage: loadingMessage,
                representativeUserMessage: representativeUserMessage,
                pendingToolCallMessageID: pendingToolCallSourceID(in: requestMessages),
                createsNewVersion: false
            )
        }

        let existingAttemptIDs = ChatResponseAttemptSupport.orderedAttemptIDs(
            for: responseGroupID,
            in: storedMessages
        )
        let nextAttemptIndex = storedMessages
            .filter { $0.responseGroupID == responseGroupID }
            .compactMap(\.responseAttemptIndex)
            .max()
            .map { $0 + 1 } ?? existingAttemptIDs.count
        let newAttempt = ResponseAttemptMetadata(
            groupID: responseGroupID,
            attemptID: UUID(),
            attemptIndex: nextAttemptIndex
        )

        let copiedPrefixRange = turn.responseRange.lowerBound..<max(
            turn.responseRange.lowerBound,
            min(requestEndIndex, turn.responseRange.upperBound)
        )
        var newAttemptMessages = visibleMessages[copiedPrefixRange].map { message in
            var copy = message
            copy.id = UUID()
            copy.conversationEventID = nil
            applyResponseAttemptMetadata(newAttempt, to: &copy)
            return copy
        }
        var loadingMessage = ChatMessage(
            role: .assistant,
            content: "",
            requestedAt: requestedAt
        )
        applyResponseAttemptMetadata(newAttempt, to: &loadingMessage)
        newAttemptMessages.append(loadingMessage)

        let insertionIndex = retryAttemptInsertionIndex(
            turn: turn,
            visibleMessages: visibleMessages,
            storedMessages: storedMessages
        )
        storedMessages.insert(contentsOf: newAttemptMessages, at: insertionIndex)
        storedMessages = ChatResponseAttemptSupport.selectAttempt(
            attemptID: newAttempt.attemptID,
            groupID: responseGroupID,
            in: storedMessages
        )

        guard let requestMessages = retryRequestPrefix(
            through: loadingMessage.id,
            in: storedMessages
        ) else {
            return nil
        }
        return PreparedMessageRetry(
            storedMessages: storedMessages,
            requestMessages: requestMessages,
            loadingMessage: loadingMessage,
            representativeUserMessage: representativeUserMessage,
            pendingToolCallMessageID: pendingToolCallSourceID(in: requestMessages),
            createsNewVersion: true
        )
    }

    private func retryResponseGroupID(
        targetMessage: ChatMessage,
        turn: ChatConversationTurn,
        visibleMessages: [ChatMessage]
    ) -> UUID {
        if let anchorIndex = turn.responseGroupAnchorIndex {
            return visibleMessages[anchorIndex].id
        }
        return targetMessage.responseGroupID
            ?? visibleMessages[turn.range.lowerBound].responseGroupID
            ?? visibleMessages[turn.range.lowerBound].id
    }

    private func retryRequestEndIndex(
        targetIndex: Int,
        turn: ChatConversationTurn,
        visibleMessages: [ChatMessage]
    ) -> Int {
        let targetMessage = visibleMessages[targetIndex]
        if targetMessage.role == .user {
            return turn.userRange?.upperBound ?? visibleMessages.index(after: targetIndex)
        }

        if targetMessage.role == .tool {
            return visibleMessages.index(after: targetIndex)
        }

        if targetMessage.role == .error {
            return turn.responseRange.lowerBound
        }

        guard targetMessage.role == .assistant,
              let toolCalls = targetMessage.toolCalls,
              !toolCalls.isEmpty else {
            return targetIndex
        }

        let toolCallIDs = Set(toolCalls.map(\.id))
        var endIndex = visibleMessages.index(after: targetIndex)
        while endIndex < turn.range.upperBound {
            let candidate = visibleMessages[endIndex]
            guard candidate.role == .tool,
                  candidate.toolCalls?.contains(where: { toolCallIDs.contains($0.id) }) == true else {
                break
            }
            endIndex = visibleMessages.index(after: endIndex)
        }
        return endIndex
    }

    private func shouldContinueCurrentRetryVersion(
        targetMessage: ChatMessage,
        targetIndex: Int,
        turn: ChatConversationTurn,
        visibleMessages: [ChatMessage]
    ) -> Bool {
        if targetMessage.role == .user, turn.responseRange.isEmpty {
            return true
        }
        guard targetIndex == turn.range.index(before: turn.range.endIndex) else {
            return false
        }

        switch targetMessage.role {
        case .user, .tool:
            return true
        case .error:
            guard targetIndex > turn.responseRange.lowerBound else { return false }
            let precedingResponse = visibleMessages[turn.responseRange.lowerBound..<targetIndex]
                .last(where: { $0.role != .system })
            return precedingResponse?.role == .tool
                || (precedingResponse?.role == .assistant
                    && !(precedingResponse?.toolCalls ?? []).isEmpty)
        case .assistant:
            return !(targetMessage.toolCalls ?? []).isEmpty
                || ChatQuickRetrySupport.isAbnormalStoppedAssistantMessage(targetMessage)
        case .system:
            return false
        }
    }

    private func shouldRemoveBrokenRetryTarget(_ message: ChatMessage) -> Bool {
        switch message.role {
        case .error:
            return true
        case .assistant:
            return (message.toolCalls ?? []).isEmpty
                && ChatQuickRetrySupport.isAbnormalStoppedAssistantMessage(message)
        case .system, .user, .tool:
            return false
        }
    }

    private func ensureCurrentRetryAttempt(
        groupID: UUID,
        turn: ChatConversationTurn,
        visibleMessages: [ChatMessage],
        storedMessages: inout [ChatMessage]
    ) -> ResponseAttemptMetadata? {
        let existingAttemptIDs = ChatResponseAttemptSupport.orderedAttemptIDs(
            for: groupID,
            in: storedMessages
        )
        if let selectedAttemptID = ChatResponseAttemptSupport.selectedAttemptID(
            for: groupID,
            in: storedMessages
        ) ?? existingAttemptIDs.last {
            let attemptIndex = storedMessages
                .filter { $0.responseGroupID == groupID && $0.responseAttemptID == selectedAttemptID }
                .compactMap(\.responseAttemptIndex)
                .min() ?? max(0, existingAttemptIDs.firstIndex(of: selectedAttemptID) ?? 0)
            return ResponseAttemptMetadata(
                groupID: groupID,
                attemptID: selectedAttemptID,
                attemptIndex: attemptIndex
            )
        }

        guard !turn.responseRange.isEmpty else { return nil }
        let attempt = ResponseAttemptMetadata(
            groupID: groupID,
            attemptID: UUID(),
            attemptIndex: 0
        )
        let responseMessageIDs = Set(visibleMessages[turn.responseRange].map(\.id))
        for index in storedMessages.indices where responseMessageIDs.contains(storedMessages[index].id) {
            applyResponseAttemptMetadata(attempt, to: &storedMessages[index])
        }
        storedMessages = ChatResponseAttemptSupport.selectAttempt(
            attemptID: attempt.attemptID,
            groupID: groupID,
            in: storedMessages
        )
        return attempt
    }

    private func retryAttemptInsertionIndex(
        turn: ChatConversationTurn,
        visibleMessages: [ChatMessage],
        storedMessages: [ChatMessage]
    ) -> Int {
        guard turn.range.upperBound < visibleMessages.endIndex else {
            return storedMessages.endIndex
        }
        let nextTurnMessageID = visibleMessages[turn.range.upperBound].id
        return storedMessages.firstIndex(where: { $0.id == nextTurnMessageID })
            ?? storedMessages.endIndex
    }

    private func retryRequestPrefix(
        through loadingMessageID: UUID,
        in storedMessages: [ChatMessage]
    ) -> [ChatMessage]? {
        let visibleMessages = ChatResponseAttemptSupport.visibleMessages(from: storedMessages)
        guard let loadingIndex = visibleMessages.firstIndex(where: { $0.id == loadingMessageID }) else {
            return nil
        }
        return Array(visibleMessages.prefix(through: loadingIndex))
    }

    private func pendingToolCallSourceID(in requestMessages: [ChatMessage]) -> UUID? {
        for (index, message) in requestMessages.enumerated().reversed() {
            guard message.role == .assistant,
                  let toolCalls = message.toolCalls,
                  !toolCalls.isEmpty else {
                continue
            }
            let expectedIDs = Set(toolCalls.map(\.id))
            var resolvedIDs = Set<String>()
            var cursor = requestMessages.index(after: index)
            while cursor < requestMessages.endIndex, requestMessages[cursor].role == .tool {
                for call in requestMessages[cursor].toolCalls ?? [] where expectedIDs.contains(call.id) {
                    let result = (call.result ?? requestMessages[cursor].content)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !result.isEmpty {
                        resolvedIDs.insert(call.id)
                    }
                }
                cursor = requestMessages.index(after: cursor)
            }
            if !expectedIDs.isSubset(of: resolvedIDs) {
                return message.id
            }
        }
        return nil
    }

    func resumePendingToolCalls(
        sourceMessageID: UUID,
        loadingMessageID: UUID,
        sessionID: UUID,
        agentRunID: UUID
    ) async -> ResumedToolCallRequest {
        var storedMessages = messagesSnapshot(for: sessionID)
        guard let sourceIndex = storedMessages.firstIndex(where: { $0.id == sourceMessageID }),
              let initialLoadingIndex = storedMessages.firstIndex(where: { $0.id == loadingMessageID }),
              sourceIndex < initialLoadingIndex,
              var sourceToolCalls = storedMessages[sourceIndex].toolCalls,
              !sourceToolCalls.isEmpty else {
            return ResumedToolCallRequest(
                messages: retryRequestPrefix(through: loadingMessageID, in: storedMessages) ?? storedMessages,
                shouldContinueRequest: true
            )
        }

        let attemptID = storedMessages[sourceIndex].responseAttemptID
        let attemptMetadata = responseAttemptMetadata(from: storedMessages[sourceIndex])
        let existingToolMessageIndices = storedMessages.indices.filter { index in
            guard index > sourceIndex,
                  index < initialLoadingIndex,
                  storedMessages[index].role == .tool else {
                return false
            }
            if let attemptID {
                return storedMessages[index].responseAttemptID == attemptID
            }
            return storedMessages[index].responseAttemptID == nil
        }

        var emptyToolMessageIDs = Set<UUID>()
        var additions: [ChatMessage] = []
        var shouldContinueRequest = true

        for callIndex in sourceToolCalls.indices {
            let call = sourceToolCalls[callIndex]
            let existingMessageIndex = existingToolMessageIndices.first { messageIndex in
                storedMessages[messageIndex].toolCalls?.contains(where: { $0.id == call.id }) == true
            }
            let existingResult = existingMessageIndex.flatMap { messageIndex in
                resolvedStoredToolResult(
                    for: call.id,
                    in: storedMessages[messageIndex]
                )
            }
            let embeddedResult = call.result?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let completedResult = [existingResult, embeddedResult]
                .compactMap { $0 }
                .first(where: { !$0.isEmpty })

            if let completedResult {
                sourceToolCalls[callIndex].result = completedResult
                if existingMessageIndex == nil {
                    var reconstructed = ChatMessage(
                        role: .tool,
                        content: completedResult,
                        toolCalls: [
                            InternalToolCall(
                                id: call.id,
                                toolName: call.toolName,
                                arguments: call.arguments,
                                result: completedResult,
                                resultDisposition: call.resultDisposition,
                                providerSpecificFields: call.providerSpecificFields
                            )
                        ]
                    )
                    applyResponseAttemptMetadata(attemptMetadata, to: &reconstructed)
                    additions.append(reconstructed)
                }
                continue
            }

            if let existingMessageIndex {
                emptyToolMessageIDs.insert(storedMessages[existingMessageIndex].id)
            }
            let outcome = await handleToolCall(
                call,
                sessionID: sessionID,
                agentRunID: agentRunID,
                triggeringMessageID: attemptMetadata?.groupID
            )
            let result = (outcome.toolResult ?? outcome.message.content)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            sourceToolCalls[callIndex].result = result
            sourceToolCalls[callIndex].resultDisposition = outcome.resultDisposition

            var outcomeMessage = outcome.message
            applyResponseAttemptMetadata(attemptMetadata, to: &outcomeMessage)
            additions.append(outcomeMessage)
            if outcome.shouldAwaitUserSupplement || outcome.shouldPauseForConversation {
                shouldContinueRequest = false
                break
            }
        }

        storedMessages[sourceIndex].toolCalls = sourceToolCalls
        if !emptyToolMessageIDs.isEmpty {
            storedMessages.removeAll { emptyToolMessageIDs.contains($0.id) }
        }
        guard let loadingIndex = storedMessages.firstIndex(where: { $0.id == loadingMessageID }) else {
            return ResumedToolCallRequest(messages: storedMessages, shouldContinueRequest: false)
        }
        storedMessages.insert(contentsOf: additions, at: loadingIndex)
        if !shouldContinueRequest {
            storedMessages.removeAll { $0.id == loadingMessageID }
        }
        persistAndPublishMessages(storedMessages, for: sessionID)

        let requestMessages = shouldContinueRequest
            ? retryRequestPrefix(through: loadingMessageID, in: storedMessages) ?? storedMessages
            : ChatResponseAttemptSupport.visibleMessages(from: storedMessages)
        return ResumedToolCallRequest(
            messages: requestMessages,
            shouldContinueRequest: shouldContinueRequest
        )
    }

    private func resolvedStoredToolResult(
        for toolCallID: String,
        in message: ChatMessage
    ) -> String? {
        let result = message.toolCalls?
            .first(where: { $0.id == toolCallID })?
            .result?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let result, !result.isEmpty {
            return result
        }
        let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return content.isEmpty ? nil : content
    }
}
