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

// MARK: - Streaming Transport

public final class MCPStreamingTransport: MCPTransport, @unchecked Sendable {
    private let endpoint: URL
    private let sseEndpoint: URL?
    private let session: URLSession
    private let headers: [String: String]
    
    private var sseTask: Task<Void, Never>?
    private let pendingRequestsActor = PendingRequestsActor()
    
    public weak var notificationDelegate: MCPNotificationDelegate?
    public weak var samplingHandler: MCPSamplingHandler?
    
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    
    public init(
        endpoint: URL,
        sseEndpoint: URL? = nil,
        session: URLSession = .shared,
        headers: [String: String] = [:]
    ) {
        self.endpoint = endpoint
        self.sseEndpoint = sseEndpoint
        self.session = session
        self.headers = headers
    }
    
    deinit {
        disconnect()
    }
    
    // MARK: - MCPTransport
    
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
    
    // MARK: - SSE Connection
    
    public func connectSSE() {
        guard let sseURL = sseEndpoint else {
            streamingLogger.warning("未配置 SSE endpoint，无法建立长连接")
            return
        }
        
        disconnect()
        
        sseTask = Task { [weak self] in
            guard let self = self else { return }
            await self.runSSELoop(url: sseURL)
        }
    }
    
    public func disconnect() {
        sseTask?.cancel()
        sseTask = nil
        
        Task {
            let pending = await pendingRequestsActor.removeAll()
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
        
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode) else {
                streamingLogger.error("SSE 连接失败")
                return
            }
            
            streamingLogger.info("SSE 连接已建立")
            
            var buffer = ""
            for try await line in bytes.lines {
                if Task.isCancelled { break }
                
                if line.isEmpty {
                    // 空行表示事件结束
                    if !buffer.isEmpty {
                        await processSSEEvent(buffer)
                        buffer = ""
                    }
                } else if line.hasPrefix("data:") {
                    let data = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                    if data != "[DONE]" {
                        buffer += data
                    }
                }
            }
        } catch {
            if !Task.isCancelled {
                streamingLogger.error("SSE 连接错误: \(error.localizedDescription)")
            }
        }
    }
    
    private func processSSEEvent(_ data: String) async {
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
            _ = try await sendMessage(data)
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
            _ = try await sendMessage(data)
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
}

// MARK: - Internal Models

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
