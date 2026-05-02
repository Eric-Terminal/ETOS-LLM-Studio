// ============================================================================
// SharedTests+PersistenceLegacyMigration.swift
// ============================================================================
// Persistence 的旧 JSON 导入、启动备份、迁移清理与重复消息修复测试。
// ============================================================================

import Testing
import Foundation
@testable import Shared
import Combine
import SwiftUI
import SQLite3

@Suite("聊天界面架构默认值测试")
extension PersistenceTests {

    @Test("快捷指令在 SQLite 为空时会回退读取 legacy JSON 并补录")
    func testShortcutToolsFallbackToLegacyJSONWhenSQLiteEmpty() throws {
        cleanup(sessions: [])

        let previousOverride = Persistence.grdbEnabledOverrideForTests
        Persistence.grdbEnabledOverrideForTests = true
        Persistence.resetGRDBStoreForTests()
        defer {
            Persistence.grdbEnabledOverrideForTests = previousOverride
            Persistence.resetGRDBStoreForTests()
            cleanup(sessions: [])
        }

        try FileManager.default.createDirectory(at: shortcutToolsDirectory, withIntermediateDirectories: true)

        let legacyTools = [
            ShortcutToolDefinition(
                id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                name: "legacy-shortcut-tool",
                metadata: ["displayName": .string("Legacy Tool")],
                source: "legacy-json",
                runModeHint: .bridge,
                isEnabled: true,
                generatedDescription: "legacy tool description",
                createdAt: Date(timeIntervalSince1970: 1_710_000_100),
                updatedAt: Date(timeIntervalSince1970: 1_710_000_100),
                lastImportedAt: Date(timeIntervalSince1970: 1_710_000_100)
            )
        ]
        let legacyData = try JSONEncoder().encode(legacyTools)
        try legacyData.write(to: shortcutToolsFileURL, options: .atomic)

        let loaded = ShortcutToolStore.loadTools()
        #expect(loaded.map(\.id) == legacyTools.map(\.id))
        #expect(loaded.map(\.name) == legacyTools.map(\.name))

        #expect(sqliteCount(configStoreSQLiteURL, sql: "SELECT COUNT(*) FROM shortcut_tools") == legacyTools.count)
        #expect(!FileManager.default.fileExists(atPath: shortcutToolsFileURL.path))
    }

    @Test("用户画像在 SQLite 为空时会回退读取 legacy JSON 并补录")
    func testConversationProfileFallbackToLegacyJSONWhenSQLiteEmpty() throws {
        cleanup(sessions: [])

        let previousOverride = Persistence.grdbEnabledOverrideForTests
        Persistence.grdbEnabledOverrideForTests = true
        Persistence.resetGRDBStoreForTests()
        defer {
            Persistence.grdbEnabledOverrideForTests = previousOverride
            Persistence.resetGRDBStoreForTests()
            cleanup(sessions: [])
        }

        try FileManager.default.createDirectory(at: memoryDirectory, withIntermediateDirectories: true)

        let legacyProfile = ConversationUserProfile(
            content: "legacy-user-profile",
            updatedAt: Date(timeIntervalSince1970: 1_710_000_200),
            sourceSessionID: UUID(uuidString: "33333333-3333-3333-3333-333333333333")
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let profileData = try encoder.encode(legacyProfile)
        try profileData.write(to: memoryUserProfileFileURL, options: .atomic)

        let loaded = ConversationMemoryManager.loadUserProfile()
        #expect(loaded?.content == legacyProfile.content)
        #expect(loaded?.updatedAt == legacyProfile.updatedAt)
        #expect(loaded?.sourceSessionID == legacyProfile.sourceSessionID)

        #expect(sqliteCount(memoryStoreSQLiteURL, sql: "SELECT COUNT(*) FROM conversation_user_profile") == 1)
        #expect(!FileManager.default.fileExists(atPath: memoryUserProfileFileURL.path))
    }

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

    @Test("旧 JSON 快照消息为零且数据库已有消息时不会覆盖与清理")
    func testBootstrapGRDBSkipsZeroMessageSnapshotWhenDatabaseHasMessages() throws {
        cleanup(sessions: [])

        let sessionID = UUID()
        let persistedSession = ChatSession(id: sessionID, name: "Persisted Session", isTemporary: false)
        let persistedMessages = [
            ChatMessage(role: .user, content: "db-user"),
            ChatMessage(role: .assistant, content: "db-assistant")
        ]

        let previousOverride = Persistence.grdbEnabledOverrideForTests
        Persistence.grdbEnabledOverrideForTests = true
        Persistence.resetGRDBStoreForTests()
        defer {
            Persistence.grdbEnabledOverrideForTests = previousOverride
            Persistence.resetGRDBStoreForTests()
            cleanup(sessions: [persistedSession])
        }

        Persistence.saveChatSessions([persistedSession])
        Persistence.saveMessages(persistedMessages, for: sessionID)

        let legacySessionsData = try JSONEncoder().encode([persistedSession])
        try legacySessionsData.write(to: legacySessionsIndexURL, options: .atomic)
        let emptyLegacyMessagesData = try JSONEncoder().encode([ChatMessage]())
        try emptyLegacyMessagesData.write(to: legacyMessageFileURL(sessionID), options: .atomic)

        Persistence.resetGRDBStoreForTests()
        Persistence.bootstrapGRDBStoreOnLaunch()

        let loadedMessages = Persistence.loadMessages(for: sessionID)
        #expect(loadedMessages.map(\.content) == persistedMessages.map(\.content))
        #expect(FileManager.default.fileExists(atPath: legacySessionsIndexURL.path))
        #expect(FileManager.default.fileExists(atPath: legacyMessageFileURL(sessionID).path))
    }

    @Test("旧 JSON 快照有消息且数据库已有消息时不会触发覆盖导入")
    func testBootstrapGRDBSkipsImportWhenDatabaseAlreadyHasMessages() throws {
        cleanup(sessions: [])

        let sessionID = UUID()
        let persistedSession = ChatSession(id: sessionID, name: "Persisted Session", isTemporary: false)
        let persistedMessages = [
            ChatMessage(role: .user, content: "db-user"),
            ChatMessage(role: .assistant, content: "db-assistant")
        ]
        let legacyMessages = [
            ChatMessage(role: .user, content: "legacy-user")
        ]

        let previousOverride = Persistence.grdbEnabledOverrideForTests
        Persistence.grdbEnabledOverrideForTests = true
        Persistence.resetGRDBStoreForTests()
        defer {
            Persistence.grdbEnabledOverrideForTests = previousOverride
            Persistence.resetGRDBStoreForTests()
            cleanup(sessions: [persistedSession])
        }

        Persistence.saveChatSessions([persistedSession])
        Persistence.saveMessages(persistedMessages, for: sessionID)

        let legacySessionsData = try JSONEncoder().encode([persistedSession])
        try legacySessionsData.write(to: legacySessionsIndexURL, options: .atomic)
        let legacyMessagesData = try JSONEncoder().encode(legacyMessages)
        try legacyMessagesData.write(to: legacyMessageFileURL(sessionID), options: .atomic)

        Persistence.resetGRDBStoreForTests()
        Persistence.bootstrapGRDBStoreOnLaunch()

        let loadedMessages = Persistence.loadMessages(for: sessionID)
        #expect(loadedMessages.map(\.content) == persistedMessages.map(\.content))
        #expect(FileManager.default.fileExists(atPath: legacySessionsIndexURL.path))
        #expect(FileManager.default.fileExists(atPath: legacyMessageFileURL(sessionID).path))
    }

    @Test("旧 JSON 快照已导入但缺少标记时会自动清理遗留 JSON")
    func testBootstrapGRDBCleansLegacyJSONWhenSnapshotAlreadyImportedWithoutMeta() throws {
        cleanup(sessions: [])

        let sessionID = UUID()
        let persistedSession = ChatSession(id: sessionID, name: "Persisted Session", isTemporary: false)
        let persistedMessages = [
            ChatMessage(role: .user, content: "db-user"),
            ChatMessage(role: .assistant, content: "db-assistant")
        ]

        let previousOverride = Persistence.grdbEnabledOverrideForTests
        Persistence.grdbEnabledOverrideForTests = true
        Persistence.resetGRDBStoreForTests()
        defer {
            Persistence.grdbEnabledOverrideForTests = previousOverride
            Persistence.resetGRDBStoreForTests()
            cleanup(sessions: [persistedSession])
        }

        Persistence.saveChatSessions([persistedSession])
        Persistence.saveMessages(persistedMessages, for: sessionID)

        let legacySessionsData = try JSONEncoder().encode([persistedSession])
        try legacySessionsData.write(to: legacySessionsIndexURL, options: .atomic)
        let legacyMessagesData = try JSONEncoder().encode(persistedMessages)
        try legacyMessagesData.write(to: legacyMessageFileURL(sessionID), options: .atomic)

        sqliteExecute(
            chatStoreSQLiteURL,
            sql: """
            DELETE FROM meta
            WHERE key IN ('json_import_completed', 'json_cleanup_completed', 'json_import_completed_v1', 'json_cleanup_completed_v1')
            """
        )
        #expect(sqliteCount(chatStoreSQLiteURL, sql: "SELECT COUNT(*) FROM meta WHERE key = 'json_import_completed'") == 0)
        #expect(sqliteCount(chatStoreSQLiteURL, sql: "SELECT COUNT(*) FROM meta WHERE key = 'json_cleanup_completed'") == 0)

        Persistence.resetGRDBStoreForTests()
        Persistence.bootstrapGRDBStoreOnLaunch()

        let loadedMessages = Persistence.loadMessages(for: sessionID)
        #expect(loadedMessages.map(\.content) == persistedMessages.map(\.content))
        #expect(!FileManager.default.fileExists(atPath: legacySessionsIndexURL.path))
        #expect(!FileManager.default.fileExists(atPath: legacyMessageFileURL(sessionID).path))
        #expect(sqliteCount(chatStoreSQLiteURL, sql: "SELECT COUNT(*) FROM meta WHERE key = 'json_import_completed' AND value = '1'") == 1)
        #expect(sqliteCount(chatStoreSQLiteURL, sql: "SELECT COUNT(*) FROM meta WHERE key = 'json_cleanup_completed' AND value = '1'") == 1)
    }

    @Test("跨会话重复消息ID不会阻止 GRDB 启动迁移清理旧 JSON")
    func testBootstrapGRDBMigratesDuplicateMessageIDsAcrossSessions() throws {
        cleanup(sessions: [])

        let duplicatedMessageID = UUID()
        let firstSession = ChatSession(id: UUID(), name: "First Session", isTemporary: false)
        let secondSession = ChatSession(id: UUID(), name: "Second Session", isTemporary: false)

        let firstMessages = [
            ChatMessage(id: duplicatedMessageID, role: .user, content: "first-user"),
            ChatMessage(role: .assistant, content: "first-assistant")
        ]
        let secondMessages = [
            ChatMessage(id: duplicatedMessageID, role: .user, content: "second-user"),
            ChatMessage(role: .assistant, content: "second-assistant")
        ]

        let legacySessionsData = try JSONEncoder().encode([firstSession, secondSession])
        try legacySessionsData.write(to: legacySessionsIndexURL, options: .atomic)
        try JSONEncoder().encode(firstMessages).write(to: legacyMessageFileURL(firstSession.id), options: .atomic)
        try JSONEncoder().encode(secondMessages).write(to: legacyMessageFileURL(secondSession.id), options: .atomic)

        let previousOverride = Persistence.grdbEnabledOverrideForTests
        Persistence.grdbEnabledOverrideForTests = true
        Persistence.resetGRDBStoreForTests()
        defer {
            Persistence.grdbEnabledOverrideForTests = previousOverride
            Persistence.resetGRDBStoreForTests()
            cleanup(sessions: [firstSession, secondSession])
        }

        Persistence.bootstrapGRDBStoreOnLaunch()

        let loadedFirst = Persistence.loadMessages(for: firstSession.id)
        let loadedSecond = Persistence.loadMessages(for: secondSession.id)
        #expect(loadedFirst.map(\.content) == firstMessages.map(\.content))
        #expect(loadedSecond.map(\.content) == secondMessages.map(\.content))
        #expect(sqliteCount(chatStoreSQLiteURL, sql: "SELECT COUNT(*) FROM messages") == firstMessages.count + secondMessages.count)
        #expect(!FileManager.default.fileExists(atPath: legacySessionsIndexURL.path))
        #expect(!FileManager.default.fileExists(atPath: legacyMessageFileURL(firstSession.id).path))
        #expect(!FileManager.default.fileExists(atPath: legacyMessageFileURL(secondSession.id).path))
    }

    @Test("GRDB 在缺失会话索引时不会清理孤立消息 JSON 文件")
    func testBootstrapGRDBKeepsOrphanLegacyMessageJSONWithoutIndex() throws {
        struct LegacyRequestLogEnvelope: Encodable {
            let schemaVersion: Int
            let updatedAt: String
            let logs: [RequestLogEntry]
        }

        cleanup(sessions: [])

        let orphanSessionID = UUID()
        let orphanMessages = [
            ChatMessage(role: .user, content: "orphan-user"),
            ChatMessage(role: .assistant, content: "orphan-assistant")
        ]
        let orphanData = try JSONEncoder().encode(orphanMessages)
        try orphanData.write(to: legacyMessageFileURL(orphanSessionID), options: .atomic)

        try FileManager.default.createDirectory(
            at: requestLogsDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )
        let requestLog = RequestLogEntry(
            requestID: UUID(),
            sessionID: nil,
            providerID: nil,
            providerName: "migration-guard",
            modelID: "guard-model",
            requestedAt: Date(timeIntervalSince1970: 1_700_300_000),
            finishedAt: Date(timeIntervalSince1970: 1_700_300_001),
            isStreaming: false,
            status: .success,
            tokenUsage: nil
        )
        let legacyRequestLogData = try JSONEncoder().encode(
            LegacyRequestLogEnvelope(
                schemaVersion: 1,
                updatedAt: ISO8601DateFormatter().string(from: Date()),
                logs: [requestLog]
            )
        )
        try legacyRequestLogData.write(to: requestLogsDirectory.appendingPathComponent("index.json"), options: .atomic)

        let previousOverride = Persistence.grdbEnabledOverrideForTests
        Persistence.grdbEnabledOverrideForTests = true
        Persistence.resetGRDBStoreForTests()
        defer {
            Persistence.grdbEnabledOverrideForTests = previousOverride
            Persistence.resetGRDBStoreForTests()
            removeIfExists(legacyMessageFileURL(orphanSessionID))
            cleanup(sessions: [])
        }

        Persistence.bootstrapGRDBStoreOnLaunch()

        #expect(FileManager.default.fileExists(atPath: chatStoreSQLiteURL.path))
        #expect(FileManager.default.fileExists(atPath: legacyMessageFileURL(orphanSessionID).path))
    }

    @Test("Migrate Legacy Session Store To Current Layout And Cleanup Legacy Files")
    func testMigrateLegacySessionStoreToCurrentLayoutAndCleanupLegacyFiles() throws {
        let sessionId = UUID()
        let legacySession = ChatSession(
            id: sessionId,
            name: "Legacy Session",
            topicPrompt: "legacy-topic",
            enhancedPrompt: "legacy-enhanced",
            isTemporary: false
        )
        let legacyMessages = [
            ChatMessage(role: .user, content: "legacy-user"),
            ChatMessage(role: .assistant, content: "legacy-assistant")
        ]

        removeIfExists(currentIndexFileURL)
        removeIfExists(currentSessionsDirectory)
        removeIfExists(legacySessionDirectory)
        removeIfExists(legacyRootDirectory)
        removeIfExists(legacySessionsIndexURL)
        removeIfExists(legacyMessageFileURL(sessionId))

        let legacySessionsData = try JSONEncoder().encode([legacySession])
        try legacySessionsData.write(to: legacySessionsIndexURL, options: .atomic)
        let legacyMessagesData = try JSONEncoder().encode(legacyMessages)
        try legacyMessagesData.write(to: legacyMessageFileURL(sessionId), options: .atomic)

        let loadedSessions = Persistence.loadChatSessions()
        #expect(loadedSessions.count == 1)
        #expect(loadedSessions.first?.id == sessionId)
        #expect(loadedSessions.first?.topicPrompt == "legacy-topic")
        #expect(loadedSessions.first?.enhancedPrompt == "legacy-enhanced")

        let loadedMessages = Persistence.loadMessages(for: sessionId)
        #expect(loadedMessages.map(\.content) == ["legacy-user", "legacy-assistant"])

        let migratedFileURL = currentSessionFileURL(sessionId)
        #expect(FileManager.default.fileExists(atPath: migratedFileURL.path))
        let migratedData = try Data(contentsOf: migratedFileURL)
        let record = try JSONDecoder().decode(LegacySessionRecord.self, from: migratedData)
        #expect(record.schemaVersion == 3)
        #expect(record.session.id == sessionId)
        #expect(record.session.name == "Legacy Session")
        #expect(record.prompts.topicPrompt == "legacy-topic")
        #expect(record.prompts.enhancedPrompt == "legacy-enhanced")
        #expect(record.messages.last?.content == "legacy-assistant")

        #expect(!FileManager.default.fileExists(atPath: legacySessionsIndexURL.path))
        #expect(!FileManager.default.fileExists(atPath: legacyMessageFileURL(sessionId).path))
        #expect(!FileManager.default.fileExists(atPath: legacyRootDirectory.path))

        cleanup(sessions: [legacySession])
    }

    @Test("Migrate Legacy Directory To Root Layout And Delete Old Folder")
    func testMigrateLegacyDirectoryToRootLayoutAndDeleteOldFolder() throws {
        struct LegacySessionIndexFile: Encodable {
            struct Item: Encodable {
                let id: UUID
                let name: String
                let updatedAt: String
            }

            let schemaVersion: Int
            let updatedAt: String
            let sessions: [Item]
        }

        struct LegacySessionRecordFile: Encodable {
            struct SessionMeta: Encodable {
                let id: UUID
                let name: String
                let lorebookIDs: [UUID]
            }

            struct Prompts: Encodable {
                let topicPrompt: String?
                let enhancedPrompt: String?
            }

            let schemaVersion: Int
            let session: SessionMeta
            let prompts: Prompts
            let messages: [ChatMessage]
        }

        let sessionId = UUID()
        let sessionName = "Legacy Session"
        let now = ISO8601DateFormatter().string(from: Date())
        let messages = [
            ChatMessage(role: .user, content: "from-legacy-user"),
            ChatMessage(role: .assistant, content: "from-legacy-assistant")
        ]

        removeIfExists(currentIndexFileURL)
        removeIfExists(currentSessionsDirectory)
        removeIfExists(legacySessionDirectory)
        removeIfExists(legacySessionsIndexURL)
        removeIfExists(legacyRootDirectory)
        removeIfExists(legacyMessageFileURL(sessionId))

        try FileManager.default.createDirectory(
            at: legacySessionFileURL(sessionId).deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )

        let index = LegacySessionIndexFile(
            schemaVersion: 3,
            updatedAt: now,
            sessions: [.init(id: sessionId, name: sessionName, updatedAt: now)]
        )
        let indexData = try JSONEncoder().encode(index)
        try indexData.write(to: legacySessionIndexFileURL, options: .atomic)

        let recordData = try JSONEncoder().encode(
            LegacySessionRecordFile(
                schemaVersion: 3,
                session: .init(id: sessionId, name: sessionName, lorebookIDs: []),
                prompts: .init(topicPrompt: nil, enhancedPrompt: nil),
                messages: messages
            )
        )
        try recordData.write(to: legacySessionFileURL(sessionId), options: .atomic)

        let loadedSessions = Persistence.loadChatSessions()
        #expect(loadedSessions.count == 1)
        #expect(loadedSessions.first?.id == sessionId)
        #expect(loadedSessions.first?.name == sessionName)

        let loadedMessages = Persistence.loadMessages(for: sessionId)
        #expect(loadedMessages.map(\.content) == ["from-legacy-user", "from-legacy-assistant"])

        #expect(FileManager.default.fileExists(atPath: currentIndexFileURL.path))
        #expect(FileManager.default.fileExists(atPath: currentSessionFileURL(sessionId).path))
        #expect(!FileManager.default.fileExists(atPath: legacySessionDirectory.path))

        cleanup(sessions: [ChatSession(id: sessionId, name: sessionName, isTemporary: false)])
    }
}
