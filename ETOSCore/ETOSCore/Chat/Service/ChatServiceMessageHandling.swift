// ============================================================================
// ChatServiceMessageHandling.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责 ChatService 的消息写入、更新、转写回填与回复原子化。
// ============================================================================

import Foundation
import Combine
import os.log

extension ChatService {
    // MARK: - 错误消息与消息写入

    public func addErrorMessage(_ content: String, sessionID: UUID? = nil, httpStatusCode: Int? = nil) {
        let resolvedSessionID: UUID
        if let sessionID {
            resolvedSessionID = sessionID
        } else if let currentSessionID = currentSessionSubject.value?.id {
            resolvedSessionID = currentSessionID
        } else {
            return
        }
        var messages = messagesSnapshot(for: resolvedSessionID)
        let originalMessages = messages
        var forcedMutationMessageIDs = Set<UUID>()

        // 格式化错误内容，使其更简洁易读
        let (formattedContent, fullContent) = formatErrorContent(content, httpStatusCode: httpStatusCode)

        let loadingIndex: Int? = {
            // 优先使用当前请求记录的 loading 消息，避免误命中历史中的空 assistant（例如工具调用占位消息）。
            if let loadingMessageID = loadingMessageID(for: resolvedSessionID),
               let index = messages.firstIndex(where: { $0.id == loadingMessageID && $0.role == .assistant }) {
                return index
            }

            // 回退策略仅允许替换“最后一条消息且为空 assistant”，避免破坏中间历史结构。
            guard let lastIndex = messages.indices.last else { return nil }
            let lastMessage = messages[lastIndex]
            let isLastLoadingAssistant = lastMessage.role == .assistant
                && lastMessage.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return isLastLoadingAssistant ? lastIndex : nil
        }()

        func makeErrorMessage(
            _ requestedAt: Date?,
            _ prefix: String? = nil,
            metadata: ResponseAttemptMetadata? = nil
        ) -> ChatMessage {
            let resolvedContent: String
            let resolvedFullContent: String?
            if let prefix, !prefix.isEmpty {
                resolvedContent = "\(prefix)\n\n\(formattedContent)"
                if let fullContent {
                    resolvedFullContent = "\(prefix)\n\n\(fullContent)"
                } else {
                    resolvedFullContent = nil
                }
            } else {
                resolvedContent = formattedContent
                resolvedFullContent = fullContent
            }
            var message = ChatMessage(
                id: UUID(),
                role: .error,
                content: resolvedContent,
                requestedAt: requestedAt,
                fullErrorContent: resolvedFullContent
            )
            applyResponseAttemptMetadata(metadata, to: &message)
            return message
        }

        // 找到正在加载中的消息
        if let loadingIndex {
            let loadingMessage = finalizeInterruptedReasoningMessage(messages[loadingIndex])
            messages[loadingIndex] = loadingMessage
            let loadingAttemptMetadata = responseAttemptMetadata(from: loadingMessage)
            let shouldPreserveLoadingMessage = messageHasDisplayablePayload(loadingMessage)

            if shouldPreserveLoadingMessage {
                // 流式正文只存在于运行期快照时，它与 originalMessages 相等，但磁盘仍可能是空占位。
                // 错误收尾必须强制落盘该助手消息，随后才能追加错误气泡。
                forcedMutationMessageIDs.insert(loadingMessage.id)
                messages.insert(makeErrorMessage(loadingMessage.requestedAt, metadata: loadingAttemptMetadata), at: loadingIndex + 1)
                logger.error("流式内容已保留，并追加错误消息。")
            } else {
                // 正常场景：将 loading message 转为 error
                messages[loadingIndex] = ChatMessage(
                    id: loadingMessage.id,
                    role: .error,
                    content: formattedContent,
                    requestedAt: loadingMessage.requestedAt,
                    modelReference: loadingMessage.modelReference,
                    costEstimate: loadingMessage.costEstimate,
                    fullErrorContent: fullContent,
                    sentSystemPromptSnapshot: loadingMessage.sentSystemPromptSnapshot,
                    responseGroupID: loadingMessage.responseGroupID,
                    responseAttemptID: loadingMessage.responseAttemptID,
                    responseAttemptIndex: loadingMessage.responseAttemptIndex,
                    selectedResponseAttemptID: loadingMessage.selectedResponseAttemptID ?? loadingMessage.responseAttemptID
                )
                logger.error("错误消息已添加。")
            }
        } else {
            // 没有 loading message，直接添加错误
            messages.append(makeErrorMessage(nil))
            logger.error("错误消息已添加。")
        }

        messages = messages.flatMap(ChatMessageAtomicContentSupport.atomized)

        let mutations: [(message: ChatMessage, afterMessageID: UUID?)] = messages.indices.compactMap { index in
            let message = messages[index]
            if originalMessages.first(where: { $0.id == message.id }) == message,
               !forcedMutationMessageIDs.contains(message.id) {
                return nil
            }
            let afterMessageID = index > messages.startIndex ? messages[messages.index(before: index)].id : nil
            return (message, afterMessageID)
        }
        // UI 先同步采用内存结果，磁盘写入继续在后台逐条提交；否则入口在返回后
        // 立即读取当前会话时，可能短暂看不到刚生成的错误气泡。
        storeRuntimeMessagesSnapshot(messages, for: resolvedSessionID)
        publishMessagesIfCurrentSession(messages, for: resolvedSessionID)
        Task { [weak self] in
            guard let self else { return }
            for mutation in mutations {
                do {
                    _ = try await self.upsertConversationMessage(
                        mutation.message,
                        to: resolvedSessionID,
                        afterMessageID: mutation.afterMessageID
                    )
                } catch {
                    self.logger.error("原子保存错误消息失败：\(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - 附件转写

    func handleBackgroundTranscription(audioAttachment: AudioAttachment, placeholder: String, messageID: UUID, sessionID: UUID) async {
        guard let speechModel = resolveSelectedSpeechModel() else {
            // 当开启直接发送音频给模型时，后台转文字是可选的增强功能
            // 没有配置语音模型时只记录日志，不显示错误打扰用户
            logger.info(" 后台语音转文字跳过: 未配置语音模型。消息将保持为 [语音消息] 显示。")
            return
        }

        logger.info("(后台) 正在使用 \(speechModel.model.displayName) 进行语音转文字...")

        do {
            let rawTranscript = try await transcribeAudio(
                using: speechModel,
                audioData: audioAttachment.data,
                fileName: audioAttachment.fileName,
                mimeType: audioAttachment.mimeType
            )
            let transcript = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !transcript.isEmpty else {
                // 转写结果为空时静默处理，不显示错误
                logger.warning("后台语音转文字返回空结果，消息将保持为 [语音消息] 显示。")
                return
            }

            await applyTranscriptionResult(
                transcript,
                toMessageWithID: messageID,
                in: sessionID,
                placeholder: placeholder
            )
        } catch {
            // 后台转文字失败时静默处理，不显示错误打扰用户
            // 因为音频已经成功发送给模型了，转文字只是可选的UI增强
            logger.warning("后台语音转文字失败: \(error.localizedDescription)。消息将保持为 [语音消息] 显示。")
        }
    }

    func applyTranscriptionResult(_ transcript: String, toMessageWithID messageID: UUID, in sessionID: UUID, placeholder: String) async {
        let cachedMessage = runtimeMessagesSnapshot(for: sessionID)?.first(where: { $0.id == messageID })
        let persistedMessage: ChatMessage?
        if cachedMessage == nil {
            persistedMessage = await Task.detached(priority: .utility) {
                Persistence.loadMessages(for: sessionID).first(where: { $0.id == messageID })
            }.value
        } else {
            persistedMessage = nil
        }
        guard var message = cachedMessage ?? persistedMessage else {
            logger.warning("未找到需要更新的语音消息（可能会话已被切换或删除）。")
            return
        }

        message.content = transcript
        do {
            _ = try await upsertConversationMessage(message, to: sessionID)
        } catch {
            logger.error("原子保存语音转写结果失败：\(error.localizedDescription)")
            return
        }

        let sessionsToPersist = await MainActor.run { () -> [ChatSession]? in
            var sessions = chatSessionsSubject.value
            guard let sessionIndex = sessions.firstIndex(where: { $0.id == sessionID }),
                  sessions[sessionIndex].name == placeholder else { return nil }
            sessions[sessionIndex].name = String(transcript.prefix(20))
            chatSessionsSubject.send(sessions)
            if currentSessionSubject.value?.id == sessionID {
                currentSessionSubject.send(sessions[sessionIndex])
            }
            return sessions
        }
        if let sessionsToPersist {
            await Task.detached(priority: .utility) {
                Persistence.saveChatSessions(sessionsToPersist)
            }.value
        }
    }

    // MARK: - 消息生命周期与重试恢复

    func finalizeInterruptedReasoningMessage(_ message: ChatMessage, completedAt: Date = Date()) -> ChatMessage {
        var updated = message
        let reasoning = (updated.reasoningContent ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reasoning.isEmpty else { return updated }

        var metrics = updated.responseMetrics ?? MessageResponseMetrics()
        if metrics.reasoningStartedAt == nil {
            metrics.reasoningStartedAt = metrics.requestStartedAt ?? updated.requestedAt ?? completedAt
        }
        if metrics.reasoningCompletedAt == nil {
            metrics.reasoningCompletedAt = completedAt
        }
        updated.responseMetrics = metrics
        return updated
    }

    func attachCostEstimateIfPossible(
        to message: inout ChatMessage,
        using context: RequestLogContext
    ) {
        message.modelReference = message.modelReference ?? context.modelReference
        message.costEstimate = ModelCostCalculator.estimateCost(
            usage: message.tokenUsage,
            pricing: context.modelPricing,
            requestedAt: message.requestedAt ?? context.requestedAt
        )
    }

    func removeMessage(withID messageID: UUID, in sessionID: UUID) async {
        if messagesSnapshot(for: sessionID).contains(where: { $0.id == messageID }) {
            do {
                _ = try await deleteConversationMessage(id: messageID, from: sessionID)
            } catch {
                logger.error("原子移除占位消息失败：\(error.localizedDescription)")
                return
            }
            logger.info("已移除占位消息 \(messageID.uuidString)。")
        }
    }

    func shouldRemoveLoadingMessageOnCancel(loadingMessageID: UUID, in sessionID: UUID) -> Bool {
        guard let message = messagesSnapshot(for: sessionID).first(where: { $0.id == loadingMessageID }) else {
            return false
        }
        return !messageHasDisplayablePayload(message)
    }

    func finalizeInterruptedReasoningMessageIfNeeded(loadingMessageID: UUID, in sessionID: UUID) async {
        guard let message = messagesSnapshot(for: sessionID).first(where: { $0.id == loadingMessageID }) else { return }
        let finalizedMessage = finalizeInterruptedReasoningMessage(message)
        guard finalizedMessage != message else { return }
        do {
            _ = try await upsertConversationMessage(finalizedMessage, to: sessionID)
        } catch {
            logger.error("原子保存中断推理消息失败：\(error.localizedDescription)")
        }
    }

    func messageHasDisplayablePayload(_ message: ChatMessage) -> Bool {
        let hasContent = !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasReasoning = !(message.reasoningContent ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasToolCalls = !(message.toolCalls ?? []).isEmpty
        let hasImages = !(message.imageFileNames ?? []).isEmpty
        let hasAudio = message.audioFileName != nil
        let hasFiles = !(message.fileFileNames ?? []).isEmpty
        return hasContent || hasReasoning || hasToolCalls || hasImages || hasAudio || hasFiles
    }

    /// 将最终确定的消息更新到消息列表中
    func updateMessage(with newMessage: ChatMessage, for loadingMessageID: UUID, in sessionID: UUID) async {
        let priorMessages = messagesSnapshot(for: sessionID)
        let didProcessRoleplay = RoleplayRuntime.processMVU(
            content: newMessage.content,
            messageID: loadingMessageID,
            versionIndex: priorMessages.first(where: { $0.id == loadingMessageID })?.getCurrentVersionIndex() ?? 0,
            sessionID: sessionID,
            previousMessages: priorMessages.filter { $0.id != loadingMessageID },
            store: roleplayStore
        )
        let messageRegexRules = MessageRegexRuleStore.currentRules()
        let newMessage = messageRegexRules.isEmpty
            ? newMessage
            : applyMessageRegexRules(to: newMessage, rules: messageRegexRules, mode: .persist)
        let messages = messagesSnapshot(for: sessionID)

        if let index = messages.firstIndex(where: { $0.id == loadingMessageID }) {
            // 无论普通请求还是轮次重试，都只替换已预先放入正确位置的占位气泡。
            let preservedToolCalls = messages[index].toolCalls
            let mergedToolCalls: [InternalToolCall]? = {
                if let newCalls = newMessage.toolCalls, !newCalls.isEmpty {
                    return newCalls
                }
                // 如果新消息没有附带工具调用，则沿用之前的记录，方便在最终答案中回顾工具使用详情。
                return preservedToolCalls
            }()
            let updatedMessage = ChatMessage(
                id: loadingMessageID, // 保持ID不变
                role: newMessage.role,
                content: newMessage.content,
                requestedAt: messages[index].requestedAt ?? newMessage.requestedAt,
                reasoningContent: newMessage.reasoningContent,
                reasoningProviderSpecificFields: newMessage.reasoningProviderSpecificFields ?? messages[index].reasoningProviderSpecificFields,
                providerResponseMetadata: newMessage.providerResponseMetadata ?? messages[index].providerResponseMetadata,
                toolCalls: mergedToolCalls, // 确保 toolCalls 保持最新或沿用历史数据
                toolCallsPlacement: newMessage.toolCallsPlacement ?? messages[index].toolCallsPlacement,
                tokenUsage: newMessage.tokenUsage ?? messages[index].tokenUsage,
                modelReference: newMessage.modelReference ?? messages[index].modelReference,
                costEstimate: newMessage.costEstimate ?? messages[index].costEstimate,
                audioFileName: newMessage.audioFileName ?? messages[index].audioFileName,
                imageFileNames: newMessage.imageFileNames ?? messages[index].imageFileNames,
                modelExcludedImageFileNames: newMessage.modelExcludedImageFileNames
                    ?? messages[index].modelExcludedImageFileNames,
                fileFileNames: newMessage.fileFileNames ?? messages[index].fileFileNames,
                videoAnalysisResults: newMessage.videoAnalysisResults ?? messages[index].videoAnalysisResults,
                fullErrorContent: newMessage.fullErrorContent ?? messages[index].fullErrorContent,
                sentSystemPromptSnapshot: newMessage.sentSystemPromptSnapshot ?? messages[index].sentSystemPromptSnapshot,
                responseMetrics: newMessage.responseMetrics ?? messages[index].responseMetrics,
                responseGroupID: newMessage.responseGroupID ?? messages[index].responseGroupID,
                responseAttemptID: newMessage.responseAttemptID ?? messages[index].responseAttemptID,
                responseAttemptIndex: newMessage.responseAttemptIndex ?? messages[index].responseAttemptIndex,
                selectedResponseAttemptID: newMessage.selectedResponseAttemptID ?? messages[index].selectedResponseAttemptID
            )
            let atomizedMessages = ChatMessageAtomicContentSupport.atomized(updatedMessage)
            var updatedMessages = messages
            updatedMessages.replaceSubrange(index...index, with: atomizedMessages)
            persistAndPublishMessages(
                updatedMessages,
                for: sessionID,
                keepingSpeedSamplesFor: loadingMessageID
            )
            if didProcessRoleplay != nil {
                // 流式正文可能已与最终消息相同；变量快照落盘后仍需显式重算酒馆 HTML。
                RoleplayDisplayedMessageBridge.postDidChange(sessionID: sessionID)
            }
        }
    }

    // MARK: - 成就追踪

    func scheduleAssistantReplyAchievementDetectionIfNeeded(_ content: String) {
        Task.detached(priority: .utility) {
            guard !content.isEmpty else { return }

            let hasUnlockedSteadyCatch = await AchievementCenter.shared.hasUnlocked(id: .steadyCatch)
            if !hasUnlockedSteadyCatch,
               AchievementTriggerEvaluator.shouldUnlockSteadyCatch(from: content) {
                await AchievementCenter.shared.unlock(id: .steadyCatch)
            }

            let hasUnlockedLanguageLubrication = await AchievementCenter.shared.hasUnlocked(id: .languageLubrication)
            if !hasUnlockedLanguageLubrication,
               AchievementTriggerEvaluator.shouldUnlockLanguageLubrication(from: content) {
                await AchievementCenter.shared.unlock(id: .languageLubrication)
            }
        }
    }

    func scheduleUserMessageAchievementDetectionIfNeeded(
        content: String,
        userMessageCount: Int,
        sentAt: Date,
        previousAssistantReply: String?
    ) {
        Task.detached(priority: .utility) {
            let hasUnlockedPoliteHuman = await AchievementCenter.shared.hasUnlocked(id: .politeHuman)
            let ids = AchievementTriggerEvaluator.userMessageAchievementIDs(
                for: content,
                userMessageCount: userMessageCount,
                sentAt: sentAt,
                previousAssistantReply: previousAssistantReply,
                includePoliteHuman: !hasUnlockedPoliteHuman
            )
            guard !ids.isEmpty else { return }

            for id in ids {
                let hasUnlocked = await AchievementCenter.shared.hasUnlocked(id: id)
                guard !hasUnlocked else { continue }
                await AchievementCenter.shared.unlock(id: id)
            }
        }
    }

    func latestAssistantReply(in sessionID: UUID) -> String? {
        messagesSnapshot(for: sessionID).last(where: {
            $0.role == .assistant
                && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        })?.content
    }

    func registerRetryAchievementAttempt(sessionID: UUID, content: String) {
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedContent.isEmpty else {
            resetConsecutiveRetryTracking()
            return
        }

        let signature = RetryAchievementSignature(sessionID: sessionID, content: trimmedContent)
        if consecutiveRetrySignature == signature {
            consecutiveRetryCount += 1
        } else {
            consecutiveRetrySignature = signature
            consecutiveRetryCount = 1
        }

        if AchievementTriggerEvaluator.shouldUnlockSchrodingerQuestion(consecutiveRetryCount: consecutiveRetryCount) {
            scheduleAchievementUnlockIfNeeded(.schrodingerQuestion)
        }
    }

    func resetConsecutiveRetryTracking() {
        consecutiveRetrySignature = nil
        consecutiveRetryCount = 0
    }
}
