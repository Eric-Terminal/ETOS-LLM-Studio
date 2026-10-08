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
        let pending = pendingOpenAIRequests
        let result = await Task.detached(priority: .utility) {
            let queue = pending.map { item in
                [
                    "id": item.id.uuidString,
                    "model": item.model ?? "",
                    "message_count": item.originalMessageCount,
                    "received_at": Self.formatWebConsoleDate(item.receivedAt)
                ] as [String: Any]
            }
            return LocalDebugJSONObject(value: ["status": "ok", "queue": queue, "count": queue.count])
        }.value
        return result.value
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

        guard let pending = reservePendingOpenAIRequest(targetID: targetID) else {
            return ["status": "error", "message": NSLocalizedString("The captured request is missing or already being processed.", comment: "调试捕获请求不可用")]
        }
        do {
            try await finishPendingOpenAIRequest(pending, save: shouldSave)
            return [
                "status": "ok",
                "message": shouldSave ? "已保存捕获请求" : "已忽略捕获请求",
                "resolved_id": pending.id.uuidString,
                "remaining": pendingOpenAIRequests.count
            ]
        } catch {
            return ["status": "error", "message": error.localizedDescription]
        }
    }

    func handleOpenAICapture(_ json: [String: Any]) async -> [String: Any] {
        guard let requestData = json["request"] as? [String: Any] else {
            return ["status": "error", "message": "无效的 OpenAI 请求"]
        }
        let request = LocalDebugJSONObject(value: requestData)
        let worker = Task.detached(priority: .userInitiated) { self.parseOpenAIChatCompletions(request.value) }
        let parsed = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        guard canContinueDebugCommand, let pending = parsed else {
            return ["status": "error", "message": "无效的 OpenAI 请求"]
        }

        let model = pending.model

        pendingOpenAIRequests.append(pending)
        updatePendingOpenAIState()

        logger.info("捕获 OpenAI 请求: \(model ?? "unknown")")

        return [
            "status": "ok",
            "message": "已捕获请求，等待用户确认"
        ]
    }

    public func resolvePendingOpenAIRequest(save: Bool) {
        guard let pending = reservePendingOpenAIRequest(targetID: nil) else { return }
        let token = connectionToken
        // 用户已经确认的保存必须完成；断开可以丢弃远端排队命令，不能丢弃这次原生确认。
        commandQueue.enqueue(discardOnCancellation: false) { [self] in
            do { try await finishPendingOpenAIRequest(pending, save: save) }
            catch { if isCurrentConnection(token) { errorMessage = error.localizedDescription } }
        }
    }

    private func reservePendingOpenAIRequest(targetID: UUID?) -> PendingOpenAIRequest? {
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

        let pending = pendingOpenAIRequests[targetIndex]
        guard resolvingOpenAIRequestIDs.insert(pending.id).inserted else { return nil }
        return pending
    }

    private func finishPendingOpenAIRequest(_ pending: PendingOpenAIRequest, save: Bool) async throws {
        defer { resolvingOpenAIRequestIDs.remove(pending.id) }
        if save { try await saveCapturedOpenAIRequest(pending) }
        // 保存失败时保留原请求供重试；断开已清空的旧队列不会因此重新出现。
        pendingOpenAIRequests.removeAll { $0.id == pending.id }
        updatePendingOpenAIState()
    }

    nonisolated func parseOpenAIChatCompletions(_ json: [String: Any]) -> PendingOpenAIRequest? {
        guard let rawMessages = json["messages"] as? [[String: Any]] else {
            return nil
        }

        let model = json["model"] as? String
        var systemParts: [String] = []
        var messages: [ChatMessage] = []

        for rawMessage in rawMessages {
            guard !Task.isCancelled else { return nil }
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

    nonisolated func normalizeOpenAIContent(_ content: Any?) -> String {
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

    func saveCapturedOpenAIRequest(_ pending: PendingOpenAIRequest) async throws {
        let insertSession = insertSession
        let session = try await Task.detached(priority: .userInitiated) {
            let session = ChatSession(id: UUID(), name: self.formatSessionTitle(for: pending.receivedAt),
                topicPrompt: pending.systemPrompt, enhancedPrompt: nil, isTemporary: false)
            try insertSession(session, pending.messages)
            return session
        }.value

        let chatService = ChatService.shared
        var liveSessions = chatService.chatSessionsSubject.value
        liveSessions.insert(session, at: 0)
        chatService.chatSessionsSubject.send(liveSessions)
    }

    nonisolated func formatSessionTitle(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
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
        pendingOpenAIRequest = summary
        pendingOpenAIQueueCount = pendingOpenAIRequests.count
    }
}
