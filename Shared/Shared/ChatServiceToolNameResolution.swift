// ============================================================================
// ChatServiceToolNameResolution.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责 ChatService 工具名清洗、长度限制与工具调用名称解析。
// ============================================================================

import CryptoKit
import Foundation
import os.log

extension ChatService {
    private static let toolNameRegex = try! NSRegularExpression(pattern: "[^a-zA-Z0-9_.-]", options: [])

    func sanitizedToolName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        let sanitized = Self.toolNameRegex.stringByReplacingMatches(in: trimmed, options: [], range: range, withTemplate: "_")
        return enforceToolNameLimit(sanitized, source: trimmed)
    }

    private func enforceToolNameLimit(_ name: String, source: String) -> String {
        let maxLength = 64
        guard name.count > maxLength else { return name }
        let digest = SHA256.hash(data: Data(source.utf8))
        let hash = digest.compactMap { String(format: "%02x", $0) }.joined().prefix(8)
        let prefixLength = maxLength - 1 - hash.count
        let prefix = name.prefix(prefixLength)
        return "\(prefix)_\(hash)"
    }

    func resolveToolName(_ name: String, availableTools: [InternalToolDefinition]) -> String {
        if availableTools.contains(where: { $0.name == name }) {
            return name
        }
        let matches = availableTools.filter { sanitizedToolName($0.name) == name }
        if matches.count == 1 {
            return matches[0].name
        }
        if matches.count > 1 {
            let names = matches.map(\.name).joined(separator: ", ")
            logger.warning("工具名在清洗后发生冲突: '\(names)'")
        }
        return name
    }

    func resolveToolCalls(_ toolCalls: [InternalToolCall], availableTools: [InternalToolDefinition]) -> [InternalToolCall] {
        toolCalls.map { call in
            let resolvedName = resolveToolName(call.toolName, availableTools: availableTools)
            guard resolvedName != call.toolName else { return call }
            return InternalToolCall(
                id: call.id,
                toolName: resolvedName,
                arguments: call.arguments,
                result: call.result,
                providerSpecificFields: call.providerSpecificFields
            )
        }
    }
}
