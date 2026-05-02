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
    
    /// 处理单个工具调用
    func handleToolCall(_ toolCall: InternalToolCall) async -> ToolCallOutcome {
        logger.info("正在处理工具调用: \(toolCall.toolName)")
        
        var content = ""
        var displayResult: String?
        var shouldAwaitUserSupplement = false
        
        switch toolCall.toolName {
        case "save_memory":
            // 解析参数
            struct SaveMemoryArgs: Decodable {
                let content: String
            }
            if let argsData = toolCall.arguments.data(using: .utf8), let args = try? JSONDecoder().decode(SaveMemoryArgs.self, from: argsData) {
                await self.memoryManager.addMemory(content: args.content)
                content = "成功将内容 \"\(args.content)\" 存入记忆。"
                displayResult = content
                logger.info("  - 记忆保存成功。")
            } else {
                content = "错误：无法解析 save_memory 的参数。"
                displayResult = content
                logger.error("  - 无法解析 save_memory 的参数: \(toolCall.arguments)")
            }

        case "search_memory":
            struct SearchMemoryArgs: Decodable {
                let mode: String
                let query: String
                let count: Int?
            }

            guard let argsData = toolCall.arguments.data(using: .utf8),
                  let args = try? JSONDecoder().decode(SearchMemoryArgs.self, from: argsData) else {
                content = NSLocalizedString("错误：无法解析 search_memory 的参数。请提供 mode、query，并可选 count。", comment: "Search memory args parse error")
                displayResult = content
                logger.error("  - 无法解析 search_memory 的参数: \(toolCall.arguments)")
                break
            }

            let mode = args.mode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let query = args.query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else {
                content = NSLocalizedString("错误：search_memory 的 query 不能为空。", comment: "Search memory empty query error")
                displayResult = content
                logger.error("  - search_memory query 为空。")
                break
            }

            let requestedCount = max(1, args.count ?? resolvedMemoryTopK())
            var resolvedMemories: [MemoryItem] = []
            switch mode {
            case "vector":
                resolvedMemories = await memoryManager.searchMemories(query: query, topK: requestedCount)
            case "keyword":
                resolvedMemories = await memoryManager.searchMemoriesByKeyword(query: query, topK: requestedCount)
            default:
                content = NSLocalizedString("错误：search_memory 的 mode 仅支持 vector 或 keyword。", comment: "Search memory unsupported mode error")
                displayResult = content
                logger.error("  - search_memory mode 不支持: \(mode)")
                break
            }

            if !content.isEmpty {
                break
            }

            content = serializeMemorySearchResult(
                mode: mode,
                query: query,
                requestedCount: requestedCount,
                memories: resolvedMemories
            )
            displayResult = content
            logger.info("  - search_memory 检索完成: mode=\(mode), queryLength=\(query.count), resultCount=\(resolvedMemories.count)")
            
        case _ where MCPManager.isMCPToolName(toolCall.toolName):
            let toolLabel = await MainActor.run {
                MCPManager.shared.displayLabel(for: toolCall.toolName)
            } ?? toolCall.toolName
            let approvalPolicy = await MainActor.run {
                MCPManager.shared.approvalPolicy(for: toolCall.toolName) ?? .askEveryTime
            }

            switch approvalPolicy {
            case .alwaysDeny:
                content = "\(toolLabel) 已被策略禁止调用。"
                displayResult = content
                logger.info("  - MCP 工具调用被策略拒绝: \(toolCall.toolName)")
            case .alwaysAllow:
                do {
                    let result = try await MCPManager.shared.executeToolFromChat(toolName: toolCall.toolName, argumentsJSON: toolCall.arguments)
                    content = result
                    displayResult = result
                    logger.info("  - MCP 工具调用成功: \(toolCall.toolName)")
                } catch {
                    content = "\(toolLabel) 调用失败：\(error.localizedDescription)"
                    displayResult = content
                    logger.error("  - MCP 工具调用失败: \(error.localizedDescription)")
                }
            case .askEveryTime:
                let permissionDecision = await ToolPermissionCenter.shared.requestPermission(
                    toolName: toolCall.toolName,
                    displayName: toolLabel,
                    arguments: toolCall.arguments
                )
                switch permissionDecision {
                case .deny:
                    content = "\(toolLabel) 调用已被用户拒绝。"
                    displayResult = content
                    logger.info("  - MCP 工具调用被用户拒绝: \(toolCall.toolName)")
                case .supplement:
                    content = "\(toolLabel) 调用已被用户拒绝。"
                    displayResult = content
                    shouldAwaitUserSupplement = true
                    logger.info("  - MCP 工具调用被用户拒绝并等待补充: \(toolCall.toolName)")
                case .allowOnce, .allowForTool, .allowAll:
                    do {
                        let result = try await MCPManager.shared.executeToolFromChat(toolName: toolCall.toolName, argumentsJSON: toolCall.arguments)
                        content = result
                        displayResult = result
                        logger.info("  - MCP 工具调用成功: \(toolCall.toolName)")
                    } catch {
                        content = "\(toolLabel) 调用失败：\(error.localizedDescription)"
                        displayResult = content
                        logger.error("  - MCP 工具调用失败: \(error.localizedDescription)")
                    }
                }
            }

        case _ where ShortcutToolManager.isShortcutToolName(toolCall.toolName):
            let toolLabel = await ShortcutToolManager.shared.displayLabel(for: toolCall.toolName) ?? toolCall.toolName
            let shortcutToolsEnabled = await MainActor.run { ShortcutToolManager.shared.chatToolsEnabled }
            guard shortcutToolsEnabled else {
                content = "快捷指令工具总开关已关闭。"
                displayResult = content
                logger.info("  - 快捷指令工具调用被总开关拒绝: \(toolCall.toolName)")
                break
            }
            let permissionDecision = await ToolPermissionCenter.shared.requestPermission(
                toolName: toolCall.toolName,
                displayName: toolLabel,
                arguments: toolCall.arguments
            )
            switch permissionDecision {
            case .deny:
                content = "\(toolLabel) 调用已被用户拒绝。"
                displayResult = content
                logger.info("  - 快捷指令工具调用被用户拒绝: \(toolCall.toolName)")
            case .supplement:
                content = "\(toolLabel) 调用已被用户拒绝。"
                displayResult = content
                shouldAwaitUserSupplement = true
                logger.info("  - 快捷指令工具调用被用户拒绝并等待补充: \(toolCall.toolName)")
            case .allowOnce, .allowForTool, .allowAll:
                do {
                    let result = try await ShortcutToolManager.shared.executeToolFromChat(
                        toolName: toolCall.toolName,
                        argumentsJSON: toolCall.arguments
                    )
                    content = result
                    displayResult = result
                    logger.info("  - 快捷指令工具调用成功: \(toolCall.toolName)")
                } catch {
                    content = "\(toolLabel) 调用失败：\(error.localizedDescription)"
                    displayResult = content
                    logger.error("  - 快捷指令工具调用失败: \(error.localizedDescription)")
                }
            }

        case _ where SkillManager.isSkillToolName(toolCall.toolName):
            let toolLabel = await MainActor.run {
                SkillManager.shared.displayLabel(for: toolCall.toolName)
            } ?? toolCall.toolName
            let skillsEnabled = await MainActor.run { SkillManager.shared.chatToolsEnabled }
            guard skillsEnabled else {
                content = "Agent Skills 总开关已关闭。"
                displayResult = content
                logger.info("  - Agent Skills 调用被总开关拒绝: \(toolCall.toolName)")
                break
            }

            do {
                let result = try await MainActor.run {
                    try SkillManager.shared.executeToolFromChat(
                        toolName: toolCall.toolName,
                        argumentsJSON: toolCall.arguments
                    )
                }
                content = result
                displayResult = result
                logger.info("  - Agent Skills 调用成功: \(toolCall.toolName)")
            } catch {
                content = "\(toolLabel) 调用失败：\(error.localizedDescription)"
                displayResult = content
                logger.error("  - Agent Skills 调用失败: \(error.localizedDescription)")
            }

        case _ where AppToolManager.isAppToolName(toolCall.toolName):
            let toolLabel = await MainActor.run {
                AppToolManager.shared.displayLabel(for: toolCall.toolName)
            } ?? toolCall.toolName
            let isBuiltInAppTool = AppToolManager.isBuiltInToolName(toolCall.toolName)
            let appToolsEnabled = await MainActor.run { AppToolManager.shared.chatToolsEnabled }
            guard appToolsEnabled || isBuiltInAppTool else {
                content = "拓展工具总开关已关闭。"
                displayResult = content
                logger.info("  - 拓展工具调用被总开关拒绝: \(toolCall.toolName)")
                break
            }
            let approvalPolicy = await MainActor.run {
                AppToolManager.shared.approvalPolicy(for: toolCall.toolName) ?? .askEveryTime
            }
            switch approvalPolicy {
            case .alwaysDeny:
                content = "\(toolLabel) 已被策略禁止调用。"
                displayResult = content
                logger.info("  - 拓展工具调用被策略拒绝: \(toolCall.toolName)")
            case .alwaysAllow:
                do {
                    let result = try await AppToolManager.shared.executeToolFromChat(
                        toolName: toolCall.toolName,
                        argumentsJSON: toolCall.arguments
                    )
                    content = result
                    displayResult = result
                    if toolCall.toolName == AppToolKind.askUserInput.toolName {
                        shouldAwaitUserSupplement = true
                    }
                    logger.info("  - 拓展工具调用成功: \(toolCall.toolName)")
                } catch {
                    content = "\(toolLabel) 调用失败：\(error.localizedDescription)"
                    displayResult = content
                    logger.error("  - 拓展工具调用失败: \(error.localizedDescription)")
                }
            case .askEveryTime:
                let permissionDecision = await ToolPermissionCenter.shared.requestPermission(
                    toolName: toolCall.toolName,
                    displayName: toolLabel,
                    arguments: toolCall.arguments
                )
                switch permissionDecision {
                case .deny:
                    content = "\(toolLabel) 调用已被用户拒绝。"
                    displayResult = content
                    logger.info("  - 拓展工具调用被用户拒绝: \(toolCall.toolName)")
                case .supplement:
                    content = "\(toolLabel) 调用已被用户拒绝。"
                    displayResult = content
                    shouldAwaitUserSupplement = true
                    logger.info("  - 拓展工具调用被用户拒绝并等待补充: \(toolCall.toolName)")
                case .allowOnce, .allowForTool, .allowAll:
                    do {
                        let result = try await AppToolManager.shared.executeToolFromChat(
                            toolName: toolCall.toolName,
                            argumentsJSON: toolCall.arguments
                        )
                        content = result
                        displayResult = result
                        if toolCall.toolName == AppToolKind.askUserInput.toolName {
                            shouldAwaitUserSupplement = true
                        }
                        logger.info("  - 拓展工具调用成功: \(toolCall.toolName)")
                    } catch {
                        content = "\(toolLabel) 调用失败：\(error.localizedDescription)"
                        displayResult = content
                        logger.error("  - 拓展工具调用失败: \(error.localizedDescription)")
                    }
                }
            }
            
        default:
            content = "错误：未知的工具名称 \(toolCall.toolName)。"
            displayResult = content
            logger.error("  - 未知的工具名称: \(toolCall.toolName)")
        }
        
        let message = ChatMessage(
            role: .tool,
            content: content,
            toolCalls: [
                InternalToolCall(
                    id: toolCall.id,
                    toolName: toolCall.toolName,
                    arguments: toolCall.arguments,
                    result: displayResult,
                    providerSpecificFields: toolCall.providerSpecificFields
                )
            ]
        )
        
        return ToolCallOutcome(message: message, toolResult: displayResult, shouldAwaitUserSupplement: shouldAwaitUserSupplement)
    }

    func serializeMemorySearchResult(
        mode: String,
        query: String,
        requestedCount: Int,
        memories: [MemoryItem]
    ) -> String {
        let formatter = ISO8601DateFormatter()
        let items: [[String: Any]] = memories.map { memory in
            [
                "id": memory.id.uuidString,
                "createdAt": formatter.string(from: memory.createdAt),
                "content": memory.content
            ]
        }
        let payload: [String: Any] = [
            "mode": mode,
            "query": query,
            "requestedCount": requestedCount,
            "returnedCount": memories.count,
            "items": items
        ]

        do {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
            return String(data: data, encoding: .utf8) ?? NSLocalizedString("错误：检索结果序列化失败。", comment: "Search memory serialize fallback")
        } catch {
            logger.error("search_memory 结果序列化失败：\(error.localizedDescription)")
            return NSLocalizedString("错误：检索结果序列化失败。", comment: "Search memory serialize error")
        }
    }

    @MainActor
    func attachToolResult(_ result: String, to toolCallID: String, toolName: String, loadingMessageID: UUID, sessionID: UUID) {
        var messages = messagesSnapshot(for: sessionID)
        guard let messageIndex = messages.firstIndex(where: { $0.id == loadingMessageID }) else { return }
        var message = messages[messageIndex]
        guard var toolCalls = message.toolCalls else { return }
        var callIndex = toolCalls.firstIndex(where: { $0.id == toolCallID })
        if callIndex == nil {
            let matchedByName = toolCalls.enumerated().filter { $0.element.toolName == toolName }
            if matchedByName.count == 1 {
                callIndex = matchedByName.first?.offset
                logger.warning("未找到匹配的工具调用 ID，已按名称 '\(toolName)' 回退匹配结果。")
            }
        }
        guard let resolvedIndex = callIndex else { return }
        toolCalls[resolvedIndex].result = result
        message.toolCalls = toolCalls
        messages[messageIndex] = message
        persistAndPublishMessages(messages, for: sessionID)
    }

    func ensureToolCallsVisible(_ toolCalls: [InternalToolCall], in loadingMessageID: UUID, sessionID: UUID) {
        guard !toolCalls.isEmpty else { return }
        var messages = messagesSnapshot(for: sessionID)
        guard let messageIndex = messages.firstIndex(where: { $0.id == loadingMessageID }) else { return }
        var message = messages[messageIndex]
        var existingCalls = message.toolCalls ?? []
        var didChange = false

        for call in toolCalls {
            if let existingIndex = existingCalls.firstIndex(where: { $0.id == call.id }) {
                let existingResult = existingCalls[existingIndex].result
                if existingCalls[existingIndex].toolName != call.toolName
                    || existingCalls[existingIndex].arguments != call.arguments
                    || existingCalls[existingIndex].providerSpecificFields != call.providerSpecificFields {
                    existingCalls[existingIndex] = InternalToolCall(
                        id: call.id,
                        toolName: call.toolName,
                        arguments: call.arguments,
                        result: existingResult,
                        providerSpecificFields: call.providerSpecificFields
                    )
                    didChange = true
                }
            } else {
                existingCalls.append(call)
                didChange = true
            }
        }

        guard didChange else { return }
        message.toolCalls = existingCalls
        messages[messageIndex] = message
        persistAndPublishMessages(messages, for: sessionID)
    }

    // MARK: - 核心请求执行逻辑 (已重构)
    
    func executeMessageRequest(
        messages: [ChatMessage],
        loadingMessageID: UUID,
        currentSessionID: UUID,
        userMessage: ChatMessage?,
        wasTemporarySession: Bool,
        aiTemperature: Double,
        aiTopP: Double,
        systemPrompt: String,
        maxChatHistory: Int,
        enableStreaming: Bool,
        enhancedPrompt: String?,
        tools: [InternalToolDefinition]?,
        enableMemory: Bool,
        enableMemoryWrite: Bool,
        enableMemoryActiveRetrieval: Bool,
        includeSystemTime: Bool,
        systemTimeInjectionPosition: SystemTimeInjectionPosition,
        enablePeriodicTimeLandmark: Bool,
        periodicTimeLandmarkIntervalMinutes: Int,
        enableResponseSpeedMetrics: Bool,
        currentAudioAttachment: AudioAttachment?, // 当前消息的音频附件（用于首次发送，尚未保存到文件）
        currentFileAttachments: [FileAttachment] // 当前消息的文件附件（用于首次发送，尚未保存到文件）
    ) async {
        let currentSessionSnapshot = currentSessionSubject.value
        let sessionForRequest = currentSessionSnapshot?.id == currentSessionID
            ? currentSessionSnapshot
            : chatSessionsSubject.value.first(where: { $0.id == currentSessionID })
        let requestMessages = preparedMessagesForRequest(
            from: messages,
            loadingMessageID: loadingMessageID,
            session: sessionForRequest
        )

        // 自动查：执行记忆搜索
        var memories: [MemoryItem] = []
        if enableMemory {
            let topK = resolvedMemoryTopK()
            if topK == 0 {
                // topK == 0 表示不进行向量检索，直接获取所有激活的记忆
                memories = await self.memoryManager.getActiveMemories()
            } else {
                let queryText = buildMemoryQueryContext(from: requestMessages, fallbackUserMessage: userMessage)
                if let queryText {
                    memories = await self.memoryManager.searchMemories(query: queryText, topK: topK)
                }
            }
            if !memories.isEmpty {
                logger.info("已检索到 \(memories.count) 条相关记忆。")
            }
        }

        let isWorldbookIsolationActive = sessionForRequest?.isWorldbookContextIsolationActive ?? false
        let conversationMemoryEnabled = isConversationMemoryEnabled() && !isWorldbookIsolationActive
        let recentConversationSummaries: [ConversationSessionSummary]
        let conversationUserProfile: ConversationUserProfile?
        if conversationMemoryEnabled {
            recentConversationSummaries = ConversationMemoryManager.loadRecentSessionSummaries(
                limit: resolvedConversationMemoryRecentLimit(),
                excludingSessionID: currentSessionID
            )
            conversationUserProfile = ConversationMemoryManager.loadUserProfile()
        } else {
            recentConversationSummaries = []
            conversationUserProfile = nil
        }
        
        guard let runnableModel = selectedModelSubject.value else {
            addErrorMessage(
                NSLocalizedString("错误: 没有选中的可用模型。请在设置中激活一个模型。", comment: "No active model error"),
                sessionID: currentSessionID
            )
            emitSessionRequestStatus(.error, sessionID: currentSessionID)
            return
        }
        
        guard let adapter = adapters[runnableModel.provider.apiFormat] else {
            addErrorMessage(String(
                format: NSLocalizedString("错误: 找不到适用于 '%@' 格式的 API 适配器。", comment: "Missing API adapter error"),
                runnableModel.provider.apiFormat
            ), sessionID: currentSessionID)
            emitSessionRequestStatus(.error, sessionID: currentSessionID)
            return
        }

        let requestStartedAt = Date()
        let requestLogContext = RequestLogContext(
            requestID: UUID(),
            sessionID: currentSessionID,
            providerID: runnableModel.provider.id,
            providerName: runnableModel.provider.name,
            modelID: runnableModel.model.modelName,
            requestSource: .chat,
            isStreaming: enableStreaming,
            requestedAt: requestStartedAt
        )

        if let configurationError = providerConfigurationValidationErrorMessage(
            for: runnableModel.provider,
            action: NSLocalizedString("发送聊天请求", comment: "Send chat request action")
        ) {
            addErrorMessage(configurationError, sessionID: currentSessionID)
            emitSessionRequestStatus(.error, sessionID: currentSessionID)
            persistRequestLog(
                context: requestLogContext,
                status: .failed,
                tokenUsage: nil,
                finishedAt: Date(),
                recordUsageEvent: false
            )
            return
        }

        let boundWorldbooks = worldbookStore.resolveWorldbooks(ids: sessionForRequest?.lorebookIDs ?? [])
        let worldbookResult = worldbookEngine.evaluate(
            .init(
                sessionID: currentSessionID,
                worldbooks: boundWorldbooks,
                messages: requestMessages,
                topicPrompt: sessionForRequest?.topicPrompt,
                enhancedPrompt: enhancedPrompt
            )
        )

        var messagesToSend: [ChatMessage] = []
        let finalSystemPrompt = buildFinalSystemPrompt(
            global: systemPrompt,
            topic: sessionForRequest?.topicPrompt,
            memories: memories,
            recentConversationSummaries: recentConversationSummaries,
            conversationProfile: conversationUserProfile,
            includeSystemTime: includeSystemTime && systemTimeInjectionPosition == .front,
            worldbookBefore: worldbookResult.before,
            worldbookAfter: worldbookResult.after,
            worldbookANTop: worldbookResult.anTop,
            worldbookANBottom: worldbookResult.anBottom,
            worldbookOutlet: worldbookResult.outlet
        )

        if !finalSystemPrompt.isEmpty {
            messagesToSend.append(ChatMessage(role: .system, content: finalSystemPrompt))
        }

        var chatHistory = requestMessages
        if maxChatHistory > 0 && chatHistory.count > maxChatHistory {
            chatHistory = Array(chatHistory.suffix(maxChatHistory))
        }

        if enablePeriodicTimeLandmark {
            chatHistory = injectPeriodicTimeLandmarkIfNeeded(
                into: chatHistory,
                sessionID: currentSessionID,
                now: Date(),
                intervalMinutes: periodicTimeLandmarkIntervalMinutes
            )
        } else {
            periodicTimeLandmarkLastInjectedAtBySessionID.removeValue(forKey: currentSessionID)
        }

        if !worldbookResult.atDepth.isEmpty {
            chatHistory = injectAtDepthMessages(worldbookResult.atDepth, into: chatHistory)
        }

        let emTopMessages = makeWorldbookRoleMessages(worldbookResult.emTop, tag: "worldbook_em_top")
        let emBottomMessages = makeWorldbookRoleMessages(worldbookResult.emBottom, tag: "worldbook_em_bottom")

        messagesToSend.append(contentsOf: emTopMessages)
        messagesToSend.append(contentsOf: chatHistory)
        messagesToSend.append(contentsOf: emBottomMessages)

        if let enhancedPromptMessage = makeEnhancedPromptSystemMessage(enhancedPrompt) {
            messagesToSend.append(enhancedPromptMessage)
        }

        if includeSystemTime && systemTimeInjectionPosition == .tail {
            messagesToSend.append(makeSystemTimeSystemMessage())
        }
        
        // 构建音频附件字典：从历史消息中加载已保存的音频文件
        var audioAttachments: [UUID: AudioAttachment] = [:]
        for msg in messagesToSend {
            // 如果是当前消息且有传入的音频附件，优先使用传入的（避免重复读取刚保存的文件）
            if let currentAudio = currentAudioAttachment, msg.id == userMessage?.id {
                audioAttachments[msg.id] = currentAudio
            } else if let audioFileName = msg.audioFileName,
                      let attachment = loadAudioAttachmentFromStorage(fileName: audioFileName) {
                audioAttachments[msg.id] = attachment
                logger.info("已加载历史音频: \(audioFileName) 用于消息 \(msg.id)")
            }
        }
        
        // 构建图片附件字典：从历史消息中加载已保存的图片文件
        var imageAttachments: [UUID: [ImageAttachment]] = [:]
        for msg in messagesToSend {
            guard let imageFileNames = msg.imageFileNames, !imageFileNames.isEmpty else { continue }
            var attachments: [ImageAttachment] = []
            for fileName in imageFileNames {
                if let attachment = loadImageAttachmentFromStorage(fileName: fileName) {
                    attachments.append(attachment)
                    logger.info("已加载历史图片: \(fileName) 用于消息 \(msg.id)")
                }
            }
            if !attachments.isEmpty {
                imageAttachments[msg.id] = attachments
            }
        }

        let imagePreprocessing = await preprocessImageAttachmentsIfNeeded(
            messages: messagesToSend,
            imageAttachments: imageAttachments,
            targetModel: runnableModel,
            sessionID: currentSessionID
        )
        if let errorMessage = imagePreprocessing.errorMessage {
            addErrorMessage(errorMessage, sessionID: currentSessionID)
            emitSessionRequestStatus(.error, sessionID: currentSessionID)
            persistRequestLog(
                context: requestLogContext,
                status: .failed,
                tokenUsage: nil,
                finishedAt: Date(),
                recordUsageEvent: false,
                errorKind: "ocr_model_missing"
            )
            return
        }
        messagesToSend = imagePreprocessing.messages
        imageAttachments = imagePreprocessing.imageAttachments

        // 构建文件附件字典：从历史消息中加载已保存的文件
        var fileAttachments: [UUID: [FileAttachment]] = [:]
        for msg in messagesToSend {
            if msg.id == userMessage?.id, !currentFileAttachments.isEmpty {
                fileAttachments[msg.id] = currentFileAttachments
                continue
            }
            guard let fileFileNames = msg.fileFileNames, !fileFileNames.isEmpty else { continue }
            var attachments: [FileAttachment] = []
            for fileName in fileFileNames {
                if let attachment = loadFileAttachmentFromStorage(fileName: fileName) {
                    attachments.append(attachment)
                    logger.info("已加载历史文件附件: \(fileName) 用于消息 \(msg.id)")
                }
            }
            if !attachments.isEmpty {
                fileAttachments[msg.id] = attachments
            }
        }

        let filePreprocessing = preprocessFileAttachmentsForText(
            messages: messagesToSend,
            fileAttachments: fileAttachments
        )
        if let errorMessage = filePreprocessing.errorMessage {
            addErrorMessage(errorMessage, sessionID: currentSessionID)
            emitSessionRequestStatus(.error, sessionID: currentSessionID)
            persistRequestLog(
                context: requestLogContext,
                status: .failed,
                tokenUsage: nil,
                finishedAt: Date(),
                recordUsageEvent: false,
                errorKind: "file_attachment_text_extraction_failed"
            )
            return
        }
        messagesToSend = filePreprocessing.messages
        fileAttachments = filePreprocessing.fileAttachments
        
        var commonPayload: [String: Any] = ["temperature": aiTemperature, "top_p": aiTopP, "stream": enableStreaming]
        if adapter is OpenAIAdapter {
            let includeUsageInStream = UserDefaults.standard.object(forKey: "enableOpenAIStreamIncludeUsage") as? Bool ?? true
            commonPayload[OpenAIAdapter.streamIncludeUsageControlKey] = includeUsageInStream
        }
        let effectiveTools = runnableModel.model.supportsToolCalling ? tools : nil
        if tools != nil, effectiveTools == nil {
            logger.info("当前模型未启用工具能力，本次请求不会附带工具定义。")
        }
        
        guard let request = adapter.buildChatRequest(for: runnableModel, commonPayload: commonPayload, messages: messagesToSend, tools: effectiveTools, audioAttachments: audioAttachments, imageAttachments: imageAttachments, fileAttachments: fileAttachments) else {
            let reason = providerConfigurationValidationErrorMessage(
                for: runnableModel.provider,
                action: NSLocalizedString("发送聊天请求", comment: "Send chat request action")
            ) ?? NSLocalizedString("错误: 无法构建 API 请求。", comment: "Failed to build API request error")
            addErrorMessage(reason, sessionID: currentSessionID)
            emitSessionRequestStatus(.error, sessionID: currentSessionID)
            persistRequestLog(
                context: requestLogContext,
                status: .failed,
                tokenUsage: nil,
                finishedAt: Date(),
                recordUsageEvent: false
            )
            return
        }

        if enableStreaming {
            await handleStreamedResponse(
                request: request,
                provider: runnableModel.provider,
                adapter: adapter,
                loadingMessageID: loadingMessageID,
                currentSessionID: currentSessionID,
                userMessage: userMessage,
                wasTemporarySession: wasTemporarySession,
                aiTemperature: aiTemperature,
                aiTopP: aiTopP,
                systemPrompt: systemPrompt,
                maxChatHistory: maxChatHistory,
                availableTools: effectiveTools,
                enableMemory: enableMemory,
                enableMemoryWrite: enableMemoryWrite,
                enableMemoryActiveRetrieval: enableMemoryActiveRetrieval,
                includeSystemTime: includeSystemTime,
                systemTimeInjectionPosition: systemTimeInjectionPosition,
                enablePeriodicTimeLandmark: enablePeriodicTimeLandmark,
                periodicTimeLandmarkIntervalMinutes: periodicTimeLandmarkIntervalMinutes,
                enableResponseSpeedMetrics: enableResponseSpeedMetrics,
                requestStartedAt: requestStartedAt,
                requestLogContext: requestLogContext
            )
        } else {
            await handleStandardResponse(
                request: request,
                provider: runnableModel.provider,
                adapter: adapter,
                loadingMessageID: loadingMessageID,
                currentSessionID: currentSessionID,
                userMessage: userMessage,
                wasTemporarySession: wasTemporarySession,
                availableTools: effectiveTools,
                aiTemperature: aiTemperature,
                aiTopP: aiTopP,
                systemPrompt: systemPrompt,
                maxChatHistory: maxChatHistory,
                enableMemory: enableMemory,
                enableMemoryWrite: enableMemoryWrite,
                enableMemoryActiveRetrieval: enableMemoryActiveRetrieval,
                includeSystemTime: includeSystemTime,
                systemTimeInjectionPosition: systemTimeInjectionPosition,
                enablePeriodicTimeLandmark: enablePeriodicTimeLandmark,
                periodicTimeLandmarkIntervalMinutes: periodicTimeLandmarkIntervalMinutes,
                enableResponseSpeedMetrics: enableResponseSpeedMetrics,
                requestStartedAt: requestStartedAt,
                requestLogContext: requestLogContext
            )
        }
    }

    func resolvedMimeType(for fileName: String) -> String {
        let ext = (fileName as NSString).pathExtension.lowercased()
        if ext.isEmpty {
            return "application/octet-stream"
        }
        #if canImport(UniformTypeIdentifiers)
        if let type = UTType(filenameExtension: ext), let mime = type.preferredMIMEType {
            return mime
        }
        #endif
        return "application/octet-stream"
    }
}
