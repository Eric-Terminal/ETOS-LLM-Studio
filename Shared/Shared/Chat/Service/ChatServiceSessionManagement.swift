// ============================================================================
// ChatServiceSessionManagement.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责 ChatService 的会话创建、删除、分支、文件夹管理与当前会话切换。
// ============================================================================

import Foundation
import Combine
import os.log

extension ChatService {
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
            var messagesToCopy = Array(sourceMessages[0...messageIndex])

            for i in messagesToCopy.indices {
                if let originalFileName = messagesToCopy[i].audioFileName,
                   let audioData = Persistence.loadAudio(fileName: originalFileName) {
                    let ext = (originalFileName as NSString).pathExtension
                    let newFileName = "\(UUID().uuidString).\(ext)"
                    if Persistence.saveAudio(audioData, fileName: newFileName) != nil {
                        messagesToCopy[i].audioFileName = newFileName
                        logger.info("  - 复制了音频文件: \(originalFileName) -> \(newFileName)")
                    }
                }

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
            deleteStoredAttachments(for: lastMessage)
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

    private func relatedToolResultMessageIDs(for message: ChatMessage, at messageIndex: Int, in messages: [ChatMessage]) -> Set<UUID> {
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

    private func isSameResponseAttempt(_ lhs: ChatMessage, _ rhs: ChatMessage) -> Bool {
        switch (lhs.responseAttemptID, rhs.responseAttemptID) {
        case let (lhsAttemptID?, rhsAttemptID?):
            return lhsAttemptID == rhsAttemptID
        case (nil, nil):
            return true
        default:
            return false
        }
    }

    private func deleteStoredAttachments(for message: ChatMessage) {
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

    private func repairSelectedResponseAttempts(in messages: inout [ChatMessage], affectedBy deletedMessages: [ChatMessage]) {
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

    private func responseAttemptHasDisplaySegment(groupID: UUID, attemptID: UUID, in messages: [ChatMessage]) -> Bool {
        messages.contains {
            $0.responseGroupID == groupID
                && $0.responseAttemptID == attemptID
                && ($0.role == .assistant || $0.role == .error)
        }
    }
}
