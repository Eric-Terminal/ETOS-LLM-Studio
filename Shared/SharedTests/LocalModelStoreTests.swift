// ============================================================================
// LocalModelStoreTests.swift
// ============================================================================
// ETOS LLM Studio
//
// 验证本地模型元数据、文件生命周期与虚拟提供商映射。
// ============================================================================

import Testing
import Foundation
@testable import Shared

@Suite("本地模型存储测试")
struct LocalModelStoreTests {
    @Test("导入、更新和删除本地模型")
    func importUpdateDeleteLocalModel() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("source.gguf")
        try Data([1, 2, 3, 4]).write(to: source)
        let store = LocalModelStore(directoryURL: root.appendingPathComponent("LocalModels"))

        var record = try store.importModel(from: source, displayName: "  小模型  ")
        #expect(store.models.count == 1)
        #expect(record.sanitizedDisplayName == "小模型")
        #expect(store.fileExists(for: record))

        record.displayName = "新名字"
        record.contextSize = 0
        record.maxOutputTokens = 0
        record.gpuLayers = 7
        store.update(record)

        let reloaded = LocalModelStore(directoryURL: store.directoryURL)
        #expect(reloaded.models.first?.sanitizedDisplayName == "新名字")
        #expect(reloaded.models.first?.contextSize == 1)
        #expect(reloaded.models.first?.maxOutputTokens == 1)
        #expect(reloaded.models.first?.gpuLayers == 7)

        if let saved = reloaded.models.first {
            reloaded.delete(saved)
            #expect(reloaded.models.isEmpty)
            #expect(!reloaded.fileExists(for: saved))
        }
    }

    @Test("本地模型虚拟提供商使用稳定 ID")
    func localProviderBridgeUsesStableRunnableID() {
        let id = UUID()
        let record = LocalModelRecord(
            id: id,
            displayName: "TinyLlama",
            fileName: "tiny.gguf",
            relativePath: "tiny.gguf",
            fileSize: 8
        )

        let runnable = LocalModelProviderBridge.runnableModel(for: record)

        #expect(runnable.provider.id == LocalModelProviderBridge.providerID)
        #expect(runnable.provider.apiFormat == LocalModelProviderBridge.apiFormat)
        #expect(runnable.model.id == id)
        #expect(runnable.model.overrideParameters["context_size"] == .int(LocalModelRecord.defaultContextSize))
        #expect(runnable.model.overrideParameters["max_output_tokens"] == .int(LocalModelRecord.defaultMaxOutputTokens))
        #expect(runnable.model.overrideParameters["n_gpu_layers"] == .int(LocalModelRecord.defaultGPULayers))
        #expect(runnable.model.overrideParameters["llama_cli_args"] == .string(LocalModelRecord.defaultAdvancedArguments))
        #expect(runnable.model.supportsToolCalling)
        #expect(runnable.model.supportsEmbedding)
        #expect(LocalModelProviderBridge.localRecordID(from: runnable.id) == id)
    }

    @Test("本地模型开关决定虚拟提供商是否出现")
    func localProviderBridgeHonorsEnabledSwitch() {
        let record = LocalModelRecord(
            displayName: "TinyLlama",
            fileName: "tiny.gguf",
            relativePath: "tiny.gguf",
            fileSize: 8
        )

        let disabledProviders = LocalModelProviderBridge.applyingLocalProvider(
            to: [],
            records: [record],
            isEnabled: false,
            preferRecordBasics: true
        )
        let enabledProviders = LocalModelProviderBridge.applyingLocalProvider(
            to: [],
            records: [record],
            isEnabled: true,
            preferRecordBasics: true
        )

        #expect(!disabledProviders.contains(where: LocalModelProviderBridge.isLocalProvider))
        #expect(enabledProviders.contains(where: LocalModelProviderBridge.isLocalProvider))
        #expect(enabledProviders.first(where: LocalModelProviderBridge.isLocalProvider)?.models.count == 1)
    }

    @Test("本地模型提供商会保留管理页模型设置")
    func localProviderBridgePreservesManagedModelConfiguration() {
        let record = LocalModelRecord(
            displayName: "TinyLlama",
            fileName: "tiny.gguf",
            relativePath: "tiny.gguf",
            fileSize: 8
        )
        var provider = LocalModelProviderBridge.provider(records: [record])
        provider.models[0].kind = .embedding
        provider.models[0].overrideParameters["temperature"] = .double(0.2)
        provider.models[0].requestBodyControls = [
            ModelRequestBodyControl(
                title: "归一化",
                kind: .toggle,
                defaultIsActive: true,
                payload: ["normalize": .bool(true)]
            )
        ]

        let restored = LocalModelProviderBridge.provider(
            records: [record],
            preserving: provider,
            preferRecordBasics: true
        )

        #expect(restored.models.first?.kind == .embedding)
        #expect(restored.models.first?.overrideParameters["temperature"] == .double(0.2))
        #expect(restored.models.first?.requestBodyControls.count == 1)
    }

    @Test("提供商模型设置会回写本地权重记录")
    func localProviderModelChangesPersistToRecord() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("source.gguf")
        try Data([1, 2, 3, 4]).write(to: source)
        let store = LocalModelStore(directoryURL: root.appendingPathComponent("LocalModels"))
        let record = try store.importModel(from: source, displayName: "原名")
        var model = LocalModelProviderBridge.model(for: record)
        model.displayName = "模型别名"
        model.isActivated = false
        model.overrideParameters["context_size"] = .string("4096")
        model.overrideParameters["max_output_tokens"] = .int(1024)
        model.overrideParameters["n_gpu_layers"] = .int(0)
        model.overrideParameters["llama_cli_args"] = .string(" --temp 0.7 --top-p 0.9 ")

        store.updateFromProviderModel(model)

        #expect(store.models.first?.sanitizedDisplayName == "模型别名")
        #expect(store.models.first?.isActivated == false)
        #expect(store.models.first?.contextSize == 4096)
        #expect(store.models.first?.maxOutputTokens == 1024)
        #expect(store.models.first?.gpuLayers == 0)
        #expect(store.models.first?.advancedArguments == "--temp 0.7 --top-p 0.9")
    }

    @Test("本地对话会转换为结构化 role/content 消息")
    func localChatMessagesKeepRolesAndTrimContent() throws {
        let toolCall = InternalToolCall(id: "call_1", toolName: "app_get_system_time", arguments: "{}")
        let messages = LocalLLMChatMessageBuilder.messages(from: [
            ChatMessage(role: .system, content: "  你是助手  "),
            ChatMessage(role: .user, content: "\n你好\n"),
            ChatMessage(role: .assistant, content: "", toolCalls: [toolCall]),
            ChatMessage(role: .tool, content: "工具结果", toolCalls: [toolCall]),
            ChatMessage(role: .error, content: "错误不应进入模型"),
            ChatMessage(role: .user, content: "   ")
        ])

        #expect(messages.map(\.role) == ["system", "user", "assistant", "tool"])
        #expect(messages[0].content == "你是助手")
        #expect(messages[1].content == "你好")
        let toolCallsJSON = try #require(messages[2].toolCallsJSON)
        #expect(toolCallsJSON.contains("app_get_system_time"))
        #expect(messages[3].name == "app_get_system_time")
        #expect(messages[3].toolCallID == "call_1")
        #expect(messages[3].content == "工具结果")
    }

    @Test("本地工具定义会转换为 OpenAI 兼容函数结构")
    func localToolDefinitionsKeepFunctionSchema() throws {
        let tool = InternalToolDefinition(
            name: "app_get_system_time",
            description: "获取当前设备时间",
            parameters: .dictionary([
                "type": .string("object"),
                "properties": .dictionary([:])
            ])
        )
        let definition = try #require(LocalLLMChatMessageBuilder.toolDefinitions(from: [tool]).first)

        #expect(definition.name == "app_get_system_time")
        #expect(definition.description == "获取当前设备时间")
        #expect(definition.parametersJSON.contains("\"type\":\"object\""))
    }

    @Test("缺失文件的本地模型不会进入可用候选")
    func missingLocalModelIsNotActivatedCandidate() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalModelStore(directoryURL: root.appendingPathComponent("LocalModels"))

        store.update(LocalModelRecord(
            displayName: "Missing",
            fileName: "missing.gguf",
            relativePath: "missing.gguf",
            fileSize: 0,
            isActivated: true
        ))

        let service = ChatService(localModelStore: store)
        service.providers = LocalModelProviderBridge.applyingLocalProvider(
            to: [],
            records: store.models,
            isEnabled: true,
            preferRecordBasics: true
        )

        #expect(service.configuredRunnableModels.contains(where: { LocalModelProviderBridge.isLocalRunnableModel($0) }))
        #expect(!service.activatedConversationModels.contains(where: { LocalModelProviderBridge.isLocalRunnableModel($0) }))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalModelStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
