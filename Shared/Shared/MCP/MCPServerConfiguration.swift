// ============================================================================
// MCPServerConfiguration.swift
// ============================================================================
// 用于描述和序列化 MCP Server 的连接配置。
// ============================================================================

import Foundation

public struct MCPServerConfiguration: Codable, Identifiable, Hashable {
    public enum Transport: Codable, Hashable {
        case http(endpoint: URL, apiKey: String?, additionalHeaders: [String: String])
        case httpSSE(endpoint: URL, apiKey: String?, additionalHeaders: [String: String])
        case oauth(endpoint: URL, tokenEndpoint: URL, clientID: String, clientSecret: String, scope: String?)
    }

    public var id: UUID
    public var displayName: String
    public var notes: String?
    public var transport: Transport

    public init(
        id: UUID = UUID(),
        displayName: String,
        notes: String? = nil,
        transport: Transport
    ) {
        self.id = id
        self.displayName = displayName
        self.notes = notes
        self.transport = transport
    }
}

public extension MCPServerConfiguration {
    var humanReadableEndpoint: String {
        switch transport {
        case .http(let endpoint, _, _):
            return endpoint.absoluteString
        case .httpSSE(let endpoint, _, _):
            return endpoint.absoluteString
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
            return MCPHTTPTransport(endpoint: endpoint, session: urlSession, headers: headers)
        case .httpSSE(let endpoint, let apiKey, let additionalHeaders):
            var headers = additionalHeaders
            if let apiKey, !apiKey.isEmpty {
                headers["Authorization"] = "Bearer \(apiKey)"
            }
            return MCPSSETransport(endpoint: endpoint, session: urlSession, headers: headers)
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

extension MCPServerConfiguration.Transport {
    private enum CodingKeys: String, CodingKey {
        case kind
        case endpoint
        case apiKey
        case additionalHeaders
        case tokenEndpoint
        case clientID
        case clientSecret
        case scope
    }

    private enum Kind: String, Codable {
        case http
        case httpSSE
        case oauth
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .http:
            let endpoint = try container.decode(URL.self, forKey: .endpoint)
            let apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey)
            let headers = try container.decodeIfPresent([String: String].self, forKey: .additionalHeaders) ?? [:]
            self = .http(endpoint: endpoint, apiKey: apiKey, additionalHeaders: headers)
        case .httpSSE:
            let endpoint = try container.decode(URL.self, forKey: .endpoint)
            let apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey)
            let headers = try container.decodeIfPresent([String: String].self, forKey: .additionalHeaders) ?? [:]
            self = .httpSSE(endpoint: endpoint, apiKey: apiKey, additionalHeaders: headers)
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
            try container.encode(Kind.http, forKey: .kind)
            try container.encode(endpoint, forKey: .endpoint)
            try container.encodeIfPresent(apiKey, forKey: .apiKey)
            if !headers.isEmpty {
                try container.encode(headers, forKey: .additionalHeaders)
            }
        case .httpSSE(let endpoint, let apiKey, let headers):
            try container.encode(Kind.httpSSE, forKey: .kind)
            try container.encode(endpoint, forKey: .endpoint)
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
