// ============================================================================
// ChatServiceContextCompression.swift
// ============================================================================
// ETOS LLM Studio
//
// 执行附件语义提取、完整覆盖分块摘要、递归归并与续聊会话创建。
// ============================================================================

import Foundation
import Combine
import os

extension ChatService {
    private static let contextCompressionInputTokenBudget = 12_000
    private static let contextCompressionNodeMetadataTokenEstimate = 128
    private static let contextCompressionMaximumSynthesisLevels = 8

    private struct ContextCompressionSummaryNode: Sendable {
        let coveredMessageIDs: [UUID]
        let summary: String

        var estimatedTokens: Int {
            ContextCompressionTokenEstimator.estimate(summary)
                + ChatService.contextCompressionNodeMetadataTokenEstimate
        }
    }

    @discardableResult
    public func createCompressedContinuation(
        from sourceSessionID: UUID,
        options: ContextCompressionOptions = ContextCompressionOptions(),
        progress: @escaping @MainActor @Sendable (ContextCompressionProgress) -> Void = { _ in }
    ) async throws -> ChatSession {
        await progress(ContextCompressionProgress(phase: .preparing))
        try Task.checkCancellation()

        guard let sourceSession = chatSessionsSubject.value.first(where: { $0.id == sourceSessionID }) else {
            throw ContextCompressionError.sourceSessionNotFound
        }
        guard let compressionModel = resolvedChatCapableModel(
            storedIdentifier: options.compressionModelIdentifier
        ) else {
            throw ContextCompressionError.compressionModelNotFound
        }

        let sourceMessages = await contextCompressionSourceMessagesSnapshot(for: sourceSessionID)
        let inheritedContext = try await Task.detached(priority: .userInitiated) {
            try Persistence.loadConversationContinuationContext(for: sourceSessionID)
        }.value
        let effectiveMessages = inheritedContext.map {
            ContextCompressionPromptBuilder.continuationRequestMessages($0)
        } ?? []
        let preparedSourceMessages = try await prepareContextCompressionSourceMessages(
            effectiveMessages + sourceMessages,
            compressionModel: compressionModel,
            sourceSessionID: sourceSessionID
        )
        let plan = try ContextCompressionPlanner.makePlan(
            sourceMessages: preparedSourceMessages,
            retainedRoundCount: options.retainedRoundCount,
            inputTokenBudget: Self.contextCompressionInputTokenBudget
        )
        let finalSummary = try await generateContextCompressionSummary(
            plan: plan,
            options: options,
            compressionModel: compressionModel,
            sourceSessionID: sourceSessionID,
            progress: progress
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !finalSummary.isEmpty else {
            throw ContextCompressionError.emptySummary
        }

        try Task.checkCancellation()
        await progress(ContextCompressionProgress(phase: .saving))

        let childSession = ChatSession(
            id: UUID(),
            name: String(
                format: NSLocalizedString("%@ · 续聊", comment: "Compressed continuation session name"),
                sourceSession.name
            ),
            topicPrompt: sourceSession.topicPrompt,
            enhancedPrompt: sourceSession.enhancedPrompt,
            lorebookIDs: sourceSession.lorebookIDs,
            tagIDs: sourceSession.tagIDs,
            worldbookContextIsolationEnabled: sourceSession.worldbookContextIsolationEnabled,
            folderID: sourceSession.folderID,
            isTemporary: false
        )
        let context = ConversationContinuationContext(
            childSessionID: childSession.id,
            sourceSessionID: sourceSession.id,
            sourceSessionNameSnapshot: sourceSession.name,
            sourceThroughMessageID: plan.sourceThroughMessageID,
            summary: finalSummary,
            retainedMessages: plan.retainedMessages,
            retainedRoundCount: plan.retainedRoundCount,
            compressionModelIdentifier: compressionModel.id,
            sourceMessageCount: plan.sourceMessageCount,
            summarizedMessageCount: plan.summarizedMessageCount,
            estimatedSourceTokens: plan.estimatedSourceTokens,
            estimatedResultTokens: ContextCompressionTokenEstimator.estimate(finalSummary)
        )

        try await Task.detached(priority: .userInitiated) {
            try Persistence.createConversationContinuationSession(
                session: childSession,
                context: context
            )
        }.value

        storeRuntimeMessagesSnapshot([], for: childSession.id)
        await MainActor.run {
            var sessions = self.chatSessionsSubject.value
            sessions.removeAll { $0.id == childSession.id }
            sessions.insert(childSession, at: 0)
            self.chatSessionsSubject.send(sessions)
            self.currentSessionSubject.send(childSession)
            self.publishMessages([])
            self.logger.info("已创建上下文压缩续聊会话: \(childSession.id.uuidString)")
            AppLog.userOperation(
                category: NSLocalizedString("会话", comment: "App log category"),
                action: NSLocalizedString("创建压缩续聊", comment: "App log action"),
                payload: [
                    "sourceSessionID": sourceSession.id.uuidString,
                    "childSessionID": childSession.id.uuidString,
                    "sourceMessageCount": "\(plan.sourceMessageCount)",
                    "retainedRoundCount": "\(plan.retainedRoundCount)"
                ]
            )
        }
        return childSession
    }

    private func prepareContextCompressionSourceMessages(
        _ messages: [ChatMessage],
        compressionModel: RunnableModel,
        sourceSessionID: UUID
    ) async throws -> [ContextCompressionSourceMessage] {
        let visibleMessages = ChatResponseAttemptSupport.visibleMessages(from: messages)
            .filter { $0.role != .error }
        var attachmentCache: [String: ContextCompressionAttachmentContent] = [:]
        var preparedMessages: [ContextCompressionSourceMessage] = []

        for message in visibleMessages {
            try Task.checkCancellation()
            let attachmentContents = try await contextCompressionAttachmentContents(
                for: message,
                compressionModel: compressionModel,
                sourceSessionID: sourceSessionID,
                cache: &attachmentCache
            )
            let prepared = try ContextCompressionSourceMessage(
                message: message,
                attachmentContents: attachmentContents
            )
            if !prepared.semanticContent.isEmpty {
                preparedMessages.append(prepared)
            }
        }
        return preparedMessages
    }

    private func contextCompressionAttachmentContents(
        for message: ChatMessage,
        compressionModel: RunnableModel,
        sourceSessionID: UUID,
        cache: inout [String: ContextCompressionAttachmentContent]
    ) async throws -> [ContextCompressionAttachmentContent] {
        var contents: [ContextCompressionAttachmentContent] = []

        if let audioFileName = message.audioFileName {
            let content = try await cachedContextCompressionAttachment(
                identifier: audioFileName,
                kind: .audio,
                messageID: message.id,
                cache: &cache
            ) {
                guard let speechModel = self.resolveSelectedSpeechModel(),
                      let audioData = await Task.detached(priority: .utility, operation: {
                          Persistence.loadAudio(fileName: audioFileName)
                      }).value else {
                    throw ContextCompressionError.unsupportedAttachments(
                        messageID: message.id,
                        identifiers: [audioFileName]
                    )
                }
                let fileExtension = (audioFileName as NSString).pathExtension.lowercased()
                let transcript = try await self.transcribeAudio(
                    using: speechModel,
                    audioData: audioData,
                    fileName: audioFileName,
                    mimeType: "audio/\(fileExtension.isEmpty ? "m4a" : fileExtension)"
                )
                return transcript
            }
            contents.append(content)
        }

        for imageFileName in message.imageFileNames ?? [] {
            let content = try await cachedContextCompressionAttachment(
                identifier: imageFileName,
                kind: .image,
                messageID: message.id,
                cache: &cache
            ) {
                guard let imageData = await Task.detached(priority: .utility, operation: {
                    Persistence.loadImage(fileName: imageFileName)
                }).value,
                let visionModel = self.contextCompressionVisionModel(preferred: compressionModel) else {
                    throw ContextCompressionError.unsupportedAttachments(
                        messageID: message.id,
                        identifiers: [imageFileName]
                    )
                }
                let fileExtension = (imageFileName as NSString).pathExtension.lowercased()
                let mimeType = fileExtension == "png" ? "image/png" : "image/jpeg"
                let attachment = ImageAttachment(
                    data: imageData,
                    mimeType: mimeType,
                    fileName: imageFileName
                )
                let promptMessage = ChatMessage(
                    role: .user,
                    content: BuiltInPromptStore.render(.contextCompressionImageDescription)
                )
                return try await self.generateDetachedChatCompletion(
                    messages: [promptMessage],
                    temperature: 0,
                    runnableModel: visionModel,
                    requestSource: .contextCompression,
                    sessionID: sourceSessionID,
                    imageAttachments: [promptMessage.id: [attachment]]
                )
            }
            contents.append(content)
        }

        for fileName in message.fileFileNames ?? [] {
            let content = try await cachedContextCompressionAttachment(
                identifier: fileName,
                kind: .file,
                messageID: message.id,
                cache: &cache
            ) {
                try await Task.detached(priority: .utility) {
                    guard let data = Persistence.loadFile(fileName: fileName) else {
                        throw ContextCompressionError.unsupportedAttachments(
                            messageID: message.id,
                            identifiers: [fileName]
                        )
                    }
                    let attachment = FileAttachment(
                        data: data,
                        mimeType: "application/octet-stream",
                        fileName: fileName
                    )
                    return try FileAttachmentTextExtractor()
                        .extractTextPreservingLayout(from: attachment)
                }.value
            }
            contents.append(content)
        }
        return contents
    }

    private func cachedContextCompressionAttachment(
        identifier: String,
        kind: ContextCompressionAttachmentKind,
        messageID: UUID,
        cache: inout [String: ContextCompressionAttachmentContent],
        loader: () async throws -> String
    ) async throws -> ContextCompressionAttachmentContent {
        if let cached = cache[identifier] {
            return cached
        }
        let loadedContent = try await loader()
        guard !loadedContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ContextCompressionError.unsupportedAttachments(
                messageID: messageID,
                identifiers: [identifier]
            )
        }
        let result = ContextCompressionAttachmentContent(
            identifier: identifier,
            kind: kind,
            content: loadedContent
        )
        cache[identifier] = result
        return result
    }

    private func contextCompressionSourceMessagesSnapshot(
        for sessionID: UUID
    ) async -> [ChatMessage] {
        if currentSessionSubject.value?.id == sessionID {
            return messagesForSessionSubject.value
        }
        if let cachedMessages = runtimeMessagesSnapshot(for: sessionID) {
            return cachedMessages
        }
        return await Task.detached(priority: .userInitiated) {
            Persistence.loadMessages(for: sessionID)
        }.value
    }

    private func contextCompressionVisionModel(preferred: RunnableModel) -> RunnableModel? {
        let candidates = [preferred] + activatedOCRModels
        return candidates.first {
            $0.model.supportsVisionInput
                && !LocalModelProviderBridge.isLocalRunnableModel($0)
        }
    }

    private func generateContextCompressionSummary(
        plan: ContextCompressionPlan,
        options: ContextCompressionOptions,
        compressionModel: RunnableModel,
        sourceSessionID: UUID,
        progress: @escaping @MainActor @Sendable (ContextCompressionProgress) -> Void
    ) async throws -> String {
        guard !plan.chunks.isEmpty else {
            return NSLocalizedString("较早历史无需摘要；最近对话已按原文保留。", comment: "Continuation context with retained messages only")
        }

        var nodes: [ContextCompressionSummaryNode] = []
        for (index, chunk) in plan.chunks.enumerated() {
            try Task.checkCancellation()
            await progress(ContextCompressionProgress(
                phase: .summarizing(completed: index, total: plan.chunks.count)
            ))
            let summary = try await generateContextCompressionCompletion(
                userPrompt: ContextCompressionPromptBuilder.chunkUserPrompt(
                    chunk,
                    focusInstruction: options.focusInstruction
                ),
                compressionModel: compressionModel,
                sourceSessionID: sourceSessionID
            )
            nodes.append(ContextCompressionSummaryNode(
                coveredMessageIDs: orderedUniqueMessageIDs(in: chunk.fragments),
                summary: summary
            ))
        }
        await progress(ContextCompressionProgress(
            phase: .summarizing(completed: plan.chunks.count, total: plan.chunks.count)
        ))

        var level = 1
        while nodes.count > 1 {
            guard level <= Self.contextCompressionMaximumSynthesisLevels else {
                throw ContextCompressionError.unableToReduceSummaries
            }
            try Task.checkCancellation()
            await progress(ContextCompressionProgress(phase: .synthesizing(level: level)))
            let expandedNodes = try splitOversizedContextCompressionNodes(nodes)
            let groups = groupContextCompressionNodes(expandedNodes)
            var synthesizedNodes: [ContextCompressionSummaryNode] = []
            for group in groups {
                let prompt = try ContextCompressionPromptBuilder.synthesisUserPrompt(
                    group.map {
                        ContextCompressionSummaryInput(
                            coveredMessageIDs: $0.coveredMessageIDs,
                            summary: $0.summary
                        )
                    },
                    focusInstruction: options.focusInstruction
                )
                let summary = try await generateContextCompressionCompletion(
                    userPrompt: prompt,
                    compressionModel: compressionModel,
                    sourceSessionID: sourceSessionID
                )
                synthesizedNodes.append(ContextCompressionSummaryNode(
                    coveredMessageIDs: orderedUniqueMessageIDs(in: group),
                    summary: summary
                ))
            }
            nodes = synthesizedNodes
            level += 1
        }
        guard let summary = nodes.first?.summary else {
            throw ContextCompressionError.emptySummary
        }
        return summary
    }

    private func generateContextCompressionCompletion(
        userPrompt: String,
        compressionModel: RunnableModel,
        sourceSessionID: UUID
    ) async throws -> String {
        let summary = try await generateDetachedChatCompletion(
            systemPrompt: ContextCompressionPromptBuilder.systemPrompt,
            userPrompt: userPrompt,
            temperature: 0.2,
            runnableModel: compressionModel,
            requestSource: .contextCompression,
            sessionID: sourceSessionID
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else {
            throw ContextCompressionError.emptySummary
        }
        return summary
    }

    private func splitOversizedContextCompressionNodes(
        _ nodes: [ContextCompressionSummaryNode]
    ) throws -> [ContextCompressionSummaryNode] {
        var result: [ContextCompressionSummaryNode] = []
        for node in nodes {
            guard node.estimatedTokens > Self.contextCompressionInputTokenBudget else {
                result.append(node)
                continue
            }
            let message = ChatMessage(role: .user, content: node.summary)
            let source = try ContextCompressionSourceMessage(message: message)
            let plan = try ContextCompressionPlanner.makePlan(
                sourceMessages: [source],
                retainedRoundCount: 0,
                inputTokenBudget: Self.contextCompressionInputTokenBudget
            )
            for fragment in plan.chunks.flatMap(\.fragments) {
                result.append(ContextCompressionSummaryNode(
                    coveredMessageIDs: node.coveredMessageIDs,
                    summary: fragment.content
                ))
            }
        }
        return result
    }

    private func groupContextCompressionNodes(
        _ nodes: [ContextCompressionSummaryNode]
    ) -> [[ContextCompressionSummaryNode]] {
        var groups: [[ContextCompressionSummaryNode]] = []
        var current: [ContextCompressionSummaryNode] = []
        var currentTokens = 0

        for node in nodes {
            if !current.isEmpty,
               currentTokens + node.estimatedTokens > Self.contextCompressionInputTokenBudget {
                groups.append(current)
                current = []
                currentTokens = 0
            }
            current.append(node)
            currentTokens += node.estimatedTokens
        }
        if !current.isEmpty {
            groups.append(current)
        }
        return groups
    }

    private func orderedUniqueMessageIDs(
        in fragments: [ContextCompressionFragment]
    ) -> [UUID] {
        var seen = Set<UUID>()
        return fragments.compactMap { fragment in
            seen.insert(fragment.sourceMessageID).inserted ? fragment.sourceMessageID : nil
        }
    }

    private func orderedUniqueMessageIDs(
        in nodes: [ContextCompressionSummaryNode]
    ) -> [UUID] {
        var seen = Set<UUID>()
        return nodes.flatMap(\.coveredMessageIDs).compactMap { messageID in
            seen.insert(messageID).inserted ? messageID : nil
        }
    }
}
