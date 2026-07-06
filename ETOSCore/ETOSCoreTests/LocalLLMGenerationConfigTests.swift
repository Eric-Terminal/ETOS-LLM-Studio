// ============================================================================
// LocalLLMGenerationConfigTests.swift
// ============================================================================
// ETOS LLM Studio
//
// 验证本地 llama.cpp 高级参数在 Swift 侧完成结构化映射。
// ============================================================================

import Testing
import Foundation
@testable import ETOSCore

@Suite("本地 LLM 生成配置测试")
struct LocalLLMGenerationConfigTests {
    @Test("默认生成配置使用轻量聊天采样")
    func defaultOptionsUseLightweightChatSampling() throws {
        let options = LocalLLMGenerationOptions(
            contextSize: 2048,
            maxOutputTokens: 512
        )

        let config = try LocalLLMGenerationConfig(options: options)

        #expect(config.temperature == 1.0)
        #expect(config.topP == 1.0)
        #expect(config.topK == 0)
        #expect(config.minP == 0.0)
        #expect(config.batchSize == 0)
        #expect(config.ubatchSize == 0)
        #expect(config.kvOffload)
        #expect(config.flashAttention == .auto)
        #expect(config.useModelCache)
        #expect(config.mmprojPath.isEmpty)
        #expect(config.imageMinTokens == -1)
        #expect(config.imageMaxTokens == -1)
        #expect(config.samplerKinds == [.temperature])
        #expect(config.chatTemplateKwargs.isEmpty)
    }

    @Test("高级参数会映射到结构化采样配置")
    func advancedArgumentsMapToStructuredConfig() throws {
        let options = LocalLLMGenerationOptions(
            contextSize: 1024,
            maxOutputTokens: 64,
            temperature: 0.2,
            topP: 0.7,
            gpuLayers: 3,
            advancedArguments: "--ctx-size 2048 --n-predict=128 --ngl 0 --n-batch 128 --n-ubatch 64 --no-kv-offload --flash-attn off --seed 42 --temp 0.9 --top-k 12 --top-p 0.8 --min-p 0.2 --typ-p 0.6 --repeat-last-n 32 --repeat-penalty 1.2 --frequency-penalty 0.3 --presence-penalty 0.4 --dry-sequence-breaker none --dry-sequence-breaker <stop> --sampler-seq kpt --ignore-eos --image-min-tokens 1000 --image-max-tokens 1120"
        )

        let config = try LocalLLMGenerationConfig(options: options)

        #expect(config.contextSize == 2048)
        #expect(config.maxOutputTokens == 128)
        #expect(config.gpuLayers == 0)
        #expect(config.batchSize == 128)
        #expect(config.ubatchSize == 64)
        #expect(!config.kvOffload)
        #expect(config.flashAttention == .disabled)
        #expect(config.seed == 42)
        #expect(config.temperature == 0.9)
        #expect(config.topK == 12)
        #expect(config.topP == 0.8)
        #expect(config.minP == 0.2)
        #expect(config.typicalP == 0.6)
        #expect(config.repeatLastN == 32)
        #expect(config.repeatPenalty == 1.2)
        #expect(config.frequencyPenalty == 0.3)
        #expect(config.presencePenalty == 0.4)
        #expect(config.drySequenceBreakers == ["<stop>"])
        #expect(config.samplerKinds == [.topK, .topP, .temperature])
        #expect(config.ignoreEOS)
        #expect(config.imageMinTokens == 1000)
        #expect(config.imageMaxTokens == 1120)
    }

    @Test("grammar-file 不会直接读取任意本地路径")
    func grammarFileIsNotReadFromArbitraryPath() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalLLMGenerationConfigTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let grammarURL = root.appendingPathComponent("json.gbnf")
        try "root ::= \"ok\"".write(to: grammarURL, atomically: true, encoding: .utf8)

        let options = LocalLLMGenerationOptions(
            contextSize: 128,
            maxOutputTokens: 16,
            advancedArguments: "--grammar-file \(grammarURL.path)"
        )

        #expect(throws: LocalLLMEngineError.self) {
            _ = try LocalLLMGenerationConfig(options: options)
        }
    }

    @Test("结构化参数会直接进入生成配置")
    func structuredOptionsMapToGenerationConfig() throws {
        let options = LocalLLMGenerationOptions(
            mmprojPath: " /tmp/mmproj.gguf ",
            contextSize: 4096,
            maxOutputTokens: 256,
            temperature: 0.65,
            topP: 0.88,
            gpuLayers: 12,
            batchSize: 256,
            ubatchSize: 128,
            kvOffload: false,
            flashAttention: .disabled,
            useModelCache: false,
            seed: 7,
            topK: 20,
            minP: 0.12,
            repeatLastN: 128,
            repeatPenalty: 1.15,
            frequencyPenalty: 0.2,
            presencePenalty: 0.1,
            grammar: "root ::= \"ok\"",
            ignoreEOS: true,
            imageMinTokens: 512,
            imageMaxTokens: 1024,
            samplerKinds: [.penalties, .topK, .topP, .temperature],
            chatTemplateKwargs: [
                "enable_thinking": .bool(false),
                "reasoning_budget": .int(0)
            ]
        )

        let config = try LocalLLMGenerationConfig(options: options)

        #expect(config.contextSize == 4096)
        #expect(config.maxOutputTokens == 256)
        #expect(config.gpuLayers == 12)
        #expect(config.batchSize == 256)
        #expect(config.ubatchSize == 128)
        #expect(!config.kvOffload)
        #expect(config.flashAttention == .disabled)
        #expect(!config.useModelCache)
        #expect(config.seed == 7)
        #expect(config.temperature == 0.65)
        #expect(config.topK == 20)
        #expect(config.topP == 0.88)
        #expect(config.minP == 0.12)
        #expect(config.repeatLastN == 128)
        #expect(config.repeatPenalty == 1.15)
        #expect(config.frequencyPenalty == 0.2)
        #expect(config.presencePenalty == 0.1)
        #expect(config.grammar == "root ::= \"ok\"")
        #expect(config.ignoreEOS)
        #expect(config.mmprojPath == "/tmp/mmproj.gguf")
        #expect(config.imageMinTokens == 512)
        #expect(config.imageMaxTokens == 1024)
        #expect(config.samplerKinds == [.penalties, .topK, .topP, .temperature])
        #expect(config.chatTemplateKwargs["enable_thinking"] == .bool(false))
        #expect(config.chatTemplateKwargs["reasoning_budget"] == .int(0))
    }

    @Test("llama.cpp-style 导入会收集应用、不支持和出错参数")
    func cliStyleImportCollectsResultBuckets() throws {
        let record = LocalModelRecord(
            displayName: "TinyLlama",
            fileName: "tiny.gguf",
            relativePath: "tiny.gguf",
            fileSize: 8,
            advancedArguments: "--temp 0.1"
        )

        let result = LocalLLMCLIStyleArgumentImporter.importArguments(
            "--temp 0.7 --top-p 0.9 --ctx-size 4096 --seed -1 --repeat-last-n -1 --ngl -1 --n-batch 256 --n-ubatch 128 --no-kv-offload --flash-attn auto --image-min-tokens 1000 --image-max-tokens 1120 --sampler-seq kpt --grammar-file /tmp/x.gbnf --mmproj /tmp/mmproj.gguf --bad-option 1 --top-k nope stray",
            into: record
        )

        #expect(result.updatedRecord.temperature == 0.7)
        #expect(result.updatedRecord.topP == 0.9)
        #expect(result.updatedRecord.contextSize == 4096)
        #expect(result.updatedRecord.seed == LocalModelRecord.defaultSeed)
        #expect(result.updatedRecord.repeatLastN == -1)
        #expect(result.updatedRecord.gpuLayers == -1)
        #expect(result.updatedRecord.batchSize == 256)
        #expect(result.updatedRecord.ubatchSize == 128)
        #expect(result.updatedRecord.kvOffload == false)
        #expect(result.updatedRecord.flashAttention == .auto)
        #expect(result.updatedRecord.imageMinTokens == 1000)
        #expect(result.updatedRecord.imageMaxTokens == 1120)
        #expect(result.updatedRecord.samplerKinds == [.topK, .topP, .temperature])
        #expect(result.updatedRecord.advancedArguments.isEmpty)
        #expect(result.appliedParameters.map(\.title).contains("温度"))
        #expect(result.unsupportedParameters.map(\.option).contains("--grammar-file"))
        #expect(result.unsupportedParameters.map(\.option).contains("--mmproj"))
        #expect(result.unsupportedParameters.map(\.option).contains("--bad-option"))
        #expect(result.errorParameters.contains(where: { $0.option == "--top-k" }))
        #expect(result.errorParameters.contains(where: { $0.option == "stray" }))
    }

    @Test("不支持的高级参数会在进入 C++ 前失败")
    func unsupportedAdvancedArgumentFailsBeforeBridge() throws {
        let options = LocalLLMGenerationOptions(
            contextSize: 128,
            maxOutputTokens: 16,
            advancedArguments: "--unknown-llama-option 1"
        )

        #expect(throws: LocalLLMEngineError.self) {
            _ = try LocalLLMGenerationConfig(options: options)
        }
    }
}
