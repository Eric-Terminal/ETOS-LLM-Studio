// ============================================================================
// WatchContentViewTypes.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件负责 watchOS ContentView 使用的轻量路由、输入动作与包装类型。
// ============================================================================

import Foundation
import ETOSCore

enum WatchChatInputActionState: Equatable {
    case stop
    case send
    case quickRetry
    case speechInput
    case inactive

    static func resolve(isSending: Bool, hasSendableContent: Bool, canQuickRetry: Bool, isSpeechInputEnabled: Bool) -> Self {
        if isSending {
            return .stop
        }
        if hasSendableContent {
            return .send
        }
        if canQuickRetry {
            return .quickRetry
        }
        if isSpeechInputEnabled {
            return .speechInput
        }
        return .inactive
    }

    var systemImageName: String {
        switch self {
        case .stop:
            return "stop.circle.fill"
        case .send, .inactive:
            return "arrow.up"
        case .quickRetry:
            return "arrow.clockwise"
        case .speechInput:
            return "mic.fill"
        }
    }

    var isDisabled: Bool {
        self == .inactive
    }
}

enum WatchChatInputSubmission {
    static func normalizedText(from submittedText: String) -> String {
        submittedText.watchKeyboardUnescapedNewlines()
    }

    static func shouldUseBoundEditor(for currentText: String) -> Bool {
        // TextFieldLink 没有初始文本入口，已有草稿要走可绑定编辑页才能回填。
        !currentText.isEmpty
    }
}

struct WatchMessageActionsNavigationTarget: Identifiable, Hashable {
    let id: UUID
}

struct WatchMessageRewriteNavigationTarget: Identifiable, Hashable {
    let id: UUID
}

struct WatchSelectedMessagesExportNavigationTarget: Identifiable, Hashable {
    let id = UUID()
    let messageIDs: Set<UUID>
}

struct FullErrorContentWrapper: Identifiable {
    let id = UUID()
    let content: String
}

struct MessageJumpRequest: Equatable {
    let token = UUID()
    let messageID: UUID
}

enum WatchImportSourceHistory {
    nonisolated static let limit = 5

    nonisolated static func values(from rawValue: String, fallback: String = "") -> [String] {
        guard let data = rawValue.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            return normalized([fallback])
        }
        let history = normalized(decoded)
        return history.isEmpty ? normalized([fallback]) : history
    }

    nonisolated static func appending(_ source: String, to history: [String]) -> [String] {
        normalized([source] + history)
    }

    nonisolated static func rawValue(for history: [String]) -> String {
        let normalizedHistory = normalized(history)
        guard let data = try? JSONEncoder().encode(normalizedHistory),
              let rawValue = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return rawValue
    }

    nonisolated static func normalized(_ sources: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for source in sources {
            let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard seen.insert(trimmed).inserted else { continue }
            result.append(trimmed)
            if result.count == limit { break }
        }
        return result
    }
}
