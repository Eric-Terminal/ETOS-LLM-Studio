// ============================================================================
// PersistenceDatabaseLifecycle.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责 Persistence 的 GRDB 入口、辅助存储、启动恢复与 SQLite 备份生命周期。
// ============================================================================

import Foundation
import os.log
import SQLite3
import GRDB
#if canImport(CoreText)
import CoreText
#endif

extension Persistence {
    private static func shouldUseGRDBStore() -> Bool {
        if let override = grdbEnabledOverrideForTests {
            return override
        }
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return false
        }
        return true
    }

    static func activeGRDBStore() -> PersistenceGRDBStore? {
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
            if quarantineDatabaseAfterInitializationFailure(kind: .chat, error: error) {
                do {
                    let store = try PersistenceGRDBStore(chatsDirectory: getChatsDirectory())
                    cachedGRDBStore = store
                    lastGRDBStoreInitializationFailedAt = nil
                    logger.info("聊天数据库已自动重建，GRDB 持久化继续启用。")
                    return store
                } catch {
                    logger.error("聊天数据库自动重建后仍初始化失败: \(String(describing: error))")
                }
            }
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
            let launchKind: LaunchDatabaseKind = kind == .config ? .config : .memory
            if quarantineDatabaseAfterInitializationFailure(kind: launchKind, error: error) {
                do {
                    let databaseURL = auxiliaryStoreDatabaseURL(for: kind)
                    let store = try PersistenceAuxiliaryGRDBStore(
                        databaseURL: databaseURL,
                        loggerCategory: kind.loggerCategory
                    )
                    cachedAuxiliaryStores[kind] = store
                    lastAuxiliaryStoreInitializationFailedAt[kind] = nil
                    logger.info("辅助数据库已自动重建(\(kind.rawValue))。")
                    return store
                } catch {
                    logger.error("辅助数据库自动重建后仍初始化失败(\(kind.rawValue)): \(String(describing: error))")
                }
            }
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
    }

    public static func legacyJSONMigrationStatus() -> LegacyJSONMigrationStatus {
        guard let store = activeGRDBStore() else {
            return LegacyJSONMigrationStatus(
                hasLegacyArtifacts: false,
                importCompleted: false,
                cleanupCompleted: false,
                requiresImportDecision: false,
                requiresCleanupDecision: false,
                estimatedLegacyBytes: 0,
                estimatedSessionCount: 0
            )
        }
        return store.legacyJSONMigrationStatus()
    }

    public static func migrateLegacyJSONIncrementally(
        shouldCleanupLegacyJSONAfterImport: Bool,
        throttleInterval: TimeInterval = 0.02,
        progressHandler: (@Sendable (LegacyJSONMigrationProgress) -> Void)? = nil
    ) async throws -> LegacyJSONMigrationResult {
        try await Task.detached(priority: .userInitiated) {
            guard let store = activeGRDBStore() else {
                throw LegacyJSONMigrationError.grdbUnavailable
            }
            do {
                return try store.migrateLegacyJSONIncrementally(
                    shouldCleanupLegacyJSONAfterImport: shouldCleanupLegacyJSONAfterImport,
                    throttleInterval: throttleInterval,
                    progressHandler: progressHandler
                )
            } catch {
                throw LegacyJSONMigrationError.importFailed(error.localizedDescription)
            }
        }.value
    }

    @discardableResult
    public static func cleanupLegacyJSONArtifactsAfterImport() async throws -> Bool {
        try await Task.detached(priority: .userInitiated) {
            guard let store = activeGRDBStore() else {
                throw LegacyJSONMigrationError.grdbUnavailable
            }
            do {
                return try store.cleanupLegacyJSONArtifactsAfterImport()
            } catch {
                throw LegacyJSONMigrationError.cleanupFailed(error.localizedDescription)
            }
        }.value
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
        hasScheduledLaunchBackupPoint = false
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

    @discardableResult
    public static func scheduleLaunchBackupPointAfterStartupIfEnabled() -> Task<Void, Never>? {
        scheduleLaunchBackupPointAfterStartupIfEnabled(delay: deferredLaunchBackupDelay)
    }

    @discardableResult
    public static func scheduleLaunchBackupPointAfterStartupIfEnabled(delay: TimeInterval) -> Task<Void, Never>? {
        guard UserDefaults.standard.bool(forKey: launchBackupEnabledKey) else { return nil }

        launchBackupAndRecoveryLock.lock()
        if hasScheduledLaunchBackupPoint || hasCreatedLaunchBackupPoint {
            launchBackupAndRecoveryLock.unlock()
            return nil
        }
        hasScheduledLaunchBackupPoint = true
        launchBackupAndRecoveryLock.unlock()

        return Task.detached(priority: .background) {
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            createLaunchBackupPointIfEnabled()
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

    private static func quarantineDatabaseAfterInitializationFailure(kind: LaunchDatabaseKind, error: Error) -> Bool {
        let sourceURL = databaseURL(for: kind)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sourceURL.path) else { return false }

        let timestamp = ISO8601DateFormatter()
            .string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let quarantineDirectory = sourceURL.deletingLastPathComponent()
            .appendingPathComponent("DatabaseQuarantine", isDirectory: true)
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let destinationURL = quarantineDirectory
            .appendingPathComponent("\(baseName)-\(timestamp).sqlite", isDirectory: false)

        do {
            try ensureDirectoryExists(quarantineDirectory)
            try moveItemIfExists(from: sourceURL, to: destinationURL)
            try moveItemIfExists(
                from: URL(fileURLWithPath: sourceURL.path + "-wal"),
                to: URL(fileURLWithPath: destinationURL.path + "-wal")
            )
            try moveItemIfExists(
                from: URL(fileURLWithPath: sourceURL.path + "-shm"),
                to: URL(fileURLWithPath: destinationURL.path + "-shm")
            )
            UserDefaults.standard.set(
                "检测到\(kind.displayName)无法打开或迁移，已隔离损坏文件并自动重建。",
                forKey: launchRecoveryNoticeUserDefaultsKey
            )
            logger.error("数据库初始化失败，已隔离后自动重建(\(kind.displayName)): \(error.localizedDescription)")
            return true
        } catch {
            logger.error("数据库隔离失败(\(kind.displayName)): \(error.localizedDescription)")
            return false
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

        try installVerifiedLaunchBackup(
            temporaryURL: tempBackupURL,
            backupURL: backupURL,
            fileManager: fileManager
        )
        removeSQLiteSidecars(at: backupURL)
        removeSQLiteSidecars(at: tempBackupURL)
        logger.info("启动备份已更新(\(kind.displayName)): \(backupURL.path)")
    }

    private static func installVerifiedLaunchBackup(
        temporaryURL: URL,
        backupURL: URL,
        fileManager: FileManager
    ) throws {
        if fileManager.fileExists(atPath: backupURL.path) {
            _ = try fileManager.replaceItemAt(
                backupURL,
                withItemAt: temporaryURL,
                backupItemName: nil,
                options: []
            )
        } else {
            try fileManager.moveItem(at: temporaryURL, to: backupURL)
        }
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
}
