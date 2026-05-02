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
    public static let directoryName = "Worldbooks"
    public static let fileName = "worldbooks.json"
    static let grdbBlobKey = "worldbooks"
    static let legacyGrdbBlobKey = "worldbooks_v1"
    static let legacyBlobKeys = [grdbBlobKey, legacyGrdbBlobKey]
    static let standaloneFileExtension = "json"
    static let importedFileExtensions: Set<String> = ["json", "png"]

    var cachedWorldbooks: [Worldbook]?
    var cacheByID: [UUID: Worldbook] = [:]
    var cacheNormalizedContents: Set<String> = []

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
}
