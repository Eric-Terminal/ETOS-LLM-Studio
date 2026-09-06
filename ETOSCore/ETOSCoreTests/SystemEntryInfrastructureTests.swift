// ============================================================================
// SystemEntryInfrastructureTests.swift
// ============================================================================

import Foundation
import Testing
@testable import ETOSCore

@Suite("系统入口基础设施测试", .serialized)
struct SystemEntryInfrastructureTests {
    @Test("回复完成通知在前台静默且保留会话路由")
    func chatReplyNotificationForegroundPolicy() {
        let sessionID = UUID()
        let userInfo = AppLocalNotificationCenter.chatReplyFinishedUserInfo(sessionID: sessionID)

        #expect(AppLocalNotificationCenter.notificationTargetsChatSession(userInfo: userInfo))
        #expect(!AppLocalNotificationCenter.notificationShouldPresentWhileForeground(userInfo: userInfo))
        #expect(AppLocalNotificationCenter.notificationShouldPresentWhileForeground(userInfo: [:]))
    }

    @Test("工作区路径拒绝越界与保留目录")
    func workspacePathBoundary() throws {
        #expect(try ETOSSharedWorkspacePathValidator.components(for: "Shared/项目/资料.txt") == ["Shared", "项目", "资料.txt"])
        #expect(try ETOSSharedWorkspacePathValidator.components(for: "Exports/result.json") == ["Exports", "result.json"])
        #expect(throws: Error.self) {
            _ = try ETOSSharedWorkspacePathValidator.components(for: "Shared/../Inbox/request.json")
        }
        #expect(throws: Error.self) {
            _ = try ETOSSharedWorkspacePathValidator.components(for: "Inbox/request.json")
        }
        #expect(throws: Error.self) {
            _ = try ETOSSharedWorkspacePathValidator.fileName("../secret.txt")
        }
    }

    @Test("共享快照写入原子文件并限制公开条目数量")
    func sharedSnapshotRoundTrip() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = ETOSSharedStorageLayout(container: root)
        try layout.prepare()
        let runs = (0..<8).map { index in
            ETOSRunSnapshot(
                id: UUID(),
                sessionID: UUID(),
                title: String(repeating: "任", count: 120),
                status: .running,
                startedAt: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }
        let sessions = (0..<16).map { index in
            ETOSSessionSummary(id: UUID(), name: "会话 \(index)")
        }
        let snapshot = ETOSWidgetSnapshot(recentRuns: runs, recentSessions: sessions)
        let destination = layout.runSnapshots.appendingPathComponent("widget.json")

        try ETOSSharedFileStore.write(snapshot, to: destination)
        let restored = try ETOSSharedFileStore.read(ETOSWidgetSnapshot.self, from: destination)

        #expect(restored.recentRuns.count == 5)
        #expect(restored.recentSessions.count == 10)
        #expect(restored.recentRuns.allSatisfy { $0.title.count == 80 })
        #expect(throws: Error.self) {
            _ = try ETOSSharedFileStore.read(ETOSWidgetSnapshot.self, from: destination, maximumBytes: 1)
        }
    }

    @Test("分享收件箱整包发布并对重复请求保持幂等")
    func shareInboxCommitIsAtomicAndIdempotent() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = ETOSSharedStorageLayout(container: root)
        let requestID = UUID()
        let payloads = [
            ETOSInboxPayloadItem(
                item: ETOSInboxItem(kind: .text, displayName: "说明", text: "请整理附件", byteCount: 18),
                data: nil
            ),
            ETOSInboxPayloadItem(
                item: ETOSInboxItem(kind: .file, displayName: "../资料.txt", byteCount: 4),
                data: Data("data".utf8)
            )
        ]

        let first = try ETOSInboxStore.persist(
            payloads: payloads,
            mode: .agent,
            preferredSessionID: nil,
            requestID: requestID,
            layout: layout
        )
        let duplicate = try ETOSInboxStore.persist(
            payloads: payloads,
            mode: .agent,
            preferredSessionID: nil,
            requestID: requestID,
            layout: layout
        )
        let restored = try ETOSInboxStore.load(requestID: requestID, layout: layout)
        let relativePath = try #require(restored.items.last?.relativeFilePath)

        #expect(first == duplicate)
        #expect(restored == first)
        #expect(relativePath == "\(requestID.uuidString)/2-资料.txt")
        #expect(FileManager.default.fileExists(
            atPath: layout.inbox.appendingPathComponent(relativePath).path
        ))
        #expect((try? FileManager.default.contentsOfDirectory(atPath: layout.staging.path))?.isEmpty == true)
    }

    @Test("外部请求回执只能领取一次并保留首次会话")
    func systemEntryReceiptIsIdempotent() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try PersistenceGRDBStore(chatsDirectory: root)
        let requestID = UUID()
        let firstSessionID = UUID()

        #expect(try store.claimSystemEntryRequest(id: requestID, kind: .appIntent))
        #expect(try !store.claimSystemEntryRequest(id: requestID, kind: .appIntent))
        try store.saveSystemEntryReceipt(
            ETOSSystemEntryReceipt(id: requestID, kind: .appIntent, sessionID: firstSessionID)
        )
        try store.saveSystemEntryReceipt(
            ETOSSystemEntryReceipt(id: requestID, kind: .appIntent, sessionID: UUID())
        )

        let loadedReceipt = try store.loadSystemEntryReceipt(id: requestID)
        let receipt = try #require(loadedReceipt)
        #expect(receipt.sessionID == firstSessionID)
        #expect(receipt.kind == .appIntent)
    }

    @Test("旧 Linux 共享目录迁移到 App Group 且可重复调用")
    func legacyLinuxDirectoryMigration() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let documents = root.appendingPathComponent("Documents", isDirectory: true)
        let sharedLayout = ETOSSharedStorageLayout(
            container: root.appendingPathComponent("AppGroup", isDirectory: true)
        )
        let layout = LocalLinuxStorageLayout(
            documentsDirectory: documents,
            sharedDirectory: sharedLayout.shared,
            exportsDirectory: sharedLayout.exports
        )
        try FileManager.default.createDirectory(
            at: layout.legacyShared.appendingPathComponent("nested", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: layout.legacyShared.appendingPathComponent("资料.bundle", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: layout.legacyExports, withIntermediateDirectories: true)
        try Data("shared".utf8).write(to: layout.legacyShared.appendingPathComponent("nested/data.txt"))
        try Data("hidden".utf8).write(to: layout.legacyShared.appendingPathComponent(".metadata"))
        try Data("package".utf8).write(to: layout.legacyShared.appendingPathComponent("资料.bundle/content.json"))
        try Data("export".utf8).write(to: layout.legacyExports.appendingPathComponent("result.txt"))

        try ETOSAppGroupStorageMigrator.migrateLegacyLinuxDirectories(
            layout: layout,
            sharedLayout: sharedLayout
        )
        try ETOSAppGroupStorageMigrator.migrateLegacyLinuxDirectories(
            layout: layout,
            sharedLayout: sharedLayout
        )

        #expect(!FileManager.default.fileExists(atPath: layout.legacyShared.path))
        #expect(!FileManager.default.fileExists(atPath: layout.legacyExports.path))
        #expect(FileManager.default.fileExists(atPath: sharedLayout.shared.appendingPathComponent("nested/data.txt").path))
        #expect(FileManager.default.fileExists(atPath: sharedLayout.shared.appendingPathComponent(".metadata").path))
        #expect(FileManager.default.fileExists(
            atPath: sharedLayout.shared.appendingPathComponent("资料.bundle/content.json").path
        ))
        #expect(FileManager.default.fileExists(atPath: sharedLayout.exports.appendingPathComponent("result.txt").path))
        #expect(FileManager.default.fileExists(
            atPath: sharedLayout.receipts.appendingPathComponent("linux-shared-migration-v1.json").path
        ))
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("etos-system-entry-tests-\(UUID().uuidString)", isDirectory: true)
    }
}
