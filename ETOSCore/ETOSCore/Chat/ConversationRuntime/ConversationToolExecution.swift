// ============================================================================
// ConversationToolExecution.swift
// ============================================================================
// ETOS LLM Studio
//
// 执行模型发起的长期会话操作。所有跨会话等待都先持久化，再让当前
// HTTP 请求自然结束；后续续写由 ConversationRunCoordinator 重新发起。
// ============================================================================

import Foundation
import Combine
import os.log

private struct ConversationWaitTarget {
    let sessionID: UUID
    let run: ConversationRun?
    let initialStatus: ConversationWaitStatus
    let resultMessageID: UUID?
}

extension ChatService {
    func executeConversationTool(
        _ toolCall: InternalToolCall,
        sourceSessionID: UUID
    ) async throws -> ConversationToolExecutionResult {
        guard let toolName = ConversationToolName(rawValue: toolCall.toolName) else {
            throw ConversationRuntimeError.malformedArguments
        }
        guard let sourceSession = conversationSession(withID: sourceSessionID),
              let sourceRun = activeConversationRun(for: sourceSessionID) else {
            throw ConversationRuntimeError.sessionNotFound
        }

        switch toolName {
        case .createConversation:
            let arguments: CreateConversationToolArguments = try decodeConversationToolArguments(toolCall.arguments)
            return try await createConversation(
                arguments: arguments,
                toolCall: toolCall,
                sourceSession: sourceSession,
                sourceRun: sourceRun
            )
        case .sendMessage:
            let arguments: SendConversationMessageToolArguments = try decodeConversationToolArguments(toolCall.arguments)
            return try await sendConversationMessage(
                arguments: arguments,
                toolCall: toolCall,
                sourceSession: sourceSession,
                sourceRun: sourceRun
            )
        case .listConversations:
            let arguments: ListConversationToolArguments = try decodeConversationToolArguments(toolCall.arguments)
            return try listConversations(arguments: arguments, sourceSessionID: sourceSessionID)
        case .listAvailableModels:
            let arguments: ListConversationToolArguments = try decodeConversationToolArguments(toolCall.arguments)
            return try listAvailableConversationModels(arguments: arguments)
        case .readConversation:
            let arguments: ReadConversationToolArguments = try decodeConversationToolArguments(toolCall.arguments)
            return try readConversation(arguments: arguments, sourceSessionID: sourceSessionID)
        case .waitForConversations:
            let arguments: WaitForConversationsToolArguments = try decodeConversationToolArguments(toolCall.arguments)
            return try waitForConversations(
                arguments: arguments,
                toolCall: toolCall,
                sourceSessionID: sourceSessionID,
                sourceRun: sourceRun
            )
        case .interruptConversation:
            let arguments: InterruptConversationToolArguments = try decodeConversationToolArguments(toolCall.arguments)
            return try await interruptConversation(arguments: arguments, sourceSessionID: sourceSessionID)
        }
    }

    private func createConversation(
        arguments: CreateConversationToolArguments,
        toolCall: InternalToolCall,
        sourceSession: ChatSession,
        sourceRun: ConversationRun
    ) async throws -> ConversationToolExecutionResult {
        let initialMessageText = arguments.initialMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !initialMessageText.isEmpty,
              let contextMode = conversationContextMode(arguments.contextMode),
              let executionMode = conversationExecutionMode(arguments.executionMode) else {
            throw ConversationRuntimeError.malformedArguments
        }
        if contextMode == .forkRecent, (arguments.recentRounds ?? 0) < 1 {
            throw ConversationRuntimeError.malformedArguments
        }

        let eventID = UUID()
        let sourceLoadingMessageID = loadingMessageID(for: sourceSession.id)
        var initialMessages = ConversationContextForkBuilder.messages(
            from: messagesSnapshot(for: sourceSession.id),
            mode: contextMode,
            recentRoundCount: arguments.recentRounds,
            excludingMessageID: sourceLoadingMessageID
        ).map { message in
            var copied = message
            copied.sourceSessionID = copied.sourceSessionID ?? sourceSession.id
            return copied
        }
        let requestMessage = ChatMessage(
            role: .user,
            content: initialMessageText,
            authorKind: .conversation,
            sourceSessionID: sourceSession.id,
            sourceMessageID: sourceLoadingMessageID,
            conversationEventID: eventID
        )
        initialMessages.append(requestMessage)

        let inheritsSessionConfiguration = contextMode != .new
        let systemPrompt = try resolvedConversationPrompt(
            inherited: inheritsSessionConfiguration ? sourceSession.systemPrompt : nil,
            provided: arguments.systemPrompt,
            rawMode: arguments.systemPromptMode
        )
        let topicPrompt = try resolvedConversationPrompt(
            inherited: inheritsSessionConfiguration ? sourceSession.topicPrompt : nil,
            provided: arguments.topicPrompt,
            rawMode: arguments.topicPromptMode
        )
        let enhancedPrompt = try resolvedConversationPrompt(
            inherited: inheritsSessionConfiguration ? sourceSession.enhancedPrompt : nil,
            provided: arguments.enhancedPrompt,
            rawMode: arguments.enhancedPromptMode
        )
        let requestedModelIdentifier = ConversationToolModelSelection.explicitIdentifier(
            from: arguments.modelIdentifier
        )
        if let requestedModelIdentifier,
           !activatedChatModels.contains(where: { $0.id == requestedModelIdentifier }) {
            throw ConversationRuntimeError.targetUnavailable
        }
        guard let sourceModelIdentifier = normalizedOptionalText(
            sourceRun.requestConfiguration.modelIdentifier
        ) else {
            throw ConversationRuntimeError.targetUnavailable
        }
        let preferredModelIdentifier = requestedModelIdentifier ?? sourceModelIdentifier

        let hidesConversation = arguments.hidesConversation
        let containerSessionID = hidesConversation
            ? (sourceSession.containerSessionID ?? sourceSession.id)
            : nil
        var groupingFolder: SessionFolder?
        var groupingRootSessionID: UUID?
        var targetFolderID: UUID?
        if !hidesConversation {
            let rootSessionID = sourceSession.containerSessionID ?? sourceSession.id
            guard let rootSession = conversationSession(withID: rootSessionID) else {
                throw ConversationRuntimeError.sessionNotFound
            }
            if sessionFoldersSubject.value.contains(where: { $0.id == rootSessionID }) {
                targetFolderID = rootSessionID
            } else {
                let folder = SessionFolder(
                    id: rootSessionID,
                    name: rootSession.name,
                    parentID: rootSession.folderID == rootSessionID ? nil : rootSession.folderID
                )
                groupingFolder = folder
                groupingRootSessionID = rootSessionID
                targetFolderID = folder.id
            }
        }

        let targetSession = ChatSession(
            id: UUID(),
            name: normalizedOptionalText(arguments.title) ?? String(initialMessageText.prefix(24)),
            systemPrompt: systemPrompt,
            topicPrompt: topicPrompt,
            enhancedPrompt: enhancedPrompt,
            preferredModelIdentifier: preferredModelIdentifier,
            lorebookIDs: inheritsSessionConfiguration ? sourceSession.lorebookIDs : [],
            worldbookContextIsolationEnabled: inheritsSessionConfiguration
                ? sourceSession.worldbookContextIsolationEnabled
                : false,
            folderID: targetFolderID,
            containerSessionID: containerSessionID,
            isTemporary: false
        )

        let delegationID = UUID()
        let shouldGenerateReply = executionMode != .createOnly
        var targetRun: ConversationRun?
        if shouldGenerateReply {
            var configuration = sourceRun.requestConfiguration
            configuration.modelIdentifier = preferredModelIdentifier
            targetRun = ConversationRun(
                sessionID: targetSession.id,
                rootRunID: sourceRun.rootRunID,
                parentRunID: sourceRun.id,
                triggerEventID: eventID,
                status: .queued,
                requestConfiguration: configuration
            )
        }

        let origin = ConversationOrigin(
            childSessionID: targetSession.id,
            parentSessionID: sourceSession.id,
            parentSessionNameSnapshot: sourceSession.name,
            createdByRunID: sourceRun.id,
            createdByMessageID: sourceLoadingMessageID,
            contextMode: contextMode,
            recentRoundCount: contextMode == .forkRecent ? arguments.recentRounds : nil,
            forkThroughMessageID: sourceLoadingMessageID
        )
        let capabilities = [
            ConversationCapability(
                sourceSessionID: sourceSession.id,
                targetSessionID: targetSession.id,
                relation: .created,
                canRead: true,
                canSend: true,
                canTriggerReply: true,
                canInterrupt: true
            ),
            ConversationCapability(
                sourceSessionID: targetSession.id,
                targetSessionID: sourceSession.id,
                relation: .parent,
                canRead: true,
                canSend: true,
                canTriggerReply: true,
                canInterrupt: false
            )
        ]
        let event = ConversationEvent(
            id: eventID,
            destinationSessionID: targetSession.id,
            sourceSessionID: sourceSession.id,
            sourceRunID: sourceRun.id,
            messageID: requestMessage.id,
            correlationID: delegationID,
            kind: .incomingMessage,
            deliveryPolicy: shouldGenerateReply ? .respondWhenIdle : .deliverOnly,
            payloadJSON: encodeConversationToolResult([
                "delegation_id": delegationID.uuidString,
                "execution_mode": executionMode.rawValue
            ])
        )
        let delegation = ConversationDelegation(
            id: delegationID,
            sourceSessionID: sourceSession.id,
            targetSessionID: targetSession.id,
            sourceRunID: sourceRun.id,
            targetRunID: targetRun?.id,
            requestMessageID: requestMessage.id,
            toolCallID: toolCall.id,
            executionMode: executionMode,
            status: executionMode == .createOnly ? .completed : (executionMode == .awaitReply ? .waiting : .pending),
            completedAt: executionMode == .createOnly ? Date() : nil
        )

        var conversationWait: ConversationWait?
        if executionMode == .awaitReply, let targetRun {
            try validateConversationWait(waitingRunID: sourceRun.id, targetRunID: targetRun.id)
            conversationWait = ConversationWait(
                waitGroupID: UUID(),
                waitingRunID: sourceRun.id,
                targetSessionID: targetSession.id,
                targetRunID: targetRun.id,
                toolCallID: toolCall.id,
                completionMode: .all
            )
        }
        guard Persistence.createConversationRuntimeBundle(
            targetSession: targetSession,
            targetMessages: initialMessages,
            groupingFolder: groupingFolder,
            groupingRootSessionID: groupingRootSessionID,
            origin: origin,
            capabilities: capabilities,
            targetRun: targetRun,
            event: event,
            delegation: delegation,
            waits: [conversationWait].compactMap { $0 },
            waitingRunID: conversationWait == nil ? nil : sourceRun.id
        ) else {
            throw ConversationRuntimeError.persistenceUnavailable
        }
        if let groupingFolder {
            var folders = sessionFoldersSubject.value
            if !folders.contains(where: { $0.id == groupingFolder.id }) {
                folders.append(groupingFolder)
                sessionFoldersSubject.send(folders)
            }
        }
        if !targetSession.isEmbeddedSubagent {
            var updatedSessions = chatSessionsSubject.value
            if let groupingRootSessionID,
               let rootIndex = updatedSessions.firstIndex(where: { $0.id == groupingRootSessionID }),
               let groupingFolder {
                updatedSessions[rootIndex].folderID = groupingFolder.id
                if currentSessionSubject.value?.id == groupingRootSessionID {
                    currentSessionSubject.send(updatedSessions[rootIndex])
                }
            }
            updatedSessions.removeAll { $0.id == targetSession.id }
            updatedSessions.insert(targetSession, at: 0)
            chatSessionsSubject.send(updatedSessions)
        }
        storeRuntimeMessagesSnapshot(initialMessages, for: targetSession.id)
        logger.info("已原子创建协作会话及其运行时关系：\(targetSession.name)")
        await ConversationRunCoordinator.shared.signal()

        return ConversationToolExecutionResult(
            content: encodeConversationToolResult(JSONValue.dictionary([
                "conversation_id": .string(targetSession.id.uuidString),
                "title": .string(targetSession.name),
                "run_id": .string(targetRun?.id.uuidString ?? ""),
                "hidden": .bool(hidesConversation),
                "status": .string(executionMode == .createOnly ? "created" : "queued")
            ])),
            shouldPauseCurrentRun: executionMode == .awaitReply
        )
    }

    private func sendConversationMessage(
        arguments: SendConversationMessageToolArguments,
        toolCall: InternalToolCall,
        sourceSession: ChatSession,
        sourceRun: ConversationRun
    ) async throws -> ConversationToolExecutionResult {
        guard let targetSessionID = UUID(uuidString: arguments.conversationID),
              conversationSession(withID: targetSessionID) != nil else {
            throw ConversationRuntimeError.sessionNotFound
        }
        let messageText = arguments.message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !messageText.isEmpty,
              let completionMode = conversationExecutionMode(arguments.completion),
              completionMode != .createOnly else {
            throw ConversationRuntimeError.malformedArguments
        }
        let requestsReply: Bool
        switch arguments.delivery {
        case "deliver_only":
            requestsReply = false
        case "request_reply":
            requestsReply = true
        default:
            throw ConversationRuntimeError.malformedArguments
        }
        let capability = try requiredCapability(
            sourceSessionID: sourceSession.id,
            targetSessionID: targetSessionID
        )
        guard capability.canSend, !requestsReply || capability.canTriggerReply else {
            throw ConversationRuntimeError.capabilityDenied
        }

        let eventID = UUID()
        let delegationID = UUID()
        let outgoingMessage = try await appendConversationMessage(
            ChatMessage(
                role: .user,
                content: messageText,
                authorKind: .conversation,
                sourceSessionID: sourceSession.id,
                sourceMessageID: loadingMessageID(for: sourceSession.id),
                conversationEventID: eventID
            ),
            to: targetSessionID
        )

        var targetRun: ConversationRun?
        if requestsReply {
            targetRun = ConversationRun(
                sessionID: targetSessionID,
                rootRunID: sourceRun.rootRunID,
                parentRunID: sourceRun.id,
                triggerEventID: eventID,
                status: .queued,
                requestConfiguration: requestConfiguration(for: targetSessionID, inheriting: sourceRun)
            )
        }

        var conversationWait: ConversationWait?
        if requestsReply, completionMode == .awaitReply, let targetRun {
            try validateConversationWait(waitingRunID: sourceRun.id, targetRunID: targetRun.id)
            conversationWait = ConversationWait(
                waitGroupID: UUID(),
                waitingRunID: sourceRun.id,
                targetSessionID: targetSessionID,
                targetRunID: targetRun.id,
                toolCallID: toolCall.id,
                completionMode: .all
            )
        }
        let event = ConversationEvent(
            id: eventID,
            destinationSessionID: targetSessionID,
            sourceSessionID: sourceSession.id,
            sourceRunID: sourceRun.id,
            messageID: outgoingMessage.id,
            correlationID: requestsReply ? delegationID : nil,
            kind: .incomingMessage,
            deliveryPolicy: requestsReply ? .respondWhenIdle : .deliverOnly,
            payloadJSON: encodeConversationToolResult(["execution_mode": completionMode.rawValue])
        )
        let delegation: ConversationDelegation? = requestsReply
            ? ConversationDelegation(
                id: delegationID,
                sourceSessionID: sourceSession.id,
                targetSessionID: targetSessionID,
                sourceRunID: sourceRun.id,
                targetRunID: targetRun?.id,
                requestMessageID: outgoingMessage.id,
                toolCallID: toolCall.id,
                executionMode: completionMode,
                status: completionMode == .awaitReply ? .waiting : .pending
            )
            : nil
        guard Persistence.createConversationRuntimeBundle(
            origin: nil,
            capabilities: [],
            targetRun: targetRun,
            event: event,
            delegation: delegation,
            waits: [conversationWait].compactMap { $0 },
            waitingRunID: conversationWait == nil ? nil : sourceRun.id
        ) else {
            throw ConversationRuntimeError.persistenceUnavailable
        }
        await ConversationRunCoordinator.shared.signal()

        return ConversationToolExecutionResult(
            content: encodeConversationToolResult([
                "conversation_id": targetSessionID.uuidString,
                "message_id": outgoingMessage.id.uuidString,
                "run_id": targetRun?.id.uuidString ?? "",
                "status": requestsReply ? "queued" : "delivered"
            ]),
            shouldPauseCurrentRun: requestsReply && completionMode == .awaitReply
        )
    }

    private func readConversation(
        arguments: ReadConversationToolArguments,
        sourceSessionID: UUID
    ) throws -> ConversationToolExecutionResult {
        guard let targetSessionID = UUID(uuidString: arguments.conversationID),
              let targetSession = conversationSession(withID: targetSessionID) else {
            throw ConversationRuntimeError.sessionNotFound
        }
        let capability = try requiredCapability(
            sourceSessionID: sourceSessionID,
            targetSessionID: targetSessionID
        )
        guard capability.canRead else { throw ConversationRuntimeError.capabilityDenied }
        let selectedMessages = ConversationContextForkBuilder.selectedMessages(
            from: messagesSnapshot(for: targetSessionID),
            mode: .forkRecent,
            recentRoundCount: max(1, arguments.rounds ?? 4)
        )
        let items: [JSONValue] = selectedMessages.map { message in
            .dictionary([
                "id": .string(message.id.uuidString),
                "role": .string(message.role.rawValue),
                "author": .string(message.authorKind.rawValue),
                "source_session_id": message.sourceSessionID.map { .string($0.uuidString) } ?? .null,
                "source_message_id": message.sourceMessageID.map { .string($0.uuidString) } ?? .null,
                "content": .string(message.content)
            ])
        }
        _ = Persistence.acknowledgeConversationEvents(
            destinationSessionID: sourceSessionID,
            sourceSessionID: targetSessionID
        )
        return ConversationToolExecutionResult(
            content: encodeConversationToolResult(JSONValue.dictionary([
                "conversation_id": .string(targetSession.id.uuidString),
                "title": .string(targetSession.name),
                "messages": .array(items)
            ])),
            shouldPauseCurrentRun: false
        )
    }

    private func listConversations(
        arguments: ListConversationToolArguments,
        sourceSessionID: UUID
    ) throws -> ConversationToolExecutionResult {
        let limit = try ConversationToolListLimit.resolve(arguments.max)
        let allContacts = Persistence.loadLinkedConversationContacts(sourceSessionID: sourceSessionID)
        let contacts = Array(allContacts.prefix(limit))
        let items: [JSONValue] = contacts.map { contact in
            var permissions: [JSONValue] = []
            if contact.canRead { permissions.append(.string("read")) }
            if contact.canSend { permissions.append(.string("send")) }
            if contact.canTriggerReply { permissions.append(.string("trigger_reply")) }
            if contact.canInterrupt { permissions.append(.string("interrupt")) }
            return .dictionary([
                "conversation_id": .string(contact.sessionID.uuidString),
                "title": .string(contact.title),
                "hidden": .bool(contact.isEmbeddedSubagent),
                "relation": .string(contact.relation.rawValue),
                "status": contact.runStatus.map { .string($0.rawValue) } ?? .null,
                "unread": .int(contact.unreadEventCount),
                "permissions": .array(permissions)
            ])
        }
        return ConversationToolExecutionResult(
            content: encodeConversationToolResult(JSONValue.dictionary([
                "total": .int(allContacts.count),
                "returned": .int(contacts.count),
                "truncated": .bool(contacts.count < allContacts.count),
                "conversations": .array(items)
            ])),
            shouldPauseCurrentRun: false
        )
    }

    private func listAvailableConversationModels(
        arguments: ListConversationToolArguments
    ) throws -> ConversationToolExecutionResult {
        let limit = try ConversationToolListLimit.resolve(arguments.max)
        let allModels = activatedChatModels
        let models = Array(allModels.prefix(limit))
        let items: [JSONValue] = models.map { model in
            .dictionary([
                "identifier": .string(model.id),
                "provider": .string(model.provider.name),
                "model_name": .string(model.model.modelName),
                "display_name": .string(model.model.displayName)
            ])
        }
        return ConversationToolExecutionResult(
            content: encodeConversationToolResult(JSONValue.dictionary([
                "total": .int(allModels.count),
                "returned": .int(models.count),
                "truncated": .bool(models.count < allModels.count),
                "models": .array(items)
            ])),
            shouldPauseCurrentRun: false
        )
    }

    private func waitForConversations(
        arguments: WaitForConversationsToolArguments,
        toolCall: InternalToolCall,
        sourceSessionID: UUID,
        sourceRun: ConversationRun
    ) throws -> ConversationToolExecutionResult {
        guard let mode = ConversationWaitCompletionMode(rawValue: arguments.mode),
              !arguments.conversationIDs.isEmpty else {
            throw ConversationRuntimeError.malformedArguments
        }
        var targets: [ConversationWaitTarget] = []
        var seen = Set<UUID>()
        for rawID in arguments.conversationIDs {
            guard let sessionID = UUID(uuidString: rawID), seen.insert(sessionID).inserted else {
                throw ConversationRuntimeError.malformedArguments
            }
            let capability = try requiredCapability(sourceSessionID: sourceSessionID, targetSessionID: sessionID)
            guard capability.canRead else { throw ConversationRuntimeError.capabilityDenied }
            let run = Persistence.loadLatestConversationRun(sessionID: sessionID)
            let initialStatus: ConversationWaitStatus
            if let run, run.status.isTerminal {
                initialStatus = run.status == .completed ? .satisfied : .failed
            } else if run == nil {
                initialStatus = .satisfied
            } else {
                initialStatus = .pending
            }
            let resultMessageID = run.flatMap { completedRun in
                let messages = messagesSnapshot(for: sessionID)
                if let loadingMessageID = completedRun.loadingMessageID,
                   let reply = messages.first(where: { $0.id == loadingMessageID && $0.role == .assistant }) {
                    return reply.id
                }
                return nil
            }
            targets.append(
                ConversationWaitTarget(
                    sessionID: sessionID,
                    run: run,
                    initialStatus: initialStatus,
                    resultMessageID: resultMessageID
                )
            )
        }

        let pendingTargets = targets.filter { $0.initialStatus == .pending }
        let isAlreadyComplete = mode == .any
            ? targets.contains { $0.initialStatus == .satisfied } || pendingTargets.isEmpty
            : pendingTargets.isEmpty
        if isAlreadyComplete {
            let succeeded = mode == .any
                ? targets.contains { $0.initialStatus == .satisfied }
                : targets.allSatisfy { $0.initialStatus == .satisfied }
            let results: [JSONValue] = targets.map { target in
                .dictionary([
                    "conversation_id": .string(target.sessionID.uuidString),
                    "run_id": target.run.map { .string($0.id.uuidString) } ?? .null,
                    "status": .string(target.initialStatus.rawValue)
                ])
            }
            return ConversationToolExecutionResult(
                content: encodeConversationToolResult(JSONValue.dictionary([
                    "status": .string(succeeded ? "completed" : "failed"),
                    "results": .array(results)
                ])),
                shouldPauseCurrentRun: false
            )
        }

        let existingEdges = Persistence.loadPendingConversationWaitEdges()
        for targetRun in pendingTargets.compactMap(\.run) where ConversationWaitGraph.wouldCreateCycle(
            waitingRunID: sourceRun.id,
            targetRunID: targetRun.id,
            existingEdges: existingEdges
        ) {
            throw ConversationRuntimeError.waitCycleDetected
        }
        let waitGroupID = UUID()
        let waits = targets.map { target in
            ConversationWait(
                    waitGroupID: waitGroupID,
                    waitingRunID: sourceRun.id,
                    targetSessionID: target.sessionID,
                    targetRunID: target.run?.id,
                    toolCallID: toolCall.id,
                    completionMode: mode,
                    status: target.initialStatus,
                    resultMessageID: target.resultMessageID
            )
        }
        guard Persistence.createConversationRuntimeBundle(
            origin: nil,
            capabilities: [],
            targetRun: nil,
            event: nil,
            delegation: nil,
            waits: waits,
            waitingRunID: sourceRun.id
        ) else {
            throw ConversationRuntimeError.persistenceUnavailable
        }
        return ConversationToolExecutionResult(
            content: encodeConversationToolResult([
                "wait_group_id": waitGroupID.uuidString,
                "status": "waiting",
                "mode": mode.rawValue
            ]),
            shouldPauseCurrentRun: true
        )
    }

    private func interruptConversation(
        arguments: InterruptConversationToolArguments,
        sourceSessionID: UUID
    ) async throws -> ConversationToolExecutionResult {
        guard let targetSessionID = UUID(uuidString: arguments.conversationID),
              conversationSession(withID: targetSessionID) != nil else {
            throw ConversationRuntimeError.sessionNotFound
        }
        let capability = try requiredCapability(sourceSessionID: sourceSessionID, targetSessionID: targetSessionID)
        guard capability.canInterrupt else { throw ConversationRuntimeError.capabilityDenied }

        if hasActiveRequestContext(for: targetSessionID) {
            await cancelRequest(for: targetSessionID)
        } else if let run = Persistence.loadLatestConversationRun(sessionID: targetSessionID),
                  !run.status.isTerminal {
            _ = Persistence.updateConversationRunStatus(id: run.id, status: .cancelled)
        }
        for event in Persistence.loadPendingConversationEvents(destinationSessionID: targetSessionID) {
            _ = Persistence.updateConversationEventState(id: event.id, state: .cancelled)
        }
        await ConversationRunCoordinator.shared.signal()
        return ConversationToolExecutionResult(
            content: encodeConversationToolResult([
                "conversation_id": targetSessionID.uuidString,
                "status": "interrupted"
            ]),
            shouldPauseCurrentRun: false
        )
    }

    private func validateConversationWait(waitingRunID: UUID, targetRunID: UUID) throws {
        if ConversationWaitGraph.wouldCreateCycle(
            waitingRunID: waitingRunID,
            targetRunID: targetRunID,
            existingEdges: Persistence.loadPendingConversationWaitEdges()
        ) {
            throw ConversationRuntimeError.waitCycleDetected
        }
    }

    private func requiredCapability(
        sourceSessionID: UUID,
        targetSessionID: UUID
    ) throws -> ConversationCapability {
        guard let capability = Persistence.loadConversationCapability(
            sourceSessionID: sourceSessionID,
            targetSessionID: targetSessionID
        ), capability.revokedAt == nil else {
            throw ConversationRuntimeError.capabilityDenied
        }
        return capability
    }

    private func activeConversationRun(for sessionID: UUID) -> ConversationRun? {
        if let ids = conversationRunIDs(for: sessionID) {
            return Persistence.loadConversationRun(id: ids.runID)
        }
        guard let run = Persistence.loadLatestConversationRun(sessionID: sessionID), !run.status.isTerminal else {
            return nil
        }
        return run
    }

    private func requestConfiguration(
        for sessionID: UUID,
        inheriting sourceRun: ConversationRun
    ) -> ConversationRunRequestConfiguration {
        var configuration = sourceRun.requestConfiguration
        if let target = conversationSession(withID: sessionID), let preferred = target.preferredModelIdentifier {
            configuration.modelIdentifier = preferred
        }
        return configuration
    }

    private func resolvedConversationPrompt(
        inherited: String?,
        provided: String?,
        rawMode: String?
    ) throws -> String? {
        let defaultMode: ConversationPromptInheritanceMode = normalizedOptionalText(provided) == nil ? .inherit : .append
        let mode: ConversationPromptInheritanceMode
        if let rawMode {
            guard let parsedMode = ConversationPromptInheritanceMode(rawValue: rawMode) else {
                throw ConversationRuntimeError.malformedArguments
            }
            mode = parsedMode
        } else {
            mode = defaultMode
        }
        return ConversationContextForkBuilder.resolvedPrompt(
            inherited: inherited,
            provided: provided,
            mode: mode
        )
    }

    private func conversationContextMode(_ rawValue: String) -> ConversationSpawnContextMode? {
        switch rawValue {
        case "new": return .new
        case "fork_all": return .forkAll
        case "fork_recent": return .forkRecent
        default: return nil
        }
    }

    private func conversationExecutionMode(_ rawValue: String) -> ConversationDelegationExecutionMode? {
        switch rawValue {
        case "create_only": return .createOnly
        case "await_reply": return .awaitReply
        case "background": return .background
        case "background_continue": return .backgroundContinue
        default: return nil
        }
    }

    private func decodeConversationToolArguments<T: Decodable>(_ rawJSON: String) throws -> T {
        guard let data = rawJSON.data(using: .utf8),
              let arguments = try? JSONDecoder().decode(T.self, from: data) else {
            throw ConversationRuntimeError.malformedArguments
        }
        return arguments
    }

    private func normalizedOptionalText(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func encodeConversationToolResult<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value), let result = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return result
    }
}
