// ============================================================================
// SQLiteVectorStore.swift
// ============================================================================
// ETOS LLM Studio
//
// VectorStoreProtocol 的 SQLite 实现。
// 负责将向量索引持久化到 Memory 目录下的单个 SQLite 数据库中，
// 以便未来扩展批量更新、分块检索等功能。
// ============================================================================

import Foundation
import SQLite3
import os.log

public final class SQLiteVectorStore: VectorStoreProtocol {
    private let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "SQLiteVectorStore")
    private let tableName = "memory_chunks"
    
    public init() {}
    
    public func saveIndex(items: [IndexItem], to url: URL, as name: String) throws -> URL {
        let databaseURL = url.appendingPathComponent("\(name).sqlite", isDirectory: false)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        
        var db: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &db) == SQLITE_OK else {
            throw SQLiteError.openDatabase(databaseURL.path)
        }
        defer { sqlite3_close(db) }
        
        try createTableIfNeeded(in: db)
        try beginExclusiveTransaction(in: db)
        try clearExistingRows(in: db)
        try insert(items, into: db)
        try commitTransaction(in: db)
        
        return databaseURL
    }
    
    public func loadIndex(from url: URL) throws -> [IndexItem] {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            throw SQLiteError.openDatabase(url.path)
        }
        defer { sqlite3_close(db) }
        
        return try fetchItems(from: db)
    }
    
    public func listIndexes(at url: URL) -> [URL] {
        do {
            let files = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            return files.filter { $0.pathExtension == "sqlite" }
        } catch {
            logger.error("列出 SQLite 索引失败: \(error.localizedDescription)")
            return []
        }
    }
}

// MARK: - SQLite Helpers

private extension SQLiteVectorStore {
    enum SQLiteError: Error {
        case openDatabase(String)
        case prepareStatement(String)
        case executionFailed(String)
    }
    
    func createTableIfNeeded(in db: OpaquePointer?) throws {
        let createSQL = """
        CREATE TABLE IF NOT EXISTS \(tableName) (
            chunk_id TEXT PRIMARY KEY,
            parent_memory_id TEXT NOT NULL,
            text TEXT NOT NULL,
            embedding BLOB NOT NULL,
            metadata TEXT NOT NULL
        );
        """
        try execute(sql: createSQL, in: db)
        
        let indexSQL = "CREATE INDEX IF NOT EXISTS idx_parent_memory ON \(tableName)(parent_memory_id);"
        try execute(sql: indexSQL, in: db)
    }
    
    func beginExclusiveTransaction(in db: OpaquePointer?) throws {
        try execute(sql: "BEGIN EXCLUSIVE TRANSACTION;", in: db)
    }
    
    func commitTransaction(in db: OpaquePointer?) throws {
        try execute(sql: "COMMIT TRANSACTION;", in: db)
    }
    
    func clearExistingRows(in db: OpaquePointer?) throws {
        try execute(sql: "DELETE FROM \(tableName);", in: db)
    }
    
    func insert(_ items: [IndexItem], into db: OpaquePointer?) throws {
        let insertSQL = """
        INSERT INTO \(tableName) (chunk_id, parent_memory_id, text, embedding, metadata)
        VALUES (?, ?, ?, ?, ?);
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, insertSQL, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteError.prepareStatement("无法准备 INSERT 语句")
        }
        defer { sqlite3_finalize(statement) }
        
        for item in items {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            
            let parentID = item.metadata["parentMemoryId"] ?? item.id
            let metadataJSON = try JSONSerialization.data(withJSONObject: item.metadata, options: [])
            let embeddingData = data(from: item.embedding)
            
            sqlite3_bind_text(statement, 1, (item.id as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 2, (parentID as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 3, (item.text as NSString).utf8String, -1, SQLITE_TRANSIENT)
            _ = embeddingData.withUnsafeBytes { buffer in
                sqlite3_bind_blob(statement, 4, buffer.baseAddress, Int32(buffer.count), SQLITE_TRANSIENT)
            }
            _ = metadataJSON.withUnsafeBytes { buffer in
                sqlite3_bind_blob(statement, 5, buffer.baseAddress, Int32(buffer.count), SQLITE_TRANSIENT)
            }
            
            if sqlite3_step(statement) != SQLITE_DONE {
                throw SQLiteError.executionFailed("插入向量失败: \(sqlite3_errmsg(db).flatMap { String(cString: $0) } ?? "")")
            }
        }
    }
    
    func fetchItems(from db: OpaquePointer?) throws -> [IndexItem] {
        let querySQL = "SELECT chunk_id, text, embedding, metadata FROM \(tableName);"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, querySQL, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteError.prepareStatement("无法准备 SELECT 语句")
        }
        defer { sqlite3_finalize(statement) }
        
        var results: [IndexItem] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let chunkCString = sqlite3_column_text(statement, 0),
                let textCString = sqlite3_column_text(statement, 1)
            else { continue }
            
            let chunkID = String(cString: chunkCString)
            let text = String(cString: textCString)
            
            let embedding = arrayOfFloat(fromColumn: 2, statement: statement)
            let metadata = dictionary(fromColumn: 3, statement: statement) ?? [:]
            
            let item = IndexItem(id: chunkID, text: text, embedding: embedding, metadata: metadata)
            results.append(item)
        }
        return results
    }
    
    func execute(sql: String, in db: OpaquePointer?) throws {
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            let message = sqlite3_errmsg(db).flatMap { String(cString: $0) } ?? "未知错误"
            throw SQLiteError.executionFailed(message)
        }
    }
}

// MARK: - 数据转换

private extension SQLiteVectorStore {
    func data(from floats: [Float]) -> Data {
        floats.withUnsafeBufferPointer { buffer in
            Data(buffer: buffer)
        }
    }
    
    func arrayOfFloat(fromColumn index: Int32, statement: OpaquePointer?) -> [Float] {
        guard let blobPointer = sqlite3_column_blob(statement, index) else {
            return []
        }
        let blobLength = Int(sqlite3_column_bytes(statement, index))
        let count = blobLength / MemoryLayout<Float>.size
        let pointer = blobPointer.bindMemory(to: Float.self, capacity: count)
        return Array(UnsafeBufferPointer(start: pointer, count: count))
    }
    
    func dictionary(fromColumn index: Int32, statement: OpaquePointer?) -> [String: String]? {
        guard let blobPointer = sqlite3_column_blob(statement, index) else {
            return nil
        }
        let blobLength = Int(sqlite3_column_bytes(statement, index))
        let data = Data(bytes: blobPointer, count: blobLength)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: String]
    }
}

// MARK: - SQLite helpers bridging

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
