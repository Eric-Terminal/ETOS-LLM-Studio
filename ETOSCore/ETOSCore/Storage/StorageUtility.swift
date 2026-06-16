// ============================================================================
// StorageUtility.swift
// ============================================================================
// ETOS LLM Studio - 存储管理工具
//
// 功能特性:
// - 计算各类目录的存储空间占用
// - 列出目录中的文件及其详细信息
// - 检测和清理孤立文件
// - 提供缓存清理功能
// ============================================================================

import Foundation
import os.log

private let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "StorageUtility")

// MARK: - 存储工具类

public enum StorageUtility {
    
    // MARK: - 目录访问
    
    /// 获取 Documents 目录
    public static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    
    /// 获取指定类别的目录 URL
    public static func getDirectory(for category: StorageCategory) -> URL {
        documentsDirectory.appendingPathComponent(category.rawValue)
    }
    
    // MARK: - 大小计算
    
    /// 格式化文件大小
    public static func formatSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        return formatter.string(fromByteCount: bytes)
    }
    
    /// 计算单个文件或目录的大小
    public static func calculateSize(at url: URL) -> Int64 {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return 0
        }
        
        if isDirectory.boolValue {
            return calculateDirectorySize(url)
        } else {
            do {
                let attributes = try fileManager.attributesOfItem(atPath: url.path)
                return attributes[.size] as? Int64 ?? 0
            } catch {
                logger.warning("Failed to get file size: \(error.localizedDescription)")
                return 0
            }
        }
    }
    
    /// 计算目录总大小（递归）
    public static func calculateDirectorySize(_ directoryURL: URL) -> Int64 {
        let fileManager = FileManager.default
        var totalSize: Int64 = 0
        
        guard let enumerator = fileManager.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        
        for case let fileURL as URL in enumerator {
            do {
                let resourceValues = try fileURL.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
                if resourceValues.isDirectory == false {
                    totalSize += Int64(resourceValues.fileSize ?? 0)
                }
            } catch {
                logger.warning("Failed to get size for \(fileURL.path): \(error.localizedDescription)")
            }
        }
        
        return totalSize
    }
    
    /// 获取存储统计信息
    public static func getStorageBreakdown() -> StorageBreakdown {
        var breakdown = StorageBreakdown()
        
        // 计算各类别大小
        for category in StorageCategory.allCases {
            let directory = getDirectory(for: category)
            let size = calculateDirectorySize(directory)
            breakdown.categorySize[category] = size
            breakdown.totalSize += size
        }
        
        // 计算其他文件大小（直接在 Documents 根目录的文件）
        let fileManager = FileManager.default
        do {
            let contents = try fileManager.contentsOfDirectory(
                at: documentsDirectory,
                includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey]
            )
            
            let knownDirectories = Set(StorageCategory.allCases.map { $0.rawValue })
            
            for url in contents {
                let resourceValues = try url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
                if resourceValues.isDirectory == true {
                    if !knownDirectories.contains(url.lastPathComponent) {
                        let size = calculateDirectorySize(url)
                        breakdown.otherSize += size
                        breakdown.totalSize += size
                    }
                } else {
                    let size = Int64(resourceValues.fileSize ?? 0)
                    breakdown.otherSize += size
                    breakdown.totalSize += size
                }
            }
        } catch {
            logger.warning("Failed to scan documents directory: \(error.localizedDescription)")
        }
        
        return breakdown
    }
    
    // MARK: - 文件列表
    
    /// 获取目录中的所有文件（非递归）
    public static func listFiles(in directory: URL) -> [FileItem] {
        let fileManager = FileManager.default
        var items: [FileItem] = []
        
        do {
            let contents = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey]
            )
            
            for url in contents {
                let attributes = try fileManager.attributesOfItem(atPath: url.path)
                let item = FileItem(url: url, attributes: attributes)
                items.append(item)
            }
        } catch {
            logger.warning("Failed to list files in \(directory.path): \(error.localizedDescription)")
        }
        
        return items.sorted { $0.modificationDate > $1.modificationDate }
    }
    
    /// 获取指定类别的文件列表
    public static func listFiles(for category: StorageCategory) -> [FileItem] {
        let directory = getDirectory(for: category)
        return listFiles(in: directory)
    }
    
    /// 获取 Documents 根目录的内容
    public static func listDocumentsRoot() -> [FileItem] {
        return listFiles(in: documentsDirectory)
    }
    
    // MARK: - 文件操作
    
    /// 删除单个文件
    public static func deleteFile(at url: URL) throws {
        logger.info("Deleting file: \(url.path)")
        try FileManager.default.removeItem(at: url)
        invalidateRelatedCaches(for: url)
        logger.info("File deleted successfully: \(url.lastPathComponent)")
    }
    
    /// 批量删除文件
    public static func deleteFiles(_ urls: [URL]) -> (success: Int, failed: Int) {
        var successCount = 0
        var failedCount = 0
        
        for url in urls {
            do {
                try deleteFile(at: url)
                successCount += 1
            } catch {
                logger.error("Failed to delete \(url.path): \(error.localizedDescription)")
                failedCount += 1
            }
        }
        
        return (successCount, failedCount)
    }
    
    /// 清空指定类别的所有文件
    public static func clearCategory(_ category: StorageCategory) throws {
        let directory = getDirectory(for: category)
        let fileManager = FileManager.default
        
        logger.info("Clearing category: \(category.rawValue)")
        
        let contents = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for url in contents {
            try fileManager.removeItem(at: url)
        }

        invalidateRelatedCaches(for: directory)
        
        logger.info("Category cleared: \(category.rawValue)")
    }

    /// 通知共享层某个沙盒文件路径发生了变更，用于刷新相关缓存。
    public static func notifyFilesystemMutation(at url: URL) {
        invalidateRelatedCaches(for: url)
    }
    
    // MARK: - 缓存清理
    
    /// 清理缓存文件（音频和图片文件）
    public static func clearCacheFiles() -> (audioDeleted: Int, imageDeleted: Int) {
        var audioDeleted = 0
        var imageDeleted = 0
        
        // 清理音频缓存
        let audioFiles = listFiles(for: .audio)
        for file in audioFiles {
            do {
                try deleteFile(at: file.url)
                audioDeleted += 1
            } catch {
                logger.error("Failed to delete audio file: \(error.localizedDescription)")
            }
        }
        
        // 清理图片缓存
        let imageFiles = listFiles(for: .images)
        for file in imageFiles {
            do {
                try deleteFile(at: file.url)
                imageDeleted += 1
            } catch {
                logger.error("Failed to delete image file: \(error.localizedDescription)")
            }
        }
        
        return (audioDeleted, imageDeleted)
    }
    
    // MARK: - 孤立文件检测

    /// 查找孤立的音频文件（无消息引用的音频文件）
    public static func findOrphanedAudioFiles() -> [FileItem] {
        let referencedFiles = Persistence.allReferencedAudioFileNames()
        let allAudioFiles = listFiles(for: .audio)
        return allAudioFiles.filter { !referencedFiles.contains($0.name) }
    }

    /// 查找孤立的图片文件（无消息引用的图片文件）
    public static func findOrphanedImageFiles() -> [FileItem] {
        let referencedFiles = Persistence.allReferencedImageFileNames()
        let allImageFiles = listFiles(for: .images)
        return allImageFiles.filter { !referencedFiles.contains($0.name) }
    }
    
    // MARK: - 幽灵会话检测（彩蛋功能）
    
    /// 幽灵会话 - 会话索引存在但对应会话数据文件不存在
    public struct GhostSession: Identifiable {
        public let id: UUID
        public let name: String
        
        public init(id: UUID, name: String) {
            self.id = id
            self.name = name
        }
    }
    
    /// 查找幽灵会话（会话记录存在但无任何消息）
    public static func findGhostSessions() -> [GhostSession] {
        let ghostIDs = Persistence.sessionIDsWithoutMessageData()
        guard !ghostIDs.isEmpty else { return [] }

        let sessions = Persistence.loadChatSessions()
        let sessionsByID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })

        return ghostIDs.compactMap { id in
            guard let session = sessionsByID[id] else { return nil }
            return GhostSession(id: id, name: session.name)
        }
    }

    /// 清理幽灵会话，返回被清理的会话数量
    public static func cleanupGhostSessions() -> Int {
        let ghostSessions = findGhostSessions()
        guard !ghostSessions.isEmpty else { return 0 }

        var allSessions = Persistence.loadChatSessions()
        let ghostIDs = Set(ghostSessions.map(\.id))
        allSessions.removeAll { ghostIDs.contains($0.id) }
        Persistence.saveChatSessions(allSessions)

        logger.info("Cleaned up \(ghostSessions.count) ghost sessions")
        return ghostSessions.count
    }
    
    /// 获取关于幽灵会话的趣味消息（彩蛋文本）
    public static func getGhostSessionEasterEggMessage(count: Int) -> String {
        switch count {
        case 0:
            return NSLocalizedString("👻 一切正常！没有发现幽灵会话。", comment: "")
        case 1:
            return NSLocalizedString("👻 发现 1 个幽灵会话！看起来有人删除了消息文件但忘记清理会话记录了...", comment: "")
        case 2...5:
            return String(
                format: NSLocalizedString("👻 发现 %d 个幽灵会话在四处游荡！它们的消息文件已经不在了，但记录还留着呢。", comment: ""),
                locale: Locale.current,
                count
            )
        case 6...10:
            return String(
                format: NSLocalizedString("👻 哇！%d 个幽灵会话！这里简直像是会话墓地。要不要驱个鬼？", comment: ""),
                locale: Locale.current,
                count
            )
        default:
            return String(
                format: NSLocalizedString("👻👻👻 天呐！发现了 %d 个幽灵会话！这里已经闹鬼了！建议立即清理。", comment: ""),
                locale: Locale.current,
                count
            )
        }
    }
    
    /// 清理所有孤立文件
    public static func cleanupOrphanedFiles() -> (audioDeleted: Int, imageDeleted: Int) {
        let orphanedAudio = findOrphanedAudioFiles()
        let orphanedImages = findOrphanedImageFiles()
        
        var audioDeleted = 0
        var imageDeleted = 0
        
        for file in orphanedAudio {
            do {
                try deleteFile(at: file.url)
                audioDeleted += 1
            } catch {
                logger.error("Failed to delete orphaned audio: \(error.localizedDescription)")
            }
        }
        
        for file in orphanedImages {
            do {
                try deleteFile(at: file.url)
                imageDeleted += 1
            } catch {
                logger.error("Failed to delete orphaned image: \(error.localizedDescription)")
            }
        }
        
        logger.info("Cleaned up \(audioDeleted) orphaned audio and \(imageDeleted) orphaned image files")
        return (audioDeleted, imageDeleted)
    }
    
    // MARK: - 无效音频引用检测
    
    /// 无效音频引用 - 消息中引用了不存在的音频文件
    public struct OrphanedAudioReference: Identifiable {
        public let id: UUID
        public let sessionID: UUID
        public let sessionName: String
        public let messageID: UUID
        public let missingFile: String
        
        public init(sessionID: UUID, sessionName: String, messageID: UUID, missingFile: String) {
            self.id = UUID()
            self.sessionID = sessionID
            self.sessionName = sessionName
            self.messageID = messageID
            self.missingFile = missingFile
        }
    }
    
    /// 查找消息中引用但文件不存在的音频
    public static func findOrphanedAudioReferences() -> [OrphanedAudioReference] {
        let audioDirectory = getDirectory(for: .audio)
        let fileManager = FileManager.default
        let allRefs = Persistence.allAudioReferencesWithSessionInfo()

        return allRefs.compactMap { ref in
            let audioFileURL = audioDirectory.appendingPathComponent(ref.audioFileName)
            guard !fileManager.fileExists(atPath: audioFileURL.path) else { return nil }
            return OrphanedAudioReference(
                sessionID: ref.sessionID,
                sessionName: ref.sessionName,
                messageID: ref.messageID,
                missingFile: ref.audioFileName
            )
        }
    }

    /// 清理消息中的无效音频引用，返回清理的引用数量
    public static func cleanupOrphanedAudioReferences() -> Int {
        let orphanedRefs = findOrphanedAudioReferences()
        guard !orphanedRefs.isEmpty else { return 0 }

        let messageIDs = orphanedRefs.map(\.messageID)
        Persistence.clearAudioFileNames(messageIDs: messageIDs)

        logger.info("Cleaned up \(orphanedRefs.count) orphaned audio references")
        return orphanedRefs.count
    }
    
    // MARK: - 统一清理
    
    /// 清理摘要
    public struct CleanupSummary {
        public let ghostSessionsCleaned: Int
        public let orphanedAudioFilesCleaned: Int
        public let orphanedImageFilesCleaned: Int
        public let orphanedAudioReferencesCleaned: Int
        
        public var totalCleaned: Int {
            ghostSessionsCleaned + orphanedAudioFilesCleaned + orphanedImageFilesCleaned + orphanedAudioReferencesCleaned
        }
        
        public var description: String {
            var parts: [String] = []
            if ghostSessionsCleaned > 0 {
                parts.append("\(ghostSessionsCleaned) 个幽灵会话")
            }
            if orphanedAudioFilesCleaned > 0 {
                parts.append("\(orphanedAudioFilesCleaned) 个孤立音频")
            }
            if orphanedImageFilesCleaned > 0 {
                parts.append("\(orphanedImageFilesCleaned) 个孤立图片")
            }
            if orphanedAudioReferencesCleaned > 0 {
                parts.append("\(orphanedAudioReferencesCleaned) 个无效音频引用")
            }
            return parts.isEmpty ? "没有需要清理的内容" : parts.joined(separator: "、")
        }
    }
    
    /// 统一清理所有孤立数据
    public static func cleanupAllOrphans() -> CleanupSummary {
        let ghostSessions = cleanupGhostSessions()
        let (audioFiles, imageFiles) = cleanupOrphanedFiles()
        let audioRefs = cleanupOrphanedAudioReferences()
        
        let summary = CleanupSummary(
            ghostSessionsCleaned: ghostSessions,
            orphanedAudioFilesCleaned: audioFiles,
            orphanedImageFilesCleaned: imageFiles,
            orphanedAudioReferencesCleaned: audioRefs
        )
        
        logger.info("统一清理完成: \(summary.description)")
        return summary
    }
    
    /// 检测所有孤立数据的数量
    public struct OrphanedDataCount {
        public let ghostSessions: Int
        public let orphanedAudioFiles: Int
        public let orphanedImageFiles: Int
        public let orphanedAudioReferences: Int
        
        public init(ghostSessions: Int = 0, orphanedAudioFiles: Int = 0, orphanedImageFiles: Int = 0, orphanedAudioReferences: Int = 0) {
            self.ghostSessions = ghostSessions
            self.orphanedAudioFiles = orphanedAudioFiles
            self.orphanedImageFiles = orphanedImageFiles
            self.orphanedAudioReferences = orphanedAudioReferences
        }
        
        public var total: Int {
            ghostSessions + orphanedAudioFiles + orphanedImageFiles + orphanedAudioReferences
        }
        
        public var description: String {
            var parts: [String] = []
            if ghostSessions > 0 {
                parts.append("\(ghostSessions) 个幽灵会话")
            }
            if orphanedAudioFiles > 0 {
                parts.append("\(orphanedAudioFiles) 个孤立音频")
            }
            if orphanedImageFiles > 0 {
                parts.append("\(orphanedImageFiles) 个孤立图片")
            }
            if orphanedAudioReferences > 0 {
                parts.append("\(orphanedAudioReferences) 个无效音频引用")
            }
            return parts.isEmpty ? "无孤立数据" : parts.joined(separator: "、")
        }
    }
    
    /// 统计所有孤立数据的数量（不执行清理）
    public static func countAllOrphanedData() -> OrphanedDataCount {
        return OrphanedDataCount(
            ghostSessions: findGhostSessions().count,
            orphanedAudioFiles: findOrphanedAudioFiles().count,
            orphanedImageFiles: findOrphanedImageFiles().count,
            orphanedAudioReferences: findOrphanedAudioReferences().count
        )
    }
    
    // MARK: - JSON 文件预览
    
    /// 读取 JSON 文件内容（用于预览）
    public static func readJSONFile(at url: URL) -> String? {
        do {
            let data = try Data(contentsOf: url)
            let jsonObject = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            if JSONSerialization.isValidJSONObject(jsonObject) {
                let prettyData = try JSONSerialization.data(withJSONObject: jsonObject, options: [.prettyPrinted, .sortedKeys])
                return String(data: prettyData, encoding: .utf8)
            }
            return String(data: data, encoding: .utf8)
        } catch {
            logger.warning("Failed to read JSON file: \(error.localizedDescription)")
            return nil
        }
    }

    private static func invalidateRelatedCaches(for url: URL) {
        let worldbookDirectory = getDirectory(for: .worldbooks).standardizedFileURL.path
        let skillDirectory = getDirectory(for: .skills).standardizedFileURL.path
        let targetPath = url.standardizedFileURL.path
        let isWorldbookPath = targetPath == worldbookDirectory || targetPath.hasPrefix(worldbookDirectory + "/")
        let isSkillPath = targetPath == skillDirectory || targetPath.hasPrefix(skillDirectory + "/")

        if isWorldbookPath {
            WorldbookStore.shared.invalidateCache()
        }
        if isSkillPath {
            Task { @MainActor in
                SkillManager.shared.reloadFromDisk()
            }
        }
    }
}
