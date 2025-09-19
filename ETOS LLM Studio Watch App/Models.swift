// ============================================================================
// Models.swift
// ============================================================================
// ETOS LLM Studio Watch App 数据模型文件
//
// 定义内容:
// - ChatMessage: 聊天消息结构
// - ChatSession: 聊天会话结构
// - AIModelConfig: AI模型配置结构
// - 其他与数据相关的枚举和结构体
// ============================================================================

import Foundation
import SwiftUI

// MARK: - 配置与数据模型

/// AI模型配置
struct AIModelConfig: Identifiable, Hashable {
    static func == (lhs: AIModelConfig, rhs: AIModelConfig) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    
    let id = UUID()
    let name: String
    let apiKeys: [String]
    let apiURL: String
    let basePayload: [String: Any]
}

// MARK: - 消息与会话模型

/// 聊天消息数据结构
struct ChatMessage: Identifiable, Codable, Equatable {
    var id: UUID
    var role: String // "user", "assistant", "system", "error"
    var content: String
    var reasoning: String? = nil
    var isLoading: Bool = false
    var isReasoningExpanded: Bool? = nil

    enum CodingKeys: String, CodingKey {
        case id, role, content, reasoning, isLoading, isReasoningExpanded
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        role = try container.decode(String.self, forKey: .role)
        content = try container.decode(String.self, forKey: .content)
        reasoning = try container.decodeIfPresent(String.self, forKey: .reasoning)
        isLoading = try container.decodeIfPresent(Bool.self, forKey: .isLoading) ?? false
        isReasoningExpanded = try container.decodeIfPresent(Bool.self, forKey: .isReasoningExpanded)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(role, forKey: .role)
        try container.encode(content, forKey: .content)
        try container.encodeIfPresent(reasoning, forKey: .reasoning)
        if isLoading {
            try container.encode(isLoading, forKey: .isLoading)
        }
        try container.encodeIfPresent(isReasoningExpanded, forKey: .isReasoningExpanded)
    }
    
    init(id: UUID, role: String, content: String, reasoning: String? = nil, isLoading: Bool = false, isReasoningExpanded: Bool? = nil) {
        self.id = id
        self.role = role
        self.content = content
        self.reasoning = reasoning
        self.isLoading = isLoading
        self.isReasoningExpanded = isReasoningExpanded
    }
}

/// 聊天会话数据结构
struct ChatSession: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var topicPrompt: String?
    var enhancedPrompt: String?
    var isTemporary: Bool = false

    init(id: UUID, name: String, topicPrompt: String? = nil, enhancedPrompt: String? = nil, isTemporary: Bool = false) {
        self.id = id
        self.name = name
        self.topicPrompt = topicPrompt
        self.enhancedPrompt = enhancedPrompt
        self.isTemporary = isTemporary
    }
    
    enum CodingKeys: String, CodingKey {
        case id, name, topicPrompt, enhancedPrompt
    }
}

// MARK: - 导出相关模型

/// 用于导出的聊天消息数据结构
struct ExportableChatMessage: Codable {
    var role: String
    var content: String
    var reasoning: String?
}

/// 用于导出提示词的结构
struct ExportPrompts: Codable {
    let globalSystemPrompt: String?
    let topicPrompt: String?
    let enhancedPrompt: String?
}

/// 完整的导出数据结构
struct FullExportData: Codable {
    let prompts: ExportPrompts
    let history: [ExportableChatMessage]
}

// MARK: - API与UI状态模型

/// 通用API响应数据结构
struct GenericAPIResponse: Codable {
    struct Choice: Codable {
        struct Message: Codable {
            let content: String?
            let reasoning_content: String?
        }
        struct Delta: Codable {
            let content: String?
            let reasoning_content: String?
        }
        let message: Message?
        let delta: Delta?
    }
    let choices: [Choice]
}

/// 用于管理所有可能弹出的 Sheet 视图的枚举
enum ActiveSheet: Identifiable, Equatable {
    case settings
    case editMessage
    case export(ChatSession)
    
    var id: Int {
        switch self {
        case .settings: return 1
        case .editMessage: return 2
        case .export: return 3
        }
    }
}

/// 导出状态枚举
enum ExportStatus {
    case idle
    case exporting
    case success
    case failed(String)
}
