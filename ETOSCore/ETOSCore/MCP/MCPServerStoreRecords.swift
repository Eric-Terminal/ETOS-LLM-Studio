// ============================================================================
// MCPServerStoreRecords.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件负责 MCP Server 关系化存储使用的记录类型与 JSON 编解码辅助。
// ============================================================================

import Foundation
import GRDB

struct MCPServerHeaderRecord: Codable, FetchableRecord, MutablePersistableRecord, TableRecord {
    static let databaseTableName = MCPServerStore.relationalServerTable

    enum Status: String {
        case idle
        case ready
    }

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case notes
        case isSelectedForChat = "is_selected_for_chat"
        case sortIndex = "sort_index"
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
        static let sortIndex = Column(CodingKeys.sortIndex.rawValue)
        static let status = Column(CodingKeys.status.rawValue)
        static let updatedAt = Column(CodingKeys.updatedAt.rawValue)
    }

    var id: String
    var displayName: String
    var notes: String?
    var isSelectedForChat: Int
    var sortIndex: Int
    var status: String
    var transportKind: String
    var endpointURL: String?
    var messageEndpointURL: String?
    var sseEndpointURL: String?
    var metadataCachedAt: Double?
    var updatedAt: Double
}

struct MCPOAuthPayload: Codable, Hashable {
    var tokenEndpoint: String
    var clientID: String
    var clientSecret: String?
    var scope: String?
    var grantType: MCPOAuthGrantType
    var authorizationCode: String?
    var redirectURI: String?
    var codeVerifier: String?
}

struct MCPServerPayloadRecord: Codable, FetchableRecord, MutablePersistableRecord, TableRecord {
    static let databaseTableName = MCPServerStore.relationalServerTable

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

    init(
        id: String,
        apiKey: String?,
        additionalHeadersJSON: String?,
        disabledToolIDsJSON: String?,
        toolApprovalPoliciesJSON: String?,
        oauthPayloadJSON: String?,
        streamResumptionToken: String?,
        infoJSON: String?,
        resourcesJSON: String?,
        resourceTemplatesJSON: String?,
        promptsJSON: String?,
        rootsJSON: String?
    ) {
        self.id = id
        self.apiKey = apiKey
        self.additionalHeadersJSON = additionalHeadersJSON
        self.disabledToolIDsJSON = disabledToolIDsJSON
        self.toolApprovalPoliciesJSON = toolApprovalPoliciesJSON
        self.oauthPayloadJSON = oauthPayloadJSON
        self.streamResumptionToken = streamResumptionToken
        self.infoJSON = infoJSON
        self.resourcesJSON = resourcesJSON
        self.resourceTemplatesJSON = resourceTemplatesJSON
        self.promptsJSON = promptsJSON
        self.rootsJSON = rootsJSON
    }

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
        case .builtInSearch:
            self.apiKey = nil
            additionalHeadersJSON = nil
            oauthPayloadJSON = nil
        case .builtInAppTool:
            self.apiKey = nil
            additionalHeadersJSON = nil
            oauthPayloadJSON = nil
        case .builtInPersonalData:
            self.apiKey = nil
            additionalHeadersJSON = nil
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


struct MCPToolPayloadRecord: Codable, FetchableRecord, MutablePersistableRecord, TableRecord {
    static let databaseTableName = MCPServerStore.relationalToolTable

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

enum MCPServerStoreCodec {
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

extension NSLock {
    func withLock<T>(_ block: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try block()
    }
}
