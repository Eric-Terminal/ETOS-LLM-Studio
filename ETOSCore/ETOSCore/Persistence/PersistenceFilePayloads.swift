// ============================================================================
// PersistenceFilePayloads.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责 Persistence 相关的会话文件、请求日志与旧版迁移文件格式定义。
// ============================================================================

import Foundation

struct SessionIndexItemPayload: Codable {
    let id: UUID
    let name: String
    let updatedAt: String
}

struct SessionIndexFilePayload: Codable {
    let schemaVersion: Int
    let updatedAt: String
    let sessions: [SessionIndexItemPayload]
}

struct SessionPromptsPayload: Codable {
    let topicPrompt: String?
    let enhancedPrompt: String?
}

struct SessionMetaPayload: Codable {
    let id: UUID
    let name: String
    let folderID: UUID?
    let lorebookIDs: [UUID]
    let tagIDs: [UUID]?
    let worldbookContextIsolationEnabled: Bool?
    let conversationSummary: String?
    let conversationSummaryUpdatedAt: String?
}

struct SessionRecordSummaryPayload: Codable {
    let schemaVersion: Int
    let session: SessionMetaPayload
    let prompts: SessionPromptsPayload
}

struct SessionRecordFilePayload: Codable {
    let schemaVersion: Int
    let session: SessionMetaPayload
    let prompts: SessionPromptsPayload
    let messages: [ChatMessage]
}

struct LegacyMessagesReadResult {
    let messages: [ChatMessage]
    let didMigrateFileSchema: Bool
    let didMigratePlacement: Bool
}

struct ChatMessagesFileEnvelope: Codable {
    let schemaVersion: Int
    let messages: [ChatMessage]
}

struct SessionFoldersFileEnvelope: Codable {
    let schemaVersion: Int
    let updatedAt: String
    let folders: [SessionFolder]
}

struct SessionTagsFileEnvelope: Codable {
    let schemaVersion: Int
    let updatedAt: String
    let tags: [SessionTag]
}

struct RequestLogFileEnvelope: Codable {
    let schemaVersion: Int
    let updatedAt: String
    let logs: [RequestLogEntry]
}

struct LegacySessionIndexFile: Codable {
    struct Item: Codable {
        let id: UUID
        let name: String
        let updatedAt: String
    }

    let schemaVersion: Int
    let updatedAt: String
    let sessions: [Item]
}

struct LegacySessionPrompts: Codable {
    let topicPrompt: String?
    let enhancedPrompt: String?
}

struct LegacySessionMeta: Codable {
    let id: UUID
    let name: String
    let folderID: UUID?
    let lorebookIDs: [UUID]
    let worldbookContextIsolationEnabled: Bool?
    let conversationSummary: String?
    let conversationSummaryUpdatedAt: String?
}

struct LegacySessionRecordFile: Codable {
    let schemaVersion: Int
    let session: LegacySessionMeta
    let prompts: LegacySessionPrompts
    let messages: [ChatMessage]
}
