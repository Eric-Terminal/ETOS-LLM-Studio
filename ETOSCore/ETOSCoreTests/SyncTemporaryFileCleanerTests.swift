// ============================================================================
// SyncTemporaryFileCleanerTests.swift
// ============================================================================
// 同步临时文件清理测试
// ============================================================================

import Foundation
import Testing
@testable import ETOSCore

@Suite("同步临时文件清理测试")
struct SyncTemporaryFileCleanerTests {
    @Test("临时文件写入当前同步临时目录")
    func testMakeFileURLUsesCurrentSessionDirectory() throws {
        let fileManager = FileManager.default
        let sandbox = fileManager.temporaryDirectory
            .appendingPathComponent("sync-temp-cleaner-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: sandbox) }

        let fileURL = try SyncTemporaryFileCleaner.makeFileURL(
            prefix: "sync",
            fileExtension: "json",
            temporaryDirectory: sandbox
        )
        let sessionDirectory = SyncTemporaryFileCleaner.currentSessionDirectoryURL(in: sandbox)

        #expect(fileURL.deletingLastPathComponent() == sessionDirectory)
        #expect(fileURL.lastPathComponent.hasPrefix("sync-"))
        #expect(fileURL.pathExtension == "json")
        #expect(fileManager.fileExists(atPath: sessionDirectory.path))
    }

    @Test("启动清理只删除上次同步临时目录")
    func testCleanupRemovesPreviousSessionDirectories() throws {
        let fileManager = FileManager.default
        let sandbox = fileManager.temporaryDirectory
            .appendingPathComponent("sync-temp-cleaner-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: sandbox) }

        let rootDirectory = SyncTemporaryFileCleaner.rootDirectoryURL(in: sandbox)
        let currentSessionDirectory = SyncTemporaryFileCleaner.currentSessionDirectoryURL(in: sandbox)
        let previousSessionDirectory = rootDirectory.appendingPathComponent("previous-session", isDirectory: true)
        let previousFile = rootDirectory.appendingPathComponent("legacy-sync.json", isDirectory: false)
        let unrelatedDirectory = sandbox.appendingPathComponent("ETOS-Snapshots", isDirectory: true)

        try fileManager.createDirectory(at: currentSessionDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: previousSessionDirectory, withIntermediateDirectories: true)
        try Data("legacy".utf8).write(to: previousFile)
        try fileManager.createDirectory(at: unrelatedDirectory, withIntermediateDirectories: true)

        let removedCount = SyncTemporaryFileCleaner.cleanupResidualTemporaryDirectories(
            temporaryDirectory: sandbox
        )

        #expect(removedCount == 2)
        #expect(fileManager.fileExists(atPath: currentSessionDirectory.path))
        #expect(!fileManager.fileExists(atPath: previousSessionDirectory.path))
        #expect(!fileManager.fileExists(atPath: previousFile.path))
        #expect(fileManager.fileExists(atPath: unrelatedDirectory.path))
    }
}
