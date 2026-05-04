// ============================================================================
// MCPServerStoreLegacy.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件负责 MCP Server 的旧版 JSON Blob 与文件回退逻辑。
// ============================================================================

import Foundation
import os.log

extension MCPServerStore {
    static func loadLegacyRecords(usingBlobCache: Bool) -> [MCPServerStoredRecord] {
        if let records = loadLegacyRecordsFromBlob() {
            return records.sorted { $0.server.displayName.lowercased() < $1.server.displayName.lowercased() }
        }

        let fileRecords = loadRecordsFromFiles()
        guard !fileRecords.isEmpty else { return [] }

        if usingBlobCache,
           Persistence.saveAuxiliaryBlob(fileRecords, forKey: recordBlobKey) {
            removeLegacyRecordBlobs(excluding: recordBlobKey)
            cleanupLegacyFileArtifacts()
        }

        return fileRecords.sorted { $0.server.displayName.lowercased() < $1.server.displayName.lowercased() }
    }

    static func saveLegacyRecords(_ records: [MCPServerStoredRecord]) {
        let sortedRecords = records.sorted { $0.server.displayName.lowercased() < $1.server.displayName.lowercased() }
        if Persistence.saveAuxiliaryBlob(sortedRecords, forKey: recordBlobKey) {
            removeLegacyRecordBlobs(excluding: recordBlobKey)
            cleanupLegacyFileArtifacts()
            return
        }
        saveRecordsToFiles(sortedRecords)
    }

    static func loadLegacyRecordsFromBlob() -> [MCPServerStoredRecord]? {
        for key in allRecordBlobKeys {
            guard Persistence.auxiliaryBlobExists(forKey: key) else {
                continue
            }
            return Persistence.loadAuxiliaryBlob([MCPServerStoredRecord].self, forKey: key) ?? []
        }
        return nil
    }

    static func removeLegacyRecordBlobs(excluding keepKey: String? = nil) {
        for key in allRecordBlobKeys where key != keepKey {
            _ = Persistence.removeAuxiliaryBlob(forKey: key)
        }
    }

    static func configurationSignatureFromLegacyRecords() -> String {
        let signatures: [String] = loadLegacyRecords(usingBlobCache: true)
            .map { record in
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let serverData = (try? encoder.encode(record.server)) ?? Data()
                let serverJSON = String(data: serverData, encoding: .utf8) ?? "{}"
                return "\(record.server.id.uuidString)|\(serverJSON)"
            }
            .sorted()
        return signatures.joined(separator: ";")
    }

    static func loadRecordsFromFiles() -> [MCPServerStoredRecord] {
        setupDirectoryIfNeeded()
        let fm = FileManager.default
        var records: [MCPServerStoredRecord] = []
        do {
            let files = try fm.contentsOfDirectory(at: serversDirectory, includingPropertiesForKeys: nil)
            for file in files where file.pathExtension == "json" {
                guard let record = loadRecord(from: file) else { continue }
                records.append(record)
            }
        } catch {
            mcpStoreLogger.error("读取 MCPServers 目录失败: \(error.localizedDescription, privacy: .public)")
        }
        return records
    }

    static func saveRecordsToFiles(_ records: [MCPServerStoredRecord]) {
        setupDirectoryIfNeeded()
        let fm = FileManager.default

        for record in records {
            writeRecord(record, fileName: record.server.id.uuidString)
        }

        do {
            let files = try fm.contentsOfDirectory(at: serversDirectory, includingPropertiesForKeys: nil)
            let desired = Set(records.map { "\($0.server.id.uuidString).json".lowercased() })
            for file in files where file.pathExtension == "json" {
                if desired.contains(file.lastPathComponent.lowercased()) {
                    continue
                }
                try? fm.removeItem(at: file)
            }
        } catch {
            mcpStoreLogger.error("清理 MCP Server 旧配置文件失败: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func cleanupLegacyFileArtifacts() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: serversDirectory.path) else { return }
        do {
            let files = try fm.contentsOfDirectory(at: serversDirectory, includingPropertiesForKeys: nil)
            for file in files where file.pathExtension == "json" {
                try? fm.removeItem(at: file)
            }
            let remaining = try fm.contentsOfDirectory(atPath: serversDirectory.path)
            if remaining.isEmpty {
                try? fm.removeItem(at: serversDirectory)
            }
        } catch {
            mcpStoreLogger.error("清理 MCP Server 遗留 JSON 失败: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func loadRecord(from url: URL) -> MCPServerStoredRecord? {
        do {
            let data = try Data(contentsOf: url)
            let record = try JSONDecoder().decode(MCPServerStoredRecord.self, from: data)
            return record
        } catch {
            mcpStoreLogger.error("解析 MCP Server 文件失败 \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    static func writeRecord(_ record: MCPServerStoredRecord, fileName: String) {
        let url = serversDirectory.appendingPathComponent("\(fileName).json")
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(record)
            try data.write(to: url, options: [.atomicWrite, .completeFileProtection])
            mcpStoreLogger.info("已保存 MCP Server: \(record.server.displayName, privacy: .public)")
        } catch {
            mcpStoreLogger.error("保存 MCP Server 失败: \(error.localizedDescription, privacy: .public)")
        }
    }

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
