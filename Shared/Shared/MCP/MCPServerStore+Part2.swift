import Foundation
import GRDB
import os.log

extension MCPServerStore {
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

    // MARK: - 旧版数据（JSON Blob / 文件）

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

        enum CodingKeys: String, CodingKey {
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
