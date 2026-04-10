// ============================================================================
// MCPServerStore.swift
// ============================================================================
// 管理 MCP Server 配置的增删改查（优先 SQLite，失败时回退 JSON 文件）。
// ============================================================================

import Foundation
import os.log

private let mcpStoreLogger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "MCPServerStore")

public struct MCPServerMetadataCache: Codable, Hashable {
    public var cachedAt: Date
    public var info: MCPServerInfo?
    public var tools: [MCPToolDescription]
    public var resources: [MCPResourceDescription]
    public var resourceTemplates: [MCPResourceTemplate]
    public var prompts: [MCPPromptDescription]
    public var roots: [MCPRoot]

    public init(
        cachedAt: Date = Date(),
        info: MCPServerInfo?,
        tools: [MCPToolDescription],
        resources: [MCPResourceDescription],
        resourceTemplates: [MCPResourceTemplate],
        prompts: [MCPPromptDescription],
        roots: [MCPRoot]
    ) {
        self.cachedAt = cachedAt
        self.info = info
        self.tools = tools
        self.resources = resources
        self.resourceTemplates = resourceTemplates
        self.prompts = prompts
        self.roots = roots
    }

    private enum CodingKeys: String, CodingKey {
        case cachedAt
        case info
        case tools
        case resources
        case resourceTemplates
        case prompts
        case roots
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cachedAt = try container.decodeIfPresent(Date.self, forKey: .cachedAt) ?? Date()
        info = try container.decodeIfPresent(MCPServerInfo.self, forKey: .info)
        tools = try container.decodeIfPresent([MCPToolDescription].self, forKey: .tools) ?? []
        resources = try container.decodeIfPresent([MCPResourceDescription].self, forKey: .resources) ?? []
        resourceTemplates = try container.decodeIfPresent([MCPResourceTemplate].self, forKey: .resourceTemplates) ?? []
        prompts = try container.decodeIfPresent([MCPPromptDescription].self, forKey: .prompts) ?? []
        roots = try container.decodeIfPresent([MCPRoot].self, forKey: .roots) ?? []
    }
}

public struct MCPServerStore {
    private static let lock = NSLock()
    private static let grdbBlobKey = "mcp_servers_records_v1"
    
    private static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    
    private static var serversDirectory: URL {
        documentsDirectory.appendingPathComponent("MCPServers")
    }
    
    @discardableResult
    public static func setupDirectoryIfNeeded() -> URL {
        let fm = FileManager.default
        if !fm.fileExists(atPath: serversDirectory.path) {
            do {
                try fm.createDirectory(at: serversDirectory, withIntermediateDirectories: true)
                mcpStoreLogger.info("MCPServers 目录已创建: \(serversDirectory.path, privacy: .public)")
            } catch {
                mcpStoreLogger.error("创建 MCPServers 目录失败: \(error.localizedDescription, privacy: .public)")
            }
        }
        return serversDirectory
    }
    
    public static func loadServers() -> [MCPServerConfiguration] {
        lock.withLock {
            loadAllRecords().map(\.server)
        }
    }

    public static func save(_ server: MCPServerConfiguration) {
        lock.withLock {
            var records = loadAllRecords()
            if let index = records.firstIndex(where: { $0.server.id == server.id }) {
                let existingRecord = records[index]
                let shouldPreserveMetadata = existingRecord.server.transport == server.transport
                let metadata = shouldPreserveMetadata ? existingRecord.metadata : nil
                records[index] = MCPServerStoredRecord(server: server, metadata: metadata)
            } else {
                records.append(MCPServerStoredRecord(server: server, metadata: nil))
            }
            saveAllRecords(records)
        }
    }

    public static func delete(_ server: MCPServerConfiguration) {
        lock.withLock {
            var records = loadAllRecords()
            records.removeAll { $0.server.id == server.id }
            saveAllRecords(records)
            mcpStoreLogger.info("已删除 MCP Server: \(server.displayName, privacy: .public)")
        }
    }

    public static func loadMetadata(for serverID: UUID) -> MCPServerMetadataCache? {
        lock.withLock {
            loadAllRecords().first(where: { $0.server.id == serverID })?.metadata
        }
    }

    public static func saveMetadata(_ metadata: MCPServerMetadataCache?, for serverID: UUID) {
        lock.withLock {
            var records = loadAllRecords()
            guard let index = records.firstIndex(where: { $0.server.id == serverID }) else { return }
            records[index].metadata = metadata
            records[index].schemaVersion = 3
            saveAllRecords(records)
        }
    }

    /// 返回用于快速判断配置目录是否发生变化的签名。
    /// 签名包含：文件名 + 修改时间 + 文件大小。
    public static func configurationSnapshotSignature() -> String {
        lock.withLock {
            let signatures: [String] = loadAllRecords()
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
    }

    private static func loadAllRecords() -> [MCPServerStoredRecord] {
        if Persistence.auxiliaryBlobExists(forKey: grdbBlobKey) {
            let records = Persistence.loadAuxiliaryBlob([MCPServerStoredRecord].self, forKey: grdbBlobKey) ?? []
            return records.sorted { $0.server.displayName.lowercased() < $1.server.displayName.lowercased() }
        }

        let fileRecords = loadRecordsFromFiles()
        guard !fileRecords.isEmpty else { return [] }

        if Persistence.saveAuxiliaryBlob(fileRecords, forKey: grdbBlobKey) {
            cleanupLegacyFileArtifacts()
        }
        return fileRecords.sorted { $0.server.displayName.lowercased() < $1.server.displayName.lowercased() }
    }

    private static func saveAllRecords(_ records: [MCPServerStoredRecord]) {
        let sortedRecords = records.sorted { $0.server.displayName.lowercased() < $1.server.displayName.lowercased() }
        if Persistence.saveAuxiliaryBlob(sortedRecords, forKey: grdbBlobKey) {
            cleanupLegacyFileArtifacts()
            return
        }
        saveRecordsToFiles(sortedRecords)
    }

    private static func loadRecordsFromFiles() -> [MCPServerStoredRecord] {
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

    private static func saveRecordsToFiles(_ records: [MCPServerStoredRecord]) {
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

    private static func cleanupLegacyFileArtifacts() {
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

    private struct MCPServerStoredRecord: Codable {
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

    private static func loadRecord(for serverID: UUID) -> MCPServerStoredRecord? {
        let url = serversDirectory.appendingPathComponent("\(serverID.uuidString).json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return loadRecord(from: url)
    }

    private static func loadRecord(from url: URL) -> MCPServerStoredRecord? {
        do {
            let data = try Data(contentsOf: url)
            let record = try JSONDecoder().decode(MCPServerStoredRecord.self, from: data)
            return record
        } catch {
            mcpStoreLogger.error("解析 MCP Server 文件失败 \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static func writeRecord(_ record: MCPServerStoredRecord, fileName: String) {
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
}

private extension NSLock {
    func withLock<T>(_ block: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try block()
    }
}
