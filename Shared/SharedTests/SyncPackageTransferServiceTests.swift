// ============================================================================
// SyncPackageTransferServiceTests.swift
// ============================================================================
// SyncPackageTransferService 导出编解码测试
// - 验证 ETOS 导出信封可正确往返
// - 验证兼容旧版纯 SyncPackage JSON
// ============================================================================

import Foundation
import Testing
@testable import Shared

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
        let package = SyncPackage(
            options: [.providers, .appStorage],
            providers: [provider],
            appStorageSnapshot: snapshot
        )

        let exported = try SyncPackageTransferService.exportPackage(
            package,
            exportedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let decoded = try SyncPackageTransferService.decodePackage(from: exported.data)

        #expect(exported.suggestedFileName.hasPrefix("ETOS-数据导出-"))
        #expect(decoded.options == package.options)
        #expect(decoded.providers.count == 1)
        #expect(decoded.providers[0].apiKeys == ["export-key"])
        #expect(decoded.appStorageSnapshot == snapshot)
    }

    @Test("兼容旧版纯 SyncPackage JSON")
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

        #expect(decoded.options.contains(.sessions))
        #expect(decoded.sessions.count == 1)
        #expect(decoded.sessions[0].session.name == "旧版会话")
        #expect(decoded.sessions[0].messages.map(\.content) == ["legacy message"])
    }
}
