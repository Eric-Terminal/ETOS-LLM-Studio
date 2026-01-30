// ============================================================================
// MCPStreamingTransport.swift
// ============================================================================
// 实现支持双向通信的 MCP 传输层，用于处理服务器推送通知和 Sampling 请求。
// 基于 HTTP + SSE 实现长连接。
// ============================================================================

import Foundation
import os.log

private let streamingLogger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "MCPStreamingTransport")

// MARK: - Sampling Handler Protocol

public protocol MCPSamplingHandler: AnyObject {
    func handleSamplingRequest(_ request: MCPSamplingRequest) async throws -> MCPSamplingResponse
}

// MARK: - Notification Delegate

public protocol MCPNotificationDelegate: AnyObject {
    func didReceiveNotification(_ notification: MCPNotification)
    func didReceiveLogMessage(_ entry: MCPLogEntry)
    func didReceiveProgress(_ progress: MCPProgressParams)
}

// MARK: - Streaming Transport Protocol

public protocol MCPStreamingTransportProtocol: AnyObject {
    var notificationDelegate: MCPNotificationDelegate? { get set }
    var samplingHandler: MCPSamplingHandler? { get set }
    func connectStream()
    func disconnect()
}

// MARK: - Streaming Transport

public final class MCPStreamingTransport: MCPTransport, MCPStreamingTransportProtocol, @unchecked Sendable {
    private let sseEndpoint: URL
    private let session: URLSession
    private let headers: [String: String]
    private let protocolVersion: String? = MCPProtocolVersion.current
    
    private var sseTask: Task<Void, Never>?
    private let pendingRequestsActor = PendingRequestsActor()
    private let state: StreamingState
    
    public weak var notificationDelegate: MCPNotificationDelegate?
    public weak var samplingHandler: MCPSamplingHandler?
    
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    
    public init(
        messageEndpoint: URL,
        sseEndpoint: URL,
        session: URLSession = .shared,
        headers: [String: String] = [:]
    ) {
        self.sseEndpoint = sseEndpoint
        self.session = session
        self.headers = headers
        self.state = StreamingState(messageEndpoint: messageEndpoint)
    }
    
    deinit {
        disconnect()
    }
    
    // MARK: - MCPTransport
    
    public func sendMessage(_ payload: Data) async throws -> Data {
        let requestId = try extractRequestId(from: payload)
        if sseTask == nil {
            connectSSE()
        }

        return try await withCheckedThrowingContinuation { continuation in
            Task {
                await pendingRequestsActor.add(id: requestId, continuation: continuation)
                do {
                    let (endpoint, sessionId) = await state.snapshot()
                    var request = URLRequest(url: endpoint)
                    request.httpMethod = "POST"
                    request.httpBody = payload
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("application/json", forHTTPHeaderField: "Accept")

                    for (key, value) in headers {
                        request.setValue(value, forHTTPHeaderField: key)
                    }
                    if let sessionId, !sessionId.isEmpty, !hasHeader("MCP-Session-Id", in: headers) {
                        request.setValue(sessionId, forHTTPHeaderField: "MCP-Session-Id")
                    }

                    let (data, response) = try await session.data(for: request)
                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw MCPClientError.invalidResponse
                    }

                    guard (200..<300).contains(httpResponse.statusCode) else {
                        let message = String(data: data, encoding: .utf8)
                        throw MCPTransportError.httpStatus(code: httpResponse.statusCode, body: message)
                    }

                    if let resolved = try resolveImmediateResponse(data: data, response: httpResponse) {
                        let pending = await pendingRequestsActor.remove(id: requestId)
                        pending?.resume(returning: resolved)
                    }
                } catch {
                    let pending = await pendingRequestsActor.remove(id: requestId)
                    pending?.resume(throwing: error)
                }
            }
        }
    }

    public func sendNotification(_ payload: Data) async throws {
        let (endpoint, sessionId) = await state.snapshot()
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = payload
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if let sessionId, !sessionId.isEmpty, !hasHeader("MCP-Session-Id", in: headers) {
            request.setValue(sessionId, forHTTPHeaderField: "MCP-Session-Id")
        }
        if let protocolVersion, !protocolVersion.isEmpty, !hasHeader("MCP-Protocol-Version", in: headers) {
            request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        }
        if let protocolVersion, !protocolVersion.isEmpty, !hasHeader("MCP-Protocol-Version", in: headers) {
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
    
    // MARK: - SSE Connection
    
    public func connectStream() {
        connectSSE()
    }

    public func connectSSE() {
        disconnect()
        
        sseTask = Task { [weak self] in
            guard let self = self else { return }
            await self.runSSELoop(url: sseEndpoint)
        }
    }
    
    public func disconnect() {
        sseTask?.cancel()
        sseTask = nil

        let pendingActor = pendingRequestsActor
        Task {
            let pending = await pendingActor.removeAll()
            for continuation in pending {
                continuation.resume(throwing: CancellationError())
            }
        }
    }
    
    private func runSSELoop(url: URL) async {
        var request = URLRequest(url: url)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = .infinity
        
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if let protocolVersion, !protocolVersion.isEmpty, !hasHeader("MCP-Protocol-Version", in: headers) {
            request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        }
        
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode) else {
                streamingLogger.error("SSE 连接失败")
                return
            }

            streamingLogger.info("SSE 连接已建立")
            if let sessionId = httpResponse.value(forHTTPHeaderField: "MCP-Session-Id"),
               !sessionId.isEmpty {
                await state.updateSessionId(sessionId)
            }

            var eventName = "message"
            var dataLines: [String] = []
            for try await line in bytes.lines {
                if Task.isCancelled { break }
                
                if line.isEmpty {
                    // 空行表示事件结束
                    if !dataLines.isEmpty {
                        let payload = dataLines.joined(separator: "\n")
                        await handleSSEEvent(name: eventName, data: payload)
                    }
                    eventName = "message"
                    dataLines = []
                } else if line.hasPrefix(":") {
                    continue
                } else if line.hasPrefix("event:") {
                    eventName = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                } else if line.hasPrefix("data:") {
                    let data = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                    if data != "[DONE]" {
                        dataLines.append(data)
                    }
                }
            }
        } catch {
            if !Task.isCancelled {
                streamingLogger.error("SSE 连接错误: \(error.localizedDescription)")
            }
        }
    }
    
    private func handleSSEEvent(name: String, data: String) async {
        let trimmed = data.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if name == "endpoint" {
            let parsed = parseEndpointEventData(trimmed)
            if let endpoint = parsed.endpoint {
                await state.updateMessageEndpoint(endpoint)
            }
            if let sessionId = parsed.sessionId {
                await state.updateSessionId(sessionId)
            }
            return
        }
        if name == "session" || name == "sessionId" {
            await state.updateSessionId(trimmed)
            return
        }
        await processSSEPayload(trimmed)
    }

    private func processSSEPayload(_ data: String) async {
        guard let jsonData = data.data(using: .utf8) else { return }
        
        // 尝试解析为通知
        if let notification = try? decoder.decode(MCPNotification.self, from: jsonData) {
            await handleNotification(notification)
            return
        }
        
        // 尝试解析为 Sampling 请求
        if let samplingRequest = try? decoder.decode(MCPServerSamplingRequest.self, from: jsonData) {
            await handleSamplingRequest(samplingRequest)
            return
        }
        
        // 尝试解析为 JSON-RPC 响应
        if let response = try? decoder.decode(JSONRPCResponseWrapper.self, from: jsonData),
           let id = response.id {
            let continuation = await pendingRequestsActor.remove(id: id)
            continuation?.resume(returning: jsonData)
        }
    }
    
    private func handleNotification(_ notification: MCPNotification) async {
        streamingLogger.debug("收到通知: \(notification.method)")
        
        // 处理日志消息
        if notification.method == MCPNotificationType.logMessage.rawValue,
           let params = notification.params,
           let logEntry = try? decodeLogEntry(from: params) {
            await MainActor.run {
                notificationDelegate?.didReceiveLogMessage(logEntry)
            }
            return
        }
        
        // 处理进度通知
        if notification.method == MCPNotificationType.progress.rawValue,
           let params = notification.params,
           let progress = try? decodeProgress(from: params) {
            await MainActor.run {
                notificationDelegate?.didReceiveProgress(progress)
            }
            return
        }
        
        // 通用通知
        await MainActor.run {
            notificationDelegate?.didReceiveNotification(notification)
        }
    }
    
    private func handleSamplingRequest(_ request: MCPServerSamplingRequest) async {
        guard let handler = samplingHandler else {
            streamingLogger.warning("收到 Sampling 请求但未设置 handler")
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
            streamingLogger.error("发送 Sampling 响应失败: \(error.localizedDescription)")
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
            streamingLogger.error("发送 Sampling 错误响应失败: \(error.localizedDescription)")
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

    private func extractRequestId(from payload: Data) throws -> String {
        if let request = try? decoder.decode(JSONRPCRequestEnvelope.self, from: payload) {
            return request.id
        }
        throw MCPClientError.invalidResponse
    }

    private func resolveImmediateResponse(data: Data, response: HTTPURLResponse) throws -> Data? {
        guard !data.isEmpty else { return nil }
        let contentType = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        if contentType.contains("text/event-stream") {
            return try extractLastEvent(from: data)
        }
        if let text = String(data: data, encoding: .utf8),
           text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return nil
        }
        return data
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

    private func parseEndpointEventData(_ data: String) -> (endpoint: URL?, sessionId: String?) {
        if let direct = urlFromEventData(data) {
            return (direct, extractSessionId(from: direct))
        }
        if let jsonData = data.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
            let endpointString = object["endpoint"] as? String
                ?? object["messageEndpoint"] as? String
                ?? object["message"] as? String
                ?? object["url"] as? String
            let sessionId = object["sessionId"] as? String
                ?? object["session_id"] as? String
                ?? object["mcpSessionId"] as? String
            if let endpointString, let resolved = urlFromEventData(endpointString) {
                return (resolved, sessionId ?? extractSessionId(from: resolved))
            }
            return (nil, sessionId)
        }
        return (nil, nil)
    }

    private func urlFromEventData(_ data: String) -> URL? {
        let trimmed = data.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(string: trimmed, relativeTo: sseEndpoint)?.absoluteURL
    }

    private func extractSessionId(from url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
              let items = components.queryItems else {
            return nil
        }
        for item in items {
            let name = item.name.lowercased()
            if name == "sessionid" || name == "session_id" || name == "mcp_session_id" {
                return item.value
            }
        }
        return nil
    }

    private func hasHeader(_ name: String, in headers: [String: String]) -> Bool {
        headers.keys.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }
}

// MARK: - Internal Models

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

// MARK: - Actor for Thread-Safe Pending Requests

private actor PendingRequestsActor {
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

private actor StreamingState {
    private var messageEndpoint: URL
    private var sessionId: String?

    init(messageEndpoint: URL) {
        self.messageEndpoint = messageEndpoint
    }

    func snapshot() -> (URL, String?) {
        (messageEndpoint, sessionId)
    }

    func updateMessageEndpoint(_ endpoint: URL) {
        messageEndpoint = endpoint
    }

    func updateSessionId(_ id: String?) {
        sessionId = id
    }
}
