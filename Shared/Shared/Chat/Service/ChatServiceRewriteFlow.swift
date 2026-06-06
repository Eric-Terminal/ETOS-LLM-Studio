// ============================================================================
// ChatServiceRewriteFlow.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责 ChatService 的单条助手回复重写请求与版本写回。
// ============================================================================

import Foundation
import Combine
import os.log

extension ChatService {
    public enum MessageRewriteError: LocalizedError {
        case currentSessionMissing
        case messageNotFound
        case unsupportedMessageRole
        case emptyInstruction
        case emptyOriginalContent
        case emptyRewriteResult

        public var errorDescription: String? {
            switch self {
            case .currentSessionMissing:
                return NSLocalizedString("当前没有可用会话，无法重写消息。", comment: "Rewrite message error")
            case .messageNotFound:
                return NSLocalizedString("找不到要重写的消息。", comment: "Rewrite message error")
            case .unsupportedMessageRole:
                return NSLocalizedString("只能重写 AI 回复。", comment: "Rewrite message error")
            case .emptyInstruction:
                return NSLocalizedString("请填写重写要求。", comment: "Rewrite message error")
            case .emptyOriginalContent:
                return NSLocalizedString("这条回复没有可重写的正文。", comment: "Rewrite message error")
            case .emptyRewriteResult:
                return NSLocalizedString("AI 返回了空内容，请调整重写要求后重试。", comment: "Rewrite message error")
            }
        }
    }

    public func rewriteMessage(
        _ message: ChatMessage,
        instruction: String,
        aiTemperature: Double,
        sessionID: UUID? = nil,
        referenceVersions: [MessageRewriteReferenceVersion] = []
    ) async throws {
        await waitForInitialPersistenceStateIfNeeded()

        let trimmedInstruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInstruction.isEmpty else {
            throw MessageRewriteError.emptyInstruction
        }

        let resolvedSessionID: UUID
        if let sessionID {
            resolvedSessionID = sessionID
        } else if let currentSessionID = currentSessionSubject.value?.id {
            resolvedSessionID = currentSessionID
        } else {
            throw MessageRewriteError.currentSessionMissing
        }

        guard message.role == .assistant else {
            throw MessageRewriteError.unsupportedMessageRole
        }

        let messages = messagesSnapshot(for: resolvedSessionID)
        guard let messageIndex = messages.firstIndex(where: { $0.id == message.id }) else {
            throw MessageRewriteError.messageNotFound
        }

        let originalMessage = messages[messageIndex]
        let originalContent = originalMessage.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !originalContent.isEmpty else {
            throw MessageRewriteError.emptyOriginalContent
        }

        await cancelRequest(for: resolvedSessionID)

        var updatedMessages = messagesSnapshot(for: resolvedSessionID)
        guard let refreshedMessageIndex = updatedMessages.firstIndex(where: { $0.id == message.id }) else {
            throw MessageRewriteError.messageNotFound
        }
        let refreshedMessage = updatedMessages[refreshedMessageIndex]
        guard refreshedMessage.role == .assistant else {
            throw MessageRewriteError.unsupportedMessageRole
        }

        let attemptMetadata = prepareRewriteAttemptMetadata(
            in: &updatedMessages,
            targetIndex: refreshedMessageIndex
        )

        var loadingMessage = ChatMessage(
            role: .assistant,
            content: "",
            requestedAt: Date(),
            responseGroupID: attemptMetadata.groupID,
            responseAttemptID: attemptMetadata.attemptID,
            responseAttemptIndex: attemptMetadata.attemptIndex,
            selectedResponseAttemptID: attemptMetadata.attemptID
        )
        loadingMessage.modelReference = refreshedMessage.modelReference
        loadingMessage.costEstimate = refreshedMessage.costEstimate

        let insertionIndex = rewriteInsertionIndex(
            in: updatedMessages,
            targetIndex: refreshedMessageIndex,
            attemptID: refreshedMessage.responseAttemptID
        )
        updatedMessages.insert(loadingMessage, at: insertionIndex)
        persistAndPublishMessages(updatedMessages, for: resolvedSessionID)

        let loadingMessageID = loadingMessage.id
        let loadingRequestedAt = loadingMessage.requestedAt
        let fallbackModelReference = refreshedMessage.modelReference
        let fallbackCostEstimate = refreshedMessage.costEstimate

        let requestToken = UUID()
        emitSessionRequestStatus(.started, sessionID: resolvedSessionID)
        setRequestContext(
            RequestExecutionContext(
                token: requestToken,
                task: nil,
                loadingMessageID: loadingMessageID,
                imageGenerationContext: nil
            ),
            for: resolvedSessionID
        )

        let requestTask = Task<Void, Error> { [weak self] in
            guard let self else { return }
            let targetModel = self.detachedChatCompletionFallbackModel()
            let rewrittenContent = try await self.generateRewriteContent(
                originalContent: originalContent,
                instruction: trimmedInstruction,
                referenceVersions: referenceVersions,
                aiTemperature: aiTemperature,
                sessionID: resolvedSessionID,
                runnableModel: targetModel
            )
            let sanitizedContent = rewrittenContent.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sanitizedContent.isEmpty else {
                throw MessageRewriteError.emptyRewriteResult
            }
            let modelReference = targetModel.map {
                MessageModelReference(
                    providerID: $0.provider.id,
                    providerName: $0.provider.name,
                    modelUUID: $0.model.id,
                    modelName: $0.model.modelName,
                    modelDisplayName: $0.model.displayName
                )
            }
            var rewrittenMessage = ChatMessage(
                role: .assistant,
                content: sanitizedContent,
                requestedAt: loadingRequestedAt,
                responseGroupID: attemptMetadata.groupID,
                responseAttemptID: attemptMetadata.attemptID,
                responseAttemptIndex: attemptMetadata.attemptIndex,
                selectedResponseAttemptID: attemptMetadata.attemptID
            )
            rewrittenMessage.modelReference = modelReference ?? fallbackModelReference
            rewrittenMessage.costEstimate = modelReference == nil ? fallbackCostEstimate : nil
            self.applyRewriteResult(
                rewrittenMessage,
                loadingMessageID: loadingMessageID,
                sessionID: resolvedSessionID
            )
        }
        updateRequestTask(requestTask, for: resolvedSessionID, token: requestToken)

        defer {
            clearRequestContextIfNeeded(for: resolvedSessionID, token: requestToken)
        }

        do {
            try await requestTask.value
            emitSessionRequestStatus(.finished, sessionID: resolvedSessionID)
        } catch is CancellationError {
            emitSessionRequestStatus(.cancelled, sessionID: resolvedSessionID)
            throw CancellationError()
        } catch {
            if isCancellationError(error) {
                emitSessionRequestStatus(.cancelled, sessionID: resolvedSessionID)
                throw CancellationError()
            }
            removeMessage(withID: loadingMessageID, in: resolvedSessionID)
            emitSessionRequestStatus(.error, sessionID: resolvedSessionID)
            throw error
        }
    }

    private func generateRewriteContent(
        originalContent: String,
        instruction: String,
        referenceVersions: [MessageRewriteReferenceVersion],
        aiTemperature: Double,
        sessionID: UUID,
        runnableModel: RunnableModel?
    ) async throws -> String {
        let systemPrompt = NSLocalizedString("""
        你是消息重写助手。

        规则：
        - 按照重写要求修改原文中指定的地方。
        - 重写要求没有提到的地方不要动，尽量保持原文的内容、结构、语气、格式和 Markdown 标记。
        - 直接输出修改后的原文全文，输出内容会原样作为新的回复版本。
        - 不要输出“好的，这是你要求的修改后的文案”等说明、寒暄、标题、前后缀或代码围栏。
        """, comment: "Message rewrite system prompt")
        let userPrompt: String
        let referenceVersionBlock = makeReferenceVersionPromptBlock(referenceVersions)
        if referenceVersionBlock.isEmpty {
            let userPromptTemplate = NSLocalizedString("""
            重写要求：
            %@

            原文：
            %@
            """, comment: "Message rewrite user prompt")
            userPrompt = String(
                format: userPromptTemplate,
                markdownSeparatedContent(instruction),
                originalContent
            )
        } else {
            let userPromptTemplate = NSLocalizedString("""
            重写要求：
            %@

            其他版本：
            %@

            原文：
            %@
            """, comment: "Message rewrite user prompt with reference versions")
            userPrompt = String(
                format: userPromptTemplate,
                markdownSeparatedContent(instruction),
                markdownSeparatedContent(referenceVersionBlock),
                originalContent
            )
        }

        return try await generateDetachedChatCompletion(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            temperature: aiTemperature,
            runnableModel: runnableModel,
            requestSource: .messageRewrite,
            sessionID: sessionID,
            appendOutputLanguageInstruction: false
        )
    }

    private func markdownSeparatedContent(_ content: String) -> String {
        "\(content)\n\n---"
    }

    private func makeReferenceVersionPromptBlock(
        _ referenceVersions: [MessageRewriteReferenceVersion]
    ) -> String {
        referenceVersions
            .sorted { $0.versionNumber < $1.versionNumber }
            .map { version in
                String(
                    format: NSLocalizedString("版本 %d：\n%@", comment: "Message rewrite reference version prompt item"),
                    version.versionNumber,
                    version.content
                )
            }
            .joined(separator: "\n\n")
    }

    private func prepareRewriteAttemptMetadata(
        in messages: inout [ChatMessage],
        targetIndex: Int
    ) -> ResponseAttemptMetadata {
        if let groupID = messages[targetIndex].responseGroupID {
            return prepareRewriteAttemptMetadataForExistingGroup(
                groupID: groupID,
                in: &messages
            )
        }

        let groupID = previousUserMessageID(before: targetIndex, in: messages) ?? messages[targetIndex].id
        let legacyAttemptID = UUID()
        messages[targetIndex].responseGroupID = groupID
        messages[targetIndex].responseAttemptID = legacyAttemptID
        messages[targetIndex].responseAttemptIndex = 0
        messages[targetIndex].selectedResponseAttemptID = legacyAttemptID
        if let anchorIndex = messages.firstIndex(where: { $0.id == groupID && $0.role == .user }) {
            messages[anchorIndex].selectedResponseAttemptID = legacyAttemptID
        }

        return ResponseAttemptMetadata(
            groupID: groupID,
            attemptID: UUID(),
            attemptIndex: 1
        )
    }

    private func prepareRewriteAttemptMetadataForExistingGroup(
        groupID: UUID,
        in messages: inout [ChatMessage]
    ) -> ResponseAttemptMetadata {
        let attempts = ChatResponseAttemptSupport.orderedAttemptIDs(for: groupID, in: messages)
        let nextAttemptIndex = messages
            .filter { $0.responseGroupID == groupID }
            .compactMap(\.responseAttemptIndex)
            .max()
            .map { $0 + 1 } ?? attempts.count
        let newAttempt = ResponseAttemptMetadata(
            groupID: groupID,
            attemptID: UUID(),
            attemptIndex: nextAttemptIndex
        )
        if let anchorIndex = messages.firstIndex(where: { $0.id == groupID && $0.role == .user }) {
            messages[anchorIndex].selectedResponseAttemptID = newAttempt.attemptID
        }
        for index in messages.indices where messages[index].responseGroupID == groupID {
            messages[index].selectedResponseAttemptID = newAttempt.attemptID
        }
        return newAttempt
    }

    private func previousUserMessageID(before targetIndex: Int, in messages: [ChatMessage]) -> UUID? {
        guard targetIndex > messages.startIndex else { return nil }
        return messages[..<targetIndex].last(where: { $0.role == .user })?.id
    }

    private func rewriteInsertionIndex(
        in messages: [ChatMessage],
        targetIndex: Int,
        attemptID: UUID?
    ) -> Int {
        if let attemptID,
           let lastAttemptIndex = messages.lastIndex(where: { $0.responseAttemptID == attemptID }) {
            return messages.index(after: lastAttemptIndex)
        }
        return messages.index(after: targetIndex)
    }

    private func applyRewriteResult(
        _ rewrittenMessage: ChatMessage,
        loadingMessageID: UUID,
        sessionID: UUID
    ) {
        let messageRegexRules = MessageRegexRuleStore.currentRules()
        let rewrittenMessage = messageRegexRules.isEmpty
            ? rewrittenMessage
            : applyMessageRegexRules(to: rewrittenMessage, rules: messageRegexRules, mode: .persist)
        var messages = messagesSnapshot(for: sessionID)
        guard let index = messages.firstIndex(where: { $0.id == loadingMessageID }) else { return }
        messages[index] = ChatMessage(
            id: loadingMessageID,
            role: .assistant,
            content: rewrittenMessage.content,
            requestedAt: messages[index].requestedAt ?? rewrittenMessage.requestedAt,
            reasoningContent: nil,
            reasoningProviderSpecificFields: nil,
            toolCalls: nil,
            toolCallsPlacement: nil,
            tokenUsage: rewrittenMessage.tokenUsage ?? messages[index].tokenUsage,
            modelReference: rewrittenMessage.modelReference ?? messages[index].modelReference,
            costEstimate: rewrittenMessage.costEstimate ?? messages[index].costEstimate,
            responseMetrics: rewrittenMessage.responseMetrics ?? messages[index].responseMetrics,
            responseGroupID: rewrittenMessage.responseGroupID,
            responseAttemptID: rewrittenMessage.responseAttemptID,
            responseAttemptIndex: rewrittenMessage.responseAttemptIndex,
            selectedResponseAttemptID: rewrittenMessage.selectedResponseAttemptID
        )
        persistAndPublishMessages(messages, for: sessionID)
        logger.info("已完成消息重写并保存为新版本: \(loadingMessageID.uuidString)")
    }
}
