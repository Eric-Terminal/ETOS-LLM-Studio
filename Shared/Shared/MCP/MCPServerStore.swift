// ============================================================================
// MCPServerStore.swift
// ============================================================================
// 管理 MCP Server 配置文件的增删改查。
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
        setupDirectoryIfNeeded()
        let fm = FileManager.default
        var result: [MCPServerConfiguration] = []
        do {
            let files = try fm.contentsOfDirectory(at: serversDirectory, includingPropertiesForKeys: nil)
            for file in files where file.pathExtension == "json" {
                guard let record = loadRecord(from: file) else { continue }
                result.append(record.server)
            }
        } catch {
            mcpStoreLogger.error("读取 MCPServers 目录失败: \(error.localizedDescription, privacy: .public)")
        }
        return result.sorted { $0.displayName.lowercased() < $1.displayName.lowercased() }
    }

    public static func save(_ server: MCPServerConfiguration) {
        setupDirectoryIfNeeded()
        let existingRecord = loadRecord(for: server.id)
        let shouldPreserveMetadata = existingRecord?.server.transport == server.transport
        let metadata = shouldPreserveMetadata ? existingRecord?.metadata : nil
        let record = MCPServerStoredRecord(server: server, metadata: metadata)
        writeRecord(record, fileName: server.id.uuidString)
    }

    public static func delete(_ server: MCPServerConfiguration) {
        let fm = FileManager.default
        let url = serversDirectory.appendingPathComponent("\(server.id.uuidString).json")
        do {
            try fm.removeItem(at: url)
            mcpStoreLogger.info("已删除 MCP Server: \(server.displayName, privacy: .public)")
        } catch {
            mcpStoreLogger.error("删除 MCP Server 失败: \(error.localizedDescription, privacy: .public)")
        }
    }

    public static func loadMetadata(for serverID: UUID) -> MCPServerMetadataCache? {
        setupDirectoryIfNeeded()
        return loadRecord(for: serverID)?.metadata
    }

    public static func saveMetadata(_ metadata: MCPServerMetadataCache?, for serverID: UUID) {
        setupDirectoryIfNeeded()
        guard var record = loadRecord(for: serverID) else { return }
        record.metadata = metadata
        record.schemaVersion = 3
        writeRecord(record, fileName: serverID.uuidString)
    }

    /// 返回用于快速判断配置目录是否发生变化的签名。
    /// 签名包含：文件名 + 修改时间 + 文件大小。
    public static func configurationSnapshotSignature() -> String {
        setupDirectoryIfNeeded()
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: serversDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return "mcp_servers_signature_unavailable"
        }

        let signatures: [String] = files
            .filter { $0.pathExtension == "json" }
            .map { fileURL in
                guard let record = loadRecord(from: fileURL) else {
                    return "\(fileURL.lastPathComponent)|decode_error"
                }
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let serverData = (try? encoder.encode(record.server)) ?? Data()
                let serverJSON = String(data: serverData, encoding: .utf8) ?? "{}"
                return "\(record.server.id.uuidString)|\(serverJSON)"
            }
            .sorted()
        return signatures.joined(separator: ";")
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
