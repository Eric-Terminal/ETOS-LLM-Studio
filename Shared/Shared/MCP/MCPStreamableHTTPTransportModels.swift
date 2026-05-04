// ============================================================================
// MCPStreamableHTTPTransportModels.swift
// ============================================================================
// ETOS LLM Studio
//
// MCP Streamable HTTP 传输专用的 SSE 事件与待处理请求状态模型。
// ============================================================================

import Foundation

struct SSEEvent {
    let id: String?
    let name: String?
    let data: String
}

actor StreamablePendingRequestsActor {
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

struct JSONRPCNotificationEnvelope: Decodable {
    let method: String
}
