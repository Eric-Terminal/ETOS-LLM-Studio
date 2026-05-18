// ============================================================================
// WorldbookStoreSupport.swift
// ============================================================================
// 世界书存储的文件读写、数据库和去重辅助。
// ============================================================================

import Foundation
import os.log

extension WorldbookStore {
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
            let sortedStoredWorldbooks = deduplicatedAndSortedWorldbooks(storedWorldbooks, normalizeLegacyBudgets: true)
            updateCaches(with: sortedStoredWorldbooks)
            cleanupLegacyFilesAfterGRDBSave(removeLegacyAggregate: true)
            return sortedStoredWorldbooks
        }

        _ = ensureDirectoryIfNeeded()
        let standaloneResult = loadStandaloneWorldbooksUnlocked()
        let legacyResult = loadLegacyWorldbooksUnlocked()

        let sorted = deduplicatedAndSortedWorldbooks(standaloneResult.worldbooks + legacyResult.worldbooks, normalizeLegacyBudgets: true)

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

    func deduplicatedAndSortedWorldbooks(
        _ worldbooks: [Worldbook],
        normalizeLegacyBudgets: Bool = false
    ) -> [Worldbook] {
        var merged: [Worldbook] = []
        var knownIDs = Set<UUID>()

        for worldbook in worldbooks {
            let normalized = normalizeLegacyBudgets ? normalizedInjectionBudgetDefaults(for: worldbook) : worldbook
            if knownIDs.insert(normalized.id).inserted {
                merged.append(normalized)
            }
        }

        return merged.sorted { lhs, rhs in
            if lhs.updatedAt == rhs.updatedAt {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    func normalizedInjectionBudgetDefaults(for worldbook: Worldbook) -> Worldbook {
        guard worldbook.settings.maxInjectedEntries == 64,
              !hasExplicitImportedEntryBudget(worldbook.metadata) else {
            return worldbook
        }

        var normalized = worldbook
        normalized.settings.maxInjectedEntries = WorldbookSettings.unlimitedInjectedEntries
        return normalized
    }

    private func hasExplicitImportedEntryBudget(_ metadata: [String: JSONValue]) -> Bool {
        let nestedSettings: [String: JSONValue]
        if case .dictionary(let value) = metadata["settings"] {
            nestedSettings = value
        } else {
            nestedSettings = [:]
        }

        let hasRootBudget = metadata["maxEntries"] != nil ||
            metadata["max_entries"] != nil ||
            metadata["maxInjectedEntries"] != nil ||
            metadata["max_injected_entries"] != nil ||
            metadata["etosExplicitMaxInjectedEntries"] != nil
        let hasNestedBudget = nestedSettings["maxEntries"] != nil ||
            nestedSettings["max_entries"] != nil ||
            nestedSettings["maxInjectedEntries"] != nil ||
            nestedSettings["max_injected_entries"] != nil
        return hasRootBudget || hasNestedBudget
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
