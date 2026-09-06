// ============================================================================
// SyncPackageTransferServiceTests.swift
// ============================================================================
// SyncPackageTransferService 导出编解码测试
// - 验证 ETOS 导出信封可正确往返
// - 验证旧版纯 SyncPackage JSON 已不再支持
// ============================================================================

import Foundation
import Testing
@testable import ETOSCore

@Suite("同步数据包导出编解码测试")
struct SyncPackageTransferServiceTests {

    @Test("ETOS 导出信封可还原完整同步包")
    func testEncodeAndDecodeEnvelope() throws {
        let provider = Provider(
            id: UUID(),
            name: "导出测试提供商",
            baseURL: "https://example.com",
            apiKeys: ["export-key"],
            apiFormat: "openai-compatible",
            models: [Model(modelName: "test-model", displayName: "Test Model", isActivated: true)]
        )
        let snapshot = Data([0x01, 0x23, 0x45, 0x67])
        let profile = ConversationUserProfile(
            content: "用户偏好跨端同步稳定性。",
            updatedAt: Date(timeIntervalSince1970: 1_700_000_010),
            needsLLMDedup: true
        )
        let package = SyncPackage(
            options: [.providers, .memories, .appStorage],
            sourcePlatform: "watchOS",
            providers: [provider],
            conversationUserProfile: profile,
            appStorageSnapshot: snapshot
        )

        let exported = try SyncPackageTransferService.exportPackage(
            package,
            exportedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let decoded = try SyncPackageTransferService.decodePackage(from: exported.data)
        let envelope = try SyncPackageTransferService.decodeEnvelope(from: exported.data)

        #expect(exported.suggestedFileName.hasPrefix("ETOS-数据导出-"))
        #expect(envelope.schemaVersion == SyncPackageTransferService.currentSchemaVersion)
        #expect(envelope.delta.options == package.options)
        #expect(decoded.options == package.options)
        #expect(decoded.sourcePlatform == "watchOS")
        #expect(decoded.providers.count == 1)
        #expect(decoded.providers[0].apiKeys == ["export-key"])
        #expect(decoded.conversationUserProfile == profile)
        #expect(decoded.appStorageSnapshot == snapshot)
    }

    @Test("ETOS 导出信封可直接写入文件并解码")
    func testExportEnvelopeToFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sync-export-file-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let package = SyncPackage(
            options: [.backgrounds, .appStorage],
            backgrounds: [
                SyncedBackground(filename: "background.png", data: Data([0x01, 0x02, 0x03]))
            ],
            appStorageSnapshot: Data([0x04, 0x05, 0x06])
        )

        let exported = try SyncPackageTransferService.exportPackageToFile(
            package,
            destinationDirectory: directory,
            exportedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let decoded = try SyncPackageTransferService.decodePackage(
            from: Data(contentsOf: exported.fileURL)
        )

        #expect(FileManager.default.fileExists(atPath: exported.fileURL.path))
        #expect(exported.suggestedFileName.hasPrefix("ETOS-数据导出-"))
        #expect(decoded.backgrounds.count == 1)
        #expect(decoded.backgrounds[0].data == Data([0x01, 0x02, 0x03]))
        #expect(decoded.appStorageSnapshot == Data([0x04, 0x05, 0x06]))
    }

    @Test("导出清单按设置键生成独立记录")
    func testExportManifestContainsOneRecordPerAppConfigKey() throws {
        let keys = [
            AppConfigKey.systemPrompt.rawValue,
            AppConfigKey.appToolsChatToolsEnabled.rawValue
        ]
        let snapshot = SyncEngine.encodeAppStorageSnapshot([
            keys[0]: "提示词",
            keys[1]: true
        ])
        let package = SyncPackage(
            options: [.appStorage],
            appStorageSnapshot: snapshot
        )

        let exported = try SyncPackageTransferService.exportPackage(package)
        let envelope = try SyncPackageTransferService.decodeEnvelope(from: exported.data)
        let appConfigRecords = envelope.manifest.records.filter { $0.type == .appStorage }

        #expect(Set(appConfigRecords.map(\.recordID)) == Set(keys))
    }

    @Test("清理临时导出文件只删除过期 ETOS 导出包")
    func testCleanupTemporaryExportFilesRemovesOnlyStaleExports() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
        let staleURL = temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-ETOS-数据导出-stale.json")
        let freshURL = temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-ETOS-数据导出-fresh.json")
        let unrelatedURL = temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-other.json")
        defer {
            try? FileManager.default.removeItem(at: staleURL)
            try? FileManager.default.removeItem(at: freshURL)
            try? FileManager.default.removeItem(at: unrelatedURL)
        }

        try Data("stale".utf8).write(to: staleURL)
        try Data("fresh".utf8).write(to: freshURL)
        try Data("other".utf8).write(to: unrelatedURL)
        let now = Date(timeIntervalSince1970: 2_000)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 0)],
            ofItemAtPath: staleURL.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: now],
            ofItemAtPath: freshURL.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 0)],
            ofItemAtPath: unrelatedURL.path
        )

        SyncPackageTransferService.cleanupTemporaryExportFiles(olderThan: 60, now: now)

        #expect(!FileManager.default.fileExists(atPath: staleURL.path))
        #expect(FileManager.default.fileExists(atPath: freshURL.path))
        #expect(FileManager.default.fileExists(atPath: unrelatedURL.path))
    }

    @Test("旧版纯 SyncPackage JSON 仍可兼容导入")
    func testDecodeLegacyRawSyncPackageJSON() throws {
        let session = ChatSession(
            id: UUID(),
            name: "旧版会话",
            isTemporary: false
        )
        let message = ChatMessage(
            id: UUID(),
            role: .user,
            content: "legacy message"
        )
        let package = SyncPackage(
            options: [.sessions],
            sessions: [SyncedSession(session: session, messages: [message])]
        )

        let legacyData = try JSONEncoder().encode(package)
        let decoded = try SyncPackageTransferService.decodePackage(from: legacyData)

        #expect(decoded.sessions.first?.session.id == session.id)
        #expect(decoded.sessions.first?.messages.first?.id == message.id)
    }
}
