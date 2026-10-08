// ============================================================================
// LocalDebugServerWebConsole.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件负责本地调试客户端的 Web 控制台数据编解码，
// 以及 providers、sessions 和 memories 的同步命令。
// ============================================================================

import Combine
import Foundation

extension LocalDebugServer {
    nonisolated static func parseWebConsoleDate(_ value: String) -> Date? {
        let preciseFormatter = ISO8601DateFormatter()
        preciseFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let precise = preciseFormatter.date(from: value) {
            return precise
        }
        let defaultFormatter = ISO8601DateFormatter()
        defaultFormatter.formatOptions = [.withInternetDateTime]
        return defaultFormatter.date(from: value)
    }

    nonisolated static func formatWebConsoleDate(_ value: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: value)
    }

    nonisolated func makeWebConsoleJSONEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    nonisolated func makeWebConsoleJSONDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()

            if let timestamp = try? container.decode(Double.self) {
                return Date(timeIntervalSince1970: timestamp)
            }
            if let timestamp = try? container.decode(Int.self) {
                return Date(timeIntervalSince1970: TimeInterval(timestamp))
            }
            if let value = try? container.decode(String.self) {
                if let parsed = Self.parseWebConsoleDate(value) {
                    return parsed
                }
                if let timestamp = Double(value) {
                    return Date(timeIntervalSince1970: timestamp)
                }
            }

            throw DecodingError.dataCorruptedError(in: container, debugDescription: "无法解析日期")
        }
        return decoder
    }

    nonisolated func encodeWebConsoleJSONObject<T: Encodable>(_ value: T) throws -> Any {
        let data = try makeWebConsoleJSONEncoder().encode(value)
        return try JSONSerialization.jsonObject(with: data)
    }

    nonisolated func decodeWebConsoleObject<T: Decodable>(_ raw: Any, as type: T.Type) throws -> T {
        let data = try JSONSerialization.data(withJSONObject: raw)
        return try makeWebConsoleJSONDecoder().decode(type, from: data)
    }

    func handleProvidersList() async -> [String: Any] {
        await runDebugDataOperation { self.readDebugProviders() }
    }

    nonisolated private func readDebugProviders() -> [String: Any] {
        let providers = ConfigLoader.loadProviders()
        do {
            let payload = try encodeWebConsoleJSONObject(providers)
            return ["status": "ok", "providers": payload, "count": providers.count]
        } catch {
            return ["status": "error", "message": "提供商序列化失败：\(error.localizedDescription)"]
        }
    }

    func handleProvidersSave(_ json: [String: Any]) async -> [String: Any] {
        let request = LocalDebugJSONObject(value: json)
        return await runDebugDataOperation { self.replaceDebugProviders(request.value) }
    }

    nonisolated private func replaceDebugProviders(_ json: [String: Any]) -> [String: Any] {
        guard let providersRaw = json["providers"] else {
            return ["status": "error", "message": "缺少 providers 参数"]
        }

        do {
            let providers = try decodeWebConsoleObject(providersRaw, as: [Provider].self)
            let result = LocalDebugProviderStore.perform { current in
                current = providers
                return ["status": "ok", "message": "提供商配置已保存", "count": providers.count]
            }
            if result["status"] as? String == "ok" { ChatService.shared.reloadProviders() }
            return result
        } catch {
            return ["status": "error", "message": "保存提供商失败：\(error.localizedDescription)"]
        }
    }

    func handleSessionsList() async -> [String: Any] {
        await runDebugDataOperation { self.readDebugSessions() }
    }

    nonisolated private func readDebugSessions() -> [String: Any] {
        let sessions = Persistence.loadChatSessions()
        do {
            let payload = try encodeWebConsoleJSONObject(sessions)
            return ["status": "ok", "sessions": payload, "count": sessions.count]
        } catch {
            return ["status": "error", "message": "会话序列化失败：\(error.localizedDescription)"]
        }
    }

    func handleSessionGet(_ json: [String: Any]) async -> [String: Any] {
        let request = LocalDebugJSONObject(value: json)
        return await runDebugDataOperation { self.readDebugSession(request.value) }
    }

    nonisolated private func readDebugSession(_ json: [String: Any]) -> [String: Any] {
        guard let sessionIDString = json["session_id"] as? String,
              let sessionID = UUID(uuidString: sessionIDString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return ["status": "error", "message": "缺少或无效的 session_id"]
        }

        let sessions = Persistence.loadChatSessions()
        guard let session = sessions.first(where: { $0.id == sessionID }) else {
            return ["status": "error", "message": "未找到会话"]
        }

        let messages = Persistence.loadMessages(for: sessionID)
        do {
            let sessionPayload = try encodeWebConsoleJSONObject(session)
            let messagesPayload = try encodeWebConsoleJSONObject(messages)
            return [
                "status": "ok",
                "session": sessionPayload,
                "messages": messagesPayload,
                "message_count": messages.count
            ]
        } catch {
            return ["status": "error", "message": "会话详情序列化失败：\(error.localizedDescription)"]
        }
    }

    func handleSessionCreate(_ json: [String: Any]) async -> [String: Any] {
        let request = LocalDebugJSONObject(value: json)
        let insertSession = insertSession
        do {
            let created = try await Task.detached(priority: .userInitiated) {
                let rawName = (request.value["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let name = rawName?.isEmpty == false ? rawName! : NSLocalizedString("新的对话", comment: "新会话默认名称")
                let session = ChatSession(id: UUID(), name: name, topicPrompt: request.value["topic_prompt"] as? String,
                    enhancedPrompt: request.value["enhanced_prompt"] as? String, isTemporary: false)
                let response = LocalDebugJSONObject(value: ["status": "ok", "message": "会话已创建",
                    "session": try self.encodeWebConsoleJSONObject(session)])
                try insertSession(session, [])
                return (session, response)
            }.value
            var liveSessions = ChatService.shared.chatSessionsSubject.value
            liveSessions.insert(created.0, at: 0)
            ChatService.shared.chatSessionsSubject.send(liveSessions)
            return created.1.value
        } catch {
            return ["status": "error", "message": error.localizedDescription]
        }
    }

    func handleSessionDelete(_ json: [String: Any]) async -> [String: Any] {
        let request = LocalDebugJSONObject(value: json)
        return await runDebugDataOperation { self.deleteDebugSession(request.value) }
    }

    nonisolated private func deleteDebugSession(_ json: [String: Any]) -> [String: Any] {
        guard let sessionIDString = json["session_id"] as? String,
              let sessionID = UUID(uuidString: sessionIDString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return ["status": "error", "message": "缺少或无效的 session_id"]
        }

        let sessions = ChatService.shared.chatSessionsSubject.value
        guard let target = sessions.first(where: { $0.id == sessionID }) else {
            return ["status": "error", "message": "未找到会话"]
        }

        ChatService.shared.deleteSessions([target])
        return ["status": "ok", "message": "会话已删除", "session_id": sessionID.uuidString]
    }

    func handleSessionUpdateMeta(_ json: [String: Any]) async -> [String: Any] {
        let request = LocalDebugJSONObject(value: json)
        return await runDebugDataOperation { self.updateDebugSessionMetadata(request.value) }
    }

    nonisolated private func updateDebugSessionMetadata(_ json: [String: Any]) -> [String: Any] {
        guard let sessionRaw = json["session"] else {
            return ["status": "error", "message": "缺少 session 参数"]
        }

        do {
            let session = try decodeWebConsoleObject(sessionRaw, as: ChatSession.self)
            let existingSessions = Persistence.loadChatSessions()
            guard existingSessions.contains(where: { $0.id == session.id }) else {
                return ["status": "error", "message": "未找到会话"]
            }

            ChatService.shared.updateSession(session)
            let payload = try encodeWebConsoleJSONObject(session)
            return ["status": "ok", "message": "会话元数据已更新", "session": payload]
        } catch {
            return ["status": "error", "message": "更新会话元数据失败：\(error.localizedDescription)"]
        }
    }

    func handleSessionUpdateMessages(_ json: [String: Any]) async -> [String: Any] {
        let request = LocalDebugJSONObject(value: json)
        return await runDebugDataOperation { await self.updateDebugSessionMessages(request.value) }
    }

    nonisolated private func updateDebugSessionMessages(_ json: [String: Any]) async -> [String: Any] {
        guard let sessionIDString = json["session_id"] as? String,
              let sessionID = UUID(uuidString: sessionIDString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return ["status": "error", "message": "缺少或无效的 session_id"]
        }
        guard let messagesRaw = json["messages"] else {
            return ["status": "error", "message": "缺少 messages 参数"]
        }

        do {
            let messages = try decodeWebConsoleObject(messagesRaw, as: [ChatMessage].self)
            Persistence.saveMessages(messages, for: sessionID)
            await Persistence.flushPendingMessageWritesForSyncSnapshotAsync()

            if ChatService.shared.currentSessionSubject.value?.id == sessionID {
                ChatService.shared.reloadCurrentSessionMessagesFromPersistence()
            }

            return ["status": "ok", "message": "会话消息已更新", "count": messages.count]
        } catch {
            return ["status": "error", "message": "更新会话消息失败：\(error.localizedDescription)"]
        }
    }

    func handleMemoriesList() async -> [String: Any] {
        await runDebugDataOperation { await self.readDebugMemories() }
    }

    nonisolated private func readDebugMemories() async -> [String: Any] {
        let memories = await MemoryManager.shared.getAllMemories()
        do {
            let payload = try encodeWebConsoleJSONObject(memories)
            let activeCount = memories.filter { !$0.isArchived }.count
            return [
                "status": "ok",
                "memories": payload,
                "count": memories.count,
                "active_count": activeCount
            ]
        } catch {
            return ["status": "error", "message": "记忆序列化失败：\(error.localizedDescription)"]
        }
    }

    func handleMemoryUpdate(_ json: [String: Any]) async -> [String: Any] {
        let request = LocalDebugJSONObject(value: json)
        return await runDebugDataOperation { await self.updateDebugMemory(request.value) }
    }

    nonisolated private func updateDebugMemory(_ json: [String: Any]) async -> [String: Any] {
        guard let memoryIDString = json["memory_id"] as? String,
              let memoryID = UUID(uuidString: memoryIDString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return ["status": "error", "message": "缺少或无效的 memory_id"]
        }

        let memories = await MemoryManager.shared.getAllMemories()
        guard let existing = memories.first(where: { $0.id == memoryID }) else {
            return ["status": "error", "message": "未找到记忆"]
        }

        let content = (json["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasContent = content != nil
        let hasArchive = json["is_archived"] != nil
        guard hasContent || hasArchive else {
            return ["status": "error", "message": "至少提供 content 或 is_archived 中的一个"]
        }
        if let content, content.isEmpty {
            return ["status": "error", "message": "content 不能为空字符串"]
        }

        if hasContent {
            var updated = existing
            updated.content = content ?? existing.content
            if let isArchived = json["is_archived"] as? Bool {
                updated.isArchived = isArchived
            }
            await MemoryManager.shared.updateMemory(item: updated)
            return [
                "status": "ok",
                "message": "记忆已更新",
                "memory_id": updated.id.uuidString,
                "reembedded": MemoryManager.shared.isEmbeddingModelConfigured()
            ]
        }

        if let isArchived = json["is_archived"] as? Bool {
            if isArchived {
                await MemoryManager.shared.archiveMemory(existing)
            } else {
                await MemoryManager.shared.unarchiveMemory(existing)
            }
            return [
                "status": "ok",
                "message": "记忆归档状态已更新",
                "memory_id": existing.id.uuidString,
                "is_archived": isArchived,
                "reembedded": false
            ]
        }

        return ["status": "error", "message": "无效的更新参数"]
    }

    func handleMemoryArchive(_ json: [String: Any]) async -> [String: Any] {
        var payload = json
        payload["is_archived"] = true
        return await handleMemoryUpdate(payload)
    }

    func handleMemoryUnarchive(_ json: [String: Any]) async -> [String: Any] {
        var payload = json
        payload["is_archived"] = false
        return await handleMemoryUpdate(payload)
    }

    func handleMemoriesReembedAll() async -> [String: Any] {
        await runDebugDataOperation { await self.reembedDebugMemories() }
    }

    nonisolated private func reembedDebugMemories() async -> [String: Any] {
        do {
            let summary = try await MemoryManager.shared.reembedAllMemories()
            return [
                "status": "ok",
                "message": "记忆重嵌入完成",
                "processed_memories": summary.processedMemories,
                "chunk_count": summary.chunkCount
            ]
        } catch {
            return ["status": "error", "message": "重嵌入失败：\(error.localizedDescription)"]
        }
    }
}
