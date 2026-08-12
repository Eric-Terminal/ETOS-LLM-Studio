// ============================================================================
// ConversationRunContinuation.swift
// ============================================================================
// ETOS LLM Studio
//
// 根据持久化 tool result 重建等待方的后续模型请求。这里不会复用原请求的
// Task 或 continuation，保证 App 退出后仍可从数据库恢复。
// ============================================================================

import Foundation
import Combine

extension ChatService {
    @discardableResult
    func resumeConversationRun(
        _ run: ConversationRun,
        toolCallID: String,
        result: String,
        sourceSessionID: UUID?,
        sourceMessageID: UUID?
    ) async -> Bool {
        guard !hasActiveRequestContext(for: run.sessionID) else {
            return false
        }
        guard let session = conversationSession(withID: run.sessionID),
              let toolCallMessageID = run.loadingMessageID else {
            _ = Persistence.updateConversationRunStatus(
                id: run.id,
                status: .failed,
                errorMessage: NSLocalizedString("无法恢复等待会话的运行现场。", comment: "Missing persisted waiting conversation state")
            )
            return true
        }

        let requestToken = UUID()
        guard reserveRequestContextIfIdle(
            RequestExecutionContext(
                token: requestToken,
                task: nil,
                loadingMessageID: toolCallMessageID,
                imageGenerationContext: nil,
                conversationRunID: run.id,
                rootConversationRunID: run.rootRunID
            ),
            for: run.sessionID
        ) else {
            return false
        }
        defer {
            clearRequestContextIfNeeded(for: run.sessionID, token: requestToken)
        }

        let messagesBeforeResult = messagesSnapshot(for: run.sessionID)
        guard let assistantMessage = messagesBeforeResult.first(where: { $0.id == toolCallMessageID }),
              let originalToolCall = assistantMessage.toolCalls?.first(where: { $0.id == toolCallID }) else {
            _ = Persistence.updateConversationRunStatus(
                id: run.id,
                status: .failed,
                errorMessage: NSLocalizedString("无法恢复等待中的工具调用。", comment: "Missing persisted conversation tool call")
            )
            return true
        }

        var updatedAssistantMessage = assistantMessage
        var updatedToolCalls = assistantMessage.toolCalls ?? []
        guard let toolCallIndex = updatedToolCalls.firstIndex(where: { $0.id == toolCallID }) else {
            _ = Persistence.updateConversationRunStatus(
                id: run.id,
                status: .failed,
                errorMessage: NSLocalizedString("无法恢复等待中的工具调用。", comment: "Missing persisted conversation tool call")
            )
            return true
        }
        updatedToolCalls[toolCallIndex].result = result
        updatedToolCalls[toolCallIndex].resultDisposition = .completed
        updatedAssistantMessage.toolCalls = updatedToolCalls
        do {
            _ = try await upsertConversationMessage(updatedAssistantMessage, to: run.sessionID)
        } catch {
            _ = Persistence.updateConversationRunStatus(
                id: run.id,
                status: .failed,
                errorMessage: error.localizedDescription
            )
            return true
        }

        var requestMessages = messagesBeforeResult
        if let assistantIndex = requestMessages.firstIndex(where: { $0.id == updatedAssistantMessage.id }) {
            requestMessages[assistantIndex] = updatedAssistantMessage
        }
        let existingToolResultMessage = requestMessages.first { message in
            message.role == .tool && message.toolCalls?.contains(where: { $0.id == toolCallID }) == true
        }
        let attemptTailMessageID = assistantMessage.responseAttemptID.flatMap { attemptID in
            requestMessages.last(where: { $0.responseAttemptID == attemptID })?.id
        }
        var continuationAnchorMessageID = attemptTailMessageID
            ?? existingToolResultMessage?.id
            ?? toolCallMessageID
        if existingToolResultMessage == nil {
            var toolMessage = ChatMessage(
                role: .tool,
                content: result,
                toolCalls: [
                    InternalToolCall(
                        id: originalToolCall.id,
                        toolName: originalToolCall.toolName,
                        arguments: originalToolCall.arguments,
                        result: result,
                        resultDisposition: .completed,
                        providerSpecificFields: originalToolCall.providerSpecificFields
                    )
                ],
                authorKind: .tool,
                sourceSessionID: sourceSessionID,
                sourceMessageID: sourceMessageID
            )
            applyResponseAttemptMetadata(responseAttemptMetadata(from: assistantMessage), to: &toolMessage)
            do {
                _ = try await upsertConversationMessage(
                    toolMessage,
                    to: run.sessionID,
                    afterMessageID: toolCallMessageID
                )
            } catch {
                _ = Persistence.updateConversationRunStatus(
                    id: run.id,
                    status: .failed,
                    errorMessage: error.localizedDescription
                )
                return true
            }
            requestMessages = insertingResponseAttemptMessages(
                [toolMessage],
                afterAttemptOf: toolCallMessageID,
                in: requestMessages
            )
            continuationAnchorMessageID = toolMessage.id
        }

        do {
            _ = try ConversationExecutionBudgetPolicy.consume(rootRunID: run.rootRunID)
        } catch ConversationRuntimeError.executionBudgetExhausted {
            _ = Persistence.updateConversationRunStatus(id: run.id, status: .pausedByBudget)
            return true
        } catch {
            _ = Persistence.updateConversationRunStatus(
                id: run.id,
                status: .failed,
                errorMessage: error.localizedDescription
            )
            return true
        }

        var loadingMessage = ChatMessage(role: .assistant, content: "", requestedAt: Date())
        applyResponseAttemptMetadata(responseAttemptMetadata(from: assistantMessage), to: &loadingMessage)
        do {
            _ = try await upsertConversationMessage(
                loadingMessage,
                to: run.sessionID,
                afterMessageID: continuationAnchorMessageID
            )
        } catch {
            _ = Persistence.updateConversationRunStatus(
                id: run.id,
                status: .failed,
                errorMessage: error.localizedDescription
            )
            return true
        }
        requestMessages = insertingResponseAttemptMessages(
            [loadingMessage],
            afterAttemptOf: toolCallMessageID,
            in: requestMessages
        )
        await consumePendingUserSteeringEvents(
            in: run.sessionID,
            includedMessageIDs: Set(requestMessages.map(\.id))
        )

        setRequestContext(
            RequestExecutionContext(
                token: requestToken,
                task: nil,
                loadingMessageID: loadingMessage.id,
                imageGenerationContext: nil,
                conversationRunID: run.id,
                rootConversationRunID: run.rootRunID
            ),
            for: run.sessionID
        )
        _ = Persistence.updateConversationRunStatus(
            id: run.id,
            status: .running,
            loadingMessageID: loadingMessage.id
        )
        emitSessionRequestStatus(.started, sessionID: run.sessionID)

        let requestTask = Task<Void, Error> { [weak self] in
            guard let self else { return }
            let configuration = run.requestConfiguration
            let localAgentRecord = Persistence.loadLocalAgentRun(id: run.id)
            let localAgentContext = localAgentRecord?.state == .running
                ? localAgentRecord?.context
                : nil
            let agentToolsEnabled = configuration.agentToolsEnabled
                ?? (localAgentContext?.mode == .agent)
            let localLinuxToolsEnabled = configuration.localLinuxToolsEnabled
                ?? (localAgentContext != nil)
            let allowsChatTools = !session.isWorldbookContextIsolationActive
            let agentCapabilities = AgentToolCapabilityPolicy(
                preparesAgentRun: agentToolsEnabled && localLinuxToolsEnabled,
                includesConversationTools: allowsChatTools,
                includesBrowserTools: allowsChatTools,
                includesLocalLinuxTools: agentToolsEnabled && localLinuxToolsEnabled
            )
            let selectedAgentMCPServerIDs = configuration.selectedAgentMCPServerIDs.map { Set($0) }
                ?? localAgentContext.map { Set($0.selectedMCPServerIDs) }
            let requestTooling = await self.resolveRequestTooling(
                for: session,
                enableMemory: configuration.enableMemory,
                enableMemoryWrite: configuration.enableMemoryWrite,
                enableMemoryActiveRetrieval: configuration.enableMemoryActiveRetrieval,
                localAgentContext: localAgentContext,
                agentCapabilities: agentCapabilities,
                selectedAgentMCPServerIDs: selectedAgentMCPServerIDs
            )
            await self.executeMessageRequest(
                messages: requestMessages,
                loadingMessageID: loadingMessage.id,
                currentSessionID: run.sessionID,
                userMessage: nil,
                wasTemporarySession: false,
                aiTemperature: configuration.temperature,
                aiTopP: configuration.topP,
                systemPrompt: configuration.systemPrompt,
                maxChatHistory: configuration.maxChatHistory,
                enableStreaming: configuration.enableStreaming,
                enhancedPrompt: configuration.enhancedPrompt,
                tools: requestTooling.tools,
                localAgentPrompt: localAgentContext?.promptContent,
                enableMemory: requestTooling.policy.enableMemory,
                enableMemoryWrite: requestTooling.policy.enableMemoryWrite,
                enableMemoryActiveRetrieval: requestTooling.policy.enableMemoryActiveRetrieval,
                includeSystemTime: configuration.includeSystemTime,
                systemTimeInjectionPosition: configuration.systemTimeInjectionPosition,
                enablePeriodicTimeLandmark: configuration.enablePeriodicTimeLandmark,
                periodicTimeLandmarkIntervalMinutes: configuration.periodicTimeLandmarkIntervalMinutes,
                enableResponseSpeedMetrics: configuration.enableResponseSpeedMetrics,
                currentAudioAttachment: nil,
                currentImageAttachments: [],
                currentFileAttachments: []
            )
        }
        updateRequestTask(requestTask, for: run.sessionID, token: requestToken)
        do {
            try await requestTask.value
        } catch {
            if !isCancellationError(error) {
                _ = Persistence.updateConversationRunStatus(
                    id: run.id,
                    status: .failed,
                    errorMessage: error.localizedDescription
                )
            }
        }
        return true
    }
}
