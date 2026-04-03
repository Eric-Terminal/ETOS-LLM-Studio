// ============================================================================
// ConfigLoaderDownloadOnceStateTests.swift
// ============================================================================
// ConfigLoaderDownloadOnceStateTests 测试文件
// - 覆盖 download_once 完成标记读写
// - 覆盖下载文件有效性判定
// ============================================================================

import Testing
import Foundation
@testable import Shared

@Suite("ConfigLoader download_once 状态测试")
struct ConfigLoaderDownloadOnceStateTests {

    @Test("完成标记仅在显式设置后为 true")
    func testDownloadOnceCompletionFlagRoundTrip() {
        let suiteName = "ConfigLoaderDownloadOnceStateTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("无法创建测试用 UserDefaults 套件")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(ConfigLoader.isDownloadOnceCompleted(defaults: defaults) == false)

        ConfigLoader.setDownloadOnceCompleted(true, defaults: defaults)
        #expect(ConfigLoader.isDownloadOnceCompleted(defaults: defaults) == true)

        ConfigLoader.setDownloadOnceCompleted(false, defaults: defaults)
        #expect(ConfigLoader.isDownloadOnceCompleted(defaults: defaults) == false)
    }

    @Test("仅非空文件会被视为已下载完成")
    func testDownloadOnceFileReadinessCheck() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("ConfigLoaderDownloadOnceStateTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        defer { try? fileManager.removeItem(at: directory) }

        let missingFile = directory.appendingPathComponent("missing.bin")
        let emptyFile = directory.appendingPathComponent("empty.bin")
        let validFile = directory.appendingPathComponent("valid.bin")

        _ = fileManager.createFile(atPath: emptyFile.path, contents: Data(), attributes: nil)
        try Data([0x01, 0x02, 0x03]).write(to: validFile, options: .atomic)

        #expect(ConfigLoader.isDownloadOnceFileReady(at: missingFile, fileManager: fileManager) == false)
        #expect(ConfigLoader.isDownloadOnceFileReady(at: emptyFile, fileManager: fileManager) == false)
        #expect(ConfigLoader.isDownloadOnceFileReady(at: validFile, fileManager: fileManager) == true)
    }
}
