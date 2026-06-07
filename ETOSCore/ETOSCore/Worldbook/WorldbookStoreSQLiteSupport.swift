// ============================================================================
// WorldbookStoreSQLiteSupport.swift
// ============================================================================
// ETOS LLM Studio
//
// 世界书存储的 SQLite 关系表读写与旧辅助 blob 迁移逻辑。
// ============================================================================

import Foundation
import GRDB

extension WorldbookStore {
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

    func loadWorldbooksFromRelationalStore(_ db: Database) throws -> [Worldbook] {
        let worldbookRows = try RelationalWorldbookRecord.fetchAll(db)
            .sorted {
                if $0.updatedAt == $1.updatedAt {
                    return $0.id < $1.id
                }
                return $0.updatedAt > $1.updatedAt
            }

        let worldbookMetadataRows = try RelationalWorldbookMetadataRecord.fetchAll(db)
            .sorted {
                if $0.worldbookID == $1.worldbookID {
                    return $0.metaKey < $1.metaKey
                }
                return $0.worldbookID < $1.worldbookID
            }
        var worldbookMetadataByID: [String: [String: JSONValue]] = [:]
        for row in worldbookMetadataRows {
            worldbookMetadataByID[row.worldbookID, default: [:]][row.metaKey] = RelationalJSONValueCodec.decode(
                type: row.valueType,
                stringValue: row.stringValue,
                numberValue: row.numberValue,
                boolValue: row.boolValue,
                jsonValueText: row.jsonValueText
            )
        }

        let entryRows = try RelationalWorldbookEntryRecord.fetchAll(db)
            .sorted {
                if $0.worldbookID != $1.worldbookID {
                    return $0.worldbookID < $1.worldbookID
                }
                if $0.sortIndex != $1.sortIndex {
                    return $0.sortIndex < $1.sortIndex
                }
                return $0.id < $1.id
            }

        let entryKeyRows = try RelationalWorldbookEntryKeyRecord.fetchAll(db)
            .sorted {
                if $0.entryID != $1.entryID {
                    return $0.entryID < $1.entryID
                }
                if $0.keyKind != $1.keyKind {
                    return $0.keyKind < $1.keyKind
                }
                return $0.sortIndex < $1.sortIndex
            }
        var primaryKeysByEntryID: [String: [String]] = [:]
        var secondaryKeysByEntryID: [String: [String]] = [:]
        for row in entryKeyRows {
            if row.keyKind == "secondary" {
                secondaryKeysByEntryID[row.entryID, default: []].append(row.keyValue)
            } else {
                primaryKeysByEntryID[row.entryID, default: []].append(row.keyValue)
            }
        }

        let entryMetadataRows = try RelationalWorldbookEntryMetadataRecord.fetchAll(db)
            .sorted {
                if $0.entryID == $1.entryID {
                    return $0.metaKey < $1.metaKey
                }
                return $0.entryID < $1.entryID
            }
        var entryMetadataByID: [String: [String: JSONValue]] = [:]
        for row in entryMetadataRows {
            entryMetadataByID[row.entryID, default: [:]][row.metaKey] = RelationalJSONValueCodec.decode(
                type: row.valueType,
                stringValue: row.stringValue,
                numberValue: row.numberValue,
                boolValue: row.boolValue,
                jsonValueText: row.jsonValueText
            )
        }

        var entriesByWorldbookID: [String: [WorldbookEntry]] = [:]
        for row in entryRows {
            let entryIDRaw = row.id
            let worldbookID = row.worldbookID

            let entry = WorldbookEntry(
                id: UUID(uuidString: entryIDRaw) ?? UUID(),
                uid: row.uid,
                comment: row.comment,
                content: row.content,
                keys: primaryKeysByEntryID[entryIDRaw] ?? [],
                secondaryKeys: secondaryKeysByEntryID[entryIDRaw] ?? [],
                selectiveLogic: WorldbookSelectiveLogic(rawOrLegacyValue: row.selectiveLogic),
                isEnabled: row.isEnabled != 0,
                constant: row.constantFlag != 0,
                position: WorldbookPosition(stRawValue: row.position),
                outletName: row.outletName,
                order: row.entryOrder,
                depth: row.depth,
                scanDepth: row.scanDepth,
                caseSensitive: row.caseSensitive != 0,
                matchWholeWords: row.matchWholeWords != 0,
                useRegex: row.useRegex != 0,
                useProbability: row.useProbability != 0,
                probability: row.probability,
                group: row.groupName,
                groupOverride: row.groupOverride != 0,
                groupWeight: row.groupWeight,
                useGroupScoring: row.useGroupScoring != 0,
                role: WorldbookEntryRole(rawOrLegacyValue: row.role),
                sticky: row.sticky,
                cooldown: row.cooldown,
                delay: row.delay,
                excludeRecursion: row.excludeRecursion != 0,
                preventRecursion: row.preventRecursion != 0,
                delayUntilRecursion: row.delayUntilRecursion != 0,
                metadata: entryMetadataByID[entryIDRaw] ?? [:]
            )
            entriesByWorldbookID[worldbookID, default: []].append(entry)
        }

        return worldbookRows.map { row in
            let worldbookIDRaw = row.id
            let settings = WorldbookSettings(
                scanDepth: row.scanDepth,
                maxRecursionDepth: row.maxRecursionDepth,
                maxInjectedEntries: row.maxInjectedEntries,
                maxInjectedCharacters: row.maxInjectedCharacters,
                fallbackPosition: WorldbookPosition(stRawValue: row.fallbackPosition)
            )

            return Worldbook(
                id: UUID(uuidString: worldbookIDRaw) ?? UUID(),
                name: row.name,
                description: row.description,
                isEnabled: row.isEnabled != 0,
                createdAt: Date(timeIntervalSince1970: row.createdAt),
                updatedAt: Date(timeIntervalSince1970: row.updatedAt),
                entries: entriesByWorldbookID[worldbookIDRaw] ?? [],
                settings: settings,
                sourceFileName: row.sourceFileName,
                metadata: worldbookMetadataByID[worldbookIDRaw] ?? [:]
            )
        }
    }
}
