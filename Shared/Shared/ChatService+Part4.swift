// ============================================================================
// ChatService.swift
// ============================================================================ 
// ETOS LLM Studio
//
// 本类作为应用的中央大脑，处理所有与平台无关的业务逻辑。
// 它被设计为单例，以便在应用的不同部分（iOS 和 watchOS）之间共享。
// ============================================================================ 

import Foundation
import Combine
import CryptoKit
import os.log
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

/// 一个组合了 Provider 和 Model 的可运行实体，包含了发起 API 请求所需的所有信息。
extension ChatService {

    func orderedToolCallIDs(from toolCalls: [InternalToolCall]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for call in toolCalls {
            guard let id = normalizedToolCallID(call.id), seen.insert(id).inserted else { continue }
            ordered.append(id)
        }
        return ordered
    }

    func normalizedToolCallID(from message: ChatMessage) -> String? {
        guard let id = message.toolCalls?.first?.id else { return nil }
        return normalizedToolCallID(id)
    }

    func normalizedToolCallID(_ id: String) -> String? {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
        
    public func sendAndProcessMessage(
        content: String,
        aiTemperature: Double,
        aiTopP: Double,
        systemPrompt: String,
        maxChatHistory: Int,
        enableStreaming: Bool,
        enhancedPrompt: String?,
        enableMemory: Bool,
        enableMemoryWrite: Bool,
        enableMemoryActiveRetrieval: Bool = false,
        includeSystemTime: Bool,
        systemTimeInjectionPosition: SystemTimeInjectionPosition = .front,
        enablePeriodicTimeLandmark: Bool = false,
        periodicTimeLandmarkIntervalMinutes: Int = 30,
        enableResponseSpeedMetrics: Bool = true,
        audioAttachment: AudioAttachment? = nil,
        imageAttachments: [ImageAttachment] = [],
        fileAttachments: [FileAttachment] = [],
        isRetry: Bool = false
    ) async {
        await waitForInitialPersistenceStateIfNeeded()

        guard var currentSession = currentSessionSubject.value else {
            addErrorMessage(NSLocalizedString("错误: 没有当前会话。", comment: "No current session error"))
            requestStatusSubject.send(.error)
            return
        }

        if !isRetry {
            resetConsecutiveRetryTracking()
        }

        // 若当前模型具备图像输出能力，则主聊天输入直接切到生图请求通道。
        if let selectedModel = selectedModelSubject.value,
           shouldRouteMessageToImageGeneration(using: selectedModel) {
            if audioAttachment != nil {
                let reason = NSLocalizedString("生图模式不支持语音附件。", comment: "Image mode does not support audio attachments")
                addErrorMessage(reason)
                requestStatusSubject.send(.error)
                return
            }
            if !fileAttachments.isEmpty {
                let reason = NSLocalizedString("生图模式仅支持文本提示词和图片参考图。", comment: "Image mode only supports text prompt and reference images")
                addErrorMessage(reason)
                requestStatusSubject.send(.error)
                return
            }

            await generateImageAndProcessMessage(
                prompt: content,
                imageAttachments: imageAttachments,
                runnableModel: selectedModel
            )
            return
        }

        // 准备用户消息和UI占位消息
        let audioPlaceholder = NSLocalizedString("[语音消息]", comment: "Audio message placeholder")
        let imagePlaceholder = NSLocalizedString("[图片]", comment: "Image message placeholder")
        var messageContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        var savedAudioFileName: String? = nil
        var savedImageFileNames: [String] = []
        var savedFileNames: [String] = []
        let requestTimestamp = Date()
        var userMessages: [ChatMessage] = []
        var primaryUserMessage: ChatMessage?
        
        if let audioAttachment {
            // 保存音频文件到持久化目录，使用时间戳命名
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            let timestamp = dateFormatter.string(from: Date())
            let audioFileName = "语音_\(timestamp).\(audioAttachment.format)"
            if Persistence.saveAudio(audioAttachment.data, fileName: audioFileName) != nil {
                savedAudioFileName = audioFileName
                logger.info("音频文件已保存: \(audioFileName)")
            }
        }
        
        // 保存图片附件
        for imageAttachment in imageAttachments {
            let imageFileName = imageAttachment.fileName
            if Persistence.saveImage(imageAttachment.data, fileName: imageFileName) != nil {
                savedImageFileNames.append(imageFileName)
                logger.info("图片文件已保存: \(imageFileName)")
            }
        }

        // 保存文件附件
        for fileAttachment in fileAttachments {
            let originalName = (fileAttachment.fileName as NSString).lastPathComponent
            let fallbackName = originalName.isEmpty ? "file-\(UUID().uuidString)" : originalName
            var targetName = fallbackName
            if Persistence.fileExists(fileName: targetName) {
                let ext = (fallbackName as NSString).pathExtension
                let name = (fallbackName as NSString).deletingPathExtension
                let suffix = UUID().uuidString.prefix(8)
                targetName = ext.isEmpty ? "\(name)_\(suffix)" : "\(name)_\(suffix).\(ext)"
            }
            if Persistence.saveFile(fileAttachment.data, fileName: targetName) != nil {
                savedFileNames.append(targetName)
                logger.info("文件附件已保存: \(targetName)")
            }
        }
        
        if messageContent.isEmpty && savedAudioFileName == nil {
            if !savedFileNames.isEmpty {
                messageContent = savedFileNames.joined(separator: "\n")
            } else if !savedImageFileNames.isEmpty {
                messageContent = imagePlaceholder
            }
        }
        
        // 构建用户消息列表：
        // - 若同时含语音和文字，拆分为两个独立气泡，方便单独删除
        // - 若只有一种内容，保持原有单条消息行为
        if let savedAudioFileName {
            let audioMessage = ChatMessage(
                role: .user,
                content: audioPlaceholder,
                requestedAt: requestTimestamp,
                audioFileName: savedAudioFileName,
                imageFileNames: savedImageFileNames.isEmpty ? nil : savedImageFileNames,
                fileFileNames: savedFileNames.isEmpty ? nil : savedFileNames
            )
            userMessages.append(audioMessage)
        }
        
        if !messageContent.isEmpty {
            // 当同时有语音与文字时，避免重复附带图片到文字消息（保持图片随首条消息）
            let imageNamesForText = savedAudioFileName == nil ? (savedImageFileNames.isEmpty ? nil : savedImageFileNames) : nil
            let fileNamesForText = savedAudioFileName == nil ? (savedFileNames.isEmpty ? nil : savedFileNames) : nil
            let textMessage = ChatMessage(
                role: .user,
                content: messageContent,
                requestedAt: requestTimestamp,
                audioFileName: nil,
                imageFileNames: imageNamesForText,
                fileFileNames: fileNamesForText
            )
            userMessages.append(textMessage)
        }
        
        // 兜底：如果没有生成任何用户消息，直接报错返回
        guard !userMessages.isEmpty else {
            addErrorMessage(
                NSLocalizedString("错误: 待发送消息为空。", comment: "Empty message error"),
                sessionID: currentSession.id
            )
            requestStatusSubject.send(.error)
            return
        }
        
        // 用于命名会话/记忆检索的代表消息：优先文字，其次第一条消息
        if let textMessage = userMessages.first(where: { $0.audioFileName == nil && !$0.content.isEmpty }) {
            primaryUserMessage = textMessage
        } else {
            primaryUserMessage = userMessages.first
        }
        let responseAttempt = ResponseAttemptMetadata(
            groupID: userMessages[userMessages.index(before: userMessages.endIndex)].id,
            attemptID: UUID(),
            attemptIndex: 0
        )
        if let anchorUserIndex = userMessages.indices.last {
            userMessages[anchorUserIndex].selectedResponseAttemptID = responseAttempt.attemptID
            if primaryUserMessage?.id == userMessages[anchorUserIndex].id {
                primaryUserMessage = userMessages[anchorUserIndex]
            }
        }
        let previousAssistantReply = latestAssistantReply(in: currentSession.id)
        let loadingMessage = ChatMessage(
            role: .assistant,
            content: "",
            requestedAt: requestTimestamp,
            responseGroupID: responseAttempt.groupID,
            responseAttemptID: responseAttempt.attemptID,
            responseAttemptIndex: responseAttempt.attemptIndex
        ) // 内容为空的助手消息作为加载占位符
        var wasTemporarySession = false
        
        var messages = messagesSnapshot(for: currentSession.id)
        messages.append(contentsOf: userMessages)
        messages.append(loadingMessage)
        persistAndPublishMessages(messages, for: currentSession.id)
        scheduleUserMessageAchievementDetectionIfNeeded(
            content: messageContent,
            userMessageCount: messages.filter { $0.role == .user }.count,
            sentAt: requestTimestamp,
            previousAssistantReply: previousAssistantReply
        )
        
        // 注意：当音频作为附件直接发送给模型时，不再需要后台转文字
        // 因为每次发送消息都会重新加载音频文件并以 base64 发送
        // UI 上通过 audioFileName 属性标识这是一条语音消息
        
        // 处理临时会话的转换
        if currentSession.isTemporary, let sessionTitleSource = primaryUserMessage {
            wasTemporarySession = true // 标记此为首次交互
            currentSession.name = String(sessionTitleSource.content.prefix(20))
            currentSession.isTemporary = false
            currentSessionSubject.send(currentSession)
            var updatedSessions = chatSessionsSubject.value
            if let index = updatedSessions.firstIndex(where: { $0.id == currentSession.id }) { updatedSessions[index] = currentSession }
            chatSessionsSubject.send(updatedSessions)
            Persistence.saveChatSessions(updatedSessions)
            logger.info("临时会话已转为永久会话: \(currentSession.name)")
            
            // 用户发送第一条消息时，立即异步生成标题（无需等待AI响应）
            let trimmedTitleSource = sessionTitleSource.content.trimmingCharacters(in: .whitespacesAndNewlines)
            let isPlaceholderTitle = trimmedTitleSource == audioPlaceholder || trimmedTitleSource == imagePlaceholder
            if !trimmedTitleSource.isEmpty && !isPlaceholderTitle {
                let sessionIDForTitle = currentSession.id
                let userMessageForTitle = sessionTitleSource
                Task {
                    await self.generateAndApplySessionTitle(for: sessionIDForTitle, firstUserMessage: userMessageForTitle)
                }
            } else {
                logger.info("跳过自动标题生成：首条消息为空或仅包含附件占位。")
            }
        } else {
            // 老会话重新收到消息时，将其排到列表顶部
            promoteSessionToTopIfNeeded(sessionID: currentSession.id)
        }
        
        emitSessionRequestStatus(.started, sessionID: currentSession.id)

        let requestToken = UUID()
        setRequestContext(
            RequestExecutionContext(
                token: requestToken,
                task: nil,
                loadingMessageID: loadingMessage.id,
                imageGenerationContext: nil
            ),
            for: currentSession.id
        )
        
        let requestTask = Task<Void, Error> { [weak self] in
            guard let self else { return }
            let requestTooling = await self.resolveRequestTooling(
                for: currentSession,
                enableMemory: enableMemory,
                enableMemoryWrite: enableMemoryWrite,
                enableMemoryActiveRetrieval: enableMemoryActiveRetrieval
            )
            await self.executeMessageRequest(
                messages: messages,
                loadingMessageID: loadingMessage.id,
                currentSessionID: currentSession.id,
                userMessage: primaryUserMessage,
                wasTemporarySession: wasTemporarySession,
                aiTemperature: aiTemperature,
                aiTopP: aiTopP,
                systemPrompt: systemPrompt,
                maxChatHistory: maxChatHistory,
                enableStreaming: enableStreaming,
                enhancedPrompt: enhancedPrompt,
                tools: requestTooling.tools,
                enableMemory: requestTooling.policy.enableMemory,
                enableMemoryWrite: requestTooling.policy.enableMemoryWrite,
                enableMemoryActiveRetrieval: requestTooling.policy.enableMemoryActiveRetrieval,
                includeSystemTime: includeSystemTime,
                systemTimeInjectionPosition: systemTimeInjectionPosition,
                enablePeriodicTimeLandmark: enablePeriodicTimeLandmark,
                periodicTimeLandmarkIntervalMinutes: periodicTimeLandmarkIntervalMinutes,
                enableResponseSpeedMetrics: enableResponseSpeedMetrics,
                currentAudioAttachment: audioAttachment,
                currentFileAttachments: fileAttachments
            )
        }
        updateRequestTask(requestTask, for: currentSession.id, token: requestToken)
        
        defer {
            clearRequestContextIfNeeded(for: currentSession.id, token: requestToken)
        }
        
        do {
            try await requestTask.value
        } catch is CancellationError {
            logger.info("请求已被用户取消，将等待后续动作。")
        } catch {
            // URLError.cancelled 不会匹配 CancellationError，需要单独检测
            if isCancellationError(error) {
                logger.info("请求已被用户取消 (URLError)，将等待后续动作。")
            } else {
                logger.error("请求执行过程中出现未预期错误: \(error.localizedDescription)")
            }
        }
    }

    public func generateImageAndProcessMessage(
        prompt: String,
        imageAttachments: [ImageAttachment] = [],
        runnableModel: RunnableModel? = nil,
        runtimeOverrideParameters: [String: JSONValue] = [:]
    ) async {
        guard var currentSession = currentSessionSubject.value else {
            let reason = NSLocalizedString("错误: 没有当前会话。", comment: "No current session error")
            addErrorMessage(reason)
            requestStatusSubject.send(.error)
            imageGenerationStatusSubject.send(
                .failed(
                    sessionID: nil,
                    loadingMessageID: nil,
                    prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
                    reason: reason,
                    finishedAt: Date()
                )
            )
            return
        }

        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            let reason = NSLocalizedString("错误: 生图提示词不能为空。", comment: "Image generation prompt empty")
            addErrorMessage(reason, sessionID: currentSession.id)
            requestStatusSubject.send(.error)
            imageGenerationStatusSubject.send(
                .failed(
                    sessionID: currentSession.id,
                    loadingMessageID: nil,
                    prompt: trimmedPrompt,
                    reason: reason,
                    finishedAt: Date()
                )
            )
            return
        }

        guard let runnableModel = runnableModel ?? selectedModelSubject.value else {
            let reason = NSLocalizedString("错误: 没有选中的可用模型。请在设置中激活一个模型。", comment: "No active model error")
            addErrorMessage(reason, sessionID: currentSession.id)
            requestStatusSubject.send(.error)
            imageGenerationStatusSubject.send(
                .failed(
                    sessionID: currentSession.id,
                    loadingMessageID: nil,
                    prompt: trimmedPrompt,
                    reason: reason,
                    finishedAt: Date()
                )
            )
            return
        }

        logger.info(
            "开始生图流程: session=\(currentSession.id.uuidString), provider=\(runnableModel.provider.name), model=\(runnableModel.model.displayName), promptLength=\(trimmedPrompt.count), referenceCount=\(imageAttachments.count), runtimeOverrideCount=\(runtimeOverrideParameters.count)"
        )

        guard let adapter = adapters[runnableModel.provider.apiFormat] else {
            let reason = String(
                format: NSLocalizedString("错误: 找不到适用于 '%@' 格式的 API 适配器。", comment: "Missing API adapter error"),
                runnableModel.provider.apiFormat
            )
            addErrorMessage(reason, sessionID: currentSession.id)
            requestStatusSubject.send(.error)
            imageGenerationStatusSubject.send(
                .failed(
                    sessionID: currentSession.id,
                    loadingMessageID: nil,
                    prompt: trimmedPrompt,
                    reason: reason,
                    finishedAt: Date()
                )
            )
            return
        }

        guard runnableModel.model.supportsImageGeneration else {
            let reason = NSLocalizedString("当前模型不可用于生图，请在模型设置中将用途设为图片生成，或在模型能力中开启可生成图片。", comment: "模型没有生图能力提示")
            addErrorMessage(reason, sessionID: currentSession.id)
            requestStatusSubject.send(.error)
            imageGenerationStatusSubject.send(
                .failed(
                    sessionID: currentSession.id,
                    loadingMessageID: nil,
                    prompt: trimmedPrompt,
                    reason: reason,
                    finishedAt: Date()
                )
            )
            return
        }

        var savedImageFileNames: [String] = []
        for imageAttachment in imageAttachments {
            var targetName = imageAttachment.fileName
            if targetName.isEmpty {
                targetName = "\(UUID().uuidString).jpg"
            }
            if Persistence.imageFileExists(fileName: targetName) {
                let ext = (targetName as NSString).pathExtension
                let stem = (targetName as NSString).deletingPathExtension
                let suffix = UUID().uuidString.prefix(8)
                targetName = ext.isEmpty ? "\(stem)_\(suffix)" : "\(stem)_\(suffix).\(ext)"
            }
            if Persistence.saveImage(imageAttachment.data, fileName: targetName) != nil {
                savedImageFileNames.append(targetName)
                logger.info("生图参考图已保存: \(targetName)")
            } else {
                logger.error("生图参考图保存失败: \(targetName)")
            }
        }

        let userMessage = ChatMessage(
            role: .user,
            content: trimmedPrompt,
            requestedAt: Date(),
            imageFileNames: savedImageFileNames.isEmpty ? nil : savedImageFileNames
        )
        let loadingMessage = ChatMessage(
            role: .assistant,
            content: "",
            requestedAt: Date()
        )

        var messages = messagesSnapshot(for: currentSession.id)
        messages.append(userMessage)
        messages.append(loadingMessage)
        persistAndPublishMessages(messages, for: currentSession.id)
        scheduleUserMessageAchievementDetectionIfNeeded(
            content: trimmedPrompt,
            userMessageCount: messages.filter { $0.role == .user }.count,
            sentAt: userMessage.requestedAt ?? Date(),
            previousAssistantReply: latestAssistantReply(in: currentSession.id)
        )
        logger.info("生图占位消息已创建: loadingMessageID=\(loadingMessage.id.uuidString)")

        if currentSession.isTemporary {
            currentSession.name = String(trimmedPrompt.prefix(20))
            currentSession.isTemporary = false
            currentSessionSubject.send(currentSession)
            var updatedSessions = chatSessionsSubject.value
            if let index = updatedSessions.firstIndex(where: { $0.id == currentSession.id }) {
                updatedSessions[index] = currentSession
            }
            chatSessionsSubject.send(updatedSessions)
            Persistence.saveChatSessions(updatedSessions)
            logger.info("生图请求已跳过自动标题生成: session=\(currentSession.id.uuidString)")
        } else {
            promoteSessionToTopIfNeeded(sessionID: currentSession.id)
        }

        emitSessionRequestStatus(.started, sessionID: currentSession.id)
        imageGenerationStatusSubject.send(
            .started(
                sessionID: currentSession.id,
                loadingMessageID: loadingMessage.id,
                prompt: trimmedPrompt,
                startedAt: Date(),
                referenceCount: imageAttachments.count
            )
        )
        logger.info("生图请求即将发送: session=\(currentSession.id.uuidString)")

        let requestToken = UUID()
        setRequestContext(
            RequestExecutionContext(
                token: requestToken,
                task: nil,
                loadingMessageID: loadingMessage.id,
                imageGenerationContext: ImageGenerationContext(
                    sessionID: currentSession.id,
                    loadingMessageID: loadingMessage.id,
                    prompt: trimmedPrompt
                )
            ),
            for: currentSession.id
        )

        let requestTask = Task<Void, Error> { [weak self] in
            guard let self else { return }
            var effectiveModel = runnableModel.model
            if !runtimeOverrideParameters.isEmpty {
                effectiveModel.overrideParameters = effectiveModel.overrideParameters.merging(runtimeOverrideParameters) { _, runtime in
                    runtime
                }
            }
            let effectiveRunnableModel = RunnableModel(provider: runnableModel.provider, model: effectiveModel)
            await self.executeImageGenerationRequest(
                adapter: adapter,
                runnableModel: effectiveRunnableModel,
                prompt: trimmedPrompt,
                referenceImages: imageAttachments,
                loadingMessageID: loadingMessage.id,
                currentSessionID: currentSession.id
            )
        }
        updateRequestTask(requestTask, for: currentSession.id, token: requestToken)

        defer {
            clearRequestContextIfNeeded(for: currentSession.id, token: requestToken)
        }

        do {
            try await requestTask.value
        } catch is CancellationError {
            logger.info("生图请求已被用户取消。")
        } catch {
            if isCancellationError(error) {
                logger.info("生图请求已被用户取消 (URLError)。")
            } else {
                logger.error("生图请求执行过程中出现未预期错误: \(error.localizedDescription)")
            }
        }
    }
    
    // MARK: - Agent & Tooling
    
    /// 定义 `save_memory` 工具
    internal var saveMemoryTool: InternalToolDefinition {
        let toolDescription = NSLocalizedString("""
        将信息写入长期记忆，仅在「这条信息在后续很多次对话中都可能有用」时调用。

        【必须满足至少一条才可调用】
        1. 用户的稳定偏好：口味、写作/编码风格、喜欢/不喜欢的输出格式、长期习惯（如默认语言、格式）。
        2. 用户的身份与长期背景：职业角色、长期项目或研究方向、长期合作对象。
        3. 用户明确要求记住：包含"记住…以后…都…"、"从现在开始你要记得…"等表达。

        【严禁调用的情况(除非用户明确要求你记住)】
        - 一次性任务或会话细节（某次会议数据、单个文件内容等）；
        - 短期信息（今天的临时待办、本次对话才用一次的参数）；
        - 敏感信息：精确地址、身份证号、银行卡、健康状况、政治立场等；
        - 第三方隐私信息（他人全名 + 个人细节）。
        """, comment: "System tool description for save_memory.")
        
        let contentDescription = ModelPromptLanguage.appendingToolArgumentInstruction(
            to: NSLocalizedString("需要记住的内容，要求：压缩成一句或几句话；进行抽象概括，不要原封不动复制对话；使之可在不同场景下复用。", comment: "System tool content description for save_memory.")
        )
        
        let parameters = JSONValue.dictionary([
            "type": .string("object"),
            "properties": .dictionary([
                "content": .dictionary([
                    "type": .string("string"),
                    "description": .string(contentDescription)
                ])
            ]),
            "required": .array([.string("content")])
        ])
        // 将此工具标记为非阻塞式
        return InternalToolDefinition(name: "save_memory", description: ModelPromptLanguage.appendingToolArgumentInstruction(to: toolDescription), parameters: parameters, isBlocking: false)
    }

    /// 定义 `search_memory` 工具
    internal var searchMemoryTool: InternalToolDefinition {
        let toolDescription = NSLocalizedString("""
        主动检索长期记忆，用于在回答前补充用户历史偏好、长期背景和已记录事实。

        用法：
        1. mode=vector：语义相似检索，适合自然语言问题。
        2. mode=keyword：关键词命中检索，适合名称、术语、短语定位。
        3. count：希望返回的条数；未传时使用系统默认检索数量（Top K）。

        返回结果包含完整原文 content。若结果为空，表示当前记忆库无匹配项。
        """, comment: "System tool description for search_memory.")

        let parameters = JSONValue.dictionary([
            "type": .string("object"),
            "properties": .dictionary([
                "mode": .dictionary([
                    "type": .string("string"),
                    "description": .string(NSLocalizedString("检索模式：vector 或 keyword。", comment: "Search memory mode description")),
                    "enum": .array([.string("vector"), .string("keyword")])
                ]),
                "query": .dictionary([
                    "type": .string("string"),
                    "description": .string(NSLocalizedString("检索查询文本，不能为空。", comment: "Search memory query description"))
                ]),
                "count": .dictionary([
                    "type": .string("integer"),
                    "description": .string(NSLocalizedString("返回条数；不填则使用系统默认 Top K。", comment: "Search memory count description"))
                ])
            ]),
            "required": .array([.string("mode"), .string("query")])
        ])

        return InternalToolDefinition(name: "search_memory", description: ModelPromptLanguage.appendingToolArgumentInstruction(to: toolDescription), parameters: parameters)
    }

    struct ToolCallOutcome {
        let message: ChatMessage
        let toolResult: String?
        let shouldAwaitUserSupplement: Bool
    }
}
