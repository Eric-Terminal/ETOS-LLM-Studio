// ============================================================================
// ThirdPartyImportChatGPT.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件负责解析 ChatGPT 导出的 conversations.json 会话数据。
// ============================================================================

import Foundation

extension ThirdPartyImportService {
    static func parseChatGPT(fileURL: URL) throws -> ParsedPayload {
        let rootURL: URL
        if isDirectory(fileURL) {
            guard let conversationsURL = findFileInDirectory(
                fileURL,
                preferredNames: ["conversations.json"]
            ) else {
                throw ThirdPartyImportError.unsupportedBackupFormat(
                    reason: NSLocalizedString("未在目录中找到 conversations.json。", comment: "ChatGPT import missing conversations file")
                )
            }
            rootURL = conversationsURL
        } else {
            rootURL = fileURL
        }

        if isLikelyCompressedBackup(rootURL) {
            throw ThirdPartyImportError.unsupportedBackupFormat(
                reason: NSLocalizedString("当前版本暂不支持直接读取压缩包，请先解压后导入 conversations.json。", comment: "ChatGPT import compressed backup unsupported")
            )
        }

        guard let data = try? Data(contentsOf: rootURL) else {
            throw ThirdPartyImportError.fileNotReadable
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            throw ThirdPartyImportError.invalidJSON
        }

        let sessions = try parseChatGPTJSONRoot(json)
        guard !sessions.isEmpty else {
            throw ThirdPartyImportError.noImportableContent
        }

        return ParsedPayload(providers: [], sessions: sessions, warnings: [])
    }

    static func parseChatGPTJSONRoot(_ json: Any) throws -> [SyncedSession] {
        let conversations: [[String: Any]]
        if let list = json as? [[String: Any]] {
            conversations = list
        } else if let root = json as? [String: Any] {
            let list: [[String: Any]] = normalizeJSONArray(root["conversations"]).compactMap(dictionary)
            if !list.isEmpty {
                conversations = list
            } else if root["mapping"] != nil || root["messages"] != nil {
                conversations = [root]
            } else {
                throw ThirdPartyImportError.unsupportedBackupFormat(
                    reason: NSLocalizedString("未识别到 ChatGPT conversations.json 结构。", comment: "ChatGPT import unrecognized conversations structure")
                )
            }
        } else {
            throw ThirdPartyImportError.unsupportedBackupFormat(
                reason: NSLocalizedString("未识别到 ChatGPT conversations.json 结构。", comment: "ChatGPT import unrecognized conversations structure")
            )
        }

        var sessions: [SyncedSession] = []
        sessions.reserveCapacity(conversations.count)

        for (index, conversation) in conversations.enumerated() {
            let title = nonEmpty(string(conversation["title"])) ?? String(format: NSLocalizedString("ChatGPT 对话 %d", comment: "ChatGPT imported conversation fallback title"), index + 1)

            let messages: [ChatMessage]
            if let mapping = dictionary(conversation["mapping"]) {
                messages = extractChatGPTTreeMessages(mapping: mapping, currentNode: string(conversation["current_node"]))
            } else {
                messages = extractChatGPTFlatMessages(normalizeJSONArray(conversation["messages"]))
            }

            guard !messages.isEmpty else { continue }
            let session = ChatSession(
                id: stableUUID(from: string(conversation["id"])) ?? UUID(),
                name: title,
                isTemporary: false
            )
            sessions.append(SyncedSession(session: session, messages: messages))
        }

        return sessions
    }

    static func extractChatGPTTreeMessages(
        mapping: [String: Any],
        currentNode: String?
    ) -> [ChatMessage] {
        var chain: [String] = []
        var nodeID = nonEmpty(currentNode)

        if nodeID == nil {
            for (candidateID, nodeAny) in mapping {
                guard let node = dictionary(nodeAny) else { continue }
                let children = normalizeJSONArray(node["children"])
                if children.isEmpty {
                    nodeID = candidateID
                    break
                }
            }
        }

        while let id = nodeID, let node = dictionary(mapping[id]) {
            chain.insert(id, at: 0)
            nodeID = nonEmpty(string(node["parent"]))
        }

        var result: [ChatMessage] = []
        for id in chain {
            guard let node = dictionary(mapping[id]),
                  let message = dictionary(node["message"]) else {
                continue
            }

            let role = mapMessageRole(string(dictionary(message["author"])?["role"]))
            if role == .tool { continue }

            let content = extractChatGPTMessageContent(message)
            guard !content.isEmpty else { continue }

            var chatMessage = ChatMessage(
                id: stableUUID(from: string(message["id"])) ?? UUID(),
                role: role,
                content: content
            )
            if let createdAt = parseDate(message["create_time"]) {
                chatMessage.responseMetrics = MessageResponseMetrics(
                    requestStartedAt: createdAt,
                    responseCompletedAt: createdAt
                )
            }
            result.append(chatMessage)
        }

        return result
    }

    static func extractChatGPTFlatMessages(_ rawMessages: [Any]) -> [ChatMessage] {
        rawMessages.compactMap { messageAny in
            guard let message = dictionary(messageAny) else { return nil }
            let role = mapMessageRole(string(message["role"]) ?? string(dictionary(message["author"])?["role"]))
            var content = nonEmpty(string(message["content"])) ?? ""
            if content.isEmpty {
                content = flattenText(message["parts"]) ?? flattenText(dictionary(message["content"])?["parts"]) ?? ""
            }
            guard !content.isEmpty else { return nil }
            return ChatMessage(
                id: stableUUID(from: string(message["id"])) ?? UUID(),
                role: role,
                content: content
            )
        }
    }

    static func extractChatGPTMessageContent(_ message: [String: Any]) -> String {
        if let content = nonEmpty(string(message["content"])) {
            return content
        }

        if let contentObject = dictionary(message["content"]) {
            if let partsText = flattenText(contentObject["parts"]), !partsText.isEmpty {
                return partsText
            }
            if let text = nonEmpty(string(contentObject["text"])) {
                return text
            }
        }

        if let partsText = flattenText(message["parts"]), !partsText.isEmpty {
            return partsText
        }

        return ""
    }
}
