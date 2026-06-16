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
    static let relationalServerTable = "mcp_servers"
    static let relationalToolTable = "mcp_tools"
    static var didBootstrapRelationalStore = false

    public static func loadServers() -> [MCPServerConfiguration] {
        lock.withLock {
            bootstrapRelationalStoreIfNeeded()
            return loadServersFromRelationalStore() ?? []
        }
    }

    public static func loadServerHeaders() -> [MCPServerListHeader] {
        lock.withLock {
            bootstrapRelationalStoreIfNeeded()
            return loadServerHeadersFromRelationalStore() ?? []
        }
    }

    public static func save(_ server: MCPServerConfiguration) {
        lock.withLock {
            bootstrapRelationalStoreIfNeeded()
            saveServerToRelationalStore(server)
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
            saveServerOrderToRelationalStore(normalizedServers)
        }
        WatchDatabaseSyncService.markDatabaseChanged(.config)
        NotificationCenter.default.post(name: .cloudSyncLocalDataDidChange, object: nil)
    }

    public static func delete(_ server: MCPServerConfiguration) {
        lock.withLock {
            bootstrapRelationalStoreIfNeeded()
            deleteServerFromRelationalStore(serverID: server.id)
        }
        mcpStoreLogger.info("已删除 MCP Server: \(server.displayName, privacy: .public)")
        WatchDatabaseSyncService.markDatabaseChanged(.config)
        NotificationCenter.default.post(name: .cloudSyncLocalDataDidChange, object: nil)
    }

    public static func deletedBuiltInServerIDs() -> Set<UUID> {
        let rawIDs = AppConfigStore.stringArrayValue(
            for: .mcpDeletedBuiltInServerIDs,
            defaultValue: []
        ) ?? []
        return Set(rawIDs.compactMap(UUID.init(uuidString:)))
    }

    public static func markBuiltInServerDeleted(_ serverID: UUID) {
        var deletedIDs = deletedBuiltInServerIDs()
        guard deletedIDs.insert(serverID).inserted else { return }
        persistDeletedBuiltInServerIDs(deletedIDs)
    }

    public static func clearBuiltInServerDeletedMark(_ serverID: UUID) {
        var deletedIDs = deletedBuiltInServerIDs()
        guard deletedIDs.remove(serverID) != nil else { return }
        persistDeletedBuiltInServerIDs(deletedIDs)
    }

    private static func persistDeletedBuiltInServerIDs(_ serverIDs: Set<UUID>) {
        AppConfigStore.persistStringArray(
            serverIDs.map(\.uuidString).sorted(),
            for: .mcpDeletedBuiltInServerIDs
        )
    }

    public static func loadMetadata(for serverID: UUID, includeTools: Bool = true) -> MCPServerMetadataCache? {
        lock.withLock {
            bootstrapRelationalStoreIfNeeded()
            return loadMetadataFromRelationalStore(serverID: serverID, includeTools: includeTools)
        }
    }

    public static func saveMetadata(_ metadata: MCPServerMetadataCache?, for serverID: UUID) {
        lock.withLock {
            bootstrapRelationalStoreIfNeeded()
            saveMetadataToRelationalStore(metadata, for: serverID)
        }
    }

    public static func loadTools(for serverID: UUID) -> [MCPToolDescription] {
        lock.withLock {
            bootstrapRelationalStoreIfNeeded()
            return loadToolsFromRelationalStore(serverID: serverID) ?? []
        }
    }

    public static func loadServerInfo(for serverID: UUID) -> MCPServerInfo? {
        lock.withLock {
            bootstrapRelationalStoreIfNeeded()
            return loadServerInfoFromRelationalStore(serverID: serverID)
        }
    }

    public static func loadResources(for serverID: UUID) -> [MCPResourceDescription] {
        lock.withLock {
            bootstrapRelationalStoreIfNeeded()
            return loadResourcesFromRelationalStore(serverID: serverID) ?? []
        }
    }

    public static func loadResourceTemplates(for serverID: UUID) -> [MCPResourceTemplate] {
        lock.withLock {
            bootstrapRelationalStoreIfNeeded()
            return loadResourceTemplatesFromRelationalStore(serverID: serverID) ?? []
        }
    }

    public static func loadPrompts(for serverID: UUID) -> [MCPPromptDescription] {
        lock.withLock {
            bootstrapRelationalStoreIfNeeded()
            return loadPromptsFromRelationalStore(serverID: serverID) ?? []
        }
    }

    public static func loadRoots(for serverID: UUID) -> [MCPRoot] {
        lock.withLock {
            bootstrapRelationalStoreIfNeeded()
            return loadRootsFromRelationalStore(serverID: serverID) ?? []
        }
    }

    public static func loadMetadataCachedAt(for serverID: UUID) -> Date? {
        lock.withLock {
            bootstrapRelationalStoreIfNeeded()
            return loadMetadataCachedAtFromRelationalStore(serverID: serverID)
        }
    }

    public static func configurationSnapshotSignature() -> String {
        lock.withLock {
            bootstrapRelationalStoreIfNeeded()
            return configurationSignatureFromRelationalStore() ?? ""
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
