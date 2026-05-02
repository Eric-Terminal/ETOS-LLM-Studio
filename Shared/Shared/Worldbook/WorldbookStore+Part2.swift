import Foundation
import GRDB
import os.log

extension WorldbookStore {
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

    // MARK: - GRDB 关系模型

    struct RelationalWorldbookRecord: Codable, FetchableRecord, MutablePersistableRecord, TableRecord {
        static let databaseTableName = "worldbooks"

        enum CodingKeys: String, CodingKey {
            case id
            case name
            case description
            case isEnabled = "is_enabled"
            case createdAt = "created_at"
            case updatedAt = "updated_at"
            case scanDepth = "scan_depth"
            case maxRecursionDepth = "max_recursion_depth"
            case maxInjectedEntries = "max_injected_entries"
            case maxInjectedCharacters = "max_injected_characters"
            case fallbackPosition = "fallback_position"
            case sourceFileName = "source_file_name"
        }

        var id: String
        var name: String
        var description: String
        var isEnabled: Int
        var createdAt: Double
        var updatedAt: Double
        var scanDepth: Int
        var maxRecursionDepth: Int
        var maxInjectedEntries: Int
        var maxInjectedCharacters: Int
        var fallbackPosition: String
        var sourceFileName: String?
    }

    struct RelationalWorldbookMetadataRecord: Codable, FetchableRecord, MutablePersistableRecord, TableRecord {
        static let databaseTableName = "worldbook_metadata"

        enum CodingKeys: String, CodingKey {
            case worldbookID = "worldbook_id"
            case metaKey = "meta_key"
            case valueType = "value_type"
            case stringValue = "string_value"
            case numberValue = "number_value"
            case boolValue = "bool_value"
            case jsonValueText = "json_value_text"
        }

        var worldbookID: String
        var metaKey: String
        var valueType: String
        var stringValue: String?
        var numberValue: Double?
        var boolValue: Int?
        var jsonValueText: String?
    }

    struct RelationalWorldbookEntryRecord: Codable, FetchableRecord, MutablePersistableRecord, TableRecord {
        static let databaseTableName = "worldbook_entries"

        enum CodingKeys: String, CodingKey {
            case id
            case worldbookID = "worldbook_id"
            case uid
            case comment
            case content
            case selectiveLogic = "selective_logic"
            case isEnabled = "is_enabled"
            case constantFlag = "constant_flag"
            case position
            case outletName = "outlet_name"
            case entryOrder = "entry_order"
            case depth
            case scanDepth = "scan_depth"
            case caseSensitive = "case_sensitive"
            case matchWholeWords = "match_whole_words"
            case useRegex = "use_regex"
            case useProbability = "use_probability"
            case probability
            case groupName = "group_name"
            case groupOverride = "group_override"
            case groupWeight = "group_weight"
            case useGroupScoring = "use_group_scoring"
            case role
            case sticky
            case cooldown
            case delay
            case excludeRecursion = "exclude_recursion"
            case preventRecursion = "prevent_recursion"
            case delayUntilRecursion = "delay_until_recursion"
            case sortIndex = "sort_index"
        }

        var id: String
        var worldbookID: String
        var uid: Int?
        var comment: String
        var content: String
        var selectiveLogic: String
        var isEnabled: Int
        var constantFlag: Int
        var position: String
        var outletName: String?
        var entryOrder: Int
        var depth: Int?
        var scanDepth: Int?
        var caseSensitive: Int
        var matchWholeWords: Int
        var useRegex: Int
        var useProbability: Int
        var probability: Double
        var groupName: String?
        var groupOverride: Int
        var groupWeight: Double
        var useGroupScoring: Int
        var role: String
        var sticky: Int?
        var cooldown: Int?
        var delay: Int?
        var excludeRecursion: Int
        var preventRecursion: Int
        var delayUntilRecursion: Int
        var sortIndex: Int
    }

    struct RelationalWorldbookEntryKeyRecord: Codable, FetchableRecord, MutablePersistableRecord, TableRecord {
        static let databaseTableName = "worldbook_entry_keys"

        enum CodingKeys: String, CodingKey {
            case entryID = "entry_id"
            case keyValue = "key_value"
            case keyKind = "key_kind"
            case sortIndex = "sort_index"
        }

        var entryID: String
        var keyValue: String
        var keyKind: String
        var sortIndex: Int
    }

    struct RelationalWorldbookEntryMetadataRecord: Codable, FetchableRecord, MutablePersistableRecord, TableRecord {
        static let databaseTableName = "worldbook_entry_metadata"

        enum CodingKeys: String, CodingKey {
            case entryID = "entry_id"
            case metaKey = "meta_key"
            case valueType = "value_type"
            case stringValue = "string_value"
            case numberValue = "number_value"
            case boolValue = "bool_value"
            case jsonValueText = "json_value_text"
        }

        var entryID: String
        var metaKey: String
        var valueType: String
        var stringValue: String?
        var numberValue: Double?
        var boolValue: Int?
        var jsonValueText: String?
    }

    func loadStandaloneWorldbooksUnlocked() -> StandaloneLoadResult {
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

    func loadLegacyWorldbooksUnlocked() -> StandaloneLoadResult {
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

    func loadStandaloneWorldbook(at fileURL: URL) -> LoadedStandaloneBook? {
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

    func standaloneCandidateFileURLs() -> [URL] {
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

    func standaloneFileURLs(for worldbooks: [Worldbook]) -> [UUID: URL] {
        var usedNames = Set<String>()
        var result: [UUID: URL] = [:]

        for worldbook in worldbooks.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            let fileName = nextAvailableStandaloneFileName(for: worldbook, usedNames: &usedNames)
            result[worldbook.id] = storageDirectory.appendingPathComponent(fileName, isDirectory: false)
        }

        return result
    }

    func nextAvailableStandaloneFileName(
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

    func preferredStandaloneFileName(for worldbook: Worldbook) -> String {
        if let sourceFileName = worldbook.sourceFileName,
           !sourceFileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let sanitizedSource = sanitizedSourceFileName(sourceFileName) {
            return sanitizedSource
        }

        return nameBasedStandaloneFileName(for: worldbook)
    }

    func nameBasedStandaloneFileName(for worldbook: Worldbook) -> String {
        let baseName = sanitizedFileComponent(worldbook.name)
        let safeBaseName = baseName.isEmpty ? "worldbook" : baseName
        return "\(safeBaseName)--\(worldbook.id.uuidString.lowercased()).\(Self.standaloneFileExtension)"
    }

    func indexedStandaloneFileName(for worldbook: Worldbook, index: Int) -> String {
        let baseName = sanitizedFileComponent(worldbook.name)
        let safeBaseName = baseName.isEmpty ? "worldbook" : baseName
        return "\(safeBaseName)--\(worldbook.id.uuidString.lowercased())-\(index).\(Self.standaloneFileExtension)"
    }

    func sanitizedSourceFileName(_ rawValue: String) -> String? {
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

    func sanitizedFileComponent(_ rawValue: String) -> String {
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

    func cleanupStaleStandaloneFiles(
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

    func cleanupLegacyFilesAfterGRDBSave(removeLegacyAggregate: Bool) {
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

    func deduplicatedAndSortedWorldbooks(_ worldbooks: [Worldbook]) -> [Worldbook] {
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

    func updateCaches(with worldbooks: [Worldbook]) {
        cachedWorldbooks = worldbooks
        cacheByID = Dictionary(uniqueKeysWithValues: worldbooks.map { ($0.id, $0) })
        cacheNormalizedContents = Set(
            worldbooks.flatMap { book in
                book.entries.map { Self.normalizedContent($0.content) }
            }
        )
    }

    func deduplicateEntriesInBook(_ entries: [WorldbookEntry]) -> [WorldbookEntry] {
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

    func deduplicateUUIDs(_ values: [UUID]) -> [UUID] {
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
