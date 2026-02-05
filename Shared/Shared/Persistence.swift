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
            var loadedMessages = try JSONDecoder().decode([ChatMessage].self, from: data)
            var didMigratePlacement = false
            for index in loadedMessages.indices {
                guard loadedMessages[index].toolCallsPlacement == nil,
                      let toolCalls = loadedMessages[index].toolCalls,
                      !toolCalls.isEmpty else { continue }
                loadedMessages[index].toolCallsPlacement = inferToolCallsPlacement(from: loadedMessages[index].content)
                didMigratePlacement = true
            }
            if didMigratePlacement {
                logger.info("Migrated toolCallsPlacement for session \(sessionID.uuidString).")
                saveMessages(loadedMessages, for: sessionID)
            }
            logger.info("Successfully loaded \(loadedMessages.count) messages for session \(sessionID.uuidString).")
            return loadedMessages
        } catch {
            logger.warning("Failed to load messages for session \(sessionID.uuidString), returning empty list: \(error.localizedDescription)")
            return []
        }
    }

    private static func inferToolCallsPlacement(from content: String) -> ToolCallsPlacement {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return .afterReasoning
        }
        let lowered = trimmed.lowercased()
        let startsWithThought = lowered.hasPrefix("<thought") || lowered.hasPrefix("<thinking") || lowered.hasPrefix("<think")
        if startsWithThought {
            let hasClosing = lowered.contains("</thought>") || lowered.contains("</thinking>") || lowered.contains("</think>")
            if !hasClosing {
                return .afterReasoning
            }
        }
        let contentWithoutThought = stripThoughtTags(from: content)
        if !contentWithoutThought.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .afterContent
        }
        if lowered.contains("<thought") || lowered.contains("<thinking") || lowered.contains("<think") {
            return .afterReasoning
        }
        return .afterContent
    }

    private static func stripThoughtTags(from text: String) -> String {
        let pattern = "<(thought|thinking|think)>(.*?)</\\1>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
    }
    
    // MARK: - 音频文件持久化
    
    /// 获取用于存储音频文件的目录URL
    /// - Returns: 音频存储目录的URL路径
    public static func getAudioDirectory() -> URL {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        let audioDirectory = paths[0].appendingPathComponent("AudioFiles")
        if !FileManager.default.fileExists(atPath: audioDirectory.path) {
            logger.info("Audio directory does not exist, creating: \(audioDirectory.path)")
            try? FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        }
        return audioDirectory
    }
    
    /// 保存音频数据到文件
    /// - Parameters:
    ///   - data: 音频数据
    ///   - fileName: 文件名（包含扩展名）
    /// - Returns: 保存成功返回文件URL，失败返回nil
    @discardableResult
    public static func saveAudio(_ data: Data, fileName: String) -> URL? {
        let fileURL = getAudioDirectory().appendingPathComponent(fileName)
        logger.info("Saving audio file: \(fileName)")
        
        do {
            try data.write(to: fileURL, options: [.atomicWrite, .completeFileProtection])
            logger.info("Audio file saved successfully: \(fileName)")
            return fileURL
        } catch {
            logger.error("Failed to save audio file \(fileName): \(error.localizedDescription)")
            return nil
        }
    }
    
    /// 加载音频数据
    /// - Parameter fileName: 文件名（包含扩展名）
    /// - Returns: 音频数据，如果文件不存在则返回nil
    public static func loadAudio(fileName: String) -> Data? {
        let fileURL = getAudioDirectory().appendingPathComponent(fileName)
        logger.info("Loading audio file: \(fileName)")
        
        do {
            let data = try Data(contentsOf: fileURL)
            logger.info("Audio file loaded successfully: \(fileName)")
            return data
        } catch {
            logger.warning("Failed to load audio file \(fileName): \(error.localizedDescription)")
            return nil
        }
    }
    
    /// 检查音频文件是否存在
    /// - Parameter fileName: 文件名（包含扩展名）
    /// - Returns: 文件是否存在
    public static func audioFileExists(fileName: String) -> Bool {
        let fileURL = getAudioDirectory().appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: fileURL.path)
    }
    
    /// 删除指定的音频文件
    /// - Parameter fileName: 文件名（包含扩展名）
    public static func deleteAudio(fileName: String) {
        let fileURL = getAudioDirectory().appendingPathComponent(fileName)
        logger.info("Deleting audio file: \(fileName)")
        
        do {
            try FileManager.default.removeItem(at: fileURL)
            logger.info("Audio file deleted successfully: \(fileName)")
        } catch {
            logger.warning("Failed to delete audio file \(fileName): \(error.localizedDescription)")
        }
    }
    
    /// 删除会话相关的所有音频文件
    /// - Parameters:
    ///   - messages: 会话中的消息列表
    public static func deleteAudioFiles(for messages: [ChatMessage]) {
        let audioFileNames = messages.compactMap { $0.audioFileName }
        for fileName in audioFileNames {
            deleteAudio(fileName: fileName)
        }
        if !audioFileNames.isEmpty {
            logger.info("Deleted \(audioFileNames.count) audio files for session.")
        }
    }
    
    /// 获取所有音频文件
    /// - Returns: 音频文件名数组
    public static func getAllAudioFileNames() -> [String] {
        let directory = getAudioDirectory()
        do {
            let fileURLs = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            return fileURLs.map { $0.lastPathComponent }
        } catch {
            logger.warning("Failed to list audio files: \(error.localizedDescription)")
            return []
        }
    }
    
    // MARK: - 图片文件持久化
    
    /// 获取用于存储图片文件的目录URL
    /// - Returns: 图片存储目录的URL路径
    public static func getImageDirectory() -> URL {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        let imageDirectory = paths[0].appendingPathComponent("ImageFiles")
        if !FileManager.default.fileExists(atPath: imageDirectory.path) {
            logger.info("Image directory does not exist, creating: \(imageDirectory.path)")
            try? FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
        }
        return imageDirectory
    }
    
    /// 保存图片数据到文件
    /// - Parameters:
    ///   - data: 图片数据
    ///   - fileName: 文件名（包含扩展名）
    /// - Returns: 保存成功返回文件URL，失败返回nil
    @discardableResult
    public static func saveImage(_ data: Data, fileName: String) -> URL? {
        let fileURL = getImageDirectory().appendingPathComponent(fileName)
        logger.info("Saving image file: \(fileName)")
        
        do {
            try data.write(to: fileURL, options: [.atomicWrite, .completeFileProtection])
            logger.info("Image file saved successfully: \(fileName)")
            return fileURL
        } catch {
            logger.error("Failed to save image file \(fileName): \(error.localizedDescription)")
            return nil
        }
    }
    
    /// 加载图片数据
    /// - Parameter fileName: 文件名（包含扩展名）
    /// - Returns: 图片数据，如果文件不存在则返回nil
    public static func loadImage(fileName: String) -> Data? {
        let fileURL = getImageDirectory().appendingPathComponent(fileName)
        
        do {
            let data = try Data(contentsOf: fileURL)
            return data
        } catch {
            logger.warning("Failed to load image file \(fileName): \(error.localizedDescription)")
            return nil
        }
    }
    
    /// 检查图片文件是否存在
    /// - Parameter fileName: 文件名（包含扩展名）
    /// - Returns: 文件是否存在
    public static func imageFileExists(fileName: String) -> Bool {
        let fileURL = getImageDirectory().appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: fileURL.path)
    }
    
    /// 删除指定的图片文件
    /// - Parameter fileName: 文件名（包含扩展名）
    public static func deleteImage(fileName: String) {
        let fileURL = getImageDirectory().appendingPathComponent(fileName)
        logger.info("Deleting image file: \(fileName)")
        
        do {
            try FileManager.default.removeItem(at: fileURL)
            logger.info("Image file deleted successfully: \(fileName)")
        } catch {
            logger.warning("Failed to delete image file \(fileName): \(error.localizedDescription)")
        }
    }
    
    /// 删除会话相关的所有图片文件
    /// - Parameters:
    ///   - messages: 会话中的消息列表
    public static func deleteImageFiles(for messages: [ChatMessage]) {
        let imageFileNames = messages.flatMap { $0.imageFileNames ?? [] }
        for fileName in imageFileNames {
            deleteImage(fileName: fileName)
        }
        if !imageFileNames.isEmpty {
            logger.info("Deleted \(imageFileNames.count) image files for session.")
        }
    }
    
    /// 获取所有图片文件名
    /// - Returns: 图片文件名数组
    public static func getAllImageFileNames() -> [String] {
        let directory = getImageDirectory()
        do {
            let fileURLs = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            return fileURLs.map { $0.lastPathComponent }
        } catch {
            logger.warning("Failed to list image files: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - 通用文件持久化

    /// 获取用于存储文件附件的目录URL
    /// - Returns: 文件附件存储目录的URL路径
    public static func getFileDirectory() -> URL {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        let fileDirectory = paths[0].appendingPathComponent("FileAttachments")
        if !FileManager.default.fileExists(atPath: fileDirectory.path) {
            logger.info("File attachment directory does not exist, creating: \(fileDirectory.path)")
            try? FileManager.default.createDirectory(at: fileDirectory, withIntermediateDirectories: true)
        }
        return fileDirectory
    }

    /// 保存文件数据到文件
    /// - Parameters:
    ///   - data: 文件数据
    ///   - fileName: 文件名（包含扩展名）
    /// - Returns: 保存成功返回文件URL，失败返回nil
    @discardableResult
    public static func saveFile(_ data: Data, fileName: String) -> URL? {
        let fileURL = getFileDirectory().appendingPathComponent(fileName)
        logger.info("Saving file attachment: \(fileName)")
        
        do {
            try data.write(to: fileURL, options: [.atomicWrite, .completeFileProtection])
            logger.info("File attachment saved successfully: \(fileName)")
            return fileURL
        } catch {
            logger.error("Failed to save file attachment \(fileName): \(error.localizedDescription)")
            return nil
        }
    }
    
    /// 加载文件数据
    /// - Parameter fileName: 文件名（包含扩展名）
    /// - Returns: 文件数据，如果文件不存在则返回nil
    public static func loadFile(fileName: String) -> Data? {
        let fileURL = getFileDirectory().appendingPathComponent(fileName)
        logger.info("Loading file attachment: \(fileName)")
        
        do {
            let data = try Data(contentsOf: fileURL)
            logger.info("File attachment loaded successfully: \(fileName)")
            return data
        } catch {
            logger.warning("Failed to load file attachment \(fileName): \(error.localizedDescription)")
            return nil
        }
    }
    
    /// 检查文件是否存在
    /// - Parameter fileName: 文件名（包含扩展名）
    /// - Returns: 文件是否存在
    public static func fileExists(fileName: String) -> Bool {
        let fileURL = getFileDirectory().appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: fileURL.path)
    }
    
    /// 删除指定的文件
    /// - Parameter fileName: 文件名（包含扩展名）
    public static func deleteFile(fileName: String) {
        let fileURL = getFileDirectory().appendingPathComponent(fileName)
        logger.info("Deleting file attachment: \(fileName)")
        
        do {
            try FileManager.default.removeItem(at: fileURL)
            logger.info("File attachment deleted successfully: \(fileName)")
        } catch {
            logger.warning("Failed to delete file attachment \(fileName): \(error.localizedDescription)")
        }
    }
    
    /// 删除会话相关的所有文件附件
    /// - Parameters:
    ///   - messages: 会话中的消息列表
    public static func deleteFileFiles(for messages: [ChatMessage]) {
        let fileNames = messages.flatMap { $0.fileFileNames ?? [] }
        for fileName in fileNames {
            deleteFile(fileName: fileName)
        }
        if !fileNames.isEmpty {
            logger.info("Deleted \(fileNames.count) file attachments for session.")
        }
    }
    
    /// 获取所有文件附件名
    /// - Returns: 文件附件名数组
    public static func getAllFileNames() -> [String] {
        let directory = getFileDirectory()
        do {
            let fileURLs = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            return fileURLs.map { $0.lastPathComponent }
        } catch {
            logger.warning("Failed to list file attachments: \(error.localizedDescription)")
            return []
        }
    }
}
