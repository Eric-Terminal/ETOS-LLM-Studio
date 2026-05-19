// ============================================================================
// ChatServiceSessionFolderManagement.swift
// ============================================================================
// ETOS LLM Studio
//
// ChatService 的会话文件夹管理与当前会话刷新逻辑。
// ============================================================================

import Foundation
import Combine
import os.log

extension ChatService {
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

    public func reloadCurrentSessionMessagesFromPersistence() {
        guard let currentSession = currentSessionSubject.value else { return }
        let reloadedMessages = Persistence.loadMessages(for: currentSession.id)
        publishMessages(reloadedMessages)
        logger.info("已从持久化层刷新当前会话消息: \(currentSession.id.uuidString)")
    }

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
                category: NSLocalizedString("会话", comment: "App log category"),
                action: NSLocalizedString("更新当前会话", comment: "App log action"),
                payload: ["sessionID": session.id.uuidString]
            )
            return
        }

        currentSessionSubject.send(session)
        let messages = session != nil ? Persistence.loadMessages(for: session!.id) : []
        publishMessages(messages)
        logger.info("已切换到会话: \(session?.name ?? "无")")
        AppLog.userOperation(
            category: NSLocalizedString("会话", comment: "App log category"),
            action: NSLocalizedString("切换会话", comment: "App log action"),
            payload: ["sessionID": session?.id.uuidString ?? NSLocalizedString("无", comment: "App log empty value")]
        )
    }

    func promoteSessionToTopIfNeeded(sessionID: UUID) {
        var sessions = chatSessionsSubject.value
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }), index > 0 else { return }
        let session = sessions.remove(at: index)
        sessions.insert(session, at: 0)
        chatSessionsSubject.send(sessions)
        Persistence.saveChatSessions(sessions)
        logger.info("已将会话移动到列表顶部: \(session.name)")
    }

    private func collectSessionFolderDescendantIDs(rootID: UUID, folders: [SessionFolder]) -> Set<UUID> {
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
}
