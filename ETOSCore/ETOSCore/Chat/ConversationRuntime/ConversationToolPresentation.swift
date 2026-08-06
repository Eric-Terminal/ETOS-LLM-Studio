// ============================================================================
// ConversationToolPresentation.swift
// ============================================================================
// ETOS LLM Studio
//
// 为会话工具卡预计算目标会话、最新运行状态与回复摘要。调用方应在后台
// 执行加载，避免在 SwiftUI 渲染链路中解析 JSON 或读取数据库。
// ============================================================================

import Foundation

public struct ConversationToolTargetPresentation: Identifiable, Equatable, Sendable {
    public var id: UUID { sessionID }
    public let sessionID: UUID
    public let title: String
    public let runStatus: ConversationRunStatus?
    public let replyPreview: String?

    public init(
        sessionID: UUID,
        title: String,
        runStatus: ConversationRunStatus?,
        replyPreview: String?
    ) {
        self.sessionID = sessionID
        self.title = title
        self.runStatus = runStatus
        self.replyPreview = replyPreview
    }
}

public enum ConversationToolPresentationLoader {
    /// 返回空数组表示该工具不指向具体会话，或结果尚未包含可识别的目标。
    public static func loadTargets(for toolCall: InternalToolCall) -> [ConversationToolTargetPresentation] {
        guard ConversationToolDefinitions.containsExposedName(toolCall.toolName) else { return [] }
        let targetIDs = targetSessionIDs(for: toolCall)
        guard !targetIDs.isEmpty else { return [] }

        let sessionsByID = Dictionary(uniqueKeysWithValues: Persistence.loadChatSessions().map { ($0.id, $0) })
        return targetIDs.map { sessionID in
            let run = Persistence.loadLatestConversationRun(sessionID: sessionID)
            let replyPreview = Persistence.loadMessages(for: sessionID)
                .last(where: { message in
                    message.role == .assistant
                        && !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                })
                .map { message in
                    String(message.content.trimmingCharacters(in: .whitespacesAndNewlines).prefix(180))
                }
            return ConversationToolTargetPresentation(
                sessionID: sessionID,
                title: sessionsByID[sessionID]?.name ?? String(sessionID.uuidString.prefix(8)),
                runStatus: run?.status,
                replyPreview: replyPreview
            )
        }
    }

    static func targetSessionIDs(for toolCall: InternalToolCall) -> [UUID] {
        var ids: [UUID] = []
        if let result = decodedJSON(toolCall.result) {
            collectTargetSessionIDs(from: result, into: &ids)
        }
        if let arguments = decodedJSON(toolCall.arguments) {
            collectTargetSessionIDs(from: arguments, into: &ids)
        }

        var seen = Set<UUID>()
        return ids.filter { seen.insert($0).inserted }
    }

    private static func decodedJSON(_ text: String?) -> JSONValue? {
        guard let text,
              let data = text.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    private static func collectTargetSessionIDs(from value: JSONValue, into ids: inout [UUID]) {
        switch value {
        case .dictionary(let dictionary):
            if case .string(let rawID)? = dictionary["conversation_id"],
               let id = UUID(uuidString: rawID) {
                ids.append(id)
            }
            if case .array(let values)? = dictionary["conversation_ids"] {
                for value in values {
                    if case .string(let rawID) = value,
                       let id = UUID(uuidString: rawID) {
                        ids.append(id)
                    }
                }
            }
            for nestedValue in dictionary.values {
                collectTargetSessionIDs(from: nestedValue, into: &ids)
            }
        case .array(let values):
            for nestedValue in values {
                collectTargetSessionIDs(from: nestedValue, into: &ids)
            }
        case .string, .int, .double, .bool, .null:
            break
        }
    }
}
