// ============================================================================
// PersistenceLaunchBackupLifecycle.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责启动阶段数据库健康检查、自动恢复、隔离损坏库与 SQLite 启动备份。
// ============================================================================

import Foundation
import os.log
import GRDB

extension Persistence {
    public static func createLaunchBackupPointIfEnabled() {
        cleanupInterruptedLaunchBackupInstalls()
        guard isLaunchBackupEnabled() else { return }
        guard !hasPendingLaunchRecoveryRequest() else { return }

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
        guard isLaunchBackupEnabled() else { return nil }
        guard !hasPendingLaunchRecoveryRequest() else { return nil }

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

    static func prepareDatabasesForLaunchIfNeeded() -> LaunchPreparationResult {
        launchBackupAndRecoveryLock.lock()
        if hasPreparedLaunchDatabases {
            let cached = launchPreparationResult
            launchBackupAndRecoveryLock.unlock()
            return cached
        }
        hasPreparedLaunchDatabases = true
        launchBackupAndRecoveryLock.unlock()

        cleanupInterruptedLaunchBackupInstalls()
        guard isLaunchBackupEnabled() else {
            clearLaunchRecoveryNotice()
            clearPendingLaunchRecoveryRequest()
            return cacheLaunchPreparationResult(LaunchPreparationResult())
        }

        var result = LaunchPreparationResult()
        for kind in LaunchDatabaseKind.allCases {
            guard isSQLiteDatabaseHealthy(at: databaseURL(for: kind)) else {
                if hasUsableLaunchBackup(for: kind) {
                    result.recoverableKinds.append(kind)
                } else {
                    result.missingBackupKinds.append(kind)
                }
                continue
            }
        }

        setPendingLaunchRecoveryRequest(for: result.recoverableKinds)
        setLaunchRecoveryNotice(makeLaunchRecoveryNotice(from: result))

        return cacheLaunchPreparationResult(result)
    }

    @discardableResult
    private static func cacheLaunchPreparationResult(_ result: LaunchPreparationResult) -> LaunchPreparationResult {
        launchBackupAndRecoveryLock.lock()
        launchPreparationResult = result
        launchBackupAndRecoveryLock.unlock()
        return result
    }

    private static func isLaunchBackupEnabled() -> Bool {
        if let value = readAppConfigInteger(key: launchBackupEnabledKey) {
            return value != 0
        }
        if hasPendingLaunchRecoveryRequest() {
            return true
        }
        let isEnabled = AppConfigStore.boolValue(
            for: .syncBackupCreateOnLaunch,
            legacyUserDefaultsKey: launchBackupEnabledKey
        )
        return isEnabled || hasPendingLaunchRecoveryRequest()
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
            let joined = localizedDatabaseList(result.restoredKinds)
            parts.append(String(
                format: NSLocalizedString("已按你的确认从启动备份恢复%@。", comment: "Launch backup recovery success message"),
                joined
            ))
        }
        if !result.missingBackupKinds.isEmpty {
            let joined = localizedDatabaseList(result.missingBackupKinds)
            parts.append(String(
                format: NSLocalizedString("%@损坏，但未找到可用的启动备份。", comment: "Launch backup missing message"),
                joined
            ))
        }
        if !result.failedKinds.isEmpty {
            let joined = localizedDatabaseList(result.failedKinds)
            parts.append(String(
                format: NSLocalizedString("%@损坏，且从启动备份恢复失败。请尽快手动导入快照备份。", comment: "Launch backup failed message"),
                joined
            ))
        }
        if result.needsChatFTSRebuild {
            parts.append(NSLocalizedString("聊天检索索引已重新构建。", comment: "Launch backup FTS rebuild message"))
        }
        return parts.joined(separator: "\n")
    }

    private static func setLaunchRecoveryNotice(_ message: String?) {
        launchBackupAndRecoveryLock.lock()
        pendingLaunchRecoveryNotice = message
        launchBackupAndRecoveryLock.unlock()

        if let message {
            writeAppConfig(key: launchRecoveryNoticeKey, text: message, typeHint: "text")
        } else {
            deleteAppConfig(key: launchRecoveryNoticeKey)
        }
    }

    private static func clearLaunchRecoveryNotice() {
        setLaunchRecoveryNotice(nil)
    }

    public static func currentLaunchRecoveryRequest() -> LaunchRecoveryRequest? {
        launchBackupAndRecoveryLock.lock()
        let request = pendingLaunchRecoveryRequest
        launchBackupAndRecoveryLock.unlock()
        return request
    }

    public static func hasPendingLaunchRecoveryRequest() -> Bool {
        launchBackupAndRecoveryLock.lock()
        let hasRequest = pendingLaunchRecoveryRequest != nil
        launchBackupAndRecoveryLock.unlock()
        return hasRequest
    }

    public static func dismissPendingLaunchRecoveryRequest() {
        clearPendingLaunchRecoveryRequest()
    }

    public static func restorePendingLaunchBackupRequest() throws -> String {
        let kinds: [LaunchDatabaseKind]
        launchBackupAndRecoveryLock.lock()
        kinds = pendingLaunchRecoveryKinds
        launchBackupAndRecoveryLock.unlock()

        guard !kinds.isEmpty else {
            return NSLocalizedString("没有待恢复的启动备份。", comment: "No pending launch recovery")
        }

        var result = LaunchPreparationResult()
        do {
            try closeActiveStoresForSnapshotRestore()
            for kind in kinds {
                switch restoreDatabaseFromLaunchBackup(for: kind) {
                case .restored:
                    result.restoredKinds.append(kind)
                case .missingBackup:
                    result.missingBackupKinds.append(kind)
                case .failed:
                    result.failedKinds.append(kind)
                }
            }

            clearPendingLaunchRecoveryRequest()
            launchBackupAndRecoveryLock.lock()
            launchPreparationResult = result
            hasPreparedLaunchDatabases = false
            hasCreatedLaunchBackupPoint = false
            hasScheduledLaunchBackupPoint = false
            launchBackupAndRecoveryLock.unlock()
            bootstrapGRDBStoreOnLaunch()
            if result.needsChatFTSRebuild {
                activeGRDBStore()?.rebuildMessagesFTSIndex()
            }

            let message = makeLaunchRecoveryNotice(from: result)
                ?? NSLocalizedString("启动备份已恢复。", comment: "Launch backup restored")
            setLaunchRecoveryNotice(message)

            if !result.failedKinds.isEmpty || !result.missingBackupKinds.isEmpty {
                throw NSError(domain: "Persistence.LaunchBackupRecovery", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: message
                ])
            }
            return message
        } catch {
            clearPendingLaunchRecoveryRequest()
            bootstrapGRDBStoreOnLaunch()
            throw error
        }
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

    private static func localizedDatabaseList(_ kinds: [LaunchDatabaseKind]) -> String {
        kinds.map(\.localizedDisplayName).joined(separator: NSLocalizedString("、", comment: "Database list separator"))
    }

    private static func setPendingLaunchRecoveryRequest(for kinds: [LaunchDatabaseKind]) {
        guard !kinds.isEmpty else {
            clearPendingLaunchRecoveryRequest()
            return
        }

        let joined = localizedDatabaseList(kinds)
        let message = String(
            format: NSLocalizedString("检测到%@可能已损坏。可以使用上一次启动留下的本机还原点恢复；恢复会替换对应数据库。", comment: "Pending launch recovery request message"),
            joined
        )
        let request = LaunchRecoveryRequest(kinds: kinds, message: message)
        launchBackupAndRecoveryLock.lock()
        pendingLaunchRecoveryKinds = kinds
        pendingLaunchRecoveryRequest = request
        launchBackupAndRecoveryLock.unlock()
    }

    private static func clearPendingLaunchRecoveryRequest() {
        launchBackupAndRecoveryLock.lock()
        pendingLaunchRecoveryKinds = []
        pendingLaunchRecoveryRequest = nil
        launchBackupAndRecoveryLock.unlock()
    }

    private static func launchBackupURL(for kind: LaunchDatabaseKind) -> URL {
        let databaseURL = databaseURL(for: kind)
        let backupDirectory = databaseURL.deletingLastPathComponent()
            .appendingPathComponent(launchBackupDirectoryName, isDirectory: true)
        return backupDirectory.appendingPathComponent(databaseURL.lastPathComponent, isDirectory: false)
    }

    private static func hasUsableLaunchBackup(for kind: LaunchDatabaseKind) -> Bool {
        let backupURL = launchBackupURL(for: kind)
        return FileManager.default.fileExists(atPath: backupURL.path)
            && isSQLiteDatabaseHealthy(at: backupURL)
    }

    private static func launchBackupTemporaryURL(for backupURL: URL) -> URL {
        backupURL.appendingPathExtension("creating")
    }

    private static func launchBackupPreviousURL(for backupURL: URL) -> URL {
        backupURL.appendingPathExtension("previous")
    }

    private static func legacyLaunchBackupTemporaryURL(for backupURL: URL) -> URL {
        backupURL.appendingPathExtension("tmp")
    }

    private static func cleanupInterruptedLaunchBackupInstalls() {
        for kind in LaunchDatabaseKind.allCases {
            cleanupInterruptedLaunchBackupInstall(for: kind)
        }
    }

    private static func cleanupInterruptedLaunchBackupInstall(for kind: LaunchDatabaseKind) {
        let backupURL = launchBackupURL(for: kind)
        let temporaryURL = launchBackupTemporaryURL(for: backupURL)
        let legacyTemporaryURL = legacyLaunchBackupTemporaryURL(for: backupURL)
        let previousURL = launchBackupPreviousURL(for: backupURL)
        let fileManager = FileManager.default

        if !fileManager.fileExists(atPath: backupURL.path),
           fileManager.fileExists(atPath: previousURL.path) {
            do {
                try moveSQLiteDatabaseAndSidecarsIfPresent(from: previousURL, to: backupURL)
            } catch {
                logger.error("恢复中断的启动备份轮换失败(\(kind.displayName)): \(error.localizedDescription)")
            }
        }

        for staleURL in [temporaryURL, legacyTemporaryURL] {
            try? removeSQLiteDatabaseAndSidecarsIfPresent(at: staleURL)
        }
        if fileManager.fileExists(atPath: backupURL.path) {
            try? removeSQLiteDatabaseAndSidecarsIfPresent(at: previousURL)
        }
    }

    private static func moveSQLiteDatabaseAndSidecarsIfPresent(from sourceURL: URL, to destinationURL: URL) throws {
        let fileManager = FileManager.default
        try ensureDirectoryExists(destinationURL.deletingLastPathComponent())
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: sourceURL.path + suffix)
            let destination = URL(fileURLWithPath: destinationURL.path + suffix)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            try removeItemIfExists(at: destination)
            try fileManager.moveItem(at: source, to: destination)
        }
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
            try removeSQLiteDatabaseAndSidecarsIfPresent(at: databaseURL)
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

    static func quarantineDatabaseAfterInitializationFailure(kind: LaunchDatabaseKind, error: Error) -> Bool {
        if hasUsableLaunchBackup(for: kind) {
            setPendingLaunchRecoveryRequest(for: [kind])
            logger.error("数据库初始化失败，已等待用户确认启动备份恢复(\(kind.displayName)): \(error.localizedDescription)")
            return false
        }

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
            setLaunchRecoveryNotice(String(
                format: NSLocalizedString("检测到%@无法打开或迁移，已隔离损坏文件并自动重建。", comment: "Launch database quarantine notice"),
                kind.localizedDisplayName
            ))
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
        cleanupInterruptedLaunchBackupInstall(for: kind)
        let tempBackupURL = launchBackupTemporaryURL(for: backupURL)
        try ensureDirectoryExists(backupURL.deletingLastPathComponent())
        try removeSQLiteDatabaseAndSidecarsIfPresent(at: tempBackupURL)
        defer {
            try? removeSQLiteDatabaseAndSidecarsIfPresent(at: tempBackupURL)
        }

        switch kind {
        case .chat:
            try createChatLaunchBackupWithoutFTS(sourceURL: sourceURL, destinationURL: tempBackupURL)
        case .config, .memory:
            try copySQLiteDatabase(sourceURL: sourceURL, destinationURL: tempBackupURL)
        }

        guard isSQLiteDatabaseHealthy(at: tempBackupURL) else {
            throw NSError(domain: "Persistence.LaunchBackup", code: 1, userInfo: [
                NSLocalizedDescriptionKey: NSLocalizedString("备份文件完整性检查失败", comment: "Launch backup integrity error")
            ])
        }

        try installVerifiedLaunchBackup(
            temporaryURL: tempBackupURL,
            backupURL: backupURL
        )
        removeSQLiteSidecars(at: backupURL)
        cleanupInterruptedLaunchBackupInstall(for: kind)
        logger.info("启动备份已更新(\(kind.displayName)): \(backupURL.path)")
    }

    private static func installVerifiedLaunchBackup(
        temporaryURL: URL,
        backupURL: URL
    ) throws {
        let fileManager = FileManager.default
        let previousURL = launchBackupPreviousURL(for: backupURL)
        try removeSQLiteDatabaseAndSidecarsIfPresent(at: previousURL)

        if fileManager.fileExists(atPath: backupURL.path) {
            removeSQLiteSidecars(at: backupURL)
            try moveSQLiteDatabaseAndSidecarsIfPresent(from: backupURL, to: previousURL)
            do {
                try moveSQLiteDatabaseAndSidecarsIfPresent(from: temporaryURL, to: backupURL)
                try removeSQLiteDatabaseAndSidecarsIfPresent(at: previousURL)
            } catch {
                if !fileManager.fileExists(atPath: backupURL.path),
                   fileManager.fileExists(atPath: previousURL.path) {
                    try? moveSQLiteDatabaseAndSidecarsIfPresent(from: previousURL, to: backupURL)
                }
                throw error
            }
        } else {
            try moveSQLiteDatabaseAndSidecarsIfPresent(from: temporaryURL, to: backupURL)
        }
    }

    private static func createChatLaunchBackupWithoutFTS(sourceURL: URL, destinationURL: URL) throws {
        try copySQLiteDatabase(sourceURL: sourceURL, destinationURL: destinationURL)
        let configuration = databaseEncryptionHasStoredPassphrase()
            ? makeEncryptedDatabaseConfiguration()
            : makePlainDatabaseConfiguration()
        let queue = try DatabaseQueue(path: destinationURL.path, configuration: configuration)
        defer { try? queue.close() }

        try queue.writeWithoutTransaction { db in
            try db.execute(sql: "DROP TRIGGER IF EXISTS messages_ai")
            try db.execute(sql: "DROP TRIGGER IF EXISTS messages_ad")
            try db.execute(sql: "DROP TRIGGER IF EXISTS messages_au")
            try db.execute(sql: "DROP TABLE IF EXISTS messages_fts")
            try db.execute(sql: "VACUUM")
        }
    }

    private static func copySQLiteDatabase(sourceURL: URL, destinationURL: URL) throws {
        try copyDatabaseForLaunchBackup(sourceURL: sourceURL, destinationURL: destinationURL)
    }

    private static func isSQLiteDatabaseHealthy(at url: URL) -> Bool {
        Persistence.isDatabaseHealthy(at: url)
    }

}
