// ============================================================================
// ThirdPartyImportKelivoTests.swift
// ============================================================================
// ThirdPartyImportService Kelivo 导入测试
// - 覆盖 settings.json provider_configs 解析
// - 覆盖 chats.json conversations/messages 解析
// ============================================================================

import Foundation
import Testing
@testable import ETOSCore

@Suite("第三方导入 Kelivo 兼容测试")
struct ThirdPartyImportKelivoTests {

    @Test("Kelivo 目录备份可解析 provider 与会话")
    func testPrepareKelivoImportFromDirectory() throws {
        let sandbox = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let settings: [String: Any] = [
            "provider_configs": [
                "kelivo-provider-1": [
                    "name": "Kelivo Gemini",
                    "providerType": "gemini",
                    "baseUrl": "https://generativelanguage.googleapis.com",
                    "apiKey": "kelivo-key",
                    "enabled": true,
                    "models": ["gemini-2.5-pro"]
                ]
            ]
        ]

        let chats: [String: Any] = [
            "conversations": [
                ["id": "conv-1", "title": "Kelivo 测试会话"]
            ],
            "messages": [
                [
                    "id": "kmsg-2",
                    "conversationId": "conv-1",
                    "role": "assistant",
                    "content": "",
                    "reasoningText": "推理内容",
                    "timestamp": 2,
                    "totalTokens": 42
                ],
                [
                    "id": "kmsg-1",
                    "conversationId": "conv-1",
                    "role": "user",
                    "content": "你好",
                    "timestamp": 1
                ]
            ]
        ]

        try JSONSerialization.data(withJSONObject: settings)
            .write(to: sandbox.appendingPathComponent("settings.json"))
        try JSONSerialization.data(withJSONObject: chats)
            .write(to: sandbox.appendingPathComponent("chats.json"))

        let prepared = try ThirdPartyImportService.prepareImport(
            source: .kelivo,
            fileURL: sandbox
        )

        #expect(prepared.package.options.contains(.providers))
        #expect(prepared.package.options.contains(.sessions))
        #expect(prepared.package.providers.count == 1)
        #expect(prepared.package.sessions.count == 1)
        #expect(prepared.warnings.isEmpty)

        let provider = prepared.package.providers[0]
        #expect(provider.apiFormat == "gemini")
        #expect(provider.baseURL == "https://generativelanguage.googleapis.com/v1beta")
        #expect(provider.models.map(\.modelName) == ["gemini-2.5-pro"])

        let session = prepared.package.sessions[0]
        #expect(session.session.name == "Kelivo 测试会话")
        #expect(session.messages.count == 2)
        #expect(session.messages[0].role == .user)
        #expect(session.messages[1].role == .assistant)
        #expect(session.messages[1].content == "推理内容")
        #expect(session.messages[1].tokenUsage?.totalTokens == 42)
    }

    @Test("Kelivo 的显式 providerType 优先于模型名推断")
    func testPrepareKelivoImportRespectsExplicitProviderType() throws {
        let sandbox = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let settings: [String: Any] = [
            "provider_configs": [
                "kelivo-provider-2": [
                    "name": "OpenAI 兼容提供商",
                    "providerType": "openai",
                    "baseUrl": "https://example.com/v1",
                    "apiKey": "kelivo-key",
                    "enabled": true,
                    "models": ["claude-3-5-sonnet"]
                ]
            ]
        ]

        try JSONSerialization.data(withJSONObject: settings)
            .write(to: sandbox.appendingPathComponent("settings.json"))

        let prepared = try ThirdPartyImportService.prepareImport(
            source: .kelivo,
            fileURL: sandbox
        )

        #expect(prepared.package.providers.count == 1)
        let provider = prepared.package.providers[0]
        #expect(provider.apiFormat == "openai-compatible")
        #expect(provider.baseURL == "https://example.com/v1")
        #expect(provider.models.map(\.modelName) == ["claude-3-5-sonnet"])
    }

    @Test("Kelivo 导入会保留 Responses、多 Key、代理与模型覆盖")
    func testPrepareKelivoImportPreservesResponsesKeysProxyAndModelOverrides() throws {
        let sandbox = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let settings: [String: Any] = [
            "provider_configs": [
                "kelivo-provider-3": [
                    "name": "Kelivo OpenAI",
                    "providerType": "openai",
                    "baseUrl": "https://example.com/v1",
                    "apiKey": "primary-key",
                    "enabled": true,
                    "useResponseApi": true,
                    "proxyEnabled": true,
                    "proxyType": "socks5",
                    "proxyHost": "127.0.0.1",
                    "proxyPort": "7890",
                    "apiKeys": [
                        ["key": "secondary-key", "isEnabled": true, "status": "active"],
                        ["key": "disabled-key", "isEnabled": false, "status": "disabled"]
                    ],
                    "models": ["logical-vision", "extra-embedding"],
                    "modelOverrides": [
                        "logical-vision": [
                            "apiModelId": "gpt-4o",
                            "name": "GPT 4o Vision",
                            "type": "chat",
                            "input": ["text", "image"],
                            "output": ["text"],
                            "abilities": ["tool", "reasoning"],
                            "body": [
                                ["key": "temperature", "value": "0.4"],
                                ["key": "metadata", "value": "{\"source\":\"kelivo\"}"]
                            ]
                        ],
                        "extra-embedding": [
                            "apiModelId": "text-embedding-3-small",
                            "name": "Embedding",
                            "type": "embedding",
                            "input": ["text"]
                        ]
                    ]
                ]
            ]
        ]

        try JSONSerialization.data(withJSONObject: settings)
            .write(to: sandbox.appendingPathComponent("settings.json"))

        let prepared = try ThirdPartyImportService.prepareImport(
            source: .kelivo,
            fileURL: sandbox
        )

        let provider = try #require(prepared.package.providers.first)
        #expect(provider.apiKeys == ["primary-key", "secondary-key"])
        #expect(provider.proxyConfiguration?.type == .socks5)
        #expect(provider.proxyConfiguration?.host == "127.0.0.1")
        #expect(provider.proxyConfiguration?.port == 7890)

        let visionModel = try #require(provider.models.first { $0.modelName == "gpt-4o" })
        #expect(visionModel.displayName == "GPT 4o Vision")
        #expect(visionModel.inputModalities == [.text, .image])
        #expect(visionModel.capabilities == [.toolCalling, .reasoning])
        #expect(visionModel.overrideParameters["use_responses_api"] == .bool(true))
        #expect(visionModel.overrideParameters["temperature"] == .double(0.4))
        #expect(visionModel.overrideParameters["metadata"] == .dictionary(["source": .string("kelivo")]))

        let embeddingModel = try #require(provider.models.first { $0.modelName == "text-embedding-3-small" })
        #expect(embeddingModel.kind == .embedding)
        #expect(embeddingModel.capabilities == [])
    }

    @Test("Kelivo 导入会忽略已从 models 移除的覆盖项")
    func testPrepareKelivoImportIgnoresStaleOverrideOnlyModels() throws {
        let sandbox = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let settings: [String: Any] = [
            "provider_configs": [
                "kelivo-provider-stale": [
                    "name": "Kelivo OpenAI",
                    "providerType": "openai",
                    "baseUrl": "https://example.com/v1",
                    "apiKey": "kelivo-key",
                    "enabled": true,
                    "models": ["active-model"],
                    "modelOverrides": [
                        "active-model": [
                            "apiModelId": "gpt-4o"
                        ],
                        "removed-model": [
                            "apiModelId": "gpt-4.1"
                        ]
                    ]
                ]
            ]
        ]

        try JSONSerialization.data(withJSONObject: settings)
            .write(to: sandbox.appendingPathComponent("settings.json"))

        let prepared = try ThirdPartyImportService.prepareImport(
            source: .kelivo,
            fileURL: sandbox
        )

        let provider = try #require(prepared.package.providers.first)
        #expect(provider.models.map(\.modelName) == ["gpt-4o"])
    }

    @Test("Kelivo 导入在 apiModelId 重复时保留逻辑模型 ID")
    func testPrepareKelivoImportPreservesLogicalModelIDsWhenAPIModelIDRepeats() throws {
        let sandbox = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let settings: [String: Any] = [
            "provider_configs": [
                "kelivo-provider-duplicates": [
                    "name": "Kelivo OpenAI",
                    "providerType": "openai",
                    "baseUrl": "https://example.com/v1",
                    "apiKey": "kelivo-key",
                    "enabled": true,
                    "models": ["gpt-4o", "gpt-4o#1"],
                    "modelOverrides": [
                        "gpt-4o": [
                            "apiModelId": "gpt-4o",
                            "name": "默认 4o",
                            "body": [["key": "temperature", "value": "0.2"]]
                        ],
                        "gpt-4o#1": [
                            "apiModelId": "gpt-4o",
                            "name": "低温 4o",
                            "body": [["key": "temperature", "value": "0.8"]]
                        ]
                    ]
                ]
            ]
        ]

        try JSONSerialization.data(withJSONObject: settings)
            .write(to: sandbox.appendingPathComponent("settings.json"))

        let prepared = try ThirdPartyImportService.prepareImport(
            source: .kelivo,
            fileURL: sandbox
        )

        let provider = try #require(prepared.package.providers.first)
        #expect(provider.models.map(\.modelName).sorted() == ["gpt-4o", "gpt-4o#1"])

        let baseModel = try #require(provider.models.first { $0.modelName == "gpt-4o" })
        let duplicateModel = try #require(provider.models.first { $0.modelName == "gpt-4o#1" })
        #expect(baseModel.overrideParameters["model"] == .string("gpt-4o"))
        #expect(duplicateModel.overrideParameters["model"] == .string("gpt-4o"))
        #expect(baseModel.overrideParameters["temperature"] == .double(0.2))
        #expect(duplicateModel.overrideParameters["temperature"] == .double(0.8))
    }

    @Test("Kelivo 导入不会合并带有不同模型覆盖的同名 provider")
    func testPrepareKelivoImportKeepsProvidersWithDifferentOverridesSeparate() throws {
        let sandbox = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let commonProvider: [String: Any] = [
            "name": "同名 OpenAI",
            "providerType": "openai",
            "baseUrl": "https://example.com/v1",
            "apiKey": "same-key",
            "enabled": true
        ]

        let settings: [String: Any] = [
            "provider_configs": [
                "kelivo-provider-a": commonProvider.merging([
                    "models": ["model-a"],
                    "modelOverrides": [
                        "model-a": [
                            "body": [["key": "temperature", "value": "0.1"]]
                        ]
                    ]
                ]) { _, new in new },
                "kelivo-provider-b": commonProvider.merging([
                    "models": ["model-a"],
                    "modelOverrides": [
                        "model-a": [
                            "body": [["key": "temperature", "value": "0.9"]]
                        ]
                    ]
                ]) { _, new in new }
            ]
        ]

        try JSONSerialization.data(withJSONObject: settings)
            .write(to: sandbox.appendingPathComponent("settings.json"))

        let prepared = try ThirdPartyImportService.prepareImport(
            source: .kelivo,
            fileURL: sandbox
        )

        #expect(prepared.package.providers.count == 2)
        let temperatures = prepared.package.providers.compactMap {
            $0.models.first?.overrideParameters["temperature"]
        }
        #expect(temperatures.contains(.double(0.1)))
        #expect(temperatures.contains(.double(0.9)))
    }

    private func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
