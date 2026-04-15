// ============================================================================
// SyncPackageTransferServiceTests.swift
// ============================================================================
// SyncPackageTransferService 导出编解码测试
// - 验证 ETOS 导出信封可正确往返
// - 验证旧版纯 SyncPackage JSON 已不再支持
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
        let envelope = try SyncPackageTransferService.decodeEnvelope(from: exported.data)

        #expect(exported.suggestedFileName.hasPrefix("ETOS-数据导出-"))
        #expect(envelope.schemaVersion == SyncPackageTransferService.currentSchemaVersion)
        #expect(envelope.delta.options == package.options)
        #expect(decoded.options == package.options)
        #expect(decoded.providers.count == 1)
        #expect(decoded.providers[0].apiKeys == ["export-key"])
        #expect(decoded.appStorageSnapshot == snapshot)
    }

    @Test("旧版纯 SyncPackage JSON 会被拒绝")
    func testDecodeLegacyRawSyncPackageJSONThrowsInvalidEnvelope() throws {
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
        do {
            _ = try SyncPackageTransferService.decodePackage(from: legacyData)
            Issue.record("旧版纯 SyncPackage JSON 应该被拒绝")
        } catch let error as SyncPackageTransferError {
            switch error {
            case .invalidEnvelope:
                #expect(Bool(true))
            default:
                Issue.record("抛出了错误类型，但不是 invalidEnvelope：\(error.localizedDescription)")
            }
        } catch {
            Issue.record("抛出了非预期错误：\(error.localizedDescription)")
        }
    }
}
