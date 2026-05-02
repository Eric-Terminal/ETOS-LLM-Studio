// ============================================================================
// LocalDebugServer.swift (WebSocket Client Version)
// ============================================================================
// ETOS LLM Studio
//
// 反向探针调试客户端,通过WebSocket主动连接到电脑端服务器。
// 功能包括:文件浏览、下载、上传、OpenAI请求捕获转发。
// ============================================================================

import Foundation
import Combine
import Network
import os.log
#if os(iOS)
import UIKit
#elseif os(watchOS)
import WatchKit
#endif

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

    @Published public var isRunning = false
    @Published public var serverURL: String = ""
    @Published public var connectionStatus: String = "未连接"
    @Published public var errorMessage: String?
    @Published public var pendingOpenAIRequest: OpenAIRequestSummary?
    @Published public var pendingOpenAIQueueCount: Int = 0
    @Published public var useHTTP: Bool = true // HTTP 轮询模式开关（默认启用）
    @Published public var debugLogs: [DebugLogEntry] = [] // 调试日志
    @Published public var isTransferring: Bool = false // 是否正在进行批量传输（暂停轮询）
    
    /// 调试日志条目
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
    
    let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "LocalDebugServer")
    var wsConnection: NWConnection?
    let queue = DispatchQueue(label: "com.etos.localdebug", qos: .userInitiated)
    var pendingOpenAIRequests: [PendingOpenAIRequest] = []
    var permissionProbeConnection: NWConnection?

    var httpPollingTimer: Timer?
    var httpSession: URLSession?
    let httpPollingInterval: TimeInterval = 1.0 // 1秒轮询一次
    var httpFailureCount: Int = 0 // HTTP 失败计数
    let maxHTTPFailures: Int = 5 // 最大失败次数

    var wsAutoFallbackEnabled = false
    var wsFallbackHTTPPort = "7654"

    let maxLogEntries = 100 // 最大日志条数

    public init() {}
}

// MARK: - OpenAI 捕获解析

extension LocalDebugServer {
    struct PendingOpenAIRequest: Sendable {
        let id: UUID
        let receivedAt: Date
        let model: String?
        let systemPrompt: String?
        let messages: [ChatMessage]
        let originalMessageCount: Int
    }
    
    func parseOpenAIChatCompletions(_ json: [String: Any]) -> PendingOpenAIRequest? {
        guard let rawMessages = json["messages"] as? [[String: Any]] else {
            return nil
        }
        
        let model = json["model"] as? String
        var systemParts: [String] = []
        var messages: [ChatMessage] = []
        
        for rawMessage in rawMessages {
            let roleString = (rawMessage["role"] as? String) ?? "user"
            let content = normalizeOpenAIContent(rawMessage["content"])
            
            if roleString == "system" {
                if !content.isEmpty {
                    systemParts.append(content)
                }
                continue
            }
            
            let mappedRole: MessageRole
            switch roleString {
            case "assistant": mappedRole = .assistant
            case "tool", "function": mappedRole = .tool
            default: mappedRole = .user
            }
            
            messages.append(ChatMessage(role: mappedRole, content: content))
        }
        
        return PendingOpenAIRequest(
            id: UUID(),
            receivedAt: Date(),
            model: model,
            systemPrompt: systemParts.isEmpty ? nil : systemParts.joined(separator: "\n\n"),
            messages: messages,
            originalMessageCount: rawMessages.count
        )
    }
    
    func normalizeOpenAIContent(_ content: Any?) -> String {
        if let text = content as? String {
            return text
        }
        if let parts = content as? [[String: Any]] {
            var pieces: [String] = []
            for part in parts {
                if let text = part["text"] as? String {
                    pieces.append(text)
                }
            }
            return pieces.joined(separator: "\n")
        }
        return ""
    }
    
    func saveCapturedOpenAIRequest(_ pending: PendingOpenAIRequest) {
        let session = ChatSession(
            id: UUID(),
            name: formatSessionTitle(for: pending.receivedAt),
            topicPrompt: pending.systemPrompt,
            enhancedPrompt: nil,
            isTemporary: false
        )
        
        Persistence.saveMessages(pending.messages, for: session.id)
        var sessions = Persistence.loadChatSessions()
        sessions.insert(session, at: 0)
        Persistence.saveChatSessions(sessions)
        
        Task { @MainActor in
            let chatService = ChatService.shared
            var liveSessions = chatService.chatSessionsSubject.value
            liveSessions.insert(session, at: 0)
            chatService.chatSessionsSubject.send(liveSessions)
        }
    }
    
    func formatSessionTitle(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年MM月dd日 HH点mm分ss秒"
        return formatter.string(from: date)
    }
    
    func updatePendingOpenAIState() {
        let summary: OpenAIRequestSummary?
        if let pending = pendingOpenAIRequests.first {
            summary = OpenAIRequestSummary(
                id: pending.id,
                model: pending.model,
                messageCount: pending.originalMessageCount,
                receivedAt: pending.receivedAt
            )
        } else {
            summary = nil
        }
        let count = pendingOpenAIRequests.count
        
        Task { @MainActor in
            self.pendingOpenAIRequest = summary
            self.pendingOpenAIQueueCount = count
        }
    }
}
