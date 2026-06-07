// ============================================================================
// OpenAITestSupport.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件负责 OpenAI 相关测试共用的轻量响应结构。
// ============================================================================

import Foundation
@testable import ETOSCore

struct OpenAIResponse: Codable {
    struct Choice: Codable {
        struct Message: Codable {
            let content: String?
        }

        let message: Message
    }

    let choices: [Choice]
}

func saveMemoryToolDefinition() -> InternalToolDefinition {
    let parameters = JSONValue.dictionary([
        "type": .string("object"),
        "properties": .dictionary([
            "content": .dictionary([
                "type": .string("string"),
                "description": .string("The specific information to remember long-term.")
            ])
        ]),
        "required": .array([.string("content")])
    ])
    return InternalToolDefinition(
        name: "save_memory",
        description: "Save a piece of important information to long-term memory.",
        parameters: parameters,
        isBlocking: false
    )
}
