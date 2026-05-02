// ============================================================================
// ChatService+RetryAndRequestPreparation.swift
// ============================================================================
// ChatService 的当前会话切换、错误消息格式化、重试上下文与请求消息准备。
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

    public func deleteSessionFolder(folderID: UUID) {
        let folders = sessionFoldersSubject.value
        guard folders.contains(where: { $0.id == folderID }) else { return }

        let removedIDs = collectSessionFolderDescendantIDs(rootID: folderID, folders: folders)
        let retainedFolders = folders.filter { !removedIDs.contains($0.id) }
        sessionFoldersSubject.send(retainedFolders)
        Persistence.saveSessionFolders(retainedFolders)

        var sessions = chatSessionsSubject.value
        var didUpdateSessions = false
        for index in sessions.indices {
            guard let assignedFolderID = sessions[index].folderID else { continue }
            guard removedIDs.contains(assignedFolderID) else { continue }
            sessions[index].folderID = nil
            didUpdateSessions = true
        }

        if didUpdateSessions {
            chatSessionsSubject.send(sessions)
            if let current = currentSessionSubject.value,
               let updatedCurrent = sessions.first(where: { $0.id == current.id }),
               updatedCurrent != current {
                currentSessionSubject.send(updatedCurrent)
            }
            Persistence.saveChatSessions(sessions)
        }

        logger.info("已删除会话文件夹及子目录，共 \(removedIDs.count) 个。")
    }

    public func moveSessionFolder(folderID: UUID, toParentID parentID: UUID?) {
        var folders = sessionFoldersSubject.value
        guard let folderIndex = folders.firstIndex(where: { $0.id == folderID }) else { return }
        guard folders[folderIndex].parentID != parentID else { return }

        if let parentID {
            guard folders.contains(where: { $0.id == parentID }) else { return }
            let descendantIDs = collectSessionFolderDescendantIDs(rootID: folderID, folders: folders)
            guard !descendantIDs.contains(parentID) else { return }
        }

        folders[folderIndex].parentID = parentID
        folders[folderIndex].updatedAt = Date()
        sessionFoldersSubject.send(folders)
        Persistence.saveSessionFolders(folders)
        logger.info("已移动会话文件夹。")
    }

    public func moveSessionFolder(_ folder: SessionFolder, toParentID parentID: UUID?) {
        moveSessionFolder(folderID: folder.id, toParentID: parentID)
    }

    public func moveSession(sessionID: UUID, toFolderID folderID: UUID?) {
        var sessions = chatSessionsSubject.value
        guard let sessionIndex = sessions.firstIndex(where: { $0.id == sessionID }) else { return }

        if let folderID,
           !sessionFoldersSubject.value.contains(where: { $0.id == folderID }) {
            return
        }
        guard sessions[sessionIndex].folderID != folderID else { return }
        sessions[sessionIndex].folderID = folderID
        chatSessionsSubject.send(sessions)

        if let current = currentSessionSubject.value, current.id == sessionID {
            currentSessionSubject.send(sessions[sessionIndex])
        }

        Persistence.saveChatSessions(sessions)
        logger.info("已移动会话到文件夹。")
    }

    public func moveSession(_ session: ChatSession, toFolderID folderID: UUID?) {
        moveSession(sessionID: session.id, toFolderID: folderID)
    }

    /// 从持久化层重新加载当前会话消息并刷新 UI，不会触发写盘。
    public func reloadCurrentSessionMessagesFromPersistence() {
        guard let currentSession = currentSessionSubject.value else { return }
        let reloadedMessages = Persistence.loadMessages(for: currentSession.id)
        publishMessages(reloadedMessages)
        logger.info("已从持久化层刷新当前会话消息: \(currentSession.id.uuidString)")
    }

    /// 在 JSON→SQLite 迁移完成后，从持久化层重新同步会话/文件夹/当前消息状态。
    public func reloadSessionStateFromPersistenceAfterMigration() {
        let persistedSessions = Persistence.loadChatSessions()
        let persistedFolders = Persistence.loadSessionFolders()
        let existingTemporary = chatSessionsSubject.value.first(where: \.isTemporary)
            ?? ChatSession(id: UUID(), name: "新的对话", isTemporary: true)

        var mergedSessions = persistedSessions
        mergedSessions.insert(existingTemporary, at: 0)

        let previousCurrentSessionID = currentSessionSubject.value?.id
        let resolvedCurrentSession = mergedSessions.first(where: { $0.id == previousCurrentSessionID })
            ?? persistedSessions.first
            ?? existingTemporary

        chatSessionsSubject.send(mergedSessions)
        sessionFoldersSubject.send(persistedFolders)
        currentSessionSubject.send(resolvedCurrentSession)

        let resolvedMessages = resolvedCurrentSession.isTemporary
            ? []
            : Persistence.loadMessages(for: resolvedCurrentSession.id)
        publishMessages(resolvedMessages)

        logger.info("JSON→SQLite 迁移后已刷新会话状态: sessions=\(persistedSessions.count), folders=\(persistedFolders.count)")
    }
    
    public func setCurrentSession(_ session: ChatSession?) {
        let currentSession = currentSessionSubject.value
        if currentSession == session { return }

        if let session, session.id == currentSession?.id {
            currentSessionSubject.send(session)

            var sessions = chatSessionsSubject.value
            if let index = sessions.firstIndex(where: { $0.id == session.id }) {
                sessions[index] = session
                chatSessionsSubject.send(sessions)
                Persistence.saveChatSessions(sessions)
            }

            logger.info("已更新当前会话元数据: \(session.name)")
            AppLog.userOperation(
                category: "会话",
                action: "更新当前会话",
                payload: ["sessionID": session.id.uuidString]
            )
            return
        }

        currentSessionSubject.send(session)
        let messages = session != nil ? Persistence.loadMessages(for: session!.id) : []
        publishMessages(messages)
        logger.info("已切换到会话: \(session?.name ?? "无")")
        AppLog.userOperation(
            category: "会话",
            action: "切换会话",
            payload: ["sessionID": session?.id.uuidString ?? "无"]
        )
    }

    /// 当老会话重新变为活跃状态时，将其移动到列表顶部以保持最近使用的排序
    func promoteSessionToTopIfNeeded(sessionID: UUID) {
        var sessions = chatSessionsSubject.value
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }), index > 0 else { return }
        let session = sessions.remove(at: index)
        sessions.insert(session, at: 0)
        chatSessionsSubject.send(sessions)
        Persistence.saveChatSessions(sessions)
        logger.info("已将会话移动到列表顶部: \(session.name)")
    }

    func collectSessionFolderDescendantIDs(rootID: UUID, folders: [SessionFolder]) -> Set<UUID> {
        let childrenByParent = Dictionary(grouping: folders, by: \.parentID)
        var collected: Set<UUID> = [rootID]
        var queue: [UUID] = [rootID]

        while let current = queue.first {
            queue.removeFirst()
            let children = childrenByParent[current] ?? []
            for child in children where collected.insert(child.id).inserted {
                queue.append(child.id)
            }
        }

        return collected
    }
    
    // MARK: - 公开方法 (消息处理)
    
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
        
        // 格式化错误内容，使其更简洁易读
        let (formattedContent, fullContent) = formatErrorContent(content, httpStatusCode: httpStatusCode)
        
        let loadingIndex: Int? = {
            // 优先使用当前请求记录的 loading 消息，避免误命中历史中的空 assistant（例如工具调用占位消息）。
            if let loadingMessageID = withRequestStateLock({ requestContextBySessionID[resolvedSessionID]?.loadingMessageID }),
               let index = messages.firstIndex(where: { $0.id == loadingMessageID && $0.role == .assistant }) {
                return index
            }

            // 兼容重试场景：当 retryTargetMessageID 仍存在时，优先定位该消息。
            if let targetID = retryTargetMessageID,
               let index = messages.firstIndex(where: { $0.id == targetID && $0.role == .assistant }) {
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

            // 检查是否在重试 assistant 场景（有保留的旧 assistant）
            if let targetID = retryTargetMessageID,
               loadingMessage.id == targetID {
                if shouldPreserveLoadingMessage {
                    messages.insert(
                        makeErrorMessage(
                            loadingMessage.requestedAt,
                            NSLocalizedString("重试失败", comment: "Retry failed error message prefix"),
                            metadata: loadingAttemptMetadata
                        ),
                        at: loadingIndex + 1
                    )
                } else if let originalAssistant = retryTargetOriginalAssistantMessage {
                    messages[loadingIndex] = originalAssistant
                    messages.insert(
                        makeErrorMessage(
                            loadingMessage.requestedAt,
                            NSLocalizedString("重试失败", comment: "Retry failed error message prefix"),
                            metadata: loadingAttemptMetadata
                        ),
                        at: loadingIndex + 1
                    )
                } else if shouldPreserveLoadingMessage {
                    messages.insert(
                        makeErrorMessage(
                            loadingMessage.requestedAt,
                            NSLocalizedString("重试失败", comment: "Retry failed error message prefix"),
                            metadata: loadingAttemptMetadata
                        ),
                        at: loadingIndex + 1
                    )
                } else {
                    messages[loadingIndex] = ChatMessage(
                        id: loadingMessage.id,
                        role: .error,
                        content: "重试失败\n\n\(formattedContent)",
                        requestedAt: loadingMessage.requestedAt,
                        fullErrorContent: fullContent.map { "重试失败\n\n\($0)" },
                        responseGroupID: loadingMessage.responseGroupID,
                        responseAttemptID: loadingMessage.responseAttemptID,
                        responseAttemptIndex: loadingMessage.responseAttemptIndex
                    )
                }
                
                retryTargetMessageID = nil
                retryTargetOriginalAssistantMessage = nil
                logger.error("重试失败，已根据输出情况保留或恢复 assistant，并追加错误气泡: \(content)")
            } else if shouldPreserveLoadingMessage {
                messages.insert(makeErrorMessage(loadingMessage.requestedAt, metadata: loadingAttemptMetadata), at: loadingIndex + 1)
                logger.error("流式内容已保留，并追加错误消息: \(content)")
            } else {
                // 正常场景：将 loading message 转为 error
                messages[loadingIndex] = ChatMessage(
                    id: loadingMessage.id,
                    role: .error,
                    content: formattedContent,
                    requestedAt: loadingMessage.requestedAt,
                    fullErrorContent: fullContent,
                    responseGroupID: loadingMessage.responseGroupID,
                    responseAttemptID: loadingMessage.responseAttemptID,
                    responseAttemptIndex: loadingMessage.responseAttemptIndex
                )
                logger.error("错误消息已添加: \(content)")
            }
        } else {
            // 没有 loading message，直接添加错误
            messages.append(makeErrorMessage(nil))
            logger.error("错误消息已添加: \(content)")
        }
        
        persistAndPublishMessages(messages, for: resolvedSessionID)
    }
    
    /// 获取 HTTP 状态码的描述信息
    func httpStatusCodeDescription(_ code: Int) -> String {
        switch code {
        // 4xx 客户端错误
        case 400: return NSLocalizedString("请求格式错误 (Bad Request)", comment: "HTTP 400 description")
        case 401: return NSLocalizedString("未授权，请检查 API Key (Unauthorized)", comment: "HTTP 401 description")
        case 403: return NSLocalizedString("访问被拒绝，权限不足 (Forbidden)", comment: "HTTP 403 description")
        case 404: return NSLocalizedString("请求的资源不存在 (Not Found)", comment: "HTTP 404 description")
        case 405: return NSLocalizedString("请求方法不被允许 (Method Not Allowed)", comment: "HTTP 405 description")
        case 408: return NSLocalizedString("请求超时 (Request Timeout)", comment: "HTTP 408 description")
        case 409: return NSLocalizedString("请求冲突 (Conflict)", comment: "HTTP 409 description")
        case 413: return NSLocalizedString("请求体过大 (Payload Too Large)", comment: "HTTP 413 description")
        case 415: return NSLocalizedString("不支持的媒体类型 (Unsupported Media Type)", comment: "HTTP 415 description")
        case 422: return NSLocalizedString("请求参数无法处理 (Unprocessable Entity)", comment: "HTTP 422 description")
        case 429: return NSLocalizedString("请求过于频繁，请稍后重试 (Too Many Requests)", comment: "HTTP 429 description")
        // 5xx 服务端错误
        case 500: return NSLocalizedString("服务器内部错误 (Internal Server Error)", comment: "HTTP 500 description")
        case 501: return NSLocalizedString("功能未实现 (Not Implemented)", comment: "HTTP 501 description")
        case 502: return NSLocalizedString("网关错误，上游服务无响应 (Bad Gateway)", comment: "HTTP 502 description")
        case 503: return NSLocalizedString("服务暂时不可用 (Service Unavailable)", comment: "HTTP 503 description")
        case 504: return NSLocalizedString("网关超时 (Gateway Timeout)", comment: "HTTP 504 description")
        case 520: return NSLocalizedString("未知错误 (Cloudflare)", comment: "HTTP 520 description")
        case 521: return NSLocalizedString("服务器宕机 (Cloudflare)", comment: "HTTP 521 description")
        case 522: return NSLocalizedString("连接超时 (Cloudflare)", comment: "HTTP 522 description")
        case 523: return NSLocalizedString("源站不可达 (Cloudflare)", comment: "HTTP 523 description")
        case 524: return NSLocalizedString("响应超时 (Cloudflare)", comment: "HTTP 524 description")
        case 525: return NSLocalizedString("SSL 握手失败 (Cloudflare)", comment: "HTTP 525 description")
        case 526: return NSLocalizedString("无效的 SSL 证书 (Cloudflare)", comment: "HTTP 526 description")
        // 其他
        default:
            if code >= 400 && code < 500 {
                return NSLocalizedString("客户端错误", comment: "Generic 4xx error description")
            } else if code >= 500 && code < 600 {
                return NSLocalizedString("服务器错误", comment: "Generic 5xx error description")
            }
            return NSLocalizedString("HTTP 错误", comment: "Generic HTTP error description")
        }
    }
    
    /// 格式化错误内容，使其更简洁易读
    /// - Returns: (显示内容, 完整内容（如果被截断则非空）)
    func formatErrorContent(_ content: String, httpStatusCode: Int? = nil) -> (String, String?) {
        let maxLength = 500
        var displayMessage: String
        var fullContent: String? = nil
        
        // 构建状态码描述前缀
        var statusPrefix = ""
        if let code = httpStatusCode {
            let description = httpStatusCodeDescription(code)
            statusPrefix = String(
                format: NSLocalizedString("HTTP %d: %@\n\n", comment: "HTTP status prefix with code and description"),
                code,
                description
            )
        }
        
        // 检查内容是否需要截断
        if content.count > maxLength {
            // 内容过长，需要截断
            let truncatedContent = String(content.prefix(maxLength))
            let truncationNotice = NSLocalizedString(
                "...\n\n(响应已截断，可在更多操作中查看完整内容)",
                comment: "Truncation notice for long error content"
            )
            displayMessage = statusPrefix + truncatedContent + truncationNotice
            fullContent = statusPrefix + content
        } else {
            // 内容长度合适，直接显示
            displayMessage = statusPrefix + content
        }
        
        return (displayMessage, fullContent)
    }

    struct AuxiliaryContextPolicy {
        let enableMemory: Bool
        let enableMemoryWrite: Bool
        let enableMemoryActiveRetrieval: Bool
        let includeAppTools: Bool
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
        let isolationActive = session?.isWorldbookContextIsolationActive ?? false
        guard isolationActive else {
            return AuxiliaryContextPolicy(
                enableMemory: enableMemory,
                enableMemoryWrite: enableMemoryWrite,
                enableMemoryActiveRetrieval: enableMemoryActiveRetrieval,
                includeAppTools: true,
                includeMCPTools: true,
                includeShortcutTools: true,
                includeSkills: true
            )
        }

        logger.info("当前会话已启用世界书隔离发送，将屏蔽长期记忆与工具上下文。")
        return AuxiliaryContextPolicy(
            enableMemory: false,
            enableMemoryWrite: false,
            enableMemoryActiveRetrieval: false,
            includeAppTools: false,
            includeMCPTools: false,
            includeShortcutTools: false,
            includeSkills: false
        )
    }

    func resolveRequestTooling(
        for session: ChatSession?,
        enableMemory: Bool,
        enableMemoryWrite: Bool,
        enableMemoryActiveRetrieval: Bool
    ) async -> (tools: [InternalToolDefinition]?, policy: AuxiliaryContextPolicy) {
        let policy = auxiliaryContextPolicy(
            for: session,
            enableMemory: enableMemory,
            enableMemoryWrite: enableMemoryWrite,
            enableMemoryActiveRetrieval: enableMemoryActiveRetrieval
        )

        var resolvedTools: [InternalToolDefinition] = []
        if policy.enableMemory && policy.enableMemoryWrite {
            resolvedTools.append(saveMemoryTool)
        }
        if policy.enableMemory && policy.enableMemoryActiveRetrieval && resolvedMemoryTopK() > 0 {
            resolvedTools.append(searchMemoryTool)
        }
        let builtInAppTools = await MainActor.run { AppToolManager.shared.builtInToolsForLLM() }
        resolvedTools.append(contentsOf: builtInAppTools)
        if policy.includeAppTools {
            let appTools = await MainActor.run { AppToolManager.shared.chatToolsForLLM() }
            resolvedTools.append(contentsOf: appTools)
        }
        if policy.includeMCPTools {
            let mcpTools = await MainActor.run { MCPManager.shared.chatToolsForLLM() }
            resolvedTools.append(contentsOf: mcpTools)
        }
        if policy.includeShortcutTools {
            let shortcutTools = await MainActor.run { ShortcutToolManager.shared.chatToolsForLLM() }
            resolvedTools.append(contentsOf: shortcutTools)
        }
        if policy.includeSkills {
            let skillTools = await MainActor.run { SkillManager.shared.chatToolsForLLM() }
            resolvedTools.append(contentsOf: skillTools)
        }
        return (resolvedTools.isEmpty ? nil : resolvedTools, policy)
    }

    func preparedMessagesForRequest(
        from messages: [ChatMessage],
        loadingMessageID: UUID,
        session: ChatSession?
    ) -> [ChatMessage] {
        let visibleMessages = ChatResponseAttemptSupport.visibleMessages(from: messages)
        let baseMessages = visibleMessages.filter { $0.role != .error && $0.id != loadingMessageID }
        let normalizedMessages = normalizedMessagesForToolCallChain(baseMessages)
        guard session?.isWorldbookContextIsolationActive == true else {
            return normalizedMessages
        }

        return normalizedMessages.compactMap { message in
            guard message.role != .tool else { return nil }
            var sanitized = message
            sanitized.toolCalls = nil
            sanitized.toolCallsPlacement = nil

            if sanitized.role == .assistant,
               sanitized.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return nil
            }
            return sanitized
        }
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

    func responseRoundEndIndex(in messages: [ChatMessage], anchorUserIndex: Int) -> Int {
        guard anchorUserIndex + 1 < messages.count else { return messages.count }
        return messages[(anchorUserIndex + 1)...].firstIndex(where: { $0.role == .user }) ?? messages.count
    }

    func prepareRetryAttemptMetadata(
        in messages: inout [ChatMessage],
        anchorUserIndex: Int
    ) -> ResponseAttemptMetadata {
        let groupID = messages[anchorUserIndex].id
        let roundEndIndex = responseRoundEndIndex(in: messages, anchorUserIndex: anchorUserIndex)
        let roundRange = messages.index(after: anchorUserIndex)..<roundEndIndex
        let existingAttemptIDs = ChatResponseAttemptSupport.orderedAttemptIDs(for: groupID, in: messages)

        if existingAttemptIDs.isEmpty, !roundRange.isEmpty {
            let legacyAttemptID = UUID()
            for index in roundRange where messages[index].role != .user {
                messages[index].responseGroupID = groupID
                messages[index].responseAttemptID = legacyAttemptID
                messages[index].responseAttemptIndex = 0
            }
            messages[anchorUserIndex].selectedResponseAttemptID = legacyAttemptID
        } else if messages[anchorUserIndex].selectedResponseAttemptID == nil {
            messages[anchorUserIndex].selectedResponseAttemptID = existingAttemptIDs.last
        }

        let nextAttemptIndex = messages[roundRange]
            .compactMap(\.responseAttemptIndex)
            .max()
            .map { $0 + 1 } ?? (existingAttemptIDs.isEmpty ? 0 : existingAttemptIDs.count)
        let newAttempt = ResponseAttemptMetadata(
            groupID: groupID,
            attemptID: UUID(),
            attemptIndex: nextAttemptIndex
        )
        messages[anchorUserIndex].selectedResponseAttemptID = newAttempt.attemptID
        return newAttempt
    }

    func isTailContinuationRetryTarget(_ message: ChatMessage, in messages: [ChatMessage]) -> Bool {
        guard message.role == .error else { return false }
        let visibleMessages = ChatResponseAttemptSupport.visibleMessages(from: messages)
        guard let visibleIndex = visibleMessages.firstIndex(where: { $0.id == message.id }) else { return false }
        let precedingMessages = visibleMessages[..<visibleIndex]
        guard precedingMessages.last(where: { $0.role != .system })?.role == .tool else {
            return false
        }
        let trailingMessages = visibleMessages[visibleMessages.index(after: visibleIndex)...]
        return !trailingMessages.contains { trailingMessage in
            switch trailingMessage.role {
            case .user, .assistant, .tool, .error:
                return true
            case .system:
                return false
            }
        }
    }

    func continuationAttemptMetadata(
        for message: ChatMessage,
        in messages: [ChatMessage],
        anchorUserIndex: Int,
        targetIndex: Int
    ) -> ResponseAttemptMetadata? {
        if let metadata = responseAttemptMetadata(from: message) {
            return metadata
        }

        let anchorUser = messages[anchorUserIndex]
        if let selectedAttemptID = anchorUser.selectedResponseAttemptID {
            let attemptIndex = messages
                .filter { $0.responseGroupID == anchorUser.id && $0.responseAttemptID == selectedAttemptID }
                .compactMap(\.responseAttemptIndex)
                .min() ?? 0
            return ResponseAttemptMetadata(
                groupID: anchorUser.id,
                attemptID: selectedAttemptID,
                attemptIndex: attemptIndex
            )
        }

        guard targetIndex > anchorUserIndex else { return nil }
        return messages[anchorUserIndex...targetIndex]
            .reversed()
            .compactMap { responseAttemptMetadata(from: $0) }
            .first
    }

    func continuationInsertionIndex(
        in messages: [ChatMessage],
        referenceIndex: Int,
        metadata: ResponseAttemptMetadata?
    ) -> Int {
        if let attemptID = metadata?.attemptID,
           let lastAttemptIndex = messages.lastIndex(where: { $0.responseAttemptID == attemptID }) {
            return messages.index(after: lastAttemptIndex)
        }
        return messages.index(after: referenceIndex)
    }

    /// 规范化历史中的工具调用链，避免把不完整/损坏的工具消息带入下一次请求。
    /// 这一步会：
    /// 1. 丢弃无法关联到 assistant.toolCalls 的孤立 tool 消息；
    /// 2. 对没有匹配结果的 assistant.toolCalls 做裁剪（必要时直接移除该 assistant 占位消息）。
    func normalizedMessagesForToolCallChain(_ source: [ChatMessage]) -> [ChatMessage] {
        guard !source.isEmpty else { return source }

        var normalized: [ChatMessage] = []
        normalized.reserveCapacity(source.count)

        var index = 0
        while index < source.count {
            let message = source[index]

            // 单独出现的 tool 消息视为孤儿消息，直接跳过，避免触发上游 400。
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
                // 若 assistant 只有工具调用占位且无正文，直接删除；否则仅清理 toolCalls。
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
}
