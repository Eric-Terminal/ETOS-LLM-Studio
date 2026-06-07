// ============================================================================
// ChatServiceSessionTagManagement.swift
// ============================================================================
// ETOS LLM Studio
//
// ChatService 的会话标签管理逻辑。
// ============================================================================

import Combine
import Foundation
import os.log

extension ChatService {
    @discardableResult
    public func createSessionTag(name: String, color: SessionTagColor? = nil) -> SessionTag? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return nil }

        var tags = sessionTagsSubject.value
        guard !tags.contains(where: { normalizedSessionTagName($0.name) == normalizedSessionTagName(trimmedName) }) else {
            return nil
        }

        let tag = SessionTag(name: trimmedName, color: color, updatedAt: Date())
        tags.append(tag)
        tags = normalizedSessionTags(tags)
        sessionTagsSubject.send(tags)
        Persistence.saveSessionTags(tags)
        logger.info("已创建会话标签: \(trimmedName)")
        return tag
    }

    public func updateSessionTag(_ tag: SessionTag, name: String, color: SessionTagColor?) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        var tags = sessionTagsSubject.value
        guard let index = tags.firstIndex(where: { $0.id == tag.id }) else { return }
        let normalizedName = normalizedSessionTagName(trimmedName)
        guard !tags.contains(where: { $0.id != tag.id && normalizedSessionTagName($0.name) == normalizedName }) else {
            return
        }

        guard tags[index].name != trimmedName || tags[index].color != color else { return }
        tags[index].name = trimmedName
        tags[index].color = color
        tags[index].updatedAt = Date()
        tags = normalizedSessionTags(tags)
        sessionTagsSubject.send(tags)
        Persistence.saveSessionTags(tags)
        logger.info("已更新会话标签: \(trimmedName)")
    }

    public func deleteSessionTag(_ tag: SessionTag) {
        deleteSessionTag(tagID: tag.id)
    }

    public func deleteSessionTag(tagID: UUID) {
        var tags = sessionTagsSubject.value
        guard tags.contains(where: { $0.id == tagID }) else { return }
        tags.removeAll { $0.id == tagID }
        sessionTagsSubject.send(tags)
        Persistence.saveSessionTags(tags)

        var sessions = chatSessionsSubject.value
        var didUpdateSessions = false
        for index in sessions.indices where sessions[index].tagIDs.contains(tagID) {
            sessions[index].tagIDs.removeAll { $0 == tagID }
            didUpdateSessions = true
        }

        if didUpdateSessions {
            chatSessionsSubject.send(sessions)
            if let current = currentSessionSubject.value,
               let updatedCurrent = sessions.first(where: { $0.id == current.id }) {
                currentSessionSubject.send(updatedCurrent)
            }
            Persistence.saveChatSessions(sessions)
        }

        logger.info("已删除会话标签。")
    }

    public func setSessionTags(sessionID: UUID, tagIDs: [UUID]) {
        let validTagIDs = Set(sessionTagsSubject.value.map(\.id))
        var seen = Set<UUID>()
        let normalizedTagIDs = tagIDs.filter { tagID in
            validTagIDs.contains(tagID) && seen.insert(tagID).inserted
        }

        var sessions = chatSessionsSubject.value
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        guard sessions[index].tagIDs != normalizedTagIDs else { return }

        sessions[index].tagIDs = normalizedTagIDs
        chatSessionsSubject.send(sessions)
        if let current = currentSessionSubject.value, current.id == sessionID {
            currentSessionSubject.send(sessions[index])
        }
        Persistence.saveChatSessions(sessions)
        logger.info("已更新会话标签绑定。")
    }

    public func toggleSessionTag(sessionID: UUID, tagID: UUID) {
        guard sessionTagsSubject.value.contains(where: { $0.id == tagID }) else { return }
        let currentTagIDs = chatSessionsSubject.value.first(where: { $0.id == sessionID })?.tagIDs ?? []
        if currentTagIDs.contains(tagID) {
            setSessionTags(sessionID: sessionID, tagIDs: currentTagIDs.filter { $0 != tagID })
        } else {
            setSessionTags(sessionID: sessionID, tagIDs: currentTagIDs + [tagID])
        }
    }

    private func normalizedSessionTags(_ tags: [SessionTag]) -> [SessionTag] {
        tags.sorted { left, right in
            let order = left.name.localizedStandardCompare(right.name)
            if order != .orderedSame {
                return order == .orderedAscending
            }
            return left.id.uuidString < right.id.uuidString
        }
    }

    private func normalizedSessionTagName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
