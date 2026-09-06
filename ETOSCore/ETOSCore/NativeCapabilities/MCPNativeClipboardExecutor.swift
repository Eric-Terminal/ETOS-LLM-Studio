// ============================================================================
// MCPNativeClipboardExecutor.swift
// ============================================================================
// ETOS LLM Studio
//
// 剪贴板只读写当前设备的纯文本。
// ============================================================================

import Foundation
#if canImport(UIKit)
import UIKit
#endif

actor MCPNativeClipboardExecutor {
    func execute(toolName: String, arguments: [String: Any]) async throws -> [String: Any] {
        #if os(iOS) && canImport(UIKit)
        return try await MainActor.run {
            switch toolName {
            case "clipboard.read":
                let text = UIPasteboard.general.string
                return [
                    "text": text ?? NSNull(),
                    "has_text": text != nil
                ]
            case "clipboard.write":
                UIPasteboard.general.string = try arguments.nativeRequiredString("text")
                return ["written": true]
            case "clipboard.clear":
                UIPasteboard.general.items = []
                return ["cleared": true]
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
