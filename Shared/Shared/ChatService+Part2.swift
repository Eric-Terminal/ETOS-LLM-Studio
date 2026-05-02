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
    
    public func fetchModels(for provider: Provider) async throws -> [Model] {
        logger.info("正在为提供商 '\(provider.name)' 获取云端模型列表...")
        guard let adapter = adapters[provider.apiFormat] else {
            throw NetworkError.adapterNotFound(format: provider.apiFormat)
        }

        if let configurationError = providerConfigurationValidationErrorMessage(
            for: provider,
            action: NSLocalizedString("在线获取模型列表", comment: "Fetch model list action")
        ) {
            logger.warning("  - 提供商 '\(provider.name)' 配置异常: \(configurationError)")
            throw NetworkError.invalidProviderConfiguration(message: configurationError)
        }
        
        guard let request = adapter.buildModelListRequest(for: provider) else {
            logger.warning("  - 提供商 '\(provider.name)' (\(provider.apiFormat)) 当前适配器未实现在线模型列表。")
            throw NetworkError.modelListUnavailable(provider: provider.name, apiFormat: provider.apiFormat)
        }
        
        do {
            let data = try await fetchData(for: request, provider: provider)
            let fetchedModels = try adapter.parseModelListResponse(data: data)
            logger.info("  - 成功获取并解析了 \(fetchedModels.count) 个模型。")
            return fetchedModels
        } catch {
            logger.error("  - 获取或解析模型列表失败: \(error.localizedDescription)")
            throw error
        }
    }

    /// 将音频数据发送到选定的语音转文字模型，并返回识别结果。
    /// - Parameters:
    ///   - model: 需要调用的语音模型。
    ///   - audioData: 录制的音频数据。
    ///   - fileName: 上传使用的文件名。
    ///   - mimeType: 音频数据的类型，例如 `audio/m4a`。
    ///   - language: 可选的语言提示，留空则由模型自动判断。
    /// - Returns: 识别出的文本。
    public func transcribeAudio(
        using model: RunnableModel,
        audioData: Data,
        fileName: String,
        mimeType: String,
        language: String? = nil
    ) async throws -> String {
        if Self.isSystemSpeechRecognizerModel(model) {
            let extensionFromName = URL(fileURLWithPath: fileName).pathExtension
            let fallbackExtension = mimeType.lowercased().contains("wav") ? "wav" : "m4a"
            let transcript = try await SystemSpeechRecognizerService.transcribe(
                audioData: audioData,
                fileExtension: extensionFromName.isEmpty ? fallbackExtension : extensionFromName,
                localeIdentifier: language
            )
            logger.info("系统语音识别完成，长度 \(transcript.count) 字符。")
            return transcript
        }

        logger.info("正在向 \(model.provider.name) 的语音模型 \(model.model.displayName) 发起转写请求...")
        
        guard let adapter = adapters[model.provider.apiFormat] else {
            throw NetworkError.adapterNotFound(format: model.provider.apiFormat)
        }
        
        guard let request = adapter.buildTranscriptionRequest(
            for: model,
            audioData: audioData,
            fileName: fileName,
            mimeType: mimeType,
            language: language
        ) else {
            throw NetworkError.featureUnavailable(provider: model.provider.name)
        }
        
        do {
            let data = try await fetchData(for: request, provider: model.provider)
            let transcript = try adapter.parseTranscriptionResponse(data: data)
            logger.info("语音转文字完成，长度 \(transcript.count) 字符。")
            return transcript
        } catch {
            logger.error("语音转文字失败: \(error.localizedDescription)")
            throw error
        }
    }

    /// 取消指定会话正在进行的请求，并进行必要的状态恢复。
    public func cancelRequest(for sessionID: UUID) async {
        guard let context = withRequestStateLock({ requestContextBySessionID[sessionID] }),
              let task = context.task else { return }
        let token = context.token
        task.cancel()

        do {
            try await task.value
        } catch is CancellationError {
            logger.info("用户已手动取消会话请求: \(sessionID.uuidString)")
        } catch {
            // URLError.cancelled 不会匹配 CancellationError，需要单独检测
            if isCancellationError(error) {
                logger.info("用户已手动取消会话请求 (URLError): \(sessionID.uuidString)")
            } else {
                logger.error("取消会话请求时出现意外错误: \(error.localizedDescription)")
            }
        }

        guard let activeContext = withRequestStateLock({ requestContextBySessionID[sessionID] }),
              activeContext.token == token else {
            return
        }

        if let loadingID = activeContext.loadingMessageID {
            finalizeInterruptedReasoningMessageIfNeeded(loadingMessageID: loadingID, in: sessionID)
            if restoreRetryTargetMessageIfNeeded(loadingMessageID: loadingID, in: sessionID) {
                logger.info("已恢复被取消重试的原始 assistant 消息: \(loadingID.uuidString)")
            } else if shouldRemoveLoadingMessageOnCancel(loadingMessageID: loadingID, in: sessionID) {
                removeMessage(withID: loadingID, in: sessionID)
            }
            if retryTargetMessageID == loadingID {
                retryTargetMessageID = nil
                retryTargetOriginalAssistantMessage = nil
            }
        }

        let cancelledImageContext = activeContext.imageGenerationContext
        _ = withRequestStateLock {
            requestContextBySessionID.removeValue(forKey: sessionID)
        }
        setSessionRunning(sessionID, isRunning: false)
        emitSessionRequestStatus(.cancelled, sessionID: sessionID)

        if let imageContext = cancelledImageContext {
            imageGenerationStatusSubject.send(
                .cancelled(
                    sessionID: imageContext.sessionID,
                    loadingMessageID: imageContext.loadingMessageID,
                    prompt: imageContext.prompt,
                    finishedAt: Date()
                )
            )
        }
    }

    /// 兼容旧调用：取消当前会话请求。
    public func cancelOngoingRequest() async {
        if let currentSessionID = currentSessionSubject.value?.id {
            await cancelRequest(for: currentSessionID)
            return
        }
        let sessionIDs = withRequestStateLock { Array(requestContextBySessionID.keys) }
        for sessionID in sessionIDs {
            await cancelRequest(for: sessionID)
        }
    }
    
    public func saveAndReloadProviders(from providers: [Provider]) {
        logger.info("正在保存并重载提供商配置...")
        self.providers = providers
        for provider in self.providers {
            ConfigLoader.saveProvider(provider)
        }
        self.reloadProviders()
    }

    public func moveConfiguredModel(fromPosition source: Int, toPosition destination: Int) {
        let orderedModels = configuredRunnableModels
        let modelCount = orderedModels.count
        guard modelCount > 1 else { return }
        guard source >= 0 && source < modelCount else { return }
        guard destination >= 0 && destination < modelCount else { return }
        guard source != destination else { return }

        let reorderedIDs = ModelOrderIndex.move(
            ids: orderedModels.map(\.id),
            fromPosition: source,
            toPosition: destination
        )
        setConfiguredModelOrder(reorderedIDs)
    }

    public func moveConfiguredModels(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        var orderedModels = configuredRunnableModels
        let modelCount = orderedModels.count
        guard modelCount > 1 else { return }
        guard destination >= 0 && destination <= modelCount else { return }
        guard offsets.allSatisfy({ $0 >= 0 && $0 < modelCount }) else { return }
        guard !offsets.isEmpty else { return }

        moveElements(in: &orderedModels, fromOffsets: offsets, toOffset: destination)
        setConfiguredModelOrder(orderedModels.map(\.id))
    }

    // MARK: - 公开方法 (会话管理)
    
    public func createNewSession() {
        var updatedSessions = chatSessionsSubject.value

        // 约束：最多只保留一个临时会话，重复点击“新建对话”时复用现有临时会话。
        let temporarySessions = updatedSessions.filter(\.isTemporary)
        if let reusableTemporary = temporarySessions.first {
            var didMutateList = false

            // 若历史遗留了多个临时会话，清理多余项并删除其会话文件。
            if temporarySessions.count > 1 {
                let removableIDs = Set(temporarySessions.dropFirst().map(\.id))
                for sessionID in removableIDs {
                    Persistence.deleteSessionArtifacts(sessionID: sessionID)
                }
                updatedSessions.removeAll { removableIDs.contains($0.id) }
                didMutateList = true
                logger.info("检测到多个临时会话，已清理多余会话: \(removableIDs.count) 个。")
            }

            // 将唯一临时会话放到顶部，保证列表行为一致。
            if let index = updatedSessions.firstIndex(where: { $0.id == reusableTemporary.id }), index > 0 {
                let temporary = updatedSessions.remove(at: index)
                updatedSessions.insert(temporary, at: 0)
                didMutateList = true
            }

            if didMutateList {
                chatSessionsSubject.send(updatedSessions)
                Persistence.saveChatSessions(updatedSessions)
            }

            // 始终切换到复用的临时会话，并刷新其消息列表（通常为空）。
            if let target = updatedSessions.first(where: { $0.id == reusableTemporary.id }) {
                if currentSessionSubject.value?.id == target.id {
                    publishMessages(Persistence.loadMessages(for: target.id))
                } else {
                    setCurrentSession(target)
                }
                logger.info("复用了已有临时会话。")
                AppLog.userOperation(
                    category: "会话",
                    action: "复用临时会话",
                    payload: ["sessionID": target.id.uuidString]
                )
            }
            return
        }

        let newSession = ChatSession(id: UUID(), name: "新的对话", isTemporary: true)
        updatedSessions.insert(newSession, at: 0)
        chatSessionsSubject.send(updatedSessions)
        currentSessionSubject.send(newSession)
        publishMessages([])
        logger.info("创建了新的临时会话。")
        AppLog.userOperation(
            category: "会话",
            action: "创建新会话",
            payload: ["sessionID": newSession.id.uuidString]
        )
    }

    /// 创建一个带初始消息的正式会话，并切换到该会话。
    @discardableResult
    public func createSavedSession(
        name: String,
        initialMessages: [ChatMessage] = [],
        topicPrompt: String? = nil,
        enhancedPrompt: String? = nil,
        lorebookIDs: [UUID] = [],
        worldbookContextIsolationEnabled: Bool = false,
        folderID: UUID? = nil
    ) -> ChatSession {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let sessionName = trimmedName.isEmpty ? "新的对话" : trimmedName
        let newSession = ChatSession(
            id: UUID(),
            name: sessionName,
            topicPrompt: topicPrompt,
            enhancedPrompt: enhancedPrompt,
            lorebookIDs: lorebookIDs,
            worldbookContextIsolationEnabled: worldbookContextIsolationEnabled,
            folderID: folderID,
            isTemporary: false
        )

        var updatedSessions = chatSessionsSubject.value
        updatedSessions.insert(newSession, at: 0)
        chatSessionsSubject.send(updatedSessions)
        currentSessionSubject.send(newSession)
        publishMessages(initialMessages)
        persistMessages(initialMessages, for: newSession.id)
        Persistence.saveChatSessions(updatedSessions)
        logger.info("创建了正式会话并写入初始消息: \(newSession.name)")
        AppLog.userOperation(
            category: "会话",
            action: "创建正式会话",
            payload: [
                "sessionID": newSession.id.uuidString,
                "messageCount": "\(initialMessages.count)"
            ]
        )
        return newSession
    }
    
    public func deleteSessions(_ sessionsToDelete: [ChatSession]) {
        var currentSessions = chatSessionsSubject.value
        let existingPermanentSessionIDs = Set(currentSessions.filter { !$0.isTemporary }.map(\.id))
        let deletingSessionIDs = Set(sessionsToDelete.map(\.id))
        let isClearingAllConversationRecords = !existingPermanentSessionIDs.isEmpty
            && existingPermanentSessionIDs.isSubset(of: deletingSessionIDs)
        for session in sessionsToDelete {
            // 删除消息文件前先加载消息，清理关联的音频和图片文件
            let messages = Persistence.loadMessages(for: session.id)
            Persistence.deleteAudioFiles(for: messages)
            Persistence.deleteImageFiles(for: messages)
            Persistence.deleteFileFiles(for: messages)

            Persistence.deleteSessionArtifacts(sessionID: session.id)
            periodicTimeLandmarkLastInjectedAtBySessionID.removeValue(forKey: session.id)
            logger.info("删除了会话的数据文件: \(session.name)")
        }
        currentSessions.removeAll { session in sessionsToDelete.contains { $0.id == session.id } }
        var newCurrentSession = currentSessionSubject.value
        if let current = newCurrentSession, sessionsToDelete.contains(where: { $0.id == current.id }) {
            if let firstSession = currentSessions.first {
                newCurrentSession = firstSession
            } else {
                let newSession = ChatSession(id: UUID(), name: "新的对话", isTemporary: true)
                currentSessions.append(newSession)
                newCurrentSession = newSession
            }
        }
        chatSessionsSubject.send(currentSessions)
        if newCurrentSession?.id != currentSessionSubject.value?.id {
            setCurrentSession(newCurrentSession)
        }
        Persistence.saveChatSessions(currentSessions)
        logger.info("删除后已保存会话列表。")
        AppLog.userOperation(
            category: "会话",
            action: "删除会话",
            payload: ["count": "\(sessionsToDelete.count)"]
        )
        if isClearingAllConversationRecords {
            scheduleAchievementUnlockIfNeeded(.memoryPurge)
        }
    }
    
    @discardableResult
    public func branchSession(from sourceSession: ChatSession, copyMessages: Bool) -> ChatSession {
        let newSession = ChatSession(
            id: UUID(),
            name: "分支: \(sourceSession.name)",
            topicPrompt: sourceSession.topicPrompt,
            enhancedPrompt: sourceSession.enhancedPrompt,
            lorebookIDs: sourceSession.lorebookIDs,
            worldbookContextIsolationEnabled: sourceSession.worldbookContextIsolationEnabled,
            folderID: sourceSession.folderID,
            isTemporary: false
        )
        logger.info("创建了分支会话: \(newSession.name)")
        if copyMessages {
            var sourceMessages = Persistence.loadMessages(for: sourceSession.id)
            if !sourceMessages.isEmpty {
                // 复制关联的音频文件，并更新消息中的音频文件名引用
                for i in sourceMessages.indices {
                    if let originalFileName = sourceMessages[i].audioFileName,
                       let audioData = Persistence.loadAudio(fileName: originalFileName) {
                        let ext = (originalFileName as NSString).pathExtension
                        let newFileName = "\(UUID().uuidString).\(ext)"
                        if Persistence.saveAudio(audioData, fileName: newFileName) != nil {
                            sourceMessages[i].audioFileName = newFileName
                            logger.info("  - 复制了音频文件: \(originalFileName) -> \(newFileName)")
                        }
                    }
                    if let originalFileNames = sourceMessages[i].fileFileNames, !originalFileNames.isEmpty {
                        var newFileNames: [String] = []
                        for originalFileName in originalFileNames {
                            if let fileData = Persistence.loadFile(fileName: originalFileName) {
                                let ext = (originalFileName as NSString).pathExtension
                                let newFileName = ext.isEmpty ? "\(UUID().uuidString)" : "\(UUID().uuidString).\(ext)"
                                if Persistence.saveFile(fileData, fileName: newFileName) != nil {
                                    newFileNames.append(newFileName)
                                    logger.info("  - 复制了文件附件: \(originalFileName) -> \(newFileName)")
                                }
                            }
                        }
                        if !newFileNames.isEmpty {
                            sourceMessages[i].fileFileNames = newFileNames
                        }
                    }
                }
                persistMessages(sourceMessages, for: newSession.id)
                logger.info("  - 复制了 \(sourceMessages.count) 条消息到新会话。")
            }
        }
        var updatedSessions = chatSessionsSubject.value
        updatedSessions.insert(newSession, at: 0)
        chatSessionsSubject.send(updatedSessions)
        setCurrentSession(newSession)
        Persistence.saveChatSessions(updatedSessions)
        logger.info("保存了会话列表。")
        return newSession
    }
    
    /// 从指定消息处创建分支会话
    /// - Parameters:
    ///   - sourceSession: 源会话
    ///   - upToMessage: 包含此消息及之前的所有消息
    ///   - copyPrompts: 是否复制话题提示词和增强提示词
    /// - Returns: 新创建的分支会话
    @discardableResult
    public func branchSessionFromMessage(from sourceSession: ChatSession, upToMessage: ChatMessage, copyPrompts: Bool) -> ChatSession {
        let newSession = ChatSession(
            id: UUID(),
            name: "分支: \(sourceSession.name)",
            topicPrompt: copyPrompts ? sourceSession.topicPrompt : nil,
            enhancedPrompt: copyPrompts ? sourceSession.enhancedPrompt : nil,
            lorebookIDs: sourceSession.lorebookIDs,
            worldbookContextIsolationEnabled: sourceSession.worldbookContextIsolationEnabled,
            folderID: sourceSession.folderID,
            isTemporary: false
        )
        logger.info("从消息处创建分支会话: \(newSession.name)\(copyPrompts ? "（包含提示词）": "（不含提示词）")")
        
        let sourceMessages = ChatResponseAttemptSupport.visibleMessages(from: Persistence.loadMessages(for: sourceSession.id))
        if let messageIndex = sourceMessages.firstIndex(where: { $0.id == upToMessage.id }) {
            // 只保留到指定消息的消息（包含该消息）
            var messagesToCopy = Array(sourceMessages[0...messageIndex])
            
            // 复制关联的音频和图片文件
            for i in messagesToCopy.indices {
                // 复制音频文件
                if let originalFileName = messagesToCopy[i].audioFileName,
                   let audioData = Persistence.loadAudio(fileName: originalFileName) {
                    let ext = (originalFileName as NSString).pathExtension
                    let newFileName = "\(UUID().uuidString).\(ext)"
                    if Persistence.saveAudio(audioData, fileName: newFileName) != nil {
                        messagesToCopy[i].audioFileName = newFileName
                        logger.info("  - 复制了音频文件: \(originalFileName) -> \(newFileName)")
                    }
                }
                
                // 复制图片文件
                if let originalImageFileNames = messagesToCopy[i].imageFileNames, !originalImageFileNames.isEmpty {
                    var newImageFileNames: [String] = []
                    for originalImageFileName in originalImageFileNames {
                        if let imageData = Persistence.loadImage(fileName: originalImageFileName) {
                            let ext = (originalImageFileName as NSString).pathExtension
                            let newImageFileName = "\(UUID().uuidString).\(ext)"
                            if Persistence.saveImage(imageData, fileName: newImageFileName) != nil {
                                newImageFileNames.append(newImageFileName)
                                logger.info("  - 复制了图片文件: \(originalImageFileName) -> \(newImageFileName)")
                            }
                        }
                    }
                    if !newImageFileNames.isEmpty {
                        messagesToCopy[i].imageFileNames = newImageFileNames
                    }
                }

                // 复制文件附件
                if let originalFileNames = messagesToCopy[i].fileFileNames, !originalFileNames.isEmpty {
                    var newFileNames: [String] = []
                    for originalFileName in originalFileNames {
                        if let fileData = Persistence.loadFile(fileName: originalFileName) {
                            let ext = (originalFileName as NSString).pathExtension
                            let newFileName = ext.isEmpty ? "\(UUID().uuidString)" : "\(UUID().uuidString).\(ext)"
                            if Persistence.saveFile(fileData, fileName: newFileName) != nil {
                                newFileNames.append(newFileName)
                                logger.info("  - 复制了文件附件: \(originalFileName) -> \(newFileName)")
                            }
                        }
                    }
                    if !newFileNames.isEmpty {
                        messagesToCopy[i].fileFileNames = newFileNames
                    }
                }
            }
            
            persistMessages(messagesToCopy, for: newSession.id)
            logger.info("  - 复制了 \(messagesToCopy.count) 条消息到新会话（截止到指定消息）。")
        } else {
            logger.warning("  - 未找到指定的消息，创建空分支会话。")
        }
        
        var updatedSessions = chatSessionsSubject.value
        updatedSessions.insert(newSession, at: 0)
        chatSessionsSubject.send(updatedSessions)
        setCurrentSession(newSession)
        Persistence.saveChatSessions(updatedSessions)
        logger.info("保存了会话列表。")
        return newSession
    }
    
    public func deleteLastMessage(for session: ChatSession) {
        var messages = Persistence.loadMessages(for: session.id)
        if !messages.isEmpty {
            let lastMessage = messages.removeLast()
            invalidateAttachmentCache(for: lastMessage)
            // 清理被删除消息关联的音频文件
            if let audioFileName = lastMessage.audioFileName {
                Persistence.deleteAudio(fileName: audioFileName)
            }
            // 清理被删除消息关联的图片文件
            if let imageFileNames = lastMessage.imageFileNames {
                for fileName in imageFileNames {
                    Persistence.deleteImage(fileName: fileName)
                }
            }
            // 清理被删除消息关联的文件附件
            if let fileFileNames = lastMessage.fileFileNames {
                for fileName in fileFileNames {
                    Persistence.deleteFile(fileName: fileName)
                }
            }
            persistMessages(messages, for: session.id)
            logger.info("删除了会话的最后一条消息: \(session.name)")
            if session.id == currentSessionSubject.value?.id {
                publishMessages(messages)
            }
        }
    }
    
    public func deleteMessage(_ message: ChatMessage) {
        guard let currentSession = currentSessionSubject.value else { return }
        var messages = messagesForSessionSubject.value
        guard let messageIndex = messages.firstIndex(where: { $0.id == message.id }) else { return }
        let targetMessage = messages[messageIndex]
        let relatedToolMessageIDs = relatedToolResultMessageIDs(for: targetMessage, at: messageIndex, in: messages)
        let deletedMessageIDs = Set([targetMessage.id]).union(relatedToolMessageIDs)
        let deletedMessages = messages.filter { deletedMessageIDs.contains($0.id) }
        for deletedMessage in deletedMessages {
            deleteStoredAttachments(for: deletedMessage)
        }
        messages.removeAll { deletedMessageIDs.contains($0.id) }
        repairSelectedResponseAttempts(in: &messages, affectedBy: deletedMessages)

        publishMessages(messages)
        persistMessages(messages, for: currentSession.id)
        logger.info("已删除消息: \(targetMessage.id.uuidString)")
    }

    public func deleteAllVersions(of message: ChatMessage) {
        guard let currentSession = currentSessionSubject.value else { return }
        var messages = messagesForSessionSubject.value
        guard let messageIndex = messages.firstIndex(where: { $0.id == message.id }) else { return }
        let targetMessage = messages[messageIndex]

        if let groupID = targetMessage.responseGroupID,
           targetMessage.responseAttemptID != nil,
           ChatResponseAttemptSupport.orderedAttemptIDs(for: groupID, in: messages).count > 1 {
            let deletedMessages = messages.filter { $0.responseGroupID == groupID }
            guard !deletedMessages.isEmpty else { return }
            for deletedMessage in deletedMessages {
                deleteStoredAttachments(for: deletedMessage)
            }
            messages.removeAll { $0.responseGroupID == groupID }
            if let anchorIndex = messages.firstIndex(where: { $0.id == groupID && $0.role == .user }) {
                messages[anchorIndex].selectedResponseAttemptID = nil
            }

            publishMessages(messages)
            persistMessages(messages, for: currentSession.id)
            logger.info("已删除回复组的所有版本: \(groupID.uuidString)")
            return
        }

        deleteMessage(targetMessage)
    }

    func relatedToolResultMessageIDs(for message: ChatMessage, at messageIndex: Int, in messages: [ChatMessage]) -> Set<UUID> {
        guard message.role == .assistant,
              let toolCalls = message.toolCalls,
              !toolCalls.isEmpty else {
            return []
        }

        let toolCallIDs = Set(toolCalls.map(\.id))
        var relatedIDs = Set<UUID>()
        var cursor = messages.index(after: messageIndex)
        while cursor < messages.endIndex {
            let candidate = messages[cursor]
            guard candidate.role == .tool else { break }
            if isSameResponseAttempt(candidate, message),
               let candidateToolCalls = candidate.toolCalls,
               candidateToolCalls.contains(where: { toolCallIDs.contains($0.id) }) {
                relatedIDs.insert(candidate.id)
            }
            cursor = messages.index(after: cursor)
        }
        return relatedIDs
    }

    func isSameResponseAttempt(_ lhs: ChatMessage, _ rhs: ChatMessage) -> Bool {
        switch (lhs.responseAttemptID, rhs.responseAttemptID) {
        case let (lhsAttemptID?, rhsAttemptID?):
            return lhsAttemptID == rhsAttemptID
        case (nil, nil):
            return true
        default:
            return false
        }
    }

    func deleteStoredAttachments(for message: ChatMessage) {
        invalidateAttachmentCache(for: message)
        if let audioFileName = message.audioFileName {
            Persistence.deleteAudio(fileName: audioFileName)
        }
        if let imageFileNames = message.imageFileNames {
            for fileName in imageFileNames {
                Persistence.deleteImage(fileName: fileName)
            }
        }
        if let fileFileNames = message.fileFileNames {
            for fileName in fileFileNames {
                Persistence.deleteFile(fileName: fileName)
            }
        }
    }

    func repairSelectedResponseAttempts(in messages: inout [ChatMessage], affectedBy deletedMessages: [ChatMessage]) {
        let affectedGroupIDs = Set(deletedMessages.compactMap(\.responseGroupID))
        guard !affectedGroupIDs.isEmpty else { return }

        for groupID in affectedGroupIDs {
            guard let anchorIndex = messages.firstIndex(where: { $0.id == groupID && $0.role == .user }),
                  let selectedAttemptID = messages[anchorIndex].selectedResponseAttemptID else {
                continue
            }
            guard !responseAttemptHasDisplaySegment(groupID: groupID, attemptID: selectedAttemptID, in: messages) else {
                continue
            }

            let replacementAttemptID = ChatResponseAttemptSupport
                .orderedAttemptIDs(for: groupID, in: messages)
                .reversed()
                .first { responseAttemptHasDisplaySegment(groupID: groupID, attemptID: $0, in: messages) }
            messages[anchorIndex].selectedResponseAttemptID = replacementAttemptID
        }
    }

    func responseAttemptHasDisplaySegment(groupID: UUID, attemptID: UUID, in messages: [ChatMessage]) -> Bool {
        messages.contains {
            $0.responseGroupID == groupID
                && $0.responseAttemptID == attemptID
                && ($0.role == .assistant || $0.role == .error)
        }
    }
    
    public func updateMessageContent(_ message: ChatMessage, with newContent: String) {
        guard let currentSession = currentSessionSubject.value else { return }
        var messages = messagesForSessionSubject.value
        guard let index = messages.firstIndex(where: { $0.id == message.id }) else { return }
        messages[index].content = newContent
        publishMessages(messages)
        persistMessages(messages, for: currentSession.id)
        logger.info("已更新消息内容: \(message.id.uuidString)")
    }

    /// 更新单条消息（包括内容和思考过程）
    public func updateMessage(_ updatedMessage: ChatMessage) {
        guard let currentSession = currentSessionSubject.value else { return }
        var messages = messagesForSessionSubject.value
        guard let index = messages.firstIndex(where: { $0.id == updatedMessage.id }) else { return }
        messages[index] = updatedMessage
        publishMessages(messages)
        persistMessages(messages, for: currentSession.id)
        logger.info("已更新消息: \(updatedMessage.id.uuidString)")
    }
    
    /// 更新整个消息列表（用于版本管理等批量操作）
    public func updateMessages(_ messages: [ChatMessage], for sessionID: UUID) {
        publishMessages(messages)
        persistMessages(messages, for: sessionID)
        logger.info("已更新会话消息列表: \(sessionID.uuidString)")
    }
    
    public func updateSession(_ session: ChatSession) {
        guard !session.isTemporary else { return }
        var currentSessions = chatSessionsSubject.value
        if let index = currentSessions.firstIndex(where: { $0.id == session.id }) {
            currentSessions[index] = session
            chatSessionsSubject.send(currentSessions)
            
            // 关键修复：如果被修改的是当前会话，则必须同步更新 currentSessionSubject
            if currentSessionSubject.value?.id == session.id {
                currentSessionSubject.send(session)
                logger.info("  - 同步更新了当前活动会话的状态。")
            }
            
            Persistence.saveChatSessions(currentSessions)
            logger.info("更新了会话详情: \(session.name)")
        }
    }
    
    public func forceSaveSessions() {
        let sessions = chatSessionsSubject.value
        Persistence.saveChatSessions(sessions)
        logger.info("已强制保存所有会话。")
    }

    // MARK: - 会话文件夹管理

    public func createSessionFolder(name: String, parentID: UUID? = nil) -> SessionFolder? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return nil }

        var folders = sessionFoldersSubject.value
        if let parentID, !folders.contains(where: { $0.id == parentID }) {
            return nil
        }

        let folder = SessionFolder(name: trimmedName, parentID: parentID, updatedAt: Date())
        folders.append(folder)
        sessionFoldersSubject.send(folders)
        Persistence.saveSessionFolders(folders)
        logger.info("已创建会话文件夹: \(trimmedName)")
        return folder
    }

    public func renameSessionFolder(folderID: UUID, newName: String) {
        let trimmedName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        var folders = sessionFoldersSubject.value
        guard let index = folders.firstIndex(where: { $0.id == folderID }) else { return }
        guard folders[index].name != trimmedName else { return }
        folders[index].name = trimmedName
        folders[index].updatedAt = Date()
        sessionFoldersSubject.send(folders)
        Persistence.saveSessionFolders(folders)
        logger.info("已重命名会话文件夹: \(trimmedName)")
    }
}
