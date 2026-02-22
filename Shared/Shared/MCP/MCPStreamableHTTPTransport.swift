// ============================================================================
// MCPStreamableHTTPTransport.swift
// ============================================================================
// Streamable HTTP transport for MCP: POST for requests, optional GET SSE for
// streaming responses/notifications.
// ============================================================================

import Foundation
import os.log

private let streamableLogger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "MCPStreamableHTTPTransport")

private let mcpSessionHeader = "MCP-Session-Id"
private let mcpProtocolHeader = "MCP-Protocol-Version"
private let mcpResumptionHeader = "Last-Event-ID"

public final class MCPStreamableHTTPTransport: MCPTransport, MCPStreamingTransportProtocol, @unchecked Sendable {
    private let endpoint: URL
    private let session: URLSession
    private let headers: [String: String]
    private let protocolVersion: String?
    private let sseReconnectMaxAttempts = 5
    private let sseReconnectBaseDelay: TimeInterval = 1.0
    private let sseReconnectMaxDelay: TimeInterval = 30.0

    private let pendingRequestsActor = StreamablePendingRequestsActor()
    private var sseTask: Task<Void, Never>?
    private var sessionId: String?
    private var lastEventId: String?
    private var sseReconnectAttempt = 0
    private var isSSEEnabled = true

    public weak var notificationDelegate: MCPNotificationDelegate?
    public weak var samplingHandler: MCPSamplingHandler?
    public weak var elicitationHandler: MCPElicitationHandler?

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

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

    deinit {
        disconnect()
    }

    // MARK: - MCPTransport

    public func sendMessage(_ payload: Data) async throws -> Data {
        let requestId = try extractRequestId(from: payload)
        if sseTask == nil, isSSEEnabled {
            connectStream()
        }

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
        guard isSSEEnabled else {
            streamableLogger.info("SSE 已被服务端禁用，跳过连接。")
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
        let headers = self.headers
        let protocolVersion = self.protocolVersion
        Task {
            if let sessionId = previousSessionId {
                await Self.terminateRemoteSession(
                    session: session,
                    endpoint: endpoint,
                    headers: headers,
                    protocolVersion: protocolVersion,
                    sessionId: sessionId
                )
            }
            let pending = await pendingActor.removeAll()
            for continuation in pending {
                continuation.resume(throwing: CancellationError())
            }
        }
    }

    private func disconnectStream() {
        sseTask?.cancel()
        sseTask = nil
    }

    // MARK: - HTTP + SSE Implementation

    private func postMessage(_ payload: Data, requestId: JSONRPCID?) async throws {
        let notificationMethod = requestId == nil ? extractNotificationMethod(from: payload) : nil
        var didRetryForMissingSession = false

        while true {
            let appliedSessionId = currentAppliedSessionId()

            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.httpBody = payload
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
            applyHeaders(to: &request, includeResumption: false)

            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw MCPClientError.invalidResponse
            }

            if let serverSession = httpResponse.value(forHTTPHeaderField: mcpSessionHeader),
               !serverSession.isEmpty {
                sessionId = serverSession
            }

            if httpResponse.statusCode == 404,
               let staleSessionId = appliedSessionId,
               !didRetryForMissingSession {
                didRetryForMissingSession = true
                resetSessionAfterNotFound(previousSessionId: staleSessionId)
                continue
            }

            guard (200..<300).contains(httpResponse.statusCode) else {
                let message = String(data: data, encoding: .utf8)
                throw MCPTransportError.httpStatus(code: httpResponse.statusCode, body: message)
            }

            // 202: response will come via SSE stream
            if httpResponse.statusCode == 202 {
                if let requestId {
                    guard isSSEEnabled else {
                        throw MCPClientError.invalidResponse
                    }
                    await pendingRequestsActor.markAwaitingSSE(id: requestId)
                    if sseTask == nil {
                        connectStream()
                    }
                } else if notificationMethod == "notifications/initialized", isSSEEnabled, sseTask == nil {
                    // 初始化后异步建立 SSE，会和官方 SDK 行为保持一致。
                    connectStream()
                }
                return
            }

            let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
            if contentType.contains("text/event-stream") {
                await handleInlineSSE(data)
                return
            }

            guard let requestId else { return }
            guard !data.isEmpty else {
                let pending = await pendingRequestsActor.remove(id: requestId)
                pending?.resume(throwing: MCPClientError.invalidResponse)
                return
            }
            let pending = await pendingRequestsActor.remove(id: requestId)
            pending?.resume(returning: data)
            return
        }
    }

    private func runSSELoop() async {
        defer { sseTask = nil }
        while !Task.isCancelled {
            let appliedSessionId = currentAppliedSessionId()
            var request = URLRequest(url: endpoint)
            request.httpMethod = "GET"
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            request.timeoutInterval = .infinity
            applyHeaders(to: &request, includeResumption: true)

            do {
                let (bytes, response) = try await session.bytes(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw MCPClientError.invalidResponse
                }

                if let serverSession = httpResponse.value(forHTTPHeaderField: mcpSessionHeader),
                   !serverSession.isEmpty {
                    sessionId = serverSession
                }

                if httpResponse.statusCode == 405 {
                    await disableSSEMode(reason: "Streamable HTTP GET/SSE not supported (405).")
                    return
                }

                if httpResponse.statusCode == 404,
                   let staleSessionId = appliedSessionId {
                    resetSessionAfterNotFound(previousSessionId: staleSessionId)
                    continue
                }

                let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
                if contentType.contains("application/json") {
                    await disableSSEMode(reason: "Streamable HTTP SSE disabled (application/json response).")
                    return
                }

                guard (200..<300).contains(httpResponse.statusCode) else {
                    streamableLogger.error("Streamable HTTP SSE failed: \(httpResponse.statusCode)")
                    guard await scheduleSSEReconnectIfNeeded() else { return }
                    continue
                }

                sseReconnectAttempt = 0

                for try await line in bytes.lines {
                    if Task.isCancelled { break }
                    await consumeSSELine(line)
                }

                if Task.isCancelled {
                    return
                }

                streamableLogger.info("Streamable HTTP SSE stream closed by peer, scheduling reconnect.")
                guard await scheduleSSEReconnectIfNeeded() else { return }
            } catch {
                if Task.isCancelled {
                    return
                }
                streamableLogger.error("Streamable HTTP SSE error: \(error.localizedDescription)")
                guard await scheduleSSEReconnectIfNeeded() else { return }
            }
        }
    }

    private var sseEventName: String?
    private var sseEventId: String?
    private var sseDataLines: [String] = []

    private func consumeSSELine(_ line: String) async {
        if line.isEmpty {
            if !sseDataLines.isEmpty {
                let data = sseDataLines.joined(separator: "\n")
                await handleSSEEvent(name: sseEventName, data: data, id: sseEventId)
            }
            sseEventName = nil
            sseEventId = nil
            sseDataLines = []
            return
        }

        if line.hasPrefix(":") {
            return
        }
        if line.hasPrefix("event:") {
            sseEventName = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            return
        }
        if line.hasPrefix("id:") {
            sseEventId = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            return
        }
        if line.hasPrefix("data:") {
            let data = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            if data != "[DONE]" {
                sseDataLines.append(data)
            }
        }
    }

    private func handleInlineSSE(_ data: Data) async {
        let events = parseSSEEvents(from: data)
        for event in events {
            await handleSSEEvent(name: event.name, data: event.data, id: event.id)
        }
    }

    private func handleSSEEvent(name: String?, data: String, id: String?) async {
        if let id, !id.isEmpty {
            lastEventId = id
        }
        if name == "session" || name == "sessionId" {
            let trimmed = data.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                sessionId = trimmed
            }
            return
        }
        if name == "error" {
            streamableLogger.error("Streamable HTTP SSE error event: \(data, privacy: .public)")
            return
        }
        await processSSEPayload(data)
    }

    private func processSSEPayload(_ data: String) async {
        guard let jsonData = data.data(using: .utf8) else { return }

        if let notification = try? decoder.decode(MCPNotification.self, from: jsonData) {
            await handleNotification(notification)
            return
        }

        if let requestEnvelope = try? decoder.decode(JSONRPCRequestMethodEnvelope.self, from: jsonData) {
            switch requestEnvelope.method {
            case "sampling/createMessage":
                if let samplingRequest = try? decoder.decode(MCPServerSamplingRequest.self, from: jsonData) {
                    await handleSamplingRequest(samplingRequest)
                } else if let requestID = requestEnvelope.id {
                    await sendErrorResponse(requestId: requestID, code: -32602, message: "Sampling 请求参数无效")
                }
                return
            case "elicitation/create":
                if let elicitationRequest = try? decoder.decode(MCPServerElicitationRequest.self, from: jsonData) {
                    await handleElicitationRequest(elicitationRequest)
                } else if let requestID = requestEnvelope.id {
                    await sendErrorResponse(requestId: requestID, code: -32602, message: "Elicitation 请求参数无效")
                }
                return
            default:
                break
            }
        }

        if let response = try? decoder.decode(JSONRPCResponseWrapper.self, from: jsonData),
           let id = response.id {
            let continuation = await pendingRequestsActor.remove(id: id)
            continuation?.resume(returning: jsonData)
        }
    }

    private func handleNotification(_ notification: MCPNotification) async {
        if notification.method == MCPNotificationType.logMessage.rawValue,
           let params = notification.params,
           let logEntry = try? decodeLogEntry(from: params) {
            await MainActor.run {
                notificationDelegate?.didReceiveLogMessage(logEntry)
            }
            return
        }

        if notification.method == MCPNotificationType.progress.rawValue,
           let params = notification.params,
           let progress = try? decodeProgress(from: params) {
            await MainActor.run {
                notificationDelegate?.didReceiveProgress(progress)
            }
            return
        }

        await MainActor.run {
            notificationDelegate?.didReceiveNotification(notification)
        }
    }

    private func handleSamplingRequest(_ request: MCPServerSamplingRequest) async {
        guard let handler = samplingHandler else {
            streamableLogger.warning("收到 Sampling 请求但未设置 handler")
            await sendErrorResponse(requestId: request.id, code: -32603, message: "客户端未启用 Sampling 能力")
            return
        }

        do {
            let response = try await handler.handleSamplingRequest(request.params)
            await sendSamplingResponse(requestId: request.id, response: response)
        } catch {
            await sendErrorResponse(requestId: request.id, code: -32603, message: error.localizedDescription)
        }
    }

    private func handleElicitationRequest(_ request: MCPServerElicitationRequest) async {
        guard let handler = elicitationHandler else {
            streamableLogger.info("收到 Elicitation 请求但未设置 handler，返回 decline")
            await sendElicitationResponse(requestId: request.id, response: .declined)
            return
        }

        do {
            let response = try await handler.handleElicitationRequest(request.params)
            await sendElicitationResponse(requestId: request.id, response: response)
        } catch {
            await sendErrorResponse(requestId: request.id, code: -32603, message: error.localizedDescription)
        }
    }

    private func sendSamplingResponse(requestId: JSONRPCID, response: MCPSamplingResponse) async {
        let rpcResponse = JSONRPCSamplingResponse(id: requestId, result: response)
        guard let data = try? encoder.encode(rpcResponse) else { return }

        do {
            try await sendNotification(data)
        } catch {
            streamableLogger.error("发送 Sampling 响应失败: \(error.localizedDescription)")
        }
    }

    private func sendElicitationResponse(requestId: JSONRPCID, response: MCPElicitationResult) async {
        let rpcResponse = JSONRPCElicitationResponse(id: requestId, result: response)
        guard let data = try? encoder.encode(rpcResponse) else { return }

        do {
            try await sendNotification(data)
        } catch {
            streamableLogger.error("发送 Elicitation 响应失败: \(error.localizedDescription)")
        }
    }

    private func sendErrorResponse(requestId: JSONRPCID, code: Int, message: String) async {
        let error = JSONRPCErrorResponse(
            id: requestId,
            error: JSONRPCErrorBody(code: code, message: message)
        )
        guard let data = try? encoder.encode(error) else { return }

        do {
            try await sendNotification(data)
        } catch {
            streamableLogger.error("发送 RPC 错误响应失败: \(error.localizedDescription)")
        }
    }

    private func decodeLogEntry(from value: JSONValue) throws -> MCPLogEntry {
        let data = try encoder.encode(value)
        return try decoder.decode(MCPLogEntry.self, from: data)
    }

    private func decodeProgress(from value: JSONValue) throws -> MCPProgressParams {
        let data = try encoder.encode(value)
        return try decoder.decode(MCPProgressParams.self, from: data)
    }

    private func applyHeaders(to request: inout URLRequest, includeResumption: Bool) {
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if let sessionId, !sessionId.isEmpty, !Self.hasHeader(mcpSessionHeader, in: headers) {
            request.setValue(sessionId, forHTTPHeaderField: mcpSessionHeader)
        }
        if let protocolVersion, !protocolVersion.isEmpty, !Self.hasHeader(mcpProtocolHeader, in: headers) {
            request.setValue(protocolVersion, forHTTPHeaderField: mcpProtocolHeader)
        }
        if includeResumption, let lastEventId, !lastEventId.isEmpty {
            request.setValue(lastEventId, forHTTPHeaderField: mcpResumptionHeader)
        }
    }

    private func disableSSEMode(reason: String) async {
        guard isSSEEnabled else { return }
        isSSEEnabled = false
        sseReconnectAttempt = 0
        streamableLogger.info("\(reason, privacy: .public)")
        await pendingRequestsActor.failAwaitingSSE()
    }

    private func scheduleSSEReconnectIfNeeded() async -> Bool {
        guard isSSEEnabled else { return false }

        let nextAttempt = sseReconnectAttempt + 1
        guard nextAttempt <= sseReconnectMaxAttempts else {
            streamableLogger.error("Streamable HTTP SSE reconnect exhausted at \(nextAttempt - 1) attempts.")
            isSSEEnabled = false
            await pendingRequestsActor.failAwaitingSSE()
            return false
        }

        sseReconnectAttempt = nextAttempt
        let exponent = max(0, nextAttempt - 1)
        let delay = min(sseReconnectBaseDelay * pow(2.0, Double(exponent)), sseReconnectMaxDelay)
        streamableLogger.info("Streamable HTTP SSE reconnect attempt=\(nextAttempt), delay=\(delay, privacy: .public)s")

        let nanos = UInt64(delay * 1_000_000_000)
        do {
            try await Task.sleep(nanoseconds: nanos)
        } catch {
            return false
        }
        return !Task.isCancelled && isSSEEnabled
    }

    private static func hasHeader(_ name: String, in headers: [String: String]) -> Bool {
        headers.keys.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    private func currentAppliedSessionId() -> String? {
        guard !Self.hasHeader(mcpSessionHeader, in: headers),
              let sessionId,
              !sessionId.isEmpty else {
            return nil
        }
        return sessionId
    }

    private func resetSessionAfterNotFound(previousSessionId: String) {
        if sessionId == previousSessionId {
            sessionId = nil
        }
        lastEventId = nil
        sseReconnectAttempt = 0
        streamableLogger.info("Streamable HTTP session 已失效（404），将清理本地会话并重建。")
    }

    private func snapshotAndClearSession() -> String? {
        let previousSessionId = sessionId
        sessionId = nil
        lastEventId = nil
        return previousSessionId
    }

    private static func terminateRemoteSession(
        session: URLSession,
        endpoint: URL,
        headers: [String: String],
        protocolVersion: String?,
        sessionId: String
    ) async {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if !Self.hasHeader(mcpSessionHeader, in: headers) {
            request.setValue(sessionId, forHTTPHeaderField: mcpSessionHeader)
        }
        if let protocolVersion, !protocolVersion.isEmpty, !Self.hasHeader(mcpProtocolHeader, in: headers) {
            request.setValue(protocolVersion, forHTTPHeaderField: mcpProtocolHeader)
        }

        do {
            let (_, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                streamableLogger.error("会话终止请求返回了无效响应。")
                return
            }
            if !(200..<300).contains(httpResponse.statusCode) && httpResponse.statusCode != 405 {
                streamableLogger.error("会话终止请求失败：status=\(httpResponse.statusCode)")
            }
        } catch {
            streamableLogger.error("会话终止请求失败：\(error.localizedDescription)")
        }
    }

    private func extractRequestId(from payload: Data) throws -> JSONRPCID {
        if let request = try? decoder.decode(JSONRPCRequestEnvelope.self, from: payload) {
            return request.id
        }
        throw MCPClientError.invalidResponse
    }

    private func extractNotificationMethod(from payload: Data) -> String? {
        (try? decoder.decode(JSONRPCNotificationEnvelope.self, from: payload))?.method
    }

    private func parseSSEEvents(from data: Data) -> [SSEEvent] {
        guard let raw = String(data: data, encoding: .utf8) else { return [] }
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
        let blocks = normalized.components(separatedBy: "\n\n")
        var events: [SSEEvent] = []
        for block in blocks {
            var eventName: String?
            var eventId: String?
            var dataLines: [String] = []
            for lineSub in block.split(separator: "\n") {
                let line = lineSub.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty else { continue }
                if line.hasPrefix(":") { continue }
                if line.hasPrefix("event:") {
                    eventName = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                    continue
                }
                if line.hasPrefix("id:") {
                    eventId = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    continue
                }
                if line.hasPrefix("data:") {
                    let data = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                    if data != "[DONE]" {
                        dataLines.append(data)
                    }
                }
            }
            let payload = dataLines.joined(separator: "\n")
            if !payload.isEmpty {
                events.append(SSEEvent(id: eventId, name: eventName, data: payload))
            }
        }
        return events
    }
}

private struct SSEEvent {
    let id: String?
    let name: String?
    let data: String
}

private actor StreamablePendingRequestsActor {
    private var requests: [JSONRPCID: CheckedContinuation<Data, Error>] = [:]
    private var awaitingSSE: Set<JSONRPCID> = []

    func add(id: JSONRPCID, continuation: CheckedContinuation<Data, Error>) {
        requests[id] = continuation
    }

    func markAwaitingSSE(id: JSONRPCID) {
        awaitingSSE.insert(id)
    }

    func remove(id: JSONRPCID) -> CheckedContinuation<Data, Error>? {
        awaitingSSE.remove(id)
        return requests.removeValue(forKey: id)
    }

    func failAwaitingSSE() {
        let targets = awaitingSSE
        awaitingSSE.removeAll()
        for id in targets {
            if let continuation = requests.removeValue(forKey: id) {
                continuation.resume(throwing: MCPClientError.invalidResponse)
            }
        }
    }

    func removeAll() -> [CheckedContinuation<Data, Error>] {
        let all = Array(requests.values)
        requests.removeAll()
        awaitingSSE.removeAll()
        return all
    }
}

private struct JSONRPCRequestEnvelope: Decodable {
    let id: JSONRPCID
}

private struct JSONRPCNotificationEnvelope: Decodable {
    let method: String
}

private struct JSONRPCRequestMethodEnvelope: Decodable {
    let id: JSONRPCID?
    let method: String
}

private struct MCPServerSamplingRequest: Codable {
    let jsonrpc: String
    let id: JSONRPCID
    let method: String
    let params: MCPSamplingRequest
}

private struct MCPServerElicitationRequest: Codable {
    let jsonrpc: String
    let id: JSONRPCID
    let method: String
    let params: MCPElicitationRequest
}

private struct JSONRPCResponseWrapper: Codable {
    let jsonrpc: String
    let id: JSONRPCID?
}

private struct JSONRPCSamplingResponse: Encodable {
    let jsonrpc: String
    let id: JSONRPCID
    let result: MCPSamplingResponse

    init(id: JSONRPCID, result: MCPSamplingResponse) {
        self.jsonrpc = "2.0"
        self.id = id
        self.result = result
    }
}

private struct JSONRPCElicitationResponse: Encodable {
    let jsonrpc: String
    let id: JSONRPCID
    let result: MCPElicitationResult

    init(id: JSONRPCID, result: MCPElicitationResult) {
        self.jsonrpc = "2.0"
        self.id = id
        self.result = result
    }
}

private struct JSONRPCErrorResponse: Encodable {
    let jsonrpc: String
    let id: JSONRPCID
    let error: JSONRPCErrorBody

    init(id: JSONRPCID, error: JSONRPCErrorBody) {
        self.jsonrpc = "2.0"
        self.id = id
        self.error = error
    }
}

private struct JSONRPCErrorBody: Codable {
    let code: Int
    let message: String
}
