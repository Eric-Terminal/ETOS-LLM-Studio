// ============================================================================
// MCPServerStore.swift
// ============================================================================
// 管理 MCP Server 配置的增删改查（优先关系化 SQLite，失败时回退 JSON 文件）。
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

    enum CodingKeys: String, CodingKey {
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
}

// MARK: - GRDB Records

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

struct MCPToolHeaderRecord: Codable, FetchableRecord, MutablePersistableRecord, TableRecord {
    static let databaseTableName = MCPServerStore.relationalToolTable

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

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
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
