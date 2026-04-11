// ============================================================================
// WorldbookStore.swift
// ============================================================================
// 世界书持久化存储
//
// 负责世界书数据读写（优先 SQLite，失败时回退目录级 JSON 文件）、旧版聚合文件迁移、去重导入与基础 CRUD。
// ============================================================================

import Foundation
import GRDB
import os.log

public struct WorldbookImportReport: Hashable, Sendable {
    public var importedBookID: UUID?
    public var importedEntries: Int
    public var skippedEntries: Int
    public var failedEntries: Int
    public var failureReasons: [String]

    public init(
        importedBookID: UUID? = nil,
        importedEntries: Int,
        skippedEntries: Int,
        failedEntries: Int,
        failureReasons: [String] = []
    ) {
        self.importedBookID = importedBookID
        self.importedEntries = importedEntries
        self.skippedEntries = skippedEntries
        self.failedEntries = failedEntries
        self.failureReasons = failureReasons
    }
}

public struct WorldbookImportDiagnostics: Hashable, Sendable {
    public var failedEntries: Int
    public var failureReasons: [String]

    public init(
        failedEntries: Int = 0,
        failureReasons: [String] = []
    ) {
        self.failedEntries = max(0, failedEntries)
        self.failureReasons = failureReasons
    }
}

public final class WorldbookStore {
    public static let shared = WorldbookStore()

    private struct StandaloneLoadResult {
        var worldbooks: [Worldbook]
        var requiresRewrite: Bool
    }

    private struct LoadedStandaloneBook {
        var worldbook: Worldbook
        var requiresRewrite: Bool
    }

    private let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "WorldbookStore")
    private let queue = DispatchQueue(label: "com.ETOS.LLM.Studio.worldbook.store")
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let importService: WorldbookImportService
    private let storageDirectoryOverride: URL?
    private var cachedWorldbooks: [Worldbook]?
    private var cacheByID: [UUID: Worldbook] = [:]
    private var cacheNormalizedContents: Set<String> = []

    public static let directoryName = "Worldbooks"
    public static let fileName = "worldbooks.json"
    private static let grdbBlobKey = "worldbooks_v1"
    private static let standaloneFileExtension = "json"
    private static let importedFileExtensions: Set<String> = ["json", "png"]

    init(
        storageDirectoryURL: URL? = nil,
        importService: WorldbookImportService = WorldbookImportService()
    ) {
        self.storageDirectoryOverride = storageDirectoryURL
        self.importService = importService
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    public var storageDirectory: URL {
        if let storageDirectoryOverride {
            return storageDirectoryOverride
        }
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        return paths[0].appendingPathComponent(Self.directoryName, isDirectory: true)
    }

    public var storageFileURL: URL {
        storageDirectory.appendingPathComponent(Self.fileName, isDirectory: false)
    }

    private var canUseGRDB: Bool {
        storageDirectoryOverride == nil
    }

    @discardableResult
    public func setupDirectoryIfNeeded() -> URL {
        queue.sync {
            ensureDirectoryIfNeeded()
        }
    }

    public func loadWorldbooks() -> [Worldbook] {
        queue.sync {
            loadWorldbooksUnlocked()
        }
    }

    public func resolveWorldbooks(ids: [UUID]) -> [Worldbook] {
        queue.sync {
            guard !ids.isEmpty else { return [] }
            _ = loadWorldbooksUnlocked()
            return ids.compactMap { cacheByID[$0] }
        }
    }

    public func saveWorldbooks(_ worldbooks: [Worldbook]) {
        queue.sync {
            saveWorldbooksUnlocked(worldbooks)
        }
    }

    public func invalidateCache() {
        queue.sync {
            cachedWorldbooks = nil
            cacheByID = [:]
            cacheNormalizedContents = []
        }
    }

    public func upsertWorldbook(_ worldbook: Worldbook) {
        queue.sync {
            var all = loadWorldbooksUnlocked()
            if let index = all.firstIndex(where: { $0.id == worldbook.id }) {
                all[index] = worldbook
            } else {
                all.append(worldbook)
            }
            saveWorldbooksUnlocked(all)
        }
    }

    public func deleteWorldbook(id: UUID) {
        queue.sync {
            var all = loadWorldbooksUnlocked()
            all.removeAll { $0.id == id }
            saveWorldbooksUnlocked(all)
        }
    }

    public func assignWorldbooks(sessionID: UUID, worldbookIDs: [UUID]) {
        var sessions = Persistence.loadChatSessions()
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[index].lorebookIDs = deduplicateUUIDs(worldbookIDs)
        Persistence.saveChatSessions(sessions)
    }

    @discardableResult
    public func mergeImportedWorldbook(
        _ worldbook: Worldbook,
        dedupeByContent: Bool = true,
        diagnostics: WorldbookImportDiagnostics? = nil
    ) -> WorldbookImportReport {
        queue.sync {
            var all = loadWorldbooksUnlocked()

            var globalContentSet = cacheNormalizedContents
            if dedupeByContent {
                if globalContentSet.isEmpty {
                    for existingBook in all {
                        for entry in existingBook.entries {
                            globalContentSet.insert(Self.normalizedContent(entry.content))
                        }
                    }
                }
            }

            var acceptedEntries: [WorldbookEntry] = []
            var skipped = 0
            let failedEntries = diagnostics?.failedEntries ?? 0
            var failureReasons = diagnostics?.failureReasons ?? []

            for entry in worldbook.entries {
                let normalized = Self.normalizedContent(entry.content)
                if normalized.isEmpty {
                    skipped += 1
                    continue
                }
                if dedupeByContent, globalContentSet.contains(normalized) {
                    skipped += 1
                    continue
                }
                acceptedEntries.append(entry)
                if dedupeByContent {
                    globalContentSet.insert(normalized)
                }
            }

            guard !acceptedEntries.isEmpty else {
                if failureReasons.isEmpty {
                    failureReasons.append("导入内容为空，或条目均被去重跳过。")
                }
                return WorldbookImportReport(
                    importedBookID: nil,
                    importedEntries: 0,
                    skippedEntries: skipped,
                    failedEntries: failedEntries,
                    failureReasons: failureReasons
                )
            }

            var candidate = worldbook
            candidate.entries = deduplicateEntriesInBook(acceptedEntries)
            candidate.updatedAt = Date()

            // 同名不同内容：自动重命名保留
            let sameNameBooks = all.filter {
                $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    .localizedCaseInsensitiveCompare(candidate.name.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
            }
            if !sameNameBooks.isEmpty && !sameNameBooks.contains(where: { $0.contentHash == candidate.contentHash }) {
                candidate.name = Self.uniqueSyncName(baseName: candidate.name, existing: all.map(\.name))
            }

            // UUID 冲突时重建 ID
            if all.contains(where: { $0.id == candidate.id }) {
                candidate.id = UUID()
            }

            all.append(candidate)
            saveWorldbooksUnlocked(all)

            return WorldbookImportReport(
                importedBookID: candidate.id,
                importedEntries: candidate.entries.count,
                skippedEntries: skipped,
                failedEntries: failedEntries,
                failureReasons: failureReasons
            )
        }
    }

    private func ensureDirectoryIfNeeded() -> URL {
        let fm = FileManager.default
        let directory = storageDirectory
        if !fm.fileExists(atPath: directory.path) {
            do {
                try fm.createDirectory(at: directory, withIntermediateDirectories: true)
                logger.info("Worldbooks 目录已创建: \(directory.path, privacy: .public)")
            } catch {
                logger.error("创建 Worldbooks 目录失败: \(error.localizedDescription, privacy: .public)")
            }
        }
        return directory
    }

    private func loadWorldbooksUnlocked() -> [Worldbook] {
        if let cachedWorldbooks {
            return cachedWorldbooks
        }

        if canUseGRDB,
           let storedWorldbooks = loadWorldbooksFromSQLite(),
           !storedWorldbooks.isEmpty {
            let sortedStoredWorldbooks = deduplicatedAndSortedWorldbooks(storedWorldbooks)
            updateCaches(with: sortedStoredWorldbooks)
            cleanupLegacyFilesAfterGRDBSave(removeLegacyAggregate: true)
            return sortedStoredWorldbooks
        }

        _ = ensureDirectoryIfNeeded()
        let standaloneResult = loadStandaloneWorldbooksUnlocked()
        let legacyResult = loadLegacyWorldbooksUnlocked()

        let sorted = deduplicatedAndSortedWorldbooks(standaloneResult.worldbooks + legacyResult.worldbooks)

        if canUseGRDB {
            saveWorldbooksUnlocked(sorted, removeLegacyAggregate: true)
            return cachedWorldbooks ?? sorted
        }

        if standaloneResult.requiresRewrite || legacyResult.requiresRewrite {
            saveWorldbooksUnlocked(sorted, removeLegacyAggregate: legacyResult.requiresRewrite)
            return cachedWorldbooks ?? sorted
        }

        updateCaches(with: sorted)
        return sorted
    }

    private func saveWorldbooksUnlocked(
        _ worldbooks: [Worldbook],
        removeLegacyAggregate: Bool = true
    ) {
        let sorted = deduplicatedAndSortedWorldbooks(worldbooks)

        if canUseGRDB, saveWorldbooksToSQLite(sorted) {
            cleanupLegacyFilesAfterGRDBSave(removeLegacyAggregate: removeLegacyAggregate)
            logger.info("已保存世界书到 SQLite: \(sorted.count)")
            updateCaches(with: sorted)
            return
        }

        _ = ensureDirectoryIfNeeded()
        do {
            let destinationMap = standaloneFileURLs(for: sorted)

            for worldbook in sorted {
                guard let destinationURL = destinationMap[worldbook.id] else { continue }
                let data = try encoder.encode(worldbook)
                try data.write(to: destinationURL, options: [.atomicWrite, .completeFileProtection])
            }

            cleanupStaleStandaloneFiles(
                keeping: Set(destinationMap.values.map { $0.lastPathComponent.lowercased() }),
                removeLegacyAggregate: removeLegacyAggregate
            )

            logger.info("已保存世界书文件: \(sorted.count)")
            updateCaches(with: sorted)
        } catch {
            logger.error("保存世界书失败: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func loadWorldbooksFromSQLite() -> [Worldbook]? {
        guard let worldbooks = Persistence.withConfigDatabaseRead({ db in
            try loadWorldbooksFromRelationalStore(db)
        }) else {
            return nil
        }

        if worldbooks.isEmpty,
           let legacyWorldbooks = loadLegacyWorldbooksFromBlob(),
           !legacyWorldbooks.isEmpty {
            if saveWorldbooksToSQLite(legacyWorldbooks) {
                _ = Persistence.removeAuxiliaryBlob(forKey: Self.grdbBlobKey)
            }
            return legacyWorldbooks
        }

        return worldbooks
    }

    private func loadLegacyWorldbooksFromBlob() -> [Worldbook]? {
        guard Persistence.auxiliaryBlobExists(forKey: Self.grdbBlobKey) else {
            return nil
        }
        return Persistence.loadAuxiliaryBlob([Worldbook].self, forKey: Self.grdbBlobKey) ?? []
    }

    @discardableResult
    private func saveWorldbooksToSQLite(_ worldbooks: [Worldbook]) -> Bool {
        let didSave = Persistence.withConfigDatabaseWrite { db in
            try db.execute(sql: "DELETE FROM worldbooks")

            for worldbook in worldbooks {
                try db.execute(
                    sql: """
                    INSERT INTO worldbooks (
                        id, name, description, is_enabled, created_at, updated_at,
                        scan_depth, max_recursion_depth, max_injected_entries,
                        max_injected_characters, fallback_position, source_file_name
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        worldbook.id.uuidString,
                        worldbook.name,
                        worldbook.description,
                        worldbook.isEnabled ? 1 : 0,
                        worldbook.createdAt.timeIntervalSince1970,
                        worldbook.updatedAt.timeIntervalSince1970,
                        worldbook.settings.scanDepth,
                        worldbook.settings.maxRecursionDepth,
                        worldbook.settings.maxInjectedEntries,
                        worldbook.settings.maxInjectedCharacters,
                        worldbook.settings.fallbackPosition.stRawValue,
                        worldbook.sourceFileName
                    ]
                )

                for metadataKey in worldbook.metadata.keys.sorted() {
                    let encodedValue = RelationalJSONValueCodec.encode(worldbook.metadata[metadataKey] ?? .null)
                    try db.execute(
                        sql: """
                        INSERT INTO worldbook_metadata (
                            worldbook_id, meta_key, value_type, string_value, number_value, bool_value, json_value_text
                        ) VALUES (?, ?, ?, ?, ?, ?, ?)
                        """,
                        arguments: [
                            worldbook.id.uuidString,
                            metadataKey,
                            encodedValue.type,
                            encodedValue.stringValue,
                            encodedValue.numberValue,
                            encodedValue.boolValue,
                            encodedValue.jsonValueText
                        ]
                    )
                }

                for (entryIndex, entry) in worldbook.entries.enumerated() {
                    try db.execute(
                        sql: """
                        INSERT INTO worldbook_entries (
                            id, worldbook_id, uid, comment, content, selective_logic, is_enabled,
                            constant_flag, position, outlet_name, entry_order, depth, scan_depth,
                            case_sensitive, match_whole_words, use_regex, use_probability, probability,
                            group_name, group_override, group_weight, use_group_scoring, role, sticky,
                            cooldown, delay, exclude_recursion, prevent_recursion, delay_until_recursion,
                            sort_index
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                        arguments: [
                            entry.id.uuidString,
                            worldbook.id.uuidString,
                            entry.uid,
                            entry.comment,
                            entry.content,
                            entry.selectiveLogic.rawValue,
                            entry.isEnabled ? 1 : 0,
                            entry.constant ? 1 : 0,
                            entry.position.stRawValue,
                            entry.outletName,
                            entry.order,
                            entry.depth,
                            entry.scanDepth,
                            entry.caseSensitive ? 1 : 0,
                            entry.matchWholeWords ? 1 : 0,
                            entry.useRegex ? 1 : 0,
                            entry.useProbability ? 1 : 0,
                            entry.probability,
                            entry.group,
                            entry.groupOverride ? 1 : 0,
                            entry.groupWeight,
                            entry.useGroupScoring ? 1 : 0,
                            entry.role.rawValue,
                            entry.sticky,
                            entry.cooldown,
                            entry.delay,
                            entry.excludeRecursion ? 1 : 0,
                            entry.preventRecursion ? 1 : 0,
                            entry.delayUntilRecursion ? 1 : 0,
                            entryIndex
                        ]
                    )

                    for (keyIndex, keyValue) in entry.keys.enumerated() {
                        try db.execute(
                            sql: """
                            INSERT INTO worldbook_entry_keys (entry_id, key_value, key_kind, sort_index)
                            VALUES (?, ?, 'primary', ?)
                            """,
                            arguments: [entry.id.uuidString, keyValue, keyIndex]
                        )
                    }

                    for (keyIndex, keyValue) in entry.secondaryKeys.enumerated() {
                        try db.execute(
                            sql: """
                            INSERT INTO worldbook_entry_keys (entry_id, key_value, key_kind, sort_index)
                            VALUES (?, ?, 'secondary', ?)
                            """,
                            arguments: [entry.id.uuidString, keyValue, keyIndex]
                        )
                    }

                    for metadataKey in entry.metadata.keys.sorted() {
                        let encodedValue = RelationalJSONValueCodec.encode(entry.metadata[metadataKey] ?? .null)
                        try db.execute(
                            sql: """
                            INSERT INTO worldbook_entry_metadata (
                                entry_id, meta_key, value_type, string_value, number_value, bool_value, json_value_text
                            ) VALUES (?, ?, ?, ?, ?, ?, ?)
                            """,
                            arguments: [
                                entry.id.uuidString,
                                metadataKey,
                                encodedValue.type,
                                encodedValue.stringValue,
                                encodedValue.numberValue,
                                encodedValue.boolValue,
                                encodedValue.jsonValueText
                            ]
                        )
                    }
                }
            }

            return true
        } ?? false

        if didSave {
            _ = Persistence.removeAuxiliaryBlob(forKey: Self.grdbBlobKey)
        }
        return didSave
    }

    private func loadWorldbooksFromRelationalStore(_ db: Database) throws -> [Worldbook] {
        let worldbookRows = try Row.fetchAll(
            db,
            sql: """
            SELECT id, name, description, is_enabled, created_at, updated_at,
                   scan_depth, max_recursion_depth, max_injected_entries,
                   max_injected_characters, fallback_position, source_file_name
            FROM worldbooks
            ORDER BY updated_at DESC, id ASC
            """
        )

        let worldbookMetadataRows = try Row.fetchAll(
            db,
            sql: """
            SELECT worldbook_id, meta_key, value_type, string_value, number_value, bool_value, json_value_text
            FROM worldbook_metadata
            ORDER BY worldbook_id ASC, meta_key ASC
            """
        )
        var worldbookMetadataByID: [String: [String: JSONValue]] = [:]
        for row in worldbookMetadataRows {
            let worldbookID: String = row["worldbook_id"]
            let key: String = row["meta_key"]
            let valueType: String = row["value_type"]
            let stringValue: String? = row["string_value"]
            let numberValue: Double? = row["number_value"]
            let boolValue: Int? = row["bool_value"]
            let jsonValueText: String? = row["json_value_text"]
            worldbookMetadataByID[worldbookID, default: [:]][key] = RelationalJSONValueCodec.decode(
                type: valueType,
                stringValue: stringValue,
                numberValue: numberValue,
                boolValue: boolValue,
                jsonValueText: jsonValueText
            )
        }

        let entryRows = try Row.fetchAll(
            db,
            sql: """
            SELECT id, worldbook_id, uid, comment, content, selective_logic, is_enabled,
                   constant_flag, position, outlet_name, entry_order, depth, scan_depth,
                   case_sensitive, match_whole_words, use_regex, use_probability, probability,
                   group_name, group_override, group_weight, use_group_scoring, role, sticky,
                   cooldown, delay, exclude_recursion, prevent_recursion, delay_until_recursion
            FROM worldbook_entries
            ORDER BY worldbook_id ASC, sort_index ASC, id ASC
            """
        )

        let entryKeyRows = try Row.fetchAll(
            db,
            sql: """
            SELECT entry_id, key_value, key_kind
            FROM worldbook_entry_keys
            ORDER BY entry_id ASC, key_kind ASC, sort_index ASC
            """
        )
        var primaryKeysByEntryID: [String: [String]] = [:]
        var secondaryKeysByEntryID: [String: [String]] = [:]
        for row in entryKeyRows {
            let entryID: String = row["entry_id"]
            let kind: String = row["key_kind"]
            let value: String = row["key_value"]
            if kind == "secondary" {
                secondaryKeysByEntryID[entryID, default: []].append(value)
            } else {
                primaryKeysByEntryID[entryID, default: []].append(value)
            }
        }

        let entryMetadataRows = try Row.fetchAll(
            db,
            sql: """
            SELECT entry_id, meta_key, value_type, string_value, number_value, bool_value, json_value_text
            FROM worldbook_entry_metadata
            ORDER BY entry_id ASC, meta_key ASC
            """
        )
        var entryMetadataByID: [String: [String: JSONValue]] = [:]
        for row in entryMetadataRows {
            let entryID: String = row["entry_id"]
            let key: String = row["meta_key"]
            let valueType: String = row["value_type"]
            let stringValue: String? = row["string_value"]
            let numberValue: Double? = row["number_value"]
            let boolValue: Int? = row["bool_value"]
            let jsonValueText: String? = row["json_value_text"]
            entryMetadataByID[entryID, default: [:]][key] = RelationalJSONValueCodec.decode(
                type: valueType,
                stringValue: stringValue,
                numberValue: numberValue,
                boolValue: boolValue,
                jsonValueText: jsonValueText
            )
        }

        var entriesByWorldbookID: [String: [WorldbookEntry]] = [:]
        for row in entryRows {
            let entryIDRaw: String = row["id"]
            let worldbookID: String = row["worldbook_id"]
            let enabledValue: Int = row["is_enabled"]
            let constantValue: Int = row["constant_flag"]
            let caseSensitiveValue: Int = row["case_sensitive"]
            let matchWholeWordsValue: Int = row["match_whole_words"]
            let useRegexValue: Int = row["use_regex"]
            let useProbabilityValue: Int = row["use_probability"]
            let groupOverrideValue: Int = row["group_override"]
            let useGroupScoringValue: Int = row["use_group_scoring"]
            let excludeRecursionValue: Int = row["exclude_recursion"]
            let preventRecursionValue: Int = row["prevent_recursion"]
            let delayUntilRecursionValue: Int = row["delay_until_recursion"]
            let positionRaw: String = row["position"]
            let roleRaw: String = row["role"]
            let selectiveLogicRaw: String = row["selective_logic"]

            let entry = WorldbookEntry(
                id: UUID(uuidString: entryIDRaw) ?? UUID(),
                uid: row["uid"],
                comment: row["comment"],
                content: row["content"],
                keys: primaryKeysByEntryID[entryIDRaw] ?? [],
                secondaryKeys: secondaryKeysByEntryID[entryIDRaw] ?? [],
                selectiveLogic: WorldbookSelectiveLogic(rawOrLegacyValue: selectiveLogicRaw),
                isEnabled: enabledValue != 0,
                constant: constantValue != 0,
                position: WorldbookPosition(stRawValue: positionRaw),
                outletName: row["outlet_name"],
                order: row["entry_order"],
                depth: row["depth"],
                scanDepth: row["scan_depth"],
                caseSensitive: caseSensitiveValue != 0,
                matchWholeWords: matchWholeWordsValue != 0,
                useRegex: useRegexValue != 0,
                useProbability: useProbabilityValue != 0,
                probability: row["probability"],
                group: row["group_name"],
                groupOverride: groupOverrideValue != 0,
                groupWeight: row["group_weight"],
                useGroupScoring: useGroupScoringValue != 0,
                role: WorldbookEntryRole(rawOrLegacyValue: roleRaw),
                sticky: row["sticky"],
                cooldown: row["cooldown"],
                delay: row["delay"],
                excludeRecursion: excludeRecursionValue != 0,
                preventRecursion: preventRecursionValue != 0,
                delayUntilRecursion: delayUntilRecursionValue != 0,
                metadata: entryMetadataByID[entryIDRaw] ?? [:]
            )
            entriesByWorldbookID[worldbookID, default: []].append(entry)
        }

        return worldbookRows.map { row in
            let worldbookIDRaw: String = row["id"]
            let isEnabledValue: Int = row["is_enabled"]
            let fallbackPositionRaw: String = row["fallback_position"]
            let settings = WorldbookSettings(
                scanDepth: row["scan_depth"],
                maxRecursionDepth: row["max_recursion_depth"],
                maxInjectedEntries: row["max_injected_entries"],
                maxInjectedCharacters: row["max_injected_characters"],
                fallbackPosition: WorldbookPosition(stRawValue: fallbackPositionRaw)
            )

            return Worldbook(
                id: UUID(uuidString: worldbookIDRaw) ?? UUID(),
                name: row["name"],
                description: row["description"],
                isEnabled: isEnabledValue != 0,
                createdAt: Date(timeIntervalSince1970: row["created_at"]),
                updatedAt: Date(timeIntervalSince1970: row["updated_at"]),
                entries: entriesByWorldbookID[worldbookIDRaw] ?? [],
                settings: settings,
                sourceFileName: row["source_file_name"],
                metadata: worldbookMetadataByID[worldbookIDRaw] ?? [:]
            )
        }
    }

    private func loadStandaloneWorldbooksUnlocked() -> StandaloneLoadResult {
        let urls = standaloneCandidateFileURLs()
        guard !urls.isEmpty else {
            return StandaloneLoadResult(worldbooks: [], requiresRewrite: false)
        }

        var loadedWorldbooks: [Worldbook] = []
        var seenIDs = Set<UUID>()
        var requiresRewrite = false

        for fileURL in urls {
            guard let loaded = loadStandaloneWorldbook(at: fileURL) else { continue }
            var worldbook = loaded.worldbook
            requiresRewrite = requiresRewrite || loaded.requiresRewrite

            if seenIDs.contains(worldbook.id) {
                worldbook.id = UUID()
                requiresRewrite = true
            }

            seenIDs.insert(worldbook.id)
            loadedWorldbooks.append(worldbook)
        }

        return StandaloneLoadResult(
            worldbooks: loadedWorldbooks.sorted { $0.updatedAt > $1.updatedAt },
            requiresRewrite: requiresRewrite
        )
    }

    private func loadLegacyWorldbooksUnlocked() -> StandaloneLoadResult {
        let legacyURL = storageFileURL
        guard FileManager.default.fileExists(atPath: legacyURL.path) else {
            return StandaloneLoadResult(worldbooks: [], requiresRewrite: false)
        }

        do {
            let data = try Data(contentsOf: legacyURL)
            let worldbooks = try decoder.decode([Worldbook].self, from: data)
            logger.info("检测到旧版世界书聚合文件，准备迁移: \(legacyURL.lastPathComponent, privacy: .public)")
            return StandaloneLoadResult(worldbooks: worldbooks, requiresRewrite: true)
        } catch {
            if let loaded = loadStandaloneWorldbook(at: legacyURL) {
                logger.info("检测到旧版路径上的单本世界书文件，准备迁移: \(legacyURL.lastPathComponent, privacy: .public)")
                return StandaloneLoadResult(worldbooks: [loaded.worldbook], requiresRewrite: true)
            }

            logger.error("读取旧版世界书聚合文件失败: \(error.localizedDescription, privacy: .public)")
            return StandaloneLoadResult(worldbooks: [], requiresRewrite: false)
        }
    }

    private func loadStandaloneWorldbook(at fileURL: URL) -> LoadedStandaloneBook? {
        do {
            let data = try Data(contentsOf: fileURL)

            if fileURL.pathExtension.lowercased() == Self.standaloneFileExtension,
               let decoded = try? decoder.decode(Worldbook.self, from: data) {
                return LoadedStandaloneBook(worldbook: decoded, requiresRewrite: false)
            }

            let imported = try importService.importWorldbookWithReport(
                from: data,
                fileName: fileURL.lastPathComponent
            )
            return LoadedStandaloneBook(worldbook: imported.worldbook, requiresRewrite: true)
        } catch {
            logger.error("读取世界书文件失败: \(fileURL.lastPathComponent, privacy: .public) - \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func standaloneCandidateFileURLs() -> [URL] {
        let directory = storageDirectory
        let fm = FileManager.default

        guard let urls = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return urls
            .filter { url in
                guard url.lastPathComponent.lowercased() != Self.fileName.lowercased() else {
                    return false
                }
                return Self.importedFileExtensions.contains(url.pathExtension.lowercased())
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private func standaloneFileURLs(for worldbooks: [Worldbook]) -> [UUID: URL] {
        var usedNames = Set<String>()
        var result: [UUID: URL] = [:]

        for worldbook in worldbooks.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            let fileName = nextAvailableStandaloneFileName(for: worldbook, usedNames: &usedNames)
            result[worldbook.id] = storageDirectory.appendingPathComponent(fileName, isDirectory: false)
        }

        return result
    }

    private func nextAvailableStandaloneFileName(
        for worldbook: Worldbook,
        usedNames: inout Set<String>
    ) -> String {
        let preferred = preferredStandaloneFileName(for: worldbook)
        let preferredKey = preferred.lowercased()
        if !usedNames.contains(preferredKey) {
            usedNames.insert(preferredKey)
            return preferred
        }

        let fallback = nameBasedStandaloneFileName(for: worldbook)
        let fallbackKey = fallback.lowercased()
        if !usedNames.contains(fallbackKey) {
            usedNames.insert(fallbackKey)
            return fallback
        }

        var index = 2
        while true {
            let candidate = indexedStandaloneFileName(for: worldbook, index: index)
            let key = candidate.lowercased()
            if !usedNames.contains(key) {
                usedNames.insert(key)
                return candidate
            }
            index += 1
        }
    }

    private func preferredStandaloneFileName(for worldbook: Worldbook) -> String {
        if let sourceFileName = worldbook.sourceFileName,
           !sourceFileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let sanitizedSource = sanitizedSourceFileName(sourceFileName) {
            return sanitizedSource
        }

        return nameBasedStandaloneFileName(for: worldbook)
    }

    private func nameBasedStandaloneFileName(for worldbook: Worldbook) -> String {
        let baseName = sanitizedFileComponent(worldbook.name)
        let safeBaseName = baseName.isEmpty ? "worldbook" : baseName
        return "\(safeBaseName)--\(worldbook.id.uuidString.lowercased()).\(Self.standaloneFileExtension)"
    }

    private func indexedStandaloneFileName(for worldbook: Worldbook, index: Int) -> String {
        let baseName = sanitizedFileComponent(worldbook.name)
        let safeBaseName = baseName.isEmpty ? "worldbook" : baseName
        return "\(safeBaseName)--\(worldbook.id.uuidString.lowercased())-\(index).\(Self.standaloneFileExtension)"
    }

    private func sanitizedSourceFileName(_ rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lastPathComponent = URL(fileURLWithPath: trimmed).lastPathComponent
        let baseName = URL(fileURLWithPath: lastPathComponent).deletingPathExtension().lastPathComponent
        let sanitizedBaseName = sanitizedFileComponent(baseName)
        guard !sanitizedBaseName.isEmpty else { return nil }

        let candidate = "\(sanitizedBaseName).\(Self.standaloneFileExtension)"
        guard candidate.lowercased() != Self.fileName.lowercased() else {
            return nil
        }

        return candidate
    }

    private func sanitizedFileComponent(_ rawValue: String) -> String {
        let invalidScalars = CharacterSet(charactersIn: "/:\\?%*|\"<>\n\r\t")
            .union(.controlCharacters)
        let cleanedScalars = rawValue.unicodeScalars.map { scalar -> Character in
            if invalidScalars.contains(scalar) {
                return "_"
            }
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                return "_"
            }
            return Character(scalar)
        }

        let cleaned = String(cleanedScalars)
            .replacingOccurrences(of: "_{2,}", with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "._ "))

        if cleaned.isEmpty || cleaned == "." || cleaned == ".." {
            return ""
        }

        return String(cleaned.prefix(80))
    }

    private func cleanupStaleStandaloneFiles(
        keeping desiredFileNames: Set<String>,
        removeLegacyAggregate: Bool
    ) {
        let fm = FileManager.default

        for url in standaloneCandidateFileURLs() {
            if desiredFileNames.contains(url.lastPathComponent.lowercased()) {
                continue
            }
            do {
                try fm.removeItem(at: url)
            } catch {
                logger.error("删除旧世界书文件失败: \(url.lastPathComponent, privacy: .public) - \(error.localizedDescription, privacy: .public)")
            }
        }

        if removeLegacyAggregate, fm.fileExists(atPath: self.storageFileURL.path) {
            do {
                try fm.removeItem(at: self.storageFileURL)
                logger.info("已删除旧版世界书聚合文件: \(self.storageFileURL.lastPathComponent, privacy: .public)")
            } catch {
                logger.error("删除旧版世界书聚合文件失败: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func cleanupLegacyFilesAfterGRDBSave(removeLegacyAggregate: Bool) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: storageDirectory.path) else { return }

        do {
            let files = try fm.contentsOfDirectory(at: storageDirectory, includingPropertiesForKeys: nil)
            for fileURL in files {
                let lowercasedName = fileURL.lastPathComponent.lowercased()
                if removeLegacyAggregate, lowercasedName == Self.fileName.lowercased() {
                    try? fm.removeItem(at: fileURL)
                    continue
                }
                if Self.importedFileExtensions.contains(fileURL.pathExtension.lowercased()) {
                    try? fm.removeItem(at: fileURL)
                }
            }
            let remaining = try fm.contentsOfDirectory(atPath: storageDirectory.path)
            if remaining.isEmpty {
                try? fm.removeItem(at: storageDirectory)
            }
        } catch {
            logger.error("清理世界书遗留 JSON 失败: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func deduplicatedAndSortedWorldbooks(_ worldbooks: [Worldbook]) -> [Worldbook] {
        var merged: [Worldbook] = []
        var knownIDs = Set<UUID>()

        for worldbook in worldbooks {
            if knownIDs.insert(worldbook.id).inserted {
                merged.append(worldbook)
            }
        }

        return merged.sorted { lhs, rhs in
            if lhs.updatedAt == rhs.updatedAt {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    private func updateCaches(with worldbooks: [Worldbook]) {
        cachedWorldbooks = worldbooks
        cacheByID = Dictionary(uniqueKeysWithValues: worldbooks.map { ($0.id, $0) })
        cacheNormalizedContents = Set(
            worldbooks.flatMap { book in
                book.entries.map { Self.normalizedContent($0.content) }
            }
        )
    }

    private func deduplicateEntriesInBook(_ entries: [WorldbookEntry]) -> [WorldbookEntry] {
        var seen = Set<String>()
        var result: [WorldbookEntry] = []
        for var entry in entries {
            let keySignature = entry.keys.map { $0.lowercased() }.sorted().joined(separator: "|")
            let signature = "\(Self.normalizedContent(entry.content))::\(keySignature)"
            if seen.contains(signature) {
                continue
            }
            if result.contains(where: { $0.id == entry.id }) {
                entry.id = UUID()
            }
            seen.insert(signature)
            result.append(entry)
        }
        return result
    }

    private func deduplicateUUIDs(_ values: [UUID]) -> [UUID] {
        var seen = Set<UUID>()
        var ordered: [UUID] = []
        for id in values where !seen.contains(id) {
            seen.insert(id)
            ordered.append(id)
        }
        return ordered
    }

    public static func normalizedContent(_ content: String) -> String {
        content
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .lowercased()
    }

    public static func uniqueSyncName(baseName: String, existing: [String]) -> String {
        let trimmed = baseName.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = trimmed.isEmpty ? "导入世界书" : trimmed
        let existingSet = Set(existing.map { $0.lowercased() })

        if !existingSet.contains(fallback.lowercased()) {
            return fallback
        }

        let first = "\(fallback)（同步）"
        if !existingSet.contains(first.lowercased()) {
            return first
        }

        var index = 2
        while true {
            let candidate = "\(fallback)（同步\(index)）"
            if !existingSet.contains(candidate.lowercased()) {
                return candidate
            }
            index += 1
        }
    }
}
