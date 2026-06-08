// ============================================================================
// MCPServerStore.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件负责 MCP Server 配置的对外入口与公共数据结构。
// ============================================================================

import Foundation
import GRDB
import os.log

let mcpStoreLogger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "MCPServerStore")

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

public struct MCPServerListHeader: Codable, Hashable, Identifiable {
    public var id: UUID
    public var displayName: String
    public var notes: String?
    public var isSelectedForChat: Bool
    public var status: String
    public var transportKind: String
    public var endpointURL: String?
    public var messageEndpointURL: String?
    public var sseEndpointURL: String?
    public var updatedAt: Date

    public init(
        id: UUID,
        displayName: String,
        notes: String?,
        isSelectedForChat: Bool,
        status: String,
        transportKind: String,
        endpointURL: String?,
        messageEndpointURL: String?,
        sseEndpointURL: String?,
        updatedAt: Date
    ) {
        self.id = id
        self.displayName = displayName
        self.notes = notes
        self.isSelectedForChat = isSelectedForChat
        self.status = status
        self.transportKind = transportKind
        self.endpointURL = endpointURL
        self.messageEndpointURL = messageEndpointURL
        self.sseEndpointURL = sseEndpointURL
        self.updatedAt = updatedAt
    }
}

public struct MCPServerStore {
    static let lock = NSLock()
    static let recordBlobKey = "mcp_servers_records"
    static let legacyRecordBlobKey = "mcp_servers_records_v1"
    static let allRecordBlobKeys = [recordBlobKey, legacyRecordBlobKey]
    static let relationalServerTable = "mcp_servers"
    static let relationalToolTable = "mcp_tools"
    static var didBootstrapRelationalStore = false

    static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var serversDirectory: URL {
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
            bootstrapRelationalStoreIfNeeded()
            if let servers = loadServersFromRelationalStore() {
                return servers
            }
            return loadLegacyRecords(usingBlobCache: true).map(\.server)
        }
    }

    public static func loadServerHeaders() -> [MCPServerListHeader] {
        lock.withLock {
            bootstrapRelationalStoreIfNeeded()
            if let headers = loadServerHeadersFromRelationalStore() {
                return headers
            }
            return loadLegacyRecords(usingBlobCache: true)
                .map { record in
                    MCPServerListHeader(
                        id: record.server.id,
                        displayName: record.server.displayName,
                        notes: record.server.notes,
                        isSelectedForChat: record.server.isSelectedForChat,
                        status: record.metadata == nil ? MCPServerHeaderRecord.Status.idle.rawValue : MCPServerHeaderRecord.Status.ready.rawValue,
                        transportKind: transportKind(of: record.server.transport),
                        endpointURL: transportEndpoint(of: record.server.transport),
                        messageEndpointURL: transportMessageEndpoint(of: record.server.transport),
                        sseEndpointURL: transportSSEEndpoint(of: record.server.transport),
                        updatedAt: Date()
                    )
                }
        }
    }

    public static func save(_ server: MCPServerConfiguration) {
        lock.withLock {
            bootstrapRelationalStoreIfNeeded()
            if saveServerToRelationalStore(server) {
                cleanupLegacyArtifactsAfterRelationalSave()
                return
            }

            var records = loadLegacyRecords(usingBlobCache: true)
            if let index = records.firstIndex(where: { $0.server.id == server.id }) {
                let existingRecord = records[index]
                let shouldPreserveMetadata = existingRecord.server.transport == server.transport
                let metadata = shouldPreserveMetadata ? existingRecord.metadata : nil
                records[index] = MCPServerStoredRecord(server: server, metadata: metadata)
            } else {
                records.append(MCPServerStoredRecord(server: server, metadata: nil))
            }
            saveLegacyRecords(records)
        }
        WatchDatabaseSyncService.markDatabaseChanged(.config)
        NotificationCenter.default.post(name: .cloudSyncLocalDataDidChange, object: nil)
    }

    public static func saveOrder(_ orderedServers: [MCPServerConfiguration]) {
        guard !orderedServers.isEmpty else { return }
        let normalizedServers = orderedServers.enumerated().map { pair -> MCPServerConfiguration in
            var server = pair.element
            server.sortIndex = pair.offset
            return server
        }

        lock.withLock {
            bootstrapRelationalStoreIfNeeded()
            if saveServerOrderToRelationalStore(normalizedServers) {
                cleanupLegacyArtifactsAfterRelationalSave()
                return
            }

            let records = loadLegacyRecords(usingBlobCache: true)
            var recordsByID: [UUID: MCPServerStoredRecord] = [:]
            for record in records {
                recordsByID[record.server.id] = record
            }

            let orderedIDs = Set(normalizedServers.map(\.id))
            let orderedRecords = normalizedServers.map { server -> MCPServerStoredRecord in
                var record = recordsByID[server.id] ?? MCPServerStoredRecord(server: server, metadata: nil)
                record.server = server
                return record
            }
            let remainingRecords = records.filter { !orderedIDs.contains($0.server.id) }
            saveLegacyRecords(orderedRecords + remainingRecords)
        }
        WatchDatabaseSyncService.markDatabaseChanged(.config)
        NotificationCenter.default.post(name: .cloudSyncLocalDataDidChange, object: nil)
    }

    public static func delete(_ server: MCPServerConfiguration) {
        guard !MCPBuiltInAppToolServer.isBuiltInServer(server) else {
            mcpStoreLogger.info("跳过删除内置 MCP Server: \(server.displayName, privacy: .public)")
            return
        }
        lock.withLock {
            bootstrapRelationalStoreIfNeeded()
            if deleteServerFromRelationalStore(serverID: server.id) {
                mcpStoreLogger.info("已删除 MCP Server: \(server.displayName, privacy: .public)")
                cleanupLegacyArtifactsAfterRelationalSave()
                return
            }

            var records = loadLegacyRecords(usingBlobCache: true)
            records.removeAll { $0.server.id == server.id }
            saveLegacyRecords(records)
            mcpStoreLogger.info("已删除 MCP Server: \(server.displayName, privacy: .public)")
        }
        WatchDatabaseSyncService.markDatabaseChanged(.config)
        NotificationCenter.default.post(name: .cloudSyncLocalDataDidChange, object: nil)
    }

    public static func loadMetadata(for serverID: UUID, includeTools: Bool = true) -> MCPServerMetadataCache? {
        lock.withLock {
            bootstrapRelationalStoreIfNeeded()
            if let metadata = loadMetadataFromRelationalStore(serverID: serverID, includeTools: includeTools) {
                return metadata
            }
            var metadata = loadLegacyRecords(usingBlobCache: true)
                .first(where: { $0.server.id == serverID })?
                .metadata
            if includeTools == false {
                metadata?.tools = []
            }
            return metadata
        }
    }

    public static func saveMetadata(_ metadata: MCPServerMetadataCache?, for serverID: UUID) {
        lock.withLock {
            bootstrapRelationalStoreIfNeeded()
            if saveMetadataToRelationalStore(metadata, for: serverID) {
                cleanupLegacyArtifactsAfterRelationalSave()
                return
            }

            var records = loadLegacyRecords(usingBlobCache: true)
            guard let index = records.firstIndex(where: { $0.server.id == serverID }) else { return }
            records[index].metadata = metadata
            records[index].schemaVersion = 3
            saveLegacyRecords(records)
        }
    }

    public static func loadTools(for serverID: UUID) -> [MCPToolDescription] {
        lock.withLock {
            bootstrapRelationalStoreIfNeeded()
            if let tools = loadToolsFromRelationalStore(serverID: serverID) {
                return tools
            }
            return loadLegacyRecords(usingBlobCache: true)
                .first(where: { $0.server.id == serverID })?
                .metadata?
                .tools ?? []
        }
    }

    public static func loadServerInfo(for serverID: UUID) -> MCPServerInfo? {
        lock.withLock {
            bootstrapRelationalStoreIfNeeded()
            if let info = loadServerInfoFromRelationalStore(serverID: serverID) {
                return info
            }
            return loadLegacyRecords(usingBlobCache: true)
                .first(where: { $0.server.id == serverID })?
                .metadata?
                .info
        }
    }

    public static func loadResources(for serverID: UUID) -> [MCPResourceDescription] {
        lock.withLock {
            bootstrapRelationalStoreIfNeeded()
            if let resources = loadResourcesFromRelationalStore(serverID: serverID) {
                return resources
            }
            return loadLegacyRecords(usingBlobCache: true)
                .first(where: { $0.server.id == serverID })?
                .metadata?
                .resources ?? []
        }
    }

    public static func loadResourceTemplates(for serverID: UUID) -> [MCPResourceTemplate] {
        lock.withLock {
            bootstrapRelationalStoreIfNeeded()
            if let resourceTemplates = loadResourceTemplatesFromRelationalStore(serverID: serverID) {
                return resourceTemplates
            }
            return loadLegacyRecords(usingBlobCache: true)
                .first(where: { $0.server.id == serverID })?
                .metadata?
                .resourceTemplates ?? []
        }
    }

    public static func loadPrompts(for serverID: UUID) -> [MCPPromptDescription] {
        lock.withLock {
            bootstrapRelationalStoreIfNeeded()
            if let prompts = loadPromptsFromRelationalStore(serverID: serverID) {
                return prompts
            }
            return loadLegacyRecords(usingBlobCache: true)
                .first(where: { $0.server.id == serverID })?
                .metadata?
                .prompts ?? []
        }
    }

    public static func loadRoots(for serverID: UUID) -> [MCPRoot] {
        lock.withLock {
            bootstrapRelationalStoreIfNeeded()
            if let roots = loadRootsFromRelationalStore(serverID: serverID) {
                return roots
            }
            return loadLegacyRecords(usingBlobCache: true)
                .first(where: { $0.server.id == serverID })?
                .metadata?
                .roots ?? []
        }
    }

    public static func loadMetadataCachedAt(for serverID: UUID) -> Date? {
        lock.withLock {
            bootstrapRelationalStoreIfNeeded()
            if let cachedAt = loadMetadataCachedAtFromRelationalStore(serverID: serverID) {
                return cachedAt
            }
            return loadLegacyRecords(usingBlobCache: true)
                .first(where: { $0.server.id == serverID })?
                .metadata?
                .cachedAt
        }
    }

    public static func configurationSnapshotSignature() -> String {
        lock.withLock {
            bootstrapRelationalStoreIfNeeded()
            if let relationalSignature = configurationSignatureFromRelationalStore() {
                return relationalSignature
            }
            return configurationSignatureFromLegacyRecords()
        }
    }

    public static func observeConfigurationSignature(
        onError: @escaping @Sendable (Error) -> Void,
        onChange: @escaping @Sendable (String) -> Void
    ) -> AnyDatabaseCancellable? {
        lock.withLock {
            bootstrapRelationalStoreIfNeeded()
        }

        final class SignatureStateBox: @unchecked Sendable {
            let lock = NSLock()
            var lastSignature: String?
        }
        let signatureState = SignatureStateBox()

        let observation = ValueObservation
            .tracking { db in
                try configurationSignatureFromRelationalDatabase(db)
            }

        return Persistence.observeConfigDatabase(
            observation,
            onError: onError,
            onChange: { signature in
                var shouldForward = false
                signatureState.lock.withLock {
                    if signatureState.lastSignature != signature {
                        signatureState.lastSignature = signature
                        shouldForward = true
                    }
                }
                if shouldForward {
                    onChange(signature)
                }
            }
        )
    }
}
