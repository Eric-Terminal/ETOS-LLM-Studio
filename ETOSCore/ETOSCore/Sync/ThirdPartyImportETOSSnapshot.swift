// ============================================================================
// ThirdPartyImportETOSSnapshot.swift
// ============================================================================
// ETOS LLM Studio
//
// 将 .elsbackup 离线快照转换为同步包，供“导入数据”入口执行非破坏性合并。
// ============================================================================

import Foundation
import GRDB
import ZIPFoundation

enum ETOSSnapshotPackageImporter {
    static func buildPackage(from fileURL: URL) throws -> SyncPackage {
        if try isEncryptedSnapshot(fileURL) {
            throw ThirdPartyImportError.unsupportedBackupFormat(
                reason: NSLocalizedString("当前 .elsbackup 快照已加密。导入数据入口暂不支持解密合并，请改用“从快照恢复”入口，或选择未加密快照。", comment: "ETOS snapshot import encrypted unsupported")
            )
        }

        let fileManager = FileManager.default
        let workingDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("ETOS-Snapshot-Import-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workingDirectory) }

        let archive: Archive
        do {
            archive = try Archive(url: fileURL, accessMode: .read)
        } catch {
            throw ThirdPartyImportError.unsupportedBackupFormat(
                reason: NSLocalizedString("无法读取快照归档。", comment: "Snapshot archive unreadable")
            )
        }

        let manifest = try decodeManifest(from: archive)
        let databaseURLs = try extractDatabases(from: archive, to: workingDirectory)
        let filePayloads = try collectFilePayloads(from: archive, manifest: manifest)

        let chatStore = try PersistenceGRDBStore(chatsDirectory: databaseURLs.chatStoreURL.deletingLastPathComponent())
        let configStore = try PersistenceAuxiliaryGRDBStore(
            databaseURL: databaseURLs.configStoreURL,
            loggerCategory: "ETOSSnapshotImportConfig"
        )
        let memoryStore = try PersistenceAuxiliaryGRDBStore(
            databaseURL: databaseURLs.memoryStoreURL,
            loggerCategory: "ETOSSnapshotImportMemory"
        )
        defer {
            try? chatStore.dbPool.close()
            try? configStore.dbPool.close()
            try? memoryStore.dbPool.close()
        }

        let appConfigSnapshot = try loadAppConfigSnapshot(from: configStore)
        let appStorageSnapshot = appConfigSnapshot.isEmpty
            ? nil
            : SyncEngine.encodeAppStorageSnapshot(appConfigSnapshot)
        let providers = try loadProviders(from: configStore, appConfigSnapshot: appConfigSnapshot)
        let sessionTags = chatStore.loadSessionTags()
        let sessions = chatStore.loadChatSessions()
            .filter { !$0.isTemporary }
            .map { session in
                SyncedSession(
                    session: session,
                    messages: chatStore.loadMessages(for: session.id)
                )
            }
        let memories = try loadMemories(from: memoryStore)
        let conversationUserProfile = try loadConversationUserProfile(from: memoryStore)
        let mcpServers = try loadMCPServers(from: configStore)
        let shortcutTools = try loadShortcutTools(from: configStore)
        let worldbooks = try loadWorldbooks(from: configStore)
        let feedbackTickets = try loadFeedbackTickets(from: configStore)
        let dailyPulseRuns = chatStore.loadDailyPulseRuns()
        let dailyPulseFeedbackHistory = chatStore.loadDailyPulseFeedbackHistory()
        let dailyPulsePendingCuration = chatStore.loadDailyPulsePendingCuration()
        let dailyPulseExternalSignals = chatStore.loadDailyPulseExternalSignals()
        let dailyPulseTasks = chatStore.loadDailyPulseTasks()
        let usageStatsDayBundles = chatStore.loadUsageStatsDayBundles()

        var options: SyncOptions = []
        if !providers.isEmpty { options.insert(.providers) }
        if !sessions.isEmpty { options.insert(.sessions) }
        if !filePayloads.backgrounds.isEmpty { options.insert(.backgrounds) }
        if !memories.isEmpty || conversationUserProfile != nil { options.insert(.memories) }
        if !mcpServers.isEmpty { options.insert(.mcpServers) }
        if !filePayloads.audioFiles.isEmpty { options.insert(.audioFiles) }
        if !filePayloads.imageFiles.isEmpty { options.insert(.imageFiles) }
        if !shortcutTools.isEmpty { options.insert(.shortcutTools) }
        if !worldbooks.isEmpty { options.insert(.worldbooks) }
        if !feedbackTickets.isEmpty { options.insert(.feedbackTickets) }
        if !dailyPulseRuns.isEmpty ||
            !dailyPulseFeedbackHistory.isEmpty ||
            dailyPulsePendingCuration != nil ||
            !dailyPulseExternalSignals.isEmpty ||
            !dailyPulseTasks.isEmpty {
            options.insert(.dailyPulse)
        }
        if !usageStatsDayBundles.isEmpty { options.insert(.usageStats) }
        if !filePayloads.fontFiles.isEmpty || filePayloads.fontRouteConfigurationData != nil {
            options.insert(.fontFiles)
        }
        if appStorageSnapshot != nil { options.insert(.appStorage) }

        guard !options.isEmpty else {
            throw ThirdPartyImportError.noImportableContent
        }

        return SyncPackage(
            options: options,
            sourcePlatform: "ETOS .elsbackup",
            providers: providers,
            sessionTags: sessionTags,
            sessions: sessions,
            backgrounds: filePayloads.backgrounds,
            memories: memories,
            conversationUserProfile: conversationUserProfile,
            mcpServers: mcpServers,
            audioFiles: filePayloads.audioFiles,
            imageFiles: filePayloads.imageFiles,
            shortcutTools: shortcutTools,
            worldbooks: worldbooks,
            feedbackTickets: feedbackTickets,
            dailyPulseRuns: dailyPulseRuns,
            dailyPulseFeedbackHistory: dailyPulseFeedbackHistory,
            dailyPulsePendingCuration: dailyPulsePendingCuration,
            dailyPulseExternalSignals: dailyPulseExternalSignals,
            dailyPulseTasks: dailyPulseTasks,
            usageStatsDayBundles: usageStatsDayBundles,
            fontFiles: filePayloads.fontFiles,
            fontRouteConfigurationData: filePayloads.fontRouteConfigurationData,
            appStorageSnapshot: appStorageSnapshot
        )
    }
}

private extension ETOSSnapshotPackageImporter {
    struct ManifestFileEntry: Decodable {
        let path: String
        let byteSize: Int64?
    }

    struct Manifest: Decodable {
        let backupKind: SnapshotBuilder.BackupKind
        let files: [ManifestFileEntry]

        enum CodingKeys: String, CodingKey {
            case backupKind, files
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            backupKind = try container.decodeIfPresent(SnapshotBuilder.BackupKind.self, forKey: .backupKind) ?? .database
            files = try container.decodeIfPresent([ManifestFileEntry].self, forKey: .files) ?? []
        }
    }

    struct FilePayloads {
        var backgrounds: [SyncedBackground] = []
        var audioFiles: [SyncedAudio] = []
        var imageFiles: [SyncedImage] = []
        var fontFiles: [SyncedFontFile] = []
        var fontRouteConfigurationData: Data?
    }

    static let databaseArchivePaths: [(archivePath: String, fileName: String)] = [
        ("Databases/chat-store.sqlite", "chat-store.sqlite"),
        ("Databases/config-store.sqlite", "config-store.sqlite"),
        ("Databases/memory-store.sqlite", "memory-store.sqlite")
    ]

    static func isEncryptedSnapshot(_ fileURL: URL) throws -> Bool {
        let fileHandle = try FileHandle(forReadingFrom: fileURL)
        defer { try? fileHandle.close() }
        let header = try fileHandle.read(upToCount: SnapshotEncryptor.magic.count + 1) ?? Data()
        return try SnapshotEncryptor.encryptedMode(for: header) != nil
    }

    static func decodeManifest(from archive: Archive) throws -> Manifest {
        guard let entry = archive["manifest.json"] else {
            return try JSONDecoder().decode(Manifest.self, from: Data("{}".utf8))
        }
        return try JSONDecoder().decode(Manifest.self, from: data(from: archive, entry: entry))
    }

    static func extractDatabases(from archive: Archive, to workingDirectory: URL) throws -> SnapshotRestoreDatabaseURLs {
        let extractedDirectory = workingDirectory.appendingPathComponent("Databases", isDirectory: true)
        try FileManager.default.createDirectory(at: extractedDirectory, withIntermediateDirectories: true)

        var extractedURLs: [String: URL] = [:]
        for item in databaseArchivePaths {
            guard let entry = archive[item.archivePath] else {
                throw SnapshotRestoreService.RestoreError.missingDatabase(item.fileName)
            }
            let destinationURL = extractedDirectory.appendingPathComponent(item.fileName, isDirectory: false)
            _ = try archive.extract(entry, to: destinationURL)
            guard Persistence.isDatabaseHealthy(at: destinationURL, encrypted: false) else {
                throw SnapshotRestoreService.RestoreError.invalidDatabase(item.fileName)
            }
            extractedURLs[item.fileName] = destinationURL
        }

        guard let chatStoreURL = extractedURLs["chat-store.sqlite"] else {
            throw SnapshotRestoreService.RestoreError.missingDatabase("chat-store.sqlite")
        }
        guard let configStoreURL = extractedURLs["config-store.sqlite"] else {
            throw SnapshotRestoreService.RestoreError.missingDatabase("config-store.sqlite")
        }
        guard let memoryStoreURL = extractedURLs["memory-store.sqlite"] else {
            throw SnapshotRestoreService.RestoreError.missingDatabase("memory-store.sqlite")
        }

        return SnapshotRestoreDatabaseURLs(
            chatStoreURL: chatStoreURL,
            configStoreURL: configStoreURL,
            memoryStoreURL: memoryStoreURL
        )
    }

    static func collectFilePayloads(from archive: Archive, manifest: Manifest) throws -> FilePayloads {
        guard manifest.backupKind == .full, !manifest.files.isEmpty else {
            return FilePayloads()
        }

        var payloads = FilePayloads()
        var fontManifestData: Data?
        var fontDataByFileName: [String: Data] = [:]

        for file in manifest.files {
            guard SnapshotBuilder.isSafeRelativePath(file.path) else {
                throw SnapshotRestoreService.RestoreError.unsafeFilePath(file.path)
            }
            let archivePath = "Files/\(file.path)"
            guard let entry = archive[archivePath] else {
                throw SnapshotRestoreService.RestoreError.missingFile(file.path)
            }
            let data = try data(from: archive, entry: entry)
            let fileName = URL(fileURLWithPath: file.path).lastPathComponent

            if file.path.hasPrefix("Backgrounds/") {
                payloads.backgrounds.append(SyncedBackground(filename: fileName, data: data))
            } else if file.path.hasPrefix("AudioFiles/") {
                payloads.audioFiles.append(SyncedAudio(filename: fileName, data: data))
            } else if file.path.hasPrefix("ImageFiles/") {
                payloads.imageFiles.append(SyncedImage(filename: fileName, data: data))
            } else if file.path.hasPrefix("FontFiles/") {
                switch fileName {
                case "font-manifest-v1.json":
                    fontManifestData = data
                case "font-routes-v1.json":
                    payloads.fontRouteConfigurationData = data
                default:
                    fontDataByFileName[fileName] = data
                }
            }
        }

        payloads.fontFiles = makeFontPayloads(
            manifestData: fontManifestData,
            fontDataByFileName: fontDataByFileName
        )
        return payloads
    }

    static func makeFontPayloads(
        manifestData: Data?,
        fontDataByFileName: [String: Data]
    ) -> [SyncedFontFile] {
        guard let manifestData,
              let records = try? JSONDecoder().decode([FontAssetRecord].self, from: manifestData) else {
            return []
        }

        return records.compactMap { record in
            guard let data = fontDataByFileName[record.fileName] else { return nil }
            return SyncedFontFile(
                assetID: record.id,
                displayName: record.displayName,
                postScriptName: record.postScriptName,
                filename: record.fileName,
                data: data,
                isEnabled: record.isEnabled
            )
        }
    }

    static func data(from archive: Archive, entry: Entry) throws -> Data {
        var data = Data()
        _ = try archive.extract(entry) { chunk in
            data.append(chunk)
        }
        return data
    }

    static func loadAppConfigSnapshot(from store: PersistenceAuxiliaryGRDBStore) throws -> [String: Any] {
        let values = try store.read { db in
            try Persistence.loadAllAppConfigs(from: db)
        }
        return values.reduce(into: [String: Any]()) { result, item in
            guard let key = AppConfigKey(rawValue: item.key),
                  key.participatesInSync,
                  SyncEngine.isCandidateAppStorageKey(item.key),
                  let normalized = SyncEngine.normalizedAppConfigValue(item.value, for: key),
                  SyncEngine.isPropertyListEncodableValue(normalized) else {
                return
            }
            result[item.key] = normalized
        }
    }

    static func loadProviders(
        from store: PersistenceAuxiliaryGRDBStore,
        appConfigSnapshot: [String: Any]
    ) throws -> [Provider] {
        let providerOrderIDs = stringArrayValue(appConfigSnapshot[AppConfigKey.providerOrderIDs.rawValue])
        let providers = try store.read { db in
            try ConfigLoader.loadProvidersFromRelationalStore(db, storedProviderOrderIDs: providerOrderIDs)
        }
        if !providers.isEmpty {
            return providers
        }
        return loadFirstAuxiliaryBlob([Provider].self, keys: ConfigLoader.legacyProvidersBlobKeys, store: store) ?? []
    }

    static func loadMemories(from store: PersistenceAuxiliaryGRDBStore) throws -> [MemoryItem] {
        let memories = try store.read { db in
            try MemoryRawStore.loadMemories(from: db)
        }
        if !memories.isEmpty {
            return memories
        }
        return MemoryRawStore.loadLegacyMemories(from: store) ?? []
    }

    static func loadConversationUserProfile(from store: PersistenceAuxiliaryGRDBStore) throws -> ConversationUserProfile? {
        if let profile = try store.read({ db in
            try ConversationMemoryManager.loadUserProfile(from: db)
        }) {
            return profile
        }
        return ConversationMemoryManager.loadLegacyUserProfile(from: store)
    }

    static func loadMCPServers(from store: PersistenceAuxiliaryGRDBStore) throws -> [MCPServerConfiguration] {
        let servers = try store.read { db in
            try MCPServerStore.loadServersFromRelationalStore(db)
        }
        if !servers.isEmpty {
            return servers
        }
        let records = loadFirstAuxiliaryBlob(
            [MCPServerStore.MCPServerStoredRecord].self,
            keys: MCPServerStore.allRecordBlobKeys,
            store: store
        ) ?? []
        return MCPServerStore.sortedRecordsByServerOrder(records).map(\.server)
    }

    static func loadShortcutTools(from store: PersistenceAuxiliaryGRDBStore) throws -> [ShortcutToolDefinition] {
        let tools = try store.read { db in
            try ShortcutToolStore.loadTools(from: db)
        }
        if !tools.isEmpty {
            return tools
        }
        return ShortcutToolStore.loadLegacyTools(from: store) ?? []
    }

    static func loadWorldbooks(from store: PersistenceAuxiliaryGRDBStore) throws -> [Worldbook] {
        let worldbooks = try store.read { db in
            try WorldbookStore.shared.loadWorldbooksFromRelationalStore(db)
        }
        if !worldbooks.isEmpty {
            return worldbooks
        }
        return loadFirstAuxiliaryBlob([Worldbook].self, keys: WorldbookStore.legacyBlobKeys, store: store) ?? []
    }

    static func loadFeedbackTickets(from store: PersistenceAuxiliaryGRDBStore) throws -> [FeedbackTicket] {
        let tickets = try store.read { db in
            try FeedbackStore.loadTickets(from: db)
        }
        if !tickets.isEmpty {
            return tickets
        }
        return FeedbackStore.loadLegacyTickets(from: store) ?? []
    }

    static func loadFirstAuxiliaryBlob<T: Decodable>(
        _ type: T.Type,
        keys: [String],
        store: PersistenceAuxiliaryGRDBStore
    ) -> T? {
        for key in keys {
            if let value = store.loadAuxiliaryBlob(type, forKey: key) {
                return value
            }
        }
        return nil
    }

    static func stringArrayValue(_ value: Any?) -> [String] {
        if let array = value as? [String] {
            return array
        }
        guard let string = value as? String,
              let data = string.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return decoded
    }
}
