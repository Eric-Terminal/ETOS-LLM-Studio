// ============================================================================
// MCPStreamingTransportModels.swift
// ============================================================================
// ETOS LLM Studio
//
// 承接 MCP Streaming Transport 的内部 JSON-RPC 模型与状态 actor。
// ============================================================================

import Foundation

struct JSONRPCRequestEnvelope: Decodable {
    let id: JSONRPCID
}


struct JSONRPCDispatchEnvelope: Decodable {
    let id: JSONRPCID?
    let method: String?
    let result: JSONValue?
    let error: JSONValue?
}

struct MCPServerSamplingRequest: Codable {
    let jsonrpc: String
    let id: JSONRPCID
    let method: String
    let params: MCPSamplingRequest
}

struct MCPServerElicitationRequest: Codable {
    let jsonrpc: String
    let id: JSONRPCID
    let method: String
    let params: MCPElicitationRequest
}


struct JSONRPCSamplingResponse: Encodable {
    let jsonrpc: String
    let id: JSONRPCID
    let result: MCPSamplingResponse

    init(id: JSONRPCID, result: MCPSamplingResponse) {
        self.jsonrpc = "2.0"
        self.id = id
        self.result = result
    }
}

struct JSONRPCElicitationResponse: Encodable {
    let jsonrpc: String
    let id: JSONRPCID
    let result: MCPElicitationResult

    init(id: JSONRPCID, result: MCPElicitationResult) {
        self.jsonrpc = "2.0"
        self.id = id
        self.result = result
    }
}

struct JSONRPCErrorResponse: Encodable {
    let jsonrpc: String
    let id: JSONRPCID
    let error: JSONRPCErrorBody

    init(id: JSONRPCID, error: JSONRPCErrorBody) {
        self.jsonrpc = "2.0"
        self.id = id
        self.error = error
    }
}

struct JSONRPCErrorBody: Codable {
    let code: Int
    let message: String
}

actor PendingRequestsActor {
    private var requests: [JSONRPCID: CheckedContinuation<Data, Error>] = [:]

    func add(id: JSONRPCID, continuation: CheckedContinuation<Data, Error>) {
        requests[id] = continuation
    }

    func remove(id: JSONRPCID) -> CheckedContinuation<Data, Error>? {
        requests.removeValue(forKey: id)
    }

    func removeAll() -> [CheckedContinuation<Data, Error>] {
        let all = Array(requests.values)
        requests.removeAll()
        return all
    }
}

actor StreamingState {
    private var messageEndpoint: URL
    private var sessionId: String?
    private var endpointReady = false
    private var endpointWaiters: [UUID: CheckedContinuation<URL, Never>] = [:]

    init(messageEndpoint: URL) {
        self.messageEndpoint = messageEndpoint
    }

    func snapshot(waitForEndpointTimeout: TimeInterval?) async -> (URL, String?) {
        let endpoint = await awaitMessageEndpoint(timeout: waitForEndpointTimeout)
        return (endpoint, sessionId)
    }

    func updateMessageEndpoint(_ endpoint: URL) {
        messageEndpoint = endpoint
        endpointReady = true
        if !endpointWaiters.isEmpty {
            let waiters = endpointWaiters
            endpointWaiters.removeAll()
            for (_, continuation) in waiters {
                continuation.resume(returning: endpoint)
            }
        }
    }

    func updateSessionId(_ id: String?) {
        sessionId = id
    }

    func prepareForNewStream() {
        endpointReady = false
        sessionId = nil
    }

    func clearSession() {
        sessionId = nil
        endpointReady = false
    }

    private func awaitMessageEndpoint(timeout: TimeInterval?) async -> URL {
        if endpointReady {
            return messageEndpoint
        }
        return await withCheckedContinuation { continuation in
            let token = UUID()
            endpointWaiters[token] = continuation
            if let timeout, timeout > 0 {
                Task { [weak self] in
                    let nanos = UInt64(timeout * 1_000_000_000)
                    try? await Task.sleep(nanoseconds: nanos)
                    await self?.resumeWaiterIfNeeded(token: token)
                }
            }
        }
    }

    private func resumeWaiterIfNeeded(token: UUID) {
        guard let continuation = endpointWaiters.removeValue(forKey: token) else { return }
        endpointReady = true
        continuation.resume(returning: messageEndpoint)
    }
}
