import Foundation
import GRDB
import os.log

extension WorldbookStore {
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

    var canUseGRDB: Bool {
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

    func ensureDirectoryIfNeeded() -> URL {
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

    func loadWorldbooksUnlocked() -> [Worldbook] {
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

    func saveWorldbooksUnlocked(
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

    func loadWorldbooksFromSQLite() -> [Worldbook]? {
        guard let worldbooks = Persistence.withConfigDatabaseRead({ db in
            try loadWorldbooksFromRelationalStore(db)
        }) else {
            return nil
        }

        if worldbooks.isEmpty,
           let legacyWorldbooks = loadLegacyWorldbooksFromBlob(),
           !legacyWorldbooks.isEmpty {
            if saveWorldbooksToSQLite(legacyWorldbooks) {
                removeLegacyWorldbookBlobs()
            }
            return legacyWorldbooks
        }

        return worldbooks
    }

    func loadLegacyWorldbooksFromBlob() -> [Worldbook]? {
        for key in Self.legacyBlobKeys {
            guard Persistence.auxiliaryBlobExists(forKey: key) else {
                continue
            }
            return Persistence.loadAuxiliaryBlob([Worldbook].self, forKey: key) ?? []
        }
        return nil
    }

    @discardableResult
    func saveWorldbooksToSQLite(_ worldbooks: [Worldbook]) -> Bool {
        let didSave = Persistence.withConfigDatabaseWrite { db in
            try RelationalWorldbookRecord.deleteAll(db)

            for worldbook in worldbooks {
                var worldbookRecord = RelationalWorldbookRecord(
                    id: worldbook.id.uuidString,
                    name: worldbook.name,
                    description: worldbook.description,
                    isEnabled: worldbook.isEnabled ? 1 : 0,
                    createdAt: worldbook.createdAt.timeIntervalSince1970,
                    updatedAt: worldbook.updatedAt.timeIntervalSince1970,
                    scanDepth: worldbook.settings.scanDepth,
                    maxRecursionDepth: worldbook.settings.maxRecursionDepth,
                    maxInjectedEntries: worldbook.settings.maxInjectedEntries,
                    maxInjectedCharacters: worldbook.settings.maxInjectedCharacters,
                    fallbackPosition: worldbook.settings.fallbackPosition.stRawValue,
                    sourceFileName: worldbook.sourceFileName
                )
                try worldbookRecord.insert(db)

                for metadataKey in worldbook.metadata.keys.sorted() {
                    let encodedValue = RelationalJSONValueCodec.encode(worldbook.metadata[metadataKey] ?? .null)
                    var metadataRecord = RelationalWorldbookMetadataRecord(
                        worldbookID: worldbook.id.uuidString,
                        metaKey: metadataKey,
                        valueType: encodedValue.type,
                        stringValue: encodedValue.stringValue,
                        numberValue: encodedValue.numberValue,
                        boolValue: encodedValue.boolValue,
                        jsonValueText: encodedValue.jsonValueText
                    )
                    try metadataRecord.insert(db)
                }

                for (entryIndex, entry) in worldbook.entries.enumerated() {
                    var entryRecord = RelationalWorldbookEntryRecord(
                        id: entry.id.uuidString,
                        worldbookID: worldbook.id.uuidString,
                        uid: entry.uid,
                        comment: entry.comment,
                        content: entry.content,
                        selectiveLogic: entry.selectiveLogic.rawValue,
                        isEnabled: entry.isEnabled ? 1 : 0,
                        constantFlag: entry.constant ? 1 : 0,
                        position: entry.position.stRawValue,
                        outletName: entry.outletName,
                        entryOrder: entry.order,
                        depth: entry.depth,
                        scanDepth: entry.scanDepth,
                        caseSensitive: entry.caseSensitive ? 1 : 0,
                        matchWholeWords: entry.matchWholeWords ? 1 : 0,
                        useRegex: entry.useRegex ? 1 : 0,
                        useProbability: entry.useProbability ? 1 : 0,
                        probability: entry.probability,
                        groupName: entry.group,
                        groupOverride: entry.groupOverride ? 1 : 0,
                        groupWeight: entry.groupWeight,
                        useGroupScoring: entry.useGroupScoring ? 1 : 0,
                        role: entry.role.rawValue,
                        sticky: entry.sticky,
                        cooldown: entry.cooldown,
                        delay: entry.delay,
                        excludeRecursion: entry.excludeRecursion ? 1 : 0,
                        preventRecursion: entry.preventRecursion ? 1 : 0,
                        delayUntilRecursion: entry.delayUntilRecursion ? 1 : 0,
                        sortIndex: entryIndex
                    )
                    try entryRecord.insert(db)

                    for (keyIndex, keyValue) in entry.keys.enumerated() {
                        var keyRecord = RelationalWorldbookEntryKeyRecord(
                            entryID: entry.id.uuidString,
                            keyValue: keyValue,
                            keyKind: "primary",
                            sortIndex: keyIndex
                        )
                        try keyRecord.insert(db)
                    }

                    for (keyIndex, keyValue) in entry.secondaryKeys.enumerated() {
                        var keyRecord = RelationalWorldbookEntryKeyRecord(
                            entryID: entry.id.uuidString,
                            keyValue: keyValue,
                            keyKind: "secondary",
                            sortIndex: keyIndex
                        )
                        try keyRecord.insert(db)
                    }

                    for metadataKey in entry.metadata.keys.sorted() {
                        let encodedValue = RelationalJSONValueCodec.encode(entry.metadata[metadataKey] ?? .null)
                        var metadataRecord = RelationalWorldbookEntryMetadataRecord(
                            entryID: entry.id.uuidString,
                            metaKey: metadataKey,
                            valueType: encodedValue.type,
                            stringValue: encodedValue.stringValue,
                            numberValue: encodedValue.numberValue,
                            boolValue: encodedValue.boolValue,
                            jsonValueText: encodedValue.jsonValueText
                        )
                        try metadataRecord.insert(db)
                    }
                }
            }

            return true
        } ?? false

        if didSave {
            removeLegacyWorldbookBlobs()
        }
        return didSave
    }

    func removeLegacyWorldbookBlobs() {
        for key in Self.legacyBlobKeys {
            _ = Persistence.removeAuxiliaryBlob(forKey: key)
        }
    }

}
