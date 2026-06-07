// ============================================================================
// SyncEngineSessionMerge.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件承载会话与聊天消息的同步深合并逻辑。
// ============================================================================

import Foundation

extension SyncEngine {
    static func containsSessionHash(
        _ hash: String,
        sessions: [ChatSession],
        messagesBySessionID: inout [UUID: [ChatMessage]]
    ) -> Bool {
        for session in sessions {
            let messages = messagesForSession(session.id, cache: &messagesBySessionID)
            if computeSessionContentHash(session: session, messages: messages) == hash {
                return true
            }
        }
        return false
    }

    static func messagesForSession(_ sessionID: UUID, cache: inout [UUID: [ChatMessage]]) -> [ChatMessage] {
        if let cached = cache[sessionID] {
            return cached
        }
        let loaded = Persistence.loadMessages(for: sessionID)
        cache[sessionID] = loaded
        return loaded
    }

    static func sessionMergeCandidateIndex(for incomingSession: ChatSession, localSessions: [ChatSession]) -> Int? {
        if let exactIDMatch = localSessions.firstIndex(where: { $0.id == incomingSession.id }) {
            return exactIDMatch
        }
        return localSessions.firstIndex(where: { $0.isEquivalentIgnoringSyncSuffix(to: incomingSession) })
    }

    static func mergeSessionDeep(
        localSession: ChatSession,
        localMessages: [ChatMessage],
        incomingSession: ChatSession,
        incomingMessages: [ChatMessage]
    ) -> DeepMergeResult<(ChatSession, [ChatMessage])> {
        guard let mergedSession = mergeChatSessionMetadata(local: localSession, incoming: incomingSession) else {
            return .conflict
        }
        guard let mergedMessagesResult = mergeLinearMessages(local: localMessages, incoming: incomingMessages) else {
            return .conflict
        }

        let payload = (mergedSession, mergedMessagesResult.messages)
        if mergedSession == localSession && !mergedMessagesResult.changed {
            return .unchanged(payload)
        }
        return .merged(payload)
    }

    static func shouldForkParallelSession(
        localMessages: [ChatMessage],
        incomingMessages: [ChatMessage]
    ) -> Bool {
        let commonPrefixCount = commonTimelinePrefixCount(
            localMessages,
            incomingMessages
        )
        return localMessages.count > commonPrefixCount
            && incomingMessages.count > commonPrefixCount
    }

    static func commonTimelinePrefixCount(
        _ local: [ChatMessage],
        _ incoming: [ChatMessage]
    ) -> Int {
        let overlapCount = min(local.count, incoming.count)
        for index in 0..<overlapCount {
            guard messagesShareTimelineIdentity(local[index], incoming[index]) else {
                return index
            }
        }
        return overlapCount
    }

    static func messagesShareTimelineIdentity(_ local: ChatMessage, _ incoming: ChatMessage) -> Bool {
        if local == incoming || local.id == incoming.id {
            return true
        }
        return messagesShareMergeIdentity(local, incoming)
    }

    static func mergeChatSessionMetadata(local: ChatSession, incoming: ChatSession) -> ChatSession? {
        guard local.baseNameWithoutSyncSuffix == incoming.baseNameWithoutSyncSuffix else {
            return nil
        }

        var merged = local
        guard let topicMerge = mergeOptionalStringField(
            local.topicPrompt,
            incoming.topicPrompt,
            allowPrefixExtension: false
        ) else {
            return nil
        }
        merged.topicPrompt = topicMerge.value

        guard let enhancedMerge = mergeOptionalStringField(
            local.enhancedPrompt,
            incoming.enhancedPrompt,
            allowPrefixExtension: false
        ) else {
            return nil
        }
        merged.enhancedPrompt = enhancedMerge.value

        if local.folderID == nil {
            merged.folderID = incoming.folderID
        }

        merged.lorebookIDs = mergeOrderedUUIDs(local.lorebookIDs, incoming.lorebookIDs)
        merged.tagIDs = mergeOrderedUUIDs(local.tagIDs, incoming.tagIDs)

        if local.worldbookContextIsolationEnabled != incoming.worldbookContextIsolationEnabled {
            let localHasBindings = !local.lorebookIDs.isEmpty
            let incomingHasBindings = !incoming.lorebookIDs.isEmpty
            if local.worldbookContextIsolationEnabled && !localHasBindings {
                merged.worldbookContextIsolationEnabled = incoming.worldbookContextIsolationEnabled
            } else if incoming.worldbookContextIsolationEnabled && !incomingHasBindings {
                merged.worldbookContextIsolationEnabled = local.worldbookContextIsolationEnabled
            } else if local.worldbookContextIsolationEnabled || incoming.worldbookContextIsolationEnabled {
                merged.worldbookContextIsolationEnabled = true
            }
        }

        if local.name != incoming.name {
            if local.baseNameWithoutSyncSuffix == incoming.baseNameWithoutSyncSuffix {
                merged.name = local.name
            } else {
                return nil
            }
        }

        merged.isTemporary = false
        return merged
    }

    static func mergeLinearMessages(
        local: [ChatMessage],
        incoming: [ChatMessage]
    ) -> (messages: [ChatMessage], changed: Bool)? {
        if local == incoming {
            return (local, false)
        }

        var merged = local
        var changed = false
        let overlapCount = min(local.count, incoming.count)

        for index in 0..<overlapCount {
            guard let mergedMessage = mergeChatMessage(local[index], incoming[index]) else {
                return nil
            }
            if mergedMessage != merged[index] {
                merged[index] = mergedMessage
                changed = true
            }
        }

        if incoming.count > local.count {
            merged.append(contentsOf: incoming.dropFirst(overlapCount))
            changed = true
        }

        return (merged, changed)
    }

    static func mergeChatMessage(_ local: ChatMessage, _ incoming: ChatMessage) -> ChatMessage? {
        if local == incoming {
            return local
        }

        let isSameMessageID = local.id == incoming.id
        let canTreatAsSameMessage = isSameMessageID
            || messagesShareMergeIdentity(local, incoming)
        guard canTreatAsSameMessage else {
            return nil
        }

        guard let contentMerge = mergeMessageVersions(
            local: local,
            incoming: incoming,
            allowsDivergentVersions: isSameMessageID
        ) else {
            return nil
        }
        guard let reasoningMerge = mergeOptionalStringField(
            local.reasoningContent,
            incoming.reasoningContent,
            allowPrefixExtension: true
        ) else {
            return nil
        }
        guard let toolCallsMerge = mergeOptionalArrayField(local.toolCalls, incoming.toolCalls) else {
            return nil
        }
        guard let toolCallsPlacement = mergeOptionalScalarField(
            local.toolCallsPlacement,
            incoming.toolCallsPlacement
        ) else {
            return nil
        }
        guard let audioFileName = mergeAttachmentReference(
            local.audioFileName,
            incoming.audioFileName,
            type: "audio",
            loader: { Persistence.loadAudio(fileName: $0) }
        ) else {
            return nil
        }
        guard let fullErrorContent = mergeOptionalStringField(
            local.fullErrorContent,
            incoming.fullErrorContent,
            allowPrefixExtension: true
        ) else {
            return nil
        }
        guard let mergedImageFiles = mergeAttachmentReferences(
            local.imageFileNames,
            incoming.imageFileNames,
            type: "image",
            loader: { Persistence.loadImage(fileName: $0) }
        ) else {
            return nil
        }
        let mergedFileFiles = mergeUnsyncedFileReferences(local.fileFileNames, incoming.fileFileNames)

        let mergedTokenUsage = mergeTokenUsage(local.tokenUsage, incoming.tokenUsage)
        let mergedResponseMetrics = mergeResponseMetrics(local.responseMetrics, incoming.responseMetrics)
        let mergedModelReference = incoming.modelReference ?? local.modelReference
        let mergedCostEstimate = incoming.costEstimate ?? local.costEstimate
        let mergedRequestedAt = minOptional(local.requestedAt, incoming.requestedAt)

        var merged = buildMessage(
            from: local,
            versions: contentMerge.versions,
            currentVersionIndex: contentMerge.currentVersionIndex,
            requestedAt: mergedRequestedAt,
            reasoningContent: reasoningMerge.value,
            toolCalls: toolCallsMerge.value,
            toolCallsPlacement: toolCallsPlacement.value,
            tokenUsage: mergedTokenUsage,
            audioFileName: audioFileName.value,
            imageFileNames: mergedImageFiles.value,
            fileFileNames: mergedFileFiles.value,
            fullErrorContent: fullErrorContent.value,
            responseMetrics: mergedResponseMetrics,
            modelReference: mergedModelReference,
            costEstimate: mergedCostEstimate
        )
        merged.responseGroupID = local.responseGroupID ?? incoming.responseGroupID
        merged.responseAttemptID = local.responseAttemptID ?? incoming.responseAttemptID
        merged.responseAttemptIndex = local.responseAttemptIndex ?? incoming.responseAttemptIndex
        merged.selectedResponseAttemptID = local.selectedResponseAttemptID ?? incoming.selectedResponseAttemptID

        if local.id != incoming.id, local.content == incoming.content {
            merged.id = local.id
        }
        return merged
    }

    static func messagesShareMergeIdentity(_ local: ChatMessage, _ incoming: ChatMessage) -> Bool {
        guard local.role == incoming.role else {
            return false
        }

        return messagesShareContentIdentity(local, incoming)
    }

    static func messagesShareContentIdentity(_ local: ChatMessage, _ incoming: ChatMessage) -> Bool {
        if stringsAreCompatible(local.content, incoming.content) {
            return true
        }
        let localVersions = local.getAllVersions()
        let incomingVersions = incoming.getAllVersions()
        for localVersion in localVersions {
            if incomingVersions.contains(where: { stringsAreCompatible(localVersion, $0) }) {
                return true
            }
        }
        return false
    }

    static func buildMessage(
        from template: ChatMessage,
        versions: [String],
        currentVersionIndex: Int,
        requestedAt: Date?,
        reasoningContent: String?,
        toolCalls: [InternalToolCall]?,
        toolCallsPlacement: ToolCallsPlacement?,
        tokenUsage: MessageTokenUsage?,
        audioFileName: String?,
        imageFileNames: [String]?,
        fileFileNames: [String]?,
        fullErrorContent: String?,
        responseMetrics: MessageResponseMetrics?,
        modelReference: MessageModelReference? = nil,
        costEstimate: MessageCostEstimate? = nil
    ) -> ChatMessage {
        let safeVersions = versions.isEmpty ? [""] : versions
        var message = ChatMessage(
            id: template.id,
            role: template.role,
            content: safeVersions[0],
            requestedAt: requestedAt,
            reasoningContent: reasoningContent,
            toolCalls: toolCalls,
            toolCallsPlacement: toolCallsPlacement,
            tokenUsage: tokenUsage,
            modelReference: modelReference,
            costEstimate: costEstimate,
            audioFileName: audioFileName,
            imageFileNames: imageFileNames,
            fileFileNames: fileFileNames,
            fullErrorContent: fullErrorContent,
            responseMetrics: responseMetrics
        )
        if safeVersions.count > 1 {
            for version in safeVersions.dropFirst() {
                message.addVersion(version)
            }
            let safeCurrentIndex = min(max(0, currentVersionIndex), safeVersions.count - 1)
            message.switchToVersion(safeCurrentIndex)
        }
        return message
    }

    static func mergeMessageVersions(
        local: ChatMessage,
        incoming: ChatMessage,
        allowsDivergentVersions: Bool
    ) -> (versions: [String], currentVersionIndex: Int)? {
        let localCurrent = local.content
        let incomingCurrent = incoming.content
        guard stringsAreCompatible(localCurrent, incomingCurrent) else {
            guard allowsDivergentVersions else {
                return nil
            }
            return mergeDivergentMessageVersionsByIndex(local: local, incoming: incoming)
        }

        var versions = orderedMessageVersionUnion(
            local.getAllVersions(),
            incoming.getAllVersions()
        )

        let preferredCurrent = preferLongerString(localCurrent, incomingCurrent)
        if !versions.contains(preferredCurrent) {
            versions.append(preferredCurrent)
        }
        let currentIndex = versions.firstIndex(of: preferredCurrent) ?? max(0, versions.count - 1)
        return (versions, currentIndex)
    }

    static func mergeDivergentMessageVersionsByIndex(
        local: ChatMessage,
        incoming: ChatMessage
    ) -> (versions: [String], currentVersionIndex: Int)? {
        let versions = orderedMessageVersionUnion(
            local.getAllVersions(),
            incoming.getAllVersions()
        )
        guard !versions.isEmpty else {
            return nil
        }

        let preferredCurrent = preferLongerString(local.content, incoming.content)
        let currentIndex = versions.firstIndex(of: preferredCurrent)
            ?? versions.firstIndex(of: local.content)
            ?? versions.firstIndex(of: incoming.content)
            ?? max(0, versions.count - 1)
        return (versions, currentIndex)
    }

    static func orderedMessageVersionUnion(_ local: [String], _ incoming: [String]) -> [String] {
        var versions: [String] = []
        let maxCount = max(local.count, incoming.count)
        for index in 0..<maxCount {
            if local.indices.contains(index), !versions.contains(local[index]) {
                versions.append(local[index])
            }
            if incoming.indices.contains(index), !versions.contains(incoming[index]) {
                versions.append(incoming[index])
            }
        }
        return versions
    }
}
