// ============================================================================
// MCPServerConfiguration.swift
// ============================================================================
// 用于描述和序列化 MCP Server 的连接配置。
// ============================================================================

import Foundation

private let mcpTokenPlaceholder = "{token}"

public enum MCPOAuthGrantType: String, Codable, Hashable, CaseIterable {
    case clientCredentials = "client_credentials"
    case authorizationCode = "authorization_code"
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

public struct MCPServerConfiguration: Codable, Identifiable, Hashable {
    public enum Transport: Codable, Hashable {
        case http(endpoint: URL, apiKey: String?, additionalHeaders: [String: String])
        case httpSSE(messageEndpoint: URL, sseEndpoint: URL, apiKey: String?, additionalHeaders: [String: String])
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

    public init(
        id: UUID = UUID(),
        displayName: String,
        notes: String? = nil,
        transport: Transport,
        isSelectedForChat: Bool = false,
        disabledToolIds: [String] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.notes = notes
        self.transport = transport
        self.isSelectedForChat = isSelectedForChat
        self.disabledToolIds = disabledToolIds
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
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
        transport = try container.decode(Transport.self, forKey: .transport)
        isSelectedForChat = try container.decodeIfPresent(Bool.self, forKey: .isSelectedForChat) ?? false
        disabledToolIds = try container.decodeIfPresent([String].self, forKey: .disabledToolIds) ?? []
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
    }
}

public extension MCPServerConfiguration {
    var humanReadableEndpoint: String {
        switch transport {
        case .http(let endpoint, _, _):
            return endpoint.absoluteString
        case .httpSSE(_, let sseEndpoint, _, _):
            return sseEndpoint.absoluteString
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
        case .oauth:
            return [:]
        }
    }

    func makeTransport(urlSession: URLSession = .shared) -> MCPTransport {
        switch transport {
        case .http(let endpoint, let apiKey, let additionalHeaders):
            let headers = resolveAdditionalHeaders(additionalHeaders, token: apiKey)
            return MCPStreamableHTTPTransport(endpoint: endpoint, session: urlSession, headers: headers)
        case .httpSSE(let messageEndpoint, let sseEndpoint, let apiKey, let additionalHeaders):
            let headers = resolveAdditionalHeaders(additionalHeaders, token: apiKey)
            return MCPStreamingTransport(messageEndpoint: messageEndpoint, sseEndpoint: sseEndpoint, session: urlSession, headers: headers)
        case .oauth(let endpoint, let tokenEndpoint, let clientID, let clientSecret, let scope, let grantType, let authorizationCode, let redirectURI, let codeVerifier):
            return MCPOAuthHTTPTransport(
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
        case endpoint
        case messageEndpoint
        case sseEndpoint
        case apiKey
        case additionalHeaders
        case tokenEndpoint
        case clientID
        case clientSecret
        case scope
        case grantType
        case authorizationCode
        case redirectURI
        case codeVerifier
    }

    private enum Kind: String, Codable {
        case stdio
        case http
        case streamableHTTP = "streamable_http"
        case httpSSE
        case sse
        case oauth
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .stdio:
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "当前平台不支持 stdio 传输（iOS/watchOS 无法启动本地子进程）。请改用 streamable_http、sse 或 oauth。"
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
