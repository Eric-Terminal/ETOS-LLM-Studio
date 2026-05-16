// ============================================================================
// ChatServiceRequestPreparation.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责 ChatService 的请求预处理、重试辅助与工具名规范化。
// ============================================================================

import Foundation
import os.log

extension ChatService {
    struct ResponseAttemptMetadata: Sendable {
        let groupID: UUID
        let attemptID: UUID
        let attemptIndex: Int
    }

    struct AuxiliaryContextPolicy {
        let enableMemory: Bool
        let enableMemoryWrite: Bool
        let enableMemoryActiveRetrieval: Bool
        let includeAppTools: Bool
        let includeMCPTools: Bool
        let includeShortcutTools: Bool
        let includeSkills: Bool
    }

    func auxiliaryContextPolicy(
        for session: ChatSession?,
        enableMemory: Bool,
        enableMemoryWrite: Bool,
        enableMemoryActiveRetrieval: Bool
    ) -> AuxiliaryContextPolicy {
        let isolationActive = session?.isWorldbookContextIsolationActive ?? false
        guard isolationActive else {
            return AuxiliaryContextPolicy(
                enableMemory: enableMemory,
                enableMemoryWrite: enableMemoryWrite,
                enableMemoryActiveRetrieval: enableMemoryActiveRetrieval,
                includeAppTools: true,
                includeMCPTools: true,
                includeShortcutTools: true,
                includeSkills: true
            )
        }

        logger.info("当前会话已启用世界书隔离发送，将屏蔽长期记忆与工具上下文。")
        return AuxiliaryContextPolicy(
            enableMemory: false,
            enableMemoryWrite: false,
            enableMemoryActiveRetrieval: false,
            includeAppTools: false,
            includeMCPTools: false,
            includeShortcutTools: false,
            includeSkills: false
        )
    }

    func resolveRequestTooling(
        for session: ChatSession?,
        enableMemory: Bool,
        enableMemoryWrite: Bool,
        enableMemoryActiveRetrieval: Bool
    ) async -> (tools: [InternalToolDefinition]?, policy: AuxiliaryContextPolicy) {
        let policy = auxiliaryContextPolicy(
            for: session,
            enableMemory: enableMemory,
            enableMemoryWrite: enableMemoryWrite,
            enableMemoryActiveRetrieval: enableMemoryActiveRetrieval
        )

        var resolvedTools: [InternalToolDefinition] = []
        if policy.enableMemory && policy.enableMemoryWrite {
            resolvedTools.append(saveMemoryTool)
        }
        if policy.enableMemory && policy.enableMemoryActiveRetrieval && resolvedMemoryTopK() > 0 {
            resolvedTools.append(searchMemoryTool)
        }
        let builtInAppTools = await MainActor.run { AppToolManager.shared.builtInToolsForLLM() }
        resolvedTools.append(contentsOf: builtInAppTools)
        if policy.includeAppTools {
            let appTools = await MainActor.run { AppToolManager.shared.chatToolsForLLM() }
            resolvedTools.append(contentsOf: appTools)
        }
        if policy.includeMCPTools {
            let mcpTools = await MainActor.run { MCPManager.shared.chatToolsForLLM() }
            resolvedTools.append(contentsOf: mcpTools)
        }
        if policy.includeShortcutTools {
            let shortcutTools = await MainActor.run { ShortcutToolManager.shared.chatToolsForLLM() }
            resolvedTools.append(contentsOf: shortcutTools)
        }
        if policy.includeSkills {
            let skillTools = await MainActor.run { SkillManager.shared.chatToolsForLLM() }
            resolvedTools.append(contentsOf: skillTools)
        }
        return (resolvedTools.isEmpty ? nil : resolvedTools, policy)
    }

    func preparedMessagesForRequest(
        from messages: [ChatMessage],
        loadingMessageID: UUID,
        session: ChatSession?
    ) -> [ChatMessage] {
        let visibleMessages = ChatResponseAttemptSupport.visibleMessages(from: messages)
        let baseMessages = visibleMessages.filter { $0.role != .error && $0.id != loadingMessageID }
        let normalizedMessages = normalizedMessagesForToolCallChain(baseMessages)
        let messageRegexRules = MessageRegexRuleStore.currentRules()
        guard session?.isWorldbookContextIsolationActive == true else {
            return normalizedMessages.map { applyMessageRegexRules(to: $0, rules: messageRegexRules, mode: .sendOnly) }
        }

        return normalizedMessages.compactMap { message in
            guard message.role != .tool else { return nil }
            var sanitized = message
            sanitized.toolCalls = nil
            sanitized.toolCallsPlacement = nil

            if sanitized.role == .assistant,
               sanitized.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return nil
            }
            return applyMessageRegexRules(to: sanitized, rules: messageRegexRules, mode: .sendOnly)
        }
    }

    func responseAttemptMetadata(from message: ChatMessage) -> ResponseAttemptMetadata? {
        guard let groupID = message.responseGroupID,
              let attemptID = message.responseAttemptID else {
            return nil
        }
        return ResponseAttemptMetadata(
            groupID: groupID,
            attemptID: attemptID,
            attemptIndex: message.responseAttemptIndex ?? 0
        )
    }

    func responseAttemptMetadata(for messageID: UUID, in sessionID: UUID) -> ResponseAttemptMetadata? {
        guard let message = messagesSnapshot(for: sessionID).first(where: { $0.id == messageID }) else {
            return nil
        }
        return responseAttemptMetadata(from: message)
    }

    func applyResponseAttemptMetadata(_ metadata: ResponseAttemptMetadata?, to message: inout ChatMessage) {
        guard let metadata else { return }
        message.responseGroupID = metadata.groupID
        message.responseAttemptID = metadata.attemptID
        message.responseAttemptIndex = metadata.attemptIndex
        message.selectedResponseAttemptID = metadata.attemptID
    }

    func insertingResponseAttemptMessages(
        _ additions: [ChatMessage],
        afterAttemptOf referenceMessageID: UUID,
        in messages: [ChatMessage]
    ) -> [ChatMessage] {
        guard !additions.isEmpty else { return messages }
        var updatedMessages = messages
        let referenceMessage = updatedMessages.first(where: { $0.id == referenceMessageID })
        let attemptID = referenceMessage?.responseAttemptID ?? additions.first?.responseAttemptID

        let insertionIndex: Int
        if let attemptID,
           let lastAttemptIndex = updatedMessages.lastIndex(where: { $0.responseAttemptID == attemptID }) {
            insertionIndex = updatedMessages.index(after: lastAttemptIndex)
        } else if let referenceIndex = updatedMessages.firstIndex(where: { $0.id == referenceMessageID }) {
            insertionIndex = updatedMessages.index(after: referenceIndex)
        } else {
            insertionIndex = updatedMessages.endIndex
        }

        updatedMessages.insert(contentsOf: additions, at: insertionIndex)
        return updatedMessages
    }

    func responseRoundEndIndex(in messages: [ChatMessage], anchorUserIndex: Int) -> Int {
        guard anchorUserIndex + 1 < messages.count else { return messages.count }
        return messages[(anchorUserIndex + 1)...].firstIndex(where: { $0.role == .user }) ?? messages.count
    }

    func prepareRetryAttemptMetadata(
        in messages: inout [ChatMessage],
        anchorUserIndex: Int
    ) -> ResponseAttemptMetadata {
        let groupID = messages[anchorUserIndex].id
        let roundEndIndex = responseRoundEndIndex(in: messages, anchorUserIndex: anchorUserIndex)
        let roundRange = messages.index(after: anchorUserIndex)..<roundEndIndex
        let existingAttemptIDs = ChatResponseAttemptSupport.orderedAttemptIDs(for: groupID, in: messages)

        if existingAttemptIDs.isEmpty, !roundRange.isEmpty {
            let legacyAttemptID = UUID()
            for index in roundRange where messages[index].role != .user {
                messages[index].responseGroupID = groupID
                messages[index].responseAttemptID = legacyAttemptID
                messages[index].responseAttemptIndex = 0
            }
            messages[anchorUserIndex].selectedResponseAttemptID = legacyAttemptID
        } else if messages[anchorUserIndex].selectedResponseAttemptID == nil {
            messages[anchorUserIndex].selectedResponseAttemptID = existingAttemptIDs.last
        }

        let nextAttemptIndex = messages[roundRange]
            .compactMap(\.responseAttemptIndex)
            .max()
            .map { $0 + 1 } ?? (existingAttemptIDs.isEmpty ? 0 : existingAttemptIDs.count)
        let newAttempt = ResponseAttemptMetadata(
            groupID: groupID,
            attemptID: UUID(),
            attemptIndex: nextAttemptIndex
        )
        messages[anchorUserIndex].selectedResponseAttemptID = newAttempt.attemptID
        return newAttempt
    }

    func isTailContinuationRetryTarget(_ message: ChatMessage, in messages: [ChatMessage]) -> Bool {
        guard message.role == .error else { return false }
        let visibleMessages = ChatResponseAttemptSupport.visibleMessages(from: messages)
        guard let visibleIndex = visibleMessages.firstIndex(where: { $0.id == message.id }) else { return false }
        let precedingMessages = visibleMessages[..<visibleIndex]
        guard precedingMessages.last(where: { $0.role != .system })?.role == .tool else {
            return false
        }
        let trailingMessages = visibleMessages[visibleMessages.index(after: visibleIndex)...]
        return !trailingMessages.contains { trailingMessage in
            switch trailingMessage.role {
            case .user, .assistant, .tool, .error:
                return true
            case .system:
                return false
            }
        }
    }

    func continuationAttemptMetadata(
        for message: ChatMessage,
        in messages: [ChatMessage],
        anchorUserIndex: Int,
        targetIndex: Int
    ) -> ResponseAttemptMetadata? {
        if let metadata = responseAttemptMetadata(from: message) {
            return metadata
        }

        let anchorUser = messages[anchorUserIndex]
        if let selectedAttemptID = anchorUser.selectedResponseAttemptID {
            let attemptIndex = messages
                .filter { $0.responseGroupID == anchorUser.id && $0.responseAttemptID == selectedAttemptID }
                .compactMap(\.responseAttemptIndex)
                .min() ?? 0
            return ResponseAttemptMetadata(
                groupID: anchorUser.id,
                attemptID: selectedAttemptID,
                attemptIndex: attemptIndex
            )
        }

        guard targetIndex > anchorUserIndex else { return nil }
        return messages[anchorUserIndex...targetIndex]
            .reversed()
            .compactMap { responseAttemptMetadata(from: $0) }
            .first
    }

    func continuationInsertionIndex(
        in messages: [ChatMessage],
        referenceIndex: Int,
        metadata: ResponseAttemptMetadata?
    ) -> Int {
        if let attemptID = metadata?.attemptID,
           let lastAttemptIndex = messages.lastIndex(where: { $0.responseAttemptID == attemptID }) {
            return messages.index(after: lastAttemptIndex)
        }
        return messages.index(after: referenceIndex)
    }

    func normalizedMessagesForToolCallChain(_ source: [ChatMessage]) -> [ChatMessage] {
        guard !source.isEmpty else { return source }

        var normalized: [ChatMessage] = []
        normalized.reserveCapacity(source.count)

        var index = 0
        while index < source.count {
            let message = source[index]

            if message.role == .tool {
                index += 1
                continue
            }

            guard message.role == .assistant,
                  let toolCalls = message.toolCalls,
                  !toolCalls.isEmpty else {
                normalized.append(message)
                index += 1
                continue
            }

            let validToolCallIDs = orderedToolCallIDs(from: toolCalls)
            let validToolCallIDSet = Set(validToolCallIDs)

            var nextIndex = index + 1
            var contiguousToolMessages: [ChatMessage] = []
            while nextIndex < source.count, source[nextIndex].role == .tool {
                contiguousToolMessages.append(source[nextIndex])
                nextIndex += 1
            }

            var matchedToolMessages: [ChatMessage] = []
            var matchedToolCallIDs = Set<String>()
            if !validToolCallIDSet.isEmpty {
                for toolMessage in contiguousToolMessages {
                    guard let toolCallID = normalizedToolCallID(from: toolMessage),
                          validToolCallIDSet.contains(toolCallID),
                          matchedToolCallIDs.insert(toolCallID).inserted else {
                        continue
                    }
                    matchedToolMessages.append(toolMessage)
                }
            }

            let hasMainContent = !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let filteredCalls = toolCalls.filter { call in
                guard let toolCallID = normalizedToolCallID(call.id) else { return false }
                return matchedToolCallIDs.contains(toolCallID)
            }

            if filteredCalls.isEmpty {
                if hasMainContent {
                    var sanitizedAssistant = message
                    sanitizedAssistant.toolCalls = nil
                    sanitizedAssistant.toolCallsPlacement = nil
                    normalized.append(sanitizedAssistant)
                }
            } else {
                var sanitizedAssistant = message
                sanitizedAssistant.toolCalls = filteredCalls
                normalized.append(sanitizedAssistant)
                normalized.append(contentsOf: matchedToolMessages)
            }

            index = max(nextIndex, index + 1)
        }

        return normalized
    }

    func orderedToolCallIDs(from toolCalls: [InternalToolCall]) -> [String] {
        var orderedIDs: [String] = []
        orderedIDs.reserveCapacity(toolCalls.count)
        var seen = Set<String>()
        for toolCall in toolCalls {
            guard let normalizedID = normalizedToolCallID(toolCall.id),
                  seen.insert(normalizedID).inserted else { continue }
            orderedIDs.append(normalizedID)
        }
        return orderedIDs
    }

    func normalizedToolCallID(from message: ChatMessage) -> String? {
        message.toolCalls?.first.flatMap { normalizedToolCallID($0.id) }
    }

    func normalizedToolCallID(_ id: String) -> String? {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
