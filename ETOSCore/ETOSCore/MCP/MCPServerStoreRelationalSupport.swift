// ============================================================================
// MCPServerStoreRelationalSupport.swift
// ============================================================================
// ETOS LLM Studio
//
// MCP Server 关系化存储的解码、工具表读写与 transport 字段映射辅助。
// ============================================================================

import Foundation
import GRDB

extension MCPServerStore {
    static func decodeServerConfiguration(from row: Row) -> MCPServerConfiguration? {
        let idRaw: String = row["id"]
        let displayName: String = row["display_name"]
        let notes: String? = row["notes"]
        let selectedRaw: Int = row["is_selected_for_chat"]
        let sortIndex: Int = row["sort_index"]
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
            sortIndex: sortIndex,
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
        case "built_in_search":
            transport = .builtInSearch
        case "built_in_app_tool":
            guard let category = MCPBuiltInAppToolServer.category(forEndpoint: header.endpointURL) else {
                return nil
            }
            transport = .builtInAppTool(category: category)
        case "built_in_personal_data":
            transport = .builtInPersonalData
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
            streamResumptionToken: streamToken,
            sortIndex: header.sortIndex
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

    static func transportKind(of transport: MCPServerConfiguration.Transport) -> String {
        switch transport {
        case .http:
            return "http"
        case .httpSSE:
            return "sse"
        case .builtInSearch:
            return "built_in_search"
        case .builtInAppTool:
            return "built_in_app_tool"
        case .builtInPersonalData:
            return "built_in_personal_data"
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
        case .builtInSearch:
            return MCPBuiltInSearchServer.endpoint
        case .builtInAppTool(let category):
            return MCPBuiltInAppToolServer.endpoint(for: category)
        case .builtInPersonalData:
            return MCPBuiltInPersonalDataServer.endpoint
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
        case .builtInSearch:
            return nil
        case .builtInAppTool:
            return nil
        case .builtInPersonalData:
            return nil
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
        case .builtInSearch:
            return nil
        case .builtInAppTool:
            return nil
        case .builtInPersonalData:
            return nil
        case .oauth:
            return nil
        }
    }
}
