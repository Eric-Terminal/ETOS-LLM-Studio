// ============================================================================
// ThirdPartyImportETOSTests.swift
// ============================================================================
// ThirdPartyImportService ETOS 数据包导入测试
// - 验证 ETOS 导出信封可解析并保留完整 options
// - 验证兼容旧版纯 SyncPackage JSON
// ============================================================================

import Foundation
import Testing
@testable import ETOSCore

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

    @Test("普通与加密快照均交给完整恢复确认，原始归档不做同步转换")
    func snapshotsRequireFullRestoreConfirmation() async throws {
        let sandbox = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let plain = Data([0x50, 0x4B, 0x03, 0x04]) + Data("归档中的全部数据库与文件".utf8)
        let encrypted = try SnapshotEncryptor.encryptSimplePassword(data: plain, password: "test-password")

        for payload in [plain, encrypted] {
            let file = sandbox.appendingPathComponent("backup.ELSBACKUP")
            try payload.write(to: file)
            do {
                _ = try await ThirdPartyImportService.prepareImportInBackground(source: .etosBackup, fileURL: file)
                Issue.record("数据库快照不应被解析为部分同步包")
            } catch let request as SnapshotRestoreRequest {
                #expect(request.fileURL != file)
                #expect(request.fileURL.lastPathComponent == file.lastPathComponent)
                // 模拟 watchOS 清理下载文件或 iOS 文件选择器结束授权。
                try FileManager.default.removeItem(at: file)
                #expect(try Data(contentsOf: request.fileURL) == payload)
                let inspection = try SnapshotRestoreService.inspectSnapshot(at: request.fileURL)
                #expect(inspection.requiresPassword == (payload == encrypted))
            }
        }
    }

    @Test("从目录选择快照同样进入完整恢复，不绕过确认")
    func snapshotInDirectoryRequiresFullRestore() throws {
        let sandbox = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let file = sandbox.appendingPathComponent("ETOS-Snapshot-directory.elsbackup")
        let content = Data("目录中的快照".utf8)
        try content.write(to: file)

        do {
            _ = try ThirdPartyImportService.prepareImport(source: .etosBackup, fileURL: sandbox)
            Issue.record("目录中的快照不应被解析为部分同步包")
        } catch let request as SnapshotRestoreRequest {
            #expect(try Data(contentsOf: request.fileURL) == content)
        }
    }
}
