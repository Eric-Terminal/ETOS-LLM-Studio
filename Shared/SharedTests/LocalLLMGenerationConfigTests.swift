// ============================================================================
// LocalLLMGenerationConfigTests.swift
// ============================================================================
// ETOS LLM Studio
//
// 验证本地 llama.cpp 高级参数在 Swift 侧完成结构化映射。
// ============================================================================

import Testing
import Foundation
@testable import Shared

@Suite("本地 LLM 生成配置测试")
struct LocalLLMGenerationConfigTests {
    @Test("高级参数会映射到结构化采样配置")
    func advancedArgumentsMapToStructuredConfig() throws {
        let options = LocalLLMGenerationOptions(
            contextSize: 1024,
            maxOutputTokens: 64,
            temperature: 0.2,
            topP: 0.7,
            gpuLayers: 3,
            advancedArguments: "--ctx-size 2048 --n-predict=128 --ngl 0 --seed 42 --temp 0.9 --top-k 12 --top-p 0.8 --min-p 0.2 --typ-p 0.6 --repeat-last-n 32 --repeat-penalty 1.2 --frequency-penalty 0.3 --presence-penalty 0.4 --dry-sequence-breaker none --dry-sequence-breaker <stop> --sampler-seq kpt --ignore-eos"
        )

        let config = try LocalLLMGenerationConfig(options: options)

        #expect(config.contextSize == 2048)
        #expect(config.maxOutputTokens == 128)
        #expect(config.gpuLayers == 0)
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
        #expect(config.samplers == "kpt")
        #expect(config.ignoreEOS)
    }

    @Test("grammar-file 会在 Swift 侧读取为 grammar 文本")
    func grammarFileReadsTextInSwift() throws {
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

        let config = try LocalLLMGenerationConfig(options: options)

        #expect(config.grammar == "root ::= \"ok\"")
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
