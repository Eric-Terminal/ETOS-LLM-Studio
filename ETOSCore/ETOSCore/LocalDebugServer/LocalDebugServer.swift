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

    public struct OpenAIRequestSummary: Identifiable, Hashable, Sendable {
        public let id: UUID
        public let model: String?
        public let messageCount: Int
        public let receivedAt: Date
    }

    public struct DebugLogEntry: Identifiable, Sendable {
        public let id = UUID()
        public let timestamp: Date
        public let message: String
        public let type: LogType

        public enum LogType: CustomStringConvertible, Sendable {
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

    struct DebugConnectionTarget: Sendable {
        let host: String
        let port: String
        let useHTTP: Bool
    }

    @Published public var isRunning = false
    @Published public var serverURL: String = ""
    @Published public var connectionStatus: String = NSLocalizedString("未连接", comment: "")
    @Published public var errorMessage: String?
    @Published public var pendingOpenAIRequest: OpenAIRequestSummary?
    @Published public var pendingOpenAIQueueCount: Int = 0
    @Published public var useHTTP: Bool = true // HTTP 轮询模式开关（默认启用）
    @Published public var debugLogs: [DebugLogEntry] = []
    @Published public var isTransferring: Bool = false
    @Published public internal(set) var isProcessingCommand = false
    @Published public internal(set) var isDisconnecting = false

    let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "LocalDebugServer")
    var wsConnection: NWConnection?
    let queue = DispatchQueue(label: "com.etos.localdebug", qos: .userInitiated)
    var pendingOpenAIRequests: [PendingOpenAIRequest] = []
    var resolvingOpenAIRequestIDs: Set<UUID> = []
    let insertSession: @Sendable (ChatSession, [ChatMessage]) throws -> Void
    var fileRoot: @Sendable () -> URL = { StorageUtility.documentsDirectory }
    var installDocuments: @Sendable (LocalDebugDocumentReplacement) throws -> Void = { try Persistence.installDebugDocuments($0) }
    var fetchFilePayload: (@Sendable (String) async throws -> Data)?

    /// 宿主在执行闭包前暂停页面和运行任务，闭包返回后刷新状态并恢复入口；不得排空当前调试命令自身。
    public var documentReplacementCoordinator: (@MainActor (@escaping @Sendable () throws -> Void) async throws -> Void)?

    var httpPollingTimer: Timer?
    var httpSession: URLSession?
    var httpConnectionTask: Task<Void, Never>?
    var httpPollTask: Task<Void, Never>?
    var httpPollID: UUID?
    let commandQueue = LocalDebugCommandQueue()
    var disconnectWaiterCount = 0
    /// 电脑端调试追求跟手操作，HTTP 轮询以高频短请求承载命令通道。
    let httpPollingInterval: TimeInterval = 0.2
    var httpFailureCount: Int = 0
    let maxHTTPFailures: Int = 5

    var wsAutoFallbackEnabled = false
    var wsFallbackPort = "7654"
    var autoReconnectEnabled = false
    var reconnectTarget: DebugConnectionTarget?
    var reconnectTask: Task<Void, Never>?
    var reconnectAttempt = 0
    let reconnectInterval: TimeInterval = 5
    var connectionToken = UUID()

    let maxLogEntries = 100

    public init() {
        insertSession = { try Persistence.insertChatSession($0, messages: $1) }
    }

    init(insertSession: @escaping @Sendable (ChatSession, [ChatMessage]) throws -> Void) {
        self.insertSession = insertSession
    }
}
