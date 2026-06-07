// ============================================================================
// ThirdPartyImportChatBoxTests.swift
// ============================================================================
// ThirdPartyImportService ChatBox 导入测试
// - 覆盖 chatbox-exported-data JSON 的 provider 与会话解析
// - 覆盖主线程、历史线程、分支和字符串化存储值
// ============================================================================

import Foundation
import Testing
@testable import ETOSCore

@Suite("第三方导入 ChatBox 兼容测试")
struct ThirdPartyImportChatBoxTests {

    @Test("ChatBox 整包导出可解析提供商、主会话、线程与分支")
    func testPrepareChatBoxImportFromExportedDataJSON() throws {
        let sandbox = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let settings: [String: Any] = [
            "providers": [
                "openai": [
                    "apiHost": "https://api.openai.com",
                    "apiKey": "sk-chatbox",
                    "models": [
                        [
                            "modelId": "gpt-4o",
                            "nickname": "GPT-4o",
                            "type": "chat",
                            "capabilities": ["vision", "tool_use", "reasoning"],
                            "contextWindow": 128_000,
                            "maxOutput": 16_384
                        ]
                    ]
                ],
                "custom-claude": [
                    "apiHost": "https://claude.example.com",
                    "apiKey": "claude-key",
                    "models": [
                        [
                            "modelId": "claude-3-5-sonnet",
                            "nickname": "Claude Sonnet",
                            "capabilities": ["tool_use"]
                        ]
                    ]
                ],
                "chatbox-ai": [
                    "apiKey": "chatbox-ai-key"
                ]
            ],
            "customProviders": [
                [
                    "id": "custom-claude",
                    "name": "我的 Claude",
                    "type": "anthropic",
                    "isCustom": true
                ]
            ],
            "defaultChatModel": [
                "provider": "openai",
                "model": "gpt-4o"
            ]
        ]

        let session: [String: Any] = [
            "id": "session-1",
            "name": "ChatBox 测试会话",
            "settings": [
                "provider": "openai",
                "modelId": "gpt-4o"
            ],
            "messages": [
                [
                    "id": "sys-1",
                    "role": "system",
                    "timestamp": 1_700_000_000_000,
                    "contentParts": [
                        ["type": "text", "text": "系统提示"]
                    ]
                ],
                [
                    "id": "user-1",
                    "role": "user",
                    "timestamp": 1_700_000_001_000,
                    "contentParts": [
                        ["type": "text", "text": "你好"],
                        ["type": "image", "ocrResult": "图片里的文字"]
                    ],
                    "files": [
                        ["name": "notes.txt", "fileType": "text/plain"]
                    ],
                    "links": [
                        ["title": "示例", "url": "https://example.com"]
                    ]
                ],
                [
                    "id": "assistant-1",
                    "role": "assistant",
                    "aiProvider": "openai",
                    "model": "gpt-4o",
                    "timestamp": 1_700_000_002_000,
                    "updatedAt": 1_700_000_003_000,
                    "firstTokenLatency": 250,
                    "usage": [
                        "inputTokens": 12,
                        "outputTokens": 4,
                        "reasoningTokens": 3,
                        "cachedInputTokens": 2,
                        "totalTokens": 16
                    ],
                    "contentParts": [
                        ["type": "reasoning", "text": "推理片段"],
                        ["type": "text", "text": "回答正文"],
                        [
                            "type": "tool-call",
                            "state": "result",
                            "toolName": "search",
                            "result": ["ok": true]
                        ]
                    ]
                ]
            ],
            "threads": [
                [
                    "id": "thread-1",
                    "name": "历史线程",
                    "messages": [
                        [
                            "id": "thread-user-1",
                            "role": "user",
                            "contentParts": [
                                ["type": "text", "text": "线程问题"]
                            ]
                        ]
                    ]
                ]
            ],
            "messageForksHash": [
                "assistant-1": [
                    "lists": [
                        [
                            "id": "fork-1",
                            "messages": [
                                [
                                    "id": "fork-assistant-1",
                                    "role": "assistant",
                                    "contentParts": [
                                        ["type": "text", "text": "分支回答"]
                                    ]
                                ]
                            ]
                        ]
                    ]
                ]
            ]
        ]

        let root: [String: Any] = [
            "__exported_items": ["setting", "conversations", "key"],
            "settings": settings,
            "chat-sessions-list": [
                ["id": "session-1", "name": "ChatBox 测试会话"]
            ],
            "session:session-1": session
        ]

        let fileURL = sandbox.appendingPathComponent("chatbox-exported-data.json")
        try JSONSerialization.data(withJSONObject: root).write(to: fileURL)

        let prepared = try ThirdPartyImportService.prepareImport(
            source: .chatbox,
            fileURL: fileURL
        )

        #expect(prepared.package.options.contains(.providers))
        #expect(prepared.package.options.contains(.sessions))
        #expect(prepared.package.providers.count == 2)
        #expect(prepared.package.sessions.count == 3)
        #expect(prepared.warnings.contains(where: { $0.contains("Chatbox AI") }))

        let openAI = try #require(prepared.package.providers.first { $0.name == "OpenAI" })
        #expect(openAI.apiFormat == "openai-compatible")
        #expect(openAI.baseURL == "https://api.openai.com/v1")
        #expect(openAI.apiKeys == ["sk-chatbox"])
        let gpt4o = try #require(openAI.models.first { $0.modelName == "gpt-4o" })
        #expect(gpt4o.displayName == "GPT-4o")
        #expect(gpt4o.inputModalities == [.text, .image])
        #expect(gpt4o.capabilities == [.toolCalling, .reasoning])

        let claude = try #require(prepared.package.providers.first { $0.name == "我的 Claude" })
        #expect(claude.apiFormat == "anthropic")
        #expect(claude.baseURL == "https://claude.example.com/v1")

        let mainSession = try #require(prepared.package.sessions.first { $0.session.name == "ChatBox 测试会话" })
        #expect(mainSession.messages.count == 3)
        #expect(mainSession.messages[0].role == .system)
        #expect(mainSession.messages[1].content.contains("图片里的文字"))
        #expect(mainSession.messages[1].content.contains("notes.txt"))
        #expect(mainSession.messages[1].content.contains("https://example.com"))

        let assistant = mainSession.messages[2]
        #expect(assistant.content.contains("回答正文"))
        #expect(assistant.content.contains("search"))
        #expect(assistant.reasoningContent == "推理片段")
        #expect(assistant.tokenUsage?.promptTokens == 12)
        #expect(assistant.tokenUsage?.completionTokens == 4)
        #expect(assistant.tokenUsage?.thinkingTokens == 3)
        #expect(assistant.tokenUsage?.cacheReadTokens == 2)
        #expect(assistant.tokenUsage?.totalTokens == 16)
        #expect(assistant.responseMetrics?.timeToFirstToken == 0.25)
        #expect(assistant.modelReference?.providerName == "OpenAI")
        #expect(assistant.modelReference?.modelDisplayName == "GPT-4o")

        #expect(prepared.package.sessions.contains { $0.session.name == "ChatBox 测试会话 - 历史线程" })
        #expect(prepared.package.sessions.contains { $0.session.name == "ChatBox 测试会话 - ChatBox 分支 1" })
    }

    @Test("ChatBox 字符串化 settings 和 session 值也能解析")
    func testPrepareChatBoxImportFromStringifiedValues() throws {
        let sandbox = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let settings: [String: Any] = [
            "providers": [
                "openai": [
                    "apiKey": "sk-stringified"
                ]
            ]
        ]
        let session: [String: Any] = [
            "id": "stringified-session",
            "name": "字符串化会话",
            "messages": [
                [
                    "id": "msg-1",
                    "role": "user",
                    "contentParts": [
                        ["type": "text", "text": "从字符串恢复"]
                    ]
                ]
            ]
        ]
        let root: [String: Any] = [
            "settings": try encodeJSONString(settings),
            "session:stringified-session": try encodeJSONString(session)
        ]

        let fileURL = sandbox.appendingPathComponent("chatbox-stringified.json")
        try JSONSerialization.data(withJSONObject: root).write(to: fileURL)

        let prepared = try ThirdPartyImportService.prepareImport(
            source: .chatbox,
            fileURL: fileURL
        )

        #expect(prepared.package.providers.count == 1)
        #expect(prepared.package.providers[0].apiKeys == ["sk-stringified"])
        #expect(prepared.package.sessions.count == 1)
        #expect(prepared.package.sessions[0].session.name == "字符串化会话")
        #expect(prepared.package.sessions[0].messages[0].content == "从字符串恢复")
    }

    private func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func encodeJSONString(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let string = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "ThirdPartyImportChatBoxTests", code: 1)
        }
        return string
    }
}
