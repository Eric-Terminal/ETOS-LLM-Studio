// ============================================================================
// PersistenceMigrationBackupTests.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件负责持久化旧数据迁移、启动备份与恢复相关测试。
// ============================================================================

import Testing
import Foundation
@testable import ETOSCore

extension PersistenceTests {
    @Test("GRDB 启动迁移后自动清理旧 JSON 会话文件")
    func testBootstrapGRDBImportAndCleanupLegacyJSON() throws {
        cleanup(sessions: [])

        let sessionID = UUID()
        let legacySession = ChatSession(id: sessionID, name: "Legacy JSON Session", isTemporary: false)
        let legacyMessages = [
            ChatMessage(role: .user, content: "legacy-user"),
            ChatMessage(role: .assistant, content: "legacy-assistant")
        ]

        let legacySessionsData = try JSONEncoder().encode([legacySession])
        try legacySessionsData.write(to: legacySessionsIndexURL, options: .atomic)

        let legacyMessagesData = try JSONEncoder().encode(legacyMessages)
        try legacyMessagesData.write(to: legacyMessageFileURL(sessionID), options: .atomic)

        let previousOverride = Persistence.grdbEnabledOverrideForTests
        Persistence.grdbEnabledOverrideForTests = true
        Persistence.resetGRDBStoreForTests()
        defer {
            Persistence.grdbEnabledOverrideForTests = previousOverride
            Persistence.resetGRDBStoreForTests()
            cleanup(sessions: [legacySession])
        }

        Persistence.bootstrapGRDBStoreOnLaunch()

        let loadedSessions = Persistence.loadChatSessions()
        #expect(loadedSessions.contains(where: { $0.id == sessionID }))

        let loadedMessages = Persistence.loadMessages(for: sessionID)
        #expect(loadedMessages.map(\.content) == ["legacy-user", "legacy-assistant"])

        #expect(FileManager.default.fileExists(atPath: chatStoreSQLiteURL.path))
        #expect(!FileManager.default.fileExists(atPath: legacySessionsIndexURL.path))
        #expect(!FileManager.default.fileExists(atPath: legacyMessageFileURL(sessionID).path))
    }

    @Test("启动备份会裁剪 chat-store 的 FTS 结构")
    func testLaunchBackupCreatesSlimChatStoreBackup() {
        cleanup(sessions: [])

        let defaults = UserDefaults.standard
        let previousBackupEnabled = defaults.object(forKey: Persistence.launchBackupEnabledKey)
        let previousOverride = Persistence.grdbEnabledOverrideForTests
        let session = ChatSession(id: UUID(), name: "Launch Backup Session", isTemporary: false)
        let messages = [
            ChatMessage(role: .user, content: "launch-backup-user"),
            ChatMessage(role: .assistant, content: "launch-backup-assistant")
        ]

        defaults.set(true, forKey: Persistence.launchBackupEnabledKey)
        Persistence.grdbEnabledOverrideForTests = true
        Persistence.resetGRDBStoreForTests()
        defer {
            if let previousBackupEnabled = previousBackupEnabled as? Bool {
                defaults.set(previousBackupEnabled, forKey: Persistence.launchBackupEnabledKey)
            } else {
                defaults.removeObject(forKey: Persistence.launchBackupEnabledKey)
            }
            Persistence.grdbEnabledOverrideForTests = previousOverride
            Persistence.resetGRDBStoreForTests()
            cleanup(sessions: [session])
        }

        Persistence.saveChatSessions([session])
        Persistence.saveMessages(messages, for: session.id)
        Persistence.bootstrapGRDBStoreOnLaunch()
        Persistence.createLaunchBackupPointIfEnabled()

        #expect(FileManager.default.fileExists(atPath: chatStoreBackupSQLiteURL.path))
        #expect(!sqliteExists(chatStoreBackupSQLiteURL, sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'messages_fts'"))
        #expect(!sqliteExists(chatStoreBackupSQLiteURL, sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger' AND name = 'messages_ai'"))
        #expect(!sqliteExists(chatStoreBackupSQLiteURL, sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger' AND name = 'messages_ad'"))
        #expect(!sqliteExists(chatStoreBackupSQLiteURL, sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger' AND name = 'messages_au'"))
        #expect(sqliteCount(chatStoreBackupSQLiteURL, sql: "SELECT COUNT(*) FROM messages") == messages.count)
    }

    @Test("离线快照会打包三处分库并排除 FTS 与向量库")
    func testSnapshotBuilderCreatesOfflineArchive() throws {
        cleanup(sessions: [])

        let previousOverride = Persistence.grdbEnabledOverrideForTests
        let session = ChatSession(id: UUID(), name: "Snapshot Session", isTemporary: false)
        let messages = [
            ChatMessage(role: .user, content: "snapshot-user"),
            ChatMessage(role: .assistant, content: "snapshot-assistant")
        ]

        Persistence.grdbEnabledOverrideForTests = true
        Persistence.resetGRDBStoreForTests()
        defer {
            Persistence.grdbEnabledOverrideForTests = previousOverride
            Persistence.resetGRDBStoreForTests()
            cleanup(sessions: [session])
        }

        Persistence.saveChatSessions([session])
        Persistence.saveMessages(messages, for: session.id)
        #expect(Persistence.saveAuxiliaryBlob(["theme": "dark"], forKey: "providers_v1"))
        try ConversationMemoryManager.saveUserProfile(
            content: "偏好离线快照。",
            sourceSessionID: session.id
        )

        let result = try SnapshotBuilder.buildSnapshotResult()
        defer { removeIfExists(result.fileURL) }

        #expect(result.backupKind == .database)
        #expect(Set(result.includedDatabaseNames) == ["chat-store.sqlite", "config-store.sqlite", "memory-store.sqlite"])
        #expect(result.includedFilePaths.isEmpty)
    }

    @Test("完整快照会打包用户文件并可恢复")
    func testFullSnapshotIncludesAndRestoresUserFiles() throws {
        cleanup(sessions: [])

        let previousOverride = Persistence.grdbEnabledOverrideForTests
        let session = ChatSession(id: UUID(), name: "Full Snapshot Session", isTemporary: false)
        let backgroundURL = documentsDirectory
            .appendingPathComponent("Backgrounds", isDirectory: true)
            .appendingPathComponent("full-snapshot-bg.png", isDirectory: false)
        let imageURL = documentsDirectory
            .appendingPathComponent("ImageFiles", isDirectory: true)
            .appendingPathComponent("full-snapshot-image.png", isDirectory: false)
        let fileURL = documentsDirectory
            .appendingPathComponent("FileAttachments", isDirectory: true)
            .appendingPathComponent("full-snapshot-note.txt", isDirectory: false)
        let vectorURL = memoryDirectory.appendingPathComponent("memory_vectors.sqlite", isDirectory: false)

        Persistence.grdbEnabledOverrideForTests = true
        Persistence.resetGRDBStoreForTests()
        defer {
            Persistence.grdbEnabledOverrideForTests = previousOverride
            Persistence.resetGRDBStoreForTests()
            cleanup(sessions: [session])
            removeIfExists(backgroundURL)
            removeIfExists(imageURL)
            removeIfExists(fileURL)
            removeIfExists(vectorURL)
        }

        Persistence.saveChatSessions([session])
        Persistence.saveMessages([ChatMessage(role: .user, content: "full-snapshot")], for: session.id)
        try FileManager.default.createDirectory(
            at: backgroundURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: imageURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: vectorURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("background-data".utf8).write(to: backgroundURL, options: .atomic)
        try Data("image-data".utf8).write(to: imageURL, options: .atomic)
        try Data("file-data".utf8).write(to: fileURL, options: .atomic)
        try Data("vector-data".utf8).write(to: vectorURL, options: .atomic)

        let result = try SnapshotBuilder.buildSnapshotResult(kind: .full)
        let snapshotURL = result.fileURL
        defer { removeIfExists(snapshotURL) }

        let filePaths = Set(result.includedFilePaths)
        #expect(result.backupKind == .full)
        #expect(filePaths.contains("Backgrounds/full-snapshot-bg.png"))
        #expect(filePaths.contains("ImageFiles/full-snapshot-image.png"))
        #expect(filePaths.contains("FileAttachments/full-snapshot-note.txt"))
        #expect(filePaths.contains("Memory/memory_vectors.sqlite"))

        try Data("changed".utf8).write(to: backgroundURL, options: .atomic)
        try FileManager.default.removeItem(at: imageURL)
        try FileManager.default.removeItem(at: fileURL)
        try FileManager.default.removeItem(at: vectorURL)

        try SnapshotRestoreService.restorePlainSnapshot(from: snapshotURL)

        #expect(try Data(contentsOf: backgroundURL) == Data("background-data".utf8))
        #expect(try Data(contentsOf: imageURL) == Data("image-data".utf8))
        #expect(try Data(contentsOf: fileURL) == Data("file-data".utf8))
        #expect(try Data(contentsOf: vectorURL) == Data("vector-data".utf8))
    }

    @Test("数据库物理加密可在三处分库间启用并关闭")
    @MainActor
    func testDatabaseEncryptionMigrationRoundTrip() throws {
        cleanup(sessions: [])

        let previousOverride = Persistence.grdbEnabledOverrideForTests
        let previousEncryptionEnabled = AppConfigStore.shared.databaseEncryptionEnabled
        let session = ChatSession(id: UUID(), name: "SQLCipher Migration", isTemporary: false)

        Persistence.grdbEnabledOverrideForTests = true
        Persistence.resetGRDBStoreForTests()
        defer {
            try? DatabaseEncryptionManager.shared.deletePassphraseWithoutVerification()
            AppConfigStore.shared.databaseEncryptionEnabled = previousEncryptionEnabled
            Persistence.grdbEnabledOverrideForTests = previousOverride
            Persistence.resetGRDBStoreForTests()
            cleanup(sessions: [session])
        }

        Persistence.saveChatSessions([session])
        Persistence.saveMessages([ChatMessage(role: .user, content: "encrypt me")], for: session.id)
        #expect(Persistence.saveAuxiliaryBlob(["provider": "local"], forKey: "providers_v1"))
        try ConversationMemoryManager.saveUserProfile(
            content: "SQLCipher profile",
            sourceSessionID: session.id
        )

        try Persistence.setDatabaseEncryptionEnabled(
            passphrase: "database-passphrase",
            confirmation: "database-passphrase"
        )

        #expect(Persistence.isDatabaseHealthy(at: chatStoreSQLiteURL, encrypted: true))
        #expect(Persistence.isDatabaseHealthy(at: configStoreSQLiteURL, encrypted: true))
        #expect(Persistence.isDatabaseHealthy(at: memoryStoreSQLiteURL, encrypted: true))
        #expect(!Persistence.isDatabaseHealthy(at: chatStoreSQLiteURL, encrypted: false))
        #expect(Persistence.loadMessages(for: session.id).first?.content == "encrypt me")
        let encryptedTables = try StorageBrowserSupport.listSQLiteTables(at: chatStoreSQLiteURL)
        #expect(encryptedTables.contains(where: { $0.name == "messages" }))
        let encryptedPage = try StorageBrowserSupport.querySQLitePage(
            at: chatStoreSQLiteURL,
            sql: "SELECT content FROM messages WHERE session_id = '\(session.id.uuidString)'",
            pageIndex: 0,
            pageSize: 10
        )
        #expect(encryptedPage.rows.first?.cells.first?.value == "encrypt me")

        let queryResult = try AppToolManager.querySQLite(
            in: .chat,
            sql: "SELECT content FROM messages WHERE session_id = ?",
            parameters: [.string(session.id.uuidString)],
            maxRows: 10
        )
        let queryRows = queryResult["rows"] as? [[String: Any]] ?? []
        #expect(queryRows.first?["content"] as? String == "encrypt me")

        let updateResult = try AppToolManager.mutateSQLite(
            in: .chat,
            sql: "UPDATE messages SET content = ?, content_versions_json = CAST(? AS BLOB) WHERE session_id = ? AND content = ?",
            parameters: [
                .string("tool-updated"),
                .string("[\"tool-updated\"]"),
                .string(session.id.uuidString),
                .string("encrypt me")
            ],
            allowWithoutWhere: false,
            returningMaxRows: 10
        )
        #expect((updateResult["affectedRows"] as? Int) == 1)
        #expect(Persistence.loadMessages(for: session.id).first?.content == "tool-updated")

        try Persistence.disableDatabaseEncryption(passphrase: "database-passphrase")

        #expect(Persistence.isDatabaseHealthy(at: chatStoreSQLiteURL, encrypted: false))
        #expect(Persistence.isDatabaseHealthy(at: configStoreSQLiteURL, encrypted: false))
        #expect(Persistence.isDatabaseHealthy(at: memoryStoreSQLiteURL, encrypted: false))
        #expect(Persistence.loadMessages(for: session.id).first?.content == "tool-updated")
    }

    @Test("明文离线快照可以恢复三处分库")
    func testSnapshotRestoreInstallsOfflineArchive() throws {
        cleanup(sessions: [])

        let previousOverride = Persistence.grdbEnabledOverrideForTests
        let snapshotSession = ChatSession(id: UUID(), name: "Snapshot Restore Source", isTemporary: false)
        let replacementSession = ChatSession(id: UUID(), name: "Snapshot Restore Target", isTemporary: false)

        Persistence.grdbEnabledOverrideForTests = true
        Persistence.resetGRDBStoreForTests()
        defer {
            Persistence.grdbEnabledOverrideForTests = previousOverride
            Persistence.resetGRDBStoreForTests()
            cleanup(sessions: [snapshotSession, replacementSession])
        }

        Persistence.saveChatSessions([snapshotSession])
        Persistence.saveMessages([ChatMessage(role: .user, content: "snapshot-restore-source")], for: snapshotSession.id)
        #expect(Persistence.saveAuxiliaryBlob(["value": "snapshot"], forKey: "providers_v1"))
        try ConversationMemoryManager.saveUserProfile(
            content: "恢复源用户画像",
            sourceSessionID: snapshotSession.id
        )

        let snapshotURL = try SnapshotBuilder.buildSnapshot()
        defer { removeIfExists(snapshotURL) }
        #expect(try SnapshotRestoreService.inspectSnapshot(at: snapshotURL).encryptionMode == nil)

        Persistence.saveChatSessions([replacementSession])
        Persistence.saveMessages([ChatMessage(role: .assistant, content: "snapshot-restore-target")], for: replacementSession.id)
        #expect(Persistence.saveAuxiliaryBlob(["value": "target"], forKey: "providers_v1"))
        try ConversationMemoryManager.saveUserProfile(
            content: "恢复前用户画像",
            sourceSessionID: replacementSession.id
        )

        try SnapshotRestoreService.restorePlainSnapshot(from: snapshotURL)

        let restoredSessions = Persistence.loadChatSessions()
        #expect(restoredSessions.contains(where: { $0.id == snapshotSession.id }))
        #expect(!restoredSessions.contains(where: { $0.id == replacementSession.id }))
        #expect(Persistence.loadMessages(for: snapshotSession.id).map(\.content) == ["snapshot-restore-source"])
        #expect(sqliteCount(chatStoreSQLiteURL, sql: "SELECT COUNT(*) FROM messages_fts") == 1)
        let restoredProviderBlob = Persistence.loadAuxiliaryBlob([String: String].self, forKey: "providers_v1")
        #expect(restoredProviderBlob?["value"] == "snapshot")
        let restoredProfile = ConversationMemoryManager.loadUserProfile()
        #expect(restoredProfile?.content == "恢复源用户画像")
        #expect(restoredProfile?.sourceSessionID == snapshotSession.id)
    }

    @Test("数据库物理加密开启时恢复快照会保持三处分库加密")
    @MainActor
    func testSnapshotRestoreKeepsEncryptedDatabasesWhenDatabaseEncryptionIsEnabled() throws {
        cleanup(sessions: [])

        let previousOverride = Persistence.grdbEnabledOverrideForTests
        let previousEncryptionEnabled = AppConfigStore.shared.databaseEncryptionEnabled
        let snapshotSession = ChatSession(id: UUID(), name: "Encrypted Restore Source", isTemporary: false)
        let replacementSession = ChatSession(id: UUID(), name: "Encrypted Restore Target", isTemporary: false)

        Persistence.grdbEnabledOverrideForTests = true
        Persistence.resetGRDBStoreForTests()
        try? DatabaseEncryptionManager.shared.deletePassphraseWithoutVerification()
        AppConfigStore.shared.databaseEncryptionEnabled = false
        defer {
            if DatabaseEncryptionManager.shared.hasStoredPassphrase {
                try? Persistence.disableDatabaseEncryption(passphrase: "database-passphrase")
            }
            try? DatabaseEncryptionManager.shared.deletePassphraseWithoutVerification()
            AppConfigStore.shared.databaseEncryptionEnabled = previousEncryptionEnabled
            Persistence.grdbEnabledOverrideForTests = previousOverride
            Persistence.resetGRDBStoreForTests()
            cleanup(sessions: [snapshotSession, replacementSession])
        }

        Persistence.saveChatSessions([snapshotSession])
        Persistence.saveMessages([ChatMessage(role: .user, content: "encrypted-restore-source")], for: snapshotSession.id)
        #expect(Persistence.saveAuxiliaryBlob(["value": "snapshot"], forKey: "providers_v1"))
        try ConversationMemoryManager.saveUserProfile(
            content: "加密恢复源用户画像",
            sourceSessionID: snapshotSession.id
        )

        let snapshotURL = try SnapshotBuilder.buildSnapshot()
        defer { removeIfExists(snapshotURL) }

        Persistence.saveChatSessions([replacementSession])
        Persistence.saveMessages([ChatMessage(role: .assistant, content: "encrypted-restore-target")], for: replacementSession.id)
        #expect(Persistence.saveAuxiliaryBlob(["value": "target"], forKey: "providers_v1"))
        try ConversationMemoryManager.saveUserProfile(
            content: "加密恢复前用户画像",
            sourceSessionID: replacementSession.id
        )

        try Persistence.setDatabaseEncryptionEnabled(
            passphrase: "database-passphrase",
            confirmation: "database-passphrase"
        )

        try SnapshotRestoreService.restorePlainSnapshot(from: snapshotURL)

        #expect(DatabaseEncryptionManager.shared.hasStoredPassphrase)
        #expect(Persistence.readAppConfigInteger(key: AppConfigKey.databaseEncryptionEnabled.rawValue) == 1)
        #expect(Persistence.isDatabaseHealthy(at: chatStoreSQLiteURL, encrypted: true))
        #expect(Persistence.isDatabaseHealthy(at: configStoreSQLiteURL, encrypted: true))
        #expect(Persistence.isDatabaseHealthy(at: memoryStoreSQLiteURL, encrypted: true))
        #expect(!Persistence.isDatabaseHealthy(at: chatStoreSQLiteURL, encrypted: false))
        #expect(!Persistence.isDatabaseHealthy(at: configStoreSQLiteURL, encrypted: false))
        #expect(!Persistence.isDatabaseHealthy(at: memoryStoreSQLiteURL, encrypted: false))

        let restoredSessions = Persistence.loadChatSessions()
        #expect(restoredSessions.contains(where: { $0.id == snapshotSession.id }))
        #expect(!restoredSessions.contains(where: { $0.id == replacementSession.id }))
        #expect(Persistence.loadMessages(for: snapshotSession.id).map(\.content) == ["encrypted-restore-source"])
        let restoredProviderBlob = Persistence.loadAuxiliaryBlob([String: String].self, forKey: "providers_v1")
        #expect(restoredProviderBlob?["value"] == "snapshot")
        let restoredProfile = ConversationMemoryManager.loadUserProfile()
        #expect(restoredProfile?.content == "加密恢复源用户画像")
        #expect(restoredProfile?.sourceSessionID == snapshotSession.id)
    }

    @Test("简单密码快照加密会写入 ELS1 头并可解密")
    func testSnapshotEncryptorSimplePasswordRoundTrip() throws {
        let plainData = Data("snapshot-plain-payload".utf8)
        let encryptedData = try SnapshotEncryptor.encryptSimplePassword(data: plainData, password: "simple-pass")

        #expect(encryptedData.prefix(4) == Data([0x45, 0x4C, 0x53, 0x31]))
        #expect(encryptedData[4] == SnapshotEncryptor.Mode.simplePassword.rawValue)
        #expect(encryptedData.count == 5 + SnapshotEncryptor.nonceByteCount + plainData.count + SnapshotEncryptor.tagByteCount)
        #expect(try SnapshotEncryptor.encryptedMode(for: encryptedData) == .simplePassword)
        #expect(try SnapshotEncryptor.decrypt(data: encryptedData, password: "simple-pass") == plainData)
        #expect(throws: Error.self) {
            try SnapshotEncryptor.decrypt(data: encryptedData, password: "wrong-pass")
        }
    }

    @Test("加密离线快照可用简单密码恢复")
    func testEncryptedSnapshotRestoreWithSimplePassword() throws {
        cleanup(sessions: [])

        let previousOverride = Persistence.grdbEnabledOverrideForTests
        let snapshotSession = ChatSession(id: UUID(), name: "Encrypted Snapshot Source", isTemporary: false)
        let replacementSession = ChatSession(id: UUID(), name: "Encrypted Snapshot Target", isTemporary: false)

        Persistence.grdbEnabledOverrideForTests = true
        Persistence.resetGRDBStoreForTests()
        defer {
            Persistence.grdbEnabledOverrideForTests = previousOverride
            Persistence.resetGRDBStoreForTests()
            cleanup(sessions: [snapshotSession, replacementSession])
        }

        Persistence.saveChatSessions([snapshotSession])
        Persistence.saveMessages([ChatMessage(role: .user, content: "encrypted-snapshot-source")], for: snapshotSession.id)
        let snapshotURL = try SnapshotBuilder.buildSnapshot()
        defer { removeIfExists(snapshotURL) }

        let encryptedData = try SnapshotEncryptor.encryptSimplePassword(
            data: Data(contentsOf: snapshotURL),
            password: "snapshot-pass"
        )
        try encryptedData.write(to: snapshotURL, options: .atomic)
        #expect(try SnapshotRestoreService.inspectSnapshot(at: snapshotURL).encryptionMode == .simplePassword)

        Persistence.saveChatSessions([replacementSession])
        Persistence.saveMessages([ChatMessage(role: .assistant, content: "encrypted-snapshot-target")], for: replacementSession.id)

        #expect(throws: Error.self) {
            try SnapshotRestoreService.restoreSnapshot(from: snapshotURL, password: nil)
        }
        #expect(Persistence.loadChatSessions().contains(where: { $0.id == replacementSession.id }))

        #expect(throws: Error.self) {
            try SnapshotRestoreService.restoreSnapshot(from: snapshotURL, password: "bad-pass")
        }
        #expect(Persistence.loadChatSessions().contains(where: { $0.id == replacementSession.id }))

        try SnapshotRestoreService.restoreSnapshot(from: snapshotURL, password: "snapshot-pass")

        let restoredSessions = Persistence.loadChatSessions()
        #expect(restoredSessions.contains(where: { $0.id == snapshotSession.id }))
        #expect(!restoredSessions.contains(where: { $0.id == replacementSession.id }))
        #expect(Persistence.loadMessages(for: snapshotSession.id).map(\.content) == ["encrypted-snapshot-source"])
    }

    @Test("高强度密码快照加密使用 PBKDF2 模式并可恢复")
    func testSnapshotEncryptorStrongPasswordRoundTripAndRestore() throws {
        cleanup(sessions: [])

        let plainData = Data("snapshot-strong-payload".utf8)
        let encryptedData = try SnapshotEncryptor.encryptStrongPassword(data: plainData, password: "strong-pass")
        #expect(encryptedData.prefix(4) == Data([0x45, 0x4C, 0x53, 0x31]))
        #expect(encryptedData[4] == SnapshotEncryptor.Mode.pbkdf2Strong.rawValue)
        #expect(encryptedData.count == 5 + SnapshotEncryptor.nonceByteCount + plainData.count + SnapshotEncryptor.tagByteCount)
        #expect(try SnapshotEncryptor.encryptedMode(for: encryptedData) == .pbkdf2Strong)
        #expect(try SnapshotEncryptor.decrypt(data: encryptedData, password: "strong-pass") == plainData)
        #expect(throws: Error.self) {
            try SnapshotEncryptor.decrypt(data: encryptedData, password: "bad-pass")
        }

        let previousOverride = Persistence.grdbEnabledOverrideForTests
        let snapshotSession = ChatSession(id: UUID(), name: "Strong Snapshot Source", isTemporary: false)
        let replacementSession = ChatSession(id: UUID(), name: "Strong Snapshot Target", isTemporary: false)

        Persistence.grdbEnabledOverrideForTests = true
        Persistence.resetGRDBStoreForTests()
        defer {
            Persistence.grdbEnabledOverrideForTests = previousOverride
            Persistence.resetGRDBStoreForTests()
            cleanup(sessions: [snapshotSession, replacementSession])
        }

        Persistence.saveChatSessions([snapshotSession])
        Persistence.saveMessages([ChatMessage(role: .user, content: "strong-snapshot-source")], for: snapshotSession.id)
        let snapshotURL = try SnapshotBuilder.buildSnapshot()
        defer { removeIfExists(snapshotURL) }

        let encryptedSnapshotData = try SnapshotEncryptor.encryptStrongPassword(
            data: Data(contentsOf: snapshotURL),
            password: "strong-snapshot-pass"
        )
        try encryptedSnapshotData.write(to: snapshotURL, options: .atomic)
        #expect(try SnapshotRestoreService.inspectSnapshot(at: snapshotURL).encryptionMode == .pbkdf2Strong)

        Persistence.saveChatSessions([replacementSession])
        Persistence.saveMessages([ChatMessage(role: .assistant, content: "strong-snapshot-target")], for: replacementSession.id)

        try SnapshotRestoreService.restoreSnapshot(from: snapshotURL, password: "strong-snapshot-pass")

        let restoredSessions = Persistence.loadChatSessions()
        #expect(restoredSessions.contains(where: { $0.id == snapshotSession.id }))
        #expect(!restoredSessions.contains(where: { $0.id == replacementSession.id }))
        #expect(Persistence.loadMessages(for: snapshotSession.id).map(\.content) == ["strong-snapshot-source"])
    }

    @Test("启动检测到 chat-store 损坏时会按备份重建并重建 FTS")
    func testLaunchBackupRestoresCorruptedChatStoreAndRebuildsFTS() throws {
        cleanup(sessions: [])

        let defaults = UserDefaults.standard
        let previousBackupEnabled = defaults.object(forKey: Persistence.launchBackupEnabledKey)
        let previousOverride = Persistence.grdbEnabledOverrideForTests
        let session = ChatSession(id: UUID(), name: "Corrupted Launch Session", isTemporary: false)
        let messages = [
            ChatMessage(role: .user, content: "recover-user"),
            ChatMessage(role: .assistant, content: "recover-assistant")
        ]

        defaults.set(true, forKey: Persistence.launchBackupEnabledKey)
        Persistence.grdbEnabledOverrideForTests = true
        Persistence.resetGRDBStoreForTests()
        defer {
            if let previousBackupEnabled = previousBackupEnabled as? Bool {
                defaults.set(previousBackupEnabled, forKey: Persistence.launchBackupEnabledKey)
            } else {
                defaults.removeObject(forKey: Persistence.launchBackupEnabledKey)
            }
            Persistence.grdbEnabledOverrideForTests = previousOverride
            Persistence.resetGRDBStoreForTests()
            cleanup(sessions: [session])
        }

        Persistence.saveChatSessions([session])
        Persistence.saveMessages(messages, for: session.id)
        Persistence.bootstrapGRDBStoreOnLaunch()
        Persistence.createLaunchBackupPointIfEnabled()
        #expect(FileManager.default.fileExists(atPath: chatStoreBackupSQLiteURL.path))

        removeIfExists(chatStoreSQLiteWALURL)
        removeIfExists(chatStoreSQLiteSHMURL)
        try Data([0x00, 0x01, 0x02, 0x03, 0x04]).write(to: chatStoreSQLiteURL, options: .atomic)

        Persistence.resetGRDBStoreForTests()
        Persistence.bootstrapGRDBStoreOnLaunch()

        let restoredMessages = Persistence.loadMessages(for: session.id)
        #expect(restoredMessages.map(\.content) == messages.map(\.content))
        let recoveryNotice = Persistence.consumeLaunchRecoveryNotice()
        #expect(recoveryNotice?.contains("聊天数据库") == true)
        #expect(sqliteCount(chatStoreSQLiteURL, sql: "SELECT COUNT(*) FROM messages_fts") == messages.count)
        #expect(sqliteExists(chatStoreSQLiteURL, sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger' AND name = 'messages_ai'"))
        #expect(sqliteExists(chatStoreSQLiteURL, sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger' AND name = 'messages_ad'"))
        #expect(sqliteExists(chatStoreSQLiteURL, sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger' AND name = 'messages_au'"))
    }

    @Test("创建新还原点失败时会保留旧备份")
    func testLaunchBackupKeepsPreviousBackupWhenNewBackupFails() throws {
        cleanup(sessions: [])

        let defaults = UserDefaults.standard
        let previousBackupEnabled = defaults.object(forKey: Persistence.launchBackupEnabledKey)
        let previousOverride = Persistence.grdbEnabledOverrideForTests
        let oldSession = ChatSession(id: UUID(), name: "Old Backup Session", isTemporary: false)
        let oldMessages = [
            ChatMessage(role: .user, content: "stable-old-backup")
        ]
        let newSession = ChatSession(id: UUID(), name: "New Backup Session", isTemporary: false)
        let newMessages = [
            ChatMessage(role: .assistant, content: "should-not-replace-old-backup")
        ]
        var didRestrictBackupDirectory = false

        defaults.set(true, forKey: Persistence.launchBackupEnabledKey)
        Persistence.grdbEnabledOverrideForTests = true
        Persistence.resetGRDBStoreForTests()
        defer {
            if didRestrictBackupDirectory {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o755],
                    ofItemAtPath: chatStoreBackupDirectory.path
                )
            }
            if let previousBackupEnabled = previousBackupEnabled as? Bool {
                defaults.set(previousBackupEnabled, forKey: Persistence.launchBackupEnabledKey)
            } else {
                defaults.removeObject(forKey: Persistence.launchBackupEnabledKey)
            }
            Persistence.grdbEnabledOverrideForTests = previousOverride
            Persistence.resetGRDBStoreForTests()
            cleanup(sessions: [oldSession, newSession])
        }

        Persistence.saveChatSessions([oldSession])
        Persistence.saveMessages(oldMessages, for: oldSession.id)
        Persistence.createLaunchBackupPointIfEnabled()
        #expect(sqliteCount(chatStoreBackupSQLiteURL, sql: "SELECT COUNT(*) FROM messages WHERE content = 'stable-old-backup'") == 1)

        Persistence.saveChatSessions([newSession])
        Persistence.saveMessages(newMessages, for: newSession.id)
        Persistence.resetGRDBStoreForTests()
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555],
            ofItemAtPath: chatStoreBackupDirectory.path
        )
        didRestrictBackupDirectory = true

        Persistence.createLaunchBackupPointIfEnabled()

        #expect(FileManager.default.fileExists(atPath: chatStoreBackupSQLiteURL.path))
        #expect(sqliteCount(chatStoreBackupSQLiteURL, sql: "SELECT COUNT(*) FROM messages WHERE content = 'stable-old-backup'") == 1)
        #expect(sqliteCount(chatStoreBackupSQLiteURL, sql: "SELECT COUNT(*) FROM messages WHERE content = 'should-not-replace-old-backup'") == 0)
    }

    @Test("启动预热不会立即创建还原点")
    func testBootstrapGRDBDoesNotCreateLaunchBackupImmediately() {
        cleanup(sessions: [])

        let defaults = UserDefaults.standard
        let previousBackupEnabled = defaults.object(forKey: Persistence.launchBackupEnabledKey)
        let previousOverride = Persistence.grdbEnabledOverrideForTests
        let session = ChatSession(id: UUID(), name: "Deferred Backup Session", isTemporary: false)
        let messages = [
            ChatMessage(role: .user, content: "deferred-backup-user")
        ]

        defaults.set(true, forKey: Persistence.launchBackupEnabledKey)
        Persistence.grdbEnabledOverrideForTests = true
        Persistence.resetGRDBStoreForTests()
        defer {
            if let previousBackupEnabled = previousBackupEnabled as? Bool {
                defaults.set(previousBackupEnabled, forKey: Persistence.launchBackupEnabledKey)
            } else {
                defaults.removeObject(forKey: Persistence.launchBackupEnabledKey)
            }
            Persistence.grdbEnabledOverrideForTests = previousOverride
            Persistence.resetGRDBStoreForTests()
            cleanup(sessions: [session])
        }

        Persistence.saveChatSessions([session])
        Persistence.saveMessages(messages, for: session.id)
        Persistence.bootstrapGRDBStoreOnLaunch()

        #expect(FileManager.default.fileExists(atPath: chatStoreSQLiteURL.path))
        #expect(!FileManager.default.fileExists(atPath: chatStoreBackupSQLiteURL.path))
    }

    @Test("启动后调度任务会延迟创建还原点")
    func testScheduleLaunchBackupAfterStartupCreatesBackup() async {
        cleanup(sessions: [])

        let defaults = UserDefaults.standard
        let previousBackupEnabled = defaults.object(forKey: Persistence.launchBackupEnabledKey)
        let previousOverride = Persistence.grdbEnabledOverrideForTests
        let session = ChatSession(id: UUID(), name: "Scheduled Backup Session", isTemporary: false)
        let messages = [
            ChatMessage(role: .assistant, content: "scheduled-backup-assistant")
        ]

        defaults.set(true, forKey: Persistence.launchBackupEnabledKey)
        Persistence.grdbEnabledOverrideForTests = true
        Persistence.resetGRDBStoreForTests()
        defer {
            if let previousBackupEnabled = previousBackupEnabled as? Bool {
                defaults.set(previousBackupEnabled, forKey: Persistence.launchBackupEnabledKey)
            } else {
                defaults.removeObject(forKey: Persistence.launchBackupEnabledKey)
            }
            Persistence.grdbEnabledOverrideForTests = previousOverride
            Persistence.resetGRDBStoreForTests()
            cleanup(sessions: [session])
        }

        Persistence.saveChatSessions([session])
        Persistence.saveMessages(messages, for: session.id)
        Persistence.bootstrapGRDBStoreOnLaunch()
        let task = Persistence.scheduleLaunchBackupPointAfterStartupIfEnabled(delay: 0)
        await task?.value

        #expect(FileManager.default.fileExists(atPath: chatStoreBackupSQLiteURL.path))
        #expect(sqliteCount(chatStoreBackupSQLiteURL, sql: "SELECT COUNT(*) FROM messages") == messages.count)
    }
}
