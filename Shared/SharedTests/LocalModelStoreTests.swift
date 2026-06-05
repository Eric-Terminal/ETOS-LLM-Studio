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
        let updatedRecord = try #require(reloaded.models.first)
        #expect(updatedRecord.sanitizedDisplayName == "新名字")
        #expect(updatedRecord.contextSize == 1)
        #expect(updatedRecord.maxOutputTokens == 1)
        #expect(updatedRecord.gpuLayers == 7)

        if let saved = reloaded.models.first {
            reloaded.delete(saved)
            #expect(reloaded.models.isEmpty)
            #expect(!reloaded.fileExists(for: saved))
        }
    }

    @Test("下载落盘文件会移动登记为本地模型")
    func downloadedModelFileRegistersWithoutDataBuffer() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let downloadedFile = root.appendingPathComponent("downloaded.tmp")
        let payload = Data([9, 8, 7, 6])
        try payload.write(to: downloadedFile)
        let store = LocalModelStore(directoryURL: root.appendingPathComponent("LocalModels"))

        let record = try store.registerDownloadedModel(
            fileAt: downloadedFile,
            suggestedFileName: "remote.gguf",
            displayName: "  下载模型  "
        )

        #expect(record.fileName == "remote.gguf")
        #expect(record.sanitizedDisplayName == "下载模型")
        #expect(store.fileExists(for: record))
        #expect(!FileManager.default.fileExists(atPath: downloadedFile.path))
        #expect(try Data(contentsOf: store.fileURL(for: record)) == payload)
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
        #expect(runnable.model.overrideParameters.isEmpty)
        #expect(!runnable.model.supportsToolCalling)
        #expect(runnable.model.supportsStreaming)
        #expect(!runnable.model.supportsEmbedding)
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
        provider.models[0].capabilities = [.toolCalling, .embedding, .reasoning]
        provider.models[0].overrideParameters["provider_only"] = .string("kept")
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
        #expect(restored.models.first?.capabilities.contains(.toolCalling) == true)
        #expect(restored.models.first?.capabilities.contains(.embedding) == true)
        #expect(restored.models.first?.capabilities.contains(.reasoning) == true)
        #expect(restored.models.first?.supportsStreaming == true)
        #expect(restored.models.first?.supportsEmbedding == true)
        #expect(restored.models.first?.overrideParameters["provider_only"] == .string("kept"))
        #expect(restored.models.first?.requestBodyControls.count == 1)
    }

    @Test("旧版强制默认参数会迁移为隐式默认")
    func legacyForcedDefaultsMigrateToImplicitOverrides() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storeDirectory = root.appendingPathComponent("LocalModels")
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        let legacyRecord = LocalModelRecord(
            displayName: "TinyLlama",
            fileName: "tiny.gguf",
            relativePath: "tiny.gguf",
            fileSize: 8,
            contextSize: LocalModelRecord.defaultContextSize,
            maxOutputTokens: LocalModelRecord.defaultMaxOutputTokens,
            gpuLayers: LocalModelRecord.defaultGPULayers,
            seed: LocalModelRecord.defaultSeed,
            temperature: 0.8,
            topK: 40,
            topP: 0.9,
            minP: 0.05,
            repeatLastN: LocalModelRecord.defaultRepeatLastN,
            repeatPenalty: LocalModelRecord.defaultRepeatPenalty,
            frequencyPenalty: LocalModelRecord.defaultFrequencyPenalty,
            presencePenalty: LocalModelRecord.defaultPresencePenalty,
            grammar: LocalModelRecord.defaultGrammar,
            ignoreEOS: LocalModelRecord.defaultIgnoreEOS,
            samplerKinds: LocalLLMSamplerKind.parse("edskypmxt")
        )
        let snapshot = LocalModelStoreSnapshot(schemaVersion: 1, models: [legacyRecord])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        try data.write(to: storeDirectory.appendingPathComponent("local-models.json"))

        let store = LocalModelStore(directoryURL: storeDirectory)
        let migrated = try #require(store.models.first)

        #expect(migrated.contextSize == nil)
        #expect(migrated.maxOutputTokens == nil)
        #expect(migrated.gpuLayers == nil)
        #expect(migrated.temperature == nil)
        #expect(migrated.topK == nil)
        #expect(migrated.topP == 0.9)
        #expect(migrated.minP == nil)
        #expect(migrated.samplerKinds == nil)
        #expect(migrated.effectiveTemperature == LocalModelRecord.defaultTemperature)
        #expect(migrated.effectiveSamplerKinds == LocalLLMSamplerKind.defaultChain)
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
        model.overrideParameters["seed"] = .string("-1")
        model.overrideParameters["temperature"] = .double(0.7)
        model.overrideParameters["top_k"] = .int(12)
        model.overrideParameters["top_p"] = .double(0.9)
        model.overrideParameters["min_p"] = .double(0.2)
        model.overrideParameters["repeat_last_n"] = .int(32)
        model.overrideParameters["repeat_penalty"] = .double(1.2)
        model.overrideParameters["frequency_penalty"] = .double(0.3)
        model.overrideParameters["presence_penalty"] = .double(0.4)
        model.overrideParameters["grammar"] = .string("root ::= \"ok\"")
        model.overrideParameters["ignore_eos"] = .bool(true)
        model.overrideParameters["sampler_seq"] = .string("kpt")
        model.overrideParameters["llama_cli_args"] = .string(" --temp 0.7 --top-p 0.9 ")

        store.updateFromProviderModel(model)

        let savedRecord = try #require(store.models.first)
        #expect(savedRecord.sanitizedDisplayName == "模型别名")
        #expect(savedRecord.isActivated == false)
        #expect(savedRecord.contextSize == 4096)
        #expect(savedRecord.maxOutputTokens == 1024)
        #expect(savedRecord.gpuLayers == 0)
        #expect(savedRecord.seed == LocalModelRecord.defaultSeed)
        #expect(savedRecord.temperature == 0.7)
        #expect(savedRecord.topK == 12)
        #expect(savedRecord.topP == 0.9)
        #expect(savedRecord.minP == 0.2)
        #expect(savedRecord.repeatLastN == 32)
        #expect(savedRecord.repeatPenalty == 1.2)
        #expect(savedRecord.frequencyPenalty == 0.3)
        #expect(savedRecord.presencePenalty == 0.4)
        #expect(savedRecord.grammar == "root ::= \"ok\"")
        #expect(savedRecord.ignoreEOS == true)
        #expect(savedRecord.samplerKinds == [.topK, .topP, .temperature])
        #expect(savedRecord.advancedArguments == "--temp 0.7 --top-p 0.9")
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

    @Test("本地工具调用在 Swift 侧解析")
    func localToolCallsParseInSwift() throws {
        let tool = LocalLLMToolDefinition(
            name: "app_get_system_time",
            description: "获取当前设备时间",
            parametersJSON: #"{"type":"object"}"#
        )

        let result = LocalLLMChatMessageBuilder.parseToolCalls(
            from: #"{"tool_calls":[{"id":"call_1","name":"app_get_system_time","arguments":{"timezone":"UTC"}}]}"#,
            tools: [tool]
        )

        let call = try #require(result.toolCalls.first)
        #expect(result.toolCalls.count == 1)
        #expect(call.id == "call_1")
        #expect(call.toolName == "app_get_system_time")
        #expect(call.arguments.contains("\"timezone\":\"UTC\""))
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

    @Test("本地 Detached Completion 不依赖远端适配器")
    func localDetachedCompletionRoutesBeforeAdapterLookup() async throws {
        let root = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            Persistence.clearUsageAnalyticsData()
        }
        let store = LocalModelStore(directoryURL: root.appendingPathComponent("LocalModels"))
        let record = LocalModelRecord(
            displayName: "Missing",
            fileName: "missing.gguf",
            relativePath: "missing.gguf",
            fileSize: 0,
            isActivated: true
        )
        store.update(record)

        let service = ChatService(adapters: [:], localModelStore: store)
        service.setSelectedModel(LocalModelProviderBridge.runnableModel(for: record))

        do {
            _ = try await service.generateDetachedChatCompletion(
                userPrompt: "生成标题",
                requestSource: .sessionTitle
            )
            Issue.record("缺失本地模型文件时不应生成成功。")
        } catch ChatService.DetachedCompletionError.unsupportedAdapter {
            Issue.record("本地 Detached Completion 不应退回 API adapter 查找。")
        } catch let error as LocalLLMEngineError {
            guard case .modelFileMissing(let fileName) = error else {
                Issue.record("错误类型不符合预期：\(error.localizedDescription)")
                return
            }
            #expect(fileName == "missing.gguf")
        } catch {
            Issue.record("抛出了非预期错误：\(error.localizedDescription)")
        }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalModelStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
