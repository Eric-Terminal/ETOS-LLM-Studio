// ============================================================================
// ThirdPartyImportRikkaHubTests.swift
// ============================================================================
// ThirdPartyImportService RikkaHub 导入测试
// - 覆盖 settings.json provider 解析
// - 覆盖会话暂不支持时的提示信息
// ============================================================================

import Foundation
import Testing
@testable import Shared

@Suite("第三方导入 RikkaHub 兼容测试")
struct ThirdPartyImportRikkaHubTests {

    @Test("RikkaHub settings.json 可解析 provider")
    func testPrepareRikkaImportFromSettingsJSON() throws {
        let sandbox = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let settings: [String: Any] = [
            "providers": [
                [
                    "id": "rikka-provider-1",
                    "name": "Gemini 官方",
                    "type": "gemini",
                    "baseUrl": "https://generativelanguage.googleapis.com",
                    "apiKey": "rk-test-key",
                    "enabled": true,
                    "models": [
                        ["modelId": "gemini-2.5-pro", "displayName": "Gemini 2.5 Pro"]
                    ]
                ]
            ]
        ]

        let fileURL = sandbox.appendingPathComponent("settings.json")
        try JSONSerialization.data(withJSONObject: settings).write(to: fileURL)

        let prepared = try ThirdPartyImportService.prepareImport(
            source: .rikkahub,
            fileURL: fileURL
        )

        #expect(prepared.package.options.contains(.providers))
        #expect(!prepared.package.options.contains(.sessions))
        #expect(prepared.package.providers.count == 1)
        #expect(prepared.package.sessions.isEmpty)

        let provider = prepared.package.providers[0]
        #expect(provider.name == "Gemini 官方")
        #expect(provider.apiFormat == "gemini")
        #expect(provider.baseURL == "https://generativelanguage.googleapis.com/v1beta")
        #expect(provider.models.map(\.modelName) == ["gemini-2.5-pro"])
        #expect(prepared.warnings.contains(where: { $0.contains("会话内容暂未解析") }))
    }

    @Test("RikkaHub 的 useResponseApi 会保留为模型请求参数")
    func testPrepareRikkaImportPreservesResponsesAPIFlag() throws {
        let sandbox = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let settings: [String: Any] = [
            "providers": [
                [
                    "id": "rikka-responses-provider",
                    "name": "OpenAI Responses",
                    "type": "openai",
                    "baseUrl": "https://api.openai.com/v1",
                    "apiKey": "rk-test-key",
                    "enabled": true,
                    "useResponseApi": true,
                    "models": [
                        ["modelId": "gpt-5", "displayName": "GPT-5"]
                    ]
                ]
            ]
        ]

        let fileURL = sandbox.appendingPathComponent("settings.json")
        try JSONSerialization.data(withJSONObject: settings).write(to: fileURL)

        let prepared = try ThirdPartyImportService.prepareImport(
            source: .rikkahub,
            fileURL: fileURL
        )

        let provider = try #require(prepared.package.providers.first)
        #expect(provider.apiFormat == "openai-compatible")
        let model = try #require(provider.models.first)
        #expect(model.overrideParameters["use_responses_api"] == .bool(true))
    }

    @Test("RikkaHub 导入会保留模型类型、模态、能力与自定义请求体")
    func testPrepareRikkaImportPreservesModelShapeAndCustomBodies() throws {
        let sandbox = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let settings: [String: Any] = [
            "providers": [
                [
                    "id": "rikka-shape-provider",
                    "name": "Rikka OpenAI",
                    "type": "openai",
                    "baseUrl": "https://api.example.com/v1",
                    "apiKey": "rk-test-key",
                    "enabled": true,
                    "models": [
                        [
                            "modelId": "vision-model",
                            "displayName": "Vision Model",
                            "type": "CHAT",
                            "inputModalities": ["TEXT", "IMAGE"],
                            "outputModalities": ["TEXT"],
                            "abilities": ["TOOL", "REASONING"],
                            "customBodies": [
                                ["key": "temperature", "value": 0.2],
                                ["key": "metadata", "value": ["from": "rikka"]]
                            ]
                        ],
                        [
                            "modelId": "embed-model",
                            "displayName": "Embedding Model",
                            "type": "EMBEDDING",
                            "inputModalities": ["TEXT"],
                            "outputModalities": [],
                            "abilities": ["TOOL"]
                        ]
                    ]
                ]
            ]
        ]

        let fileURL = sandbox.appendingPathComponent("settings-shape.json")
        try JSONSerialization.data(withJSONObject: settings).write(to: fileURL)

        let prepared = try ThirdPartyImportService.prepareImport(
            source: .rikkahub,
            fileURL: fileURL
        )

        let provider = try #require(prepared.package.providers.first)
        let visionModel = try #require(provider.models.first { $0.modelName == "vision-model" })
        #expect(visionModel.kind == .chat)
        #expect(visionModel.inputModalities == [.text, .image])
        #expect(visionModel.outputModalities == [.text])
        #expect(visionModel.capabilities == [.toolCalling, .reasoning])
        #expect(visionModel.overrideParameters["temperature"] == .double(0.2))
        #expect(visionModel.overrideParameters["metadata"] == .dictionary(["from": .string("rikka")]))

        let embeddingModel = try #require(provider.models.first { $0.modelName == "embed-model" })
        #expect(embeddingModel.kind == .embedding)
        #expect(embeddingModel.outputModalities == [])
        #expect(embeddingModel.capabilities == [])
    }

    private func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
