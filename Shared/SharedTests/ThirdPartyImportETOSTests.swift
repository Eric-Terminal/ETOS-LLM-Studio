// ============================================================================
// ThirdPartyImportETOSTests.swift
// ============================================================================
// ThirdPartyImportService ETOS 数据包导入测试
// - 验证 ETOS 导出信封可解析并保留完整 options
// - 验证兼容旧版纯 SyncPackage JSON
// ============================================================================

import Foundation
import Testing
@testable import Shared

@Suite("导入数据 ETOS 兼容测试")
struct ThirdPartyImportETOSTests {

    @Test("ETOS 导出信封可解析为全量同步包")
    func testPrepareETOSImportFromEnvelope() throws {
        let sandbox = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let provider = Provider(
            id: UUID(),
            name: "ETOS Provider",
            baseURL: "https://api.etos.dev",
            apiKeys: ["etos-key"],
            apiFormat: "openai-compatible",
            models: [Model(modelName: "etos-model", displayName: "ETOS Model", isActivated: true)]
        )
        let snapshot = Data([0x10, 0x20, 0x30])
        let package = SyncPackage(
            options: [.providers, .appStorage],
            providers: [provider],
            appStorageSnapshot: snapshot
        )

        let exported = try SyncPackageTransferService.exportPackage(package)
        let fileURL = sandbox.appendingPathComponent(exported.suggestedFileName)
        try exported.data.write(to: fileURL)

        let prepared = try ThirdPartyImportService.prepareImport(
            source: .etosBackup,
            fileURL: fileURL
        )

        #expect(prepared.package.options.contains(.providers))
        #expect(prepared.package.options.contains(.appStorage))
        #expect(prepared.package.providers.count == 1)
        #expect(prepared.package.providers[0].name == "ETOS Provider")
        #expect(prepared.package.appStorageSnapshot == snapshot)
    }

    @Test("ETOS 导入兼容旧版纯 SyncPackage JSON")
    func testPrepareETOSImportFromLegacyRawSyncPackage() throws {
        let sandbox = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let session = ChatSession(
            id: UUID(),
            name: "ETOS Legacy Session",
            isTemporary: false
        )
        let message = ChatMessage(
            id: UUID(),
            role: .assistant,
            content: "legacy session message"
        )
        let package = SyncPackage(
            options: [.sessions],
            sessions: [SyncedSession(session: session, messages: [message])]
        )

        let data = try JSONEncoder().encode(package)
        let fileURL = sandbox.appendingPathComponent("legacy-sync.json")
        try data.write(to: fileURL)

        let prepared = try ThirdPartyImportService.prepareImport(
            source: .etosBackup,
            fileURL: fileURL
        )

        #expect(prepared.package.options.contains(.sessions))
        #expect(prepared.package.sessions.count == 1)
        #expect(prepared.package.sessions[0].session.name == "ETOS Legacy Session")
    }

    private func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
