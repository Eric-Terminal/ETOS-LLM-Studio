// ============================================================================
// ShortcutExecutionRelay.swift
// ============================================================================
// watchOS <-> iOS 快捷指令执行中继
// ============================================================================

import Foundation
#if canImport(WatchConnectivity)
import WatchConnectivity
#endif

#if canImport(WatchConnectivity)
@MainActor
public final class ShortcutExecutionRelay {
    public static let shared = ShortcutExecutionRelay()

    public static let messageTypeKey = "type"
    public static let executeType = "shortcut.relay.execute"
    public static let requestPayloadKey = "request"
    public static let resultPayloadKey = "result"
    public static let errorPayloadKey = "error"

    private init() {}

    public func executeViaCompanion(request: ShortcutToolExecutionRequest) async throws -> ShortcutToolExecutionResult {
        guard WCSession.isSupported() else {
            throw ShortcutToolError.executionFailed(NSLocalizedString("设备不支持 WatchConnectivity。", comment: ""))
        }

        #if os(watchOS)
        let session = WCSession.default
        guard session.activationState == .activated else {
            throw ShortcutToolError.executionFailed(NSLocalizedString("连接到 iPhone 失败，请稍后重试。", comment: ""))
        }
        guard session.isReachable else {
            throw ShortcutToolError.executionFailed(NSLocalizedString("iPhone 当前不可达，无法中继执行。", comment: ""))
        }

        let encoder = JSONEncoder()
        let data = try encoder.encode(request)
        let requestText = String(decoding: data, as: UTF8.self)
        let message: [String: Any] = [
            Self.messageTypeKey: Self.executeType,
            Self.requestPayloadKey: requestText
        ]

        return try await withCheckedThrowingContinuation { continuation in
            session.sendMessage(message) { reply in
                if let errorMessage = reply[Self.errorPayloadKey] as? String {
                    continuation.resume(throwing: ShortcutToolError.executionFailed(errorMessage))
                    return
                }

                guard let resultText = reply[Self.resultPayloadKey] as? String,
                      let resultData = resultText.data(using: .utf8),
                      let result = try? JSONDecoder().decode(ShortcutToolExecutionResult.self, from: resultData) else {
                    continuation.resume(throwing: ShortcutToolError.executionFailed(NSLocalizedString("中继返回结果解析失败。", comment: "")))
                    return
                }
                continuation.resume(returning: result)
            } errorHandler: { error in
                continuation.resume(throwing: ShortcutToolError.executionFailed(error.localizedDescription))
            }
        }
        #else
        throw ShortcutToolError.executionFailed(NSLocalizedString("仅 watchOS 端支持发起中继执行请求。", comment: ""))
        #endif
    }

    public func handleIncomingMessage(_ message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) -> Bool {
        guard let type = message[Self.messageTypeKey] as? String, type == Self.executeType else {
            return false
        }

        guard let requestText = message[Self.requestPayloadKey] as? String,
              let requestData = requestText.data(using: .utf8),
              let request = try? JSONDecoder().decode(ShortcutToolExecutionRequest.self, from: requestData) else {
            replyHandler([Self.errorPayloadKey: NSLocalizedString("中继请求格式错误。", comment: "")])
            return true
        }

        Task {
            let result = await ShortcutToolManager.shared.executeRelayRequest(request)
            if let data = try? JSONEncoder().encode(result),
               let text = String(data: data, encoding: .utf8) {
                replyHandler([Self.resultPayloadKey: text])
            } else {
                replyHandler([Self.errorPayloadKey: NSLocalizedString("中继结果编码失败。", comment: "")])
            }
        }

        return true
    }
}
#endif
