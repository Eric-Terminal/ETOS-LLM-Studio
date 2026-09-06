// ============================================================================
// MemoryRawStore.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责读写长期记忆的原始文本列表（未分块）到 SQLite（失败时回退 Memory/memories.json）。
// UI 层展示的数据直接来源于原始存储，而不依赖向量索引。
// ============================================================================

import Foundation
import GRDB
import os.log

struct MemoryRawStore: Sendable {
    private let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "MemoryRawStore")
    private static var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
    private static let sqliteWriteQueueSpecificKey = DispatchSpecificKey<UInt8>()
    private static let sqliteWriteQueue: DispatchQueue = {
        let queue = DispatchQueue(
            label: "com.etos.memory.sqlite.incremental.write.queue",
            qos: .userInitiated
        )
        queue.setSpecific(key: sqliteWriteQueueSpecificKey, value: 1)
        return queue
    }()
    private let rootDirectory: URL?
    private let grdbBlobKey = "memory_raw_memories"
    private var legacyBlobKeys: [String] { [grdbBlobKey, "memory_raw_memories_v1"] }
    
    init(rootDirectory: URL? = nil) {
        self.rootDirectory = rootDirectory
    }
    
    func loadMemories() -> [MemoryItem] {
        let legacyJSONMemories = loadMemoriesFromJSONFile()

        if canUseGRDB, let sqliteMemories = loadMemoriesFromSQLite() {
            if !sqliteMemories.isEmpty {
                persistJSONMirror(sqliteMemories)
                return sqliteMemories
            }

            if let legacyJSONMemories, !legacyJSONMemories.isEmpty {
                _ = saveMemoriesToSQLite(legacyJSONMemories, asynchronously: !Self.isRunningUnitTests)
                persistJSONMirror(legacyJSONMemories)
                return legacyJSONMemories
            }

            return sqliteMemories
        }

        if let legacyJSONMemories {
            if canUseGRDB {
                _ = saveMemoriesToSQLite(legacyJSONMemories, asynchronously: !Self.isRunningUnitTests)
            }
            return legacyJSONMemories
        }

        return []
    }
    
    func saveMemories(_ memories: [MemoryItem]) throws {
        persistJSONMirror(memories)
        if canUseGRDB {
            _ = saveMemoriesToSQLite(memories, asynchronously: !Self.isRunningUnitTests)
        }
    }

    /// 记忆正文与审计记录在同一个 GRDB 事务内提交；任一写入失败都不会留下半条历史。
    func commitMutations(
        _ mutations: [MemoryPendingMutation],
        resultingMemories: [MemoryItem]
    ) -> Bool {
        guard !mutations.isEmpty else { return true }
        if canUseGRDB {
            let encoder = Self.makeEncoder()
            // 先排空旧的异步镜像写入，避免它在审计事务之后回写过期快照。
            Self.flushPendingSQLiteWritesForSnapshot()
            let succeeded = Persistence.withMemoryDatabaseWrite { db in
                for mutation in mutations {
                    if let memory = mutation.after {
                        try Self.upsert(memory: memory, in: db)
                    } else {
                        try db.execute(
                            sql: "DELETE FROM memory_items WHERE id = ?",
                            arguments: [mutation.record.memoryID.uuidString]
                        )
                    }
                    try Self.insertMutation(mutation.record, in: db, encoder: encoder)
                }
                return true
            } ?? false
            guard succeeded else { return false }
            persistJSONMirror(resultingMemories)
            WatchDatabaseSyncService.markDatabaseChanged(.memory)
            return true
        }

        do {
            let encoder = Self.makeEncoder()
            let memoryURL = MemoryStoragePaths.rawMemoriesFileURL(rootDirectory: rootDirectory)
            let historyURL = MemoryStoragePaths.mutationHistoryFileURL(rootDirectory: rootDirectory)
            let previousMemoryData = try? Data(contentsOf: memoryURL)
            let previousHistoryData = try? Data(contentsOf: historyURL)
            var history = loadMutationHistoryFromJSON()
            history.append(contentsOf: mutations.map(\.record))
            do {
                try encoder.encode(resultingMemories).write(to: memoryURL, options: [.atomicWrite, .completeFileProtection])
                try encoder.encode(history).write(to: historyURL, options: [.atomicWrite, .completeFileProtection])
                return true
            } catch {
                try? Self.restoreFile(at: memoryURL, data: previousMemoryData)
                try? Self.restoreFile(at: historyURL, data: previousHistoryData)
                throw error
            }
        } catch {
            logger.error("提交记忆与审计记录失败: \(error.localizedDescription)")
            return false
        }
    }

    func loadMutationHistory(memoryID: UUID? = nil, limit: Int = 200) -> [MemoryMutationRecord] {
        let boundedLimit = min(max(limit, 1), 2_000)
        if canUseGRDB {
            let decoder = Self.makeDecoder()
            return Persistence.withMemoryDatabaseRead { db in
                let rows: [Row]
                if let memoryID {
                    rows = try Row.fetchAll(
                        db,
                        sql: """
                            SELECT * FROM memory_mutation_history
                            WHERE memory_id = ?
                            ORDER BY created_at DESC, id DESC
                            LIMIT ?
                        """,
                        arguments: [memoryID.uuidString, boundedLimit]
                    )
                } else {
                    rows = try Row.fetchAll(
                        db,
                        sql: """
                            SELECT * FROM memory_mutation_history
                            ORDER BY created_at DESC, id DESC
                            LIMIT ?
                        """,
                        arguments: [boundedLimit]
                    )
                }
                return try rows.map { try Self.decodeMutation(row: $0, decoder: decoder) }
            } ?? []
        }
        return Array(loadMutationHistoryFromJSON()
            .filter { memoryID == nil || $0.memoryID == memoryID }
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(boundedLimit))
    }

    @discardableResult
    func saveTransferReceipt(_ receipt: MemoryTransferReceipt) -> Bool {
        if canUseGRDB {
            let succeeded = Persistence.withMemoryDatabaseWrite { db in
                try db.execute(
                    sql: """
                        INSERT INTO memory_transfer_receipts (
                            id, kind, file_name, payload_sha256, added_count,
                            updated_count, conflict_count, archived_count, created_at
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        receipt.id.uuidString,
                        receipt.kind.rawValue,
                        receipt.fileName,
                        receipt.payloadSHA256,
                        receipt.addedCount,
                        receipt.updatedCount,
                        receipt.conflictCount,
                        receipt.archivedCount,
                        receipt.createdAt.timeIntervalSince1970
                    ]
                )
                return true
            } ?? false
            if succeeded { WatchDatabaseSyncService.markDatabaseChanged(.memory) }
            return succeeded
        }
        do {
            let encoder = Self.makeEncoder()
            let url = MemoryStoragePaths.transferReceiptsFileURL(rootDirectory: rootDirectory)
            var receipts = loadTransferReceiptsFromJSON()
            receipts.append(receipt)
            try encoder.encode(receipts).write(to: url, options: [.atomicWrite, .completeFileProtection])
            return true
        } catch {
            logger.error("保存记忆迁移回执失败: \(error.localizedDescription)")
            return false
        }
    }

    func loadTransferReceipts(limit: Int = 100) -> [MemoryTransferReceipt] {
        let boundedLimit = min(max(limit, 1), 1_000)
        if canUseGRDB {
            return Persistence.withMemoryDatabaseRead { db in
                try Row.fetchAll(
                    db,
                    sql: "SELECT * FROM memory_transfer_receipts ORDER BY created_at DESC, id DESC LIMIT ?",
                    arguments: [boundedLimit]
                ).compactMap(Self.decodeTransferReceipt)
            } ?? []
        }
        return Array(loadTransferReceiptsFromJSON().sorted { $0.createdAt > $1.createdAt }.prefix(boundedLimit))
    }

    static func flushPendingSQLiteWritesForSnapshot() {
        if DispatchQueue.getSpecific(key: sqliteWriteQueueSpecificKey) != nil {
            return
        }
        sqliteWriteQueue.sync {}
    }

    private var canUseGRDB: Bool {
        rootDirectory == nil
    }

    private func loadMemoriesFromSQLite() -> [MemoryItem]? {
        guard let memories = Persistence.withMemoryDatabaseRead({ db in
            try Self.loadMemories(from: db)
        }) else {
            return nil
        }

        if memories.isEmpty,
           let legacy = loadLegacyMemoriesFromBlob(),
           !legacy.isEmpty {
            if saveMemoriesToSQLite(legacy, asynchronously: !Self.isRunningUnitTests) {
                removeLegacyMemoryBlobs()
            }
            return legacy
        }

        return memories
    }

    static func loadMemories(from db: Database) throws -> [MemoryItem] {
        try RelationalMemoryItemRecord.fetchAll(db)
            .sorted {
                if $0.createdAt == $1.createdAt {
                    return $0.id < $1.id
                }
                return $0.createdAt > $1.createdAt
            }
            .map { row in
                MemoryItem(
                    id: UUID(uuidString: row.id) ?? UUID(),
                    content: row.content,
                    embedding: RelationalFloatArrayCodec.decode(row.embeddingData),
                    createdAt: Date(timeIntervalSince1970: row.createdAt),
                    updatedAt: row.updatedAt.map(Date.init(timeIntervalSince1970:)),
                    isArchived: row.isArchived != 0,
                    kind: MemoryKind(rawValue: row.kind) ?? .semantic,
                    source: MemorySource(rawValue: row.source) ?? .manual,
                    importance: row.importance,
                    confidence: row.confidence,
                    entities: decodeEntities(row.entitiesJSON),
                    validFrom: row.validFrom.map(Date.init(timeIntervalSince1970:)),
                    validUntil: row.validUntil.map(Date.init(timeIntervalSince1970:)),
                    sourceSessionID: row.sourceSessionID.flatMap(UUID.init(uuidString:)),
                    accessCount: row.accessCount,
                    lastAccessedAt: row.lastAccessedAt.map(Date.init(timeIntervalSince1970:))
                )
            }
    }

    @discardableResult
    private func saveMemoriesToSQLite(_ memories: [MemoryItem], asynchronously: Bool) -> Bool {
        guard asynchronously else {
            return performIncrementalSQLiteWrite(memories)
        }

        Self.sqliteWriteQueue.async {
            _ = performIncrementalSQLiteWrite(memories)
        }
        return true
    }

    @discardableResult
    private func performIncrementalSQLiteWrite(_ memories: [MemoryItem]) -> Bool {
        let didSave = Persistence.withMemoryDatabaseWrite { db in
            let existingRecords = try RelationalMemoryItemRecord.fetchAll(db)
            var existingByID: [String: RelationalMemoryItemRecord] = [:]
            existingByID.reserveCapacity(existingRecords.count)
            for record in existingRecords {
                existingByID[record.id] = record
            }

            let targetIDs = Set(memories.map { $0.id.uuidString })
            for existingID in existingByID.keys where !targetIDs.contains(existingID) {
                try db.execute(
                    sql: "DELETE FROM memory_items WHERE id = ?",
                    arguments: [existingID]
                )
            }

            for memory in memories {
                let record = RelationalMemoryItemRecord(
                    id: memory.id.uuidString,
                    content: memory.content,
                    embeddingData: RelationalFloatArrayCodec.encode(memory.embedding),
                    createdAt: memory.createdAt.timeIntervalSince1970,
                    updatedAt: memory.updatedAt?.timeIntervalSince1970,
                    isArchived: memory.isArchived ? 1 : 0,
                    kind: memory.kind.rawValue,
                    source: memory.source.rawValue,
                    importance: memory.importance,
                    confidence: memory.confidence,
                    entitiesJSON: Self.encodeEntities(memory.entities),
                    validFrom: memory.validFrom?.timeIntervalSince1970,
                    validUntil: memory.validUntil?.timeIntervalSince1970,
                    sourceSessionID: memory.sourceSessionID?.uuidString,
                    accessCount: memory.accessCount,
                    lastAccessedAt: memory.lastAccessedAt?.timeIntervalSince1970
                )
                if let existing = existingByID[record.id], existing == record {
                    continue
                }

                try db.execute(
                    sql: """
                    INSERT INTO memory_items (
                        id, content, embedding_data, created_at, updated_at, is_archived,
                        kind, source, importance, confidence, entities_json,
                        valid_from, valid_until, source_session_id, access_count, last_accessed_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        content = excluded.content,
                        embedding_data = excluded.embedding_data,
                        created_at = excluded.created_at,
                        updated_at = excluded.updated_at,
                        is_archived = excluded.is_archived,
                        kind = excluded.kind,
                        source = excluded.source,
                        importance = excluded.importance,
                        confidence = excluded.confidence,
                        entities_json = excluded.entities_json,
                        valid_from = excluded.valid_from,
                        valid_until = excluded.valid_until,
                        source_session_id = excluded.source_session_id,
                        access_count = excluded.access_count,
                        last_accessed_at = excluded.last_accessed_at
                    """,
                    arguments: [
                        record.id,
                        record.content,
                        record.embeddingData,
                        record.createdAt,
                        record.updatedAt,
                        record.isArchived,
                        record.kind,
                        record.source,
                        record.importance,
                        record.confidence,
                        record.entitiesJSON,
                        record.validFrom,
                        record.validUntil,
                        record.sourceSessionID,
                        record.accessCount,
                        record.lastAccessedAt
                    ]
                )
            }
            return true
        } ?? false

        if didSave {
            removeLegacyMemoryBlobs()
            WatchDatabaseSyncService.markDatabaseChanged(.memory)
        }
        return didSave
    }

    private func loadLegacyMemoriesFromBlob() -> [MemoryItem]? {
        for key in legacyBlobKeys {
            guard Persistence.auxiliaryBlobExists(forKey: key) else {
                continue
            }
            return Persistence.loadAuxiliaryBlob([MemoryItem].self, forKey: key) ?? []
        }
        return nil
    }

    static func loadLegacyMemories(from store: PersistenceAuxiliaryGRDBStore) -> [MemoryItem]? {
        let keys = ["memory_raw_memories", "memory_raw_memories_v1"]
        for key in keys {
            if let memories = store.loadAuxiliaryBlob([MemoryItem].self, forKey: key) {
                return memories
            }
        }
        return nil
    }

    private func removeLegacyMemoryBlobs() {
        for key in legacyBlobKeys {
            _ = Persistence.removeAuxiliaryBlob(forKey: key)
        }
    }

    private func persistJSONMirror(_ memories: [MemoryItem]) {
        do {
            MemoryStoragePaths.ensureRootDirectory(rootDirectory: rootDirectory)
            let fileURL = MemoryStoragePaths.rawMemoriesFileURL(rootDirectory: rootDirectory)
            let data = try Self.makeEncoder().encode(memories)
            try data.write(to: fileURL, options: [.atomicWrite, .completeFileProtection])
        } catch {
            logger.error("写入 Memory JSON 镜像失败: \(error.localizedDescription)")
        }
    }

    private func loadMutationHistoryFromJSON() -> [MemoryMutationRecord] {
        let url = MemoryStoragePaths.mutationHistoryFileURL(rootDirectory: rootDirectory)
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? Self.makeDecoder().decode([MemoryMutationRecord].self, from: data)) ?? []
    }

    private func loadTransferReceiptsFromJSON() -> [MemoryTransferReceipt] {
        let url = MemoryStoragePaths.transferReceiptsFileURL(rootDirectory: rootDirectory)
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? Self.makeDecoder().decode([MemoryTransferReceipt].self, from: data)) ?? []
    }

    static func applyMutationForTests(
        _ mutation: MemoryPendingMutation,
        in db: Database
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let after = mutation.after {
            try upsert(memory: after, in: db)
        } else {
            try db.execute(sql: "DELETE FROM memory_items WHERE id = ?", arguments: [mutation.record.memoryID.uuidString])
        }
        try insertMutation(mutation.record, in: db, encoder: encoder)
    }

    private static func upsert(memory: MemoryItem, in db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO memory_items (
                    id, content, embedding_data, created_at, updated_at, is_archived,
                    kind, source, importance, confidence, entities_json,
                    valid_from, valid_until, source_session_id, access_count, last_accessed_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    content = excluded.content,
                    embedding_data = excluded.embedding_data,
                    created_at = excluded.created_at,
                    updated_at = excluded.updated_at,
                    is_archived = excluded.is_archived,
                    kind = excluded.kind,
                    source = excluded.source,
                    importance = excluded.importance,
                    confidence = excluded.confidence,
                    entities_json = excluded.entities_json,
                    valid_from = excluded.valid_from,
                    valid_until = excluded.valid_until,
                    source_session_id = excluded.source_session_id,
                    access_count = excluded.access_count,
                    last_accessed_at = excluded.last_accessed_at
            """,
            arguments: [
                memory.id.uuidString,
                memory.content,
                RelationalFloatArrayCodec.encode(memory.embedding),
                memory.createdAt.timeIntervalSince1970,
                memory.updatedAt?.timeIntervalSince1970,
                memory.isArchived ? 1 : 0,
                memory.kind.rawValue,
                memory.source.rawValue,
                memory.importance,
                memory.confidence,
                encodeEntities(memory.entities),
                memory.validFrom?.timeIntervalSince1970,
                memory.validUntil?.timeIntervalSince1970,
                memory.sourceSessionID?.uuidString,
                memory.accessCount,
                memory.lastAccessedAt?.timeIntervalSince1970
            ]
        )
    }

    private static func insertMutation(
        _ record: MemoryMutationRecord,
        in db: Database,
        encoder: JSONEncoder
    ) throws {
        let beforeData = try record.before.map { try encoder.encode($0) }
        let afterData = try record.after.map { try encoder.encode($0) }
        try db.execute(
            sql: """
                INSERT INTO memory_mutation_history (
                    id, memory_id, operation, origin, source_session_id,
                    source_message_id, source_tool_name, source_shortcut_name,
                    transfer_receipt_id, before_digest, after_digest,
                    before_snapshot_json, after_snapshot_json, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                record.id.uuidString,
                record.memoryID.uuidString,
                record.operation.rawValue,
                record.context.origin.rawValue,
                record.context.sourceSessionID?.uuidString,
                record.context.sourceMessageID?.uuidString,
                record.context.sourceToolName,
                record.context.sourceShortcutName,
                record.context.transferReceiptID?.uuidString,
                record.before?.digest,
                record.after?.digest,
                beforeData,
                afterData,
                record.createdAt.timeIntervalSince1970
            ]
        )
    }

    private static func decodeMutation(row: Row, decoder: JSONDecoder) throws -> MemoryMutationRecord {
        let beforeData: Data? = row["before_snapshot_json"]
        let afterData: Data? = row["after_snapshot_json"]
        let createdAt: Double = row["created_at"]
        let sourceSessionID: String? = row["source_session_id"]
        let sourceMessageID: String? = row["source_message_id"]
        let transferReceiptID: String? = row["transfer_receipt_id"]
        return MemoryMutationRecord(
            id: UUID(uuidString: row["id"]) ?? UUID(),
            memoryID: UUID(uuidString: row["memory_id"]) ?? UUID(),
            operation: MemoryMutationOperation(rawValue: row["operation"]) ?? .edited,
            context: MemoryMutationContext(
                origin: MemoryMutationOrigin(rawValue: row["origin"]) ?? .manual,
                sourceSessionID: sourceSessionID.flatMap(UUID.init(uuidString:)),
                sourceMessageID: sourceMessageID.flatMap(UUID.init(uuidString:)),
                sourceToolName: row["source_tool_name"],
                sourceShortcutName: row["source_shortcut_name"],
                transferReceiptID: transferReceiptID.flatMap(UUID.init(uuidString:))
            ),
            before: try beforeData.map { try decoder.decode(MemoryVersionSnapshot.self, from: $0) },
            after: try afterData.map { try decoder.decode(MemoryVersionSnapshot.self, from: $0) },
            createdAt: Date(timeIntervalSince1970: createdAt)
        )
    }

    private static func decodeTransferReceipt(row: Row) -> MemoryTransferReceipt? {
        guard let id = UUID(uuidString: row["id"]),
              let kind = MemoryTransferKind(rawValue: row["kind"]) else { return nil }
        let createdAt: Double = row["created_at"]
        return MemoryTransferReceipt(
            id: id,
            kind: kind,
            fileName: row["file_name"],
            payloadSHA256: row["payload_sha256"],
            addedCount: row["added_count"],
            updatedCount: row["updated_count"],
            conflictCount: row["conflict_count"],
            archivedCount: row["archived_count"],
            createdAt: Date(timeIntervalSince1970: createdAt)
        )
    }

    private static func restoreFile(at url: URL, data: Data?) throws {
        if let data {
            try data.write(to: url, options: .atomic)
        } else if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func loadMemoriesFromJSONFile() -> [MemoryItem]? {
        let fileURL = MemoryStoragePaths.rawMemoriesFileURL(rootDirectory: rootDirectory)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: fileURL)
            return try Self.makeDecoder().decode([MemoryItem].self, from: data)
        } catch {
            logger.error("读取 Memory JSON 失败: \(error.localizedDescription)")
            return nil
        }
    }

    private static func encodeEntities(_ entities: [String]) -> String {
        guard let data = try? JSONEncoder().encode(entities),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }

    private static func decodeEntities(_ json: String) -> [String] {
        guard let data = json.data(using: .utf8),
              let entities = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return entities
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private struct RelationalMemoryItemRecord: Codable, FetchableRecord, MutablePersistableRecord, TableRecord, Equatable {
        static let databaseTableName = "memory_items"

        enum CodingKeys: String, CodingKey {
            case id
            case content
            case embeddingData = "embedding_data"
            case createdAt = "created_at"
            case updatedAt = "updated_at"
            case isArchived = "is_archived"
            case kind
            case source
            case importance
            case confidence
            case entitiesJSON = "entities_json"
            case validFrom = "valid_from"
            case validUntil = "valid_until"
            case sourceSessionID = "source_session_id"
            case accessCount = "access_count"
            case lastAccessedAt = "last_accessed_at"
        }

        var id: String
        var content: String
        var embeddingData: Data
        var createdAt: Double
        var updatedAt: Double?
        var isArchived: Int
        var kind: String
        var source: String
        var importance: Double
        var confidence: Double
        var entitiesJSON: String
        var validFrom: Double?
        var validUntil: Double?
        var sourceSessionID: String?
        var accessCount: Int
        var lastAccessedAt: Double?
    }
}
