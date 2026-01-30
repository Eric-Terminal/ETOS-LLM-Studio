// ============================================================================
// MCPServerConfiguration.swift
// ============================================================================
// 用于描述和序列化 MCP Server 的连接配置。
// ============================================================================

import Foundation

public struct MCPServerConfiguration: Codable, Identifiable, Hashable {
    public enum Transport: Codable, Hashable {
        case http(endpoint: URL, apiKey: String?, additionalHeaders: [String: String])
        case httpSSE(messageEndpoint: URL, sseEndpoint: URL, apiKey: String?, additionalHeaders: [String: String])
        case oauth(endpoint: URL, tokenEndpoint: URL, clientID: String, clientSecret: String, scope: String?)
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
        case .oauth(let endpoint, _, _, _, _):
            return endpoint.absoluteString
        }
    }

    func makeTransport(urlSession: URLSession = .shared) -> MCPTransport {
        switch transport {
        case .http(let endpoint, let apiKey, let additionalHeaders):
            var headers = additionalHeaders
            if let apiKey, !apiKey.isEmpty {
                headers["Authorization"] = "Bearer \(apiKey)"
            }
            return MCPStreamableHTTPTransport(endpoint: endpoint, session: urlSession, headers: headers)
        case .httpSSE(_, let sseEndpoint, let apiKey, let additionalHeaders):
            var headers = additionalHeaders
            if let apiKey, !apiKey.isEmpty {
                headers["Authorization"] = "Bearer \(apiKey)"
            }
            let messageEndpoint = MCPServerConfiguration.inferMessageEndpoint(fromSSE: sseEndpoint)
            return MCPStreamingTransport(messageEndpoint: messageEndpoint, sseEndpoint: sseEndpoint, session: urlSession, headers: headers)
        case .oauth(let endpoint, let tokenEndpoint, let clientID, let clientSecret, let scope):
            return MCPOAuthHTTPTransport(
                endpoint: endpoint,
                tokenEndpoint: tokenEndpoint,
                clientID: clientID,
                clientSecret: clientSecret,
                scope: scope,
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
    }

    private enum Kind: String, Codable {
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
            let clientSecret = try container.decode(String.self, forKey: .clientSecret)
            let scope = try container.decodeIfPresent(String.self, forKey: .scope)
            self = .oauth(endpoint: endpoint, tokenEndpoint: tokenEndpoint, clientID: clientID, clientSecret: clientSecret, scope: scope)
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
        case .oauth(let endpoint, let tokenEndpoint, let clientID, let clientSecret, let scope):
            try container.encode(Kind.oauth, forKey: .kind)
            try container.encode(endpoint, forKey: .endpoint)
            try container.encode(tokenEndpoint, forKey: .tokenEndpoint)
            try container.encode(clientID, forKey: .clientID)
            try container.encode(clientSecret, forKey: .clientSecret)
            try container.encodeIfPresent(scope, forKey: .scope)
        }
    }

}
