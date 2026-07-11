// ============================================================================
// RoleplayMacroExpansionBridge.swift
// ============================================================================
// ETOS LLM Studio
//
// 让助手脚本注册的动态宏参与原生聊天与 generate 提示词构建。
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
