// ============================================================================
// SyncTemporaryFileCleaner.swift
// ============================================================================
// ETOS LLM Studio
//
// 管理同步与快照流程中可整包删除的临时目录。
// ============================================================================

import Foundation
import os.log

private let syncTemporaryFileCleanerLogger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "SyncTemporaryFileCleaner")

public enum SyncTemporaryFileCleaner {
    public static let rootDirectoryName = "ETOS-Sync-TemporaryFiles"
    private static let currentSessionDirectoryName = UUID().uuidString

    public static func cleanupResidualTemporaryDirectoriesInBackground() {
        Task.detached(priority: .utility) {
            cleanupResidualTemporaryDirectories()
        }
    }

    @discardableResult
    public static func cleanupResidualTemporaryDirectories(
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        fileManager: FileManager = .default
    ) -> Int {
        let rootDirectory = rootDirectoryURL(in: temporaryDirectory)
        guard fileManager.fileExists(atPath: rootDirectory.path) else {
            return 0
        }

        var removedCount = 0
        let fileURLs = (try? fileManager.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: nil,
            options: []
        )) ?? []

        for fileURL in fileURLs where fileURL.lastPathComponent != currentSessionDirectoryName {
            do {
                try fileManager.removeItem(at: fileURL)
                removedCount += 1
            } catch {
                syncTemporaryFileCleanerLogger.error("清理同步临时目录失败：\(fileURL.lastPathComponent), \(error.localizedDescription)")
            }
        }

        // 只删除上一轮 session 子项，保留根目录，避免后台清理与本次新传输创建目录时互相踩踏。
        if removedCount > 0 {
            syncTemporaryFileCleanerLogger.info("已清理 \(removedCount) 个上次启动残留的同步临时目录。")
        }
        return removedCount
    }

    public static func rootDirectoryURL(
        in temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> URL {
        temporaryDirectory.appendingPathComponent(rootDirectoryName, isDirectory: true)
    }

    public static func currentSessionDirectoryURL(
        in temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> URL {
        rootDirectoryURL(in: temporaryDirectory)
            .appendingPathComponent(currentSessionDirectoryName, isDirectory: true)
    }

    public static func ensureCurrentSessionDirectory(
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        fileManager: FileManager = .default
    ) throws -> URL {
        let directory = currentSessionDirectoryURL(in: temporaryDirectory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    public static func makeFileURL(
        prefix: String,
        fileExtension: String? = nil,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        fileManager: FileManager = .default
    ) throws -> URL {
        var fileName = "\(prefix)-\(UUID().uuidString)"
        if let fileExtension, !fileExtension.isEmpty {
            fileName += ".\(fileExtension)"
        }
        let directory = try ensureCurrentSessionDirectory(
            temporaryDirectory: temporaryDirectory,
            fileManager: fileManager
        )
        return directory.appendingPathComponent(fileName, isDirectory: false)
    }

    public static func makeDirectoryURL(
        prefix: String,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        fileManager: FileManager = .default
    ) throws -> URL {
        let directory = try ensureCurrentSessionDirectory(
            temporaryDirectory: temporaryDirectory,
            fileManager: fileManager
        )
        let itemURL = directory.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: itemURL, withIntermediateDirectories: true)
        return itemURL
    }

}
