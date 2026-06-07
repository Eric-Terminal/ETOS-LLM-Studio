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

    struct StandaloneLoadResult {
        var worldbooks: [Worldbook]
        var requiresRewrite: Bool
    }

    struct LoadedStandaloneBook {
        var worldbook: Worldbook
        var requiresRewrite: Bool
    }

    let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "WorldbookStore")
    let queue = DispatchQueue(label: "com.ETOS.LLM.Studio.worldbook.store")
    let encoder: JSONEncoder
    let decoder: JSONDecoder
    let importService: WorldbookImportService
    let storageDirectoryOverride: URL?
    var cachedWorldbooks: [Worldbook]?
    var cacheByID: [UUID: Worldbook] = [:]
    var cacheNormalizedContents: Set<String> = []

    public static let directoryName = "Worldbooks"
    public static let fileName = "worldbooks.json"
    static let grdbBlobKey = "worldbooks"
    static let legacyGrdbBlobKey = "worldbooks_v1"
    static let legacyBlobKeys = [grdbBlobKey, legacyGrdbBlobKey]
    static let standaloneFileExtension = "json"
    static let importedFileExtensions: Set<String> = ["json", "png"]

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
        NotificationCenter.default.post(name: .cloudSyncLocalDataDidChange, object: nil)
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
        NotificationCenter.default.post(name: .cloudSyncLocalDataDidChange, object: nil)
    }

    public func deleteWorldbook(id: UUID) {
        queue.sync {
            var all = loadWorldbooksUnlocked()
            all.removeAll { $0.id == id }
            saveWorldbooksUnlocked(all)
        }
        NotificationCenter.default.post(name: .cloudSyncLocalDataDidChange, object: nil)
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
        let report = queue.sync {
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
                    failureReasons.append(NSLocalizedString("导入内容为空，或条目均被去重跳过。", comment: "Worldbook import skipped all entries"))
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
        if report.importedBookID != nil {
            NotificationCenter.default.post(name: .cloudSyncLocalDataDidChange, object: nil)
        }
        return report
    }
}
