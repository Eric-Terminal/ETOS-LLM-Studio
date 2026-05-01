// ============================================================================
// ThirdPartyImportCherryTests.swift
// ============================================================================
// ThirdPartyImportService Cherry Studio 导入测试
// - 覆盖 provider 与会话解析
// - 覆盖压缩包输入时的错误提示
// ============================================================================

import Foundation
import Testing
@testable import Shared

@Suite("第三方导入 Cherry 兼容测试")
struct ThirdPartyImportCherryTests {

    @Test("Cherry JSON 备份可解析提供商与会话")
    func testPrepareCherryImportFromJSON() throws {
        let sandbox = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let llm: [String: Any] = [
            "providers": [
                [
                    "id": "provider-1",
                    "name": "Claude Provider",
                    "type": "anthropic",
                    "apiHost": "https://api.anthropic.com",
                    "apiKey": "test-key-1",
                    "models": [
                        ["id": "claude-3-5-sonnet", "name": "Claude 3.5 Sonnet"]
                    ]
                ]
            ]
        ]

        let assistants: [String: Any] = [
            "assistants": [
                [
                    "topics": [
                        ["id": "topic-1", "name": "测试会话"]
                    ]
                ]
            ]
        ]

        let persist: [String: Any] = [
            "llm": try encodeJSONString(llm),
            "assistants": try encodeJSONString(assistants)
        ]

        let root: [String: Any] = [
            "localStorage": [
                "persist:cherry-studio": try encodeJSONString(persist)
            ],
            "indexedDB": [
                "topics": [
                    [
                        "id": "topic-1",
                        "messages": [
                            ["id": "m-1", "role": "user", "content": "你好"],
                            ["id": "m-2", "role": "assistant", "content": "", "blocks": ["b-1"]]
                        ]
                    ]
                ],
                "message_blocks": [
                    ["id": "b-1", "messageId": "m-2", "type": "main_text", "content": "你好，这里是 Cherry"]
                ]
            ]
        ]

        let fileURL = sandbox.appendingPathComponent("cherry.json")
        try JSONSerialization.data(withJSONObject: root).write(to: fileURL)

        let prepared = try ThirdPartyImportService.prepareImport(
            source: .cherryStudio,
            fileURL: fileURL
        )

        #expect(prepared.package.options.contains(.providers))
        #expect(prepared.package.options.contains(.sessions))
        #expect(prepared.package.providers.count == 1)
        #expect(prepared.package.sessions.count == 1)

        let provider = prepared.package.providers[0]
        #expect(provider.apiFormat == "anthropic")
        #expect(provider.baseURL == "https://api.anthropic.com/v1")
        #expect(provider.models.count == 1)

        let session = prepared.package.sessions[0]
        #expect(session.session.name == "测试会话")
        #expect(session.messages.count == 2)
        #expect(session.messages[1].content == "你好，这里是 Cherry")
    }

    @Test("Cherry 的 openai-response 模式会保留为模型请求参数")
    func testPrepareCherryImportPreservesOpenAIResponsesMode() throws {
        let sandbox = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let llm: [String: Any] = [
            "providers": [
                [
                    "id": "provider-responses",
                    "name": "Responses Provider",
                    "type": "openai",
                    "apiHost": "https://api.openai.com",
                    "apiKey": "test-key",
                    "models": [
                        ["id": "gpt-5", "name": "GPT-5", "endpoint_type": "openai-response"],
                        ["id": "gpt-4.1", "name": "GPT-4.1", "endpoint_type": "openai"]
                    ]
                ]
            ]
        ]

        let persist: [String: Any] = [
            "llm": try encodeJSONString(llm)
        ]
        let root: [String: Any] = [
            "localStorage": [
                "persist:cherry-studio": try encodeJSONString(persist)
            ],
            "indexedDB": [:]
        ]

        let fileURL = sandbox.appendingPathComponent("cherry-responses.json")
        try JSONSerialization.data(withJSONObject: root).write(to: fileURL)

        let prepared = try ThirdPartyImportService.prepareImport(
            source: .cherryStudio,
            fileURL: fileURL
        )

        let provider = try #require(prepared.package.providers.first)
        #expect(provider.apiFormat == "openai-compatible")

        let responsesModel = try #require(provider.models.first { $0.modelName == "gpt-5" })
        #expect(responsesModel.overrideParameters["use_responses_api"] == .bool(true))

        let chatModel = try #require(provider.models.first { $0.modelName == "gpt-4.1" })
        #expect(chatModel.overrideParameters["use_responses_api"] == nil)
    }

    @Test("Cherry 导入会保留 provider 状态、请求头与模型能力")
    func testPrepareCherryImportPreservesProviderStateHeadersAndModelShape() throws {
        let sandbox = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let llm: [String: Any] = [
            "providers": [
                [
                    "id": "provider-shape",
                    "name": "Cherry 自定义",
                    "type": "openai",
                    "apiHost": "https://api.example.com/v1",
                    "apiKey": "test-key",
                    "enabled": false,
                    "extra_headers": [
                        "X-App": "Cherry"
                    ],
                    "models": [
                        [
                            "id": "vision-chat",
                            "name": "Vision Chat",
                            "capabilities": [
                                ["type": "vision", "isUserSelected": true],
                                ["type": "function_calling", "isUserSelected": "false"],
                                ["type": "reasoning", "isUserSelected": true]
                            ]
                        ],
                        [
                            "id": "legacy-vision",
                            "name": "Legacy Vision",
                            "type": ["vision"]
                        ],
                        [
                            "id": "capability-vision",
                            "name": "Capability Vision",
                            "capabilities": [
                                ["type": "vision", "isUserSelected": true]
                            ]
                        ],
                        [
                            "id": "gpt-image-1",
                            "name": "Image",
                            "endpoint_type": "image-generation"
                        ]
                    ]
                ]
            ]
        ]

        let persist: [String: Any] = [
            "llm": try encodeJSONString(llm)
        ]
        let root: [String: Any] = [
            "localStorage": [
                "persist:cherry-studio": try encodeJSONString(persist)
            ],
            "indexedDB": [:]
        ]

        let fileURL = sandbox.appendingPathComponent("cherry-shape.json")
        try JSONSerialization.data(withJSONObject: root).write(to: fileURL)

        let prepared = try ThirdPartyImportService.prepareImport(
            source: .cherryStudio,
            fileURL: fileURL
        )

        let provider = try #require(prepared.package.providers.first)
        #expect(provider.headerOverrides["X-App"] == "Cherry")

        let visionModel = try #require(provider.models.first { $0.modelName == "vision-chat" })
        #expect(visionModel.isActivated == false)
        #expect(visionModel.kind == .chat)
        #expect(visionModel.inputModalities == [.text, .image])
        #expect(visionModel.capabilities == [.reasoning])

        let legacyVisionModel = try #require(provider.models.first { $0.modelName == "legacy-vision" })
        #expect(legacyVisionModel.inputModalities == [.text, .image])
        #expect(legacyVisionModel.capabilities == [.toolCalling])

        let capabilityVisionModel = try #require(provider.models.first { $0.modelName == "capability-vision" })
        #expect(capabilityVisionModel.inputModalities == [.text, .image])
        #expect(capabilityVisionModel.capabilities == [.toolCalling])

        let imageModel = try #require(provider.models.first { $0.modelName == "gpt-image-1" })
        #expect(imageModel.kind == .image)
        #expect(imageModel.outputModalities == [.image])
    }

    @Test("Cherry 压缩包会提示先解压")
    func testPrepareCherryImportWithCompressedFileShowsHint() throws {
        let sandbox = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let fileURL = sandbox.appendingPathComponent("cherry.zip")
        try Data("not-a-real-zip".utf8).write(to: fileURL)

        do {
            _ = try ThirdPartyImportService.prepareImport(source: .cherryStudio, fileURL: fileURL)
            Issue.record("预期应抛出 unsupportedBackupFormat 错误。")
        } catch let error as ThirdPartyImportError {
            switch error {
            case .unsupportedBackupFormat(let reason):
                #expect(reason.contains("先解压"))
            default:
                Issue.record("错误类型不符合预期：\(error.localizedDescription)")
            }
        }
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
            throw NSError(domain: "ThirdPartyImportCherryTests", code: 1)
        }
        return string
    }
}
