// ============================================================================
// LocalDebugServer.swift
// ============================================================================
// ETOS LLM Studio
//
// 本类保存本地调试客户端的共享状态与底层连接资源。
// 具体的连接、传输、Web 控制台和 OpenAI 捕获逻辑拆分到独立扩展文件中。
// ============================================================================

import Combine
import Foundation
import Network
import os.log

/// 反向探针调试客户端
@MainActor
public class LocalDebugServer: ObservableObject {
    // 注意：这里必须使用系统合成的 objectWillChange，
    // 否则本地调试页的连接状态、请求队列与日志不会稳定刷新。

    public struct OpenAIRequestSummary: Identifiable, Hashable {
        public let id: UUID
        public let model: String?
        public let messageCount: Int
        public let receivedAt: Date
    }

    public struct DebugLogEntry: Identifiable {
        public let id = UUID()
        public let timestamp: Date
        public let message: String
        public let type: LogType

        public enum LogType: CustomStringConvertible {
            case info, send, receive, error, heartbeat

            public var description: String {
                switch self {
                case .info: return "INFO"
                case .send: return "SEND"
                case .receive: return "RECV"
                case .error: return "ERROR"
                case .heartbeat: return "BEAT"
                }
            }
        }
    }

    struct PendingOpenAIRequest: Sendable {
        let id: UUID
        let receivedAt: Date
        let model: String?
        let systemPrompt: String?
        let messages: [ChatMessage]
        let originalMessageCount: Int
    }

    @Published public var isRunning = false
    @Published public var serverURL: String = ""
    @Published public var connectionStatus: String = "未连接"
    @Published public var errorMessage: String?
    @Published public var pendingOpenAIRequest: OpenAIRequestSummary?
    @Published public var pendingOpenAIQueueCount: Int = 0
    @Published public var useHTTP: Bool = true // HTTP 轮询模式开关（默认启用）
    @Published public var debugLogs: [DebugLogEntry] = []
    @Published public var isTransferring: Bool = false

    let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "LocalDebugServer")
    var wsConnection: NWConnection?
    let queue = DispatchQueue(label: "com.etos.localdebug", qos: .userInitiated)
    var pendingOpenAIRequests: [PendingOpenAIRequest] = []
    var permissionProbeConnection: NWConnection?

    var httpPollingTimer: Timer?
    var httpSession: URLSession?
    let httpPollingInterval: TimeInterval = 1.0
    var httpFailureCount: Int = 0
    let maxHTTPFailures: Int = 5

    var wsAutoFallbackEnabled = false
    var wsFallbackHTTPPort = "7654"

    let maxLogEntries = 100

    public init() {}
}
