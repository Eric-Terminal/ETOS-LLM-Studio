// ============================================================================
// ChatServiceGenerationHelpers.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责 ChatService 的独立推理、会话标题、快捷指令描述与记忆摘要辅助生成。
// ============================================================================

import Foundation
import Combine
import os.log

extension ChatService {
    func scheduleReasoningSummaryIfNeeded(for messageID: UUID, in sessionID: UUID) {
        guard isReasoningSummaryEnabled() else { return }

        let messages = messagesSnapshot(for: sessionID)
        guard let message = messages.first(where: { $0.id == messageID }),
              message.role == .assistant else {
            return
        }

        let reasoning = (message.reasoningContent ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reasoning.isEmpty else { return }

        let existingSummary = message.responseMetrics?.reasoningSummary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard existingSummary.isEmpty else { return }

        Task { [weak self] in
            await self?.performReasoningSummaryIfNeeded(
                for: messageID,
                in: sessionID,
                reasoning: reasoning
            )
        }
    }

    func scheduleConversationMemoryUpdateIfNeeded(for sessionID: UUID, enableMemory: Bool) {
        guard enableMemory else { return }
        guard isConversationMemoryEnabled() else { return }
        guard let session = chatSessionsSubject.value.first(where: { $0.id == sessionID }), !session.isTemporary else {
            return
        }
        guard !session.isWorldbookContextIsolationActive else { return }
        let messagesSnapshot = ChatResponseAttemptSupport.visibleMessages(from: messagesSnapshot(for: sessionID))
        Task { [weak self] in
            await self?.performConversationMemoryUpdateIfNeeded(
                for: sessionID,
                messages: messagesSnapshot
            )
        }
    }

    private func performReasoningSummaryIfNeeded(for messageID: UUID, in sessionID: UUID, reasoning: String) async {
        guard let runnableModel = resolvedReasoningSummaryModel() else { return }

        let summarySystemPrompt = NSLocalizedString("""
        你是思考摘要助手。请把思考内容压缩成一个短标签。
        约束：
        - 中文输出 6~18 字，其他语言输出 2~8 个词；
        - 只写核心动作或结论方向；
        - 不要复述细节，不要写完整解释；
        - 不要出现“思考内容摘要”“总结：”等前缀；
        - 不要句号，仅输出短标签正文。
        """, comment: "Reasoning summary system prompt")
        let summaryUserPrompt = String(
            format: NSLocalizedString("""
            思考内容：
            ```
            %@
            ```
            """, comment: "Reasoning summary user prompt"),
            reasoning
        )

        do {
            let rawSummary = try await generateDetachedChatCompletion(
                systemPrompt: summarySystemPrompt,
                userPrompt: summaryUserPrompt,
                temperature: 0.2,
                runnableModel: runnableModel,
                requestSource: .reasoningSummary,
                sessionID: sessionID
            )
            let summary = sanitizeReasoningSummaryText(rawSummary)
            guard !summary.isEmpty else { return }
            applyReasoningSummary(summary, for: messageID, in: sessionID, expectedReasoning: reasoning)
        } catch {
            logger.warning("异步思考摘要生成失败: \(error.localizedDescription)")
        }
    }

    private func sanitizeReasoningSummaryText(_ rawSummary: String, maxLength: Int = 24) -> String {
        let normalized = normalizeEscapedNewlinesIfNeeded(rawSummary)
        let singleLine = normalized
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .joined(separator: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !singleLine.isEmpty else { return "" }

        let prefixes = ["思考摘要：", "思考摘要:", "摘要：", "摘要:", "总结：", "总结:"]
        let trimmedPrefix = prefixes.first(where: { singleLine.hasPrefix($0) }).map {
            String(singleLine.dropFirst($0.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        } ?? singleLine

        guard !trimmedPrefix.isEmpty else { return "" }
        if trimmedPrefix.count <= maxLength {
            return trimmedPrefix
        }
        return String(trimmedPrefix.prefix(maxLength)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func applyReasoningSummary(_ summary: String, for messageID: UUID, in sessionID: UUID, expectedReasoning: String) {
        var messages = messagesSnapshot(for: sessionID)
        guard let index = messages.firstIndex(where: { $0.id == messageID }) else { return }

        let currentReasoning = messages[index].reasoningContent?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard currentReasoning == expectedReasoning else { return }

        var metrics = messages[index].responseMetrics ?? MessageResponseMetrics()
        guard metrics.reasoningSummary != summary else { return }

        metrics.reasoningSummary = summary
        messages[index].responseMetrics = metrics
        persistAndPublishMessages(messages, for: sessionID)
    }

    private func performConversationMemoryUpdateIfNeeded(for sessionID: UUID, messages: [ChatMessage]) async {
        let conversationalMessages = normalizedConversationMessagesForSummary(from: messages)
        guard !conversationalMessages.isEmpty else { return }

        let userTurnCount = conversationalMessages.filter { $0.role == .user }.count
        let roundThreshold = resolvedConversationMemoryRoundThreshold()
        guard userTurnCount >= roundThreshold else {
            return
        }

        if let existingSummary = ConversationMemoryManager.loadSessionSummary(for: sessionID) {
            let minInterval = resolvedConversationMemorySummaryMinIntervalMinutes()
            if minInterval > 0 {
                let elapsed = Date().timeIntervalSince(existingSummary.updatedAt)
                if elapsed < Double(minInterval) * 60 {
                    return
                }
            }
        }

        let summaryContext = makeConversationSummaryContext(from: conversationalMessages)
        guard !summaryContext.isEmpty else { return }
        let summarySystemPrompt = NSLocalizedString("""
        你是会话压缩助手，负责生成可用于长期记忆的跨对话摘要。请基于给定对话提炼后续对话真正有用的信息，而不是复述聊天记录。
        优先保留：
        - 用户稳定偏好、写作/编码风格、默认语言与输出格式；
        - 用户长期项目、角色背景、正在推进的目标；
        - 已明确达成的结论、决策、约定、待办；
        - 对后续协作有帮助的术语、文件、业务背景或上下文。
        忽略：
        - 寒暄、礼貌语、临时操作步骤、一次性细节；
        - 未确认的猜测、模型自己的推断、失败过程；
        - 敏感隐私与第三方隐私，除非用户明确要求长期记住且对后续任务必要；
        - 大段原文、代码或附件内容，只提炼长期有用结论。
        输出约束：
        - 中文输出 80~180 字，其他语言输出 70~160 个词；
        - 信息不足时只记录明确事实，不要编造；
        - 仅输出摘要正文，不要加标题、列表编号或免责声明。
        """, comment: "Conversation summary system prompt")
        let summaryUserPrompt = String(
            format: NSLocalizedString("""
            请总结以下对话：
            %@
            """, comment: "Conversation summary user prompt"),
            summaryContext
        )

        do {
            let rawSummary = try await generateDetachedChatCompletion(
                systemPrompt: summarySystemPrompt,
                userPrompt: summaryUserPrompt,
                temperature: 0.2,
                runnableModel: resolvedConversationSummaryModel(),
                requestSource: .conversationSummary,
                sessionID: sessionID
            )
            let summary = sanitizeConversationMemoryText(rawSummary, maxLength: 240)
            guard !summary.isEmpty else { return }
            ConversationMemoryManager.saveSessionSummary(
                sessionID: sessionID,
                summary: summary,
                updatedAt: Date()
            )
            await updateConversationProfileIfNeeded(sessionID: sessionID, latestSummary: summary)
        } catch {
            logger.warning("异步会话摘要生成失败: \(error.localizedDescription)")
        }
    }

    private func updateConversationProfileIfNeeded(sessionID: UUID, latestSummary: String) async {
        guard isConversationProfileDailyUpdateEnabled() else { return }
        guard ConversationMemoryManager.shouldUpdateUserProfile(on: Date()) else { return }

        let existingProfileText = ConversationMemoryManager.loadUserProfile()?.content ?? ""
        let profileSystemPrompt = NSLocalizedString("""
        你是用户画像整理助手。请根据“已有画像”和“最新会话摘要”输出更新后的用户画像。
        约束：
        - 不设固定长度上限，根据信息量自然展开；
        - 强调稳定偏好、工作背景、长期关注点；
        - 避免一次性细节与短期噪音；
        - 仅输出画像正文。
        """, comment: "Conversation profile update system prompt")
        let profileUserPrompt = String(
            format: NSLocalizedString("""
            已有画像：
            %@

            最新会话摘要：
            %@
            """, comment: "Conversation profile update user prompt"),
            existingProfileText.isEmpty ? "（暂无）" : existingProfileText,
            latestSummary
        )

        do {
            let rawProfile = try await generateDetachedChatCompletion(
                systemPrompt: profileSystemPrompt,
                userPrompt: profileUserPrompt,
                temperature: 0.2,
                runnableModel: resolvedConversationSummaryModel(),
                requestSource: .conversationProfile,
                sessionID: sessionID
            )
            let profileContent = sanitizeConversationMemoryText(rawProfile)
            guard !profileContent.isEmpty else { return }
            try ConversationMemoryManager.saveUserProfile(
                content: profileContent,
                updatedAt: Date(),
                sourceSessionID: sessionID
            )
        } catch {
            logger.warning("异步用户画像更新失败: \(error.localizedDescription)")
        }
    }

    func deduplicateConversationUserProfileIfNeeded(sessionID: UUID) async {
        guard let profile = ConversationMemoryManager.loadUserProfile(),
              profile.needsLLMDedup else {
            return
        }
        guard let runnableModel = resolvedConversationSummaryModel() else { return }

        let systemPrompt = NSLocalizedString("""
        你是用户画像去重助手。请把拼接后的多端用户画像压缩成一份一致画像。
        约束：
        - 保留稳定偏好、长期背景、常见工作方式；
        - 合并重复语义，删除互相矛盾或一次性噪音；
        - 不设固定长度上限，根据信息量自然展开；
        - 仅输出画像正文。
        """, comment: "Conversation profile dedup system prompt")
        let userPrompt = String(
            format: NSLocalizedString("""
            拼接画像：
            %@
            """, comment: "Conversation profile dedup user prompt"),
            profile.content
        )

        do {
            let rawProfile = try await generateDetachedChatCompletion(
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                temperature: 0.2,
                runnableModel: runnableModel,
                requestSource: .conversationProfile,
                sessionID: sessionID
            )
            let profileContent = sanitizeConversationMemoryText(rawProfile)
            guard !profileContent.isEmpty else { return }
            try ConversationMemoryManager.saveUserProfile(
                content: profileContent,
                updatedAt: Date(),
                sourceSessionID: profile.sourceSessionID,
                needsLLMDedup: false
            )
        } catch {
            logger.warning("用户画像同步去重失败: \(error.localizedDescription)")
        }
    }

    private func normalizedConversationMessagesForSummary(from messages: [ChatMessage]) -> [ChatMessage] {
        messages.compactMap { message in
            guard message.role == .user || message.role == .assistant else { return nil }
            let trimmed = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            var normalized = message
            normalized.content = trimmed
            return normalized
        }
    }

    private func makeConversationSummaryContext(from messages: [ChatMessage], messageLimit: Int = 12) -> String {
        let slice = messages.suffix(max(1, messageLimit))
        let lines = slice.map { message -> String in
            let roleText = message.role == .user ? "用户" : "助手"
            let compact = sanitizeConversationMemoryText(message.content, maxLength: 2_000)
            return "\(roleText): \(compact)"
        }
        return lines.joined(separator: "\n")
    }

    private func sanitizeConversationMemoryText(_ text: String, maxLength: Int? = nil) -> String {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’"))
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        guard let maxLength else { return normalized }
        guard normalized.count > maxLength else { return normalized }
        let cutIndex = normalized.index(normalized.startIndex, offsetBy: maxLength)
        return String(normalized[..<cutIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func generateShortcutToolDescription(
        toolName: String,
        metadata: [String: JSONValue],
        source: String?
    ) async -> String? {
        guard let runnableModel = resolvedChatCapableModel() else {
            return nil
        }

        let metadataText: String = {
            guard !metadata.isEmpty else { return "{}" }
            return JSONValue.dictionary(metadata).prettyPrintedCompact()
        }()

        let sourceText = source?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? (source?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
            : NSLocalizedString("无", comment: "")

        let promptTemplate = NSLocalizedString("""
        你是一个 iOS 自动化分析助手。请根据以下快捷指令信息，生成一段“给 AI 工具调用用”的描述。

        要求：
        - 中文输出 40~120 字，其他语言输出 35~90 个词；
        - 重点说明这个快捷指令能做什么、适合何时调用、输入输出大致是什么；
        - 避免空话，不要出现免责声明；
        - 只返回描述正文。

        快捷指令名称：%@
        元数据：%@
        源码/流程摘要：%@
        """, comment: "Prompt for generating shortcut tool description.")
        let prompt = String(format: promptTemplate, toolName, metadataText, sourceText)

        do {
            let rawDescription = try await generateDetachedChatCompletion(
                userPrompt: prompt,
                temperature: 0.2,
                runnableModel: runnableModel,
                requestSource: .shortcutDescription
            )
            let text = rawDescription
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'”’"))
            return text.isEmpty ? nil : text
        } catch {
            logger.warning("生成快捷指令描述失败: \(error.localizedDescription)")
            return nil
        }
    }

    /// 执行一次不落入聊天历史的独立推理请求，适合标题生成、每日摘要等辅助功能。
    public func generateDetachedChatCompletion(
        systemPrompt: String? = nil,
        userPrompt: String,
        temperature: Double = 0.4,
        runnableModel: RunnableModel? = nil,
        requestSource: UsageRequestSource,
        sessionID: UUID? = nil,
        appendOutputLanguageInstruction: Bool = true
    ) async throws -> String {
        let trimmedUserPrompt = userPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUserPrompt.isEmpty else { return "" }

        guard let targetModel = runnableModel ?? detachedChatCompletionFallbackModel() else {
            throw DetachedCompletionError.noAvailableModel
        }
        guard let adapter = adapters[targetModel.provider.apiFormat] else {
            throw DetachedCompletionError.unsupportedAdapter
        }

        var requestMessages: [ChatMessage] = []
        var didAttachLanguageInstruction = false
        if let systemPrompt {
            let trimmedSystemPrompt = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedSystemPrompt.isEmpty {
                let systemContent = appendOutputLanguageInstruction
                    ? ModelPromptLanguage.appendingOutputInstruction(to: trimmedSystemPrompt)
                    : trimmedSystemPrompt
                requestMessages.append(ChatMessage(
                    role: .system,
                    content: systemContent
                ))
                didAttachLanguageInstruction = appendOutputLanguageInstruction
            }
        }
        let finalUserPrompt = didAttachLanguageInstruction || !appendOutputLanguageInstruction
            ? trimmedUserPrompt
            : ModelPromptLanguage.appendingOutputInstruction(to: trimmedUserPrompt)
        requestMessages.append(ChatMessage(role: .user, content: finalUserPrompt))

        let payload: [String: Any] = [
            "temperature": temperature,
            "stream": false
        ]
        var commonPayload = payload
        commonPayload[ReasoningContentEchoPayload.key] = await openAIReasoningContentEchoModeControlValue()
        guard let request = adapter.buildChatRequest(
            for: targetModel,
            commonPayload: commonPayload,
            messages: requestMessages,
            tools: nil,
            audioAttachments: [:],
            imageAttachments: [:],
            fileAttachments: [:]
        ) else {
            throw DetachedCompletionError.buildRequestFailed
        }

        let requestContext = RequestLogContext(
            requestID: UUID(),
            sessionID: sessionID,
            providerID: targetModel.provider.id,
            providerName: targetModel.provider.name,
            modelID: targetModel.model.modelName,
            requestSource: requestSource,
            isStreaming: false,
            requestedAt: Date()
        )

        do {
            let data = try await fetchData(for: request, provider: targetModel.provider)
            do {
                let responseMessage = try adapter.parseResponse(data: data)
                persistRequestLog(
                    context: requestContext,
                    status: .success,
                    tokenUsage: responseMessage.tokenUsage,
                    finishedAt: Date()
                )
                return responseMessage.content.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                persistRequestLog(
                    context: requestContext,
                    status: .failed,
                    tokenUsage: nil,
                    finishedAt: Date(),
                    errorKind: "parse_response_failed"
                )
                throw error
            }
        } catch is CancellationError {
            persistRequestLog(
                context: requestContext,
                status: .cancelled,
                tokenUsage: nil,
                finishedAt: Date(),
                errorKind: "cancelled"
            )
            throw CancellationError()
        } catch NetworkError.badStatusCode(let code, let bodyData) {
            persistRequestLog(
                context: requestContext,
                status: .failed,
                tokenUsage: nil,
                finishedAt: Date(),
                httpStatusCode: code,
                errorKind: "bad_status_code"
            )
            throw NetworkError.badStatusCode(code: code, responseBody: bodyData)
        } catch {
            let errorKind = isCancellationError(error) ? "cancelled" : "network_error"
            let status: RequestLogStatus = isCancellationError(error) ? .cancelled : .failed
            persistRequestLog(
                context: requestContext,
                status: status,
                tokenUsage: nil,
                finishedAt: Date(),
                errorKind: errorKind
            )
            throw error
        }
    }

    func detachedChatCompletionFallbackModel() -> RunnableModel? {
        selectedModelSubject.value?.model.isChatModel == true
            ? selectedModelSubject.value
            : activatedChatModels.first
    }

    func buildMemoryQueryContext(from messages: [ChatMessage], fallbackUserMessage: ChatMessage?) -> String? {
        let window = latestTwoRounds(from: messages)
        let lines = window.compactMap { message -> String? in
            let trimmed = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            switch message.role {
            case .user:
                return "User: \(trimmed)"
            case .assistant:
                return "Assistant: \(trimmed)"
            default:
                return nil
            }
        }
        if !lines.isEmpty {
            return lines.joined(separator: "\n")
        }
        return fallbackUserMessage?.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func latestTwoRounds(from messages: [ChatMessage]) -> [ChatMessage] {
        var collected: [ChatMessage] = []
        var userCount = 0
        var assistantCount = 0

        for message in messages.reversed() {
            switch message.role {
            case .user:
                if userCount < 2 {
                    collected.append(message)
                    userCount += 1
                }
            case .assistant:
                if assistantCount < 2 {
                    collected.append(message)
                    assistantCount += 1
                }
            default:
                continue
            }
            if userCount >= 2 && assistantCount >= 2 {
                break
            }
        }
        return collected.reversed()
    }

    func generateAndApplySessionTitle(for sessionID: UUID, firstUserMessage: ChatMessage) async {
        let isAutoNamingEnabled = await MainActor.run {
            AppConfigStore.shared.enableAutoSessionNaming
        }
        guard isAutoNamingEnabled else {
            logger.info("自动标题功能已禁用，跳过生成。")
            return
        }

        let dedicatedModelIdentifier = Persistence.readAppConfigText(key: AppConfigKey.titleGenerationModelIdentifier.rawValue) ?? ""
        guard let runnableModel = resolveTitleGenerationModel() else {
            logger.error("无法获取标题模型，无法生成标题。")
            return
        }
        let usingDedicatedTitleModel = !dedicatedModelIdentifier.isEmpty && dedicatedModelIdentifier == runnableModel.id

        logger.info(
            "开始为会话 \(sessionID.uuidString) 生成标题，使用\(usingDedicatedTitleModel ? "独立标题模型" : "当前对话模型"): \(runnableModel.model.displayName, privacy: .public)"
        )

        let titlePromptTemplate = NSLocalizedString("""
        请根据用户的问题，为本次对话生成一个简短、精炼的标题。

        要求：
        - 长度在2到6个词之间。
        - 能准确概括用户想要讨论的主题。
        - 直接返回标题内容，不要包含任何额外说明、引号或标点符号。

        用户的问题：
        %@
        """, comment: "Prompt to generate a concise session title from user message.")
        let titlePrompt = String(format: titlePromptTemplate, firstUserMessage.content)

        do {
            let rawTitle = try await generateDetachedChatCompletion(
                userPrompt: titlePrompt,
                temperature: 0.5,
                runnableModel: runnableModel,
                requestSource: .sessionTitle,
                sessionID: sessionID
            )

            let newTitle = rawTitle
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'”’"))

            guard !newTitle.isEmpty else {
                logger.warning("AI返回的标题为空。")
                return
            }

            var currentSessions = chatSessionsSubject.value
            if let index = currentSessions.firstIndex(where: { $0.id == sessionID }) {
                currentSessions[index].name = newTitle

                if var currentSession = currentSessionSubject.value, currentSession.id == sessionID {
                    currentSession.name = newTitle
                    currentSessionSubject.send(currentSession)
                }

                chatSessionsSubject.send(currentSessions)
                Persistence.saveChatSessions(currentSessions)
                logger.info("成功生成并应用新标题: '\(newTitle)'")
            }
        } catch {
            logger.error("生成会话标题时发生网络或解析错误: \(error.localizedDescription)")
        }
    }

    private func resolveTitleGenerationModel() -> RunnableModel? {
        let dedicatedModelIdentifier = Persistence.readAppConfigText(key: AppConfigKey.titleGenerationModelIdentifier.rawValue) ?? ""
        if !dedicatedModelIdentifier.isEmpty,
           let dedicatedModel = activatedChatModels.first(
                where: { $0.id == dedicatedModelIdentifier && $0.model.isChatModel }
           ) {
            return dedicatedModel
        }
        if let selectedModel = selectedModelSubject.value,
           selectedModel.model.isChatModel {
            return selectedModel
        }
        return activatedChatModels.first
    }
}
