// ============================================================================
// ConversationToolDefinitions.swift
// ============================================================================
// ETOS LLM Studio
//
// 定义模型可调用的长期会话工具及其参数协议。
// ============================================================================

import Foundation

enum ConversationToolName: String, CaseIterable {
    case createConversation = "create_conversation"
    case sendMessage = "send_message_to_conversation"
    case listConversations = "list_conversations"
    case listAvailableModels = "list_available_conversation_models"
    case readConversation = "read_conversation"
    case waitForConversations = "wait_for_conversations"
    case interruptConversation = "interrupt_conversation"
}

enum ConversationToolDefinitions {
    static var all: [InternalToolDefinition] {
        [
            createConversation,
            sendMessage,
            listConversations,
            listAvailableModels,
            readConversation,
            waitForConversations,
            interruptConversation
        ]
    }

    static func contains(_ toolName: String) -> Bool {
        ConversationToolName(rawValue: toolName) != nil
    }

    /// MCP 会把工具名包装为可读别名；历史工具卡和提示协议仍需识别其原始工具身份。
    static func containsExposedName(_ toolName: String) -> Bool {
        if contains(toolName) { return true }
        return ConversationToolName.allCases.contains { candidate in
            let rawName = candidate.rawValue
            return toolName == "mcp_\(rawName)"
                || (toolName.hasPrefix(MCPManager.toolNamePrefix) && toolName.hasSuffix("/\(rawName)"))
                || (toolName.hasPrefix(MCPManager.toolAliasPrefix) && toolName.hasSuffix("_\(rawName)"))
        }
    }

    private static var createConversation: InternalToolDefinition {
        InternalToolDefinition(
            name: ConversationToolName.createConversation.rawValue,
            description: NSLocalizedString(
                "创建一个用户可见、长期存在的新会话，并可选择立即让它回复。创建后可以在未来继续联系该会话。",
                comment: "Create conversation tool description"
            ),
            parameters: .dictionary([
                "type": .string("object"),
                "properties": .dictionary([
                    "initial_message": stringProperty(NSLocalizedString("发送给新会话的第一条消息。", comment: "Create conversation initial message")),
                    "title": stringProperty(NSLocalizedString("新会话名称；省略时从第一条消息生成简短名称。", comment: "Create conversation title")),
                    "context_mode": enumProperty(
                        values: ["new", "fork_all", "fork_recent"],
                        description: NSLocalizedString("新建空白上下文、完整分叉或最近若干轮分叉。", comment: "Create conversation context mode")
                    ),
                    "recent_rounds": .dictionary([
                        "type": .string("integer"),
                        "minimum": .int(1),
                        "description": .string(NSLocalizedString("fork_recent 使用的完整轮次数。", comment: "Create conversation recent rounds"))
                    ]),
                    "execution_mode": enumProperty(
                        values: ["create_only", "await_reply", "background", "background_continue"],
                        description: NSLocalizedString("只创建、等待回复、后台执行或完成后继续当前会话。", comment: "Create conversation execution mode")
                    ),
                    "model_identifier": stringProperty(NSLocalizedString("可选的已激活聊天模型标识；省略、留空或填写 self 时使用当前模型。", comment: "Create conversation model identifier")),
                    "system_prompt": stringProperty(NSLocalizedString("新会话的系统提示词内容。", comment: "Create conversation system prompt")),
                    "system_prompt_mode": promptModeProperty(),
                    "topic_prompt": stringProperty(NSLocalizedString("新会话的话题提示词内容。", comment: "Create conversation topic prompt")),
                    "topic_prompt_mode": promptModeProperty(),
                    "enhanced_prompt": stringProperty(NSLocalizedString("新会话的增强提示词内容。", comment: "Create conversation enhanced prompt")),
                    "enhanced_prompt_mode": promptModeProperty()
                ]),
                "required": .array([
                    .string("initial_message"),
                    .string("context_mode"),
                    .string("execution_mode")
                ])
            ])
        )
    }

    private static var sendMessage: InternalToolDefinition {
        InternalToolDefinition(
            name: ConversationToolName.sendMessage.rawValue,
            description: NSLocalizedString(
                "向已有授权会话发送消息，可以只投递，也可以要求目标回复。",
                comment: "Send conversation message tool description"
            ),
            parameters: .dictionary([
                "type": .string("object"),
                "properties": .dictionary([
                    "conversation_id": stringProperty(NSLocalizedString("目标会话 UUID。", comment: "Conversation target ID")),
                    "message": stringProperty(NSLocalizedString("要发送的消息。", comment: "Conversation outgoing message")),
                    "delivery": enumProperty(
                        values: ["deliver_only", "request_reply"],
                        description: NSLocalizedString("只投递或要求目标回复。", comment: "Conversation message delivery")
                    ),
                    "completion": enumProperty(
                        values: ["await_reply", "background", "background_continue"],
                        description: NSLocalizedString("等待回复、后台执行或完成后继续当前会话。", comment: "Conversation message completion")
                    )
                ]),
                "required": .array([
                    .string("conversation_id"),
                    .string("message"),
                    .string("delivery"),
                    .string("completion")
                ])
            ])
        )
    }

    private static var listConversations: InternalToolDefinition {
        InternalToolDefinition(
            name: ConversationToolName.listConversations.rawValue,
            description: NSLocalizedString("列出当前会话有权联系的长期会话及其状态。", comment: "List conversations tool description"),
            parameters: .dictionary([
                "type": .string("object"),
                "properties": .dictionary([
                    "max": listMaximumProperty()
                ])
            ])
        )
    }

    private static var listAvailableModels: InternalToolDefinition {
        InternalToolDefinition(
            name: ConversationToolName.listAvailableModels.rawValue,
            description: NSLocalizedString("列出创建协作会话时可以显式选择的已激活聊天模型。", comment: "List available conversation models tool description"),
            parameters: .dictionary([
                "type": .string("object"),
                "properties": .dictionary([
                    "max": listMaximumProperty()
                ])
            ])
        )
    }

    private static var readConversation: InternalToolDefinition {
        InternalToolDefinition(
            name: ConversationToolName.readConversation.rawValue,
            description: NSLocalizedString("读取一个有权限会话最近的若干完整轮次。", comment: "Read conversation tool description"),
            parameters: .dictionary([
                "type": .string("object"),
                "properties": .dictionary([
                    "conversation_id": stringProperty(NSLocalizedString("目标会话 UUID。", comment: "Read conversation ID")),
                    "rounds": .dictionary([
                        "type": .string("integer"),
                        "minimum": .int(1),
                        "description": .string(NSLocalizedString("读取的最近完整轮次数。", comment: "Read conversation rounds"))
                    ])
                ]),
                "required": .array([.string("conversation_id")])
            ])
        )
    }

    private static var waitForConversations: InternalToolDefinition {
        InternalToolDefinition(
            name: ConversationToolName.waitForConversations.rawValue,
            description: NSLocalizedString("持久等待一个或多个会话完成当前回复，不进行轮询。", comment: "Wait conversations tool description"),
            parameters: .dictionary([
                "type": .string("object"),
                "properties": .dictionary([
                    "conversation_ids": .dictionary([
                        "type": .string("array"),
                        "items": .dictionary(["type": .string("string")]),
                        "minItems": .int(1),
                        "description": .string(NSLocalizedString("要等待的会话 UUID 列表。", comment: "Wait conversation IDs"))
                    ]),
                    "mode": enumProperty(
                        values: ["all", "any"],
                        description: NSLocalizedString("等待全部目标或任意一个目标。", comment: "Wait conversation mode")
                    )
                ]),
                "required": .array([.string("conversation_ids"), .string("mode")])
            ])
        )
    }

    private static var interruptConversation: InternalToolDefinition {
        InternalToolDefinition(
            name: ConversationToolName.interruptConversation.rawValue,
            description: NSLocalizedString("停止一个有权限会话当前正在执行的回复，但保留会话和消息。", comment: "Interrupt conversation tool description"),
            parameters: .dictionary([
                "type": .string("object"),
                "properties": .dictionary([
                    "conversation_id": stringProperty(NSLocalizedString("目标会话 UUID。", comment: "Interrupt conversation ID"))
                ]),
                "required": .array([.string("conversation_id")])
            ])
        )
    }

    private static func promptModeProperty() -> JSONValue {
        enumProperty(
            values: ["inherit", "append", "replace"],
            description: NSLocalizedString("继承、追加或替换被继承的会话提示词。", comment: "Conversation prompt inheritance mode")
        )
    }

    private static func listMaximumProperty() -> JSONValue {
        .dictionary([
            "type": .string("integer"),
            "minimum": .int(ConversationToolListLimit.minimum),
            "maximum": .int(ConversationToolListLimit.maximum),
            "description": .string(NSLocalizedString("最多返回的条目数；省略时返回 20 项。", comment: "Conversation list maximum result count"))
        ])
    }

    private static func stringProperty(_ description: String) -> JSONValue {
        .dictionary([
            "type": .string("string"),
            "description": .string(description)
        ])
    }

    private static func enumProperty(values: [String], description: String) -> JSONValue {
        .dictionary([
            "type": .string("string"),
            "enum": .array(values.map { .string($0) }),
            "description": .string(description)
        ])
    }
}

enum ConversationToolListLimit {
    static let minimum = 1
    static let defaultValue = 20
    static let maximum = 200

    static func resolve(_ requested: Int?) throws -> Int {
        let value = requested ?? defaultValue
        guard (minimum...maximum).contains(value) else {
            throw ConversationRuntimeError.malformedArguments
        }
        return value
    }
}

enum ConversationToolModelSelection {
    /// `nil` 表示复用来源 Run 的模型；只有其他非空值才是显式跨模型选择。
    static func explicitIdentifier(from rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.caseInsensitiveCompare("self") != .orderedSame else {
            return nil
        }
        return trimmed
    }
}

struct CreateConversationToolArguments: Decodable {
    let initialMessage: String
    let title: String?
    let contextMode: String
    let recentRounds: Int?
    let executionMode: String
    let modelIdentifier: String?
    let systemPrompt: String?
    let systemPromptMode: String?
    let topicPrompt: String?
    let topicPromptMode: String?
    let enhancedPrompt: String?
    let enhancedPromptMode: String?

    enum CodingKeys: String, CodingKey {
        case initialMessage = "initial_message"
        case title
        case contextMode = "context_mode"
        case recentRounds = "recent_rounds"
        case executionMode = "execution_mode"
        case modelIdentifier = "model_identifier"
        case systemPrompt = "system_prompt"
        case systemPromptMode = "system_prompt_mode"
        case topicPrompt = "topic_prompt"
        case topicPromptMode = "topic_prompt_mode"
        case enhancedPrompt = "enhanced_prompt"
        case enhancedPromptMode = "enhanced_prompt_mode"
    }
}

struct SendConversationMessageToolArguments: Decodable {
    let conversationID: String
    let message: String
    let delivery: String
    let completion: String

    enum CodingKeys: String, CodingKey {
        case conversationID = "conversation_id"
        case message
        case delivery
        case completion
    }
}

struct ListConversationToolArguments: Decodable {
    let max: Int?
}

struct ReadConversationToolArguments: Decodable {
    let conversationID: String
    let rounds: Int?

    enum CodingKeys: String, CodingKey {
        case conversationID = "conversation_id"
        case rounds
    }
}

struct WaitForConversationsToolArguments: Decodable {
    let conversationIDs: [String]
    let mode: String

    enum CodingKeys: String, CodingKey {
        case conversationIDs = "conversation_ids"
        case mode
    }
}

struct InterruptConversationToolArguments: Decodable {
    let conversationID: String

    enum CodingKeys: String, CodingKey {
        case conversationID = "conversation_id"
    }
}

struct ConversationToolExecutionResult: Sendable {
    let content: String
    let shouldPauseCurrentRun: Bool
}
