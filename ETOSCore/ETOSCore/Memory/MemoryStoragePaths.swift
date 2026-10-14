// ============================================================================
// MemoryStoragePaths.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责管理长期记忆在沙盒中的目录结构与文件路径。
// 当前设计要求将所有记忆数据集中存放在 Documents/Memory/ 下，
// 其中包含原始记忆（JSON）与向量数据库（SQLite）。
// ============================================================================

import Foundation
import os.log

enum MemoryStoragePaths {
    private static let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "MemoryStoragePaths")
    
    private static let directoryName = "Memory"
    private static let rawFileName = "memories.json"
    private static let userProfileFileName = "user_profile.json"
    private static let mutationHistoryFileName = "mutation_history.json"
    private static let transferReceiptsFileName = "transfer_receipts.json"
    private static let vectorStoreNameValue = "memory_vectors"
    
    @discardableResult
    static func ensureRootDirectory(rootDirectory overrideRootDirectory: URL? = nil) -> URL {
        let rootDirectory = resolvedRootDirectory(rootDirectory: overrideRootDirectory)
        if !FileManager.default.fileExists(atPath: rootDirectory.path) {
            do {
                try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
                logger.info("创建 Memory 根目录: \(rootDirectory.path)")
            } catch {
                logger.error("创建 Memory 根目录失败: \(error.localizedDescription)")
            }
        }
        return rootDirectory
    }
    
    static func rootDirectory(rootDirectory overrideRootDirectory: URL? = nil) -> URL {
        ensureRootDirectory(rootDirectory: overrideRootDirectory)
    }
    
    static func rawMemoriesFileURL(rootDirectory overrideRootDirectory: URL? = nil) -> URL {
        rootDirectory(rootDirectory: overrideRootDirectory).appendingPathComponent(rawFileName, isDirectory: false)
    }

    static func userProfileFileURL(rootDirectory overrideRootDirectory: URL? = nil) -> URL {
        rootDirectory(rootDirectory: overrideRootDirectory).appendingPathComponent(userProfileFileName, isDirectory: false)
    }

    static func mutationHistoryFileURL(rootDirectory overrideRootDirectory: URL? = nil) -> URL {
        rootDirectory(rootDirectory: overrideRootDirectory).appendingPathComponent(mutationHistoryFileName, isDirectory: false)
    }

    static func transferReceiptsFileURL(rootDirectory overrideRootDirectory: URL? = nil) -> URL {
        rootDirectory(rootDirectory: overrideRootDirectory).appendingPathComponent(transferReceiptsFileName, isDirectory: false)
    }
    
    static func vectorStoreDirectory(rootDirectory overrideRootDirectory: URL? = nil) -> URL {
        rootDirectory(rootDirectory: overrideRootDirectory)
    }
    
    static var vectorStoreName: String {
        vectorStoreNameValue
    }

    /// 数据库已经替换后移除原安装的回退文件；完整快照随后会写入自己的向量文件。
    static func clearCachesAfterDatabaseRestore(rootDirectory overrideRootDirectory: URL? = nil) throws {
        let directory = rootDirectory(rootDirectory: overrideRootDirectory)
        let vectorName = "\(vectorStoreNameValue).sqlite"
        let names = [rawFileName, userProfileFileName, mutationHistoryFileName, transferReceiptsFileName,
                     vectorName, vectorName + "-wal", vectorName + "-shm", vectorName + "-journal"]
        for name in names {
            let url = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
    }

    private static func resolvedRootDirectory(rootDirectory overrideRootDirectory: URL?) -> URL {
        if let overrideRootDirectory {
            return overrideRootDirectory
        }
        return StorageUtility.documentsDirectory.appendingPathComponent(directoryName, isDirectory: true)
    }
}
