// ============================================================================
// Persistence.swift
// ============================================================================
// ETOS LLM Studio Watch App 数据持久化文件
//
// 功能特性:
// - 提供保存和加载聊天会话列表的功能
// - 提供保存和加载单个会话消息记录的功能
// - 管理文件系统中的存储路径
// ============================================================================

import Foundation

// MARK: - 目录管理

/// 获取用于存储聊天记录的目录URL
/// - Returns: 存储目录的URL路径
func getChatsDirectory() -> URL {
    let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
    let chatsDirectory = paths[0].appendingPathComponent("ChatSessions")
    if !FileManager.default.fileExists(atPath: chatsDirectory.path) {
        print("💾 [Persistence] 聊天记录目录不存在，正在创建: \(chatsDirectory.path)")
        try? FileManager.default.createDirectory(at: chatsDirectory, withIntermediateDirectories: true)
    }
    return chatsDirectory
}

// MARK: - 会话持久化

/// 保存所有聊天会话的列表
func saveChatSessions(_ sessions: [ChatSession]) {
    // 在保存前，过滤掉所有临时的会话
    let sessionsToSave = sessions.filter { !$0.isTemporary }
    
    let fileURL = getChatsDirectory().appendingPathComponent("sessions.json")
    print("💾 [Persistence] 准备保存会话列表...")
    print("  - 目标路径: \(fileURL.path)")
    print("  - 将要保存 \(sessionsToSave.count) 个会话。")

    do {
        let data = try JSONEncoder().encode(sessionsToSave)
        try data.write(to: fileURL, options: [.atomicWrite, .completeFileProtection])
        print("  - ✅ 会话列表保存成功。")
    } catch {
        print("  - ❌ 保存会话列表失败: \(error.localizedDescription)")
    }
}

/// 加载所有聊天会话的列表
func loadChatSessions() -> [ChatSession] {
    let fileURL = getChatsDirectory().appendingPathComponent("sessions.json")
    print("💾 [Persistence] 准备加载会话列表...")
    print("  - 目标路径: \(fileURL.path)")

    do {
        let data = try Data(contentsOf: fileURL)
        let loadedSessions = try JSONDecoder().decode([ChatSession].self, from: data)
        print("  - ✅ 成功加载了 \(loadedSessions.count) 个会话。")
        return loadedSessions
    } catch {
        print("  - ⚠️ 加载会话列表失败: \(error.localizedDescription)。将返回空列表。")
        return []
    }
}

// MARK: - 消息持久化

/// 保存指定会话的聊天消息
func saveMessages(_ messages: [ChatMessage], for sessionID: UUID) {
    let fileURL = getChatsDirectory().appendingPathComponent("\(sessionID.uuidString).json")
    print("💾 [Persistence] 准备保存消息...")
    print("  - 会话ID: \(sessionID.uuidString)")
    print("  - 目标路径: \(fileURL.path)")
    print("  - 将要保存 \(messages.count) 条消息。")

    do {
        let data = try JSONEncoder().encode(messages)
        try data.write(to: fileURL, options: [.atomicWrite, .completeFileProtection])
        print("  - ✅ 消息保存成功。")
    } catch {
        print("  - ❌ 保存消息失败: \(error.localizedDescription)")
    }
}

/// 加载指定会话的聊天消息
func loadMessages(for sessionID: UUID) -> [ChatMessage] {
    let fileURL = getChatsDirectory().appendingPathComponent("\(sessionID.uuidString).json")
    print("💾 [Persistence] 准备加载消息...")
    print("  - 会话ID: \(sessionID.uuidString)")
    print("  - 目标路径: \(fileURL.path)")

    do {
        let data = try Data(contentsOf: fileURL)
        let loadedMessages = try JSONDecoder().decode([ChatMessage].self, from: data)
        print("  - ✅ 成功加载了 \(loadedMessages.count) 条消息。")
        return loadedMessages
    } catch {
        print("  - ⚠️ 加载消息失败: \(error.localizedDescription)。将返回空列表。")
        return []
    }
}
