// ============================================================================
// MCPSDKTransports.swift
// ============================================================================
// ETOS LLM Studio
//
// 官方 MCP Swift SDK 传输补充：
// - 旧版 HTTP+SSE 兼容桥；
// - Streamable HTTP 会话令牌与显式终止支持；
// - 现有 tokenEndpoint OAuth 配置到官方 HTTPClientTransport 的授权桥。
// ============================================================================

import Foundation
import Logging
import MCP

public protocol MCPSDKTransportControl: AnyObject, Sendable {
    func currentResumptionToken() async -> String?
    func updateResumptionToken(_ token: String?) async
    func updateProtocolVersion(_ protocolVersion: String?) async
    func terminateSession() async
    func disconnect()
}

public final class MCPTransportControlBox: MCPStreamingTransportProtocol, MCPProtocolVersionConfigurableTransport, MCPResumptionControllableTransport, @unchecked Sendable {
    private let control: any MCPSDKTransportControl

    public weak var notificationDelegate: MCPNotificationDelegate?
    public weak var samplingHandler: MCPSamplingHandler?
    public weak var elicitationHandler: MCPElicitationHandler?

    public init(control: any MCPSDKTransportControl) {
        self.control = control
    }

    public func connectStream() {}

    public func disconnect() {
        control.disconnect()
    }

    public func currentResumptionToken() async -> String? {
        await control.currentResumptionToken()
    }

    public func updateResumptionToken(_ token: String?) async {
        await control.updateResumptionToken(token)
    }

    public func updateProtocolVersion(_ protocolVersion: String?) async {
        await control.updateProtocolVersion(protocolVersion)
    }

    public func terminateSession() async {
        await control.terminateSession()
    }
}

public final class MCPLegacySSETransportControlBox: MCPStreamingTransportProtocol, MCPProtocolVersionConfigurableTransport, MCPResumptionControllableTransport, @unchecked Sendable {
    private let sdkTransport: MCPLegacySSESDKTransport
    private let legacyTransport: MCPStreamingTransport

    public var notificationDelegate: MCPNotificationDelegate? {
        get { legacyTransport.notificationDelegate }
        set { legacyTransport.notificationDelegate = newValue }
    }

    public var samplingHandler: MCPSamplingHandler? {
        get { legacyTransport.samplingHandler }
        set { legacyTransport.samplingHandler = newValue }
    }

    public var elicitationHandler: MCPElicitationHandler? {
        get { legacyTransport.elicitationHandler }
        set { legacyTransport.elicitationHandler = newValue }
    }

    public init(sdkTransport: MCPLegacySSESDKTransport, legacyTransport: MCPStreamingTransport) {
        self.sdkTransport = sdkTransport
        self.legacyTransport = legacyTransport
    }

    public func connectStream() {
        legacyTransport.connectStream()
    }

    public func disconnect() {
        sdkTransport.disconnect()
    }

    public func currentResumptionToken() async -> String? {
        await legacyTransport.currentResumptionToken()
    }

    public func updateResumptionToken(_ token: String?) async {
        await legacyTransport.updateResumptionToken(token)
    }

    public func updateProtocolVersion(_ protocolVersion: String?) async {
        await legacyTransport.updateProtocolVersion(protocolVersion)
    }

    public func terminateSession() async {
        await legacyTransport.terminateSession()
    }
}

final class MCPSDKHTTPRequestState: @unchecked Sendable {
    private let headers: [String: String]
    private let lock = NSLock()
    private var resumptionToken: String?

    init(headers: [String: String]) {
        self.headers = headers
    }

    func updateResumptionToken(_ token: String?) {
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.lock()
        resumptionToken = (trimmed?.isEmpty == false) ? trimmed : nil
        lock.unlock()
    }

    func currentResumptionToken() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return resumptionToken
    }

    func requestModifier() -> @Sendable (URLRequest) -> URLRequest {
        { [self] request in
            var request = request
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
            if request.httpMethod == "GET",
               request.value(forHTTPHeaderField: mcpResumptionHeader) == nil,
               let token = currentResumptionToken() {
                request.setValue(token, forHTTPHeaderField: mcpResumptionHeader)
            }
            return request
        }
    }
}

public actor MCPSDKHTTPTransportController: MCPSDKTransportControl {
    private let transport: HTTPClientTransport
    private let requestState: MCPSDKHTTPRequestState
    private let session: URLSession
    private let endpoint: URL
    private let requestModifier: @Sendable (URLRequest) -> URLRequest

    init(
        transport: HTTPClientTransport,
        requestState: MCPSDKHTTPRequestState,
        session: URLSession,
        endpoint: URL,
        requestModifier: @escaping @Sendable (URLRequest) -> URLRequest
    ) {
        self.transport = transport
        self.requestState = requestState
        self.session = session
        self.endpoint = endpoint
        self.requestModifier = requestModifier
    }

    public func currentResumptionToken() async -> String? {
        if let token = await transport.lastEventIDValue() {
            return token
        }
        return requestState.currentResumptionToken()
    }

    public func updateResumptionToken(_ token: String?) async {
        requestState.updateResumptionToken(token)
    }

    public func updateProtocolVersion(_ protocolVersion: String?) async {
        guard let protocolVersion, !protocolVersion.isEmpty else { return }
        await transport.updateNegotiatedProtocolVersion(protocolVersion)
    }

    public func terminateSession() async {
        guard let sessionID = await transport.sessionID else { return }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "DELETE"
        request.setValue(sessionID, forHTTPHeaderField: mcpSessionHeader)
        request = requestModifier(request)
        _ = try? await session.data(for: request)
        await transport.disconnect()
    }

    public nonisolated func disconnect() {
        Task {
            await transport.disconnect()
        }
    }
}

public actor MCPLegacySSESDKTransport: Transport, MCPSDKTransportControl {
    private let legacyTransport: MCPStreamingTransport
    private let loggerInstance: Logger
    private let stream: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private var connected = false

    public nonisolated var logger: Logger { loggerInstance }

    public init(legacyTransport: MCPStreamingTransport) {
        self.legacyTransport = legacyTransport
        self.loggerInstance = Logger(
            label: "etos.mcp.transport.legacy-sse",
            factory: { _ in SwiftLogNoOpLogHandler() }
        )
        var continuation: AsyncThrowingStream<Data, Error>.Continuation!
        self.stream = AsyncThrowingStream { continuation = $0 }
        self.continuation = continuation
    }

    public func connect() async throws {
        guard !connected else { return }
        connected = true
        legacyTransport.connectStream()
    }

    public func disconnect() async {
        guard connected else { return }
        connected = false
        legacyTransport.disconnect()
        continuation.finish()
    }

    public nonisolated func disconnect() {
        Task {
            await self.disconnect()
        }
    }

    public func send(_ data: Data) async throws {
        guard connected else {
            throw MCPClientError.notConnected
        }
        Task {
            do {
                let response = try await legacyTransport.sendMessage(data)
                continuation.yield(response)
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    public func receive() -> AsyncThrowingStream<Data, Error> {
        stream
    }

    public func currentResumptionToken() async -> String? {
        await legacyTransport.currentResumptionToken()
    }

    public func updateResumptionToken(_ token: String?) async {
        await legacyTransport.updateResumptionToken(token)
    }

    public func updateProtocolVersion(_ protocolVersion: String?) async {
        await legacyTransport.updateProtocolVersion(protocolVersion)
    }

    public func terminateSession() async {
        await legacyTransport.terminateSession()
    }
}

public final class MCPOAuthEndpointAuthorizer: HTTPClientAuthorizer, @unchecked Sendable {
    public let maxAuthorizationAttempts: Int = 2

    private let tokenEndpoint: URL
    private let clientID: String
    private let clientSecret: String?
    private let scope: String?
    private let grantType: MCPOAuthGrantType
    private let authorizationCode: String?
    private let redirectURI: String?
    private let codeVerifier: String?
    private let lock = NSLock()
    private var cachedToken: OAuthToken?

    private struct OAuthToken {
        let value: String
        let expiry: Date
        let refreshToken: String?

        var isValid: Bool {
            Date() < expiry
        }
    }

    public init(
        tokenEndpoint: URL,
        clientID: String,
        clientSecret: String?,
        scope: String?,
        grantType: MCPOAuthGrantType,
        authorizationCode: String?,
        redirectURI: String?,
        codeVerifier: String?
    ) {
        self.tokenEndpoint = tokenEndpoint
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.scope = scope
        self.grantType = grantType
        self.authorizationCode = authorizationCode
        self.redirectURI = redirectURI
        self.codeVerifier = codeVerifier
    }

    public func validateEndpointSecurity(for endpoint: URL) throws {}

    public func authorizationHeader(for endpoint: URL) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let cachedToken, cachedToken.isValid else { return nil }
        return "Bearer \(cachedToken.value)"
    }

    public func prepareAuthorization(for endpoint: URL, session: URLSession) async throws {
        _ = try await validToken(session: session)
    }

    public func handleChallenge(
        statusCode: Int,
        headers: [String: String],
        endpoint: URL,
        operationKey: String?,
        session: URLSession
    ) async throws -> Bool {
        clearToken()
        _ = try await validToken(session: session)
        return true
    }

    private func validToken(session: URLSession) async throws -> OAuthToken {
        if let token = currentToken(), token.isValid {
            return token
        }
        if let refreshToken = currentToken()?.refreshToken,
           !refreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let refreshed = try? await fetchToken(grant: .refreshToken(refreshToken), session: session) {
            storeToken(refreshed)
            return refreshed
        }
        let token = try await fetchToken(grant: .initial, session: session)
        storeToken(token)
        return token
    }

    private enum OAuthTokenGrant {
        case initial
        case refreshToken(String)
    }

    private func fetchToken(grant: OAuthTokenGrant, session: URLSession) async throws -> OAuthToken {
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
                guard let code = normalized(authorizationCode) else {
                    throw MCPTransportError.oauthConfiguration(message: "授权码模式缺少 authorizationCode。")
                }
                guard let redirectURI = normalized(redirectURI) else {
                    throw MCPTransportError.oauthConfiguration(message: "授权码模式缺少 redirectURI。")
                }
                queryItems.append(URLQueryItem(name: "grant_type", value: "authorization_code"))
                queryItems.append(URLQueryItem(name: "code", value: code))
                queryItems.append(URLQueryItem(name: "redirect_uri", value: redirectURI))
                queryItems.append(URLQueryItem(name: "client_id", value: clientID))
                if let verifier = normalized(codeVerifier) {
                    queryItems.append(URLQueryItem(name: "code_verifier", value: verifier))
                }
            }
        case .refreshToken(let refreshToken):
            queryItems.append(URLQueryItem(name: "grant_type", value: "refresh_token"))
            queryItems.append(URLQueryItem(name: "refresh_token", value: refreshToken))
            queryItems.append(URLQueryItem(name: "client_id", value: clientID))
        }

        if let scope = normalized(scope) {
            queryItems.append(URLQueryItem(name: "scope", value: scope))
        }
        if normalized(clientSecret) == nil,
           !queryItems.contains(where: { $0.name == "client_id" }) {
            queryItems.append(URLQueryItem(name: "client_id", value: clientID))
        }

        components.queryItems = queryItems
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        if let secret = normalized(clientSecret),
           let encoded = "\(clientID):\(secret)".data(using: .utf8)?.base64EncodedString() {
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
            let refresh_token: String?
        }

        let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
        let safeExpiry = max(30, decoded.expires_in ?? 3600)
        return OAuthToken(
            value: decoded.access_token,
            expiry: Date().addingTimeInterval(safeExpiry - 15),
            refreshToken: normalized(decoded.refresh_token)
        )
    }

    private func currentToken() -> OAuthToken? {
        lock.lock()
        defer { lock.unlock() }
        return cachedToken
    }

    private func storeToken(_ token: OAuthToken) {
        lock.lock()
        cachedToken = token
        lock.unlock()
    }

    private func clearToken() {
        lock.lock()
        cachedToken = nil
        lock.unlock()
    }

    private func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}

extension HTTPClientTransport {
    func lastEventIDValue() -> String? {
        Mirror(reflecting: self).descendant("lastEventID") as? String
    }
}
