// ============================================================================
// ChatViewModelMemoryManagement.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件负责 ChatViewModel 中记忆条目与对话记忆摘要的管理入口。
// ============================================================================

import Foundation
import Shared

extension ChatViewModel {
    func addMemory(content: String) async {
        await MemoryManager.shared.addMemory(content: content)
    }

    func updateMemory(item: MemoryItem) async {
        await MemoryManager.shared.updateMemory(item: item)
    }

    func archiveMemory(_ item: MemoryItem) async {
        await MemoryManager.shared.archiveMemory(item)
    }

    func unarchiveMemory(_ item: MemoryItem) async {
        await MemoryManager.shared.unarchiveMemory(item)
    }

    func deleteMemories(at offsets: IndexSet) async {
        let items = offsets.map { memories[$0] }
        await MemoryManager.shared.deleteMemories(items)
    }

    func reembedAllMemories() async throws -> MemoryReembeddingSummary {
        try await MemoryManager.shared.reembedAllMemories()
    }

    func reloadConversationMemoryState() {
        conversationSessionSummaries = ConversationMemoryManager.loadAllSessionSummaries()
        conversationUserProfile = ConversationMemoryManager.loadUserProfile()
    }

    func deleteConversationSummary(for sessionID: UUID) {
        ConversationMemoryManager.removeSessionSummary(sessionID: sessionID)
        reloadConversationMemoryState()
    }

    @discardableResult
    func clearAllConversationSummaries() -> Int {
        let removed = ConversationMemoryManager.clearAllSessionSummaries()
        reloadConversationMemoryState()
        return removed
    }

    func saveConversationUserProfile(content: String) throws {
        try ConversationMemoryManager.saveUserProfile(content: content)
        reloadConversationMemoryState()
    }

    func clearConversationUserProfile() throws {
        try ConversationMemoryManager.clearUserProfile()
        reloadConversationMemoryState()
    }
}
