// ============================================================================
// MCPTransport.swift
// ============================================================================
// 实现 MCP 客户端可用的传输层。
// 目前仅支持 HTTP(S)，因为 iOS/watchOS 无法通过 stdio 启动外部进程。
// ============================================================================

import Foundation

public protocol MCPTransport: AnyObject {
    func sendMessage(_ payload: Data) async throws -> Data
    /// 发送不需要响应的通知（JSON-RPC Notification）
    func sendNotification(_ payload: Data) async throws
}

public enum MCPTransportError: LocalizedError {
    case httpStatus(code: Int, body: String?)

    public var errorDescription: String? {
        switch self {
        case .httpStatus(let code, let body):
            if let body, !body.isEmpty {
                return "HTTP \(code): \(body)"
            } else {
                return "HTTP \(code): 服务器返回错误"
            }
        }
    }
}

public final class MCPHTTPTransport: MCPTransport {
    private let endpoint: URL
    private let session: URLSession
    private let headers: [String: String]

    public init(endpoint: URL, session: URLSession = .shared, headers: [String: String] = [:]) {
        self.endpoint = endpoint
        self.session = session
        self.headers = headers
    }

    public func sendMessage(_ payload: Data) async throws -> Data {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = payload
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MCPClientError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8)
            throw MCPTransportError.httpStatus(code: httpResponse.statusCode, body: message)
        }

        return data
    }

    public func sendNotification(_ payload: Data) async throws {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = payload
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MCPClientError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8)
            throw MCPTransportError.httpStatus(code: httpResponse.statusCode, body: message)
        }
    }
}

public final class MCPSSETransport: MCPTransport {
    private let endpoint: URL
    private let session: URLSession
    private let headers: [String: String]

    public init(endpoint: URL, session: URLSession = .shared, headers: [String: String] = [:]) {
        self.endpoint = endpoint
        self.session = session
        self.headers = headers
    }

    public func sendMessage(_ payload: Data) async throws -> Data {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = payload
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MCPClientError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8)
            throw MCPTransportError.httpStatus(code: httpResponse.statusCode, body: message)
        }

        return try extractLastEvent(from: data)
    }

    public func sendNotification(_ payload: Data) async throws {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = payload
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MCPClientError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8)
            throw MCPTransportError.httpStatus(code: httpResponse.statusCode, body: message)
        }
    }

    private func extractLastEvent(from data: Data) throws -> Data {
        guard let raw = String(data: data, encoding: .utf8) else {
            throw MCPClientError.invalidResponse
        }
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
        let events = normalized.components(separatedBy: "\n\n")
        var payloads: [String] = []
        for event in events {
            var buffer = ""
            event.split(separator: "\n").forEach { line in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.hasPrefix("data:") else { return }
                let content = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
                guard content != "[DONE]" else { return }
                buffer.append(content)
            }
            if !buffer.isEmpty {
                payloads.append(buffer)
            }
        }
        if let last = payloads.last,
           let data = last.data(using: .utf8) {
            return data
        }
        throw MCPClientError.invalidResponse
    }
}

public actor MCPOAuthHTTPTransport: MCPTransport {
    private let endpoint: URL
    private let tokenEndpoint: URL
    private let clientID: String
    private let clientSecret: String
    private let scope: String?
    private let session: URLSession
    private var cachedToken: OAuthToken?

    struct OAuthToken {
        let value: String
        let expiry: Date

        var isValid: Bool {
            Date() < expiry
        }
    }

    public init(endpoint: URL, tokenEndpoint: URL, clientID: String, clientSecret: String, scope: String?, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.tokenEndpoint = tokenEndpoint
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.scope = scope
        self.session = session
    }

    public func sendMessage(_ payload: Data) async throws -> Data {
        let token = try await validToken()
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = payload
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token.value)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MCPClientError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8)
            throw MCPTransportError.httpStatus(code: httpResponse.statusCode, body: message)
        }
        return data
    }

    public func sendNotification(_ payload: Data) async throws {
        let token = try await validToken()
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = payload
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token.value)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MCPClientError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8)
            throw MCPTransportError.httpStatus(code: httpResponse.statusCode, body: message)
        }
    }

    private func validToken() async throws -> OAuthToken {
        if let cachedToken, cachedToken.isValid {
            return cachedToken
        }
        let newToken = try await fetchToken()
        cachedToken = newToken
        return newToken
    }

    private func fetchToken() async throws -> OAuthToken {
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var components = URLComponents()
        var queryItems = [
            URLQueryItem(name: "grant_type", value: "client_credentials")
        ]
        if let scope, !scope.isEmpty {
            queryItems.append(URLQueryItem(name: "scope", value: scope))
        }
        components.queryItems = queryItems
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        let credentials = "\(clientID):\(clientSecret)"
        if let encoded = credentials.data(using: .utf8)?.base64EncodedString() {
            request.setValue("Basic \(encoded)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MCPClientError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8)
            throw MCPTransportError.httpStatus(code: httpResponse.statusCode, body: message)
        }

        struct TokenResponse: Decodable {
            let access_token: String
            let expires_in: Double?
        }

        let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
        let expires = Date().addingTimeInterval((decoded.expires_in ?? 3600) - 30)
        return OAuthToken(value: decoded.access_token, expiry: expires)
    }
}
