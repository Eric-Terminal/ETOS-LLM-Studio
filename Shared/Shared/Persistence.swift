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
import os.log

private let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "Persistence")

public enum Persistence {

    // MARK: - 目录管理

    /// 获取用于存储聊天记录的目录URL
    /// - Returns: 存储目录的URL路径
    public static func getChatsDirectory() -> URL {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        let chatsDirectory = paths[0].appendingPathComponent("ChatSessions")
        if !FileManager.default.fileExists(atPath: chatsDirectory.path) {
            logger.info("Chat history directory does not exist, creating: \(chatsDirectory.path)")
            try? FileManager.default.createDirectory(at: chatsDirectory, withIntermediateDirectories: true)
        }
        return chatsDirectory
    }

    // MARK: - 会话持久化

    /// 保存所有聊天会话的列表
    public static func saveChatSessions(_ sessions: [ChatSession]) {
        // 保存前过滤掉所有临时会话。
        let sessionsToSave = sessions.filter { !$0.isTemporary }
        
        let fileURL = getChatsDirectory().appendingPathComponent("sessions.json")
        logger.info("Saving \(sessionsToSave.count) sessions to \(fileURL.path)")

        do {
            let data = try JSONEncoder().encode(sessionsToSave)
            try data.write(to: fileURL, options: [.atomicWrite, .completeFileProtection])
            logger.info("Session list saved successfully.")
        } catch {
            logger.error("Failed to save session list: \(error.localizedDescription)")
        }
    }

    /// 加载所有聊天会话的列表
    public static func loadChatSessions() -> [ChatSession] {
        let fileURL = getChatsDirectory().appendingPathComponent("sessions.json")
        logger.info("Loading session list from \(fileURL.path)")

        do {
            let data = try Data(contentsOf: fileURL)
            let loadedSessions = try JSONDecoder().decode([ChatSession].self, from: data)
            logger.info("Successfully loaded \(loadedSessions.count) sessions.")
            return loadedSessions
        } catch {
            logger.warning("Failed to load session list, returning empty list: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - 消息持久化

    /// 保存指定会话的聊天消息
    public static func saveMessages(_ messages: [ChatMessage], for sessionID: UUID) {
        let fileURL = getChatsDirectory().appendingPathComponent("\(sessionID.uuidString).json")
        logger.info("Saving \(messages.count) messages for session \(sessionID.uuidString) to \(fileURL.path)")

        do {
            let data = try JSONEncoder().encode(messages)
            try data.write(to: fileURL, options: [.atomicWrite, .completeFileProtection])
            logger.info("Messages saved successfully for session \(sessionID.uuidString).")
        } catch {
            logger.error("Failed to save messages for session \(sessionID.uuidString): \(error.localizedDescription)")
        }
    }

    /// 加载指定会话的聊天消息
    public static func loadMessages(for sessionID: UUID) -> [ChatMessage] {
        let fileURL = getChatsDirectory().appendingPathComponent("\(sessionID.uuidString).json")
        logger.info("Loading messages for session \(sessionID.uuidString) from \(fileURL.path)")

        do {
            let data = try Data(contentsOf: fileURL)
            let loadedMessages = try JSONDecoder().decode([ChatMessage].self, from: data)
            logger.info("Successfully loaded \(loadedMessages.count) messages for session \(sessionID.uuidString).")
            return loadedMessages
        } catch {
            logger.warning("Failed to load messages for session \(sessionID.uuidString), returning empty list: \(error.localizedDescription)")
            return []
        }
    }
}