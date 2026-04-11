// ============================================================================
// MCPServerStore.swift
// ============================================================================
// 管理 MCP Server 配置的增删改查（优先关系化 SQLite，失败时回退 JSON 文件）。
// ============================================================================

import Foundation
import GRDB
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
    private static let lock = NSLock()
    private static let legacyBlobKey = "mcp_servers_records_v1"
    private static let relationalServerTable = "mcp_servers_v2"
    private static let relationalToolTable = "mcp_tools_v2"
    private static var didBootstrapRelationalStore = false

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
                .sorted {
                    let lhsName = $0.displayName.lowercased()
                    let rhsName = $1.displayName.lowercased()
                    if lhsName == rhsName {
                        return $0.id.uuidString < $1.id.uuidString
                    }
                    return lhsName < rhsName
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
    }

    public static func delete(_ server: MCPServerConfiguration) {
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

    /// 仅按需加载某个服务的工具列表，避免解码整份 Server 元数据。
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

    /// 按需读取 Server info，避免解码整份元数据。
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

    /// 按需读取资源列表，避免解码整份元数据。
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

    /// 按需读取资源模板列表，避免解码整份元数据。
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

    /// 按需读取提示词列表，避免解码整份元数据。
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

    /// 按需读取 roots 列表，避免解码整份元数据。
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

    /// 按需读取元数据缓存时间，仅用于刷新策略判断。
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

    /// 返回用于快速判断配置是否变化的签名。
    /// 仅抓取 mcp_servers 轻量列，避免深层 JSON 反序列化带来的 CPU 抖动。
    public static func configurationSnapshotSignature() -> String {
        lock.withLock {
            bootstrapRelationalStoreIfNeeded()
            if let relationalSignature = configurationSignatureFromRelationalStore() {
                return relationalSignature
            }
            return configurationSignatureFromLegacyRecords()
        }
    }

    /// 基于 GRDB ValueObservation 监听配置变化（仅在真实写入时触发）。
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

    // MARK: - 关系化存储

    private static func bootstrapRelationalStoreIfNeeded() {
        guard !didBootstrapRelationalStore else { return }
        guard Persistence.withConfigDatabaseRead({ _ in true }) == true else { return }

        migrateLegacyRecordsToRelationalStoreIfNeeded()
        didBootstrapRelationalStore = true
    }

    private static func migrateLegacyRecordsToRelationalStoreIfNeeded() {
        guard let existingServerCount = Persistence.withConfigDatabaseRead({ db in
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(relationalServerTable)")
            return count ?? 0
        }) else {
            return
        }

        guard existingServerCount == 0 else { return }

        let legacyRecords = loadLegacyRecords(usingBlobCache: false)
        guard !legacyRecords.isEmpty else { return }

        let migrateSucceeded = Persistence.withConfigDatabaseWrite { db in
            for legacyRecord in legacyRecords {
                let status: MCPServerHeaderRecord.Status = legacyRecord.metadata == nil ? .idle : .ready
                try upsertServerRow(
                    db,
                    server: legacyRecord.server,
                    status: status,
                    metadata: legacyRecord.metadata,
                    updatedAt: Date().timeIntervalSince1970
                )

                if let metadata = legacyRecord.metadata {
                    let toolsTimestamp = metadata.cachedAt.timeIntervalSince1970
                    try replaceTools(
                        db,
                        serverID: legacyRecord.server.id.uuidString,
                        tools: metadata.tools,
                        updatedAt: toolsTimestamp
                    )
                } else {
                    try deleteTools(db, serverID: legacyRecord.server.id.uuidString)
                }
            }
            return true
        } ?? false

        guard migrateSucceeded else {
            mcpStoreLogger.error("MCP 关系化迁移失败：未能写入 mcp_servers_v2/mcp_tools_v2。")
            return
        }

        _ = Persistence.removeAuxiliaryBlob(forKey: legacyBlobKey)
        cleanupLegacyFileArtifacts()
        mcpStoreLogger.info("MCP 配置已自动迁移到关系化表：servers=\(legacyRecords.count)")
    }

    private static func loadServersFromRelationalStore() -> [MCPServerConfiguration]? {
        Persistence.withConfigDatabaseRead { db in
            let headers = try MCPServerHeaderRecord.fetchAll(
                db,
                sql: """
                SELECT
                    id, display_name, notes, is_selected_for_chat,
                    status, transport_kind, endpoint_url, message_endpoint_url, sse_endpoint_url,
                    metadata_cached_at, updated_at
                FROM \(relationalServerTable)
                ORDER BY LOWER(display_name) ASC, id ASC
                """
            )
            let payloadRows = try MCPServerPayloadRecord.fetchAll(
                db,
                sql: """
                SELECT
                    id, api_key, additional_headers_json, disabled_tool_ids_json,
                    tool_approval_policies_json, oauth_payload_json, stream_resumption_token,
                    info_json, resources_json, resource_templates_json, prompts_json, roots_json
                FROM \(relationalServerTable)
                """
            )
            let payloadByID = Dictionary(uniqueKeysWithValues: payloadRows.map { ($0.id, $0) })

            return headers.compactMap { header -> MCPServerConfiguration? in
                guard let server = decodeServerConfiguration(from: header, payload: payloadByID[header.id]) else {
                    let id = header.id
                    mcpStoreLogger.error("读取 MCP 服务器失败：配置数据损坏 id=\(id, privacy: .public)")
                    return nil
                }
                return server
            }
        }
    }

    private static func loadServerHeadersFromRelationalStore() -> [MCPServerListHeader]? {
        Persistence.withConfigDatabaseRead { db in
            let headers = try MCPServerHeaderRecord.fetchAll(
                db,
                sql: """
                SELECT
                    id, display_name, notes, is_selected_for_chat,
                    status, transport_kind, endpoint_url, message_endpoint_url, sse_endpoint_url,
                    metadata_cached_at, updated_at
                FROM \(relationalServerTable)
                ORDER BY LOWER(display_name) ASC, id ASC
                """
            )

            return headers.compactMap { header in
                guard let id = UUID(uuidString: header.id) else { return nil }
                return MCPServerListHeader(
                    id: id,
                    displayName: header.displayName,
                    notes: header.notes,
                    isSelectedForChat: header.isSelectedForChat != 0,
                    status: header.status,
                    transportKind: header.transportKind,
                    endpointURL: header.endpointURL,
                    messageEndpointURL: header.messageEndpointURL,
                    sseEndpointURL: header.sseEndpointURL,
                    updatedAt: Date(timeIntervalSince1970: header.updatedAt)
                )
            }
        }
    }

    private static func saveServerToRelationalStore(_ server: MCPServerConfiguration) -> Bool {
        let serverID = server.id.uuidString
        let didSave = Persistence.withConfigDatabaseWrite { db in
            let existingServerRow = try Row.fetchOne(
                db,
                sql: """
                SELECT
                    id, display_name, notes, is_selected_for_chat,
                    transport_kind, endpoint_url, message_endpoint_url, sse_endpoint_url,
                    api_key, additional_headers_json, oauth_payload_json,
                    disabled_tool_ids_json, tool_approval_policies_json, stream_resumption_token,
                    status, metadata_cached_at,
                    info_json, resources_json, resource_templates_json, prompts_json, roots_json,
                    updated_at
                FROM \(relationalServerTable)
                WHERE id = ?
                """,
                arguments: [serverID]
            )

            let shouldPreserveMetadata: Bool
            if let existingServerRow,
               let previousServer = decodeServerConfiguration(from: existingServerRow) {
                shouldPreserveMetadata = previousServer.transport == server.transport
            } else {
                shouldPreserveMetadata = false
            }

            let status: MCPServerHeaderRecord.Status
            let metadata: MCPServerMetadataCache?
            if shouldPreserveMetadata,
               let existingServerRow {
                status = MCPServerHeaderRecord.Status(rawValue: (existingServerRow["status"] as String?) ?? MCPServerHeaderRecord.Status.idle.rawValue) ?? .idle
                metadata = decodeMetadataPayload(from: existingServerRow, includeTools: true, tools: try fetchTools(db, serverID: serverID))
            } else {
                status = .idle
                metadata = nil
                try deleteTools(db, serverID: serverID)
            }

            try upsertServerRow(
                db,
                server: server,
                status: status,
                metadata: metadata,
                updatedAt: Date().timeIntervalSince1970
            )
            return true
        } ?? false

        return didSave
    }

    private static func deleteServerFromRelationalStore(serverID: UUID) -> Bool {
        Persistence.withConfigDatabaseWrite { db in
            try db.execute(
                sql: "DELETE FROM \(relationalServerTable) WHERE id = ?",
                arguments: [serverID.uuidString]
            )
            return true
        } ?? false
    }

    private static func loadMetadataFromRelationalStore(serverID: UUID, includeTools: Bool) -> MCPServerMetadataCache? {
        Persistence.withConfigDatabaseRead { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT
                    id, metadata_cached_at, updated_at,
                    info_json, resources_json, resource_templates_json, prompts_json, roots_json
                FROM \(relationalServerTable)
                WHERE id = ?
                """,
                arguments: [serverID.uuidString]
            ) else {
                return nil
            }

            let tools: [MCPToolDescription]
            if includeTools {
                tools = try fetchTools(db, serverID: serverID.uuidString)
            } else {
                tools = []
            }

            return decodeMetadataPayload(from: row, includeTools: includeTools, tools: tools)
        } ?? nil
    }

    private static func loadToolsFromRelationalStore(serverID: UUID) -> [MCPToolDescription]? {
        Persistence.withConfigDatabaseRead { db in
            try fetchTools(db, serverID: serverID.uuidString)
        }
    }

    private static func loadServerInfoFromRelationalStore(serverID: UUID) -> MCPServerInfo? {
        Persistence.withConfigDatabaseRead { db in
            let infoText = try String.fetchOne(
                db,
                sql: """
                SELECT info_json
                FROM \(relationalServerTable)
                WHERE id = ?
                """,
                arguments: [serverID.uuidString]
            )
            return MCPServerStoreCodec.decodeJSONTextIfPresent(MCPServerInfo.self, from: infoText)
        } ?? nil
    }

    private static func loadResourcesFromRelationalStore(serverID: UUID) -> [MCPResourceDescription]? {
        Persistence.withConfigDatabaseRead { db in
            let resourcesText = try String.fetchOne(
                db,
                sql: """
                SELECT resources_json
                FROM \(relationalServerTable)
                WHERE id = ?
                """,
                arguments: [serverID.uuidString]
            )
            return MCPServerStoreCodec.decodeJSONTextIfPresent([MCPResourceDescription].self, from: resourcesText) ?? []
        }
    }

    private static func loadResourceTemplatesFromRelationalStore(serverID: UUID) -> [MCPResourceTemplate]? {
        Persistence.withConfigDatabaseRead { db in
            let resourceTemplatesText = try String.fetchOne(
                db,
                sql: """
                SELECT resource_templates_json
                FROM \(relationalServerTable)
                WHERE id = ?
                """,
                arguments: [serverID.uuidString]
            )
            return MCPServerStoreCodec.decodeJSONTextIfPresent([MCPResourceTemplate].self, from: resourceTemplatesText) ?? []
        }
    }

    private static func loadPromptsFromRelationalStore(serverID: UUID) -> [MCPPromptDescription]? {
        Persistence.withConfigDatabaseRead { db in
            let promptsText = try String.fetchOne(
                db,
                sql: """
                SELECT prompts_json
                FROM \(relationalServerTable)
                WHERE id = ?
                """,
                arguments: [serverID.uuidString]
            )
            return MCPServerStoreCodec.decodeJSONTextIfPresent([MCPPromptDescription].self, from: promptsText) ?? []
        }
    }

    private static func loadRootsFromRelationalStore(serverID: UUID) -> [MCPRoot]? {
        Persistence.withConfigDatabaseRead { db in
            let rootsText = try String.fetchOne(
                db,
                sql: """
                SELECT roots_json
                FROM \(relationalServerTable)
                WHERE id = ?
                """,
                arguments: [serverID.uuidString]
            )
            return MCPServerStoreCodec.decodeJSONTextIfPresent([MCPRoot].self, from: rootsText) ?? []
        }
    }

    private static func loadMetadataCachedAtFromRelationalStore(serverID: UUID) -> Date? {
        Persistence.withConfigDatabaseRead { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT
                    metadata_cached_at,
                    updated_at,
                    info_json,
                    resources_json,
                    resource_templates_json,
                    prompts_json,
                    roots_json,
                    (SELECT COUNT(*) FROM \(relationalToolTable) t WHERE t.server_id = \(relationalServerTable).id) AS tools_count
                FROM \(relationalServerTable)
                WHERE id = ?
                """,
                arguments: [serverID.uuidString]
            ) else {
                return nil
            }

            if let cachedAt: Double = row["metadata_cached_at"] {
                return Date(timeIntervalSince1970: cachedAt)
            }

            let hasInfoData: String? = row["info_json"]
            let hasResourcesData: String? = row["resources_json"]
            let hasResourceTemplatesData: String? = row["resource_templates_json"]
            let hasPromptsData: String? = row["prompts_json"]
            let hasRootsData: String? = row["roots_json"]
            let toolCount: Int = row["tools_count"]
            let hasMetadata = toolCount > 0 ||
                hasInfoData != nil ||
                hasResourcesData != nil ||
                hasResourceTemplatesData != nil ||
                hasPromptsData != nil ||
                hasRootsData != nil
            guard hasMetadata else { return nil }

            let updatedAt: Double = row["updated_at"]
            return Date(timeIntervalSince1970: updatedAt)
        } ?? nil
    }

    private static func saveMetadataToRelationalStore(_ metadata: MCPServerMetadataCache?, for serverID: UUID) -> Bool {
        Persistence.withConfigDatabaseWrite { db in
            let exists = (try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM \(relationalServerTable) WHERE id = ?",
                arguments: [serverID.uuidString]
            ) ?? 0) > 0
            guard exists else {
                return true
            }

            try deleteTools(db, serverID: serverID.uuidString)

            if let metadata {
                let updatedAt = metadata.cachedAt.timeIntervalSince1970
                try replaceTools(db, serverID: serverID.uuidString, tools: metadata.tools, updatedAt: updatedAt)
                try db.execute(
                    sql: """
                    UPDATE \(relationalServerTable)
                    SET
                        status = ?,
                        metadata_cached_at = ?,
                        info_json = ?,
                        resources_json = ?,
                        resource_templates_json = ?,
                        prompts_json = ?,
                        roots_json = ?,
                        updated_at = ?
                    WHERE id = ?
                    """,
                    arguments: [
                        MCPServerHeaderRecord.Status.ready.rawValue,
                        metadata.cachedAt.timeIntervalSince1970,
                        MCPServerStoreCodec.encodeJSONTextIfPresent(metadata.info),
                        metadata.resources.isEmpty ? nil : MCPServerStoreCodec.encodeJSONTextIfPresent(metadata.resources),
                        metadata.resourceTemplates.isEmpty ? nil : MCPServerStoreCodec.encodeJSONTextIfPresent(metadata.resourceTemplates),
                        metadata.prompts.isEmpty ? nil : MCPServerStoreCodec.encodeJSONTextIfPresent(metadata.prompts),
                        metadata.roots.isEmpty ? nil : MCPServerStoreCodec.encodeJSONTextIfPresent(metadata.roots),
                        Date().timeIntervalSince1970,
                        serverID.uuidString
                    ]
                )
            } else {
                try db.execute(
                    sql: """
                    UPDATE \(relationalServerTable)
                    SET
                        status = ?,
                        metadata_cached_at = NULL,
                        info_json = NULL,
                        resources_json = NULL,
                        resource_templates_json = NULL,
                        prompts_json = NULL,
                        roots_json = NULL,
                        updated_at = ?
                    WHERE id = ?
                    """,
                    arguments: [
                        MCPServerHeaderRecord.Status.idle.rawValue,
                        Date().timeIntervalSince1970,
                        serverID.uuidString
                    ]
                )
            }
            return true
        } ?? false
    }

    private static func configurationSignatureFromRelationalStore() -> String? {
        Persistence.withConfigDatabaseRead { db in
            try configurationSignatureFromRelationalDatabase(db)
        }
    }

    private static func configurationSignatureFromRelationalDatabase(_ db: Database) throws -> String {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT
                s.id AS id,
                s.display_name AS name,
                s.status AS status,
                s.updated_at AS updated_at,
                COALESCE(MAX(t.updated_at), 0) AS tools_updated_at,
                COUNT(t.tool_name) AS tools_count
            FROM \(relationalServerTable) s
            LEFT JOIN \(relationalToolTable) t ON t.server_id = s.id
            GROUP BY s.id, s.display_name, s.status, s.updated_at
            ORDER BY s.id ASC
            """
        )

        let signatures = rows.map { row -> String in
            let id: String = row["id"]
            let name: String = row["name"]
            let status: String = row["status"]
            let updatedAt: Double = row["updated_at"]
            let toolsUpdatedAt: Double = row["tools_updated_at"]
            let toolsCount: Int = row["tools_count"]
            return "\(id)|\(name)|\(status)|\(updatedAt)|\(toolsUpdatedAt)|\(toolsCount)"
        }
        return signatures.joined(separator: ";")
    }

    private static func decodeServerConfiguration(from row: Row) -> MCPServerConfiguration? {
        let idRaw: String = row["id"]
        let displayName: String = row["display_name"]
        let notes: String? = row["notes"]
        let selectedRaw: Int = row["is_selected_for_chat"]
        let kindRaw: String = row["transport_kind"]
        let endpointURLRaw: String? = row["endpoint_url"]
        let messageEndpointURLRaw: String? = row["message_endpoint_url"]
        let sseEndpointURLRaw: String? = row["sse_endpoint_url"]
        let apiKey: String? = row["api_key"]
        let additionalHeadersJSON: String? = row["additional_headers_json"]
        let oauthPayloadJSON: String? = row["oauth_payload_json"]
        let disabledToolIDsJSON: String? = row["disabled_tool_ids_json"]
        let toolPoliciesJSON: String? = row["tool_approval_policies_json"]
        let streamToken: String? = row["stream_resumption_token"]

        let header = MCPServerHeaderRecord(
            id: idRaw,
            displayName: displayName,
            notes: notes,
            isSelectedForChat: selectedRaw,
            status: MCPServerHeaderRecord.Status.idle.rawValue,
            transportKind: kindRaw,
            endpointURL: endpointURLRaw,
            messageEndpointURL: messageEndpointURLRaw,
            sseEndpointURL: sseEndpointURLRaw,
            metadataCachedAt: nil,
            updatedAt: 0
        )
        let payload = MCPServerPayloadRecord(
            id: idRaw,
            apiKey: apiKey,
            additionalHeadersJSON: additionalHeadersJSON,
            disabledToolIDsJSON: disabledToolIDsJSON,
            toolApprovalPoliciesJSON: toolPoliciesJSON,
            oauthPayloadJSON: oauthPayloadJSON,
            streamResumptionToken: streamToken,
            infoJSON: nil,
            resourcesJSON: nil,
            resourceTemplatesJSON: nil,
            promptsJSON: nil,
            rootsJSON: nil
        )
        return decodeServerConfiguration(from: header, payload: payload)
    }

    private static func decodeServerConfiguration(
        from header: MCPServerHeaderRecord,
        payload: MCPServerPayloadRecord?
    ) -> MCPServerConfiguration? {
        guard let id = UUID(uuidString: header.id) else { return nil }
        let additionalHeaders = payload?.decodeAdditionalHeaders() ?? [:]
        let disabledToolIDs = payload?.decodeDisabledToolIDs() ?? []
        let toolPolicies = payload?.decodeToolApprovalPolicies() ?? [:]
        let streamToken = payload?.streamResumptionToken
        let transport: MCPServerConfiguration.Transport

        switch header.transportKind {
        case "http":
            guard let endpointURLRaw = header.endpointURL,
                  let endpoint = URL(string: endpointURLRaw) else { return nil }
            transport = .http(endpoint: endpoint, apiKey: payload?.apiKey, additionalHeaders: additionalHeaders)
        case "sse":
            guard let messageEndpointURLRaw = header.messageEndpointURL,
                  let messageEndpoint = URL(string: messageEndpointURLRaw),
                  let sseEndpointURLRaw = header.sseEndpointURL,
                  let sseEndpoint = URL(string: sseEndpointURLRaw) else { return nil }
            transport = .httpSSE(
                messageEndpoint: messageEndpoint,
                sseEndpoint: sseEndpoint,
                apiKey: payload?.apiKey,
                additionalHeaders: additionalHeaders
            )
        case "oauth":
            guard let endpointURLRaw = header.endpointURL,
                  let endpoint = URL(string: endpointURLRaw),
                  let oauthPayload = payload?.decodeOAuthPayload(),
                  let tokenEndpoint = URL(string: oauthPayload.tokenEndpoint) else {
                return nil
            }
            transport = .oauth(
                endpoint: endpoint,
                tokenEndpoint: tokenEndpoint,
                clientID: oauthPayload.clientID,
                clientSecret: oauthPayload.clientSecret,
                scope: oauthPayload.scope,
                grantType: oauthPayload.grantType,
                authorizationCode: oauthPayload.authorizationCode,
                redirectURI: oauthPayload.redirectURI,
                codeVerifier: oauthPayload.codeVerifier
            )
        default:
            return nil
        }
        return MCPServerConfiguration(
            id: id,
            displayName: header.displayName,
            notes: header.notes,
            transport: transport,
            isSelectedForChat: header.isSelectedForChat != 0,
            disabledToolIds: disabledToolIDs,
            toolApprovalPolicies: toolPolicies,
            streamResumptionToken: streamToken
        )
    }

    private static func decodeMetadataPayload(
        from row: Row,
        includeTools: Bool,
        tools: [MCPToolDescription]
    ) -> MCPServerMetadataCache? {
        let id: String = row["id"]
        let infoText: String? = row["info_json"]
        let resourcesText: String? = row["resources_json"]
        let resourceTemplatesText: String? = row["resource_templates_json"]
        let promptsText: String? = row["prompts_json"]
        let rootsText: String? = row["roots_json"]
        let metadataCachedAt: Double? = row["metadata_cached_at"]
        let updatedAt: Double = row["updated_at"]

        let payload = MCPServerPayloadRecord(
            id: id,
            apiKey: nil,
            additionalHeadersJSON: nil,
            disabledToolIDsJSON: nil,
            toolApprovalPoliciesJSON: nil,
            oauthPayloadJSON: nil,
            streamResumptionToken: nil,
            infoJSON: infoText,
            resourcesJSON: resourcesText,
            resourceTemplatesJSON: resourceTemplatesText,
            promptsJSON: promptsText,
            rootsJSON: rootsText
        )

        let info = payload.decodeInfo()
        let resources = payload.decodeResources()
        let resourceTemplates = payload.decodeResourceTemplates()
        let prompts = payload.decodePrompts()
        let roots = payload.decodeRoots()
        let payloadTools = includeTools ? tools : []

        if info == nil,
           payloadTools.isEmpty,
           resources.isEmpty,
           resourceTemplates.isEmpty,
           prompts.isEmpty,
           roots.isEmpty {
            return nil
        }

        return MCPServerMetadataCache(
            cachedAt: Date(timeIntervalSince1970: metadataCachedAt ?? updatedAt),
            info: info,
            tools: payloadTools,
            resources: resources,
            resourceTemplates: resourceTemplates,
            prompts: prompts,
            roots: roots
        )
    }

    private static func fetchTools(_ db: Database, serverID: String) throws -> [MCPToolDescription] {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT server_id, tool_name, description, sort_index, updated_at, input_schema_json, examples_json
            FROM \(relationalToolTable)
            WHERE server_id = ?
            ORDER BY sort_index ASC, tool_name ASC
            """,
            arguments: [serverID]
        )
        return rows.map { row in
            let toolName: String = row["tool_name"]
            let description: String? = row["description"]
            let inputSchemaJSON: String? = row["input_schema_json"]
            let examplesJSON: String? = row["examples_json"]
            let payload = MCPToolPayloadRecord(
                serverID: serverID,
                toolName: toolName,
                inputSchemaJSON: inputSchemaJSON,
                examplesJSON: examplesJSON
            )
            return payload.toToolDescription(toolName: toolName, description: description)
        }
    }

    private static func deleteTools(_ db: Database, serverID: String) throws {
        try db.execute(
            sql: "DELETE FROM \(relationalToolTable) WHERE server_id = ?",
            arguments: [serverID]
        )
    }

    private static func replaceTools(_ db: Database, serverID: String, tools: [MCPToolDescription], updatedAt: Double) throws {
        try deleteTools(db, serverID: serverID)
        for (index, tool) in tools.enumerated() {
            var payload = MCPToolPayloadRecord(serverID: serverID, toolName: tool.toolId)
            payload.apply(tool: tool)
            try db.execute(
                sql: """
                INSERT INTO \(relationalToolTable) (
                    server_id, tool_name, description, sort_index, updated_at, input_schema_json, examples_json
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(server_id, tool_name) DO UPDATE SET
                    description = excluded.description,
                    sort_index = excluded.sort_index,
                    updated_at = excluded.updated_at,
                    input_schema_json = excluded.input_schema_json,
                    examples_json = excluded.examples_json
                """,
                arguments: [
                    serverID,
                    tool.toolId,
                    tool.description,
                    index,
                    updatedAt,
                    payload.inputSchemaJSON,
                    payload.examplesJSON
                ]
            )
        }
    }

    private static func upsertServerRow(
        _ db: Database,
        server: MCPServerConfiguration,
        status: MCPServerHeaderRecord.Status,
        metadata: MCPServerMetadataCache?,
        updatedAt: Double
    ) throws {
        let header = MCPServerHeaderRecord(
            id: server.id.uuidString,
            displayName: server.displayName,
            notes: server.notes,
            isSelectedForChat: server.isSelectedForChat ? 1 : 0,
            status: status.rawValue,
            transportKind: transportKind(of: server.transport),
            endpointURL: transportEndpoint(of: server.transport),
            messageEndpointURL: transportMessageEndpoint(of: server.transport),
            sseEndpointURL: transportSSEEndpoint(of: server.transport),
            metadataCachedAt: metadata?.cachedAt.timeIntervalSince1970,
            updatedAt: updatedAt
        )
        let payload = MCPServerPayloadRecord(server: server, metadata: metadata)

        try db.execute(
            sql: """
            INSERT INTO \(relationalServerTable) (
                id, display_name, notes, is_selected_for_chat, status, transport_kind,
                endpoint_url, message_endpoint_url, sse_endpoint_url, metadata_cached_at, updated_at,
                api_key, additional_headers_json, disabled_tool_ids_json, tool_approval_policies_json,
                oauth_payload_json, stream_resumption_token,
                info_json, resources_json, resource_templates_json, prompts_json, roots_json
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                display_name = excluded.display_name,
                notes = excluded.notes,
                is_selected_for_chat = excluded.is_selected_for_chat,
                status = excluded.status,
                transport_kind = excluded.transport_kind,
                endpoint_url = excluded.endpoint_url,
                message_endpoint_url = excluded.message_endpoint_url,
                sse_endpoint_url = excluded.sse_endpoint_url,
                metadata_cached_at = excluded.metadata_cached_at,
                updated_at = excluded.updated_at,
                api_key = excluded.api_key,
                additional_headers_json = excluded.additional_headers_json,
                disabled_tool_ids_json = excluded.disabled_tool_ids_json,
                tool_approval_policies_json = excluded.tool_approval_policies_json,
                oauth_payload_json = excluded.oauth_payload_json,
                stream_resumption_token = excluded.stream_resumption_token,
                info_json = excluded.info_json,
                resources_json = excluded.resources_json,
                resource_templates_json = excluded.resource_templates_json,
                prompts_json = excluded.prompts_json,
                roots_json = excluded.roots_json
            """,
            arguments: [
                header.id,
                header.displayName,
                header.notes,
                header.isSelectedForChat,
                header.status,
                header.transportKind,
                header.endpointURL,
                header.messageEndpointURL,
                header.sseEndpointURL,
                header.metadataCachedAt,
                header.updatedAt,
                payload.apiKey,
                payload.additionalHeadersJSON,
                payload.disabledToolIDsJSON,
                payload.toolApprovalPoliciesJSON,
                payload.oauthPayloadJSON,
                payload.streamResumptionToken,
                payload.infoJSON,
                payload.resourcesJSON,
                payload.resourceTemplatesJSON,
                payload.promptsJSON,
                payload.rootsJSON
            ]
        )
    }

    private static func transportKind(of transport: MCPServerConfiguration.Transport) -> String {
        switch transport {
        case .http:
            return "http"
        case .httpSSE:
            return "sse"
        case .oauth:
            return "oauth"
        }
    }

    private static func transportEndpoint(of transport: MCPServerConfiguration.Transport) -> String? {
        switch transport {
        case .http(let endpoint, _, _):
            return endpoint.absoluteString
        case .httpSSE:
            return nil
        case .oauth(let endpoint, _, _, _, _, _, _, _, _):
            return endpoint.absoluteString
        }
    }

    private static func transportMessageEndpoint(of transport: MCPServerConfiguration.Transport) -> String? {
        switch transport {
        case .http:
            return nil
        case .httpSSE(let messageEndpoint, _, _, _):
            return messageEndpoint.absoluteString
        case .oauth:
            return nil
        }
    }

    private static func transportSSEEndpoint(of transport: MCPServerConfiguration.Transport) -> String? {
        switch transport {
        case .http:
            return nil
        case .httpSSE(_, let sseEndpoint, _, _):
            return sseEndpoint.absoluteString
        case .oauth:
            return nil
        }
    }

    private static func cleanupLegacyArtifactsAfterRelationalSave() {
        _ = Persistence.removeAuxiliaryBlob(forKey: legacyBlobKey)
        cleanupLegacyFileArtifacts()
    }

    // MARK: - 旧版数据（JSON Blob / 文件）

    private static func loadLegacyRecords(usingBlobCache: Bool) -> [MCPServerStoredRecord] {
        if Persistence.auxiliaryBlobExists(forKey: legacyBlobKey) {
            let records = Persistence.loadAuxiliaryBlob([MCPServerStoredRecord].self, forKey: legacyBlobKey) ?? []
            return records.sorted { $0.server.displayName.lowercased() < $1.server.displayName.lowercased() }
        }

        let fileRecords = loadRecordsFromFiles()
        guard !fileRecords.isEmpty else { return [] }

        if usingBlobCache,
           Persistence.saveAuxiliaryBlob(fileRecords, forKey: legacyBlobKey) {
            cleanupLegacyFileArtifacts()
        }

        return fileRecords.sorted { $0.server.displayName.lowercased() < $1.server.displayName.lowercased() }
    }

    private static func saveLegacyRecords(_ records: [MCPServerStoredRecord]) {
        let sortedRecords = records.sorted { $0.server.displayName.lowercased() < $1.server.displayName.lowercased() }
        if Persistence.saveAuxiliaryBlob(sortedRecords, forKey: legacyBlobKey) {
            cleanupLegacyFileArtifacts()
            return
        }
        saveRecordsToFiles(sortedRecords)
    }

    private static func configurationSignatureFromLegacyRecords() -> String {
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
}

// MARK: - GRDB Records

private struct MCPServerHeaderRecord: Codable, FetchableRecord, MutablePersistableRecord, TableRecord {
    static let databaseTableName = "mcp_servers_v2"

    enum Status: String {
        case idle
        case ready
    }

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case notes
        case isSelectedForChat = "is_selected_for_chat"
        case status
        case transportKind = "transport_kind"
        case endpointURL = "endpoint_url"
        case messageEndpointURL = "message_endpoint_url"
        case sseEndpointURL = "sse_endpoint_url"
        case metadataCachedAt = "metadata_cached_at"
        case updatedAt = "updated_at"
    }

    enum Columns {
        static let id = Column(CodingKeys.id.rawValue)
        static let displayName = Column(CodingKeys.displayName.rawValue)
        static let status = Column(CodingKeys.status.rawValue)
        static let updatedAt = Column(CodingKeys.updatedAt.rawValue)
    }

    var id: String
    var displayName: String
    var notes: String?
    var isSelectedForChat: Int
    var status: String
    var transportKind: String
    var endpointURL: String?
    var messageEndpointURL: String?
    var sseEndpointURL: String?
    var metadataCachedAt: Double?
    var updatedAt: Double
}

private struct MCPOAuthPayload: Codable, Hashable {
    var tokenEndpoint: String
    var clientID: String
    var clientSecret: String?
    var scope: String?
    var grantType: MCPOAuthGrantType
    var authorizationCode: String?
    var redirectURI: String?
    var codeVerifier: String?
}

private struct MCPServerPayloadRecord: Codable, FetchableRecord, MutablePersistableRecord, TableRecord {
    static let databaseTableName = "mcp_servers_v2"

    enum CodingKeys: String, CodingKey {
        case id
        case apiKey = "api_key"
        case additionalHeadersJSON = "additional_headers_json"
        case disabledToolIDsJSON = "disabled_tool_ids_json"
        case toolApprovalPoliciesJSON = "tool_approval_policies_json"
        case oauthPayloadJSON = "oauth_payload_json"
        case streamResumptionToken = "stream_resumption_token"
        case infoJSON = "info_json"
        case resourcesJSON = "resources_json"
        case resourceTemplatesJSON = "resource_templates_json"
        case promptsJSON = "prompts_json"
        case rootsJSON = "roots_json"
    }

    var id: String
    var apiKey: String?
    var additionalHeadersJSON: String?
    var disabledToolIDsJSON: String?
    var toolApprovalPoliciesJSON: String?
    var oauthPayloadJSON: String?
    var streamResumptionToken: String?
    var infoJSON: String?
    var resourcesJSON: String?
    var resourceTemplatesJSON: String?
    var promptsJSON: String?
    var rootsJSON: String?

    init(server: MCPServerConfiguration, metadata: MCPServerMetadataCache?) {
        id = server.id.uuidString
        streamResumptionToken = server.streamResumptionToken
        disabledToolIDsJSON = server.disabledToolIds.isEmpty ? nil : MCPServerStoreCodec.encodeJSONTextIfPresent(server.disabledToolIds)
        toolApprovalPoliciesJSON = server.toolApprovalPolicies.isEmpty ? nil : MCPServerStoreCodec.encodeJSONTextIfPresent(server.toolApprovalPolicies)
        infoJSON = MCPServerStoreCodec.encodeJSONTextIfPresent(metadata?.info)
        resourcesJSON = metadata?.resources.isEmpty == false ? MCPServerStoreCodec.encodeJSONTextIfPresent(metadata?.resources) : nil
        resourceTemplatesJSON = metadata?.resourceTemplates.isEmpty == false ? MCPServerStoreCodec.encodeJSONTextIfPresent(metadata?.resourceTemplates) : nil
        promptsJSON = metadata?.prompts.isEmpty == false ? MCPServerStoreCodec.encodeJSONTextIfPresent(metadata?.prompts) : nil
        rootsJSON = metadata?.roots.isEmpty == false ? MCPServerStoreCodec.encodeJSONTextIfPresent(metadata?.roots) : nil

        switch server.transport {
        case .http(_, let apiKey, let headers):
            self.apiKey = apiKey
            additionalHeadersJSON = headers.isEmpty ? nil : MCPServerStoreCodec.encodeJSONTextIfPresent(headers)
            oauthPayloadJSON = nil
        case .httpSSE(_, _, let apiKey, let headers):
            self.apiKey = apiKey
            additionalHeadersJSON = headers.isEmpty ? nil : MCPServerStoreCodec.encodeJSONTextIfPresent(headers)
            oauthPayloadJSON = nil
        case .oauth(_, let tokenEndpoint, let clientID, let clientSecret, let scope, let grantType, let authorizationCode, let redirectURI, let codeVerifier):
            self.apiKey = nil
            additionalHeadersJSON = nil
            oauthPayloadJSON = MCPServerStoreCodec.encodeJSONTextIfPresent(
                MCPOAuthPayload(
                    tokenEndpoint: tokenEndpoint.absoluteString,
                    clientID: clientID,
                    clientSecret: clientSecret,
                    scope: scope,
                    grantType: grantType,
                    authorizationCode: authorizationCode,
                    redirectURI: redirectURI,
                    codeVerifier: codeVerifier
                )
            )
        }
    }

    func decodeAdditionalHeaders() -> [String: String] {
        MCPServerStoreCodec.decodeJSONTextIfPresent([String: String].self, from: additionalHeadersJSON) ?? [:]
    }

    func decodeDisabledToolIDs() -> [String] {
        MCPServerStoreCodec.decodeJSONTextIfPresent([String].self, from: disabledToolIDsJSON) ?? []
    }

    func decodeToolApprovalPolicies() -> [String: MCPToolApprovalPolicy] {
        MCPServerStoreCodec.decodeJSONTextIfPresent([String: MCPToolApprovalPolicy].self, from: toolApprovalPoliciesJSON) ?? [:]
    }

    func decodeOAuthPayload() -> MCPOAuthPayload? {
        MCPServerStoreCodec.decodeJSONTextIfPresent(MCPOAuthPayload.self, from: oauthPayloadJSON)
    }

    func decodeInfo() -> MCPServerInfo? {
        MCPServerStoreCodec.decodeJSONTextIfPresent(MCPServerInfo.self, from: infoJSON)
    }

    func decodeResources() -> [MCPResourceDescription] {
        MCPServerStoreCodec.decodeJSONTextIfPresent([MCPResourceDescription].self, from: resourcesJSON) ?? []
    }

    func decodeResourceTemplates() -> [MCPResourceTemplate] {
        MCPServerStoreCodec.decodeJSONTextIfPresent([MCPResourceTemplate].self, from: resourceTemplatesJSON) ?? []
    }

    func decodePrompts() -> [MCPPromptDescription] {
        MCPServerStoreCodec.decodeJSONTextIfPresent([MCPPromptDescription].self, from: promptsJSON) ?? []
    }

    func decodeRoots() -> [MCPRoot] {
        MCPServerStoreCodec.decodeJSONTextIfPresent([MCPRoot].self, from: rootsJSON) ?? []
    }
}

private struct MCPToolHeaderRecord: Codable, FetchableRecord, MutablePersistableRecord, TableRecord {
    static let databaseTableName = "mcp_tools_v2"

    enum CodingKeys: String, CodingKey {
        case serverID = "server_id"
        case toolName = "tool_name"
        case description
        case sortIndex = "sort_index"
        case updatedAt = "updated_at"
    }

    enum Columns {
        static let serverID = Column(CodingKeys.serverID.rawValue)
        static let toolName = Column(CodingKeys.toolName.rawValue)
        static let sortIndex = Column(CodingKeys.sortIndex.rawValue)
    }

    var serverID: String
    var toolName: String
    var description: String?
    var sortIndex: Int
    var updatedAt: Double
}

private struct MCPToolPayloadRecord: Codable, FetchableRecord, MutablePersistableRecord, TableRecord {
    static let databaseTableName = "mcp_tools_v2"

    enum CodingKeys: String, CodingKey {
        case serverID = "server_id"
        case toolName = "tool_name"
        case inputSchemaJSON = "input_schema_json"
        case examplesJSON = "examples_json"
    }

    var serverID: String
    var toolName: String
    var inputSchemaJSON: String?
    var examplesJSON: String?

    init(
        serverID: String,
        toolName: String,
        inputSchemaJSON: String? = nil,
        examplesJSON: String? = nil
    ) {
        self.serverID = serverID
        self.toolName = toolName
        self.inputSchemaJSON = inputSchemaJSON
        self.examplesJSON = examplesJSON
    }

    mutating func apply(tool: MCPToolDescription) {
        inputSchemaJSON = MCPServerStoreCodec.encodeJSONTextIfPresent(tool.inputSchema)
        examplesJSON = MCPServerStoreCodec.encodeJSONTextIfPresent(tool.examples)
    }

    func decodeInputSchema() -> JSONValue? {
        MCPServerStoreCodec.decodeJSONTextIfPresent(JSONValue.self, from: inputSchemaJSON)
    }

    func decodeExamples() -> [JSONValue]? {
        MCPServerStoreCodec.decodeJSONTextIfPresent([JSONValue].self, from: examplesJSON)
    }

    func toToolDescription(toolName: String, description: String?) -> MCPToolDescription {
        MCPToolDescription(
            toolId: toolName,
            description: description,
            inputSchema: decodeInputSchema(),
            examples: decodeExamples()
        )
    }
}

private enum MCPServerStoreCodec {
    static func encodeJSONTextIfPresent<T: Encodable>(_ value: T?) -> String? {
        guard let value else { return nil }
        guard let data = try? makeEncoder().encode(value),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return text
    }

    static func decodeJSONTextIfPresent<T: Decodable>(_ type: T.Type, from text: String?) -> T? {
        guard let text,
              let data = text.data(using: .utf8) else {
            return nil
        }
        return try? makeDecoder().decode(type, from: data)
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private extension NSLock {
    func withLock<T>(_ block: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try block()
    }
}
