import Foundation
import GRDB
import os.log

extension MCPServerStore {
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

    static func bootstrapRelationalStoreIfNeeded() {
        guard !didBootstrapRelationalStore else { return }
        guard Persistence.withConfigDatabaseRead({ _ in true }) == true else { return }

        migrateLegacyRecordsToRelationalStoreIfNeeded()
        didBootstrapRelationalStore = true
    }

    static func migrateLegacyRecordsToRelationalStoreIfNeeded() {
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
            mcpStoreLogger.error("MCP 关系化迁移失败：未能写入 mcp_servers/mcp_tools。")
            return
        }

        removeLegacyRecordBlobs()
        cleanupLegacyFileArtifacts()
        mcpStoreLogger.info("MCP 配置已自动迁移到关系化表：servers=\(legacyRecords.count)")
    }

    static func loadServersFromRelationalStore() -> [MCPServerConfiguration]? {
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

    static func loadServerHeadersFromRelationalStore() -> [MCPServerListHeader]? {
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

    static func saveServerToRelationalStore(_ server: MCPServerConfiguration) -> Bool {
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

    static func deleteServerFromRelationalStore(serverID: UUID) -> Bool {
        Persistence.withConfigDatabaseWrite { db in
            try db.execute(
                sql: "DELETE FROM \(relationalServerTable) WHERE id = ?",
                arguments: [serverID.uuidString]
            )
            return true
        } ?? false
    }

    static func loadMetadataFromRelationalStore(serverID: UUID, includeTools: Bool) -> MCPServerMetadataCache? {
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

    static func loadToolsFromRelationalStore(serverID: UUID) -> [MCPToolDescription]? {
        Persistence.withConfigDatabaseRead { db in
            try fetchTools(db, serverID: serverID.uuidString)
        }
    }

    static func loadServerInfoFromRelationalStore(serverID: UUID) -> MCPServerInfo? {
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

    static func loadResourcesFromRelationalStore(serverID: UUID) -> [MCPResourceDescription]? {
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

    static func loadResourceTemplatesFromRelationalStore(serverID: UUID) -> [MCPResourceTemplate]? {
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

    static func loadPromptsFromRelationalStore(serverID: UUID) -> [MCPPromptDescription]? {
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

    static func loadRootsFromRelationalStore(serverID: UUID) -> [MCPRoot]? {
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

    static func loadMetadataCachedAtFromRelationalStore(serverID: UUID) -> Date? {
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

    static func saveMetadataToRelationalStore(_ metadata: MCPServerMetadataCache?, for serverID: UUID) -> Bool {
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

    static func configurationSignatureFromRelationalStore() -> String? {
        Persistence.withConfigDatabaseRead { db in
            try configurationSignatureFromRelationalDatabase(db)
        }
    }

    static func configurationSignatureFromRelationalDatabase(_ db: Database) throws -> String {
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

}
