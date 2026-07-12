// ============================================================================
// RoleplayMacroExpansionBridge.swift
// ============================================================================
// ETOS LLM Studio
//
// 让助手脚本注册的动态宏和可变生成事件参与原生提示词构建。
// ============================================================================

import Foundation

public enum RoleplayMacroExpansionNotification {
    public static let requested = Notification.Name("com.ETOS.roleplayMacroExpansion.requested")
    public static let requestIDKey = "requestID"
    public static let sessionIDKey = "sessionID"
    public static let scriptIDKey = "scriptID"
    public static let textKey = "text"
}

public actor RoleplayMacroExpansionBridge {
    public static let shared = RoleplayMacroExpansionBridge()

    private struct PendingRequest {
        var continuation: CheckedContinuation<String?, Never>
        var timeout: Task<Void, Never>
    }

    private var pending: [String: PendingRequest] = [:]

    public func expand(_ text: String, sessionID: UUID, scriptIDs: [UUID]) async -> String {
        var output = text
        for scriptID in scriptIDs {
            if let expanded = await requestExpansion(output, sessionID: sessionID, scriptID: scriptID) {
                output = expanded
            }
        }
        return output
    }

    public func receive(requestID: String, text: String) {
        guard let request = pending.removeValue(forKey: requestID) else { return }
        request.timeout.cancel()
        request.continuation.resume(returning: text)
    }

    private func requestExpansion(_ text: String, sessionID: UUID, scriptID: UUID) async -> String? {
        let requestID = UUID().uuidString
        return await withCheckedContinuation { continuation in
            let timeout = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await self?.expire(requestID: requestID)
            }
            pending[requestID] = PendingRequest(continuation: continuation, timeout: timeout)
            NotificationCenter.default.post(
                name: RoleplayMacroExpansionNotification.requested,
                object: nil,
                userInfo: [
                    RoleplayMacroExpansionNotification.requestIDKey: requestID,
                    RoleplayMacroExpansionNotification.sessionIDKey: sessionID,
                    RoleplayMacroExpansionNotification.scriptIDKey: scriptID,
                    RoleplayMacroExpansionNotification.textKey: text
                ]
            )
        }
    }

    private func expire(requestID: String) {
        guard let request = pending.removeValue(forKey: requestID) else { return }
        request.continuation.resume(returning: nil)
    }
}

public enum RoleplayPromptMutationNotification {
    public static let requested = Notification.Name("com.ETOS.roleplayPromptMutation.requested")
    public static let requestIDKey = "requestID"
    public static let sessionIDKey = "sessionID"
    public static let scriptIDKey = "scriptID"
    public static let promptKey = "prompt"
}

/// 将最终请求提示词交给酒馆助手脚本，并接收 `GENERATE_AFTER_DATA` 对原对象的修改。
public actor RoleplayPromptMutationBridge {
    public static let shared = RoleplayPromptMutationBridge()

    private struct PendingRequest {
        var continuation: CheckedContinuation<[String]?, Never>
        var timeout: Task<Void, Never>
        var retry: Task<Void, Never>
    }

    private var pending: [String: PendingRequest] = [:]

    public func mutate(
        _ messages: [ChatMessage],
        sessionID: UUID,
        scriptIDs: [UUID]
    ) async -> [ChatMessage] {
        var output = messages
        for scriptID in scriptIDs {
            guard let contents = await requestMutation(output, sessionID: sessionID, scriptID: scriptID),
                  contents.count == output.count else { continue }
            for index in output.indices {
                output[index].content = contents[index]
            }
        }
        return output
    }

    public func receive(requestID: String, contents: [String]) {
        guard let request = pending.removeValue(forKey: requestID) else { return }
        request.timeout.cancel()
        request.retry.cancel()
        request.continuation.resume(returning: contents)
    }

    private func requestMutation(
        _ messages: [ChatMessage],
        sessionID: UUID,
        scriptID: UUID
    ) async -> [String]? {
        let requestID = UUID().uuidString
        let prompt = messages.map { message in
            ["role": message.role.rawValue, "content": message.content]
        }
        return await withCheckedContinuation { continuation in
            let timeout = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                await self?.expire(requestID: requestID)
            }
            let retry = Task { [weak self] in
                for _ in 0..<11 {
                    do {
                        try await Task.sleep(nanoseconds: 250_000_000)
                    } catch {
                        return
                    }
                    guard await self?.repostIfPending(
                        requestID: requestID,
                        prompt: prompt,
                        sessionID: sessionID,
                        scriptID: scriptID
                    ) == true else { return }
                }
            }
            pending[requestID] = PendingRequest(
                continuation: continuation,
                timeout: timeout,
                retry: retry
            )
            postMutationRequest(
                requestID: requestID,
                prompt: prompt,
                sessionID: sessionID,
                scriptID: scriptID
            )
        }
    }

    private func repostIfPending(
        requestID: String,
        prompt: [[String: String]],
        sessionID: UUID,
        scriptID: UUID
    ) -> Bool {
        guard pending[requestID] != nil else { return false }
        postMutationRequest(
            requestID: requestID,
            prompt: prompt,
            sessionID: sessionID,
            scriptID: scriptID
        )
        return true
    }

    private func postMutationRequest(
        requestID: String,
        prompt: [[String: String]],
        sessionID: UUID,
        scriptID: UUID
    ) {
        NotificationCenter.default.post(
            name: RoleplayPromptMutationNotification.requested,
            object: nil,
            userInfo: [
                RoleplayPromptMutationNotification.requestIDKey: requestID,
                RoleplayPromptMutationNotification.sessionIDKey: sessionID,
                RoleplayPromptMutationNotification.scriptIDKey: scriptID,
                RoleplayPromptMutationNotification.promptKey: prompt
            ]
        )
    }

    private func expire(requestID: String) {
        guard let request = pending.removeValue(forKey: requestID) else { return }
        request.retry.cancel()
        request.continuation.resume(returning: nil)
    }
}
