// ============================================================================
// GuideConversationHistoryStore.swift
// ============================================================================
// 向导只保存各模式的上一段对话。编解码与磁盘操作隔离在 actor 中，不等待配置数据库启动。
// ============================================================================

import Foundation
import os

struct GuideConversationHistorySnapshot: Sendable {
    let messages: [GuideConversationMessage]
    let requestHistory: [ChatMessage]
    let streamingMessageID: UUID?
    let streamingContent: String
    let latestUserMessageID: UUID?
    let latestUserMessageAllowsEditing: Bool
}

struct GuideRestoredConversation: Sendable {
    let messages: [GuideConversationMessage]
    let requestHistory: [ChatMessage]
    let latestUserMessageID: UUID?
    let latestUserMessageAllowsEditing: Bool
    let latestTurnMessageIDs: Set<UUID>
}

public actor GuideConversationHistoryStore {
    public static let contextualHelp = GuideConversationHistoryStore(mode: .contextualHelp)
    public static let modelSetup = GuideConversationHistoryStore(mode: .modelSetup)

    private let mode: GuideMode
    private let directoryOverride: URL?
    private let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "GuideConversationHistory")

    public init(mode: GuideMode = .contextualHelp, directoryURL: URL? = nil) {
        self.mode = mode
        self.directoryOverride = directoryURL
    }

    func load() -> GuideRestoredConversation? {
        do {
            let url = try fileURL()
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let archive = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: url))
            guard archive.version == 1 else { return nil }
            let messages = archive.messages.map { message in
                GuideConversationMessage(
                    id: message.id, role: message.role, content: message.content,
                    toolCalls: message.tools.map { tool in
                        InternalToolCall(id: tool.id, toolName: tool.name, arguments: "{}", resultDisposition: tool.disposition)
                    }
                )
            }
            let latestIndex = messages.lastIndex { $0.role == .user }
            let latestID = latestIndex.map { messages[$0].id }
            return GuideRestoredConversation(
                messages: messages,
                requestHistory: archive.turns.compactMap { turn in
                    switch turn.role {
                    case .user: return ChatMessage(role: .user, content: turn.content)
                    case .assistant: return ChatMessage(role: .assistant, content: turn.content)
                    default: return nil
                    }
                },
                latestUserMessageID: latestID,
                latestUserMessageAllowsEditing: latestID == archive.latestUserMessageID && archive.latestUserMessageAllowsEditing,
                latestTurnMessageIDs: latestIndex.map { Set(messages[$0...].map(\.id)) } ?? []
            )
        } catch {
            // 历史损坏或暂不可读时仍允许用户打开向导；错误日志不包含对话原文。
            logger.error("读取向导历史失败：\(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func save(_ snapshot: GuideConversationHistorySnapshot) {
        do {
            let url = try fileURL()
            if snapshot.messages.isEmpty {
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
                return
            }
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Archive(snapshot: snapshot))
            try data.write(to: url, options: .atomic)
        } catch {
            logger.error("保存向导历史失败：\(error.localizedDescription, privacy: .public)")
        }
    }

    private func fileURL() throws -> URL {
        let directory: URL
        if let directoryOverride {
            directory = directoryOverride
        } else {
            directory = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            ).appendingPathComponent("GuideConversations", isDirectory: true)
        }
        return directory.appendingPathComponent("\(mode.rawValue).json")
    }

    private struct Archive: Codable {
        let version: Int
        let messages: [StoredMessage]
        let turns: [StoredTurn]
        let latestUserMessageID: UUID?
        let latestUserMessageAllowsEditing: Bool

        init(snapshot: GuideConversationHistorySnapshot) {
            version = 1
            latestUserMessageID = snapshot.latestUserMessageID
            latestUserMessageAllowsEditing = snapshot.latestUserMessageAllowsEditing
            messages = snapshot.messages.compactMap { message in
                guard message.role != .tool else { return nil }
                let content = message.id == snapshot.streamingMessageID ? snapshot.streamingContent : message.content
                guard !content.isEmpty || !message.toolCalls.isEmpty else { return nil }
                return StoredMessage(
                    id: message.id, role: message.role, content: content,
                    tools: message.toolCalls.map {
                        StoredTool(id: $0.id, name: $0.toolName, disposition: $0.resultDisposition)
                    }
                )
            }
            // 工具参数可能含用户新提供的密钥，结果可能含整段源码。
            // 存档仅保留聊天正文和工具状态，绝不序列化原始调用、页面快照或待执行操作。
            var turns = snapshot.requestHistory.compactMap { message -> StoredTurn? in
                switch message.role {
                case .user: return StoredTurn(role: .user, content: message.content)
                case .assistant where (message.toolCalls ?? []).isEmpty:
                    return StoredTurn(role: .assistant, content: message.content)
                default: return nil
                }
            }
            if snapshot.streamingMessageID != nil, !snapshot.streamingContent.isEmpty {
                turns.append(StoredTurn(role: .assistant, content: snapshot.streamingContent))
            }
            self.turns = turns
        }
    }

    private struct StoredMessage: Codable {
        let id: UUID
        let role: GuideConversationMessage.Role
        let content: String
        let tools: [StoredTool]
    }

    private struct StoredTool: Codable {
        let id: String
        let name: String
        let disposition: InternalToolCallResultDisposition?
    }

    private struct StoredTurn: Codable {
        let role: GuideConversationMessage.Role
        let content: String
    }
}
