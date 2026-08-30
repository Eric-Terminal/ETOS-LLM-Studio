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
        let includeMemoryTools: Bool
        let includeMemoryManagementTools: Bool
        let includeBuiltInAppTools: Bool
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
        let memoryIsolationActive = session?.isMemoryContextIsolationActive ?? false
        let toolIsolationActive = session?.isToolContextIsolationActive ?? false
        let temporaryMemoryIsolationActive = isTemporaryChatMemoryIsolated(for: session?.id)
        let shouldIsolateMemory = memoryIsolationActive || temporaryMemoryIsolationActive

        if memoryIsolationActive {
            logger.info("当前会话已屏蔽记忆，将跳过长期记忆上下文与记忆工具。")
        } else if temporaryMemoryIsolationActive {
            logger.info("当前临时对话已启用记忆隔离，将屏蔽长期记忆上下文与记忆工具。")
        }
        if toolIsolationActive {
            logger.info("当前会话已屏蔽工具，将跳过工具定义与历史工具调用。")
        }
        return AuxiliaryContextPolicy(
            enableMemory: enableMemory && !shouldIsolateMemory,
            enableMemoryWrite: enableMemoryWrite && !shouldIsolateMemory,
            enableMemoryActiveRetrieval: enableMemoryActiveRetrieval && !shouldIsolateMemory,
            includeMemoryTools: !toolIsolationActive,
            includeMemoryManagementTools: !shouldIsolateMemory,
            includeBuiltInAppTools: !toolIsolationActive,
            includeMCPTools: !toolIsolationActive,
            includeShortcutTools: !toolIsolationActive,
            includeSkills: !toolIsolationActive
        )
    }

    func resolveRequestTooling(
        for session: ChatSession?,
        enableMemory: Bool,
        enableMemoryWrite: Bool,
        enableMemoryActiveRetrieval: Bool,
        localAgentContext: AgentRuntimeContext? = nil,
        agentCapabilities: AgentToolCapabilityPolicy? = nil,
        selectedAgentMCPServerIDs: Set<UUID>? = nil
    ) async -> (tools: [InternalToolDefinition]?, policy: AuxiliaryContextPolicy) {
        let policy = auxiliaryContextPolicy(
            for: session,
            enableMemory: enableMemory,
            enableMemoryWrite: enableMemoryWrite,
            enableMemoryActiveRetrieval: enableMemoryActiveRetrieval
        )

        var resolvedTools: [InternalToolDefinition] = []
        let includeAgentTools = agentCapabilities?.preparesAgentRun
            ?? (localAgentContext?.mode == .agent && session?.isToolContextIsolationActive != true)
        let includeConversationTools = agentCapabilities?.includesConversationTools ?? includeAgentTools
        let includeBrowserTools = agentCapabilities?.includesBrowserTools ?? includeAgentTools
        let includeLocalLinuxTools = agentCapabilities?.includesLocalLinuxTools
            ?? includeAgentTools
        // 只有 Linux Agent Run 需要冻结本次可见的 MCP 集合；普通 Chat 继续使用
        // MCP 管理页的实时选择，否则空的 Agent 快照会误伤远程 MCP 与内建工具。
        let selectedServerIDs = includeLocalLinuxTools
            ? (selectedAgentMCPServerIDs ?? localAgentContext.map { Set($0.selectedMCPServerIDs) })
            : nil
        if policy.includeMemoryTools && policy.enableMemory && policy.enableMemoryWrite {
            resolvedTools.append(saveMemoryTool)
        }
        if policy.includeMemoryTools && policy.enableMemory && policy.enableMemoryActiveRetrieval && resolvedMemoryTopK() > 0 {
            resolvedTools.append(searchMemoryTool)
        }
        if policy.includeBuiltInAppTools {
            let builtInAppTools = await MainActor.run { AppToolManager.shared.builtInToolsForLLM() }
            resolvedTools.append(contentsOf: builtInAppTools)
        }
        if policy.includeMCPTools {
            let mcpTools = await MainActor.run {
                MCPManager.shared.chatToolsForLLM(
                    includeConversationAgentTools: includeConversationTools,
                    includeLocalLinuxTools: includeLocalLinuxTools,
                    includeBrowserAgentTools: includeBrowserTools,
                    selectedServerIDs: selectedServerIDs
                )
            }
            resolvedTools.append(contentsOf: mcpTools.filter { tool in
                policy.includeMemoryManagementTools
                    || MCPBuiltInAppToolServer.category(for: tool.name) != .memory
            })
        }
        if policy.includeShortcutTools {
            let shortcutTools = await MainActor.run { ShortcutToolManager.shared.chatToolsForLLM() }
            resolvedTools.append(contentsOf: shortcutTools)
        }
        if policy.includeSkills {
            let skillTools = await MainActor.run { SkillManager.shared.chatToolsForLLM() }
            resolvedTools.append(contentsOf: skillTools)
        }
        if let runID = localAgentContext?.runID {
            resolvedTools = await SkillAllowedToolRuntime.shared.filteredTools(
                resolvedTools,
                runID: runID
            )
        }
        return (resolvedTools.isEmpty ? nil : resolvedTools, policy)
    }

    func toolsUsingNativeResponsesShellIfNeeded(
        _ tools: [InternalToolDefinition]?,
        runnableModel: RunnableModel,
        sessionID: UUID
    ) async throws -> [InternalToolDefinition]? {
        guard runnableModel.model.supportsToolCalling,
              var resolved = tools,
              let runID = conversationRunIDs(for: sessionID)?.runID else {
            return tools
        }
        let usesNativeResponsesShell: Bool
        if runnableModel.effectiveAPIFormat == "openai-responses" {
            usesNativeResponsesShell = true
        } else if runnableModel.effectiveAPIFormat == "openai-compatible" {
            let overrides = runnableModel.effectiveOverrideParameters.mapValues { $0.toAny() }
            switch OpenAIAdapter().resolvedConversationAPI(for: overrides) {
            case .responses:
                usesNativeResponsesShell = true
            case .chatCompletions:
                usesNativeResponsesShell = false
            }
        } else {
            usesNativeResponsesShell = false
        }
        resolved = await SkillAllowedToolRuntime.shared.filteredTools(
            resolved,
            runID: runID,
            exemptToolNames: usesNativeResponsesShell
                ? Set([SkillManager.chatToolName, OpenAIResponsesLocalShellProtocol.toolName])
                : Set([SkillManager.chatToolName])
        )
        guard usesNativeResponsesShell,
              let context = Persistence.loadLocalAgentRun(id: runID)?.context else {
            return resolved.isEmpty ? nil : resolved
        }
        let hasNativeShell = resolved.contains {
            $0.kind == .openAIResponsesLocalShell
                || LocalLinuxToolDefinitions.isCommandExecutionToolExposedName($0.name)
        }
        guard hasNativeShell else {
            return resolved
        }

        let nativeShell = try await OpenAIResponsesLocalShellRuntime.shared.toolDefinition(for: context)
        resolved.removeAll {
            $0.kind == .openAIResponsesLocalShell
                || LocalLinuxToolDefinitions.isCommandExecutionToolExposedName($0.name)
                || $0.name == SkillManager.chatToolName
        }
        resolved.append(nativeShell)
        return resolved.isEmpty ? nil : resolved
    }

    /// Linux 操作说明必须与模型实际可调用的 Linux 工具同时出现，避免 Chat
    /// 或不支持工具调用的模型承担无用上下文和错误的能力暗示。
    func shouldIncludeLocalLinuxInstructions(
        tools: [InternalToolDefinition]?,
        modelSupportsToolCalling: Bool,
        localLinuxToolsEnabled: Bool
    ) -> Bool {
        guard modelSupportsToolCalling, localLinuxToolsEnabled else { return false }
        return tools?.contains {
            $0.kind == .openAIResponsesLocalShell
                || LocalLinuxToolDefinitions.containsExposedName($0.name)
        } == true
    }

    func activeRequestIncludesLocalLinuxTools(sessionID: UUID) -> Bool {
        guard let runID = conversationRunIDs(for: sessionID)?.runID,
              let run = Persistence.loadConversationRun(id: runID) else {
            return false
        }
        if let localLinuxToolsEnabled = run.requestConfiguration.localLinuxToolsEnabled {
            return localLinuxToolsEnabled
        }
        // 旧版本的持久化 Run 没有能力快照时，只接受真实 Agent 上下文作为兼容依据。
        return Persistence.loadLocalAgentRun(id: runID)?.context.mode == .agent
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
        let isToolIsolationActive = session?.isToolContextIsolationActive == true
        let isMemoryIsolationActive = session?.isMemoryContextIsolationActive == true
            || isTemporaryChatMemoryIsolated(for: session?.id)

        if !isToolIsolationActive && !isMemoryIsolationActive {
            guard !messageRegexRules.isEmpty else {
                return normalizedMessages
            }
            return normalizedMessages.map { applyMessageRegexRules(to: $0, rules: messageRegexRules, mode: .sendOnly) }
        }

        return normalizedMessages.compactMap { message in
            if message.role == .tool {
                if isToolIsolationActive {
                    return nil
                }
                if message.toolCalls?.contains(where: { isMemoryToolName($0.toolName) }) == true {
                    return nil
                }
            }

            var sanitized = message
            if isToolIsolationActive {
                sanitized.toolCalls = nil
                sanitized.toolCallsPlacement = nil
            } else if let toolCalls = sanitized.toolCalls {
                let retainedToolCalls = toolCalls.filter { !isMemoryToolName($0.toolName) }
                sanitized.toolCalls = retainedToolCalls.isEmpty ? nil : retainedToolCalls
                if retainedToolCalls.isEmpty {
                    sanitized.toolCallsPlacement = nil
                }
            }

            if sanitized.role == .assistant,
               sanitized.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               sanitized.toolCalls?.isEmpty != false {
                return nil
            }
            if messageRegexRules.isEmpty {
                return sanitized
            }
            return applyMessageRegexRules(to: sanitized, rules: messageRegexRules, mode: .sendOnly)
        }
    }

    private func isMemoryToolName(_ name: String) -> Bool {
        name == "save_memory"
            || name == "search_memory"
            || MCPBuiltInAppToolServer.category(for: name) == .memory
    }

    func limitedChatHistory(_ messages: [ChatMessage], maxMessages: Int) -> [ChatMessage] {
        guard maxMessages > 0, messages.count > maxMessages else { return messages }

        let turns = ChatConversationTurnSupport.turns(in: messages)
        guard !turns.isEmpty else { return Array(messages.suffix(maxMessages)) }

        var retainedCount = 0
        var retainedStart = messages.endIndex
        for turn in turns.reversed() {
            let turnCount = turn.range.count
            if retainedCount > 0, retainedCount + turnCount > maxMessages {
                break
            }
            retainedStart = turn.range.lowerBound
            retainedCount += turnCount
            if retainedCount >= maxMessages {
                break
            }
        }
        return Array(messages[retainedStart...])
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
