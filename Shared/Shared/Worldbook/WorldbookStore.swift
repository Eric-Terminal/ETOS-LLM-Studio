// ============================================================================
// WorldbookStore.swift
// ============================================================================
// 世界书持久化存储
//
// 负责 worldbooks.json 的读写、去重导入与基础 CRUD。
// ============================================================================

import Foundation
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

    private let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "WorldbookStore")
    private let queue = DispatchQueue(label: "com.ETOS.LLM.Studio.worldbook.store")
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var cachedWorldbooks: [Worldbook]?
    private var cacheByID: [UUID: Worldbook] = [:]
    private var cacheNormalizedContents: Set<String> = []

    public static let directoryName = "Worldbooks"
    public static let fileName = "worldbooks.json"

    private init() {
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    public var storageDirectory: URL {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        return paths[0].appendingPathComponent(Self.directoryName, isDirectory: true)
    }

    public var storageFileURL: URL {
        storageDirectory.appendingPathComponent(Self.fileName, isDirectory: false)
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
        _ = ensureDirectoryIfNeeded()
        let fileURL = storageFileURL
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            updateCaches(with: [])
            return []
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let books = try decoder.decode([Worldbook].self, from: data)
            let sorted = books.sorted { $0.updatedAt > $1.updatedAt }
            updateCaches(with: sorted)
            return sorted
        } catch {
            logger.error("读取世界书失败: \(error.localizedDescription, privacy: .public)")
            updateCaches(with: [])
            return []
        }
    }

    private func saveWorldbooksUnlocked(_ worldbooks: [Worldbook]) {
        _ = ensureDirectoryIfNeeded()
        do {
            let data = try encoder.encode(worldbooks)
            try data.write(to: storageFileURL, options: [.atomicWrite, .completeFileProtection])
            logger.info("已保存世界书: \(worldbooks.count)")
            let sorted = worldbooks.sorted { $0.updatedAt > $1.updatedAt }
            updateCaches(with: sorted)
        } catch {
            logger.error("保存世界书失败: \(error.localizedDescription, privacy: .public)")
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
