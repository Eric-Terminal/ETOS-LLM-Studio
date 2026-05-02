// ============================================================================
// ChatServiceWorldbookManagement.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责 ChatService 的世界书加载、导入导出、删除和会话绑定设置。
// ============================================================================

import Foundation

extension ChatService {
    public func loadWorldbooks() -> [Worldbook] {
        worldbookStore.loadWorldbooks()
    }

    public func saveWorldbook(_ worldbook: Worldbook) {
        worldbookStore.upsertWorldbook(worldbook)
    }

    public func deleteWorldbook(id: UUID) {
        worldbookStore.deleteWorldbook(id: id)

        // 清理会话绑定中的孤立引用。
        var sessions = chatSessionsSubject.value
        var didChange = false
        for index in sessions.indices {
            if sessions[index].lorebookIDs.contains(id) {
                sessions[index].lorebookIDs.removeAll { $0 == id }
                didChange = true
            }
        }
        if didChange {
            chatSessionsSubject.send(sessions)
            if let current = currentSessionSubject.value,
               let updated = sessions.first(where: { $0.id == current.id }) {
                currentSessionSubject.send(updated)
            }
            Persistence.saveChatSessions(sessions)
        }
    }

    @discardableResult
    public func importWorldbook(data: Data, fileName: String) throws -> WorldbookImportReport {
        let imported = try worldbookImportService.importWorldbookWithReport(from: data, fileName: fileName)
        return worldbookStore.mergeImportedWorldbook(
            imported.worldbook,
            dedupeByContent: true,
            diagnostics: imported.diagnostics
        )
    }

    public func assignWorldbooks(to sessionID: UUID, worldbookIDs: [UUID]) {
        let currentIsolationEnabled = chatSessionsSubject.value.first(where: { $0.id == sessionID })?.worldbookContextIsolationEnabled
            ?? currentSessionSubject.value?.worldbookContextIsolationEnabled
            ?? false
        updateWorldbookSessionSettings(
            sessionID: sessionID,
            worldbookIDs: worldbookIDs,
            worldbookContextIsolationEnabled: currentIsolationEnabled
        )
    }

    public func updateWorldbookSessionSettings(
        sessionID: UUID,
        worldbookIDs: [UUID],
        worldbookContextIsolationEnabled: Bool
    ) {
        var sessions = chatSessionsSubject.value
        let uniqueIDs = deduplicatedWorldbookIDs(worldbookIDs)

        if let index = sessions.firstIndex(where: { $0.id == sessionID }) {
            sessions[index].lorebookIDs = uniqueIDs
            sessions[index].worldbookContextIsolationEnabled = worldbookContextIsolationEnabled
            chatSessionsSubject.send(sessions)
        }

        if let current = currentSessionSubject.value, current.id == sessionID {
            var updated = current
            updated.lorebookIDs = uniqueIDs
            updated.worldbookContextIsolationEnabled = worldbookContextIsolationEnabled
            currentSessionSubject.send(updated)
        }

        Persistence.saveChatSessions(sessions)
    }

    public func exportWorldbook(id: UUID) throws -> (data: Data, suggestedFileName: String) {
        guard let book = worldbookStore.loadWorldbooks().first(where: { $0.id == id }) else {
            throw WorldbookExportRequestError.bookNotFound
        }
        let data = try worldbookExportService.exportWorldbook(book)
        return (data: data, suggestedFileName: worldbookExportService.suggestedFileName(for: book))
    }

    private func deduplicatedWorldbookIDs(_ ids: [UUID]) -> [UUID] {
        var seen = Set<UUID>()
        var ordered: [UUID] = []
        for id in ids where !seen.contains(id) {
            seen.insert(id)
            ordered.append(id)
        }
        return ordered
    }
}
