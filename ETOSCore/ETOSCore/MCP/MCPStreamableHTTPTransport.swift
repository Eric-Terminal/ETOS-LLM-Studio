// ============================================================================
// MCPStreamableHTTPTransport.swift
// ============================================================================
// ETOS LLM Studio
//
// MCP Streamable HTTP 传输入口，负责对外暴露 POST 请求、SSE 连接、
// 协议版本更新与会话终止能力。
// ============================================================================

import Foundation
import os.log

let streamableLogger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "MCPStreamableHTTPTransport")

let mcpSessionHeader = "MCP-Session-Id"
let mcpProtocolHeader = "MCP-Protocol-Version"
let mcpResumptionHeader = "Last-Event-ID"

typealias StreamableHTTPResponseExecutor = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

public final class MCPStreamableHTTPTransport: MCPTransport, MCPStreamingTransportProtocol, MCPProtocolVersionConfigurableTransport, MCPResumptionControllableTransport, @unchecked Sendable {
    let endpoint: URL
    let session: URLSession
    let headers: [String: String]
    var protocolVersion: String?
    let dynamicHeadersProvider: (@Sendable () async throws -> [String: String])?
    let responseExecutor: StreamableHTTPResponseExecutor?
    let sseReconnectMaxAttempts = MCPRuntimeDefaults.maxRetryAttempts
    let sseReconnectBaseDelay: TimeInterval = 1.0
    let sseReconnectMaxDelay: TimeInterval = 30.0
    let sseSuspensionInterval: TimeInterval = 15.0

    let pendingRequestsActor = StreamablePendingRequestsActor()
    var sseTask: Task<Void, Never>?
    var sessionId: String?
    var lastEventId: String?
    var sseReconnectAttempt = 0
    var isSSEEnabled = true
    var sseSuspendedUntil: Date?
    var sseEventName: String?
    var sseEventId: String?
    var sseDataLines: [String] = []

    public weak var notificationDelegate: MCPNotificationDelegate?
    public weak var samplingHandler: MCPSamplingHandler?
    public weak var elicitationHandler: MCPElicitationHandler?

    public init(
        endpoint: URL,
        session: URLSession = NetworkSessionConfiguration.shared,
        headers: [String: String] = [:],
        protocolVersion: String? = MCPProtocolVersion.current,
        dynamicHeadersProvider: (@Sendable () async throws -> [String: String])? = nil
    ) {
        self.endpoint = endpoint
        self.session = session
        self.headers = headers
        self.protocolVersion = protocolVersion
        self.dynamicHeadersProvider = dynamicHeadersProvider
        self.responseExecutor = nil
    }

    init(
        endpoint: URL,
        session: URLSession = NetworkSessionConfiguration.shared,
        headers: [String: String] = [:],
        protocolVersion: String? = MCPProtocolVersion.current,
        dynamicHeadersProvider: (@Sendable () async throws -> [String: String])? = nil,
        responseExecutor: StreamableHTTPResponseExecutor?
    ) {
        self.endpoint = endpoint
        self.session = session
        self.headers = headers
        self.protocolVersion = protocolVersion
        self.dynamicHeadersProvider = dynamicHeadersProvider
        self.responseExecutor = responseExecutor
    }

    deinit {
        disconnect()
    }

    // MARK: - MCPTransport

    public func sendMessage(_ payload: Data) async throws -> Data {
        let requestId = try extractRequestId(from: payload)

        return try await withCheckedThrowingContinuation { continuation in
            Task {
                await pendingRequestsActor.add(id: requestId, continuation: continuation)
                do {
                    try await postMessage(payload, requestId: requestId)
                } catch {
                    let pending = await pendingRequestsActor.remove(id: requestId)
                    pending?.resume(throwing: error)
                }
            }
        }
    }

    public func sendNotification(_ payload: Data) async throws {
        try await postMessage(payload, requestId: nil)
    }

    // MARK: - Streaming

    public func connectStream() {
        guard resumeSSEProbeIfNeeded(force: false, reason: "connectStream") else {
            if let suspendedUntil = sseSuspendedUntil {
                let remaining = max(0, suspendedUntil.timeIntervalSinceNow)
                streamableLogger.info("SSE 当前处于降级挂起状态，\(remaining, privacy: .public)s 后重试。")
            } else {
                streamableLogger.info("SSE 当前处于降级挂起状态，跳过连接。")
            }
            return
        }
        guard sseTask == nil else { return }
        sseTask = Task { [weak self] in
            guard let self else { return }
            await self.runSSELoop()
        }
    }

    public func disconnect() {
        disconnectStream()
        let pendingActor = pendingRequestsActor
        let previousSessionId = snapshotAndClearSession()
        let endpoint = self.endpoint
        let session = self.session
        let staticHeaders = self.headers
        let dynamicHeadersProvider = self.dynamicHeadersProvider
        let protocolVersion = self.protocolVersion
        let responseExecutor = self.responseExecutor
        Task {
            let dynamicHeaders = try? await dynamicHeadersProvider?()
            if let sessionId = previousSessionId {
                await Self.terminateRemoteSession(
                    session: session,
                    endpoint: endpoint,
                    headers: staticHeaders,
                    dynamicHeaders: dynamicHeaders ?? [:],
                    protocolVersion: protocolVersion,
                    sessionId: sessionId,
                    responseExecutor: responseExecutor
                )
            }
            let pending = await pendingActor.removeAll()
            for continuation in pending {
                continuation.resume(throwing: CancellationError())
            }
        }
    }

    public func updateProtocolVersion(_ protocolVersion: String?) async {
        self.protocolVersion = protocolVersion
    }

    public func currentResumptionToken() async -> String? {
        let trimmed = lastEventId?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            return trimmed
        }
        return nil
    }

    public func updateResumptionToken(_ token: String?) async {
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        lastEventId = (trimmed?.isEmpty == false) ? trimmed : nil
    }

    public func terminateSession() async {
        disconnectStream()
        let previousSessionId = snapshotAndClearSession()
        guard let previousSessionId else { return }
        await terminateSession(with: previousSessionId)
    }
}
