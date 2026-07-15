// ============================================================================
// MCPServerStoreLegacy.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件仅保留旧版 JSON Blob 与文件读取逻辑，供一次性迁移使用。
// 迁移完成后遗留数据自动清理，正常操作路径不再经过此处。
// ============================================================================

import Foundation
import os.log

extension MCPServerStore {
    static let recordBlobKey = "mcp_servers_records"
    static let legacyRecordBlobKey = "mcp_servers_records_v1"
    static let allRecordBlobKeys = [recordBlobKey, legacyRecordBlobKey]

    static var legacyServersDirectory: URL {
        StorageUtility.documentsDirectory
            .appendingPathComponent("MCPServers")
    }

    // MARK: - 迁移用：读取遗留数据

    static func loadLegacyRecords(usingBlobCache: Bool) -> [MCPServerStoredRecord] {
        if let records = loadLegacyRecordsFromBlob() {
            return sortedRecordsByServerOrder(records)
        }

        let fileRecords = loadRecordsFromFiles()
        guard !fileRecords.isEmpty else { return [] }

        if usingBlobCache,
           Persistence.saveAuxiliaryBlob(fileRecords, forKey: recordBlobKey) {
            removeLegacyRecordBlobs(excluding: recordBlobKey)
        }

        return sortedRecordsByServerOrder(fileRecords)
    }

    private static func loadLegacyRecordsFromBlob() -> [MCPServerStoredRecord]? {
        for key in allRecordBlobKeys {
            guard Persistence.auxiliaryBlobExists(forKey: key) else { continue }
            return Persistence.loadAuxiliaryBlob([MCPServerStoredRecord].self, forKey: key) ?? []
        }
        return nil
    }

    private static func loadRecordsFromFiles() -> [MCPServerStoredRecord] {
        let dir = legacyServersDirectory
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else { return [] }
        var records: [MCPServerStoredRecord] = []
        do {
            let files = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            for file in files where file.pathExtension == "json" {
                guard let record = loadRecord(from: file) else { continue }
                records.append(record)
            }
        } catch {
            mcpStoreLogger.error("读取 MCPServers 目录失败: \(error.localizedDescription, privacy: .public)")
        }
        return records
    }

    private static func loadRecord(from url: URL) -> MCPServerStoredRecord? {
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(MCPServerStoredRecord.self, from: data)
        } catch {
            mcpStoreLogger.error("解析 MCP Server 文件失败 \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    static func sortedRecordsByServerOrder(_ records: [MCPServerStoredRecord]) -> [MCPServerStoredRecord] {
        records.sorted { lhs, rhs in
            if lhs.server.sortIndex != rhs.server.sortIndex {
                return lhs.server.sortIndex < rhs.server.sortIndex
            }
            let lhsName = lhs.server.displayName.lowercased()
            let rhsName = rhs.server.displayName.lowercased()
            if lhsName != rhsName {
                return lhsName < rhsName
            }
            return lhs.server.id.uuidString < rhs.server.id.uuidString
        }
    }

    // MARK: - 迁移用：清理遗留数据

    static func removeLegacyRecordBlobs(excluding keepKey: String? = nil) {
        for key in allRecordBlobKeys where key != keepKey {
            _ = Persistence.removeAuxiliaryBlob(forKey: key)
        }
    }

    static func cleanupLegacyFileArtifacts() {
        let dir = legacyServersDirectory
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else { return }
        do {
            let files = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            for file in files where file.pathExtension == "json" {
                try? fm.removeItem(at: file)
            }
            let remaining = try fm.contentsOfDirectory(atPath: dir.path)
            if remaining.isEmpty {
                try? fm.removeItem(at: dir)
            }
        } catch {
            mcpStoreLogger.error("清理 MCP Server 遗留 JSON 失败: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - 遗留记录模型

    struct MCPServerStoredRecord: Codable {
        var schemaVersion: Int
        var server: MCPServerConfiguration
        var metadata: MCPServerMetadataCache?

        init(schemaVersion: Int = 3, server: MCPServerConfiguration, metadata: MCPServerMetadataCache?) {
            self.schemaVersion = schemaVersion
            self.server = server
            self.metadata = metadata
        }

        private enum CodingKeys: String, CodingKey {
            case schemaVersion
            case server
            case metadata
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if container.contains(.server) {
                schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 3
                server = try container.decode(MCPServerConfiguration.self, forKey: .server)
                metadata = try container.decodeIfPresent(MCPServerMetadataCache.self, forKey: .metadata)
            } else {
                server = try MCPServerConfiguration(from: decoder)
                schemaVersion = 1
                metadata = nil
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(schemaVersion, forKey: .schemaVersion)
            try container.encode(server, forKey: .server)
            try container.encodeIfPresent(metadata, forKey: .metadata)
        }
    }
}
