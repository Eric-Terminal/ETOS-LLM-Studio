// ============================================================================
// MCPNativeClipboardExecutor.swift
// ============================================================================
// ETOS LLM Studio
//
// 剪贴板只读写纯文本；watchOS 通过配对 iPhone 执行。
// ============================================================================

import Foundation
#if canImport(UIKit)
import UIKit
#endif

actor MCPNativeClipboardExecutor {
    func execute(toolName: String, arguments: [String: Any]) async throws -> [String: Any] {
        #if os(watchOS)
        return try await MCPNativeDeviceCompanionRelay.shared.execute(
            toolName: toolName,
            arguments: arguments
        )
        #elseif canImport(UIKit)
        return try await MainActor.run {
            switch toolName {
            case "clipboard.read":
                let text = UIPasteboard.general.string
                return [
                    "text": text ?? NSNull(),
                    "has_text": text != nil,
                    "delegated_to_iphone": false
                ]
            case "clipboard.write":
                UIPasteboard.general.string = try arguments.nativeRequiredString("text")
                return ["written": true, "delegated_to_iphone": false]
            case "clipboard.clear":
                UIPasteboard.general.items = []
                return ["cleared": true, "delegated_to_iphone": false]
            default:
                throw MCPNativeCapabilityError.unsupportedTool(toolName)
            }
        }
        #else
        throw MCPNativeCapabilityError.unavailable(
            NSLocalizedString("当前平台没有可用的系统剪贴板。", comment: "Clipboard unavailable")
        )
        #endif
    }
}
