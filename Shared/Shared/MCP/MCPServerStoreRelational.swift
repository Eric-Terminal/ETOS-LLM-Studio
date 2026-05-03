// ============================================================================
// MCPServerStoreRelational.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件负责 MCP Server 的关系化 SQLite 存储、迁移与查询。
// ============================================================================

import Foundation
import GRDB

extension MCPServerStore {
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

    static func decodeServerConfiguration(from row: Row) -> MCPServerConfiguration? {
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

    static func decodeServerConfiguration(
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

    static func decodeMetadataPayload(
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

    static func fetchTools(_ db: Database, serverID: String) throws -> [MCPToolDescription] {
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

    static func deleteTools(_ db: Database, serverID: String) throws {
        try db.execute(
            sql: "DELETE FROM \(relationalToolTable) WHERE server_id = ?",
            arguments: [serverID]
        )
    }

    static func replaceTools(_ db: Database, serverID: String, tools: [MCPToolDescription], updatedAt: Double) throws {
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

    static func upsertServerRow(
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

    static func transportKind(of transport: MCPServerConfiguration.Transport) -> String {
        switch transport {
        case .http:
            return "http"
        case .httpSSE:
            return "sse"
        case .oauth:
            return "oauth"
        }
    }

    static func transportEndpoint(of transport: MCPServerConfiguration.Transport) -> String? {
        switch transport {
        case .http(let endpoint, _, _):
            return endpoint.absoluteString
        case .httpSSE:
            return nil
        case .oauth(let endpoint, _, _, _, _, _, _, _, _):
            return endpoint.absoluteString
        }
    }

    static func transportMessageEndpoint(of transport: MCPServerConfiguration.Transport) -> String? {
        switch transport {
        case .http:
            return nil
        case .httpSSE(let messageEndpoint, _, _, _):
            return messageEndpoint.absoluteString
        case .oauth:
            return nil
        }
    }

    static func transportSSEEndpoint(of transport: MCPServerConfiguration.Transport) -> String? {
        switch transport {
        case .http:
            return nil
        case .httpSSE(_, let sseEndpoint, _, _):
            return sseEndpoint.absoluteString
        case .oauth:
            return nil
        }
    }

    static func cleanupLegacyArtifactsAfterRelationalSave() {
        removeLegacyRecordBlobs()
        cleanupLegacyFileArtifacts()
    }
}
