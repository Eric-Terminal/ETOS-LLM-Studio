// ============================================================================
// MCPServerConfiguration.swift
// ============================================================================
// 用于描述和序列化 MCP Server 的连接配置。
// ============================================================================

import Foundation
import MCP

private let mcpTokenPlaceholder = "{token}"

public enum MCPOAuthGrantType: String, Codable, Hashable, CaseIterable, Sendable {
    case clientCredentials = "client_credentials"
    case authorizationCode = "authorization_code"
}

public enum MCPToolApprovalPolicy: String, Codable, Hashable, CaseIterable, Sendable {
    case askEveryTime = "ask_every_time"
    case alwaysAllow = "always_allow"
    case alwaysDeny = "always_deny"
}

public extension MCPToolApprovalPolicy {
    var displayName: String {
        switch self {
        case .askEveryTime:
            return NSLocalizedString("每次询问", comment: "MCP approval policy ask every time")
        case .alwaysAllow:
            return NSLocalizedString("总是允许", comment: "MCP approval policy always allow")
        case .alwaysDeny:
            return NSLocalizedString("始终拒绝", comment: "MCP approval policy always deny")
        }
    }
}

private func resolveAdditionalHeaders(_ headers: [String: String], token: String?) -> [String: String] {
    var resolved: [String: String]
    if headers.isEmpty {
        resolved = [:]
    } else if let token, !token.isEmpty {
        resolved = headers.reduce(into: [String: String]()) { result, pair in
            result[pair.key] = pair.value.replacingOccurrences(of: mcpTokenPlaceholder, with: token)
        }
    } else {
        resolved = headers
    }
    // apiKey 存在但 headers 中无 Authorization 时，自动添加 Bearer 鉴权头
    if let token, !token.isEmpty {
        let hasAuth = resolved.keys.contains { $0.caseInsensitiveCompare("Authorization") == .orderedSame }
        if !hasAuth {
            resolved["Authorization"] = "Bearer \(token)"
        }
    }
    return resolved
}

public struct MCPServerConfiguration: Codable, Identifiable, Hashable, Sendable {
    public enum Transport: Codable, Hashable, Sendable {
        case http(endpoint: URL, apiKey: String?, additionalHeaders: [String: String])
        case httpSSE(messageEndpoint: URL, sseEndpoint: URL, apiKey: String?, additionalHeaders: [String: String])
        case localStdio(configuration: MCPLocalStdioConfiguration)
        case builtInSearch
        case builtInAppTool(category: AppToolCatalogCategory)
        case builtInPersonalData
        case oauth(
            endpoint: URL,
            tokenEndpoint: URL,
            clientID: String,
            clientSecret: String?,
            scope: String?,
            grantType: MCPOAuthGrantType,
            authorizationCode: String?,
            redirectURI: String?,
            codeVerifier: String?
        )
    }

    public var id: UUID
    public var displayName: String
    public var notes: String?
    public var transport: Transport
    public var isSelectedForChat: Bool
    public var disabledToolIds: [String]
    public var toolApprovalPolicies: [String: MCPToolApprovalPolicy]
    public var streamResumptionToken: String?
    public var sortIndex: Int

    public init(
        id: UUID = UUID(),
        displayName: String,
        notes: String? = nil,
        transport: Transport,
        isSelectedForChat: Bool = false,
        disabledToolIds: [String] = [],
        toolApprovalPolicies: [String: MCPToolApprovalPolicy] = [:],
        streamResumptionToken: String? = nil,
        sortIndex: Int = 0
    ) {
        self.id = id
        self.displayName = displayName
        self.notes = notes
        self.transport = transport
        self.isSelectedForChat = isSelectedForChat
        self.disabledToolIds = disabledToolIds
        self.toolApprovalPolicies = toolApprovalPolicies
        self.streamResumptionToken = streamResumptionToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sortIndex = sortIndex
    }
}

extension MCPServerConfiguration {
    private enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case notes
        case transport
        case isSelectedForChat
        case disabledToolIds
        case toolApprovalPolicies
        case streamResumptionToken
        case sortIndex
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
        transport = try container.decode(Transport.self, forKey: .transport)
        isSelectedForChat = try container.decodeIfPresent(Bool.self, forKey: .isSelectedForChat) ?? false
        disabledToolIds = try container.decodeIfPresent([String].self, forKey: .disabledToolIds) ?? []
        toolApprovalPolicies = try container.decodeIfPresent([String: MCPToolApprovalPolicy].self, forKey: .toolApprovalPolicies) ?? [:]
        sortIndex = try container.decodeIfPresent(Int.self, forKey: .sortIndex) ?? 0
        let decodedToken = try container.decodeIfPresent(String.self, forKey: .streamResumptionToken)
        if let decodedToken {
            let trimmed = decodedToken.trimmingCharacters(in: .whitespacesAndNewlines)
            streamResumptionToken = trimmed.isEmpty ? nil : trimmed
        } else {
            streamResumptionToken = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(displayName, forKey: .displayName)
        try container.encodeIfPresent(notes, forKey: .notes)
        try container.encode(transport, forKey: .transport)
        if isSelectedForChat {
            try container.encode(isSelectedForChat, forKey: .isSelectedForChat)
        }
        if !disabledToolIds.isEmpty {
            let uniqueIds = Array(Set(disabledToolIds)).sorted()
            try container.encode(uniqueIds, forKey: .disabledToolIds)
        }
        let normalizedToolApprovalPolicies = toolApprovalPolicies.reduce(into: [String: MCPToolApprovalPolicy]()) { partialResult, element in
            if element.value != .askEveryTime {
                partialResult[element.key] = element.value
            }
        }
        if !normalizedToolApprovalPolicies.isEmpty {
            try container.encode(normalizedToolApprovalPolicies, forKey: .toolApprovalPolicies)
        }
        if let streamResumptionToken {
            let trimmed = streamResumptionToken.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                try container.encode(trimmed, forKey: .streamResumptionToken)
            }
        }
        if sortIndex != 0 {
            try container.encode(sortIndex, forKey: .sortIndex)
        }
    }
}

public extension MCPServerConfiguration {
    var humanReadableEndpoint: String {
        switch transport {
        case .http(let endpoint, _, _):
            return endpoint.absoluteString
        case .httpSSE(_, let sseEndpoint, _, _):
            return sseEndpoint.absoluteString
        case .localStdio(let configuration):
            return "stdio://" + configuration.commandLine
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

    var additionalHeaders: [String: String] {
        switch transport {
        case .http(_, _, let headers):
            return headers
        case .httpSSE(_, _, _, let headers):
            return headers
        case .localStdio:
            return [:]
        case .builtInSearch:
            return [:]
        case .builtInAppTool:
            return [:]
        case .builtInPersonalData:
            return [:]
        case .oauth:
            return [:]
        }
    }

    func makeTransport(urlSession: URLSession = NetworkSessionConfiguration.shared) -> MCPTransport {
        switch transport {
        case .http(let endpoint, let apiKey, let additionalHeaders):
            let headers = resolveAdditionalHeaders(additionalHeaders, token: apiKey)
            return MCPStreamableHTTPTransport(endpoint: endpoint, session: urlSession, headers: headers)
        case .httpSSE(let messageEndpoint, let sseEndpoint, let apiKey, let additionalHeaders):
            let headers = resolveAdditionalHeaders(additionalHeaders, token: apiKey)
            return MCPStreamingTransport(messageEndpoint: messageEndpoint, sseEndpoint: sseEndpoint, session: urlSession, headers: headers)
        case .localStdio:
            return MCPLocalStdioLegacyTransport()
        case .builtInSearch:
            return MCPBuiltInSearchLegacyTransport()
        case .builtInAppTool(let category):
            return MCPBuiltInAppToolLegacyTransport(category: category)
        case .builtInPersonalData:
            return MCPBuiltInPersonalDataLegacyTransport()
        case .oauth(let endpoint, let tokenEndpoint, let clientID, let clientSecret, let scope, let grantType, let authorizationCode, let redirectURI, let codeVerifier):
            return MCPOAuthStreamableHTTPTransport(
                endpoint: endpoint,
                tokenEndpoint: tokenEndpoint,
                clientID: clientID,
                clientSecret: clientSecret,
                scope: scope,
                grantType: grantType,
                authorizationCode: authorizationCode,
                redirectURI: redirectURI,
                codeVerifier: codeVerifier,
                session: urlSession
            )
        }
    }

    func makeSDKTransport(
        urlSession: URLSession = NetworkSessionConfiguration.shared,
        approvedLocalLinuxCommandRuleIDs: Set<UUID> = []
    ) -> MCPSDKTransportBundle {
        switch transport {
        case .http(let endpoint, let apiKey, let additionalHeaders):
            let headers = resolveAdditionalHeaders(additionalHeaders, token: apiKey)
            let configuration = NetworkSessionConfiguration.makeConfiguration()
            let requestState = MCPSDKHTTPRequestState(headers: headers)
            let modifier = requestState.requestModifier()
            let sdkTransport = HTTPClientTransport(
                endpoint: endpoint,
                configuration: configuration,
                streaming: false,
                protocolVersion: MCPProtocolVersion.current,
                requestModifier: modifier
            )
            let controller = MCPSDKHTTPTransportController(
                transport: sdkTransport,
                requestState: requestState,
                session: urlSession,
                endpoint: endpoint,
                requestModifier: modifier
            )
            return MCPSDKTransportBundle(
                transport: sdkTransport,
                streamControl: MCPTransportControlBox(control: controller)
            )
        case .httpSSE(let messageEndpoint, let sseEndpoint, let apiKey, let additionalHeaders):
            let headers = resolveAdditionalHeaders(additionalHeaders, token: apiKey)
            let legacyTransport = MCPStreamingTransport(
                messageEndpoint: messageEndpoint,
                sseEndpoint: sseEndpoint,
                session: urlSession,
                headers: headers
            )
            let sdkTransport = MCPLegacySSESDKTransport(legacyTransport: legacyTransport)
            return MCPSDKTransportBundle(
                transport: sdkTransport,
                streamControl: MCPLegacySSETransportControlBox(
                    sdkTransport: sdkTransport,
                    legacyTransport: legacyTransport
                )
            )
        case .localStdio(let configuration):
            let transport = MCPLocalStdioTransport(
                serverID: id,
                configuration: configuration,
                approvedCommandRuleIDs: approvedLocalLinuxCommandRuleIDs
            )
            return MCPSDKTransportBundle(
                transport: transport,
                streamControl: MCPTransportControlBox(control: transport)
            )
        case .builtInSearch:
            let transport = MCPBuiltInSearchTransport()
            return MCPSDKTransportBundle(
                transport: transport,
                streamControl: MCPTransportControlBox(control: transport)
            )
        case .builtInAppTool(let category):
            let transport = MCPBuiltInAppToolTransport(category: category)
            return MCPSDKTransportBundle(
                transport: transport,
                streamControl: MCPTransportControlBox(control: transport)
            )
        case .builtInPersonalData:
            let transport = MCPBuiltInPersonalDataTransport()
            return MCPSDKTransportBundle(
                transport: transport,
                streamControl: MCPTransportControlBox(control: transport)
            )
        case .oauth(let endpoint, let tokenEndpoint, let clientID, let clientSecret, let scope, let grantType, let authorizationCode, let redirectURI, let codeVerifier):
            let configuration = NetworkSessionConfiguration.makeConfiguration()
            let authorizer = MCPOAuthEndpointAuthorizer(
                tokenEndpoint: tokenEndpoint,
                clientID: clientID,
                clientSecret: clientSecret,
                scope: scope,
                grantType: grantType,
                authorizationCode: authorizationCode,
                redirectURI: redirectURI,
                codeVerifier: codeVerifier
            )
            let requestState = MCPSDKHTTPRequestState(headers: [:])
            let modifier = requestState.requestModifier()
            let sdkTransport = HTTPClientTransport(
                endpoint: endpoint,
                configuration: configuration,
                streaming: false,
                protocolVersion: MCPProtocolVersion.current,
                authorizer: authorizer,
                requestModifier: modifier
            )
            let controller = MCPSDKHTTPTransportController(
                transport: sdkTransport,
                requestState: requestState,
                session: urlSession,
                endpoint: endpoint,
                requestModifier: modifier
            )
            return MCPSDKTransportBundle(
                transport: sdkTransport,
                streamControl: MCPTransportControlBox(control: controller)
            )
        }
    }
}

public struct MCPSDKTransportBundle {
    public let transport: any Transport
    public let streamControl: MCPStreamingTransportProtocol?

    public init(transport: any Transport, streamControl: MCPStreamingTransportProtocol?) {
        self.transport = transport
        self.streamControl = streamControl
    }
}

public extension MCPServerConfiguration {
    func isToolEnabled(_ toolId: String) -> Bool {
        !disabledToolIds.contains(toolId)
    }

    mutating func setToolEnabled(_ toolId: String, isEnabled: Bool) {
        if isEnabled {
            disabledToolIds.removeAll { $0 == toolId }
        } else if !disabledToolIds.contains(toolId) {
            disabledToolIds.append(toolId)
        }
    }

    func approvalPolicy(for toolId: String) -> MCPToolApprovalPolicy {
        toolApprovalPolicies[toolId] ?? .askEveryTime
    }

    mutating func setApprovalPolicy(_ policy: MCPToolApprovalPolicy, for toolId: String) {
        if policy == .askEveryTime {
            toolApprovalPolicies.removeValue(forKey: toolId)
        } else {
            toolApprovalPolicies[toolId] = policy
        }
    }

    mutating func setResumptionToken(_ token: String?) {
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        streamResumptionToken = (trimmed?.isEmpty == false) ? trimmed : nil
    }
}

public extension MCPServerConfiguration {
    static func inferMessageEndpoint(fromSSE sseEndpoint: URL) -> URL {
        replacePathComponent(in: sseEndpoint, from: "sse", to: "message") ?? sseEndpoint
    }

    static func inferSSEEndpoint(fromMessage messageEndpoint: URL) -> URL {
        replacePathComponent(in: messageEndpoint, from: "message", to: "sse") ?? messageEndpoint
    }

    private static func replacePathComponent(in url: URL, from: String, to: String) -> URL? {
        var components = url.pathComponents
        guard let index = components.lastIndex(of: from) else { return nil }
        components[index] = to
        let path = "/" + components.dropFirst().joined(separator: "/")
        guard var urlComponents = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        urlComponents.path = path
        return urlComponents.url
    }
}

extension MCPServerConfiguration.Transport {
    private enum CodingKeys: String, CodingKey {
        case kind
        case type
        case endpoint
        case messageEndpoint
        case sseEndpoint
        case apiKey
        case additionalHeaders
        case category
        case tokenEndpoint
        case clientID
        case clientSecret
        case scope
        case grantType
        case authorizationCode
        case redirectURI
        case codeVerifier
        case command
        case args
        case env
        case cwd
        case environmentVariableIDs
        case inheritLocalLinuxEnvironment
        case workspaceID
        case mountIDs
        case startupTimeoutSeconds
        case launchPolicy
        case idlePolicy
    }

    private enum Kind: String, Codable {
        case stdio
        case http
        case streamableHTTP = "streamable_http"
        case httpSSE
        case sse
        case builtInSearch = "built_in_search"
        case builtInAppTool = "built_in_app_tool"
        case builtInPersonalData = "built_in_personal_data"
        case oauth
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decodeIfPresent(Kind.self, forKey: .kind)
            ?? container.decode(Kind.self, forKey: .type)
        switch kind {
        case .stdio:
            self = .localStdio(
                configuration: MCPLocalStdioConfiguration(
                    command: try container.decode(String.self, forKey: .command),
                    arguments: try container.decodeIfPresent([String].self, forKey: .args) ?? [],
                    environment: try container.decodeIfPresent([String: String].self, forKey: .env) ?? [:],
                    environmentVariableIDs: try container.decodeIfPresent(
                        [UUID].self,
                        forKey: .environmentVariableIDs
                    ) ?? [],
                    inheritLocalLinuxEnvironment: try container.decodeIfPresent(
                        Bool.self,
                        forKey: .inheritLocalLinuxEnvironment
                    ) ?? true,
                    workingDirectory: try container.decodeIfPresent(String.self, forKey: .cwd) ?? "/home/etos",
                    workspaceID: try container.decodeIfPresent(UUID.self, forKey: .workspaceID),
                    mountIDs: try container.decodeIfPresent([UUID].self, forKey: .mountIDs) ?? [],
                    startupTimeoutSeconds: try container.decodeIfPresent(
                        TimeInterval.self,
                        forKey: .startupTimeoutSeconds
                    ) ?? 30,
                    launchPolicy: try container.decodeIfPresent(
                        MCPLocalStdioLaunchPolicy.self,
                        forKey: .launchPolicy
                    ) ?? .onDemand,
                    idlePolicy: try container.decodeIfPresent(
                        MCPLocalStdioIdlePolicy.self,
                        forKey: .idlePolicy
                    ) ?? .fiveMinutes
                )
            )
        case .http, .streamableHTTP:
            let endpoint = try container.decode(URL.self, forKey: .endpoint)
            let apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey)
            let headers = try container.decodeIfPresent([String: String].self, forKey: .additionalHeaders) ?? [:]
            self = .http(endpoint: endpoint, apiKey: apiKey, additionalHeaders: headers)
        case .httpSSE, .sse:
            let legacyEndpoint = try container.decodeIfPresent(URL.self, forKey: .endpoint)
            let explicitMessageEndpoint = try container.decodeIfPresent(URL.self, forKey: .messageEndpoint)
            let explicitSSEEndpoint = try container.decodeIfPresent(URL.self, forKey: .sseEndpoint)
            let inferredMessageEndpoint = explicitMessageEndpoint ?? legacyEndpoint.map { MCPServerConfiguration.inferMessageEndpoint(fromSSE: $0) }
            guard let messageEndpoint = inferredMessageEndpoint else {
                throw DecodingError.keyNotFound(CodingKeys.messageEndpoint, DecodingError.Context(codingPath: container.codingPath, debugDescription: "Missing messageEndpoint for httpSSE"))
            }
            let sseEndpoint = explicitSSEEndpoint ?? MCPServerConfiguration.inferSSEEndpoint(fromMessage: legacyEndpoint ?? messageEndpoint)
            let apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey)
            let headers = try container.decodeIfPresent([String: String].self, forKey: .additionalHeaders) ?? [:]
            self = .httpSSE(messageEndpoint: messageEndpoint, sseEndpoint: sseEndpoint, apiKey: apiKey, additionalHeaders: headers)
        case .builtInSearch:
            self = .builtInSearch
        case .builtInAppTool:
            let category = try container.decode(AppToolCatalogCategory.self, forKey: .category)
            self = .builtInAppTool(category: category)
        case .builtInPersonalData:
            self = .builtInPersonalData
        case .oauth:
            let endpoint = try container.decode(URL.self, forKey: .endpoint)
            let tokenEndpoint = try container.decode(URL.self, forKey: .tokenEndpoint)
            let clientID = try container.decode(String.self, forKey: .clientID)
            let clientSecret = try container.decodeIfPresent(String.self, forKey: .clientSecret)
            let scope = try container.decodeIfPresent(String.self, forKey: .scope)
            let grantType = try container.decodeIfPresent(MCPOAuthGrantType.self, forKey: .grantType) ?? .clientCredentials
            let authorizationCode = try container.decodeIfPresent(String.self, forKey: .authorizationCode)
            let redirectURI = try container.decodeIfPresent(String.self, forKey: .redirectURI)
            let codeVerifier = try container.decodeIfPresent(String.self, forKey: .codeVerifier)
            self = .oauth(
                endpoint: endpoint,
                tokenEndpoint: tokenEndpoint,
                clientID: clientID,
                clientSecret: clientSecret,
                scope: scope,
                grantType: grantType,
                authorizationCode: authorizationCode,
                redirectURI: redirectURI,
                codeVerifier: codeVerifier
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .localStdio(let configuration):
            try container.encode(Kind.stdio, forKey: .kind)
            try container.encode(configuration.command, forKey: .command)
            if !configuration.arguments.isEmpty { try container.encode(configuration.arguments, forKey: .args) }
            if !configuration.environment.isEmpty { try container.encode(configuration.environment, forKey: .env) }
            if !configuration.environmentVariableIDs.isEmpty {
                try container.encode(configuration.environmentVariableIDs, forKey: .environmentVariableIDs)
            }
            if !configuration.inheritLocalLinuxEnvironment {
                try container.encode(false, forKey: .inheritLocalLinuxEnvironment)
            }
            if configuration.workingDirectory != "/home/etos" {
                try container.encode(configuration.workingDirectory, forKey: .cwd)
            }
            try container.encodeIfPresent(configuration.workspaceID, forKey: .workspaceID)
            if !configuration.mountIDs.isEmpty {
                try container.encode(configuration.mountIDs, forKey: .mountIDs)
            }
            if configuration.startupTimeoutSeconds != 30 {
                try container.encode(configuration.startupTimeoutSeconds, forKey: .startupTimeoutSeconds)
            }
            if configuration.launchPolicy != .onDemand {
                try container.encode(configuration.launchPolicy, forKey: .launchPolicy)
            }
            if configuration.idlePolicy != .fiveMinutes {
                try container.encode(configuration.idlePolicy, forKey: .idlePolicy)
            }
        case .http(let endpoint, let apiKey, let headers):
            try container.encode(Kind.streamableHTTP, forKey: .kind)
            try container.encode(endpoint, forKey: .endpoint)
            try container.encodeIfPresent(apiKey, forKey: .apiKey)
            if !headers.isEmpty {
                try container.encode(headers, forKey: .additionalHeaders)
            }
        case .httpSSE(let messageEndpoint, let sseEndpoint, let apiKey, let headers):
            try container.encode(Kind.sse, forKey: .kind)
            try container.encode(messageEndpoint, forKey: .endpoint)
            try container.encode(messageEndpoint, forKey: .messageEndpoint)
            try container.encode(sseEndpoint, forKey: .sseEndpoint)
            try container.encodeIfPresent(apiKey, forKey: .apiKey)
            if !headers.isEmpty {
                try container.encode(headers, forKey: .additionalHeaders)
            }
        case .builtInSearch:
            try container.encode(Kind.builtInSearch, forKey: .kind)
        case .builtInAppTool(let category):
            try container.encode(Kind.builtInAppTool, forKey: .kind)
            try container.encode(category, forKey: .category)
        case .builtInPersonalData:
            try container.encode(Kind.builtInPersonalData, forKey: .kind)
        case .oauth(let endpoint, let tokenEndpoint, let clientID, let clientSecret, let scope, let grantType, let authorizationCode, let redirectURI, let codeVerifier):
            try container.encode(Kind.oauth, forKey: .kind)
            try container.encode(endpoint, forKey: .endpoint)
            try container.encode(tokenEndpoint, forKey: .tokenEndpoint)
            try container.encode(clientID, forKey: .clientID)
            try container.encodeIfPresent(clientSecret, forKey: .clientSecret)
            try container.encodeIfPresent(scope, forKey: .scope)
            if grantType != .clientCredentials {
                try container.encode(grantType, forKey: .grantType)
            }
            try container.encodeIfPresent(authorizationCode, forKey: .authorizationCode)
            try container.encodeIfPresent(redirectURI, forKey: .redirectURI)
            try container.encodeIfPresent(codeVerifier, forKey: .codeVerifier)
        }
    }

}
