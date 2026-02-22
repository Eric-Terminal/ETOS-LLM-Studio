// ============================================================================
// MCPTransport.swift
// ============================================================================
// 实现 MCP 客户端可用的传输层。
// 目前仅支持 HTTP(S)，因为 iOS/watchOS 无法通过 stdio 启动外部进程。
// ============================================================================

import Foundation

public protocol MCPTransport: AnyObject, Sendable {
    func sendMessage(_ payload: Data) async throws -> Data
    /// 发送不需要响应的通知（JSON-RPC Notification）
    func sendNotification(_ payload: Data) async throws
}

/// 支持在 initialize 协商后动态更新协议版本的传输层。
public protocol MCPProtocolVersionConfigurableTransport: AnyObject, Sendable {
    func updateProtocolVersion(_ protocolVersion: String?) async
}

public extension MCPProtocolVersionConfigurableTransport {
    func updateProtocolVersion(_ protocolVersion: String?) async {}
}

/// 支持流式会话恢复令牌与远端会话显式终止的传输层能力。
public protocol MCPResumptionControllableTransport: AnyObject, Sendable {
    func currentResumptionToken() async -> String?
    func updateResumptionToken(_ token: String?) async
    func terminateSession() async
}

public extension MCPResumptionControllableTransport {
    func currentResumptionToken() async -> String? { nil }
    func updateResumptionToken(_ token: String?) async {}
    func terminateSession() async {}
}

public enum MCPTransportError: LocalizedError {
    case httpStatus(code: Int, body: String?)
    case oauthConfiguration(message: String)

    public var errorDescription: String? {
        switch self {
        case .httpStatus(let code, let body):
            if let body, !body.isEmpty {
                return "HTTP \(code): \(body)"
            } else {
                return "HTTP \(code): 服务器返回错误"
            }
        case .oauthConfiguration(let message):
            return "OAuth 配置错误：\(message)"
        }
    }
}

public final class MCPHTTPTransport: MCPTransport, MCPProtocolVersionConfigurableTransport, @unchecked Sendable {
    private let endpoint: URL
    private let session: URLSession
    private let headers: [String: String]
    private var protocolVersion: String?

    public init(
        endpoint: URL,
        session: URLSession = .shared,
        headers: [String: String] = [:],
        protocolVersion: String? = MCPProtocolVersion.current
    ) {
        self.endpoint = endpoint
        self.session = session
        self.headers = headers
        self.protocolVersion = protocolVersion
    }

    public func sendMessage(_ payload: Data) async throws -> Data {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = payload
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if let protocolVersion, !protocolVersion.isEmpty, !Self.hasHeader("MCP-Protocol-Version", in: headers) {
            request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
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
        if let protocolVersion, !protocolVersion.isEmpty, !Self.hasHeader("MCP-Protocol-Version", in: headers) {
            request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
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

    public func updateProtocolVersion(_ protocolVersion: String?) async {
        self.protocolVersion = protocolVersion
    }

    private static func hasHeader(_ name: String, in headers: [String: String]) -> Bool {
        headers.keys.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }
}

public final class MCPSSETransport: MCPTransport, MCPProtocolVersionConfigurableTransport, @unchecked Sendable {
    private let endpoint: URL
    private let session: URLSession
    private let headers: [String: String]
    private var protocolVersion: String?

    public init(
        endpoint: URL,
        session: URLSession = .shared,
        headers: [String: String] = [:],
        protocolVersion: String? = MCPProtocolVersion.current
    ) {
        self.endpoint = endpoint
        self.session = session
        self.headers = headers
        self.protocolVersion = protocolVersion
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
        if let protocolVersion, !protocolVersion.isEmpty, !Self.hasHeader("MCP-Protocol-Version", in: headers) {
            request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
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
        if let protocolVersion, !protocolVersion.isEmpty, !Self.hasHeader("MCP-Protocol-Version", in: headers) {
            request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
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

    public func updateProtocolVersion(_ protocolVersion: String?) async {
        self.protocolVersion = protocolVersion
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

    private static func hasHeader(_ name: String, in headers: [String: String]) -> Bool {
        headers.keys.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }
}

public actor MCPOAuthHTTPTransport: MCPTransport, MCPProtocolVersionConfigurableTransport {
    private let endpoint: URL
    private let tokenEndpoint: URL
    private let clientID: String
    private let clientSecret: String?
    private let scope: String?
    private let grantType: MCPOAuthGrantType
    private let authorizationCode: String?
    private let redirectURI: String?
    private let codeVerifier: String?
    private let session: URLSession
    private var protocolVersion: String?
    private var cachedToken: OAuthToken?

    struct OAuthToken {
        let value: String
        let expiry: Date
        let refreshToken: String?

        var isValid: Bool {
            Date() < expiry
        }
    }

    public init(
        endpoint: URL,
        tokenEndpoint: URL,
        clientID: String,
        clientSecret: String?,
        scope: String?,
        grantType: MCPOAuthGrantType = .clientCredentials,
        authorizationCode: String? = nil,
        redirectURI: String? = nil,
        codeVerifier: String? = nil,
        protocolVersion: String? = MCPProtocolVersion.current,
        session: URLSession = .shared
    ) {
        self.endpoint = endpoint
        self.tokenEndpoint = tokenEndpoint
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.scope = scope
        self.grantType = grantType
        self.authorizationCode = authorizationCode
        self.redirectURI = redirectURI
        self.codeVerifier = codeVerifier
        self.protocolVersion = protocolVersion
        self.session = session
    }

    public func sendMessage(_ payload: Data) async throws -> Data {
        let token = try await validToken()
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = payload
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token.value)", forHTTPHeaderField: "Authorization")
        if let protocolVersion, !protocolVersion.isEmpty {
            request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
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
        let token = try await validToken()
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = payload
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token.value)", forHTTPHeaderField: "Authorization")
        if let protocolVersion, !protocolVersion.isEmpty {
            request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
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

    public func authorizationHeaders() async throws -> [String: String] {
        let token = try await validToken()
        return ["Authorization": "Bearer \(token.value)"]
    }

    public func updateProtocolVersion(_ protocolVersion: String?) async {
        self.protocolVersion = protocolVersion
    }

    private func validToken() async throws -> OAuthToken {
        if let cachedToken, cachedToken.isValid {
            return cachedToken
        }

        if let refreshToken = cachedToken?.refreshToken,
           !refreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let refreshedToken = try? await fetchToken(grant: .refreshToken(refreshToken)) {
            cachedToken = refreshedToken
            return refreshedToken
        }

        let newToken = try await fetchToken(grant: .initial)
        cachedToken = newToken
        return newToken
    }

    private enum OAuthTokenGrant {
        case initial
        case refreshToken(String)
    }

    private func fetchToken(grant: OAuthTokenGrant) async throws -> OAuthToken {
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var components = URLComponents()
        var queryItems: [URLQueryItem] = []

        switch grant {
        case .initial:
            switch grantType {
            case .clientCredentials:
                queryItems.append(URLQueryItem(name: "grant_type", value: "client_credentials"))
            case .authorizationCode:
                guard let resolvedCode = normalized(authorizationCode), !resolvedCode.isEmpty else {
                    throw MCPTransportError.oauthConfiguration(message: "授权码模式缺少 authorizationCode。")
                }
                guard let resolvedRedirectURI = normalized(redirectURI), !resolvedRedirectURI.isEmpty else {
                    throw MCPTransportError.oauthConfiguration(message: "授权码模式缺少 redirectURI。")
                }
                queryItems.append(URLQueryItem(name: "grant_type", value: "authorization_code"))
                queryItems.append(URLQueryItem(name: "code", value: resolvedCode))
                queryItems.append(URLQueryItem(name: "redirect_uri", value: resolvedRedirectURI))
                if let verifier = normalized(codeVerifier) {
                    queryItems.append(URLQueryItem(name: "code_verifier", value: verifier))
                }
                queryItems.append(URLQueryItem(name: "client_id", value: clientID))
            }
        case .refreshToken(let refreshToken):
            queryItems.append(URLQueryItem(name: "grant_type", value: "refresh_token"))
            queryItems.append(URLQueryItem(name: "refresh_token", value: refreshToken))
            queryItems.append(URLQueryItem(name: "client_id", value: clientID))
        }

        if let scope, !scope.isEmpty {
            queryItems.append(URLQueryItem(name: "scope", value: scope))
        }
        if normalized(clientSecret) == nil,
           !queryItems.contains(where: { $0.name == "client_id" }) {
            queryItems.append(URLQueryItem(name: "client_id", value: clientID))
        }
        components.queryItems = queryItems
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        if let secret = normalized(clientSecret) {
            let credentials = "\(clientID):\(secret)"
            if let encoded = credentials.data(using: .utf8)?.base64EncodedString() {
                request.setValue("Basic \(encoded)", forHTTPHeaderField: "Authorization")
            }
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
            let refresh_token: String?
        }

        let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
        let rawExpiry = decoded.expires_in ?? 3600
        let safeExpiry = max(30, rawExpiry)
        let expires = Date().addingTimeInterval(safeExpiry - 15)
        let refreshToken = normalized(decoded.refresh_token)
        return OAuthToken(value: decoded.access_token, expiry: expires, refreshToken: refreshToken)
    }

    private func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// OAuth + Streamable HTTP 组合传输：
/// - 令牌通过 OAuth actor 动态获取/刷新；
/// - 实际请求与通知流由 MCPStreamableHTTPTransport 处理，以支持服务端通知与进度。
public final class MCPOAuthStreamableHTTPTransport: MCPTransport, MCPStreamingTransportProtocol, MCPProtocolVersionConfigurableTransport, MCPResumptionControllableTransport, @unchecked Sendable {
    private let oauthTransport: MCPOAuthHTTPTransport
    private let streamableTransport: MCPStreamableHTTPTransport

    public var notificationDelegate: MCPNotificationDelegate? {
        get { streamableTransport.notificationDelegate }
        set { streamableTransport.notificationDelegate = newValue }
    }

    public var samplingHandler: MCPSamplingHandler? {
        get { streamableTransport.samplingHandler }
        set { streamableTransport.samplingHandler = newValue }
    }

    public var elicitationHandler: MCPElicitationHandler? {
        get { streamableTransport.elicitationHandler }
        set { streamableTransport.elicitationHandler = newValue }
    }

    public init(
        endpoint: URL,
        tokenEndpoint: URL,
        clientID: String,
        clientSecret: String?,
        scope: String?,
        grantType: MCPOAuthGrantType = .clientCredentials,
        authorizationCode: String? = nil,
        redirectURI: String? = nil,
        codeVerifier: String? = nil,
        session: URLSession = .shared
    ) {
        let initialProtocolVersion = MCPProtocolVersion.current
        let oauthTransport = MCPOAuthHTTPTransport(
            endpoint: endpoint,
            tokenEndpoint: tokenEndpoint,
            clientID: clientID,
            clientSecret: clientSecret,
            scope: scope,
            grantType: grantType,
            authorizationCode: authorizationCode,
            redirectURI: redirectURI,
            codeVerifier: codeVerifier,
            protocolVersion: initialProtocolVersion,
            session: session
        )
        self.oauthTransport = oauthTransport
        self.streamableTransport = MCPStreamableHTTPTransport(
            endpoint: endpoint,
            session: session,
            headers: [:],
            protocolVersion: initialProtocolVersion,
            dynamicHeadersProvider: { [oauthTransport] in
                try await oauthTransport.authorizationHeaders()
            }
        )
    }

    public func sendMessage(_ payload: Data) async throws -> Data {
        try await streamableTransport.sendMessage(payload)
    }

    public func sendNotification(_ payload: Data) async throws {
        try await streamableTransport.sendNotification(payload)
    }

    public func connectStream() {
        streamableTransport.connectStream()
    }

    public func disconnect() {
        streamableTransport.disconnect()
    }

    public func updateProtocolVersion(_ protocolVersion: String?) async {
        await oauthTransport.updateProtocolVersion(protocolVersion)
        await streamableTransport.updateProtocolVersion(protocolVersion)
    }

    public func currentResumptionToken() async -> String? {
        await streamableTransport.currentResumptionToken()
    }

    public func updateResumptionToken(_ token: String?) async {
        await streamableTransport.updateResumptionToken(token)
    }

    public func terminateSession() async {
        await streamableTransport.terminateSession()
    }
}
