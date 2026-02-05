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

    private let pendingRequestsActor = StreamablePendingRequestsActor()
    private var sseTask: Task<Void, Never>?
    private var sessionId: String?
    private var lastEventId: String?

    public weak var notificationDelegate: MCPNotificationDelegate?
    public weak var samplingHandler: MCPSamplingHandler?

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
        if sseTask == nil {
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
        disconnectStream()
        sseTask = Task { [weak self] in
            guard let self else { return }
            await self.runSSELoop()
        }
    }

    public func disconnect() {
        disconnectStream()
        let pendingActor = pendingRequestsActor
        Task {
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

    private func postMessage(_ payload: Data, requestId: String?) async throws {
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

        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8)
            throw MCPTransportError.httpStatus(code: httpResponse.statusCode, body: message)
        }

        // 202: response will come via SSE stream
        if httpResponse.statusCode == 202 {
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
    }

    private func runSSELoop() async {
        defer { sseTask = nil }
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

            if httpResponse.statusCode == 405 {
                streamableLogger.info("Streamable HTTP GET/SSE not supported (405).")
                return
            }

            let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
            if contentType.contains("application/json") {
                streamableLogger.info("Streamable HTTP SSE disabled (application/json response).")
                return
            }

            guard (200..<300).contains(httpResponse.statusCode) else {
                streamableLogger.error("Streamable HTTP SSE failed: \(httpResponse.statusCode)")
                return
            }

            for try await line in bytes.lines {
                if Task.isCancelled { break }
                await consumeSSELine(line)
            }
        } catch {
            if !Task.isCancelled {
                streamableLogger.error("Streamable HTTP SSE error: \(error.localizedDescription)")
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

        if let samplingRequest = try? decoder.decode(MCPServerSamplingRequest.self, from: jsonData) {
            await handleSamplingRequest(samplingRequest)
            return
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
            await sendSamplingError(requestId: request.id, message: "Client does not support sampling")
            return
        }

        do {
            let response = try await handler.handleSamplingRequest(request.params)
            await sendSamplingResponse(requestId: request.id, response: response)
        } catch {
            await sendSamplingError(requestId: request.id, message: error.localizedDescription)
        }
    }

    private func sendSamplingResponse(requestId: String, response: MCPSamplingResponse) async {
        let rpcResponse = JSONRPCSamplingResponse(id: requestId, result: response)
        guard let data = try? encoder.encode(rpcResponse) else { return }

        do {
            try await sendNotification(data)
        } catch {
            streamableLogger.error("发送 Sampling 响应失败: \(error.localizedDescription)")
        }
    }

    private func sendSamplingError(requestId: String, message: String) async {
        let error = JSONRPCErrorResponse(
            id: requestId,
            error: JSONRPCErrorBody(code: -32603, message: message)
        )
        guard let data = try? encoder.encode(error) else { return }

        do {
            try await sendNotification(data)
        } catch {
            streamableLogger.error("发送 Sampling 错误响应失败: \(error.localizedDescription)")
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
        if let sessionId, !sessionId.isEmpty, !hasHeader(mcpSessionHeader, in: headers) {
            request.setValue(sessionId, forHTTPHeaderField: mcpSessionHeader)
        }
        if let protocolVersion, !protocolVersion.isEmpty, !hasHeader(mcpProtocolHeader, in: headers) {
            request.setValue(protocolVersion, forHTTPHeaderField: mcpProtocolHeader)
        }
        if includeResumption, let lastEventId, !lastEventId.isEmpty {
            request.setValue(lastEventId, forHTTPHeaderField: mcpResumptionHeader)
        }
    }

    private func hasHeader(_ name: String, in headers: [String: String]) -> Bool {
        headers.keys.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    private func extractRequestId(from payload: Data) throws -> String {
        if let request = try? decoder.decode(JSONRPCRequestEnvelope.self, from: payload) {
            return request.id
        }
        throw MCPClientError.invalidResponse
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
    private var requests: [String: CheckedContinuation<Data, Error>] = [:]

    func add(id: String, continuation: CheckedContinuation<Data, Error>) {
        requests[id] = continuation
    }

    func remove(id: String) -> CheckedContinuation<Data, Error>? {
        requests.removeValue(forKey: id)
    }

    func removeAll() -> [CheckedContinuation<Data, Error>] {
        let all = Array(requests.values)
        requests.removeAll()
        return all
    }
}

private struct JSONRPCRequestEnvelope: Decodable {
    let id: String
}

private struct MCPServerSamplingRequest: Codable {
    let jsonrpc: String
    let id: String
    let method: String
    let params: MCPSamplingRequest
}

private struct JSONRPCResponseWrapper: Codable {
    let jsonrpc: String
    let id: String?
}

private struct JSONRPCSamplingResponse: Encodable {
    let jsonrpc: String
    let id: String
    let result: MCPSamplingResponse

    init(id: String, result: MCPSamplingResponse) {
        self.jsonrpc = "2.0"
        self.id = id
        self.result = result
    }
}

private struct JSONRPCErrorResponse: Encodable {
    let jsonrpc: String
    let id: String
    let error: JSONRPCErrorBody

    init(id: String, error: JSONRPCErrorBody) {
        self.jsonrpc = "2.0"
        self.id = id
        self.error = error
    }
}

private struct JSONRPCErrorBody: Codable {
    let code: Int
    let message: String
}
