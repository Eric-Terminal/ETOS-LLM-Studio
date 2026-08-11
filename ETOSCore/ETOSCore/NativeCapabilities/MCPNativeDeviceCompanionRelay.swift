// ============================================================================
// MCPNativeDeviceCompanionRelay.swift
// ============================================================================
// ETOS LLM Studio
//
// watchOS 对缺失的设备能力使用配对 iPhone；只接受设备操作白名单内的工具。
// ============================================================================

import Foundation
#if canImport(WatchConnectivity)
@preconcurrency import WatchConnectivity
#endif

actor MCPNativeDeviceCompanionRelay {
    static let shared = MCPNativeDeviceCompanionRelay()

    private static let messageKind = "etos.nativeDevice.execute"

    func execute(toolName: String, arguments: [String: Any]) async throws -> [String: Any] {
        #if os(watchOS) && canImport(WatchConnectivity)
        guard MCPNativeDeviceToolDefinitions.contains(toolName) else {
            throw MCPNativeCapabilityError.unsupportedTool(toolName)
        }
        guard WCSession.isSupported() else {
            throw companionUnavailable
        }
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else {
            throw companionUnavailable
        }
        let data = try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])
        let argumentsJSON = String(decoding: data, as: UTF8.self)
        return try await withCheckedThrowingContinuation { continuation in
            session.sendMessage(
                [
                    "kind": Self.messageKind,
                    "toolName": toolName,
                    "argumentsJSON": argumentsJSON
                ],
                replyHandler: { reply in
                    if let error = reply["error"] as? String {
                        continuation.resume(throwing: MCPNativeCapabilityError.unavailable(error))
                        return
                    }
                    guard let resultJSON = reply["resultJSON"] as? String,
                          let resultData = resultJSON.data(using: .utf8),
                          let result = try? JSONSerialization.jsonObject(with: resultData) as? [String: Any] else {
                        continuation.resume(throwing: MCPNativeCapabilityError.unavailable(
                            NSLocalizedString("iPhone 未返回有效的原生工具结果。", comment: "Invalid native companion response")
                        ))
                        return
                    }
                    var delegated = result
                    delegated["delegated_to_iphone"] = true
                    continuation.resume(returning: delegated)
                },
                errorHandler: { error in
                    continuation.resume(throwing: MCPNativeCapabilityError.unavailable(error.localizedDescription))
                }
            )
        }
        #else
        throw companionUnavailable
        #endif
    }

    @MainActor
    static func handleIncomingMessage(
        _ message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) -> Bool {
        #if os(iOS)
        guard message["kind"] as? String == messageKind else { return false }
        guard let toolName = message["toolName"] as? String,
              MCPNativeDeviceToolDefinitions.contains(toolName),
              let argumentsJSON = message["argumentsJSON"] as? String else {
            replyHandler([
                "error": NSLocalizedString("原生设备工具委托消息格式无效。", comment: "Invalid native device companion message")
            ])
            return true
        }
        Task {
            do {
                let result = try await MCPNativeDeviceExecutor.shared.execute(
                    toolName: toolName,
                    argumentsJSON: argumentsJSON
                )
                replyHandler(["resultJSON": try MCPNativeJSON.text(result)])
            } catch {
                replyHandler(["error": error.localizedDescription])
            }
        }
        return true
        #else
        return false
        #endif
    }

    private var companionUnavailable: MCPNativeCapabilityError {
        .unavailable(
            NSLocalizedString("配对 iPhone 当前不可达，无法执行该设备能力。", comment: "Native device companion unavailable")
        )
    }
}
