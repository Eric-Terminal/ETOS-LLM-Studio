// ============================================================================
// LocalDebugServerOpenAI.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件负责本地调试客户端的 OpenAI 请求捕获、队列管理、
// 手动保存/忽略，以及捕获内容转回聊天会话。
// ============================================================================

import Combine
import Foundation
import os.log

extension LocalDebugServer {
    func handleOpenAIQueueList() async -> [String: Any] {
        let queue = pendingOpenAIRequests.map { item in
            [
                "id": item.id.uuidString,
                "model": item.model ?? "",
                "message_count": item.originalMessageCount,
                "received_at": Self.formatWebConsoleDate(item.receivedAt)
            ] as [String: Any]
        }
        return [
            "status": "ok",
            "queue": queue,
            "count": queue.count
        ]
    }

    func handleOpenAIQueueResolve(_ json: [String: Any]) async -> [String: Any] {
        let shouldSave = (json["save"] as? Bool) ?? true
        let targetID: UUID?
        if let requestID = json["id"] as? String, !requestID.isEmpty {
            targetID = UUID(uuidString: requestID)
            if targetID == nil {
                return ["status": "error", "message": "id 不是合法 UUID"]
            }
        } else {
            targetID = nil
        }

        guard let resolved = resolvePendingOpenAIRequest(targetID: targetID, save: shouldSave) else {
            return ["status": "error", "message": "队列中未找到对应请求"]
        }

        return [
            "status": "ok",
            "message": shouldSave ? "已保存捕获请求" : "已忽略捕获请求",
            "resolved_id": resolved.id.uuidString,
            "remaining": pendingOpenAIRequests.count
        ]
    }

    func handleOpenAICapture(_ json: [String: Any]) async -> [String: Any] {
        guard let requestData = json["request"] as? [String: Any],
              let pending = parseOpenAIChatCompletions(requestData) else {
            return ["status": "error", "message": "无效的 OpenAI 请求"]
        }

        let model = pending.model

        await MainActor.run {
            self.pendingOpenAIRequests.append(pending)
            self.updatePendingOpenAIState()
        }

        logger.info("捕获 OpenAI 请求: \(model ?? "unknown")")

        return [
            "status": "ok",
            "message": "已捕获请求，等待用户确认"
        ]
    }

    public func resolvePendingOpenAIRequest(save: Bool) {
        _ = resolvePendingOpenAIRequest(targetID: nil, save: save)
    }

    @discardableResult
    func resolvePendingOpenAIRequest(targetID: UUID?, save: Bool) -> PendingOpenAIRequest? {
        guard !pendingOpenAIRequests.isEmpty else { return nil }

        let targetIndex: Int
        if let targetID {
            guard let index = pendingOpenAIRequests.firstIndex(where: { $0.id == targetID }) else {
                return nil
            }
            targetIndex = index
        } else {
            targetIndex = 0
        }

        let pending = pendingOpenAIRequests.remove(at: targetIndex)
        if save {
            saveCapturedOpenAIRequest(pending)
        }
        updatePendingOpenAIState()
        return pending
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
