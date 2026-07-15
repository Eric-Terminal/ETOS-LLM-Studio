// ============================================================================
// PersistenceDatabaseLifecycle.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责 Persistence 的 GRDB 入口、辅助存储、启动恢复与 SQLite 备份生命周期。
// ============================================================================

import Foundation
import os.log
import GRDB

extension Persistence {
    private static func shouldUseGRDBStore() -> Bool {
        if let override = grdbEnabledOverrideForTests {
            return override
        }
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return true
        }
        return true
    }

    static func activeGRDBStore() -> PersistenceGRDBStore? {
        guard shouldUseGRDBStore() else { return nil }
        guard !DatabaseEncryptionManager.shared.requiresManualUnlock else { return nil }
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

    static func activeAuxiliaryStore(kind: AuxiliaryStoreKind) -> PersistenceAuxiliaryGRDBStore? {
        guard shouldUseGRDBStore() else { return nil }
        guard !DatabaseEncryptionManager.shared.requiresManualUnlock else { return nil }
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

    static func auxiliaryStoreDatabaseURL(for kind: AuxiliaryStoreKind) -> URL {
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
        guard !DatabaseEncryptionManager.shared.requiresManualUnlock else {
            logger.info("数据库加密处于手动解锁模式，启动期等待用户输入主密码。")
            return
        }
        let launchPreparation = prepareDatabasesForLaunchIfNeeded()
        guard !launchPreparation.hasPendingRecoveryRequest else {
            logger.warning("启动阶段检测到可恢复的数据库损坏，等待用户确认。")
            return
        }
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
        pendingLaunchRecoveryNotice = nil
        pendingLaunchRecoveryRequest = nil
        pendingLaunchRecoveryKinds = []
        launchBackupAndRecoveryLock.unlock()
    }

    public static func consumeLaunchRecoveryNotice() -> String? {
        launchBackupAndRecoveryLock.lock()
        let pending = pendingLaunchRecoveryNotice
        pendingLaunchRecoveryNotice = nil
        launchBackupAndRecoveryLock.unlock()

        let message = pending ?? readAppConfigText(key: launchRecoveryNoticeKey)
        deleteAppConfig(key: launchRecoveryNoticeKey)
        return message
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
}
