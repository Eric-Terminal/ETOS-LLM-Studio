// ============================================================================
// Persistence.swift
// ============================================================================
// ETOS LLM Studio Watch App 数据持久化文件
//
// 功能特性:
// - 提供保存和加载聊天会话列表的功能
// - 提供保存和加载单个会话消息记录的功能
// - 管理文件系统中的存储路径
// ============================================================================

import Foundation
import os.log
import SQLite3
import GRDB
#if canImport(CoreText)
import CoreText
#endif

private let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "Persistence")

enum RelationalJSONValueCodec {
    struct EncodedValue {
        let type: String
        let stringValue: String?
        let numberValue: Double?
        let boolValue: Int?
        let jsonValueText: String?
    }

    static func encode(_ value: JSONValue) -> EncodedValue {
        switch value {
        case .string(let value):
            return EncodedValue(type: "string", stringValue: value, numberValue: nil, boolValue: nil, jsonValueText: nil)
        case .int(let value):
            return EncodedValue(type: "int", stringValue: nil, numberValue: Double(value), boolValue: nil, jsonValueText: nil)
        case .double(let value):
            return EncodedValue(type: "double", stringValue: nil, numberValue: value, boolValue: nil, jsonValueText: nil)
        case .bool(let value):
            return EncodedValue(type: "bool", stringValue: nil, numberValue: nil, boolValue: value ? 1 : 0, jsonValueText: nil)
        case .null:
            return EncodedValue(type: "null", stringValue: nil, numberValue: nil, boolValue: nil, jsonValueText: nil)
        case .array, .dictionary:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let jsonText = (try? String(data: encoder.encode(value), encoding: .utf8)) ?? "null"
            return EncodedValue(type: "json", stringValue: nil, numberValue: nil, boolValue: nil, jsonValueText: jsonText)
        }
    }

    static func decode(
        type: String,
        stringValue: String?,
        numberValue: Double?,
        boolValue: Int?,
        jsonValueText: String?
    ) -> JSONValue {
        switch type {
        case "string":
            return .string(stringValue ?? "")
        case "int":
            return .int(Int(numberValue ?? 0))
        case "double":
            return .double(numberValue ?? 0)
        case "bool":
            return .bool((boolValue ?? 0) != 0)
        case "null":
            return .null
        case "json":
            guard let jsonValueText,
                  let data = jsonValueText.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode(JSONValue.self, from: data) else {
                return .null
            }
            return decoded
        default:
            return .null
        }
    }
}

enum RelationalFloatArrayCodec {
    static func encode(_ values: [Float]) -> Data {
        let copiedValues = values
        return copiedValues.withUnsafeBytes { Data($0) }
    }

    static func decode(_ data: Data) -> [Float] {
        let stride = MemoryLayout<Float>.stride
        guard data.count % stride == 0 else { return [] }
        let count = data.count / stride
        var values = Array(repeating: Float.zero, count: count)
        _ = values.withUnsafeMutableBytes { buffer in
            data.copyBytes(to: buffer)
        }
        return values
    }
}

public enum Persistence {
    private static let sessionStoreSchemaVersion = 3
    private static let sessionFoldersFileSchemaVersion = 1
    private static let messagesFileSchemaVersion = 2
    private static let requestLogSchemaVersion = 1
    private static let defaultRequestLogRetentionLimit = 10_000
    private static let migrationLogPrefix = "[(迁移)]"
    private static let compatibilityReminderPrefix = "[(迁移)][兼容提醒]"
    private static let compatibilityReminderLock = NSLock()
    private static let requestLogLock = NSLock()
    private static let grdbStoreLock = NSLock()
    private static var cachedGRDBStore: PersistenceGRDBStore?
    private static var lastGRDBStoreInitializationFailedAt: Date?
    private static let grdbStoreRetryInterval: TimeInterval = 2
    private static let auxiliaryStoreLock = NSLock()
    private static var cachedAuxiliaryStores: [AuxiliaryStoreKind: PersistenceAuxiliaryGRDBStore] = [:]
    private static var lastAuxiliaryStoreInitializationFailedAt: [AuxiliaryStoreKind: Date] = [:]
    private static let auxiliaryStoreRetryInterval: TimeInterval = 2
    private static let auxiliaryConfigBlobKeys: Set<String> = [
        "providers",
        "providers_v1",
        "worldbooks",
        "worldbooks_v1",
        "shortcut_tools",
        "shortcut_tools_v1",
        "feedback_tickets",
        "feedback_tickets_v1",
        "mcp_servers_records",
        "mcp_servers_records_v1"
    ]
    private static let auxiliaryMemoryBlobKeys: Set<String> = [
        "memory_raw_memories",
        "memory_raw_memories_v1",
        "conversation_user_profile",
        "conversation_user_profile_v1"
    ]
    static var grdbEnabledOverrideForTests: Bool?
    static var requestLogRetentionLimitOverride: Int?
    private static var hasLoggedCompatibilityReminder = false
    public static let launchBackupEnabledKey = "sync.backup.createOnLaunch"
    private static let launchRecoveryNoticeUserDefaultsKey = "persistence.launchRecoveryNotice"
    private static let launchBackupDirectoryName = "StartupBackups"
    private static let launchBackupAndRecoveryLock = NSLock()
    private static var hasPreparedLaunchDatabases = false
    private static var launchPreparationResult = LaunchPreparationResult()
    private static var hasCreatedLaunchBackupPoint = false

    private struct LaunchPreparationResult {
        var restoredKinds: [LaunchDatabaseKind] = []
        var failedKinds: [LaunchDatabaseKind] = []
        var missingBackupKinds: [LaunchDatabaseKind] = []

        var needsChatFTSRebuild: Bool {
            restoredKinds.contains(.chat)
        }
    }

    private enum LaunchDatabaseKind: CaseIterable {
        case chat
        case config
        case memory

        var displayName: String {
            switch self {
            case .chat:
                return "聊天数据库"
            case .config:
                return "配置数据库"
            case .memory:
                return "记忆数据库"
            }
        }
    }

    private enum AuxiliaryStoreKind: String {
        case config = "config-store.sqlite"
        case memory = "memory-store.sqlite"

        var loggerCategory: String {
            switch self {
            case .config:
                return "PersistenceAuxConfig"
            case .memory:
                return "PersistenceAuxMemory"
            }
        }
    }

    private static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private static let sessionIndexFileName = "index.json"
    private static let sessionFoldersFileName = "folders.json"
    private static let sessionRecordsDirectoryName = "sessions"
    private static let requestLogsDirectoryName = "RequestLogs"
    private static let requestLogsFileName = "index.json"
    private static let dailyPulseDirectoryName = "DailyPulse"
    private static let dailyPulseRunsFileName = "runs.json"
    private static let dailyPulseFeedbackHistoryFileName = "feedback-history.json"
    private static let dailyPulsePendingCurationFileName = "pending-curation.json"
    private static let dailyPulseExternalSignalsFileName = "external-signals.json"
    private static let dailyPulseTasksFileName = "tasks.json"
    private static let legacySessionDirectoryName = "v3"
    private static let legacyArchiveDirectoryName = "legacy"

    private struct ChatMessagesFileEnvelope: Codable {
        let schemaVersion: Int
        let messages: [ChatMessage]
    }

    private struct SessionIndexFilePayload: Codable {
        let schemaVersion: Int
        let updatedAt: String
        let sessions: [SessionIndexItemPayload]
    }

    private struct SessionIndexItemPayload: Codable {
        let id: UUID
        let name: String
        let updatedAt: String
    }

    private struct SessionFoldersFileEnvelope: Codable {
        let schemaVersion: Int
        let updatedAt: String
        let folders: [SessionFolder]
    }

    private struct SessionPromptsPayload: Codable {
        let topicPrompt: String?
        let enhancedPrompt: String?
    }

    private struct SessionMetaPayload: Codable {
        let id: UUID
        let name: String
        let folderID: UUID?
        let lorebookIDs: [UUID]
        let worldbookContextIsolationEnabled: Bool?
        let conversationSummary: String?
        let conversationSummaryUpdatedAt: String?
    }

    private struct SessionRecordFilePayload: Codable {
        let schemaVersion: Int
        let session: SessionMetaPayload
        let prompts: SessionPromptsPayload
        let messages: [ChatMessage]
    }

    private struct SessionRecordSummaryPayload: Codable {
        let schemaVersion: Int
        let session: SessionMetaPayload
        let prompts: SessionPromptsPayload
    }

    private struct RequestLogFileEnvelope: Codable {
        let schemaVersion: Int
        let updatedAt: String
        let logs: [RequestLogEntry]
    }

    private struct LegacyMessagesReadResult {
        let messages: [ChatMessage]
        let didMigrateFileSchema: Bool
        let didMigratePlacement: Bool
    }

    private static func shouldUseGRDBStore() -> Bool {
        if let override = grdbEnabledOverrideForTests {
            return override
        }
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return false
        }
        return true
    }

    private static func activeGRDBStore() -> PersistenceGRDBStore? {
        guard shouldUseGRDBStore() else { return nil }
        if let store = cachedGRDBStore {
            return store
        }

        grdbStoreLock.lock()
        defer { grdbStoreLock.unlock() }

        if let store = cachedGRDBStore {
            return store
        }

        if let failedAt = lastGRDBStoreInitializationFailedAt,
           Date().timeIntervalSince(failedAt) < grdbStoreRetryInterval {
            return nil
        }

        migrateLegacySessionDirectoryToCurrentLayoutIfNeeded()
        do {
            let store = try PersistenceGRDBStore(chatsDirectory: getChatsDirectory())
            cachedGRDBStore = store
            lastGRDBStoreInitializationFailedAt = nil
            logger.info("GRDB 持久化已启用。")
            return store
        } catch {
            lastGRDBStoreInitializationFailedAt = Date()
            logger.error("GRDB 持久化初始化失败，已自动回退到 JSON: \(String(describing: error))")
            return nil
        }
    }

    private static func auxiliaryStoreKind(forKey key: String) -> AuxiliaryStoreKind {
        if auxiliaryMemoryBlobKeys.contains(key) {
            return .memory
        }
        if auxiliaryConfigBlobKeys.contains(key) {
            return .config
        }
        return .config
    }

    private static func activeAuxiliaryStore(forKey key: String) -> PersistenceAuxiliaryGRDBStore? {
        activeAuxiliaryStore(kind: auxiliaryStoreKind(forKey: key))
    }

    private static func activeAuxiliaryStore(kind: AuxiliaryStoreKind) -> PersistenceAuxiliaryGRDBStore? {
        guard shouldUseGRDBStore() else { return nil }
        if let store = cachedAuxiliaryStores[kind] {
            return store
        }

        auxiliaryStoreLock.lock()
        defer { auxiliaryStoreLock.unlock() }

        if let store = cachedAuxiliaryStores[kind] {
            return store
        }

        if let failedAt = lastAuxiliaryStoreInitializationFailedAt[kind],
           Date().timeIntervalSince(failedAt) < auxiliaryStoreRetryInterval {
            return nil
        }

        do {
            let databaseURL = auxiliaryStoreDatabaseURL(for: kind)
            migrateLegacyAuxiliaryStoreFileIfNeeded(kind: kind, targetURL: databaseURL)
            let store = try PersistenceAuxiliaryGRDBStore(
                databaseURL: databaseURL,
                loggerCategory: kind.loggerCategory
            )
            cachedAuxiliaryStores[kind] = store
            lastAuxiliaryStoreInitializationFailedAt[kind] = nil
            return store
        } catch {
            lastAuxiliaryStoreInitializationFailedAt[kind] = Date()
            logger.error("辅助存储初始化失败(\(kind.rawValue)): \(String(describing: error))")
            return nil
        }
    }

    private static func auxiliaryStoreDatabaseURL(for kind: AuxiliaryStoreKind) -> URL {
        switch kind {
        case .config:
            let configDirectory = documentsDirectory.appendingPathComponent("Config", isDirectory: true)
            if !FileManager.default.fileExists(atPath: configDirectory.path) {
                try? FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
            }
            return configDirectory.appendingPathComponent(kind.rawValue, isDirectory: false)
        case .memory:
            let memoryDirectory = MemoryStoragePaths.rootDirectory()
            return memoryDirectory.appendingPathComponent(kind.rawValue, isDirectory: false)
        }
    }

    private static func legacyAuxiliaryStoreDatabaseURL(for kind: AuxiliaryStoreKind) -> URL {
        getChatsDirectory().appendingPathComponent(kind.rawValue, isDirectory: false)
    }

    private static func migrateLegacyAuxiliaryStoreFileIfNeeded(kind: AuxiliaryStoreKind, targetURL: URL) {
        let legacyURL = legacyAuxiliaryStoreDatabaseURL(for: kind)
        guard legacyURL.standardizedFileURL.path != targetURL.standardizedFileURL.path else { return }

        let fileManager = FileManager.default
        let legacyPaths = [legacyURL.path, legacyURL.path + "-wal", legacyURL.path + "-shm"]
        let hasLegacyFiles = legacyPaths.contains { fileManager.fileExists(atPath: $0) }
        guard hasLegacyFiles else { return }

        do {
            try ensureDirectoryExists(targetURL.deletingLastPathComponent())
        } catch {
            logger.error("准备辅助存储目录失败(\(kind.rawValue)): \(error.localizedDescription)")
            return
        }

        let targetPaths = [targetURL.path, targetURL.path + "-wal", targetURL.path + "-shm"]
        let targetAlreadyExists = targetPaths.contains { fileManager.fileExists(atPath: $0) }
        if targetAlreadyExists {
            logger.warning("辅助存储目标路径已存在，跳过旧路径迁移: \(targetURL.path)")
            return
        }

        for suffix in ["", "-wal", "-shm"] {
            let sourcePath = legacyURL.path + suffix
            guard fileManager.fileExists(atPath: sourcePath) else { continue }
            let destinationPath = targetURL.path + suffix
            do {
                try fileManager.moveItem(atPath: sourcePath, toPath: destinationPath)
            } catch {
                logger.error("迁移辅助存储文件失败(\(kind.rawValue)) \(sourcePath) -> \(destinationPath): \(error.localizedDescription)")
            }
        }

        logger.info("辅助存储文件路径已迁移(\(kind.rawValue)): \(legacyURL.path) -> \(targetURL.path)")
    }

    @discardableResult
    private static func migrateLegacyAuxiliaryBlobIfNeeded(
        forKey key: String,
        targetStore: PersistenceAuxiliaryGRDBStore?
    ) -> Bool {
        guard let targetStore else { return false }
        guard !targetStore.auxiliaryBlobExists(forKey: key) else { return true }
        guard let legacyStore = activeGRDBStore(),
              let legacyData = legacyStore.loadAuxiliaryBlobRawData(forKey: key) else {
            return false
        }
        guard targetStore.saveAuxiliaryBlobRawData(legacyData, forKey: key) else {
            return false
        }
        _ = legacyStore.removeAuxiliaryBlob(forKey: key)
        logger.info("辅助存储键已迁移到分库: \(key)")
        return true
    }

    public static func bootstrapGRDBStoreOnLaunch() {
        let launchPreparation = prepareDatabasesForLaunchIfNeeded()
        let grdbStore = activeGRDBStore()
        _ = activeAuxiliaryStore(kind: .config)
        _ = activeAuxiliaryStore(kind: .memory)
        if launchPreparation.needsChatFTSRebuild {
            grdbStore?.rebuildMessagesFTSIndex()
        }
        createLaunchBackupPointIfEnabled()
    }

    static func resetGRDBStoreForTests() {
        grdbStoreLock.lock()
        cachedGRDBStore = nil
        lastGRDBStoreInitializationFailedAt = nil
        grdbStoreLock.unlock()

        auxiliaryStoreLock.lock()
        cachedAuxiliaryStores.removeAll()
        lastAuxiliaryStoreInitializationFailedAt.removeAll()
        auxiliaryStoreLock.unlock()

        launchBackupAndRecoveryLock.lock()
        hasPreparedLaunchDatabases = false
        launchPreparationResult = LaunchPreparationResult()
        hasCreatedLaunchBackupPoint = false
        launchBackupAndRecoveryLock.unlock()
        UserDefaults.standard.removeObject(forKey: launchRecoveryNoticeUserDefaultsKey)
    }

    public static func consumeLaunchRecoveryNotice() -> String? {
        let defaults = UserDefaults.standard
        let message = defaults.string(forKey: launchRecoveryNoticeUserDefaultsKey)
        defaults.removeObject(forKey: launchRecoveryNoticeUserDefaultsKey)
        return message
    }

    public static func createLaunchBackupPointIfEnabled() {
        guard UserDefaults.standard.bool(forKey: launchBackupEnabledKey) else { return }

        launchBackupAndRecoveryLock.lock()
        if hasCreatedLaunchBackupPoint {
            launchBackupAndRecoveryLock.unlock()
            return
        }
        hasCreatedLaunchBackupPoint = true
        launchBackupAndRecoveryLock.unlock()

        for kind in LaunchDatabaseKind.allCases {
            do {
                try createLaunchBackup(for: kind)
            } catch {
                logger.error("创建启动备份失败(\(kind.displayName)): \(error.localizedDescription)")
            }
        }
    }

    public static func auxiliaryBlobExists(forKey key: String) -> Bool {
        let targetStore = activeAuxiliaryStore(forKey: key)
        if targetStore?.auxiliaryBlobExists(forKey: key) == true {
            return true
        }

        if migrateLegacyAuxiliaryBlobIfNeeded(forKey: key, targetStore: targetStore) {
            return targetStore?.auxiliaryBlobExists(forKey: key) == true
        }

        guard let legacyStore = activeGRDBStore() else { return false }
        return legacyStore.auxiliaryBlobExists(forKey: key)
    }

    public static func loadAuxiliaryBlob<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        let targetStore = activeAuxiliaryStore(forKey: key)
        if let value = targetStore?.loadAuxiliaryBlob(type, forKey: key) {
            return value
        }

        _ = migrateLegacyAuxiliaryBlobIfNeeded(forKey: key, targetStore: targetStore)
        if let value = targetStore?.loadAuxiliaryBlob(type, forKey: key) {
            return value
        }

        guard let legacyStore = activeGRDBStore() else { return nil }
        return legacyStore.loadAuxiliaryBlob(type, forKey: key)
    }

    @discardableResult
    public static func saveAuxiliaryBlob<T: Encodable>(_ value: T, forKey key: String) -> Bool {
        if let targetStore = activeAuxiliaryStore(forKey: key),
           targetStore.saveAuxiliaryBlob(value, forKey: key) {
            if let legacyStore = activeGRDBStore() {
                _ = legacyStore.removeAuxiliaryBlob(forKey: key)
            }
            return true
        }

        guard let legacyStore = activeGRDBStore() else { return false }
        return legacyStore.saveAuxiliaryBlob(value, forKey: key)
    }

    @discardableResult
    public static func removeAuxiliaryBlob(forKey key: String) -> Bool {
        var didHandle = false
        var didSucceed = true

        if let targetStore = activeAuxiliaryStore(forKey: key) {
            didHandle = true
            didSucceed = targetStore.removeAuxiliaryBlob(forKey: key) && didSucceed
        }
        if let legacyStore = activeGRDBStore() {
            didHandle = true
            didSucceed = legacyStore.removeAuxiliaryBlob(forKey: key) && didSucceed
        }

        return didHandle ? didSucceed : false
    }

    static func withConfigDatabaseRead<T>(_ block: (Database) throws -> T) -> T? {
        guard let store = activeAuxiliaryStore(kind: .config) else { return nil }
        do {
            return try store.read(block)
        } catch {
            logger.error("读取配置数据库失败: \(error.localizedDescription)")
            return nil
        }
    }

    static func withConfigDatabaseWrite<T>(_ block: (Database) throws -> T) -> T? {
        guard let store = activeAuxiliaryStore(kind: .config) else { return nil }
        do {
            return try store.write(block)
        } catch {
            logger.error("写入配置数据库失败: \(error.localizedDescription)")
            return nil
        }
    }

    static func observeConfigDatabase<Reducer: ValueReducer>(
        _ observation: ValueObservation<Reducer>,
        onError: @escaping @Sendable (Error) -> Void,
        onChange: @escaping @Sendable (Reducer.Value) -> Void
    ) -> AnyDatabaseCancellable? where Reducer.Value: Sendable {
        guard let store = activeAuxiliaryStore(kind: .config) else { return nil }
        return store.startObservation(observation, onError: onError, onChange: onChange)
    }

    static func withMemoryDatabaseRead<T>(_ block: (Database) throws -> T) -> T? {
        guard let store = activeAuxiliaryStore(kind: .memory) else { return nil }
        do {
            return try store.read(block)
        } catch {
            logger.error("读取记忆数据库失败: \(error.localizedDescription)")
            return nil
        }
    }

    static func withMemoryDatabaseWrite<T>(_ block: (Database) throws -> T) -> T? {
        guard let store = activeAuxiliaryStore(kind: .memory) else { return nil }
        do {
            return try store.write(block)
        } catch {
            logger.error("写入记忆数据库失败: \(error.localizedDescription)")
            return nil
        }
    }

    private static func prepareDatabasesForLaunchIfNeeded() -> LaunchPreparationResult {
        launchBackupAndRecoveryLock.lock()
        if hasPreparedLaunchDatabases {
            let cached = launchPreparationResult
            launchBackupAndRecoveryLock.unlock()
            return cached
        }
        hasPreparedLaunchDatabases = true
        launchBackupAndRecoveryLock.unlock()

        guard UserDefaults.standard.bool(forKey: launchBackupEnabledKey) else {
            UserDefaults.standard.removeObject(forKey: launchRecoveryNoticeUserDefaultsKey)
            return cacheLaunchPreparationResult(LaunchPreparationResult())
        }

        var result = LaunchPreparationResult()
        for kind in LaunchDatabaseKind.allCases {
            guard isSQLiteDatabaseHealthy(at: databaseURL(for: kind)) else {
                switch restoreDatabaseFromLaunchBackup(for: kind) {
                case .restored:
                    result.restoredKinds.append(kind)
                case .missingBackup:
                    result.missingBackupKinds.append(kind)
                case .failed:
                    result.failedKinds.append(kind)
                }
                continue
            }
        }

        if let noticeMessage = makeLaunchRecoveryNotice(from: result) {
            UserDefaults.standard.set(noticeMessage, forKey: launchRecoveryNoticeUserDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: launchRecoveryNoticeUserDefaultsKey)
        }

        return cacheLaunchPreparationResult(result)
    }

    @discardableResult
    private static func cacheLaunchPreparationResult(_ result: LaunchPreparationResult) -> LaunchPreparationResult {
        launchBackupAndRecoveryLock.lock()
        launchPreparationResult = result
        launchBackupAndRecoveryLock.unlock()
        return result
    }

    private enum LaunchBackupRestoreResult {
        case restored
        case missingBackup
        case failed
    }

    private static func makeLaunchRecoveryNotice(from result: LaunchPreparationResult) -> String? {
        guard !result.restoredKinds.isEmpty || !result.failedKinds.isEmpty || !result.missingBackupKinds.isEmpty else {
            return nil
        }

        var parts: [String] = []
        if !result.restoredKinds.isEmpty {
            let joined = result.restoredKinds.map(\.displayName).joined(separator: "、")
            parts.append("检测到\(joined)损坏，已按启动备份自动重建。")
        }
        if !result.missingBackupKinds.isEmpty {
            let joined = result.missingBackupKinds.map(\.displayName).joined(separator: "、")
            parts.append("\(joined)损坏但未找到可用备份，未执行自动重建。")
        }
        if !result.failedKinds.isEmpty {
            let joined = result.failedKinds.map(\.displayName).joined(separator: "、")
            parts.append("\(joined)损坏且自动重建失败，请尽快手动导入备份。")
        }
        if result.needsChatFTSRebuild {
            parts.append("聊天检索索引会在启动阶段自动重建。")
        }
        return parts.joined(separator: "\n")
    }

    private static func databaseURL(for kind: LaunchDatabaseKind) -> URL {
        switch kind {
        case .chat:
            return getChatsDirectory().appendingPathComponent("chat-store.sqlite", isDirectory: false)
        case .config:
            return auxiliaryStoreDatabaseURL(for: .config)
        case .memory:
            return auxiliaryStoreDatabaseURL(for: .memory)
        }
    }

    private static func launchBackupURL(for kind: LaunchDatabaseKind) -> URL {
        let databaseURL = databaseURL(for: kind)
        let backupDirectory = databaseURL.deletingLastPathComponent()
            .appendingPathComponent(launchBackupDirectoryName, isDirectory: true)
        return backupDirectory.appendingPathComponent(databaseURL.lastPathComponent, isDirectory: false)
    }

    private static func restoreDatabaseFromLaunchBackup(for kind: LaunchDatabaseKind) -> LaunchBackupRestoreResult {
        let databaseURL = databaseURL(for: kind)
        let backupURL = launchBackupURL(for: kind)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: backupURL.path),
              isSQLiteDatabaseHealthy(at: backupURL) else {
            logger.error("检测到数据库损坏且无可用备份(\(kind.displayName))。")
            return .missingBackup
        }

        do {
            try ensureDirectoryExists(databaseURL.deletingLastPathComponent())
            try removeSQLiteFileAndSidecarsIfExists(at: databaseURL)
            try fileManager.copyItem(at: backupURL, to: databaseURL)
            removeSQLiteSidecars(at: databaseURL)
            guard isSQLiteDatabaseHealthy(at: databaseURL) else {
                logger.error("数据库恢复后完整性检查失败(\(kind.displayName))。")
                return .failed
            }
            logger.info("数据库已按启动备份重建(\(kind.displayName))。")
            return .restored
        } catch {
            logger.error("数据库按启动备份重建失败(\(kind.displayName)): \(error.localizedDescription)")
            return .failed
        }
    }

    private static func createLaunchBackup(for kind: LaunchDatabaseKind) throws {
        let sourceURL = databaseURL(for: kind)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sourceURL.path) else { return }
        guard isSQLiteDatabaseHealthy(at: sourceURL) else {
            logger.error("跳过启动备份：源数据库已损坏(\(kind.displayName))。")
            return
        }

        let backupURL = launchBackupURL(for: kind)
        let tempBackupURL = backupURL.appendingPathExtension("tmp")
        try ensureDirectoryExists(backupURL.deletingLastPathComponent())
        try removeItemIfExists(at: tempBackupURL)
        removeSQLiteSidecars(at: tempBackupURL)

        switch kind {
        case .chat:
            try createChatLaunchBackupWithoutFTS(sourceURL: sourceURL, destinationURL: tempBackupURL)
        case .config, .memory:
            try copySQLiteDatabase(sourceURL: sourceURL, destinationURL: tempBackupURL)
        }

        guard isSQLiteDatabaseHealthy(at: tempBackupURL) else {
            throw NSError(domain: "Persistence.LaunchBackup", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "备份文件完整性检查失败"
            ])
        }

        try removeItemIfExists(at: backupURL)
        try fileManager.moveItem(at: tempBackupURL, to: backupURL)
        removeSQLiteSidecars(at: backupURL)
        removeSQLiteSidecars(at: tempBackupURL)
        logger.info("启动备份已更新(\(kind.displayName)): \(backupURL.path)")
    }

    private static func createChatLaunchBackupWithoutFTS(sourceURL: URL, destinationURL: URL) throws {
        try copySQLiteDatabase(sourceURL: sourceURL, destinationURL: destinationURL)
        var database: OpaquePointer?
        guard sqlite3_open_v2(destinationURL.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database else {
            throw NSError(domain: "Persistence.LaunchBackup", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "无法打开聊天备份数据库"
            ])
        }
        defer { sqlite3_close(database) }

        try executeSQLite(database, sql: "DROP TRIGGER IF EXISTS messages_ai")
        try executeSQLite(database, sql: "DROP TRIGGER IF EXISTS messages_ad")
        try executeSQLite(database, sql: "DROP TRIGGER IF EXISTS messages_au")
        try executeSQLite(database, sql: "DROP TABLE IF EXISTS messages_fts")
        try executeSQLite(database, sql: "VACUUM")
    }

    private static func copySQLiteDatabase(sourceURL: URL, destinationURL: URL) throws {
        var sourceDatabase: OpaquePointer?
        guard sqlite3_open_v2(sourceURL.path, &sourceDatabase, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let sourceDatabase else {
            throw NSError(domain: "Persistence.LaunchBackup", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "无法打开源数据库：\(sourceURL.lastPathComponent)"
            ])
        }
        defer { sqlite3_close(sourceDatabase) }

        var destinationDatabase: OpaquePointer?
        guard sqlite3_open_v2(destinationURL.path, &destinationDatabase, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let destinationDatabase else {
            throw NSError(domain: "Persistence.LaunchBackup", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "无法创建备份数据库：\(destinationURL.lastPathComponent)"
            ])
        }
        defer { sqlite3_close(destinationDatabase) }

        try executeSQLite(destinationDatabase, sql: "PRAGMA journal_mode=DELETE")
        try executeSQLite(destinationDatabase, sql: "PRAGMA synchronous=FULL")

        guard let backupHandle = sqlite3_backup_init(destinationDatabase, "main", sourceDatabase, "main") else {
            throw NSError(domain: "Persistence.LaunchBackup", code: 5, userInfo: [
                NSLocalizedDescriptionKey: sqliteErrorMessage(for: destinationDatabase, fallback: "初始化 sqlite backup 失败")
            ])
        }
        var stepCode: Int32 = SQLITE_OK
        repeat {
            stepCode = sqlite3_backup_step(backupHandle, 128)
            if stepCode == SQLITE_BUSY || stepCode == SQLITE_LOCKED {
                sqlite3_sleep(10)
            }
        } while stepCode == SQLITE_OK || stepCode == SQLITE_BUSY || stepCode == SQLITE_LOCKED
        let finishCode = sqlite3_backup_finish(backupHandle)
        guard stepCode == SQLITE_DONE, finishCode == SQLITE_OK else {
            throw NSError(domain: "Persistence.LaunchBackup", code: 6, userInfo: [
                NSLocalizedDescriptionKey: sqliteErrorMessage(for: destinationDatabase, fallback: "执行 sqlite backup 失败")
            ])
        }
    }

    private static func isSQLiteDatabaseHealthy(at url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return true }

        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database else {
            return false
        }
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA quick_check(1)", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            return false
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW,
              let textPointer = sqlite3_column_text(statement, 0) else {
            return false
        }
        let result = String(cString: textPointer).trimmingCharacters(in: .whitespacesAndNewlines)
        return result.caseInsensitiveCompare("ok") == .orderedSame
    }

    private static func executeSQLite(_ database: OpaquePointer, sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "Persistence.SQLiteExec", code: 1, userInfo: [
                NSLocalizedDescriptionKey: sqliteErrorMessage(for: database, fallback: "执行 SQL 失败：\(sql)")
            ])
        }
    }

    private static func sqliteErrorMessage(for database: OpaquePointer, fallback: String) -> String {
        guard let cString = sqlite3_errmsg(database) else { return fallback }
        let message = String(cString: cString)
        return message.isEmpty ? fallback : message
    }

    private static func removeSQLiteFileAndSidecarsIfExists(at url: URL) throws {
        try removeItemIfExists(at: url)
        removeSQLiteSidecars(at: url)
    }

    private static func removeSQLiteSidecars(at url: URL) {
        let fileManager = FileManager.default
        let walPath = url.path + "-wal"
        let shmPath = url.path + "-shm"
        if fileManager.fileExists(atPath: walPath) {
            try? fileManager.removeItem(atPath: walPath)
        }
        if fileManager.fileExists(atPath: shmPath) {
            try? fileManager.removeItem(atPath: shmPath)
        }
    }

    // MARK: - 目录管理

    /// 获取用于存储聊天记录的目录URL
    /// - Returns: 存储目录的URL路径
    public static func getChatsDirectory() -> URL {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        let chatsDirectory = paths[0].appendingPathComponent("ChatSessions")
        if !FileManager.default.fileExists(atPath: chatsDirectory.path) {
            logger.info("Chat history directory does not exist, creating: \(chatsDirectory.path)")
            try? FileManager.default.createDirectory(at: chatsDirectory, withIntermediateDirectories: true)
        }
        return chatsDirectory
    }

    // MARK: - 会话持久化

    /// 保存所有聊天会话的列表
    public static func saveChatSessions(_ sessions: [ChatSession]) {
        if let store = activeGRDBStore() {
            store.saveChatSessions(sessions)
            return
        }

        migrateLegacySessionDirectoryToCurrentLayoutIfNeeded()

        let sessionsToSave = sessions.filter { !$0.isTemporary }
        logger.info("准备保存 \(sessionsToSave.count) 个会话到会话索引。")

        do {
            for session in sessionsToSave {
                try ensureSessionRecordMetadataUpToDate(for: session)
            }

            let now = iso8601Timestamp()
            let index = SessionIndexFilePayload(
                schemaVersion: sessionStoreSchemaVersion,
                updatedAt: now,
                sessions: sessionsToSave.map { session in
                    SessionIndexItemPayload(
                        id: session.id,
                        name: session.name,
                        updatedAt: now
                    )
                }
            )
            try writeSessionIndexFile(index)
            logger.info("会话索引保存成功。")
        } catch {
            logger.error("保存会话索引失败: \(error.localizedDescription)")
        }
    }

    /// 加载所有聊天会话的列表
    public static func loadChatSessions() -> [ChatSession] {
        if let store = activeGRDBStore() {
            return store.loadChatSessions()
        }

        migrateLegacySessionDirectoryToCurrentLayoutIfNeeded()
        logCompatibilityReminderIfNeeded(trigger: "loadChatSessions")

        if let sessions = loadChatSessionsFromIndexedFiles() {
            logger.info("已从会话索引加载 \(sessions.count) 个会话。")
            cleanupLegacyArtifactsIfPossible()
            return sessions
        }

        let legacySessions = loadLegacySessions()
        guard !legacySessions.isEmpty else {
            logger.info("未检测到可用会话索引，返回空会话列表。")
            return []
        }

        logger.info("\(migrationLogPrefix) 检测到旧版会话索引，开始全量迁移。")
        do {
            try migrateLegacyStoreToIndexedFiles(legacySessions: legacySessions)
            if let migratedSessions = loadChatSessionsFromIndexedFiles() {
                logger.info("\(migrationLogPrefix) 已完成迁移，加载到 \(migratedSessions.count) 个会话。")
                cleanupLegacyArtifactsIfPossible()
                return migratedSessions
            }
            logger.warning("\(migrationLogPrefix) 迁移后未读取到会话索引，回退返回旧会话列表。")
            return legacySessions
        } catch {
            logger.error("\(migrationLogPrefix) 迁移失败，回退旧会话列表: \(error.localizedDescription)")
            return legacySessions
        }
    }

    // MARK: - 会话文件夹持久化

    /// 保存会话文件夹列表。
    public static func saveSessionFolders(_ folders: [SessionFolder]) {
        if let store = activeGRDBStore() {
            store.saveSessionFolders(folders)
            return
        }

        migrateLegacySessionDirectoryToCurrentLayoutIfNeeded()

        let normalizedFolders = normalizeSessionFoldersForPersistence(folders)
        let envelope = SessionFoldersFileEnvelope(
            schemaVersion: sessionFoldersFileSchemaVersion,
            updatedAt: iso8601Timestamp(),
            folders: normalizedFolders
        )

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(envelope)
            try data.write(to: sessionFoldersFileURL(), options: .atomic)
            logger.info("会话文件夹保存成功，共 \(normalizedFolders.count) 个。")
        } catch {
            logger.error("保存会话文件夹失败: \(error.localizedDescription)")
        }
    }

    /// 加载会话文件夹列表。
    public static func loadSessionFolders() -> [SessionFolder] {
        if let store = activeGRDBStore() {
            return store.loadSessionFolders()
        }

        migrateLegacySessionDirectoryToCurrentLayoutIfNeeded()

        let fileURL = sessionFoldersFileURL()
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let envelope = try JSONDecoder().decode(SessionFoldersFileEnvelope.self, from: data)
            let normalizedFolders = normalizeSessionFoldersForPersistence(envelope.folders)
            let shouldRewrite = envelope.schemaVersion != sessionFoldersFileSchemaVersion
                || normalizedFolders != envelope.folders
            if shouldRewrite {
                saveSessionFolders(normalizedFolders)
            }
            return normalizedFolders
        } catch {
            logger.warning("读取会话文件夹失败: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - 消息持久化

    /// 保存指定会话的聊天消息
    public static func saveMessages(_ messages: [ChatMessage], for sessionID: UUID) {
        if let store = activeGRDBStore() {
            store.saveMessages(messages, for: sessionID)
            return
        }

        migrateLegacySessionDirectoryToCurrentLayoutIfNeeded()

        do {
            let normalized = normalizeToolCallsPlacement(in: messages, sessionID: sessionID)
            let sessionSnapshot = resolveSessionSnapshot(for: sessionID)
            let record = makeSessionRecordPayload(session: sessionSnapshot, messages: normalized.messages)
            try writeSessionRecordFile(record, for: sessionID)
            logger.info("会话 \(sessionID.uuidString) 的消息已保存到会话存储（\(normalized.messages.count) 条）。")
        } catch {
            logger.error("保存会话 \(sessionID.uuidString) 消息失败: \(error.localizedDescription)")
        }
    }

    /// 加载指定会话的聊天消息
    public static func loadMessages(for sessionID: UUID) -> [ChatMessage] {
        if let store = activeGRDBStore() {
            return store.loadMessages(for: sessionID)
        }

        migrateLegacySessionDirectoryToCurrentLayoutIfNeeded()
        logCompatibilityReminderIfNeeded(trigger: "loadMessages")

        if let loadedMessages = loadMessagesFromIndexedFiles(for: sessionID) {
            logger.info("会话 \(sessionID.uuidString) 已从会话存储加载 \(loadedMessages.count) 条消息。")
            cleanupLegacyArtifactsIfPossible()
            return loadedMessages
        }

        let legacyURL = legacyMessagesFileURL(for: sessionID)
        guard FileManager.default.fileExists(atPath: legacyURL.path) else {
            logger.warning("未找到会话 \(sessionID.uuidString) 的消息文件，返回空列表。")
            return []
        }

        logger.info("\(migrationLogPrefix) 检测到旧版消息文件，开始迁移会话 \(sessionID.uuidString)。")
        do {
            let legacy = try readLegacyMessages(for: sessionID)
            let sessionSnapshot = resolveSessionSnapshot(for: sessionID)
            let record = makeSessionRecordPayload(session: sessionSnapshot, messages: legacy.messages)
            try writeSessionRecordFile(record, for: sessionID)
            try removeItemIfExists(at: legacyURL)
            cleanupLegacyArtifactsIfPossible()
            logger.info("\(migrationLogPrefix) 会话 \(sessionID.uuidString) 消息迁移完成，共 \(legacy.messages.count) 条。")
            return legacy.messages
        } catch {
            logger.warning("加载会话 \(sessionID.uuidString) 消息失败，返回空列表: \(error.localizedDescription)")
            return []
        }
    }

    /// 统计指定会话的消息数量。
    public static func loadMessageCount(for sessionID: UUID) -> Int {
        if let store = activeGRDBStore() {
            return store.loadMessageCount(for: sessionID)
        }
        return loadMessages(for: sessionID).count
    }

    // MARK: - 请求日志持久化

    /// 追加一条请求日志，内部会执行滚动裁剪。
    public static func appendRequestLog(_ entry: RequestLogEntry) {
        if let store = activeGRDBStore() {
            store.appendRequestLog(entry, retentionLimit: effectiveRequestLogRetentionLimit())
            return
        }

        requestLogLock.lock()
        defer { requestLogLock.unlock() }

        do {
            var logs = (try loadRequestLogEnvelope()?.logs) ?? []
            logs.append(entry)
            let retentionLimit = effectiveRequestLogRetentionLimit()
            if logs.count > retentionLimit {
                logs.removeFirst(logs.count - retentionLimit)
            }
            try writeRequestLogEnvelope(
                .init(
                    schemaVersion: requestLogSchemaVersion,
                    updatedAt: iso8601Timestamp(),
                    logs: logs
                )
            )
        } catch {
            logger.error("写入请求日志失败: \(error.localizedDescription)")
        }
    }

    /// 清空请求日志文件。
    public static func clearRequestLogs() {
        if let store = activeGRDBStore() {
            store.clearRequestLogs()
            return
        }

        requestLogLock.lock()
        defer { requestLogLock.unlock() }

        let fileURL = requestLogsFileURL()
        do {
            try removeItemIfExists(at: fileURL)
        } catch {
            logger.error("清空请求日志失败: \(error.localizedDescription)")
        }
    }

    /// 按条件读取请求日志（默认按请求开始时间倒序）。
    public static func loadRequestLogs(query: RequestLogQuery = .init()) -> [RequestLogEntry] {
        if let store = activeGRDBStore() {
            return store.loadRequestLogs(query: query)
        }

        requestLogLock.lock()
        defer { requestLogLock.unlock() }

        let allLogs: [RequestLogEntry]
        do {
            allLogs = try loadRequestLogEnvelope()?.logs ?? []
        } catch {
            logger.error("读取请求日志失败: \(error.localizedDescription)")
            return []
        }

        var filtered = allLogs.filter { entry in
            if let from = query.from, entry.requestedAt < from {
                return false
            }
            if let to = query.to, entry.requestedAt > to {
                return false
            }
            if let providerID = query.providerID, entry.providerID != providerID {
                return false
            }
            if let modelID = query.modelID, entry.modelID != modelID {
                return false
            }
            if let statuses = query.statuses, !statuses.contains(entry.status) {
                return false
            }
            return true
        }
        filtered.sort { $0.requestedAt > $1.requestedAt }
        if let limit = query.limit, limit > 0, filtered.count > limit {
            return Array(filtered.prefix(limit))
        }
        return filtered
    }

    /// 汇总请求日志，用于后续统计展示与导出。
    public static func summarizeRequestLogs(query: RequestLogQuery = .init()) -> RequestLogSummary {
        if let store = activeGRDBStore() {
            return store.summarizeRequestLogs(query: query)
        }

        let logs = loadRequestLogs(query: query)
        var summary = RequestLogSummary()

        var providerBuckets: [String: RequestLogSummaryBucket] = [:]
        var modelBuckets: [String: RequestLogSummaryBucket] = [:]

        for entry in logs {
            summary.totalRequests += 1
            switch entry.status {
            case .success:
                summary.successCount += 1
            case .failed:
                summary.failedCount += 1
            case .cancelled:
                summary.cancelledCount += 1
            }
            accumulateRequestTokens(entry.tokenUsage, to: &summary.tokenTotals)

            var providerBucket = providerBuckets[entry.providerName] ?? RequestLogSummaryBucket(key: entry.providerName)
            providerBucket.requestCount += 1
            switch entry.status {
            case .success:
                providerBucket.successCount += 1
            case .failed:
                providerBucket.failedCount += 1
            case .cancelled:
                providerBucket.cancelledCount += 1
            }
            accumulateRequestTokens(entry.tokenUsage, to: &providerBucket.tokenTotals)
            providerBuckets[entry.providerName] = providerBucket

            var modelBucket = modelBuckets[entry.modelID] ?? RequestLogSummaryBucket(key: entry.modelID)
            modelBucket.requestCount += 1
            switch entry.status {
            case .success:
                modelBucket.successCount += 1
            case .failed:
                modelBucket.failedCount += 1
            case .cancelled:
                modelBucket.cancelledCount += 1
            }
            accumulateRequestTokens(entry.tokenUsage, to: &modelBucket.tokenTotals)
            modelBuckets[entry.modelID] = modelBucket
        }

        summary.byProvider = providerBuckets.values.sorted { lhs, rhs in
            if lhs.requestCount == rhs.requestCount {
                return lhs.key < rhs.key
            }
            return lhs.requestCount > rhs.requestCount
        }
        summary.byModel = modelBuckets.values.sorted { lhs, rhs in
            if lhs.requestCount == rhs.requestCount {
                return lhs.key < rhs.key
            }
            return lhs.requestCount > rhs.requestCount
        }
        return summary
    }

    /// 保存每日脉冲运行记录。
    public static func saveDailyPulseRuns(_ runs: [DailyPulseRun]) {
        if let store = activeGRDBStore() {
            store.saveDailyPulseRuns(runs)
            return
        }

        let fileURL = dailyPulseRunsFileURL()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        do {
            let data = try encoder.encode(runs)
            try data.write(to: fileURL, options: [.atomicWrite, .completeFileProtection])
        } catch {
            logger.error("保存每日脉冲记录失败: \(error.localizedDescription)")
        }
    }

    /// 读取每日脉冲运行记录。
    public static func loadDailyPulseRuns() -> [DailyPulseRun] {
        if let store = activeGRDBStore() {
            return store.loadDailyPulseRuns()
        }

        let fileURL = dailyPulseRunsFileURL()
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        do {
            let data = try Data(contentsOf: fileURL)
            return try decoder.decode([DailyPulseRun].self, from: data)
        } catch {
            logger.error("读取每日脉冲记录失败: \(error.localizedDescription)")
            return []
        }
    }

    /// 保存每日脉冲反馈历史。
    public static func saveDailyPulseFeedbackHistory(_ history: [DailyPulseFeedbackEvent]) {
        if let store = activeGRDBStore() {
            store.saveDailyPulseFeedbackHistory(history)
            return
        }

        let fileURL = dailyPulseFeedbackHistoryFileURL()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        do {
            let data = try encoder.encode(history)
            try data.write(to: fileURL, options: [.atomicWrite, .completeFileProtection])
        } catch {
            logger.error("保存每日脉冲反馈历史失败: \(error.localizedDescription)")
        }
    }

    /// 读取每日脉冲反馈历史。
    public static func loadDailyPulseFeedbackHistory() -> [DailyPulseFeedbackEvent] {
        if let store = activeGRDBStore() {
            return store.loadDailyPulseFeedbackHistory()
        }

        let fileURL = dailyPulseFeedbackHistoryFileURL()
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        do {
            let data = try Data(contentsOf: fileURL)
            return try decoder.decode([DailyPulseFeedbackEvent].self, from: data)
        } catch {
            logger.error("读取每日脉冲反馈历史失败: \(error.localizedDescription)")
            return []
        }
    }

    /// 保存待消费的每日脉冲策展输入。
    public static func saveDailyPulsePendingCuration(_ note: DailyPulseCurationNote?) {
        if let store = activeGRDBStore() {
            store.saveDailyPulsePendingCuration(note)
            return
        }

        let fileURL = dailyPulsePendingCurationFileURL()

        guard let note else {
            try? removeItemIfExists(at: fileURL)
            return
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        do {
            let data = try encoder.encode(note)
            try data.write(to: fileURL, options: [.atomicWrite, .completeFileProtection])
        } catch {
            logger.error("保存每日脉冲策展输入失败: \(error.localizedDescription)")
        }
    }

    /// 读取待消费的每日脉冲策展输入。
    public static func loadDailyPulsePendingCuration() -> DailyPulseCurationNote? {
        if let store = activeGRDBStore() {
            return store.loadDailyPulsePendingCuration()
        }

        let fileURL = dailyPulsePendingCurationFileURL()
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        do {
            let data = try Data(contentsOf: fileURL)
            return try decoder.decode(DailyPulseCurationNote.self, from: data)
        } catch {
            logger.error("读取每日脉冲策展输入失败: \(error.localizedDescription)")
            return nil
        }
    }

    /// 保存每日脉冲外部信号历史。
    public static func saveDailyPulseExternalSignals(_ signals: [DailyPulseExternalSignal]) {
        if let store = activeGRDBStore() {
            store.saveDailyPulseExternalSignals(signals)
            return
        }

        let fileURL = dailyPulseExternalSignalsFileURL()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        do {
            let data = try encoder.encode(signals)
            try data.write(to: fileURL, options: [.atomicWrite, .completeFileProtection])
        } catch {
            logger.error("保存每日脉冲外部信号历史失败: \(error.localizedDescription)")
        }
    }

    /// 读取每日脉冲外部信号历史。
    public static func loadDailyPulseExternalSignals() -> [DailyPulseExternalSignal] {
        if let store = activeGRDBStore() {
            return store.loadDailyPulseExternalSignals()
        }

        let fileURL = dailyPulseExternalSignalsFileURL()
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        do {
            let data = try Data(contentsOf: fileURL)
            return try decoder.decode([DailyPulseExternalSignal].self, from: data)
        } catch {
            logger.error("读取每日脉冲外部信号历史失败: \(error.localizedDescription)")
            return []
        }
    }

    /// 保存每日脉冲任务。
    public static func saveDailyPulseTasks(_ tasks: [DailyPulseTask]) {
        if let store = activeGRDBStore() {
            store.saveDailyPulseTasks(tasks)
            return
        }

        let fileURL = dailyPulseTasksFileURL()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        do {
            let data = try encoder.encode(tasks)
            try data.write(to: fileURL, options: [.atomicWrite, .completeFileProtection])
        } catch {
            logger.error("保存每日脉冲任务失败: \(error.localizedDescription)")
        }
    }

    /// 读取每日脉冲任务。
    public static func loadDailyPulseTasks() -> [DailyPulseTask] {
        if let store = activeGRDBStore() {
            return store.loadDailyPulseTasks()
        }

        let fileURL = dailyPulseTasksFileURL()
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        do {
            let data = try Data(contentsOf: fileURL)
            return try decoder.decode([DailyPulseTask].self, from: data)
        } catch {
            logger.error("读取每日脉冲任务失败: \(error.localizedDescription)")
            return []
        }
    }

    /// 判断会话是否存在可读取的数据文件（当前格式或 legacy）。
    public static func sessionDataExists(sessionID: UUID) -> Bool {
        if let store = activeGRDBStore() {
            return store.sessionDataExists(sessionID: sessionID)
        }

        let currentFileExists = FileManager.default.fileExists(atPath: sessionRecordFileURL(for: sessionID).path)
        let legacySessionDirectoryFileExists = FileManager.default.fileExists(atPath: legacySessionRecordFileURL(for: sessionID).path)
        let legacyFileExists = FileManager.default.fileExists(atPath: legacyMessagesFileURL(for: sessionID).path)
        return currentFileExists || legacySessionDirectoryFileExists || legacyFileExists
    }

    /// 删除会话相关的消息持久化文件（当前格式 + legacy）。
    public static func deleteSessionArtifacts(sessionID: UUID) {
        if let store = activeGRDBStore() {
            store.deleteSessionArtifacts(sessionID: sessionID)
            return
        }

        let targets = [
            sessionRecordFileURL(for: sessionID),
            legacySessionRecordFileURL(for: sessionID),
            legacyMessagesFileURL(for: sessionID)
        ]

        for url in targets {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                try FileManager.default.removeItem(at: url)
                logger.info("已删除会话数据文件: \(url.path)")
            } catch {
                logger.warning("删除会话数据文件失败 \(url.path): \(error.localizedDescription)")
            }
        }
    }

    /// 写入（或覆盖）某个会话的跨对话摘要。
    public static func upsertConversationSessionSummary(_ summary: String, for sessionID: UUID, updatedAt: Date = Date()) {
        if let store = activeGRDBStore() {
            store.upsertConversationSessionSummary(summary, for: sessionID, updatedAt: updatedAt)
            return
        }

        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            clearConversationSessionSummary(for: sessionID)
            return
        }
        updateConversationSummaryFields(
            for: sessionID,
            summary: trimmed,
            updatedAt: iso8601Timestamp(from: updatedAt)
        )
    }

    /// 清空某个会话的跨对话摘要字段。
    public static func clearConversationSessionSummary(for sessionID: UUID) {
        if let store = activeGRDBStore() {
            store.clearConversationSessionSummary(for: sessionID)
            return
        }

        updateConversationSummaryFields(for: sessionID, summary: nil, updatedAt: nil)
    }

    /// 清空所有会话的跨对话摘要，返回实际清理条数。
    @discardableResult
    public static func clearAllConversationSessionSummaries() -> Int {
        if let store = activeGRDBStore() {
            return store.clearAllConversationSessionSummaries()
        }

        let summaries = loadConversationSessionSummaries(limit: nil, excludingSessionID: nil)
        guard !summaries.isEmpty else { return 0 }
        summaries.forEach { summary in
            clearConversationSessionSummary(for: summary.sessionID)
        }
        return summaries.count
    }

    /// 读取某个会话的跨对话摘要。
    public static func loadConversationSessionSummary(for sessionID: UUID) -> ConversationSessionSummary? {
        if let store = activeGRDBStore() {
            return store.loadConversationSessionSummary(for: sessionID)
        }

        guard let summary = try? loadSessionSummaryFile(for: sessionID),
              let text = summary.session.conversationSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            return nil
        }

        let fallbackName = summary.session.name
        let parsedDate = parseISO8601Date(summary.session.conversationSummaryUpdatedAt) ?? .distantPast
        return ConversationSessionSummary(
            sessionID: summary.session.id,
            sessionName: fallbackName,
            summary: text,
            updatedAt: parsedDate
        )
    }

    /// 读取会话摘要列表，可选限制返回数量并排除指定会话。
    public static func loadConversationSessionSummaries(limit: Int?, excludingSessionID: UUID?) -> [ConversationSessionSummary] {
        if let store = activeGRDBStore() {
            return store.loadConversationSessionSummaries(limit: limit, excludingSessionID: excludingSessionID)
        }

        guard let index = loadSessionIndexFile() else { return [] }

        var summaries: [ConversationSessionSummary] = []
        summaries.reserveCapacity(index.sessions.count)

        for item in index.sessions {
            if let excludingSessionID, item.id == excludingSessionID {
                continue
            }
            guard let recordSummary = try? loadSessionSummaryFile(for: item.id),
                  let text = recordSummary.session.conversationSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else {
                continue
            }

            let updatedAt = parseISO8601Date(recordSummary.session.conversationSummaryUpdatedAt)
                ?? parseISO8601Date(item.updatedAt)
                ?? .distantPast
            let resolvedName = recordSummary.session.name.isEmpty ? item.name : recordSummary.session.name
            summaries.append(
                ConversationSessionSummary(
                    sessionID: item.id,
                    sessionName: resolvedName,
                    summary: text,
                    updatedAt: updatedAt
                )
            )
        }

        summaries.sort { lhs, rhs in
            if lhs.updatedAt == rhs.updatedAt {
                return lhs.sessionID.uuidString < rhs.sessionID.uuidString
            }
            return lhs.updatedAt > rhs.updatedAt
        }

        guard let limit else { return summaries }
        let safeLimit = max(0, limit)
        guard safeLimit > 0 else { return [] }
        return Array(summaries.prefix(safeLimit))
    }

    private static func updateConversationSummaryFields(for sessionID: UUID, summary: String?, updatedAt: String?) {
        do {
            let baseRecord: SessionRecordFilePayload
            if let existing = try loadSessionRecordFile(for: sessionID) {
                baseRecord = existing
            } else {
                let sessionSnapshot = resolveSessionSnapshot(for: sessionID)
                let messages = try loadMessagesForRecordWrite(sessionID: sessionID)
                baseRecord = makeSessionRecordPayload(session: sessionSnapshot, messages: messages)
            }

            let normalizedSummary = summary?.trimmingCharacters(in: .whitespacesAndNewlines)
            let finalSummary = (normalizedSummary?.isEmpty == false) ? normalizedSummary : nil
            let finalUpdatedAt = finalSummary == nil ? nil : updatedAt
            let updatedMeta = SessionMetaPayload(
                id: baseRecord.session.id,
                name: baseRecord.session.name,
                folderID: baseRecord.session.folderID,
                lorebookIDs: baseRecord.session.lorebookIDs,
                worldbookContextIsolationEnabled: baseRecord.session.worldbookContextIsolationEnabled,
                conversationSummary: finalSummary,
                conversationSummaryUpdatedAt: finalUpdatedAt
            )
            let updatedRecord = SessionRecordFilePayload(
                schemaVersion: sessionStoreSchemaVersion,
                session: updatedMeta,
                prompts: baseRecord.prompts,
                messages: baseRecord.messages
            )
            try writeSessionRecordFile(updatedRecord, for: sessionID)
        } catch {
            logger.warning("更新会话摘要失败 \(sessionID.uuidString): \(error.localizedDescription)")
        }
    }

    private static func loadChatSessionsFromIndexedFiles() -> [ChatSession]? {
        let indexURL = sessionIndexFileURLCurrent()
        guard FileManager.default.fileExists(atPath: indexURL.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: indexURL)
            let index = try JSONDecoder().decode(SessionIndexFilePayload.self, from: data)
            var loadedSessions: [ChatSession] = []
            loadedSessions.reserveCapacity(index.sessions.count)

            for item in index.sessions {
                if let summary = try? loadSessionSummaryFile(for: item.id) {
                    var session = makeChatSession(from: summary, fallbackName: item.name)
                    session.isTemporary = false
                    loadedSessions.append(session)
                } else {
                    let session = ChatSession(
                        id: item.id,
                        name: item.name,
                        topicPrompt: nil,
                        enhancedPrompt: nil,
                        lorebookIDs: [],
                        worldbookContextIsolationEnabled: false,
                        isTemporary: false
                    )
                    loadedSessions.append(session)
                }
            }
            return loadedSessions
        } catch {
            logger.warning("读取会话索引失败: \(error.localizedDescription)")
            return nil
        }
    }

    private static func loadLegacySessions() -> [ChatSession] {
        let fileURL = legacySessionIndexFileURL()
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let sessions = try JSONDecoder().decode([ChatSession].self, from: data)
            logger.info("已读取旧版会话索引，共 \(sessions.count) 个会话。")
            return sessions
        } catch {
            logger.warning("读取旧版会话索引失败: \(error.localizedDescription)")
            return []
        }
    }

    private static func migrateLegacyStoreToIndexedFiles(legacySessions: [ChatSession]) throws {
        let sessionsToSave = legacySessions.filter { !$0.isTemporary }
        let now = iso8601Timestamp()

        var recordsByID: [UUID: SessionRecordFilePayload] = [:]
        recordsByID.reserveCapacity(sessionsToSave.count)

        for session in sessionsToSave {
            let legacyRead = (try? readLegacyMessages(for: session.id))
            let messages = legacyRead?.messages ?? []
            let record = makeSessionRecordPayload(session: session, messages: messages)
            recordsByID[session.id] = record
        }

        for session in sessionsToSave {
            if let record = recordsByID[session.id] {
                try writeSessionRecordFile(record, for: session.id)
                logger.info("\(migrationLogPrefix) 会话 \(session.id.uuidString) 已改写为新格式。")
            }
        }

        let index = SessionIndexFilePayload(
            schemaVersion: sessionStoreSchemaVersion,
            updatedAt: now,
            sessions: sessionsToSave.map { session in
                SessionIndexItemPayload(
                    id: session.id,
                    name: session.name,
                    updatedAt: now
                )
            }
        )
        try writeSessionIndexFile(index)
        try removeLegacySourceFiles(sessions: sessionsToSave)
    }

    private static func ensureSessionRecordMetadataUpToDate(for session: ChatSession) throws {
        if let summary = try loadSessionSummaryFile(for: session.id),
           isSamePersistedSession(summary: summary, session: session) {
            return
        }

        let messages = try loadMessagesForRecordWrite(sessionID: session.id)
        let record = makeSessionRecordPayload(session: session, messages: messages)
        try writeSessionRecordFile(record, for: session.id)
    }

    private static func loadMessagesForRecordWrite(sessionID: UUID) throws -> [ChatMessage] {
        if let record = try loadSessionRecordFile(for: sessionID) {
            return record.messages
        }
        if let legacy = try? readLegacyMessages(for: sessionID) {
            return legacy.messages
        }
        return []
    }

    private static func loadMessagesFromIndexedFiles(for sessionID: UUID) -> [ChatMessage]? {
        let fileURL = sessionRecordFileURL(for: sessionID)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }

        do {
            let record = try loadSessionRecordFile(for: sessionID)
            guard let record else { return nil }

            let normalized = normalizeToolCallsPlacement(in: record.messages, sessionID: sessionID)
            let shouldRewrite = normalized.didMigratePlacement || record.schemaVersion != sessionStoreSchemaVersion
            if shouldRewrite {
                let rewritten = SessionRecordFilePayload(
                    schemaVersion: sessionStoreSchemaVersion,
                    session: record.session,
                    prompts: record.prompts,
                    messages: normalized.messages
                )
                try writeSessionRecordFile(rewritten, for: sessionID)
                logger.info("\(migrationLogPrefix) 会话 \(sessionID.uuidString) 的消息文件已规范化。")
            }

            return normalized.messages
        } catch {
            logger.warning("读取会话文件失败 \(sessionID.uuidString): \(error.localizedDescription)")
            return nil
        }
    }

    private static func readLegacyMessages(for sessionID: UUID) throws -> LegacyMessagesReadResult {
        let fileURL = legacyMessagesFileURL(for: sessionID)
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()

        if let envelope = try? decoder.decode(ChatMessagesFileEnvelope.self, from: data) {
            let normalized = normalizeToolCallsPlacement(in: envelope.messages, sessionID: sessionID)
            let didMigrateSchema = envelope.schemaVersion != messagesFileSchemaVersion
            if didMigrateSchema {
                logger.info("\(migrationLogPrefix) 会话 \(sessionID.uuidString) 检测到旧消息封装格式，将执行迁移。")
            }
            return LegacyMessagesReadResult(
                messages: normalized.messages,
                didMigrateFileSchema: didMigrateSchema,
                didMigratePlacement: normalized.didMigratePlacement
            )
        }

        let rawMessages = try decoder.decode([ChatMessage].self, from: data)
        let normalized = normalizeToolCallsPlacement(in: rawMessages, sessionID: sessionID)
        logger.info("\(migrationLogPrefix) 会话 \(sessionID.uuidString) 检测到旧数组消息格式。")
        return LegacyMessagesReadResult(
            messages: normalized.messages,
            didMigrateFileSchema: true,
            didMigratePlacement: normalized.didMigratePlacement
        )
    }

    private static func resolveSessionSnapshot(for sessionID: UUID) -> ChatSession {
        if let summary = try? loadSessionSummaryFile(for: sessionID) {
            return makeChatSession(from: summary, fallbackName: summary.session.name)
        }

        if let index = loadSessionIndexFile(),
           let item = index.sessions.first(where: { $0.id == sessionID }) {
            return ChatSession(id: sessionID, name: item.name, isTemporary: false)
        }

        if let legacy = loadLegacySessions().first(where: { $0.id == sessionID }) {
            return legacy
        }

        return ChatSession(id: sessionID, name: "新的对话", isTemporary: true)
    }

    private static func makeSessionRecordPayload(session: ChatSession, messages: [ChatMessage]) -> SessionRecordFilePayload {
        let preservedSummary = (try? loadSessionSummaryFile(for: session.id))?.session
        return SessionRecordFilePayload(
            schemaVersion: sessionStoreSchemaVersion,
            session: SessionMetaPayload(
                id: session.id,
                name: session.name,
                folderID: session.folderID,
                lorebookIDs: session.lorebookIDs,
                worldbookContextIsolationEnabled: session.worldbookContextIsolationEnabled ? true : nil,
                conversationSummary: preservedSummary?.conversationSummary,
                conversationSummaryUpdatedAt: preservedSummary?.conversationSummaryUpdatedAt
            ),
            prompts: SessionPromptsPayload(
                topicPrompt: session.topicPrompt,
                enhancedPrompt: session.enhancedPrompt
            ),
            messages: messages
        )
    }

    private static func makeChatSession(from summary: SessionRecordSummaryPayload, fallbackName: String) -> ChatSession {
        ChatSession(
            id: summary.session.id,
            name: summary.session.name.isEmpty ? fallbackName : summary.session.name,
            topicPrompt: summary.prompts.topicPrompt,
            enhancedPrompt: summary.prompts.enhancedPrompt,
            lorebookIDs: summary.session.lorebookIDs,
            worldbookContextIsolationEnabled: summary.session.worldbookContextIsolationEnabled ?? false,
            folderID: summary.session.folderID,
            isTemporary: false
        )
    }

    private static func normalizeToolCallsPlacement(in messages: [ChatMessage], sessionID: UUID) -> (messages: [ChatMessage], didMigratePlacement: Bool) {
        var normalizedMessages = messages
        var didMigratePlacement = false

        for index in normalizedMessages.indices {
            guard normalizedMessages[index].toolCallsPlacement == nil,
                  let toolCalls = normalizedMessages[index].toolCalls,
                  !toolCalls.isEmpty else { continue }
            normalizedMessages[index].toolCallsPlacement = inferToolCallsPlacement(from: normalizedMessages[index].content)
            didMigratePlacement = true
        }

        if didMigratePlacement {
            logger.info("\(migrationLogPrefix) 会话 \(sessionID.uuidString) 的 toolCallsPlacement 已自动补齐。")
        }
        return (normalizedMessages, didMigratePlacement)
    }

    private static func isSamePersistedSession(summary: SessionRecordSummaryPayload, session: ChatSession) -> Bool {
        summary.session.id == session.id &&
        summary.session.name == session.name &&
        summary.session.folderID == session.folderID &&
        summary.session.lorebookIDs == session.lorebookIDs &&
        (summary.session.worldbookContextIsolationEnabled ?? false) == session.worldbookContextIsolationEnabled &&
        summary.prompts.topicPrompt == session.topicPrompt &&
        summary.prompts.enhancedPrompt == session.enhancedPrompt
    }

    private static func normalizeSessionFoldersForPersistence(_ folders: [SessionFolder]) -> [SessionFolder] {
        var uniqueFolders: [SessionFolder] = []
        uniqueFolders.reserveCapacity(folders.count)
        var seenIDs = Set<UUID>()

        for folder in folders {
            guard seenIDs.insert(folder.id).inserted else { continue }
            let normalizedName = folder.name.trimmingCharacters(in: .whitespacesAndNewlines)
            uniqueFolders.append(
                SessionFolder(
                    id: folder.id,
                    name: normalizedName.isEmpty ? "未命名文件夹" : normalizedName,
                    parentID: folder.parentID,
                    updatedAt: folder.updatedAt
                )
            )
        }

        let parentByID = Dictionary(uniqueKeysWithValues: uniqueFolders.map { ($0.id, $0.parentID) })
        for index in uniqueFolders.indices {
            let folderID = uniqueFolders[index].id
            let candidateParentID = uniqueFolders[index].parentID
            guard isValidSessionFolderParent(candidateParentID, for: folderID, parentByID: parentByID) else {
                uniqueFolders[index].parentID = nil
                continue
            }
        }

        return uniqueFolders
    }

    private static func isValidSessionFolderParent(
        _ parentID: UUID?,
        for folderID: UUID,
        parentByID: [UUID: UUID?]
    ) -> Bool {
        guard let parentID else { return true }
        guard parentID != folderID else { return false }
        guard parentByID[parentID] != nil else { return false }

        var cursor: UUID? = parentID
        var visited = Set<UUID>()
        while let current = cursor {
            guard visited.insert(current).inserted else { return false }
            if current == folderID { return false }
            if let nextParent = parentByID[current] {
                cursor = nextParent
            } else {
                cursor = nil
            }
        }

        return true
    }

    private static func accumulateRequestTokens(_ usage: MessageTokenUsage?, to totals: inout RequestLogTokenTotals) {
        guard let usage else { return }
        totals.sentTokens += usage.promptTokens ?? 0
        totals.receivedTokens += usage.completionTokens ?? 0
        totals.thinkingTokens += usage.thinkingTokens ?? 0
        totals.cacheWriteTokens += usage.cacheWriteTokens ?? 0
        totals.cacheReadTokens += usage.cacheReadTokens ?? 0
        totals.totalTokens += usage.totalTokens ?? 0
    }

    private static func loadRequestLogEnvelope() throws -> RequestLogFileEnvelope? {
        let fileURL = requestLogsFileURL()
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(RequestLogFileEnvelope.self, from: data)
    }

    private static func writeRequestLogEnvelope(_ envelope: RequestLogFileEnvelope) throws {
        let fileURL = requestLogsFileURL()
        try ensureDirectoryExists(fileURL.deletingLastPathComponent())

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(envelope)
        try data.write(to: fileURL, options: [.atomicWrite, .completeFileProtection])
    }

    private static func loadSessionIndexFile() -> SessionIndexFilePayload? {
        let fileURL = sessionIndexFileURLCurrent()
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder().decode(SessionIndexFilePayload.self, from: data)
        } catch {
            logger.warning("读取会话索引文件失败: \(error.localizedDescription)")
            return nil
        }
    }

    private static func writeSessionIndexFile(_ index: SessionIndexFilePayload) throws {
        let url = sessionIndexFileURLCurrent()
        try ensureDirectoryExists(url.deletingLastPathComponent())

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(index)
        try data.write(to: url, options: [.atomicWrite, .completeFileProtection])
    }

    private static func loadSessionSummaryFile(for sessionID: UUID) throws -> SessionRecordSummaryPayload? {
        let url = sessionRecordFileURL(for: sessionID)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }

        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(SessionRecordSummaryPayload.self, from: data)
    }

    private static func loadSessionRecordFile(for sessionID: UUID) throws -> SessionRecordFilePayload? {
        let url = sessionRecordFileURL(for: sessionID)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }

        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(SessionRecordFilePayload.self, from: data)
    }

    private static func writeSessionRecordFile(_ record: SessionRecordFilePayload, for sessionID: UUID) throws {
        let url = sessionRecordFileURL(for: sessionID)
        try ensureDirectoryExists(url.deletingLastPathComponent())

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(record)
        try data.write(to: url, options: [.atomicWrite, .completeFileProtection])
    }

    private static func removeLegacySourceFiles(sessions: [ChatSession]) throws {
        let legacyIndexURL = legacySessionIndexFileURL()
        let legacyMessageURLs = sessions.map { legacyMessagesFileURL(for: $0.id) }

        try removeItemIfExists(at: legacyIndexURL)
        for sourceURL in legacyMessageURLs {
            try removeItemIfExists(at: sourceURL)
        }

        logger.info("\(migrationLogPrefix) 旧版会话索引与消息文件已清理。")
    }

    private static func migrateLegacySessionDirectoryToCurrentLayoutIfNeeded() {
        let legacySessionDirectory = legacySessionDirectoryURL()
        guard FileManager.default.fileExists(atPath: legacySessionDirectory.path) else {
            return
        }

        let legacySessionIndex = legacySessionDirectoryIndexFileURL()
        let legacySessionRecordsDirectory = legacySessionRecordsDirectoryURL()
        let currentIndexURL = sessionIndexFileURLCurrent()
        let currentSessionsDirectory = currentSessionRecordsDirectory()

        do {
            try ensureDirectoryExists(currentSessionsDirectory)

            if FileManager.default.fileExists(atPath: legacySessionIndex.path) {
                if FileManager.default.fileExists(atPath: currentIndexURL.path) {
                    try mergeLegacySessionIndexIntoCurrentIfNeeded(
                        currentIndexURL: currentIndexURL,
                        legacyIndexURL: legacySessionIndex
                    )
                    try removeItemIfExists(at: legacySessionIndex)
                } else {
                    try moveItemIfExists(from: legacySessionIndex, to: currentIndexURL)
                }
            }

            if FileManager.default.fileExists(atPath: legacySessionRecordsDirectory.path) {
                let sessionFiles = try FileManager.default.contentsOfDirectory(
                    at: legacySessionRecordsDirectory,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )

                for sourceURL in sessionFiles where sourceURL.pathExtension.lowercased() == "json" {
                    let targetURL = currentSessionsDirectory.appendingPathComponent(sourceURL.lastPathComponent)
                    if FileManager.default.fileExists(atPath: targetURL.path) {
                        try removeItemIfExists(at: sourceURL)
                    } else {
                        try moveItemIfExists(from: sourceURL, to: targetURL)
                    }
                }
            }

            try removeItemIfExists(at: legacySessionDirectory)
            logger.info("\(migrationLogPrefix) 旧目录数据已迁移到 ChatSessions 根目录并清理完成。")
        } catch {
            logger.warning("\(migrationLogPrefix) 旧目录迁移失败: \(error.localizedDescription)")
        }
    }

    private static func moveItemIfExists(from source: URL, to destination: URL) throws {
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        try ensureDirectoryExists(destination.deletingLastPathComponent())
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: source, to: destination)
    }

    private static func removeItemIfExists(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    private static func cleanupLegacyArtifactsIfPossible() {
        let hasLegacyIndex = FileManager.default.fileExists(atPath: legacySessionIndexFileURL().path)
        let hasLegacyMessages = hasLegacyMessageFiles()
        guard !hasLegacyIndex && !hasLegacyMessages else {
            return
        }

        let legacyArchiveURL = legacyArchiveDirectoryURL()
        guard FileManager.default.fileExists(atPath: legacyArchiveURL.path) else {
            return
        }

        do {
            try removeItemIfExists(at: legacyArchiveURL)
            logger.info("\(migrationLogPrefix) legacy 目录已自动清理。")
        } catch {
            logger.warning("\(migrationLogPrefix) 清理 legacy 目录失败: \(error.localizedDescription)")
        }
    }

    private static func mergeLegacySessionIndexIntoCurrentIfNeeded(
        currentIndexURL: URL,
        legacyIndexURL: URL
    ) throws {
        let decoder = JSONDecoder()
        let currentData = try Data(contentsOf: currentIndexURL)
        let legacyData = try Data(contentsOf: legacyIndexURL)
        let currentIndex = try decoder.decode(SessionIndexFilePayload.self, from: currentData)
        let legacyIndex = try decoder.decode(SessionIndexFilePayload.self, from: legacyData)

        var existingIDs = Set(currentIndex.sessions.map(\.id))
        var mergedSessions = currentIndex.sessions
        for item in legacyIndex.sessions where !existingIDs.contains(item.id) {
            mergedSessions.append(item)
            existingIDs.insert(item.id)
        }

        guard mergedSessions.count != currentIndex.sessions.count else {
            return
        }

        let mergedIndex = SessionIndexFilePayload(
            schemaVersion: sessionStoreSchemaVersion,
            updatedAt: iso8601Timestamp(),
            sessions: mergedSessions
        )
        try writeSessionIndexFile(mergedIndex)
        logger.info("\(migrationLogPrefix) 已合并旧目录与当前会话索引，新增 \(mergedSessions.count - currentIndex.sessions.count) 个会话条目。")
    }

    private static func logCompatibilityReminderIfNeeded(trigger: String) {
        compatibilityReminderLock.lock()
        defer { compatibilityReminderLock.unlock() }

        guard !hasLoggedCompatibilityReminder else { return }

        let hasCurrentIndex = FileManager.default.fileExists(atPath: sessionIndexFileURLCurrent().path)
        let hasLegacySessionDirectory = hasLegacySessionArtifacts()
        let hasLegacyIndex = FileManager.default.fileExists(atPath: legacySessionIndexFileURL().path)
        let hasLegacyMessages = hasLegacyMessageFiles()

        let legacyStatus: String
        if hasLegacySessionDirectory {
            legacyStatus = "检测到旧目录历史文件，将自动迁移到 ChatSessions 根目录。"
        } else if hasLegacyIndex || hasLegacyMessages {
            legacyStatus = "检测到 legacy 文件，已启用前向兼容读取。"
        } else {
            legacyStatus = "当前未检测到旧目录或 legacy 历史文件。"
        }

        logger.info("\(compatibilityReminderPrefix) 触发点=\(trigger)，存储状态: currentIndex=\(hasCurrentIndex), legacySessionDirectory=\(hasLegacySessionDirectory), legacyIndex=\(hasLegacyIndex), legacyMessages=\(hasLegacyMessages)。\(legacyStatus)")
        hasLoggedCompatibilityReminder = true
    }

    private static func hasLegacySessionArtifacts() -> Bool {
        let legacySessionDirectory = legacySessionDirectoryURL()
        return FileManager.default.fileExists(atPath: legacySessionDirectory.path)
    }

    private static func hasLegacyMessageFiles() -> Bool {
        let chatsDirectory = getChatsDirectory()
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: chatsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }

        return entries.contains { entry in
            let fileName = entry.lastPathComponent
            return fileName.range(of: "^[0-9A-Fa-f-]{36}\\.json$", options: .regularExpression) != nil
        }
    }

    private static func ensureDirectoryExists(_ directoryURL: URL) throws {
        if !FileManager.default.fileExists(atPath: directoryURL.path) {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }
    }

    private static func currentSessionRecordsDirectory() -> URL {
        let directory = getChatsDirectory().appendingPathComponent(sessionRecordsDirectoryName)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    private static func requestLogsDirectoryURL() -> URL {
        let directory = getChatsDirectory().appendingPathComponent(requestLogsDirectoryName)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    private static func dailyPulseDirectoryURL() -> URL {
        let directory = getChatsDirectory().appendingPathComponent(dailyPulseDirectoryName)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    private static func sessionIndexFileURLCurrent() -> URL {
        getChatsDirectory().appendingPathComponent(sessionIndexFileName)
    }

    private static func sessionFoldersFileURL() -> URL {
        getChatsDirectory().appendingPathComponent(sessionFoldersFileName)
    }

    private static func requestLogsFileURL() -> URL {
        requestLogsDirectoryURL().appendingPathComponent(requestLogsFileName)
    }

    private static func effectiveRequestLogRetentionLimit() -> Int {
        max(requestLogRetentionLimitOverride ?? defaultRequestLogRetentionLimit, 1)
    }

    private static func dailyPulseRunsFileURL() -> URL {
        dailyPulseDirectoryURL().appendingPathComponent(dailyPulseRunsFileName)
    }

    private static func dailyPulseFeedbackHistoryFileURL() -> URL {
        dailyPulseDirectoryURL().appendingPathComponent(dailyPulseFeedbackHistoryFileName)
    }

    private static func dailyPulsePendingCurationFileURL() -> URL {
        dailyPulseDirectoryURL().appendingPathComponent(dailyPulsePendingCurationFileName)
    }

    private static func dailyPulseExternalSignalsFileURL() -> URL {
        dailyPulseDirectoryURL().appendingPathComponent(dailyPulseExternalSignalsFileName)
    }

    private static func dailyPulseTasksFileURL() -> URL {
        dailyPulseDirectoryURL().appendingPathComponent(dailyPulseTasksFileName)
    }

    private static func sessionRecordFileURL(for sessionID: UUID) -> URL {
        currentSessionRecordsDirectory().appendingPathComponent("\(sessionID.uuidString).json")
    }

    private static func legacySessionDirectoryURL() -> URL {
        getChatsDirectory().appendingPathComponent(legacySessionDirectoryName)
    }

    private static func legacySessionDirectoryIndexFileURL() -> URL {
        legacySessionDirectoryURL().appendingPathComponent(sessionIndexFileName)
    }

    private static func legacySessionRecordsDirectoryURL() -> URL {
        legacySessionDirectoryURL().appendingPathComponent(sessionRecordsDirectoryName)
    }

    private static func legacySessionRecordFileURL(for sessionID: UUID) -> URL {
        legacySessionRecordsDirectoryURL().appendingPathComponent("\(sessionID.uuidString).json")
    }

    private static func legacySessionIndexFileURL() -> URL {
        getChatsDirectory().appendingPathComponent("sessions.json")
    }

    private static func legacyMessagesFileURL(for sessionID: UUID) -> URL {
        getChatsDirectory().appendingPathComponent("\(sessionID.uuidString).json")
    }

    private static func legacyArchiveDirectoryURL() -> URL {
        getChatsDirectory().appendingPathComponent(legacyArchiveDirectoryName)
    }

    private static func iso8601Timestamp() -> String {
        iso8601Timestamp(from: Date())
    }

    private static func iso8601Timestamp(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func parseISO8601Date(_ value: String?) -> Date? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = formatter.date(from: value) {
            return parsed
        }

        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func inferToolCallsPlacement(from content: String) -> ToolCallsPlacement {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return .afterReasoning
        }
        let lowered = trimmed.lowercased()
        let startsWithThought = lowered.hasPrefix("<thought") || lowered.hasPrefix("<thinking") || lowered.hasPrefix("<think")
        if startsWithThought {
            let hasClosing = lowered.contains("</thought>") || lowered.contains("</thinking>") || lowered.contains("</think>")
            if !hasClosing {
                return .afterReasoning
            }
        }
        let contentWithoutThought = stripThoughtTags(from: content)
        if !contentWithoutThought.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .afterContent
        }
        if lowered.contains("<thought") || lowered.contains("<thinking") || lowered.contains("<think") {
            return .afterReasoning
        }
        return .afterContent
    }

    private static func stripThoughtTags(from text: String) -> String {
        let pattern = "<(thought|thinking|think)>(.*?)</\\1>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
    }
    
    // MARK: - 音频文件持久化
    
    /// 获取用于存储音频文件的目录URL
    /// - Returns: 音频存储目录的URL路径
    public static func getAudioDirectory() -> URL {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        let audioDirectory = paths[0].appendingPathComponent("AudioFiles")
        if !FileManager.default.fileExists(atPath: audioDirectory.path) {
            logger.info("Audio directory does not exist, creating: \(audioDirectory.path)")
            try? FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        }
        return audioDirectory
    }
    
    /// 保存音频数据到文件
    /// - Parameters:
    ///   - data: 音频数据
    ///   - fileName: 文件名（包含扩展名）
    /// - Returns: 保存成功返回文件URL，失败返回nil
    @discardableResult
    public static func saveAudio(_ data: Data, fileName: String) -> URL? {
        let fileURL = getAudioDirectory().appendingPathComponent(fileName)
        logger.info("Saving audio file: \(fileName)")
        
        do {
            try data.write(to: fileURL, options: [.atomicWrite, .completeFileProtection])
            logger.info("Audio file saved successfully: \(fileName)")
            return fileURL
        } catch {
            logger.error("Failed to save audio file \(fileName): \(error.localizedDescription)")
            return nil
        }
    }
    
    /// 加载音频数据
    /// - Parameter fileName: 文件名（包含扩展名）
    /// - Returns: 音频数据，如果文件不存在则返回nil
    public static func loadAudio(fileName: String) -> Data? {
        let fileURL = getAudioDirectory().appendingPathComponent(fileName)
        logger.info("Loading audio file: \(fileName)")
        
        do {
            let data = try Data(contentsOf: fileURL)
            logger.info("Audio file loaded successfully: \(fileName)")
            return data
        } catch {
            logger.warning("Failed to load audio file \(fileName): \(error.localizedDescription)")
            return nil
        }
    }
    
    /// 检查音频文件是否存在
    /// - Parameter fileName: 文件名（包含扩展名）
    /// - Returns: 文件是否存在
    public static func audioFileExists(fileName: String) -> Bool {
        let fileURL = getAudioDirectory().appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: fileURL.path)
    }
    
    /// 删除指定的音频文件
    /// - Parameter fileName: 文件名（包含扩展名）
    public static func deleteAudio(fileName: String) {
        let fileURL = getAudioDirectory().appendingPathComponent(fileName)
        logger.info("Deleting audio file: \(fileName)")
        
        do {
            try FileManager.default.removeItem(at: fileURL)
            logger.info("Audio file deleted successfully: \(fileName)")
        } catch {
            logger.warning("Failed to delete audio file \(fileName): \(error.localizedDescription)")
        }
    }
    
    /// 删除会话相关的所有音频文件
    /// - Parameters:
    ///   - messages: 会话中的消息列表
    public static func deleteAudioFiles(for messages: [ChatMessage]) {
        let audioFileNames = messages.compactMap { $0.audioFileName }
        for fileName in audioFileNames {
            deleteAudio(fileName: fileName)
        }
        if !audioFileNames.isEmpty {
            logger.info("Deleted \(audioFileNames.count) audio files for session.")
        }
    }
    
    /// 获取所有音频文件
    /// - Returns: 音频文件名数组
    public static func getAllAudioFileNames() -> [String] {
        let directory = getAudioDirectory()
        do {
            let fileURLs = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            return fileURLs.map { $0.lastPathComponent }
        } catch {
            logger.warning("Failed to list audio files: \(error.localizedDescription)")
            return []
        }
    }
    
    // MARK: - 图片文件持久化
    
    /// 获取用于存储图片文件的目录URL
    /// - Returns: 图片存储目录的URL路径
    public static func getImageDirectory() -> URL {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        let imageDirectory = paths[0].appendingPathComponent("ImageFiles")
        if !FileManager.default.fileExists(atPath: imageDirectory.path) {
            logger.info("Image directory does not exist, creating: \(imageDirectory.path)")
            try? FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
        }
        return imageDirectory
    }
    
    /// 保存图片数据到文件
    /// - Parameters:
    ///   - data: 图片数据
    ///   - fileName: 文件名（包含扩展名）
    /// - Returns: 保存成功返回文件URL，失败返回nil
    @discardableResult
    public static func saveImage(_ data: Data, fileName: String) -> URL? {
        let fileURL = getImageDirectory().appendingPathComponent(fileName)
        logger.info("Saving image file: \(fileName)")
        
        do {
            try data.write(to: fileURL, options: [.atomicWrite, .completeFileProtection])
            logger.info("Image file saved successfully: \(fileName)")
            return fileURL
        } catch {
            logger.error("Failed to save image file \(fileName): \(error.localizedDescription)")
            return nil
        }
    }
    
    /// 加载图片数据
    /// - Parameter fileName: 文件名（包含扩展名）
    /// - Returns: 图片数据，如果文件不存在则返回nil
    public static func loadImage(fileName: String) -> Data? {
        let fileURL = getImageDirectory().appendingPathComponent(fileName)
        
        do {
            let data = try Data(contentsOf: fileURL)
            return data
        } catch {
            logger.warning("Failed to load image file \(fileName): \(error.localizedDescription)")
            return nil
        }
    }
    
    /// 检查图片文件是否存在
    /// - Parameter fileName: 文件名（包含扩展名）
    /// - Returns: 文件是否存在
    public static func imageFileExists(fileName: String) -> Bool {
        let fileURL = getImageDirectory().appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: fileURL.path)
    }
    
    /// 删除指定的图片文件
    /// - Parameter fileName: 文件名（包含扩展名）
    public static func deleteImage(fileName: String) {
        let fileURL = getImageDirectory().appendingPathComponent(fileName)
        logger.info("Deleting image file: \(fileName)")
        
        do {
            try FileManager.default.removeItem(at: fileURL)
            logger.info("Image file deleted successfully: \(fileName)")
        } catch {
            logger.warning("Failed to delete image file \(fileName): \(error.localizedDescription)")
        }
    }
    
    /// 删除会话相关的所有图片文件
    /// - Parameters:
    ///   - messages: 会话中的消息列表
    public static func deleteImageFiles(for messages: [ChatMessage]) {
        let imageFileNames = messages.flatMap { $0.imageFileNames ?? [] }
        for fileName in imageFileNames {
            deleteImage(fileName: fileName)
        }
        if !imageFileNames.isEmpty {
            logger.info("Deleted \(imageFileNames.count) image files for session.")
        }
    }
    
    /// 获取所有图片文件名
    /// - Returns: 图片文件名数组
    public static func getAllImageFileNames() -> [String] {
        let directory = getImageDirectory()
        do {
            let fileURLs = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            return fileURLs.map { $0.lastPathComponent }
        } catch {
            logger.warning("Failed to list image files: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - 通用文件持久化

    /// 获取用于存储文件附件的目录URL
    /// - Returns: 文件附件存储目录的URL路径
    public static func getFileDirectory() -> URL {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        let fileDirectory = paths[0].appendingPathComponent("FileAttachments")
        if !FileManager.default.fileExists(atPath: fileDirectory.path) {
            logger.info("File attachment directory does not exist, creating: \(fileDirectory.path)")
            try? FileManager.default.createDirectory(at: fileDirectory, withIntermediateDirectories: true)
        }
        return fileDirectory
    }

    /// 保存文件数据到文件
    /// - Parameters:
    ///   - data: 文件数据
    ///   - fileName: 文件名（包含扩展名）
    /// - Returns: 保存成功返回文件URL，失败返回nil
    @discardableResult
    public static func saveFile(_ data: Data, fileName: String) -> URL? {
        let fileURL = getFileDirectory().appendingPathComponent(fileName)
        logger.info("Saving file attachment: \(fileName)")
        
        do {
            try data.write(to: fileURL, options: [.atomicWrite, .completeFileProtection])
            logger.info("File attachment saved successfully: \(fileName)")
            return fileURL
        } catch {
            logger.error("Failed to save file attachment \(fileName): \(error.localizedDescription)")
            return nil
        }
    }
    
    /// 加载文件数据
    /// - Parameter fileName: 文件名（包含扩展名）
    /// - Returns: 文件数据，如果文件不存在则返回nil
    public static func loadFile(fileName: String) -> Data? {
        let fileURL = getFileDirectory().appendingPathComponent(fileName)
        logger.info("Loading file attachment: \(fileName)")
        
        do {
            let data = try Data(contentsOf: fileURL)
            logger.info("File attachment loaded successfully: \(fileName)")
            return data
        } catch {
            logger.warning("Failed to load file attachment \(fileName): \(error.localizedDescription)")
            return nil
        }
    }
    
    /// 检查文件是否存在
    /// - Parameter fileName: 文件名（包含扩展名）
    /// - Returns: 文件是否存在
    public static func fileExists(fileName: String) -> Bool {
        let fileURL = getFileDirectory().appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: fileURL.path)
    }
    
    /// 删除指定的文件
    /// - Parameter fileName: 文件名（包含扩展名）
    public static func deleteFile(fileName: String) {
        let fileURL = getFileDirectory().appendingPathComponent(fileName)
        logger.info("Deleting file attachment: \(fileName)")
        
        do {
            try FileManager.default.removeItem(at: fileURL)
            logger.info("File attachment deleted successfully: \(fileName)")
        } catch {
            logger.warning("Failed to delete file attachment \(fileName): \(error.localizedDescription)")
        }
    }
    
    /// 删除会话相关的所有文件附件
    /// - Parameters:
    ///   - messages: 会话中的消息列表
    public static func deleteFileFiles(for messages: [ChatMessage]) {
        let fileNames = messages.flatMap { $0.fileFileNames ?? [] }
        for fileName in fileNames {
            deleteFile(fileName: fileName)
        }
        if !fileNames.isEmpty {
            logger.info("Deleted \(fileNames.count) file attachments for session.")
        }
    }
    
    /// 获取所有文件附件名
    /// - Returns: 文件附件名数组
    public static func getAllFileNames() -> [String] {
        let directory = getFileDirectory()
        do {
            let fileURLs = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            return fileURLs.map { $0.lastPathComponent }
        } catch {
            logger.warning("Failed to list file attachments: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - 字体文件持久化

    /// 获取用于存储字体文件的目录URL
    /// - Returns: 字体存储目录的URL路径
    public static func getFontDirectory() -> URL {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        let fontDirectory = paths[0].appendingPathComponent("FontFiles")
        if !FileManager.default.fileExists(atPath: fontDirectory.path) {
            logger.info("Font directory does not exist, creating: \(fontDirectory.path)")
            try? FileManager.default.createDirectory(at: fontDirectory, withIntermediateDirectories: true)
        }
        return fontDirectory
    }

    /// 保存字体数据到文件
    /// - Parameters:
    ///   - data: 字体数据
    ///   - fileName: 文件名（包含扩展名）
    /// - Returns: 保存成功返回文件URL，失败返回nil
    @discardableResult
    public static func saveFont(_ data: Data, fileName: String) -> URL? {
        let fileURL = getFontDirectory().appendingPathComponent(fileName)
        logger.info("Saving font file: \(fileName)")

        do {
            try data.write(to: fileURL, options: [.atomicWrite, .completeFileProtection])
            logger.info("Font file saved successfully: \(fileName)")
            return fileURL
        } catch {
            logger.error("Failed to save font file \(fileName): \(error.localizedDescription)")
            return nil
        }
    }

    /// 加载字体数据
    /// - Parameter fileName: 文件名（包含扩展名）
    /// - Returns: 字体数据，如果文件不存在则返回nil
    public static func loadFont(fileName: String) -> Data? {
        let fileURL = getFontDirectory().appendingPathComponent(fileName)

        do {
            return try Data(contentsOf: fileURL)
        } catch {
            logger.warning("Failed to load font file \(fileName): \(error.localizedDescription)")
            return nil
        }
    }

    /// 删除指定字体文件
    /// - Parameter fileName: 文件名（包含扩展名）
    public static func deleteFont(fileName: String) {
        let fileURL = getFontDirectory().appendingPathComponent(fileName)
        logger.info("Deleting font file: \(fileName)")

        do {
            try FileManager.default.removeItem(at: fileURL)
            logger.info("Font file deleted successfully: \(fileName)")
        } catch {
            logger.warning("Failed to delete font file \(fileName): \(error.localizedDescription)")
        }
    }

    /// 获取所有字体文件名
    /// - Returns: 字体文件名数组
    public static func getAllFontFileNames() -> [String] {
        let directory = getFontDirectory()
        do {
            let fileURLs = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            return fileURLs.map { $0.lastPathComponent }
        } catch {
            logger.warning("Failed to list font files: \(error.localizedDescription)")
            return []
        }
    }
}

// MARK: - 字体资产与路由

public enum FontSemanticRole: String, Codable, CaseIterable, Identifiable {
    case body
    case emphasis
    case strong
    case code

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .body:
            return "正文"
        case .emphasis:
            return "斜体"
        case .strong:
            return "粗体"
        case .code:
            return "代码"
        }
    }
}

public enum FontFallbackScope: String, Codable, CaseIterable, Identifiable {
    /// 当前逻辑：以整段样本检测覆盖率，必须整段都可渲染才命中该字体。
    case segment
    /// 新逻辑：按单字回退，只要候选字体能覆盖样本中的任意字符即可命中。
    case character

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .segment:
            return "整段"
        case .character:
            return "单字"
        }
    }

    public var summary: String {
        switch self {
        case .segment:
            return "当前行为：一条文本里只要有字形缺失，就整段降级到下一优先级字体。"
        case .character:
            return "按单字回退：优先保留高优先级字体，缺失字形再由系统进行逐字回退。"
        }
    }
}

public struct FontAssetRecord: Codable, Identifiable, Equatable {
    public var id: UUID
    public var fileName: String
    public var checksum: String
    public var displayName: String
    public var postScriptName: String
    public var importedAt: Date
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        fileName: String,
        checksum: String,
        displayName: String,
        postScriptName: String,
        importedAt: Date = Date(),
        isEnabled: Bool = true
    ) {
        self.id = id
        self.fileName = fileName
        self.checksum = checksum
        self.displayName = displayName
        self.postScriptName = postScriptName
        self.importedAt = importedAt
        self.isEnabled = isEnabled
    }
}

public struct FontRouteConfiguration: Codable, Equatable {
    public struct LanguageBucketConfiguration: Codable, Equatable {
        public var body: [UUID]
        public var emphasis: [UUID]
        public var strong: [UUID]
        public var code: [UUID]

        public init(
            body: [UUID] = [],
            emphasis: [UUID] = [],
            strong: [UUID] = [],
            code: [UUID] = []
        ) {
            self.body = body
            self.emphasis = emphasis
            self.strong = strong
            self.code = code
        }
    }

    public var body: [UUID]
    public var emphasis: [UUID]
    public var strong: [UUID]
    public var code: [UUID]
    /// 预留字段：后续可扩展为按语言桶优先级配置
    public var languageBuckets: [String: LanguageBucketConfiguration]

    public init(
        body: [UUID] = [],
        emphasis: [UUID] = [],
        strong: [UUID] = [],
        code: [UUID] = [],
        languageBuckets: [String: LanguageBucketConfiguration] = [:]
    ) {
        self.body = body
        self.emphasis = emphasis
        self.strong = strong
        self.code = code
        self.languageBuckets = languageBuckets
    }

    public func chain(for role: FontSemanticRole) -> [UUID] {
        switch role {
        case .body:
            return body
        case .emphasis:
            return emphasis
        case .strong:
            return strong
        case .code:
            return code
        }
    }

    public mutating func setChain(_ ids: [UUID], for role: FontSemanticRole) {
        switch role {
        case .body:
            body = ids
        case .emphasis:
            emphasis = ids
        case .strong:
            strong = ids
        case .code:
            code = ids
        }
    }
}

public enum FontLibraryError: LocalizedError {
    case invalidFontData
    case unsupportedFontFileExtension
    case saveFailed
    case deleteFailed

    public var errorDescription: String? {
        switch self {
        case .invalidFontData:
            return "无法识别该字体文件。"
        case .unsupportedFontFileExtension:
            return "仅支持导入 TTF / OTF / TTC / WOFF / WOFF2 字体文件。"
        case .saveFailed:
            return "保存字体文件失败。"
        case .deleteFailed:
            return "删除字体文件失败。"
        }
    }
}

public enum FontLibrary {
    private static let manifestFileName = "font-manifest-v1.json"
    private static let routeConfigFileName = "font-routes-v1.json"
    private static let supportedFontFileExtensions: Set<String> = ["ttf", "otf", "ttc", "woff", "woff2"]
    public static let customFontEnabledStorageKey = "font.useCustomFonts"
    public static let fallbackScopeStorageKey = "font.fallbackScope"
    private static let cacheLock = NSLock()

    private struct RuntimeSnapshot {
        var isPrepared = false
        var assets: [FontAssetRecord] = []
        var routeConfiguration = FontRouteConfiguration()
        var fallbackPostScriptNamesByRole: [FontSemanticRole: [String]] = [:]
        var preferredPostScriptNameByRole: [FontSemanticRole: String] = [:]
        var isCustomFontEnabled = true
        var fallbackScope: FontFallbackScope = .segment
    }

    private static var runtimeSnapshot = RuntimeSnapshot()

    private static var manifestURL: URL {
        Persistence.getFontDirectory().appendingPathComponent(manifestFileName)
    }

    private static var routeConfigURL: URL {
        Persistence.getFontDirectory().appendingPathComponent(routeConfigFileName)
    }

    /// 全局开关：是否启用自定义字体（默认启用）。
    public static var isCustomFontEnabled: Bool {
        withRuntimeSnapshot { $0.isCustomFontEnabled }
    }

    /// 字体回退范围设置（默认整段）。
    public static var fallbackScope: FontFallbackScope {
        withRuntimeSnapshot { $0.fallbackScope }
    }

    public static func preloadRuntimeCacheAsync(forceReload: Bool = false) {
        Task.detached(priority: .utility) {
            preloadRuntimeCache(forceReload: forceReload)
            await MainActor.run {
                NotificationCenter.default.post(name: .syncFontsUpdated, object: nil)
            }
        }
    }

    public static func preloadRuntimeCache(forceReload: Bool = false) {
        if !forceReload, withRuntimeSnapshot({ $0.isPrepared }) {
            return
        }

        let assets = loadAssetsFromDisk()
        let routeConfiguration = loadRouteConfigurationFromDisk()
        let settings = loadFontSettingsFromUserDefaults()

        if settings.isCustomFontEnabled {
            for asset in assets where asset.isEnabled {
                registerFontFileIfNeeded(fileName: asset.fileName)
            }
        }

        let roleMappings = buildRoleMappings(
            assets: assets,
            routeConfiguration: routeConfiguration,
            isCustomFontEnabled: settings.isCustomFontEnabled
        )

        updateRuntimeSnapshot { snapshot in
            snapshot.isPrepared = true
            snapshot.assets = assets
            snapshot.routeConfiguration = routeConfiguration
            snapshot.fallbackPostScriptNamesByRole = roleMappings.fallback
            snapshot.preferredPostScriptNameByRole = roleMappings.preferred
            snapshot.isCustomFontEnabled = settings.isCustomFontEnabled
            snapshot.fallbackScope = settings.fallbackScope
        }
    }

    public static func loadAssets() -> [FontAssetRecord] {
        ensureRuntimeCachePrepared()
        return withRuntimeSnapshot { $0.assets }
    }

    @discardableResult
    public static func saveAssets(_ assets: [FontAssetRecord]) -> Bool {
        let sorted = assets.sorted { lhs, rhs in
            if lhs.importedAt != rhs.importedAt {
                return lhs.importedAt > rhs.importedAt
            }
            return lhs.fileName.localizedCaseInsensitiveCompare(rhs.fileName) == .orderedAscending
        }
        guard let data = try? JSONEncoder().encode(sorted) else { return false }
        do {
            try data.write(to: manifestURL, options: [.atomic])
            preloadRuntimeCache(forceReload: true)
            return true
        } catch {
            logger.error("Failed to save font manifest: \(error.localizedDescription)")
            return false
        }
    }

    public static func loadRouteConfiguration() -> FontRouteConfiguration {
        ensureRuntimeCachePrepared()
        return withRuntimeSnapshot { $0.routeConfiguration }
    }

    @discardableResult
    public static func saveRouteConfiguration(_ configuration: FontRouteConfiguration) -> Bool {
        guard let data = try? JSONEncoder().encode(configuration) else { return false }
        do {
            try data.write(to: routeConfigURL, options: [.atomic])
            preloadRuntimeCache(forceReload: true)
            return true
        } catch {
            logger.error("Failed to save font route configuration: \(error.localizedDescription)")
            return false
        }
    }

    public static func loadRouteConfigurationData() -> Data? {
        try? Data(contentsOf: routeConfigURL)
    }

    @discardableResult
    public static func saveRouteConfigurationData(_ data: Data?) -> Bool {
        let directory = Persistence.getFontDirectory()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        guard let data else {
            do {
                if FileManager.default.fileExists(atPath: routeConfigURL.path) {
                    try FileManager.default.removeItem(at: routeConfigURL)
                }
                preloadRuntimeCache(forceReload: true)
                return true
            } catch {
                logger.error("Failed to remove route config file: \(error.localizedDescription)")
                return false
            }
        }
        do {
            try data.write(to: routeConfigURL, options: [.atomic])
            preloadRuntimeCache(forceReload: true)
            return true
        } catch {
            logger.error("Failed to save route config data: \(error.localizedDescription)")
            return false
        }
    }

    public static func importFont(
        data: Data,
        fileName: String,
        preferredDisplayName: String? = nil
    ) throws -> FontAssetRecord {
        let normalizedExt = (fileName as NSString).pathExtension.lowercased()
        guard supportedFontFileExtensions.contains(normalizedExt) else {
            throw FontLibraryError.unsupportedFontFileExtension
        }

        guard let postScriptName = extractPostScriptName(from: data), !postScriptName.isEmpty else {
            throw FontLibraryError.invalidFontData
        }

        var assets = loadAssets()
        let checksum = data.sha256Hex
        if let existing = assets.first(where: { $0.checksum == checksum }) {
            registerFontFileIfNeeded(fileName: existing.fileName)
            return existing
        }

        let safeBaseName = sanitizeBaseName((fileName as NSString).deletingPathExtension)
        let targetFileName = uniqueFontFileName(
            baseName: safeBaseName.isEmpty ? "font" : safeBaseName,
            fileExtension: normalizedExt
        )

        guard Persistence.saveFont(data, fileName: targetFileName) != nil else {
            throw FontLibraryError.saveFailed
        }
        registerFontFileIfNeeded(fileName: targetFileName)

        let record = FontAssetRecord(
            fileName: targetFileName,
            checksum: checksum,
            displayName: preferredDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                ?? postScriptName,
            postScriptName: postScriptName
        )

        assets.append(record)
        _ = saveAssets(assets)
        var routes = loadRouteConfiguration()
        for role in FontSemanticRole.allCases {
            var chain = routes.chain(for: role)
            if !chain.contains(record.id) {
                chain.append(record.id)
                routes.setChain(chain, for: role)
            }
        }
        _ = saveRouteConfiguration(routes)
        return record
    }

    public static func deleteFontAsset(id: UUID) throws {
        var assets = loadAssets()
        guard let target = assets.first(where: { $0.id == id }) else { return }
        assets.removeAll { $0.id == id }
        if !saveAssets(assets) {
            throw FontLibraryError.deleteFailed
        }
        Persistence.deleteFont(fileName: target.fileName)
        var routes = loadRouteConfiguration()
        for role in FontSemanticRole.allCases {
            let chain = routes.chain(for: role).filter { $0 != id }
            routes.setChain(chain, for: role)
        }
        _ = saveRouteConfiguration(routes)
    }

    public static func updateChain(_ chain: [UUID], for role: FontSemanticRole) {
        var configuration = loadRouteConfiguration()
        let validIDs = Set(loadAssets().map(\.id))
        let normalizedChain = chain.filter { validIDs.contains($0) }
        configuration.setChain(normalizedChain, for: role)
        _ = saveRouteConfiguration(configuration)
    }

    @discardableResult
    public static func setAssetEnabled(id: UUID, isEnabled: Bool) -> Bool {
        var assets = loadAssets()
        guard let index = assets.firstIndex(where: { $0.id == id }) else { return false }
        guard assets[index].isEnabled != isEnabled else { return true }
        assets[index].isEnabled = isEnabled
        return saveAssets(assets)
    }

    public static func registerAllFontsIfNeeded() {
        preloadRuntimeCache(forceReload: true)
    }

    public static func fallbackPostScriptNames(for role: FontSemanticRole) -> [String] {
        withRuntimeSnapshot { snapshot in
            guard snapshot.isPrepared else { return [] }
            return snapshot.fallbackPostScriptNamesByRole[role] ?? []
        }
    }

    public static func resolvedPostScriptName(for role: FontSemanticRole) -> String? {
        withRuntimeSnapshot { snapshot in
            guard snapshot.isPrepared else { return nil }
            return snapshot.preferredPostScriptNameByRole[role]
        }
    }

    public static func adapterCacheToken() -> String {
        withRuntimeSnapshot { snapshot in
            let roleSignature = FontSemanticRole.allCases
                .map { snapshot.preferredPostScriptNameByRole[$0] ?? "-" }
                .joined(separator: "|")
            return "\(snapshot.isPrepared ? 1 : 0)|\(snapshot.isCustomFontEnabled ? 1 : 0)|\(roleSignature)"
        }
    }

    /// 按优先级链路查找可用字体；若无命中则返回 nil 由系统字体兜底。
    public static func resolvePostScriptName(
        for role: FontSemanticRole,
        sampleText: String
    ) -> String? {
        _ = sampleText
        return resolvedPostScriptName(for: role)
    }

    private static func sanitizeBaseName(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let mapped = trimmed.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let result = String(mapped).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return result
    }

    private static func uniqueFontFileName(baseName: String, fileExtension: String) -> String {
        var candidate = "\(baseName).\(fileExtension)"
        var counter = 1
        while FileManager.default.fileExists(atPath: Persistence.getFontDirectory().appendingPathComponent(candidate).path) {
            candidate = "\(baseName)-\(counter).\(fileExtension)"
            counter += 1
        }
        return candidate
    }

    private static func registerFontFileIfNeeded(fileName: String) {
#if canImport(CoreText)
        let fileURL = Persistence.getFontDirectory().appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        var error: Unmanaged<CFError>?
        let registered = CTFontManagerRegisterFontsForURL(fileURL as CFURL, .process, &error)
        if !registered, let nsError = error?.takeRetainedValue() {
            // 字体已注册等场景可继续运行，这里仅记录警告日志。
            logger.warning("Failed to register font file \(fileName): \(nsError)")
        }
#else
        _ = fileName
#endif
    }

    private static func ensureRuntimeCachePrepared() {
        if withRuntimeSnapshot({ !$0.isPrepared }) {
            preloadRuntimeCache(forceReload: false)
        }
    }

    private static func withRuntimeSnapshot<T>(_ body: (RuntimeSnapshot) -> T) -> T {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return body(runtimeSnapshot)
    }

    private static func updateRuntimeSnapshot(_ body: (inout RuntimeSnapshot) -> Void) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        body(&runtimeSnapshot)
    }

    private static func loadAssetsFromDisk() -> [FontAssetRecord] {
        guard let data = try? Data(contentsOf: manifestURL),
              let assets = try? JSONDecoder().decode([FontAssetRecord].self, from: data) else {
            return []
        }
        return assets
    }

    private static func loadRouteConfigurationFromDisk() -> FontRouteConfiguration {
        guard let data = try? Data(contentsOf: routeConfigURL),
              let configuration = try? JSONDecoder().decode(FontRouteConfiguration.self, from: data) else {
            return FontRouteConfiguration()
        }
        return configuration
    }

    private static func loadFontSettingsFromUserDefaults() -> (isCustomFontEnabled: Bool, fallbackScope: FontFallbackScope) {
        let customEnabled = (UserDefaults.standard.object(forKey: customFontEnabledStorageKey) as? Bool) ?? true
        let scope: FontFallbackScope
        if let rawValue = UserDefaults.standard.string(forKey: fallbackScopeStorageKey),
           let parsedScope = FontFallbackScope(rawValue: rawValue) {
            scope = parsedScope
        } else {
            scope = .segment
        }
        return (customEnabled, scope)
    }

    private static func buildRoleMappings(
        assets: [FontAssetRecord],
        routeConfiguration: FontRouteConfiguration,
        isCustomFontEnabled: Bool
    ) -> (fallback: [FontSemanticRole: [String]], preferred: [FontSemanticRole: String]) {
        guard isCustomFontEnabled else {
            return ([:], [:])
        }

        let enabledAssets = Dictionary(
            uniqueKeysWithValues: assets
                .filter(\.isEnabled)
                .map { ($0.id, $0) }
        )

        var fallbackByRole: [FontSemanticRole: [String]] = [:]
        var preferredByRole: [FontSemanticRole: String] = [:]

        for role in FontSemanticRole.allCases {
            let names = routeConfiguration
                .chain(for: role)
                .compactMap { enabledAssets[$0]?.postScriptName }
                .filter { !$0.isEmpty }
            fallbackByRole[role] = names
            if let first = names.first {
                preferredByRole[role] = first
            }
        }
        return (fallbackByRole, preferredByRole)
    }

    private static func extractPostScriptName(from data: Data) -> String? {
#if canImport(CoreText)
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromData(data as CFData) as? [CTFontDescriptor],
              let firstDescriptor = descriptors.first else {
            return nil
        }
        let postScriptName = CTFontDescriptorCopyAttribute(firstDescriptor, kCTFontNameAttribute) as? String
        if let postScriptName, !postScriptName.isEmpty {
            return postScriptName
        }
        let displayName = CTFontDescriptorCopyAttribute(firstDescriptor, kCTFontDisplayNameAttribute) as? String
        return displayName?.nonEmpty
#else
        _ = data
        return nil
#endif
    }

}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
