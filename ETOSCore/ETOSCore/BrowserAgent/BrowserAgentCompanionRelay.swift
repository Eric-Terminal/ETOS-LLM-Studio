// ============================================================================
// BrowserAgentCompanionRelay.swift
// ============================================================================
// ETOS LLM Studio
//
// watchOS 仅在用户明确开启委托时把 Browser Agent 操作交给已配对 iPhone。
// 委托仍沿用原聊天 sessionID，因此 iPhone 侧标签页不会跨会话混用。
// ============================================================================

import Foundation

#if canImport(WatchConnectivity)
import WatchConnectivity
#endif

public actor BrowserAgentCompanionRelay {
    public static let shared = BrowserAgentCompanionRelay()

    private static let messageKind = "etos.browserAgent.execute"

    public func execute(
        argumentsJSON: String,
        sessionID: UUID,
        runID: UUID,
        triggeringMessageID: UUID?,
        toolCallID: String,
        selectedMCPServerIDs: [UUID]
    ) async throws -> String {
        #if os(watchOS) && canImport(WatchConnectivity)
        guard WCSession.isSupported() else { throw BrowserAgentError.companionUnavailable }
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else {
            throw BrowserAgentError.companionUnavailable
        }
        return try await withCheckedThrowingContinuation { continuation in
            var message: [String: Any] = [
                    "kind": Self.messageKind,
                    "sessionID": sessionID.uuidString,
                    "runID": runID.uuidString,
                    "toolCallID": toolCallID,
                    "selectedMCPServerIDs": selectedMCPServerIDs.map(\.uuidString),
                    "argumentsJSON": argumentsJSON
            ]
            if let triggeringMessageID {
                message["triggeringMessageID"] = triggeringMessageID.uuidString
            }
            session.sendMessage(
                message,
                replyHandler: { reply in
                    if let result = reply["result"] as? String {
                        continuation.resume(returning: result)
                    } else {
                        continuation.resume(
                            throwing: BrowserAgentError.navigationFailed(
                                reply["error"] as? String
                                    ?? NSLocalizedString("iPhone 未返回浏览器操作结果。", comment: "Browser Agent empty companion reply")
                            )
                        )
                    }
                },
                errorHandler: { error in
                    continuation.resume(throwing: BrowserAgentError.navigationFailed(error.localizedDescription))
                }
            )
        }
        #else
        throw BrowserAgentError.companionUnavailable
        #endif
    }

    @MainActor
    public static func handleIncomingMessage(
        _ message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) -> Bool {
        #if os(iOS)
        guard message["kind"] as? String == messageKind else { return false }
        guard let rawSessionID = message["sessionID"] as? String,
              let sessionID = UUID(uuidString: rawSessionID),
              let rawRunID = message["runID"] as? String,
              let runID = UUID(uuidString: rawRunID),
              let toolCallID = message["toolCallID"] as? String,
              !toolCallID.isEmpty,
              let argumentsJSON = message["argumentsJSON"] as? String else {
            replyHandler([
                "error": NSLocalizedString("浏览器委托消息格式无效。", comment: "Browser Agent invalid companion message")
            ])
            return true
        }
        let triggeringMessageID = (message["triggeringMessageID"] as? String).flatMap(UUID.init(uuidString:))
        let selectedMCPServerIDs = (message["selectedMCPServerIDs"] as? [String] ?? [])
            .compactMap(UUID.init(uuidString:))
        Task {
            do {
                let result = try await BrowserAgentToolExecutor.shared.execute(
                    toolName: BrowserAgentToolDefinitions.toolName,
                    argumentsJSON: argumentsJSON,
                    sessionID: sessionID,
                    runID: runID,
                    triggeringMessageID: triggeringMessageID,
                    toolCallID: toolCallID,
                    selectedMCPServerIDs: selectedMCPServerIDs,
                    allowCompanionDelegation: false
                )
                replyHandler(["result": result])
            } catch {
                replyHandler(["error": error.localizedDescription])
            }
        }
        return true
        #else
        return false
        #endif
    }
}
