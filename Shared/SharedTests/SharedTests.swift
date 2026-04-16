// ============================================================================
// SharedTests.swift
// ============================================================================
// SharedTests 测试文件
// - 覆盖相关模块的行为与回归测试
// - 保障迭代过程中的稳定性
// ============================================================================

//
//  SharedTests.swift
//  SharedTests
//
//  Created by Eric on 2025/10/5.
//

import Testing
import Foundation
@testable import Shared
import Combine
import SwiftUI
import SQLite3

// MARK: - Network Mocking Infrastructure

/// 用于拦截和模拟网络请求的 URLProtocol。
/// 允许我们在不实际访问网络的情况下测试网络层的各种响应（成功或失败）。
fileprivate class MockURLProtocol: URLProtocol {
    // 静态字典，用于存储预设的模拟响应。URL 是键，响应（成功或失败）是值。
    static var mockResponses: [URL: Result<(HTTPURLResponse, Data), Error>] = [:]

    override class func canInit(with request: URLRequest) -> Bool {
        // 声明我们可以处理所有类型的请求。
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        // 直接返回原始请求即可。
        return request
    }

    override func startLoading() {
        guard let client = self.client, let url = request.url else {
            fatalError("Client or URL not found.")
        }

        // 检查是否有为这个 URL 预设的模拟响应。
        if let mock = MockURLProtocol.mockResponses[url] {
            switch mock {
            case .success(let (response, data)):
                // 如果是成功响应，则通知客户端接收响应头和数据体。
                client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client.urlProtocol(self, didLoad: data)
                client.urlProtocolDidFinishLoading(self)
            case .failure(let error):
                // 如果是失败响应，则通知客户端请求失败。
                client.urlProtocol(self, didFailWithError: error)
            }
        } else {
            // 如果没有找到预设的响应，也以错误形式通知客户端。
            let error = NSError(domain: "MockURLProtocol", code: -1, userInfo: [NSLocalizedDescriptionKey: "No mock response for \(url)"]) 
            client.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {
        // 这个方法必须被重写，但我们不需要在里面做任何事。
    }
}

@Suite("聊天颜色偏好编解码")
struct ChatAppearanceColorCodecTests {
    @Test("支持解析 6 位十六进制并默认不透明")
    func parsesRGBHexWithOpaqueAlpha() {
        let color = ChatAppearanceColorCodec.color(from: "3D8FF2", fallback: .black)
        let rgba = ChatAppearanceColorCodec.rgbaComponents(from: color)

        #expect(rgba != nil)
        #expect(abs((rgba?.red ?? 0) - 0.239) < 0.01)
        #expect(abs((rgba?.green ?? 0) - 0.561) < 0.01)
        #expect(abs((rgba?.blue ?? 0) - 0.949) < 0.01)
        #expect(abs((rgba?.alpha ?? 0) - 1.0) < 0.001)
    }

    @Test("Color 与十六进制 RGBA 可往返")
    func supportsRoundTripBetweenColorAndHex() {
        let original = Color(.sRGB, red: 0.2, green: 0.4, blue: 0.6, opacity: 0.8)
        let encoded = ChatAppearanceColorCodec.hexRGBA(from: original)

        #expect(encoded == "336699CC")

        let decoded = ChatAppearanceColorCodec.color(from: encoded ?? "", fallback: .clear)
        let rgba = ChatAppearanceColorCodec.rgbaComponents(from: decoded)

        #expect(rgba != nil)
        #expect(abs((rgba?.red ?? 0) - 0.2) < 0.01)
        #expect(abs((rgba?.green ?? 0) - 0.4) < 0.01)
        #expect(abs((rgba?.blue ?? 0) - 0.6) < 0.01)
        #expect(abs((rgba?.alpha ?? 0) - 0.8) < 0.01)
    }

    @Test("变暗处理仅缩放 RGB 并保持 Alpha")
    func darkenedKeepsAlpha() {
        let original = Color(.sRGB, red: 0.8, green: 0.5, blue: 0.3, opacity: 0.4)
        let darkened = ChatAppearanceColorCodec.darkened(original, factor: 0.5)
        let rgba = ChatAppearanceColorCodec.rgbaComponents(from: darkened)

        #expect(rgba != nil)
        #expect(abs((rgba?.red ?? 0) - 0.4) < 0.01)
        #expect(abs((rgba?.green ?? 0) - 0.25) < 0.01)
        #expect(abs((rgba?.blue ?? 0) - 0.15) < 0.01)
        #expect(abs((rgba?.alpha ?? 0) - 0.4) < 0.01)
    }
}

@Suite("MainstreamModelFamily Tests")
struct MainstreamModelFamilyTests {
    @Test("按模型ID识别主流模型家族")
    func testDetectByModelName() {
        #expect(MainstreamModelFamily.detect(modelName: "gpt-4o") == .chatgpt)
        #expect(MainstreamModelFamily.detect(modelName: "gemini-2.5-pro") == .gemini)
        #expect(MainstreamModelFamily.detect(modelName: "claude-3-7-sonnet") == .claude)
        #expect(MainstreamModelFamily.detect(modelName: "deepseek-chat") == .deepseek)
        #expect(MainstreamModelFamily.detect(modelName: "qwen-max") == .qwen)
        #expect(MainstreamModelFamily.detect(modelName: "moonshot-v1-8k") == .kimi)
        #expect(MainstreamModelFamily.detect(modelName: "doubao-seed-1.6") == .doubao)
        #expect(MainstreamModelFamily.detect(modelName: "grok-3") == .grok)
        #expect(MainstreamModelFamily.detect(modelName: "meta-llama/llama-3.1-8b-instruct") == .llama)
        #expect(MainstreamModelFamily.detect(modelName: "mixtral-8x7b-instruct") == .mistral)
        #expect(MainstreamModelFamily.detect(modelName: "glm-4-plus") == .glm)
    }

    @Test("按显示名识别主流模型家族")
    func testDetectByDisplayName() {
        #expect(MainstreamModelFamily.detect(modelName: "custom-model", displayName: "ChatGPT 企业版") == .chatgpt)
        #expect(MainstreamModelFamily.detect(modelName: "custom-model", displayName: "豆包 Pro") == .doubao)
    }

    @Test("未知模型识别为其他")
    func testUnknownModelReturnsNil() {
        #expect(MainstreamModelFamily.detect(modelName: "my-private-model") == nil)
    }
}

@Suite("Provider Active Model Order Tests")
struct ProviderActiveModelOrderTests {
    private func makeModel(_ name: String, active: Bool) -> Model {
        Model(modelName: name, displayName: name, isActivated: active)
    }

    @Test("仅重排已添加模型，未添加模型位置保持不变")
    func testMoveActivatedModelsKeepsInactiveOrder() {
        var provider = Provider(
            name: "Test",
            baseURL: "https://example.com",
            apiKeys: [],
            apiFormat: "openai-compatible",
            models: [
                makeModel("a", active: true),
                makeModel("x", active: false),
                makeModel("b", active: true),
                makeModel("c", active: true),
                makeModel("y", active: false)
            ]
        )

        provider.moveActivatedModels(fromOffsets: IndexSet(integer: 0), toOffset: 3)

        #expect(provider.models.map(\.modelName) == ["b", "x", "c", "a", "y"])
        #expect(provider.models.filter(\.isActivated).map(\.modelName) == ["b", "c", "a"])
    }

    @Test("非法拖拽索引不会改动模型顺序")
    func testMoveActivatedModelsWithInvalidOffsetsNoChange() {
        var provider = Provider(
            name: "Test",
            baseURL: "https://example.com",
            apiKeys: [],
            apiFormat: "openai-compatible",
            models: [
                makeModel("a", active: true),
                makeModel("x", active: false),
                makeModel("b", active: true)
            ]
        )
        let original = provider.models.map(\.modelName)

        provider.moveActivatedModels(fromOffsets: IndexSet(integer: 10), toOffset: 1)

        #expect(provider.models.map(\.modelName) == original)
    }

    @Test("按位置移动已添加模型")
    func testMoveActivatedModelByPosition() {
        var provider = Provider(
            name: "Test",
            baseURL: "https://example.com",
            apiKeys: [],
            apiFormat: "openai-compatible",
            models: [
                makeModel("a", active: true),
                makeModel("x", active: false),
                makeModel("b", active: true),
                makeModel("c", active: true),
                makeModel("y", active: false)
            ]
        )

        provider.moveActivatedModel(fromPosition: 2, toPosition: 0)

        #expect(provider.models.map(\.modelName) == ["c", "x", "a", "b", "y"])
    }
}

@Suite("ModelOrderIndex Tests")
struct ModelOrderIndexTests {
    @Test("合并隐藏索引时保留旧顺序并追加新增模型")
    func testMergeOrderKeepsStoredThenAppendsNew() {
        let stored = ["p1-m2", "p2-m1", "removed", "p1-m2"]
        let current = ["p1-m1", "p1-m2", "p2-m1", "p3-m1"]

        let merged = ModelOrderIndex.merge(storedIDs: stored, currentIDs: current)

        #expect(merged == ["p1-m2", "p2-m1", "p1-m1", "p3-m1"])
    }

    @Test("按位置移动隐藏索引")
    func testMoveOrderByPosition() {
        let ids = ["a", "b", "c", "d"]

        let moved = ModelOrderIndex.move(ids: ids, fromPosition: 3, toPosition: 1)

        #expect(moved == ["a", "d", "b", "c"])
    }
}

@Suite("Request Body Override Mode Tests")
struct RequestBodyOverrideModeTests {
    @Test("原始 JSON 对象可解析为覆盖参数")
    func testParseRawJSONObject() throws {
        let rawJSON = """
        {
          "temperature": 0.7,
          "stream": true,
          "extra_body": {
            "abc": "123",
            "tags": ["x", 1, false]
          }
        }
        """
        let parsed = try ParameterExpressionParser.parseRawJSONObject(rawJSON)
        #expect(parsed["temperature"] == .double(0.7))
        #expect(parsed["stream"] == .bool(true))

        guard case .dictionary(let extraBody)? = parsed["extra_body"] else {
            Issue.record("extra_body 未按预期解析为对象")
            return
        }
        #expect(extraBody["abc"] == .string("123"))
        guard case .array(let tags)? = extraBody["tags"] else {
            Issue.record("extra_body.tags 未按预期解析为数组")
            return
        }
        #expect(tags.count == 3)
    }

    @Test("原始 JSON 顶层非对象时返回错误")
    func testParseRawJSONObjectRejectsNonObject() {
        do {
            _ = try ParameterExpressionParser.parseRawJSONObject("[1, 2, 3]")
            Issue.record("顶层为数组时应当解析失败")
        } catch {
            #expect(error.localizedDescription.contains("顶层必须是 JSON 对象"))
        }
    }

    @Test("Model 编解码保留请求体编辑模式和原始 JSON 文本")
    func testModelCodingPreservesRequestBodyMode() throws {
        let source = Model(
            modelName: "test-model",
            overrideParameters: ["temperature": .double(0.8)],
            requestBodyOverrideMode: .rawJSON,
            rawRequestBodyJSON: "{\"temperature\":0.8}"
        )
        let data = try JSONEncoder().encode(source)
        let decoded = try JSONDecoder().decode(Model.self, from: data)

        #expect(decoded.requestBodyOverrideMode == .rawJSON)
        #expect(decoded.rawRequestBodyJSON == "{\"temperature\":0.8}")
    }

    @Test("旧配置缺少新字段时使用默认编辑模式")
    func testModelDecodingDefaultsForLegacyPayload() throws {
        let legacyJSON = """
        {
          "id": "00000000-0000-0000-0000-000000000123",
          "modelName": "legacy-model",
          "isActivated": false
        }
        """
        let data = Data(legacyJSON.utf8)
        let decoded = try JSONDecoder().decode(Model.self, from: data)

        #expect(decoded.requestBodyOverrideMode == .expression)
        #expect(decoded.rawRequestBodyJSON == nil)
    }
}


// MARK: - MemoryManager Tests

@Suite("MemoryManager Tests")
struct MemoryManagerTests {
    
    struct MockEmbeddingGenerator: MemoryEmbeddingGenerating {
        func generateEmbeddings(for texts: [String], preferredModelID: String?) async throws -> [[Float]] {
            texts.map { text in
                let normalized = text.lowercased()
                let tokens = normalized.split { !$0.isLetter && !$0.isNumber }
                var vector = Array(repeating: Float(0), count: 8)

                for token in tokens {
                    let bucket = token.unicodeScalars.reduce(0) { partialResult, scalar in
                        partialResult + Int(scalar.value)
                    } % vector.count
                    vector[bucket] += 1
                }

                if vector.allSatisfy({ $0 == 0 }) {
                    vector[0] = 1
                }
                return vector
            }
        }
    }

    class FixedDimensionEmbeddings: EmbeddingsProtocol {
        typealias TokenizerType = Never
        typealias ModelType = Never
        var tokenizer: Never { fatalError("Not implemented") }
        var model: Never { fatalError("Not implemented") }

        private let dimension: Int

        init(dimension: Int = 4) {
            self.dimension = max(1, dimension)
        }

        func encode(sentence: String) async -> [Float]? {
            Array(repeating: 0.25, count: dimension)
        }
    }
    
    actor FlakyEmbeddingGenerator: MemoryEmbeddingGenerating {
        enum TestError: Error {
            case forced
        }
        
        private var attempts = 0
        private let failuresBeforeSuccess: Int
        
        init(failuresBeforeSuccess: Int) {
            self.failuresBeforeSuccess = max(0, failuresBeforeSuccess)
        }
        
        func generateEmbeddings(for texts: [String], preferredModelID: String?) async throws -> [[Float]] {
            attempts += 1
            if attempts <= failuresBeforeSuccess {
                throw TestError.forced
            }
            return texts.map { _ in Array(repeating: 0.42, count: 4) }
        }
        
        func attemptsCount() -> Int {
            attempts
        }
    }
    
    actor AlwaysFailEmbeddingGenerator: MemoryEmbeddingGenerating {
        enum TestError: Error {
            case forced
        }
        
        func generateEmbeddings(for texts: [String], preferredModelID: String?) async throws -> [[Float]] {
            throw TestError.forced
        }
    }
    
    actor ProgressEventRecorder {
        private var events: [MemoryEmbeddingProgress] = []
        
        func append(_ event: MemoryEmbeddingProgress) {
            events.append(event)
        }
        
        func snapshot() -> [MemoryEmbeddingProgress] {
            events
        }
    }

    // Helper now accepts a specific manager instance to clean up.
    private func cleanup(memoryManager: MemoryManager) async {
        let allMems = await memoryManager.getAllMemories()
        if !allMems.isEmpty {
            await memoryManager.deleteMemories(allMems)
        }
        let currentMems = await memoryManager.getAllMemories()
        #expect(currentMems.isEmpty, "Cleanup failed: Memories should be empty.")
    }

    @Test("Add and Retrieve Memory")
    func testAddMemory() async throws {
        let memoryManager = MemoryManager(embeddingGenerator: MockEmbeddingGenerator())
        await memoryManager.waitForInitialization()
        await cleanup(memoryManager: memoryManager)
        
        let content = "The user's favorite color is blue."
        await memoryManager.addMemory(content: content)
        
        let allMems = await memoryManager.getAllMemories()
        #expect(allMems.count == 1)
        #expect(allMems.first?.content == content)

        await cleanup(memoryManager: memoryManager)
    }
    
    @Test("Embedding Retry Handles Transient Failures")
    func testEmbeddingRetryLogic() async throws {
        let generator = FlakyEmbeddingGenerator(failuresBeforeSuccess: 2)
        let retryPolicy = MemoryEmbeddingRetryPolicy(maxAttempts: 3, initialDelay: 0, backoffMultiplier: 1)
        let memoryManager = MemoryManager(
            embeddingGenerator: generator,
            chunkSize: 200,
            retryPolicy: retryPolicy
        )
        await memoryManager.waitForInitialization()
        await cleanup(memoryManager: memoryManager)
        
        await memoryManager.addMemory(content: "用户最喜欢的茶是铁观音。")
        
        let attempts = await generator.attemptsCount()
        #expect(attempts == 3, "生成器应在两次失败后第3次成功。")
        
        let memories = await memoryManager.getAllMemories()
        #expect(memories.count == 1)
        
        await cleanup(memoryManager: memoryManager)
    }
    
    @Test("Persist Pending Memory And Reconcile")
    func testPendingMemoryReconciledAfterFailure() async throws {
        let generator = FlakyEmbeddingGenerator(failuresBeforeSuccess: 1)
        let retryPolicy = MemoryEmbeddingRetryPolicy(maxAttempts: 1, initialDelay: 0, backoffMultiplier: 1)
        let memoryManager = MemoryManager(
            embeddingGenerator: generator,
            retryPolicy: retryPolicy
        )
        await memoryManager.waitForInitialization()
        await cleanup(memoryManager: memoryManager)
        
        await memoryManager.addMemory(content: "用户偏爱用法压壶冲咖啡。")
        
        let attemptsAfterAdd = await generator.attemptsCount()
        #expect(attemptsAfterAdd == 1, "首次添加应失败一次并立即写入 JSON。")
        
        let memories = await memoryManager.getAllMemories()
        #expect(memories.count == 1, "即便嵌入失败也要保存原文记忆。")
        
        let reconciled = await memoryManager.reconcilePendingEmbeddings()
        #expect(reconciled == 1, "缺失的记忆应被识别并补偿。")
        
        let attemptsAfterReconcile = await generator.attemptsCount()
        #expect(attemptsAfterReconcile == 2, "补偿时应再次调用嵌入并最终成功。")
        
        await cleanup(memoryManager: memoryManager)
    }
    
    @Test("Reembed Progress Emits Running To Completed")
    func testReembedProgressEmitsRunningToCompleted() async throws {
        let memoryManager = MemoryManager(embeddingGenerator: MockEmbeddingGenerator())
        await memoryManager.waitForInitialization()
        await cleanup(memoryManager: memoryManager)
        
        await memoryManager.addMemory(content: "用户喜欢手冲咖啡。")
        await memoryManager.addMemory(content: "用户偏好简洁回答。")
        await memoryManager.addMemory(content: "用户常用语言是中文。")
        
        let recorder = ProgressEventRecorder()
        let cancellable = memoryManager.embeddingProgressPublisher.sink { event in
            Task {
                await recorder.append(event)
            }
        }
        defer { cancellable.cancel() }
        
        _ = try await memoryManager.reembedAllMemories()
        try await Task.sleep(for: .milliseconds(100))
        
        let events = await recorder.snapshot().filter { $0.kind == .reembedAll }
        #expect(!events.isEmpty)
        #expect(events.contains { $0.phase == .running && $0.processedMemories == 0 && $0.totalMemories == 3 })
        #expect(events.contains { $0.phase == .running && $0.processedMemories > 0 && $0.processedMemories <= 3 })
        
        if let last = events.last {
            #expect(last.phase == .completed)
            #expect(last.processedMemories == 3)
            #expect(last.totalMemories == 3)
        } else {
            Issue.record("未捕获到重嵌入进度事件。")
        }
        
        await cleanup(memoryManager: memoryManager)
    }
    
    @Test("Reembed Progress Emits Failed On Error")
    func testReembedProgressEmitsFailedOnError() async throws {
        let retryPolicy = MemoryEmbeddingRetryPolicy(maxAttempts: 1, initialDelay: 0, backoffMultiplier: 1)
        let memoryManager = MemoryManager(
            embeddingGenerator: AlwaysFailEmbeddingGenerator(),
            retryPolicy: retryPolicy
        )
        await memoryManager.waitForInitialization()
        await cleanup(memoryManager: memoryManager)
        
        await memoryManager.addMemory(content: "这条记忆会导致重嵌入失败。")
        
        let recorder = ProgressEventRecorder()
        let cancellable = memoryManager.embeddingProgressPublisher.sink { event in
            Task {
                await recorder.append(event)
            }
        }
        defer { cancellable.cancel() }
        
        do {
            _ = try await memoryManager.reembedAllMemories()
            Issue.record("预期重嵌入抛错，但未抛错。")
        } catch {
            // expected
        }
        
        try await Task.sleep(for: .milliseconds(100))
        
        let events = await recorder.snapshot().filter { $0.kind == .reembedAll }
        #expect(events.contains { $0.phase == .running && $0.processedMemories == 0 && $0.totalMemories == 1 })
        
        if let last = events.last {
            #expect(last.phase == .failed)
            #expect(last.processedMemories < last.totalMemories)
        } else {
            Issue.record("未捕获到重嵌入失败进度事件。")
        }
        
        await cleanup(memoryManager: memoryManager)
    }
    
    @Test("Reconcile Progress Emits For Missing Embeddings")
    func testReconcileProgressEmitsForMissingEmbeddings() async throws {
        let generator = FlakyEmbeddingGenerator(failuresBeforeSuccess: 1)
        let retryPolicy = MemoryEmbeddingRetryPolicy(maxAttempts: 1, initialDelay: 0, backoffMultiplier: 1)
        let memoryManager = MemoryManager(
            embeddingGenerator: generator,
            retryPolicy: retryPolicy
        )
        await memoryManager.waitForInitialization()
        await cleanup(memoryManager: memoryManager)
        
        await memoryManager.addMemory(content: "这条记忆首次嵌入会失败，随后由补偿补齐。")
        
        let recorder = ProgressEventRecorder()
        let cancellable = memoryManager.embeddingProgressPublisher.sink { event in
            Task {
                await recorder.append(event)
            }
        }
        defer { cancellable.cancel() }
        
        let reconciled = await memoryManager.reconcilePendingEmbeddings()
        #expect(reconciled == 1)
        try await Task.sleep(for: .milliseconds(100))
        
        let events = await recorder.snapshot().filter { $0.kind == .reconcilePending }
        #expect(events.contains { $0.phase == .running && $0.processedMemories == 0 && $0.totalMemories == 1 })

        if let completed = events.last(where: { $0.phase == .completed }) {
            #expect(completed.processedMemories == 1)
            #expect(completed.totalMemories == 1)
        } else {
            Issue.record("未捕获到补偿完成进度事件。")
        }
        
        await cleanup(memoryManager: memoryManager)
    }
    
    @Test("No Reconcile Progress Event When Nothing To Reconcile")
    func testNoReconcileProgressEventWhenNothingToReconcile() async throws {
        let memoryManager = MemoryManager(embeddingGenerator: MockEmbeddingGenerator())
        await memoryManager.waitForInitialization()
        await cleanup(memoryManager: memoryManager)
        
        await memoryManager.addMemory(content: "这条记忆已经具备嵌入。")
        
        let recorder = ProgressEventRecorder()
        let cancellable = memoryManager.embeddingProgressPublisher.sink { event in
            Task {
                await recorder.append(event)
            }
        }
        defer { cancellable.cancel() }
        
        let reconciled = await memoryManager.reconcilePendingEmbeddings()
        #expect(reconciled == 0)
        try await Task.sleep(for: .milliseconds(100))
        
        let events = await recorder.snapshot().filter { $0.kind == .reconcilePending }
        #expect(events.isEmpty)
        
        await cleanup(memoryManager: memoryManager)
    }

    @Test("Delete Memory")
    func testDeleteMemory() async throws {
        let memoryManager = MemoryManager(embeddingGenerator: MockEmbeddingGenerator())
        await memoryManager.waitForInitialization()
        await cleanup(memoryManager: memoryManager)
        
        let content = "This memory will be deleted."
        await memoryManager.addMemory(content: content)
        var allMems = await memoryManager.getAllMemories()
        #expect(allMems.count == 1)

        guard let memoryToDelete = allMems.first else {
            Issue.record("Failed to add memory in setup for deletion test.")
            return
        }
        
        await memoryManager.deleteMemories([memoryToDelete])
        
        allMems = await memoryManager.getAllMemories()
        #expect(allMems.isEmpty)

        await cleanup(memoryManager: memoryManager)
    }

    @Test("Update Memory")
    func testUpdateMemory() async throws {
        let memoryManager = MemoryManager(embeddingGenerator: MockEmbeddingGenerator())
        await memoryManager.waitForInitialization()
        await cleanup(memoryManager: memoryManager)

        let originalContent = "Original content."
        let updatedContent = "Updated content."
        await memoryManager.addMemory(content: originalContent)

        var allMems = await memoryManager.getAllMemories()
        #expect(allMems.count == 1, "After adding, memory count should be 1.")

        guard var memoryToUpdate = allMems.first else {
            Issue.record("Failed to retrieve memory for update test.")
            return
        }
        
        memoryToUpdate.content = updatedContent
        await memoryManager.updateMemory(item: memoryToUpdate)
        
        allMems = await memoryManager.getAllMemories()
        #expect(allMems.count == 1, "After updating, memory count should still be 1.")
        #expect(allMems.first?.content == updatedContent, "The memory content should have been updated.")

        await cleanup(memoryManager: memoryManager)
    }

    @Test("Search Memories")
    func testSearchMemories() async throws {
        let memoryManager = MemoryManager(embeddingGenerator: MockEmbeddingGenerator(), chunkSize: 50)
        await memoryManager.waitForInitialization()
        await cleanup(memoryManager: memoryManager)

        await memoryManager.addMemory(content: "The user owns a golden retriever.")
        await memoryManager.addMemory(content: "The user's favorite programming language is Swift.")
        await memoryManager.addMemory(content: "The capital of France is Paris.")
        
        try await Task.sleep(for: .milliseconds(100))

        let searchResults = await memoryManager.searchMemories(query: "What is the user's favorite language?", topK: 1)
        
        #expect(searchResults.count == 1)
        #expect(searchResults.first?.content == "The user's favorite programming language is Swift.")

        await cleanup(memoryManager: memoryManager)
    }
    
    @Test("Search Memories Deduplicates Chunks And Returns Originals")
    func testSearchMemoriesDeduplicates() async throws {
        let memoryManager = MemoryManager(embeddingGenerator: MockEmbeddingGenerator(), chunkSize: 10)
        await memoryManager.waitForInitialization()
        await cleanup(memoryManager: memoryManager)
        
        let longMemory = Array(repeating: "Swift rocks!", count: 30).joined(separator: " ")
        let secondMemory = "The user enjoys cycling in Shanghai."
        let thirdMemory = "They also brew espresso every morning."
        
        await memoryManager.addMemory(content: longMemory)
        await memoryManager.addMemory(content: secondMemory)
        await memoryManager.addMemory(content: thirdMemory)
        
        try await Task.sleep(for: .milliseconds(100))
        
        let searchResults = await memoryManager.searchMemories(query: "Swift rocks! tips", topK: 2)
        
        #expect(searchResults.count == 2, "Should return the requested number of unique memories when available.")
        #expect(Set(searchResults.map(\.id)).count == 2, "Returned memories must be unique.")
        #expect(searchResults.contains(where: { $0.content == longMemory }), "Chunked memory should surface as its full original text.")

        await cleanup(memoryManager: memoryManager)
    }

    @Test("初始化不会自动修复历史分块污染")
    func testInitializationDoesNotAutoReconstructChunkedMemories() async throws {
        let parentID = UUID()
        let createdAt = Date(timeIntervalSince1970: 1_710_000_000)
        let createdAtString = ISO8601DateFormatter().string(from: createdAt)

        let index = await SimilarityIndex(
            name: "memory-reconstruct-\(UUID().uuidString)",
            model: FixedDimensionEmbeddings(),
            vectorStore: JsonStore()
        )
        await index.addItem(
            id: UUID().uuidString,
            text: "用户喜欢",
            metadata: [
                "parentMemoryId": parentID.uuidString,
                "chunkIndex": "0",
                "createdAt": createdAtString
            ],
            embedding: [0.1, 0.2, 0.3, 0.4]
        )
        await index.addItem(
            id: UUID().uuidString,
            text: "低温慢煮咖啡。",
            metadata: [
                "parentMemoryId": parentID.uuidString,
                "chunkIndex": "1",
                "createdAt": createdAtString
            ],
            embedding: [0.1, 0.2, 0.3, 0.4]
        )

        let memoryManager = MemoryManager(
            testIndex: index,
            embeddingGenerator: MockEmbeddingGenerator()
        )
        await memoryManager.waitForInitialization()

        let memories = await memoryManager.getAllMemories()
        #expect(memories.count == 2)
        #expect(memories.allSatisfy { $0.id != parentID })
        #expect(Set(memories.map(\.content)) == ["用户喜欢", "低温慢煮咖啡。"])

        await cleanup(memoryManager: memoryManager)
    }

    @Test("Search Memories By Keyword")
    func testSearchMemoriesByKeyword() async throws {
        let memoryManager = MemoryManager(embeddingGenerator: MockEmbeddingGenerator(), chunkSize: 50)
        await memoryManager.waitForInitialization()
        await cleanup(memoryManager: memoryManager)

        await memoryManager.addMemory(content: "用户喜欢喝抹茶拿铁。")
        await memoryManager.addMemory(content: "用户最喜欢的编辑器是 Xcode。")
        await memoryManager.addMemory(content: "用户每周都会去爬山。")

        let results = await memoryManager.searchMemoriesByKeyword(query: "抹茶 拿铁", topK: 2)
        #expect(!results.isEmpty)
        #expect(results.first?.content.contains("抹茶") == true)

        await cleanup(memoryManager: memoryManager)
    }
}

// MARK: - OpenAIAdapter Tests

@Suite("OpenAIAdapter Tests")
struct OpenAIAdapterTests {

    private let adapter = OpenAIAdapter()
    private let dummyModel = RunnableModel(
        provider: Provider(
            id: UUID(),
            name: "Test Provider",
            baseURL: "https://api.test.com/v1",
            apiKeys: ["test-key"],
            apiFormat: "openai-compatible"
        ),
        model: Model(modelName: "test-model")
    )

    private var saveMemoryTool: InternalToolDefinition {
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
        return InternalToolDefinition(name: "save_memory", description: "Save a piece of important information to long-term memory.", parameters: parameters, isBlocking: false)
    }

    @Test("Tool Definition Encoding")
    func testToolDefinitionEncoding() throws {
        let tools = [saveMemoryTool]
        let messages = [ChatMessage(role: .user, content: "Hello")]
        
        guard let request = adapter.buildChatRequest(for: dummyModel, commonPayload: [:], messages: messages, tools: tools, audioAttachments: [:], imageAttachments: [:], fileAttachments: [:]), 
              let httpBody = request.httpBody,
              let jsonPayload = try? JSONSerialization.jsonObject(with: httpBody) as? [String: Any] else {
            Issue.record("Failed to build or parse request payload.")
            return
        }
        
        guard let toolsPayload = jsonPayload["tools"] as? [[String: Any]],
              let firstTool = toolsPayload.first,
              let type = firstTool["type"] as? String,
              let function = firstTool["function"] as? [String: Any],
              let functionName = function["name"] as? String,
              let params = function["parameters"] as? [String: Any],
              let properties = params["properties"] as? [String: Any] else {
            Issue.record("Failed to decode the 'tools' structure from the JSON payload.")
            return
        }
        
        #expect(toolsPayload.count == 1)
        #expect(type == "function")
        #expect(functionName == "save_memory")
        #expect(params["type"] as? String == "object")
        #expect(properties["content"] != nil)
    }

    @Test("OpenAI 工具 schema 缺失 type 时自动补全")
    func testOpenAIToolSchemaTypeInferenceForEnumField() throws {
        let tools = [
            InternalToolDefinition(
                name: "tavily_search",
                description: "搜索网络内容",
                parameters: .dictionary([
                    "type": .string("object"),
                    "properties": .dictionary([
                        "query": .dictionary([
                            "type": .string("string")
                        ]),
                        "time_range": .dictionary([
                            "description": .string("可选时间范围"),
                            "enum": .array([
                                .string("day"),
                                .string("week"),
                                .string("month")
                            ])
                        ]),
                        "filters": .dictionary([
                            "properties": .dictionary([
                                "safe": .dictionary([
                                    "type": .string("boolean")
                                ])
                            ])
                        ])
                    ]),
                    "required": .array([.string("query")])
                ])
            )
        ]
        let messages = [ChatMessage(role: .user, content: "测试一下")]

        guard let request = adapter.buildChatRequest(
            for: dummyModel,
            commonPayload: [:],
            messages: messages,
            tools: tools,
            audioAttachments: [:],
            imageAttachments: [:],
            fileAttachments: [:]
        ),
        let httpBody = request.httpBody,
        let jsonPayload = try? JSONSerialization.jsonObject(with: httpBody) as? [String: Any],
        let toolsPayload = jsonPayload["tools"] as? [[String: Any]],
        let firstTool = toolsPayload.first,
        let function = firstTool["function"] as? [String: Any],
        let parameters = function["parameters"] as? [String: Any],
        let properties = parameters["properties"] as? [String: Any],
        let timeRangeSchema = properties["time_range"] as? [String: Any],
        let filtersSchema = properties["filters"] as? [String: Any] else {
            Issue.record("OpenAI 请求体中未找到工具参数 schema。")
            return
        }

        #expect(timeRangeSchema["type"] as? String == "string")
        #expect(filtersSchema["type"] as? String == "object")
    }

    @Test("OpenAI 工具 schema 组合类型和叶子节点兜底补全")
    func testOpenAISchemaTypeInferenceForCombinatorAndLeafFallback() throws {
        let tools = [
            InternalToolDefinition(
                name: "tavily_search",
                description: "搜索网络内容",
                parameters: .dictionary([
                    "type": .string("object"),
                    "properties": .dictionary([
                        "time_range": .dictionary([
                            "description": .string("时间范围"),
                            "oneOf": .array([
                                .dictionary([
                                    "enum": .array([.string("day"), .string("week"), .string("month")])
                                ]),
                                .dictionary([
                                    "type": .string("null")
                                ])
                            ])
                        ]),
                        "locale": .dictionary([
                            "description": .string("地区代码"),
                            "default": .string("en")
                        ])
                    ])
                ])
            )
        ]
        let messages = [ChatMessage(role: .user, content: "测试一下")]

        guard let request = adapter.buildChatRequest(
            for: dummyModel,
            commonPayload: [:],
            messages: messages,
            tools: tools,
            audioAttachments: [:],
            imageAttachments: [:],
            fileAttachments: [:]
        ),
        let httpBody = request.httpBody,
        let jsonPayload = try? JSONSerialization.jsonObject(with: httpBody) as? [String: Any],
        let toolsPayload = jsonPayload["tools"] as? [[String: Any]],
        let firstTool = toolsPayload.first,
        let function = firstTool["function"] as? [String: Any],
        let parameters = function["parameters"] as? [String: Any],
        let properties = parameters["properties"] as? [String: Any],
        let timeRangeSchema = properties["time_range"] as? [String: Any],
        let localeSchema = properties["locale"] as? [String: Any] else {
            Issue.record("OpenAI 请求体中未找到组合类型 schema。")
            return
        }

        #expect(timeRangeSchema["type"] as? String == "string")
        #expect(localeSchema["type"] as? String == "string")
    }

    @Test("OpenAI 工具 schema 的 anyOf 会扁平化并移除 default:null")
    func testOpenAISchemaFlattensAnyOfAndDropsNullDefault() throws {
        let tools = [
            InternalToolDefinition(
                name: "tavily_search",
                description: "搜索网络内容",
                parameters: .dictionary([
                    "type": .string("object"),
                    "properties": .dictionary([
                        "time_range": .dictionary([
                            "default": .null,
                            "anyOf": .array([
                                .dictionary([
                                    "type": .string("string"),
                                    "enum": .array([
                                        .string("day"),
                                        .string("week"),
                                        .string("month"),
                                        .string("year")
                                    ])
                                ]),
                                .dictionary([:])
                            ]),
                            "description": .string("可选时间范围")
                        ])
                    ])
                ])
            )
        ]
        let messages = [ChatMessage(role: .user, content: "测试一下")]

        guard let request = adapter.buildChatRequest(
            for: dummyModel,
            commonPayload: [:],
            messages: messages,
            tools: tools,
            audioAttachments: [:],
            imageAttachments: [:],
            fileAttachments: [:]
        ),
        let httpBody = request.httpBody,
        let jsonPayload = try? JSONSerialization.jsonObject(with: httpBody) as? [String: Any],
        let toolsPayload = jsonPayload["tools"] as? [[String: Any]],
        let firstTool = toolsPayload.first,
        let function = firstTool["function"] as? [String: Any],
        let parameters = function["parameters"] as? [String: Any],
        let properties = parameters["properties"] as? [String: Any],
        let timeRangeSchema = properties["time_range"] as? [String: Any] else {
            Issue.record("OpenAI 请求体中未找到 time_range schema。")
            return
        }

        #expect(timeRangeSchema["type"] as? String == "string")
        #expect(timeRangeSchema["anyOf"] == nil)
        #expect(timeRangeSchema["oneOf"] == nil)
        #expect(timeRangeSchema["allOf"] == nil)
        #expect(timeRangeSchema["default"] == nil)
    }

    @Test("OpenAI 工具 schema 的 properties 允许字符串简写并自动包装为对象")
    func testOpenAIPropertiesStringShorthandSchemaGetsWrapped() throws {
        let tools = [
            InternalToolDefinition(
                name: "tavily_extract",
                description: "提取网页内容",
                parameters: .dictionary([
                    "type": .string("object"),
                    "properties": .dictionary([
                        "urls": .dictionary([
                            "type": .string("array"),
                            "items": .dictionary([
                                "type": .string("string")
                            ])
                        ]),
                        "type": .string("string"),
                        "format": .dictionary([
                            "type": .string("string"),
                            "enum": .array([.string("markdown"), .string("text")]),
                            "default": .string("markdown")
                        ])
                    ]),
                    "required": .array([.string("urls")])
                ])
            )
        ]
        let messages = [ChatMessage(role: .user, content: "测试一下")]

        guard let request = adapter.buildChatRequest(
            for: dummyModel,
            commonPayload: [:],
            messages: messages,
            tools: tools,
            audioAttachments: [:],
            imageAttachments: [:],
            fileAttachments: [:]
        ),
        let httpBody = request.httpBody,
        let jsonPayload = try? JSONSerialization.jsonObject(with: httpBody) as? [String: Any],
        let toolsPayload = jsonPayload["tools"] as? [[String: Any]],
        let firstTool = toolsPayload.first,
        let function = firstTool["function"] as? [String: Any],
        let parameters = function["parameters"] as? [String: Any],
        let properties = parameters["properties"] as? [String: Any],
        let typeSchema = properties["type"] as? [String: Any] else {
            Issue.record("OpenAI 请求体中未找到 properties.type 的对象化 schema。")
            return
        }

        #expect(typeSchema["type"] as? String == "string")
        #expect(!(properties["type"] is String))
    }

    @Test("OpenAI 工具 schema 中属性名 type 不会被误当关键字移除")
    func testOpenAISchemaPropertyNamedTypeKeepsInPropertiesMap() throws {
        let tools = [
            InternalToolDefinition(
                name: "ask_user_input",
                description: "测试 ask_user_input",
                parameters: .dictionary([
                    "type": .string("object"),
                    "properties": .dictionary([
                        "questions": .dictionary([
                            "type": .string("array"),
                            "items": .dictionary([
                                "type": .string("object"),
                                "properties": .dictionary([
                                    "question": .dictionary([
                                        "type": .string("string")
                                    ]),
                                    "type": .dictionary([
                                        "type": .string("string"),
                                        "enum": .array([.string("single_select"), .string("multi_select")])
                                    ]),
                                    "options": .dictionary([
                                        "type": .string("array"),
                                        "items": .dictionary([
                                            "type": .string("string")
                                        ])
                                    ])
                                ]),
                                "required": .array([.string("question"), .string("type"), .string("options")])
                            ])
                        ])
                    ]),
                    "required": .array([.string("questions")])
                ])
            )
        ]
        let messages = [ChatMessage(role: .user, content: "测试一下")]

        guard let request = adapter.buildChatRequest(
            for: dummyModel,
            commonPayload: [:],
            messages: messages,
            tools: tools,
            audioAttachments: [:],
            imageAttachments: [:],
            fileAttachments: [:]
        ),
        let httpBody = request.httpBody,
        let jsonPayload = try? JSONSerialization.jsonObject(with: httpBody) as? [String: Any],
        let toolsPayload = jsonPayload["tools"] as? [[String: Any]],
        let firstTool = toolsPayload.first,
        let function = firstTool["function"] as? [String: Any],
        let parameters = function["parameters"] as? [String: Any],
        let rootProperties = parameters["properties"] as? [String: Any],
        let questionsSchema = rootProperties["questions"] as? [String: Any],
        let questionItemsSchema = questionsSchema["items"] as? [String: Any],
        let questionProperties = questionItemsSchema["properties"] as? [String: Any],
        let typeSchema = questionProperties["type"] as? [String: Any],
        let required = questionItemsSchema["required"] as? [String] else {
            Issue.record("OpenAI 请求体中未找到 ask_user_input 的 type 字段 schema。")
            return
        }

        #expect(typeSchema["type"] as? String == "string")
        #expect((typeSchema["enum"] as? [String]) == ["single_select", "multi_select"])
        #expect(required.contains("type"))
    }

    @Test("OpenAI 解析保留 provider_specific_fields")
    func testParseResponsePreservesProviderSpecificFields() throws {
        let json = """
        {
          "choices": [
            {
              "message": {
                "role": "assistant",
                "content": "",
                "tool_calls": [
                  {
                    "id": "call_1",
                    "type": "function",
                    "function": {
                      "name": "save_memory",
                      "arguments": "{\\"content\\":\\"Hello\\"}"
                    },
                    "provider_specific_fields": {
                      "thought_signature": "opaque-signature",
                      "nested": {
                        "trace_id": "trace-1"
                      }
                    }
                  }
                ]
              }
            }
          ]
        }
        """
        let data = try #require(json.data(using: .utf8))
        let message = try adapter.parseResponse(data: data)
        let call = try #require(message.toolCalls?.first)

        #expect(call.providerSpecificFields?["thought_signature"] == .string("opaque-signature"))
        #expect(call.providerSpecificFields?["nested"] == .dictionary(["trace_id": .string("trace-1")]))
    }

    @Test("OpenAI 请求保留 provider_specific_fields")
    func testBuildRequestIncludesProviderSpecificFields() throws {
        let toolCall = InternalToolCall(
            id: "call_9",
            toolName: "save_memory",
            arguments: #"{"content":"test"}"#,
            providerSpecificFields: [
                "thought_signature": .string("sig-9"),
                "routing": .dictionary([
                    "provider": .string("gemini")
                ])
            ]
        )
        let messages = [
            ChatMessage(role: .assistant, content: "", toolCalls: [toolCall])
        ]

        guard let request = adapter.buildChatRequest(for: dummyModel, commonPayload: [:], messages: messages, tools: nil, audioAttachments: [:], imageAttachments: [:], fileAttachments: [:]),
              let httpBody = request.httpBody,
              let jsonPayload = try? JSONSerialization.jsonObject(with: httpBody) as? [String: Any],
              let payloadMessages = jsonPayload["messages"] as? [[String: Any]],
              let firstMessage = payloadMessages.first,
              let payloadToolCalls = firstMessage["tool_calls"] as? [[String: Any]],
              let firstToolCall = payloadToolCalls.first,
              let providerFields = firstToolCall["provider_specific_fields"] as? [String: Any],
              let thoughtSignature = providerFields["thought_signature"] as? String,
              let routing = providerFields["routing"] as? [String: Any],
              let provider = routing["provider"] as? String else {
            Issue.record("请求体中未找到 provider_specific_fields。")
            return
        }

        #expect(thoughtSignature == "sig-9")
        #expect(provider == "gemini")
    }

    @Test("OpenAI 解析 Gemini extra_content 中的 thought_signature")
    func testParseResponsePreservesGeminiExtraContentThoughtSignature() throws {
        let json = """
        {
          "choices": [
            {
              "message": {
                "role": "assistant",
                "content": "",
                "tool_calls": [
                  {
                    "id": "call_extra_1",
                    "type": "function",
                    "function": {
                      "name": "save_memory",
                      "arguments": "{\\"content\\":\\"Hello\\"}"
                    },
                    "extra_content": {
                      "google": {
                        "thought_signature": "sig-extra-1"
                      }
                    }
                  }
                ]
              }
            }
          ]
        }
        """
        let data = try #require(json.data(using: .utf8))
        let message = try adapter.parseResponse(data: data)
        let call = try #require(message.toolCalls?.first)
        #expect(call.id == "call_extra_1")
        #expect(call.providerSpecificFields?["thought_signature"] == .string("sig-extra-1"))
    }

    @Test("OpenAI 请求会镜像 thought_signature 到 Gemini extra_content")
    func testBuildRequestIncludesGeminiExtraContentThoughtSignature() throws {
        let toolCall = InternalToolCall(
            id: "call_gemini_sig_1",
            toolName: "save_memory",
            arguments: #"{"content":"test"}"#,
            providerSpecificFields: [
                "thought_signature": .string("sig-gemini-1")
            ]
        )
        let messages = [ChatMessage(role: .assistant, content: "", toolCalls: [toolCall])]

        guard let request = adapter.buildChatRequest(for: dummyModel, commonPayload: [:], messages: messages, tools: nil, audioAttachments: [:], imageAttachments: [:], fileAttachments: [:]),
              let httpBody = request.httpBody,
              let jsonPayload = try? JSONSerialization.jsonObject(with: httpBody) as? [String: Any],
              let payloadMessages = jsonPayload["messages"] as? [[String: Any]],
              let firstMessage = payloadMessages.first,
              let payloadToolCalls = firstMessage["tool_calls"] as? [[String: Any]],
              let firstToolCall = payloadToolCalls.first,
              let extraContent = firstToolCall["extra_content"] as? [String: Any],
              let googleExtra = extraContent["google"] as? [String: Any],
              let thoughtSignature = googleExtra["thought_signature"] as? String else {
            Issue.record("请求体中未找到 Gemini extra_content.thought_signature。")
            return
        }

        #expect(thoughtSignature == "sig-gemini-1")
    }

    @Test("OpenAI 流式增量保留 provider_specific_fields")
    func testStreamingDeltaPreservesProviderSpecificFields() throws {
        let line = """
        data: {"choices":[{"delta":{"tool_calls":[{"id":"call_stream_1","index":0,"type":"function","function":{"name":"save_memory","arguments":"{}"},"provider_specific_fields":{"thought_signature":"sig-stream"}}]}}]}
        """
        let part = adapter.parseStreamingResponse(line: line)
        let firstDelta = try #require(part?.toolCallDeltas?.first)
        #expect(firstDelta.providerSpecificFields?["thought_signature"] == .string("sig-stream"))
    }

    @Test("OpenAI 流式增量解析 Gemini extra_content")
    func testStreamingDeltaPreservesGeminiExtraContentThoughtSignature() throws {
        let line = """
        data: {"choices":[{"delta":{"tool_calls":[{"id":"call_stream_2","index":0,"type":"function","function":{"name":"save_memory","arguments":"{}"},"extra_content":{"google":{"thought_signature":"sig-stream-extra"}}}]}}]}
        """
        let part = adapter.parseStreamingResponse(line: line)
        let firstDelta = try #require(part?.toolCallDeltas?.first)
        #expect(firstDelta.providerSpecificFields?["thought_signature"] == .string("sig-stream-extra"))
    }

    @Test("OpenAI 流式 usage-only 片段可解析 token 用量")
    func testStreamingUsageOnlyChunkParsesTokenUsage() throws {
        let line = """
        data: {"id":"chatcmpl-usage","object":"chat.completion.chunk","choices":[],"usage":{"prompt_tokens":11,"completion_tokens":29,"total_tokens":40}}
        """
        let part = try #require(adapter.parseStreamingResponse(line: line))
        let usage = try #require(part.tokenUsage)
        #expect(usage.promptTokens == 11)
        #expect(usage.completionTokens == 29)
        #expect(usage.totalTokens == 40)
        #expect(part.content == nil)
        #expect(part.reasoningContent == nil)
    }

    @Test("OpenAI 流式请求默认附带 include_usage")
    func testStreamingRequestIncludesUsageByDefault() throws {
        let messages = [ChatMessage(role: .user, content: "你好")]
        guard let request = adapter.buildChatRequest(
            for: dummyModel,
            commonPayload: ["stream": true],
            messages: messages,
            tools: nil,
            audioAttachments: [:],
            imageAttachments: [:],
            fileAttachments: [:]
        ),
        let httpBody = request.httpBody,
        let jsonPayload = try? JSONSerialization.jsonObject(with: httpBody) as? [String: Any],
        let streamOptions = jsonPayload["stream_options"] as? [String: Any] else {
            Issue.record("流式请求体缺少 stream_options。")
            return
        }

        #expect(streamOptions["include_usage"] as? Bool == true)
    }

    @Test("OpenAI 流式请求可关闭 include_usage")
    func testStreamingRequestCanDisableIncludeUsage() throws {
        let messages = [ChatMessage(role: .user, content: "你好")]
        guard let request = adapter.buildChatRequest(
            for: dummyModel,
            commonPayload: [
                "stream": true,
                OpenAIAdapter.streamIncludeUsageControlKey: false
            ],
            messages: messages,
            tools: nil,
            audioAttachments: [:],
            imageAttachments: [:],
            fileAttachments: [:]
        ),
        let httpBody = request.httpBody,
        let jsonPayload = try? JSONSerialization.jsonObject(with: httpBody) as? [String: Any] else {
            Issue.record("无法解析请求体。")
            return
        }

        #expect(jsonPayload["stream_options"] == nil)
        #expect(jsonPayload[OpenAIAdapter.streamIncludeUsageControlKey] == nil)
    }

    @Test("OpenAI 可切换为 Responses API 请求体")
    func testBuildResponsesAPIRequestPayload() throws {
        let responseModel = RunnableModel(
            provider: dummyModel.provider,
            model: Model(
                modelName: "gpt-5.4",
                overrideParameters: [
                    "openai_api": .string("responses"),
                    "max_tokens": .int(256),
                    "reasoning": .dictionary([
                        "effort": .string("medium")
                    ])
                ]
            )
        )
        let toolResultMessage = ChatMessage(
            role: .tool,
            content: "{\"saved\":true}",
            toolCalls: [
                InternalToolCall(
                    id: "call_save_1",
                    toolName: "save_memory",
                    arguments: "{}"
                )
            ]
        )
        let messages = [
            ChatMessage(role: .user, content: "你好"),
            ChatMessage(
                role: .assistant,
                content: "",
                toolCalls: [
                    InternalToolCall(
                        id: "call_save_1",
                        toolName: "save_memory",
                        arguments: "{\"content\":\"你好\"}"
                    )
                ]
            ),
            toolResultMessage
        ]
        let tools = [saveMemoryTool]

        guard let request = adapter.buildChatRequest(
            for: responseModel,
            commonPayload: ["stream": true],
            messages: messages,
            tools: tools,
            audioAttachments: [:],
            imageAttachments: [:],
            fileAttachments: [:]
        ),
        let httpBody = request.httpBody,
        let jsonPayload = try? JSONSerialization.jsonObject(with: httpBody) as? [String: Any],
        let inputItems = jsonPayload["input"] as? [[String: Any]],
        let toolPayloads = jsonPayload["tools"] as? [[String: Any]],
        let firstInput = inputItems.first,
        let functionCallInput = inputItems.dropFirst().first(where: { ($0["type"] as? String) == "function_call" }),
        let functionOutputInput = inputItems.first(where: { ($0["type"] as? String) == "function_call_output" }),
        let firstTool = toolPayloads.first else {
            Issue.record("Responses API 请求体未正确生成。")
            return
        }

        #expect(request.url?.absoluteString == "https://api.test.com/v1/responses")
        #expect(jsonPayload["messages"] == nil)
        #expect(jsonPayload["max_tokens"] == nil)
        #expect(jsonPayload["max_output_tokens"] as? Int == 256)
        #expect(jsonPayload["stream"] as? Bool == true)
        #expect((jsonPayload["reasoning"] as? [String: Any])?["effort"] as? String == "medium")

        #expect(firstInput["role"] as? String == "user")
        if let textContent = firstInput["content"] as? String {
            #expect(textContent == "你好")
        } else {
            #expect(((firstInput["content"] as? [[String: Any]])?.first)?["type"] as? String == "input_text")
        }
        #expect(functionCallInput["call_id"] as? String == "call_save_1")
        #expect(functionCallInput["name"] as? String == "save_memory")
        #expect(functionOutputInput["call_id"] as? String == "call_save_1")
        #expect(functionOutputInput["output"] as? String == "{\"saved\":true}")

        #expect(firstTool["type"] as? String == "function")
        #expect(firstTool["name"] as? String == "save_memory")
        #expect(firstTool["strict"] as? Bool == false)
    }

    @Test("OpenAI Responses 响应可解析正文、推理与工具调用")
    func testParseResponsesAPIResponse() throws {
        let json = """
        {
          "id": "resp_123",
          "object": "response",
          "output": [
            {
              "type": "reasoning",
              "summary": [
                {
                  "type": "summary_text",
                  "text": "先检查记忆是否已有相同信息。"
                }
              ]
            },
            {
              "type": "function_call",
              "call_id": "call_resp_1",
              "name": "save_memory",
              "arguments": "{\\"content\\":\\"你好\\"}"
            },
            {
              "type": "message",
              "role": "assistant",
              "content": [
                {
                  "type": "output_text",
                  "text": "已经帮你记住啦。"
                }
              ]
            }
          ],
          "usage": {
            "input_tokens": 12,
            "output_tokens": 18,
            "output_tokens_details": {
              "reasoning_tokens": 5
            },
            "total_tokens": 30
          }
        }
        """
        let data = try #require(json.data(using: .utf8))
        let message = try adapter.parseResponse(data: data)
        let toolCall = try #require(message.toolCalls?.first)
        let usage = try #require(message.tokenUsage)

        #expect(message.content == "已经帮你记住啦。")
        #expect(message.reasoningContent == "先检查记忆是否已有相同信息。")
        #expect(toolCall.id == "call_resp_1")
        #expect(toolCall.toolName == "save_memory")
        #expect(toolCall.arguments == "{\"content\":\"你好\"}")
        #expect(usage.promptTokens == 12)
        #expect(usage.completionTokens == 18)
        #expect(usage.thinkingTokens == 5)
        #expect(usage.totalTokens == 30)
    }

    @Test("OpenAI Responses 流式事件可解析文本、工具参数与用量")
    func testParseResponsesStreamingEvents() throws {
        let toolStart = """
        data: {"type":"response.output_item.added","output_index":1,"item":{"type":"function_call","call_id":"call_stream_1","name":"save_memory","arguments":""}}
        """
        let toolDelta = """
        data: {"type":"response.function_call_arguments.delta","output_index":1,"item_id":"fc_1","call_id":"call_stream_1","delta":"{\\"content\\":\\"你好\\"}"}
        """
        let textDelta = """
        data: {"type":"response.output_text.delta","output_index":2,"item_id":"msg_1","content_index":0,"delta":"已经完成"}
        """
        let completed = """
        data: {"type":"response.completed","response":{"usage":{"input_tokens":9,"output_tokens":7,"output_tokens_details":{"reasoning_tokens":2},"total_tokens":16}}}
        """

        let toolStartPart = try #require(adapter.parseStreamingResponse(line: toolStart))
        let toolDeltaPart = try #require(adapter.parseStreamingResponse(line: toolDelta))
        let textPart = try #require(adapter.parseStreamingResponse(line: textDelta))
        let completedPart = try #require(adapter.parseStreamingResponse(line: completed))

        let startedTool = try #require(toolStartPart.toolCallDeltas?.first)
        let toolArguments = try #require(toolDeltaPart.toolCallDeltas?.first)
        let usage = try #require(completedPart.tokenUsage)

        #expect(startedTool.id == "call_stream_1")
        #expect(startedTool.nameFragment == "save_memory")
        #expect(toolArguments.argumentsFragment == "{\"content\":\"你好\"}")
        #expect(textPart.content == "已经完成")
        #expect(usage.promptTokens == 9)
        #expect(usage.completionTokens == 7)
        #expect(usage.thinkingTokens == 2)
        #expect(usage.totalTokens == 16)
    }

    @Test("OpenAI 生图无参考图时走 generations 端点")
    func testOpenAIImageGenerationRequestUsesGenerationsEndpointWhenNoReferenceImages() throws {
        let request = try #require(
            adapter.buildImageGenerationRequest(
                for: dummyModel,
                prompt: "一只戴墨镜的猫",
                referenceImages: []
            )
        )
        let httpBody = try #require(request.httpBody)
        let payload = try #require(JSONSerialization.jsonObject(with: httpBody) as? [String: Any])

        #expect(request.url?.absoluteString == "https://api.test.com/v1/images/generations")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(payload["model"] as? String == "test-model")
        #expect(payload["prompt"] as? String == "一只戴墨镜的猫")
        #expect(payload["n"] as? Int == 1)
        #expect(payload["response_format"] as? String == "b64_json")
    }

    @Test("OpenAI 生图有参考图时走 edits 端点")
    func testOpenAIImageGenerationRequestUsesEditsEndpointWhenReferenceImagesExist() throws {
        let referenceImage = ImageAttachment(
            data: Data([0x89, 0x50, 0x4E, 0x47]),
            mimeType: "image/png",
            fileName: "ref.png"
        )
        let request = try #require(
            adapter.buildImageGenerationRequest(
                for: dummyModel,
                prompt: "把它改成赛博朋克风格",
                referenceImages: [referenceImage]
            )
        )
        let contentType = try #require(request.value(forHTTPHeaderField: "Content-Type"))
        let bodyData = try #require(request.httpBody)
        let bodyString = String(data: bodyData, encoding: .utf8) ?? ""

        #expect(request.url?.absoluteString == "https://api.test.com/v1/images/edits")
        #expect(request.httpMethod == "POST")
        #expect(contentType.contains("multipart/form-data; boundary="))
        #expect(bodyString.contains("name=\"model\""))
        #expect(bodyString.contains("name=\"prompt\""))
        #expect(bodyString.contains("name=\"image\""))
        #expect(bodyString.contains("filename=\"ref.png\""))
    }
}

@Suite("GeminiAdapter Tests")
struct GeminiAdapterTests {

    private let adapter = GeminiAdapter()
    private let dummyModel = RunnableModel(
        provider: Provider(
            id: UUID(),
            name: "Gemini Test Provider",
            baseURL: "https://generativelanguage.googleapis.com/v1beta",
            apiKeys: ["test-key"],
            apiFormat: "gemini"
        ),
        model: Model(modelName: "gemini-2.5-pro")
    )

    @Test("Gemini 工具 schema 缺失 type 时自动补全")
    func testGeminiToolSchemaTypeInferenceForEnumField() throws {
        let tools = [
            InternalToolDefinition(
                name: "tavily_search",
                description: "搜索网络内容",
                parameters: .dictionary([
                    "type": .string("object"),
                    "properties": .dictionary([
                        "query": .dictionary([
                            "type": .string("string")
                        ]),
                        "time_range": .dictionary([
                            "description": .string("可选时间范围"),
                            "enum": .array([
                                .string("day"),
                                .string("week"),
                                .string("month")
                            ])
                        ]),
                        "filters": .dictionary([
                            "properties": .dictionary([
                                "safe": .dictionary([
                                    "type": .string("boolean")
                                ])
                            ])
                        ])
                    ]),
                    "required": .array([.string("query")])
                ])
            )
        ]
        let messages = [ChatMessage(role: .user, content: "测试一下")]

        guard let request = adapter.buildChatRequest(
            for: dummyModel,
            commonPayload: [:],
            messages: messages,
            tools: tools,
            audioAttachments: [:],
            imageAttachments: [:],
            fileAttachments: [:]
        ),
        let httpBody = request.httpBody,
        let jsonPayload = try? JSONSerialization.jsonObject(with: httpBody) as? [String: Any],
        let toolsPayload = jsonPayload["tools"] as? [[String: Any]],
        let firstToolGroup = toolsPayload.first,
        let declarations = firstToolGroup["function_declarations"] as? [[String: Any]],
        let firstDeclaration = declarations.first,
        let parameters = firstDeclaration["parameters"] as? [String: Any],
        let properties = parameters["properties"] as? [String: Any],
        let timeRangeSchema = properties["time_range"] as? [String: Any],
        let filtersSchema = properties["filters"] as? [String: Any] else {
            Issue.record("Gemini 请求体中未找到工具参数 schema。")
            return
        }

        #expect(timeRangeSchema["type"] as? String == "string")
        #expect(filtersSchema["type"] as? String == "object")
    }

    @Test("Gemini 工具 schema 组合类型和叶子节点兜底补全")
    func testGeminiSchemaTypeInferenceForCombinatorAndLeafFallback() throws {
        let tools = [
            InternalToolDefinition(
                name: "tavily_search",
                description: "搜索网络内容",
                parameters: .dictionary([
                    "type": .string("object"),
                    "properties": .dictionary([
                        "time_range": .dictionary([
                            "description": .string("时间范围"),
                            "anyOf": .array([
                                .dictionary([
                                    "enum": .array([.string("day"), .string("week"), .string("month")])
                                ]),
                                .dictionary([
                                    "type": .array([.string("null"), .string("string")])
                                ])
                            ])
                        ]),
                        "locale": .dictionary([
                            "description": .string("地区代码"),
                            "default": .string("en")
                        ])
                    ])
                ])
            )
        ]
        let messages = [ChatMessage(role: .user, content: "测试一下")]

        guard let request = adapter.buildChatRequest(
            for: dummyModel,
            commonPayload: [:],
            messages: messages,
            tools: tools,
            audioAttachments: [:],
            imageAttachments: [:],
            fileAttachments: [:]
        ),
        let httpBody = request.httpBody,
        let jsonPayload = try? JSONSerialization.jsonObject(with: httpBody) as? [String: Any],
        let toolsPayload = jsonPayload["tools"] as? [[String: Any]],
        let firstToolGroup = toolsPayload.first,
        let declarations = firstToolGroup["function_declarations"] as? [[String: Any]],
        let firstDeclaration = declarations.first,
        let parameters = firstDeclaration["parameters"] as? [String: Any],
        let properties = parameters["properties"] as? [String: Any],
        let timeRangeSchema = properties["time_range"] as? [String: Any],
        let localeSchema = properties["locale"] as? [String: Any] else {
            Issue.record("Gemini 请求体中未找到组合类型 schema。")
            return
        }

        #expect(timeRangeSchema["type"] as? String == "string")
        #expect(localeSchema["type"] as? String == "string")
    }

    @Test("Gemini 工具 schema 的 anyOf 会扁平化并移除 default:null")
    func testGeminiSchemaFlattensAnyOfAndDropsNullDefault() throws {
        let tools = [
            InternalToolDefinition(
                name: "tavily_search",
                description: "搜索网络内容",
                parameters: .dictionary([
                    "type": .string("object"),
                    "properties": .dictionary([
                        "time_range": .dictionary([
                            "default": .null,
                            "anyOf": .array([
                                .dictionary([
                                    "type": .string("string"),
                                    "enum": .array([
                                        .string("day"),
                                        .string("week"),
                                        .string("month"),
                                        .string("year")
                                    ])
                                ]),
                                .dictionary([:])
                            ]),
                            "description": .string("可选时间范围")
                        ])
                    ])
                ])
            )
        ]
        let messages = [ChatMessage(role: .user, content: "测试一下")]

        guard let request = adapter.buildChatRequest(
            for: dummyModel,
            commonPayload: [:],
            messages: messages,
            tools: tools,
            audioAttachments: [:],
            imageAttachments: [:],
            fileAttachments: [:]
        ),
        let httpBody = request.httpBody,
        let jsonPayload = try? JSONSerialization.jsonObject(with: httpBody) as? [String: Any],
        let toolsPayload = jsonPayload["tools"] as? [[String: Any]],
        let firstToolGroup = toolsPayload.first,
        let declarations = firstToolGroup["function_declarations"] as? [[String: Any]],
        let firstDeclaration = declarations.first,
        let parameters = firstDeclaration["parameters"] as? [String: Any],
        let properties = parameters["properties"] as? [String: Any],
        let timeRangeSchema = properties["time_range"] as? [String: Any] else {
            Issue.record("Gemini 请求体中未找到 time_range schema。")
            return
        }

        #expect(timeRangeSchema["type"] as? String == "string")
        #expect(timeRangeSchema["anyOf"] == nil)
        #expect(timeRangeSchema["oneOf"] == nil)
        #expect(timeRangeSchema["allOf"] == nil)
        #expect(timeRangeSchema["default"] == nil)
    }

    @Test("Gemini 工具 schema 的 properties 允许字符串简写并自动包装为对象")
    func testGeminiPropertiesStringShorthandSchemaGetsWrapped() throws {
        let tools = [
            InternalToolDefinition(
                name: "tavily_extract",
                description: "提取网页内容",
                parameters: .dictionary([
                    "type": .string("object"),
                    "properties": .dictionary([
                        "urls": .dictionary([
                            "type": .string("array"),
                            "items": .dictionary([
                                "type": .string("string")
                            ])
                        ]),
                        "type": .string("string"),
                        "format": .dictionary([
                            "type": .string("string"),
                            "enum": .array([.string("markdown"), .string("text")]),
                            "default": .string("markdown")
                        ])
                    ]),
                    "required": .array([.string("urls")])
                ])
            )
        ]
        let messages = [ChatMessage(role: .user, content: "测试一下")]

        guard let request = adapter.buildChatRequest(
            for: dummyModel,
            commonPayload: [:],
            messages: messages,
            tools: tools,
            audioAttachments: [:],
            imageAttachments: [:],
            fileAttachments: [:]
        ),
        let httpBody = request.httpBody,
        let jsonPayload = try? JSONSerialization.jsonObject(with: httpBody) as? [String: Any],
        let toolsPayload = jsonPayload["tools"] as? [[String: Any]],
        let firstToolGroup = toolsPayload.first,
        let declarations = firstToolGroup["function_declarations"] as? [[String: Any]],
        let firstDeclaration = declarations.first,
        let parameters = firstDeclaration["parameters"] as? [String: Any],
        let properties = parameters["properties"] as? [String: Any],
        let typeSchema = properties["type"] as? [String: Any] else {
            Issue.record("Gemini 请求体中未找到 properties.type 的对象化 schema。")
            return
        }

        #expect(typeSchema["type"] as? String == "string")
        #expect(!(properties["type"] is String))
    }

    @Test("Gemini 工具 schema 会移除 Gemini 不支持的 JSON Schema 关键字")
    func testGeminiSchemaDropsUnsupportedJSONSchemaKeywords() throws {
        let tools = [
            InternalToolDefinition(
                name: "example_tool",
                description: "测试 Gemini schema 清洗",
                parameters: .dictionary([
                    "$schema": .string("https://json-schema.org/draft/2020-12/schema"),
                    "type": .string("object"),
                    "additionalProperties": .bool(false),
                    "properties": .dictionary([
                        "mode": .dictionary([
                            "const": .string("strict"),
                            "description": .string("固定模式")
                        ]),
                        "metadata": .dictionary([
                            "type": .string("object"),
                            "additionalProperties": .dictionary([
                                "type": .string("string")
                            ])
                        ])
                    ]),
                    "required": .array([.string("mode")])
                ])
            )
        ]
        let messages = [ChatMessage(role: .user, content: "测试一下")]

        guard let request = adapter.buildChatRequest(
            for: dummyModel,
            commonPayload: [:],
            messages: messages,
            tools: tools,
            audioAttachments: [:],
            imageAttachments: [:],
            fileAttachments: [:]
        ),
        let httpBody = request.httpBody,
        let jsonPayload = try? JSONSerialization.jsonObject(with: httpBody) as? [String: Any],
        let toolsPayload = jsonPayload["tools"] as? [[String: Any]],
        let firstToolGroup = toolsPayload.first,
        let declarations = firstToolGroup["function_declarations"] as? [[String: Any]],
        let firstDeclaration = declarations.first,
        let parameters = firstDeclaration["parameters"] as? [String: Any],
        let properties = parameters["properties"] as? [String: Any],
        let modeSchema = properties["mode"] as? [String: Any],
        let metadataSchema = properties["metadata"] as? [String: Any] else {
            Issue.record("Gemini 请求体中未找到清洗后的 schema。")
            return
        }

        #expect(parameters["$schema"] == nil)
        #expect(parameters["additionalProperties"] == nil)
        #expect(modeSchema["const"] == nil)
        #expect(modeSchema["type"] as? String == "string")
        #expect((modeSchema["enum"] as? [String]) == ["strict"])
        #expect(metadataSchema["additionalProperties"] == nil)
        #expect(metadataSchema["type"] as? String == "object")
    }

    @Test("Gemini 响应可解析思考 Token 字段")
    func testGeminiResponseParsesThinkingTokens() throws {
        let payload = """
        {
          "candidates": [
            {
              "content": {
                "parts": [
                  { "text": "你好" }
                ]
              }
            }
          ],
          "usageMetadata": {
            "promptTokenCount": 12,
            "candidatesTokenCount": 34,
            "totalTokenCount": 46,
            "thoughtsTokenCount": 7
          }
        }
        """

        let data = Data(payload.utf8)
        let message = try adapter.parseResponse(data: data)
        let usage = try #require(message.tokenUsage)
        #expect(usage.promptTokens == 12)
        #expect(usage.completionTokens == 34)
        #expect(usage.totalTokens == 46)
        #expect(usage.thinkingTokens == 7)
    }

    @Test("Gemini 响应解析保留函数调用 ID 与 thought_signature")
    func testGeminiResponsePreservesCallIDAndThoughtSignature() throws {
        let payload = """
        {
          "candidates": [
            {
              "content": {
                "parts": [
                  {
                    "functionCall": {
                      "id": "function-call-123",
                      "name": "shortcut_weather",
                      "args": {
                        "city": "上海"
                      }
                    },
                    "thoughtSignature": "sig-123"
                  }
                ]
              }
            }
          ]
        }
        """

        let message = try adapter.parseResponse(data: Data(payload.utf8))
        let call = try #require(message.toolCalls?.first)
        #expect(call.id == "function-call-123")
        #expect(call.toolName == "shortcut_weather")
        #expect(call.arguments == #"{"city":"上海"}"#)
        #expect(call.providerSpecificFields?["thought_signature"] == .string("sig-123"))
    }

    @Test("Gemini 请求体保留 thought_signature 并透传 function id")
    func testGeminiBuildRequestPreservesThoughtSignatureAndCallID() throws {
        let assistantCall = InternalToolCall(
            id: "function-call-456",
            toolName: "shortcut_weather",
            arguments: #"{"city":"上海"}"#,
            providerSpecificFields: [
                "thought_signature": .string("sig-456")
            ]
        )
        let toolResultCall = InternalToolCall(
            id: "function-call-456",
            toolName: "shortcut_weather",
            arguments: #"{"city":"上海"}"#
        )
        let messages = [
            ChatMessage(role: .user, content: "帮我查天气"),
            ChatMessage(role: .assistant, content: "", toolCalls: [assistantCall]),
            ChatMessage(role: .tool, content: #"{"temp":"24C"}"#, toolCalls: [toolResultCall])
        ]

        guard let request = adapter.buildChatRequest(
            for: dummyModel,
            commonPayload: [:],
            messages: messages,
            tools: nil,
            audioAttachments: [:],
            imageAttachments: [:],
            fileAttachments: [:]
        ),
        let httpBody = request.httpBody,
        let jsonPayload = try? JSONSerialization.jsonObject(with: httpBody) as? [String: Any],
        let contents = jsonPayload["contents"] as? [[String: Any]],
        contents.count == 3 else {
            Issue.record("Gemini 请求体未正确包含 contents。")
            return
        }

        let assistantPayload = contents[1]
        let toolPayload = contents[2]

        guard let assistantParts = assistantPayload["parts"] as? [[String: Any]],
        let firstAssistantPart = assistantParts.first,
        let functionCall = firstAssistantPart["functionCall"] as? [String: Any],
        let callID = functionCall["id"] as? String,
        let thoughtSignature = firstAssistantPart["thought_signature"] as? String,
        let toolParts = toolPayload["parts"] as? [[String: Any]],
        let firstToolPart = toolParts.first,
        let functionResponse = firstToolPart["functionResponse"] as? [String: Any],
        let functionResponseID = functionResponse["id"] as? String else {
            Issue.record("Gemini 请求体未正确包含 function id 或 thought_signature。")
            return
        }

        #expect(callID == "function-call-456")
        #expect(thoughtSignature == "sig-456")
        #expect(toolPayload["role"] as? String == "user")
        #expect(functionResponseID == "function-call-456")
    }

    @Test("Gemini 流式增量保留 thought_signature")
    func testGeminiStreamingDeltaPreservesThoughtSignature() throws {
        let line = """
        data: {"candidates":[{"content":{"parts":[{"functionCall":{"id":"function-call-stream","name":"shortcut_weather","args":{"city":"上海"}},"thoughtSignature":"sig-stream"}]}}]}
        """

        let part = adapter.parseStreamingResponse(line: line)
        let delta = try #require(part?.toolCallDeltas?.first)
        #expect(delta.id == "function-call-stream")
        #expect(delta.nameFragment == "shortcut_weather")
        #expect(delta.providerSpecificFields?["thought_signature"] == .string("sig-stream"))
    }

    @Test("Gemini 文生图请求走 generateContent 端点并带 key 参数")
    func testGeminiImageGenerationRequestUsesGenerateContentEndpoint() throws {
        let request = try #require(
            adapter.buildImageGenerationRequest(
                for: dummyModel,
                prompt: "画一只宇航员猫",
                referenceImages: []
            )
        )
        let payloadData = try #require(request.httpBody)
        let payload = try #require(JSONSerialization.jsonObject(with: payloadData) as? [String: Any])
        let contents = try #require(payload["contents"] as? [[String: Any]])
        let parts = try #require(contents.first?["parts"] as? [[String: Any]])

        #expect(request.url?.absoluteString.contains("/models/gemini-2.5-pro:generateContent") == true)
        #expect(request.url?.query?.contains("key=test-key") == true)
        #expect(parts.count == 1)
        #expect(parts.first?["text"] as? String == "画一只宇航员猫")
    }

    @Test("Gemini 图生图请求会先发送 inline_data 再发送文本指令")
    func testGeminiImageEditRequestPlacesReferenceImagesBeforePromptText() throws {
        let firstImage = ImageAttachment(
            data: Data([0x89, 0x50, 0x4E, 0x47]),
            mimeType: "image/png",
            fileName: "first.png"
        )
        let secondImage = ImageAttachment(
            data: Data([0xFF, 0xD8, 0xFF, 0xE0]),
            mimeType: "image/jpeg",
            fileName: "second.jpg"
        )
        let request = try #require(
            adapter.buildImageGenerationRequest(
                for: dummyModel,
                prompt: "把第一张图的风格应用到第二张图",
                referenceImages: [firstImage, secondImage]
            )
        )
        let payloadData = try #require(request.httpBody)
        let payload = try #require(JSONSerialization.jsonObject(with: payloadData) as? [String: Any])
        let contents = try #require(payload["contents"] as? [[String: Any]])
        let parts = try #require(contents.first?["parts"] as? [[String: Any]])

        #expect(parts.count == 3)
        #expect(parts[0]["inline_data"] != nil)
        #expect(parts[1]["inline_data"] != nil)
        #expect(parts[2]["text"] as? String == "把第一张图的风格应用到第二张图")
    }
}

@Suite("AnthropicAdapter Tests")
struct AnthropicAdapterTests {
    private let adapter = AnthropicAdapter()

    @Test("Anthropic 响应可解析缓存 Token 字段")
    func testAnthropicResponseParsesCacheTokens() throws {
        let payload = """
        {
          "content": [
            { "type": "text", "text": "done" }
          ],
          "usage": {
            "input_tokens": 20,
            "output_tokens": 8,
            "cache_creation_input_tokens": 3,
            "cache_read_input_tokens": 5
          }
        }
        """

        let data = Data(payload.utf8)
        let message = try adapter.parseResponse(data: data)
        let usage = try #require(message.tokenUsage)
        #expect(usage.promptTokens == 20)
        #expect(usage.completionTokens == 8)
        #expect(usage.cacheWriteTokens == 3)
        #expect(usage.cacheReadTokens == 5)
        #expect(usage.totalTokens == nil)
    }
}

// MARK: - ChatService Integration Tests

/// 用于测试的模拟 API 适配器
fileprivate class MockAPIAdapter: APIAdapter {
    var receivedMessages: [ChatMessage]?
    var receivedTitleMessages: [ChatMessage]?
    var receivedTools: [InternalToolDefinition]?
    var responseToReturn: ChatMessage?
    var receivedChatModel: RunnableModel?
    var receivedTitleModel: RunnableModel?
    
    func buildChatRequest(for model: RunnableModel, commonPayload: [String : Any], messages: [ChatMessage], tools: [InternalToolDefinition]?, audioAttachments: [UUID: AudioAttachment], imageAttachments: [UUID: [ImageAttachment]], fileAttachments: [UUID: [FileAttachment]]) -> URLRequest? {
        // 根据请求内容返回不同 URL，以便 MockURLProtocol 能够区分它们
        if messages.first?.content.contains("为本次对话生成一个简短、精炼的标题") == true {
            self.receivedTitleMessages = messages
            self.receivedTitleModel = model
            return URLRequest(url: URL(string: "https://fake.url/title-gen")!)
        } else {
            self.receivedMessages = messages
            self.receivedTools = tools
            self.receivedChatModel = model
            return URLRequest(url: URL(string: "https://fake.url/chat")!)
        }
    }
    
    func parseResponse(data: Data) throws -> ChatMessage {
        if let response = try? JSONDecoder().decode(OpenAIResponse.self, from: data),
           let content = response.choices.first?.message.content {
            return ChatMessage(role: .assistant, content: content)
        }

        // 对于标题生成，我们需要真实地解析返回的数据
        if let received = receivedMessages, received.first?.content.contains("为本次对话生成一个简短、精炼的标题") == true {
            let response = try JSONDecoder().decode(OpenAIResponse.self, from: data)
            let content = response.choices.first?.message.content ?? ""
            return ChatMessage(role: .assistant, content: content)
        }
        // 对于普通聊天，返回预设的响应
        return responseToReturn ?? ChatMessage(role: .assistant, content: "Default mock response")
    }
    
    func buildModelListRequest(for provider: Provider) -> URLRequest? { return nil }
    func parseStreamingResponse(line: String) -> ChatMessagePart? { return nil }
}

// 临时的 OpenAIResponse 结构，仅用于在测试中解码模拟数据
fileprivate struct OpenAIResponse: Codable {
    struct Choice: Codable {
        struct Message: Codable {
            let content: String?
        }
        let message: Message
    }
    let choices: [Choice]
}

@Suite("ChatService Integration Tests")
fileprivate struct ChatServiceTests {
    
    // 在所有测试之间共享的变量
    var memoryManager: MemoryManager!
    var mockAdapter: MockAPIAdapter! 
    var chatService: ChatService! 
    var dummyModel: RunnableModel! 

    // swift-testing 的初始化方法，在每个测试运行前被调用
    init() async {
        for provider in ConfigLoader.loadProviders() {
            ConfigLoader.deleteProvider(provider)
        }
        let seededProviders = [
            Provider(
                name: "Chat Service Test Primary",
                baseURL: "https://fake.url",
                apiKeys: ["key-primary"],
                apiFormat: "openai-compatible",
                models: [
                    Model(modelName: "test-model", displayName: "Test Model", isActivated: true)
                ]
            ),
            Provider(
                name: "Chat Service Test Secondary",
                baseURL: "https://fake.url",
                apiKeys: ["key-secondary"],
                apiFormat: "openai-compatible",
                models: [
                    Model(modelName: "title-model", displayName: "Title Model", isActivated: true)
                ]
            )
        ]
        for provider in seededProviders {
            ConfigLoader.saveProvider(provider)
        }
        ShortcutToolStore.saveTools([])
        await MainActor.run {
            ShortcutToolManager.shared.reloadFromDisk()
            ShortcutToolManager.shared.setChatToolsEnabled(false)
        }

        memoryManager = MemoryManager(embeddingGenerator: MemoryManagerTests.MockEmbeddingGenerator())
        await memoryManager.waitForInitialization()
        
        mockAdapter = MockAPIAdapter()

        // --- 新增：设置模拟网络会话 ---
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self] // 使用我们的模拟协议
        let mockSession = URLSession(configuration: config)
        // --- 结束设置 ---

        // 将模拟会话和适配器注入 ChatService
        chatService = ChatService(adapters: ["openai-compatible": mockAdapter], memoryManager: memoryManager, urlSession: mockSession)
        
        dummyModel = RunnableModel(
            provider: seededProviders[0],
            model: seededProviders[0].models[0]
        )
        chatService.setSelectedModel(dummyModel)
    }
    
    // 清理函数
    private func cleanup() async {
        let allMems = await memoryManager.getAllMemories()
        if !allMems.isEmpty {
            await memoryManager.deleteMemories(allMems)
        }
        Persistence.clearRequestLogs()
        UserDefaults.standard.removeObject(forKey: "titleGenerationModelIdentifier")
        // 清理模拟响应，避免测试间互相影响
        MockURLProtocol.mockResponses = [:]
        mockAdapter.receivedMessages = nil
        mockAdapter.receivedTitleMessages = nil
        mockAdapter.receivedTools = nil
        mockAdapter.responseToReturn = nil
        mockAdapter.receivedChatModel = nil
        mockAdapter.receivedTitleModel = nil
        ShortcutToolStore.saveTools([])
        await MainActor.run {
            ShortcutToolManager.shared.reloadFromDisk()
            ShortcutToolManager.shared.setChatToolsEnabled(false)
        }
        // 重置 ChatService 状态
        chatService.createNewSession()
    }

    private func setupMockResponsesForChatAndTitle(title: String = "测试标题") {
        let chatURL = URL(string: "https://fake.url/chat")!
        let titleURL = URL(string: "https://fake.url/title-gen")!
        let chatHTTPResponse = HTTPURLResponse(url: chatURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        let titleHTTPResponse = HTTPURLResponse(url: titleURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        let titleJSON = #"{"choices":[{"message":{"content":"\#(title)"}}]}"#.data(using: .utf8) ?? Data()
        MockURLProtocol.mockResponses[chatURL] = .success((chatHTTPResponse, Data()))
        MockURLProtocol.mockResponses[titleURL] = .success((titleHTTPResponse, titleJSON))
        mockAdapter.responseToReturn = ChatMessage(role: .assistant, content: "聊天回复")
    }

    private func activatedChatModels() -> [RunnableModel] {
        chatService.activatedRunnableModels.filter { $0.model.capabilities.contains(.chat) }
    }

    @Test("Chat request writes independent request log")
    func testChatRequestWritesIndependentRequestLog() async {
        await cleanup()

        setupMockResponsesForChatAndTitle()
        mockAdapter.responseToReturn = ChatMessage(
            role: .assistant,
            content: "日志测试回复",
            tokenUsage: MessageTokenUsage(
                promptTokens: 13,
                completionTokens: 21,
                totalTokens: 34,
                thinkingTokens: 5,
                cacheWriteTokens: nil,
                cacheReadTokens: nil
            )
        )

        await chatService.sendAndProcessMessage(
            content: "请记录这次请求",
            aiTemperature: 0.2,
            aiTopP: 1,
            systemPrompt: "",
            maxChatHistory: 5,
            enableStreaming: false,
            enhancedPrompt: nil,
            enableMemory: false,
            enableMemoryWrite: false,
            includeSystemTime: false
        )

        let logs = Persistence.loadRequestLogs(query: .init(limit: 1))
        #expect(logs.count == 1)
        #expect(logs[0].providerName == dummyModel.provider.name)
        #expect(logs[0].modelID == "test-model")
        #expect(logs[0].status == .success)
        #expect(logs[0].tokenUsage?.promptTokens == 13)
        #expect(logs[0].tokenUsage?.completionTokens == 21)
        #expect(logs[0].tokenUsage?.thinkingTokens == 5)
    }

    @Test("发送消息后会在会话 JSON 中保存请求时间")
    func testSendMessagePersistsRequestedAtInSessionJSON() async {
        await cleanup()

        setupMockResponsesForChatAndTitle()
        let startedAt = Date()

        await chatService.sendAndProcessMessage(
            content: "请记录请求时间",
            aiTemperature: 0.2,
            aiTopP: 1,
            systemPrompt: "",
            maxChatHistory: 5,
            enableStreaming: false,
            enhancedPrompt: nil,
            enableMemory: false,
            enableMemoryWrite: false,
            includeSystemTime: false
        )

        let finishedAt = Date()
        guard let sessionID = chatService.currentSessionSubject.value?.id else {
            Issue.record("当前会话为空，无法验证请求时间落盘。")
            return
        }

        let messages = Persistence.loadMessages(for: sessionID)
        guard let userMessage = messages.first(where: { $0.role == .user }) else {
            Issue.record("未找到用户消息，无法验证请求时间字段。")
            return
        }

        guard let requestedAt = userMessage.requestedAt else {
            Issue.record("用户消息缺少 requestedAt 字段。")
            return
        }
        #expect(requestedAt >= startedAt.addingTimeInterval(-1))
        #expect(requestedAt <= finishedAt.addingTimeInterval(1))
    }

    @Test("Auto-naming handles network error during title generation")
    func testAutoSessionNaming_HandlesNetworkError() async throws {
        await cleanup()

        // 1. 准备 (Arrange)
        let titleURL = URL(string: "https://fake.url/title-gen")!
        let initialSessionName = chatService.currentSessionSubject.value?.name ?? ""

        // 模拟主聊天的响应成功
        mockAdapter.responseToReturn = ChatMessage(role: .assistant, content: "This is the first reply.")

        // 模拟标题生成请求网络失败
        let mockTitleHTTPResponse = HTTPURLResponse(url: titleURL, statusCode: 500, httpVersion: "HTTP/1.1", headerFields: nil)!
        MockURLProtocol.mockResponses[titleURL] = .success((mockTitleHTTPResponse, Data()))

        // 2. 执行 (Act)
        await chatService.sendAndProcessMessage(content: "This is another test", aiTemperature: 0, aiTopP: 1, systemPrompt: "", maxChatHistory: 5, enableStreaming: false, enhancedPrompt: nil, enableMemory: false, enableMemoryWrite: false, includeSystemTime: false)

        // 等待后台的标题生成任务完成（并失败）
        try await Task.sleep(for: .milliseconds(200))

        // 3. 断言 (Assert)
        let finalSession = chatService.currentSessionSubject.value
        let expectedInitialName = "This is another test".prefix(20)

        #expect(finalSession != nil, "当前会话不应为 nil")
        #expect(finalSession?.name == String(expectedInitialName), "当标题生成失败时，会话名称应保持为用户第一条消息的缩略。")
        #expect(finalSession?.name != initialSessionName, "会话名称应该已经从'新的对话'变为消息缩略。")
        
        await cleanup()
    }

    @Test("Auto-naming handles empty title from AI")
    func testAutoSessionNaming_HandlesEmptyTitleResponse() async throws {
        await cleanup()

        // 1. 准备 (Arrange)
        let titleURL = URL(string: "https://fake.url/title-gen")!
        let initialSessionName = chatService.currentSessionSubject.value?.name ?? ""

        // 模拟主聊天的响应 (这是触发自动命名的前置条件)
        mockAdapter.responseToReturn = ChatMessage(role: .assistant, content: "This is the first reply.")

        // 模拟标题生成器的响应：一个包含空内容（""）的有效 JSON
        let mockTitleHTTPResponse = HTTPURLResponse(url: titleURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        let mockTitleData = #"{"choices":[{"message":{"content":""}}]}"# .data(using: .utf8)!
        MockURLProtocol.mockResponses[titleURL] = .success((mockTitleHTTPResponse, mockTitleData))

        // 2. 执行 (Act)
        // 发送第一条消息，这将触发临时会话转正，并调用标题生成逻辑
        await chatService.sendAndProcessMessage(content: "Hello world, this is a test message", aiTemperature: 0, aiTopP: 1, systemPrompt: "", maxChatHistory: 5, enableStreaming: false, enhancedPrompt: nil, enableMemory: false, enableMemoryWrite: false, includeSystemTime: false)

        // 等待后台的标题生成任务完成
        try await Task.sleep(for: .milliseconds(200))

        // 3. 断言 (Assert)
        let finalSession = chatService.currentSessionSubject.value
        let expectedInitialName = "Hello world, this is a test message".prefix(20)

        #expect(finalSession != nil, "当前会话不应为 nil")
        #expect(finalSession?.name == String(expectedInitialName), "当AI返回空标题时，会话名称应保持为用户第一条消息的缩略，而不是变成空字符串。")
        #expect(finalSession?.name != initialSessionName, "会话名称应该已经从'新的对话'变为消息缩略。")
        
        await cleanup()
    }

    @Test("Auto-naming prioritizes dedicated title model when configured")
    func testAutoSessionNaming_UsesDedicatedTitleModel() async throws {
        await cleanup()

        let chatModels = activatedChatModels()
        guard chatModels.count >= 2 else {
            Issue.record("测试环境至少需要 2 个已激活聊天模型。")
            return
        }
        let conversationModel = chatModels[0]
        let dedicatedTitleModel = chatModels[1]
        chatService.setSelectedModel(conversationModel)
        UserDefaults.standard.set(dedicatedTitleModel.id, forKey: "titleGenerationModelIdentifier")

        setupMockResponsesForChatAndTitle(title: "独立标题模型命名")

        await chatService.sendAndProcessMessage(
            content: "请帮我整理一次模型重构方案",
            aiTemperature: 0,
            aiTopP: 1,
            systemPrompt: "",
            maxChatHistory: 5,
            enableStreaming: false,
            enhancedPrompt: nil,
            enableMemory: false,
            enableMemoryWrite: false,
            includeSystemTime: false
        )
        try await Task.sleep(for: .milliseconds(200))

        #expect(mockAdapter.receivedTitleModel?.id == dedicatedTitleModel.id, "标题请求应优先使用独立配置的标题模型。")
        #expect(mockAdapter.receivedTitleModel?.id != conversationModel.id, "标题请求不应继续绑定主对话模型。")

        await cleanup()
    }

    @Test("Auto-naming falls back to selected model when dedicated model is empty")
    func testAutoSessionNaming_FallbackToSelectedModelWhenDedicatedIsEmpty() async throws {
        await cleanup()

        guard let selectedChatModel = activatedChatModels().first else {
            Issue.record("测试环境至少需要 1 个已激活聊天模型。")
            return
        }
        chatService.setSelectedModel(selectedChatModel)
        UserDefaults.standard.removeObject(forKey: "titleGenerationModelIdentifier")

        setupMockResponsesForChatAndTitle(title: "回退到主模型")

        await chatService.sendAndProcessMessage(
            content: "请帮我写一个 SwiftUI 组件",
            aiTemperature: 0,
            aiTopP: 1,
            systemPrompt: "",
            maxChatHistory: 5,
            enableStreaming: false,
            enhancedPrompt: nil,
            enableMemory: false,
            enableMemoryWrite: false,
            includeSystemTime: false
        )
        try await Task.sleep(for: .milliseconds(200))

        #expect(mockAdapter.receivedTitleModel?.id == selectedChatModel.id, "未设置独立标题模型时，应回退到当前对话模型。")

        await cleanup()
    }

    @Test("Auto-naming falls back to selected model when dedicated model is invalid")
    func testAutoSessionNaming_FallbackWhenDedicatedModelInvalid() async throws {
        await cleanup()

        guard let selectedChatModel = activatedChatModels().first else {
            Issue.record("测试环境至少需要 1 个已激活聊天模型。")
            return
        }
        chatService.setSelectedModel(selectedChatModel)
        UserDefaults.standard.set("non-existent-model-id", forKey: "titleGenerationModelIdentifier")

        setupMockResponsesForChatAndTitle(title: "无效配置回退")

        await chatService.sendAndProcessMessage(
            content: "请总结我的待办清单",
            aiTemperature: 0,
            aiTopP: 1,
            systemPrompt: "",
            maxChatHistory: 5,
            enableStreaming: false,
            enhancedPrompt: nil,
            enableMemory: false,
            enableMemoryWrite: false,
            includeSystemTime: false
        )
        try await Task.sleep(for: .milliseconds(200))

        #expect(mockAdapter.receivedTitleModel?.id == selectedChatModel.id, "独立标题模型失效时，应自动回退到当前对话模型。")

        await cleanup()
    }

    @Test("Network error correctly generates an error message")
    func testNetworkError_HandlesCorrectly() async {
        await cleanup()

        // 1. 准备 (Arrange)
        let fakeURL = URL(string: "https://fake.url/chat")!
        // 模拟一个 500 服务器内部错误
        let mockResponse = HTTPURLResponse(url: fakeURL, statusCode: 500, httpVersion: "HTTP/1.1", headerFields: nil)!
        let mockData = "Internal Server Error".data(using: .utf8)!
        
        // 配置 MockURLProtocol，让它在收到特定 URL 请求时返回我们伪造的 500 错误。
        MockURLProtocol.mockResponses[fakeURL] = .success((mockResponse, mockData))

        // 使用 withCheckedContinuation 等待 messagesForSessionSubject 发布我们期望的错误消息
        let receivedMessages = await withCheckedContinuation { continuation in
            var cancellable: AnyCancellable?
            cancellable = chatService.messagesForSessionSubject
                .dropFirst() // 忽略初始的空数组值
                .sink { messages in
                    // 我们期望最终有两条消息：用户的输入消息，以及替代了“加载中”占位符的错误消息。
                    if messages.count == 2 && messages.last?.role == .error {
                        continuation.resume(returning: messages)
                        cancellable?.cancel()
                    }
                }
            
            // 2. 执行 (Act)
            // 这个任务会触发网络请求，该请求将被我们的 MockURLProtocol 拦截。
            Task {
                await chatService.sendAndProcessMessage(content: "test message", aiTemperature: 0, aiTopP: 1, systemPrompt: "", maxChatHistory: 5, enableStreaming: false, enhancedPrompt: nil, enableMemory: false, enableMemoryWrite: false, includeSystemTime: false)
            }
        }
        
        // 3. 断言 (Assert)
        let errorMessage = receivedMessages.last
        #expect(errorMessage?.role == .error, "最后一条消息的角色应该是 .error")
        #expect(errorMessage?.content.contains("HTTP 500") == true, "错误消息内容应包含 HTTP 状态码。")
        #expect(errorMessage?.content.contains("服务器内部错误") == true, "错误消息内容应包含状态说明。")

        await cleanup()
    }

    @Test("Memory prompt is added when memory is enabled")
    func testMemoryPrompt_Enabled() async throws {
        await cleanup()
        await memoryManager.addMemory(content: "The user's cat is named Fluffy.")
        
        await chatService.sendAndProcessMessage(content: "what is my cat's name?", aiTemperature: 0, aiTopP: 1, systemPrompt: "You are a helpful assistant.", maxChatHistory: 5, enableStreaming: false, enhancedPrompt: nil, enableMemory: true, enableMemoryWrite: true, includeSystemTime: false)
        
        let systemMessage = mockAdapter.receivedMessages?.first(where: { $0.role == .system })
        let content = systemMessage?.content ?? ""
        #expect(content.contains("Fluffy"))
        #expect(content.contains("<memory>"))
        #expect(content.contains("长期记忆库"))
        await cleanup()
    }

    @Test("Memory prompt is NOT added when memory is disabled")
    func testMemoryPrompt_Disabled() async throws {
        await cleanup()
        await memoryManager.addMemory(content: "The user's cat is named Fluffy.")
        
        await chatService.sendAndProcessMessage(content: "what is my cat's name?", aiTemperature: 0, aiTopP: 1, systemPrompt: "You are a helpful assistant.", maxChatHistory: 5, enableStreaming: false, enhancedPrompt: nil, enableMemory: false, enableMemoryWrite: false, includeSystemTime: false)
        
        let systemMessage = mockAdapter.receivedMessages?.first(where: { $0.role == .system })
        let content = systemMessage?.content ?? ""
        #expect(!content.contains("Fluffy"))
        #expect(!content.contains("<memory>"))
        #expect(!content.contains("长期记忆库"))
        await cleanup()
    }

    @Test("Topic prompt is added correctly to system message")
    func testTopicPrompt_IsAddedCorrectly() async throws {
        await cleanup()
        
        // 1. Arrange
        let globalPrompt = "这是全局指令。"
        let topicPrompt = "这是一个特定的话题指令。"
        
        // 创建一个带有 topicPrompt 的新会话
        var sessionWithTopic = ChatSession(id: UUID(), name: "Session With Topic")
        sessionWithTopic.topicPrompt = topicPrompt
        
        // 将其设为当前会话
        chatService.setCurrentSession(sessionWithTopic)
        
        // 2. Act
        await chatService.sendAndProcessMessage(
            content: "你好",
            aiTemperature: 0,
            aiTopP: 1,
            systemPrompt: globalPrompt, // 传入全局指令
            maxChatHistory: 5,
            enableStreaming: false,
            enhancedPrompt: nil,
            enableMemory: false, // 关闭记忆以简化测试
            enableMemoryWrite: false,
            includeSystemTime: false
        )
        
        // 3. Assert
        let systemMessage = mockAdapter.receivedMessages?.first(where: { $0.role == .system })
        let content = systemMessage?.content ?? ""
        
        #expect(content.contains(globalPrompt), "System message should contain the global prompt.")
        #expect(content.contains(topicPrompt), "System message should contain the topic prompt.")
        #expect(content.contains("<system_prompt>"), "System message should contain the global prompt tag.")
        #expect(content.contains("<topic_prompt>"), "System message should contain the topic prompt tag.")
        
        await cleanup()
    }

    @Test("Enhanced prompt is sent via system message without rewriting user message")
    func testEnhancedPrompt_AsSystemMessageWithoutUserRewrite() async throws {
        await cleanup()

        let userText = "请保持原始用户内容"
        let enhancedPrompt = "你需要先给出结论，再给出步骤。"

        await chatService.sendAndProcessMessage(
            content: userText,
            aiTemperature: 0,
            aiTopP: 1,
            systemPrompt: "",
            maxChatHistory: 5,
            enableStreaming: false,
            enhancedPrompt: enhancedPrompt,
            enableMemory: false,
            enableMemoryWrite: false,
            includeSystemTime: false
        )

        let sentMessages = mockAdapter.receivedMessages ?? []
        let lastMessage = sentMessages.last
        let enhancedSystemMessage = sentMessages.last(where: { $0.role == .system && $0.content.contains("<enhanced_prompt>") })
        let systemContent = enhancedSystemMessage?.content ?? ""
        let systemMessages = sentMessages.filter { $0.role == .system }
        let userMessage = sentMessages.last(where: { $0.role == .user })
        let userContent = userMessage?.content ?? ""

        #expect(lastMessage?.role == .system, "Enhanced prompt system message should be appended at the end of messages.")
        #expect(systemContent.contains("<enhanced_prompt>"), "System message should contain enhanced prompt tag.")
        #expect(systemContent.contains(enhancedPrompt), "System message should contain enhanced prompt content.")
        #expect(systemMessages.count == 1, "无其他系统提示时，增强提示应单独形成唯一的 system message。")
        #expect(userContent == userText, "User message should remain unchanged.")
        #expect(!userContent.contains("<user_input>"), "User message should not be wrapped by <user_input>.")

        await cleanup()
    }
    
    @Test("Time tag is injected when preference is enabled")
    func testSystemTimePromptInjection() async throws {
        await cleanup()
        mockAdapter.responseToReturn = ChatMessage(role: .assistant, content: "ok")
        
        await chatService.sendAndProcessMessage(
            content: "现在几点？",
            aiTemperature: 0,
            aiTopP: 1,
            systemPrompt: "",
            maxChatHistory: 5,
            enableStreaming: false,
            enhancedPrompt: nil,
            enableMemory: false,
            enableMemoryWrite: false,
            includeSystemTime: true
        )
        
        let systemMessage = mockAdapter.receivedMessages?.first(where: { $0.role == .system })
        let content = systemMessage?.content ?? ""
        #expect(content.contains("<time>"), "System prompt should include <time> when the toggle is on.")
        #expect(content.contains("ISO8601"), "Time block should include ISO8601 representation for determinism.")
        
        await cleanup()
    }

    @Test("周期性时间路标支持自定义分钟并插入在锚点消息前")
    func testPeriodicTimeLandmark_CustomIntervalAndInsertPosition() async throws {
        await cleanup()
        mockAdapter.responseToReturn = ChatMessage(role: .assistant, content: "ok")

        let now = Date()
        let session = try #require(chatService.currentSessionSubject.value)
        let oldMessage = ChatMessage(
            role: .user,
            content: "10分钟前的消息",
            requestedAt: now.addingTimeInterval(-10 * 60)
        )
        let nearMessage = ChatMessage(
            role: .assistant,
            content: "3分钟前的消息",
            requestedAt: now.addingTimeInterval(-3 * 60)
        )
        let historicalMessages = [oldMessage, nearMessage]
        chatService.messagesForSessionSubject.send(historicalMessages)
        Persistence.saveMessages(historicalMessages, for: session.id)

        await chatService.sendAndProcessMessage(
            content: "现在继续聊",
            aiTemperature: 0,
            aiTopP: 1,
            systemPrompt: "",
            maxChatHistory: 20,
            enableStreaming: false,
            enhancedPrompt: nil,
            enableMemory: false,
            enableMemoryWrite: false,
            includeSystemTime: false,
            enablePeriodicTimeLandmark: true,
            periodicTimeLandmarkIntervalMinutes: 5
        )

        let sentMessages = mockAdapter.receivedMessages ?? []
        let landmarkIndex = sentMessages.firstIndex(where: {
            $0.role == .system && $0.content.contains("本条对话的请求时间为：")
        })
        let insertedIndex = try #require(landmarkIndex)
        #expect(insertedIndex + 1 < sentMessages.count)
        #expect(sentMessages[insertedIndex + 1].id == oldMessage.id, "路标应插入在命中的历史消息前面。")
        #expect(!sentMessages[insertedIndex].content.contains("<periodic_time_landmark>"), "路标提示词应保持为一句短句。")

        await cleanup()
    }

    @Test("周期性时间路标在同一时间窗口内最多注入一次")
    func testPeriodicTimeLandmark_ThrottleByIntervalWindow() async throws {
        await cleanup()
        mockAdapter.responseToReturn = ChatMessage(role: .assistant, content: "ok")

        let now = Date()
        let session = try #require(chatService.currentSessionSubject.value)
        let historicalMessages = [
            ChatMessage(role: .user, content: "很早之前的问题", requestedAt: now.addingTimeInterval(-120 * 60)),
            ChatMessage(role: .assistant, content: "很早之前的回答", requestedAt: now.addingTimeInterval(-90 * 60))
        ]
        chatService.messagesForSessionSubject.send(historicalMessages)
        Persistence.saveMessages(historicalMessages, for: session.id)

        await chatService.sendAndProcessMessage(
            content: "第一次请求",
            aiTemperature: 0,
            aiTopP: 1,
            systemPrompt: "",
            maxChatHistory: 20,
            enableStreaming: false,
            enhancedPrompt: nil,
            enableMemory: false,
            enableMemoryWrite: false,
            includeSystemTime: false,
            enablePeriodicTimeLandmark: true,
            periodicTimeLandmarkIntervalMinutes: 30
        )
        let firstSentMessages = mockAdapter.receivedMessages ?? []
        let firstCount = firstSentMessages.filter { $0.role == .system && $0.content.contains("本条对话的请求时间为：") }.count
        #expect(firstCount == 1)

        await chatService.sendAndProcessMessage(
            content: "紧接着第二次请求",
            aiTemperature: 0,
            aiTopP: 1,
            systemPrompt: "",
            maxChatHistory: 20,
            enableStreaming: false,
            enhancedPrompt: nil,
            enableMemory: false,
            enableMemoryWrite: false,
            includeSystemTime: false,
            enablePeriodicTimeLandmark: true,
            periodicTimeLandmarkIntervalMinutes: 30
        )
        let secondSentMessages = mockAdapter.receivedMessages ?? []
        let secondCount = secondSentMessages.filter { $0.role == .system && $0.content.contains("本条对话的请求时间为：") }.count
        #expect(secondCount == 0, "同一时间窗口内不应重复注入路标。")

        await cleanup()
    }
    
    @Test("save_memory tool is provided when memory is enabled")
    func testToolProvision_Enabled() async throws {
        await cleanup()
        await chatService.sendAndProcessMessage(content: "hello", aiTemperature: 0, aiTopP: 1, systemPrompt: "", maxChatHistory: 5, enableStreaming: false, enhancedPrompt: nil, enableMemory: true, enableMemoryWrite: true, includeSystemTime: false)
        #expect(self.mockAdapter.receivedTools?.contains(where: { $0.name == "save_memory" }) == true)
        await cleanup()
    }
    
    @Test("save_memory tool is NOT provided when memory is disabled")
    func testToolProvision_Disabled() async throws {
        await cleanup()
        await chatService.sendAndProcessMessage(content: "hello", aiTemperature: 0, aiTopP: 1, systemPrompt: "", maxChatHistory: 5, enableStreaming: false, enhancedPrompt: nil, enableMemory: false, enableMemoryWrite: false, includeSystemTime: false)
        #expect(self.mockAdapter.receivedTools?.contains(where: { $0.name == "save_memory" }) != true)
        await cleanup()
    }

    @Test("save_memory tool is NOT provided when write switch is disabled")
    func testToolProvision_WriteSwitchDisabled() async throws {
        await cleanup()
        await chatService.sendAndProcessMessage(content: "hello", aiTemperature: 0, aiTopP: 1, systemPrompt: "", maxChatHistory: 5, enableStreaming: false, enhancedPrompt: nil, enableMemory: true, enableMemoryWrite: false, includeSystemTime: false)
        #expect(self.mockAdapter.receivedTools?.contains(where: { $0.name == "save_memory" }) != true)
        await cleanup()
    }

    @Test("search_memory tool is provided when active retrieval is enabled and topK > 0")
    func testSearchMemoryToolProvision_Enabled() async throws {
        await cleanup()
        let defaults = UserDefaults.standard
        let originalTopK = defaults.object(forKey: "memoryTopK")
        defer {
            if let originalTopK {
                defaults.set(originalTopK, forKey: "memoryTopK")
            } else {
                defaults.removeObject(forKey: "memoryTopK")
            }
        }
        defaults.set(3, forKey: "memoryTopK")

        await chatService.sendAndProcessMessage(
            content: "hello",
            aiTemperature: 0,
            aiTopP: 1,
            systemPrompt: "",
            maxChatHistory: 5,
            enableStreaming: false,
            enhancedPrompt: nil,
            enableMemory: true,
            enableMemoryWrite: false,
            enableMemoryActiveRetrieval: true,
            includeSystemTime: false
        )

        #expect(self.mockAdapter.receivedTools?.contains(where: { $0.name == "search_memory" }) == true)
        await cleanup()
    }

    @Test("search_memory tool is NOT provided when topK is 0")
    func testSearchMemoryToolProvision_TopKZero() async throws {
        await cleanup()
        let defaults = UserDefaults.standard
        let originalTopK = defaults.object(forKey: "memoryTopK")
        defer {
            if let originalTopK {
                defaults.set(originalTopK, forKey: "memoryTopK")
            } else {
                defaults.removeObject(forKey: "memoryTopK")
            }
        }
        defaults.set(0, forKey: "memoryTopK")

        await chatService.sendAndProcessMessage(
            content: "hello",
            aiTemperature: 0,
            aiTopP: 1,
            systemPrompt: "",
            maxChatHistory: 5,
            enableStreaming: false,
            enhancedPrompt: nil,
            enableMemory: true,
            enableMemoryWrite: false,
            enableMemoryActiveRetrieval: true,
            includeSystemTime: false
        )

        #expect(self.mockAdapter.receivedTools?.contains(where: { $0.name == "search_memory" }) != true)
        await cleanup()
    }

    @Test("save_memory tool call correctly saves memory")
    func testSaveMemoryTool_Execution() async throws {
        await cleanup()
        
        // 1. Arrange: Create a mock response message that contains a tool call.
        let toolCallId = "call_123"
        let arguments = """
        {"content": "The user lives in London."}
        """
        let toolCall = InternalToolCall(id: toolCallId, toolName: "save_memory", arguments: arguments)
        let responseMessage = ChatMessage(role: .assistant, content: "Okay, I'll remember that.", toolCalls: [toolCall])
        
        let saveMemoryTool = chatService.saveMemoryTool

        // 关键修复：获取一个将发布未来更新的异步流，并丢弃第一个（当前）值。
        var memoryUpdatesIterator = memoryManager.memoriesPublisher.dropFirst().values.makeAsyncIterator()
        
        // 2. Act: Call the logic-handling function directly, bypassing the network.
        await chatService.processResponseMessage(
            responseMessage: responseMessage,
            loadingMessageID: UUID(),
            currentSessionID: chatService.currentSessionSubject.value?.id ?? UUID(),
            userMessage: nil,
            wasTemporarySession: false,
            availableTools: [saveMemoryTool],
            aiTemperature: 0,
            aiTopP: 0,
            systemPrompt: "",
            maxChatHistory: 0,
            enableMemory: true,
            enableMemoryWrite: true,
            includeSystemTime: false
        )
        
        // 关键修复：等待后台的 addMemory 操作完成，它会触发 publisher 发出新值。
        _ = await memoryUpdatesIterator.next()
        
        // 3. Assert: 现在可以安全地检查记忆是否已保存。
        let memories = await memoryManager.getAllMemories()
        #expect(memories.count == 1)
        #expect(memories.first?.content == "The user lives in London.")
        
        // 4. Teardown
        await cleanup()
    }

    @Test("search_memory tool call returns keyword retrieval result")
    func testSearchMemoryTool_Execution() async throws {
        await cleanup()
        await memoryManager.addMemory(content: "用户喜欢喝抹茶拿铁。")
        await memoryManager.addMemory(content: "用户使用 Swift 做 iOS 开发。")

        let defaults = UserDefaults.standard
        let originalTopK = defaults.object(forKey: "memoryTopK")
        defer {
            if let originalTopK {
                defaults.set(originalTopK, forKey: "memoryTopK")
            } else {
                defaults.removeObject(forKey: "memoryTopK")
            }
        }
        defaults.set(3, forKey: "memoryTopK")

        let toolCall = InternalToolCall(
            id: "call_search_1",
            toolName: "search_memory",
            arguments: #"{"mode":"keyword","query":"抹茶","count":1}"#
        )
        let responseMessage = ChatMessage(role: .assistant, content: "", toolCalls: [toolCall])

        await chatService.processResponseMessage(
            responseMessage: responseMessage,
            loadingMessageID: UUID(),
            currentSessionID: chatService.currentSessionSubject.value?.id ?? UUID(),
            userMessage: nil,
            wasTemporarySession: false,
            availableTools: [chatService.searchMemoryTool],
            aiTemperature: 0,
            aiTopP: 0,
            systemPrompt: "",
            maxChatHistory: 0,
            enableMemory: true,
            enableMemoryWrite: false,
            enableMemoryActiveRetrieval: true,
            includeSystemTime: false
        )

        let toolMessages = chatService.messagesForSessionSubject.value.filter { $0.role == .tool }
        let latestToolContent = toolMessages.last?.content ?? ""
        #expect(latestToolContent.contains("\"mode\" : \"keyword\""))
        #expect(latestToolContent.contains("抹茶"))

        await cleanup()
    }

    @Test("Worldbook prompt injection order and depth insertion")
    func testWorldbookInjectionOrderAndDepth() async throws {
        await cleanup()
        let store = WorldbookStore.shared
        let originalBooks = store.loadWorldbooks()
        defer { store.saveWorldbooks(originalBooks) }

        let book = Worldbook(
            name: "注入测试书",
            entries: [
                WorldbookEntry(content: "before", keys: ["hero"], position: .before, order: 1),
                WorldbookEntry(content: "after", keys: ["hero"], position: .after, order: 2),
                WorldbookEntry(content: "an-top", keys: ["hero"], position: .anTop, order: 3),
                WorldbookEntry(content: "an-bottom", keys: ["hero"], position: .anBottom, order: 4),
                WorldbookEntry(content: "em-top", keys: ["hero"], position: .emTop, order: 5),
                WorldbookEntry(content: "em-bottom", keys: ["hero"], position: .emBottom, order: 6),
                WorldbookEntry(content: "depth-user", keys: ["hero"], position: .atDepth, order: 7, depth: 1, role: .user),
                WorldbookEntry(content: "depth-assistant", keys: ["hero"], position: .atDepth, order: 8, depth: 1, role: .assistant),
                WorldbookEntry(content: "depth-system", keys: ["hero"], position: .atDepth, order: 9, depth: 1, role: .system)
            ]
        )
        store.saveWorldbooks([book])

        var session = chatService.currentSessionSubject.value ?? ChatSession(id: UUID(), name: "测试会话")
        session.lorebookIDs = [book.id]
        chatService.setCurrentSession(session)

        await chatService.sendAndProcessMessage(
            content: "hero",
            aiTemperature: 0,
            aiTopP: 1,
            systemPrompt: "sys",
            maxChatHistory: 10,
            enableStreaming: false,
            enhancedPrompt: nil,
            enableMemory: false,
            enableMemoryWrite: false,
            includeSystemTime: false
        )

        let allMessages = mockAdapter.receivedMessages ?? []
        let systemPrompt = allMessages.first(where: { $0.role == .system })?.content ?? ""
        #expect(systemPrompt.contains("<worldbook_before>"))
        #expect(systemPrompt.contains("<worldbook_after>"))
        #expect(systemPrompt.contains("<worldbook_an_top>"))
        #expect(systemPrompt.contains("<worldbook_an_bottom>"))

        #expect(allMessages.contains(where: { $0.content.contains("<worldbook_em_top>") }))
        #expect(allMessages.contains(where: { $0.content.contains("<worldbook_em_bottom>") }))
        #expect(allMessages.contains(where: { $0.content.contains("<worldbook_at_depth_1>") && $0.role == .system }))
        #expect(allMessages.contains(where: { $0.content.contains("<worldbook_at_depth_1>") && $0.role == .assistant }))
        #expect(allMessages.contains(where: { $0.content.contains("<worldbook_at_depth_1>") && $0.role == .user }))

        await cleanup()
    }

    @Test("Worldbook coexists with memory block")
    func testWorldbookAndMemoryCoexist() async throws {
        await cleanup()
        let store = WorldbookStore.shared
        let originalBooks = store.loadWorldbooks()
        defer { store.saveWorldbooks(originalBooks) }

        await memoryManager.addMemory(content: "memory-hit")
        let book = Worldbook(
            name: "共存书",
            entries: [WorldbookEntry(content: "wb-hit", keys: ["hero"], position: .after)]
        )
        store.saveWorldbooks([book])

        var session = chatService.currentSessionSubject.value ?? ChatSession(id: UUID(), name: "共存会话")
        session.lorebookIDs = [book.id]
        chatService.setCurrentSession(session)

        await chatService.sendAndProcessMessage(
            content: "hero",
            aiTemperature: 0,
            aiTopP: 1,
            systemPrompt: "sys",
            maxChatHistory: 10,
            enableStreaming: false,
            enhancedPrompt: nil,
            enableMemory: true,
            enableMemoryWrite: true,
            includeSystemTime: false
        )

        let systemPrompt = mockAdapter.receivedMessages?.first(where: { $0.role == .system })?.content ?? ""
        #expect(systemPrompt.contains("<memory>"))
        #expect(systemPrompt.contains("<worldbook_after>"))

        await cleanup()
    }

    @Test("Worldbook isolation suppresses memory and tool context")
    func testWorldbookIsolationSuppressesMemoryAndToolContext() async throws {
        await cleanup()
        setupMockResponsesForChatAndTitle()

        let store = WorldbookStore.shared
        let originalBooks = store.loadWorldbooks()
        let originalShortcutTools = ShortcutToolStore.loadTools()
        let originalShortcutToolsEnabled = await MainActor.run { ShortcutToolManager.shared.chatToolsEnabled }
        let originalAppToolsEnabled = await MainActor.run { AppToolManager.shared.chatToolsEnabled }
        let originalAppToolKinds = await MainActor.run { AppToolManager.shared.enabledToolKinds }

        await memoryManager.addMemory(content: "memory-should-hide")

        let shortcutTool = ShortcutToolDefinition(
            name: "RP 测试快捷指令",
            metadata: ["displayName": .string("RP 测试快捷指令")],
            isEnabled: true,
            userDescription: "用于测试世界书隔离发送。"
        )
        ShortcutToolStore.saveTools([shortcutTool])
        await MainActor.run {
            ShortcutToolManager.shared.reloadFromDisk()
            ShortcutToolManager.shared.setChatToolsEnabled(true)
            AppToolManager.shared.restoreStateForTests(
                chatToolsEnabled: true,
                enabledKinds: [.echoText]
            )
        }

        let book = Worldbook(
            name: "隔离书",
            entries: [WorldbookEntry(content: "wb-isolated", keys: ["hero"], position: .after)]
        )
        store.saveWorldbooks([book])

        var session = chatService.currentSessionSubject.value ?? ChatSession(id: UUID(), name: "隔离会话")
        session.lorebookIDs = [book.id]
        session.worldbookContextIsolationEnabled = true
        chatService.setCurrentSession(session)

        let historicalAssistantToolCall = InternalToolCall(
            id: "historical-tool-call",
            toolName: ShortcutToolNaming.alias(for: shortcutTool),
            arguments: "{}"
        )
        let historicalMessages = [
            ChatMessage(role: .user, content: "前情 hero"),
            ChatMessage(role: .assistant, content: "", toolCalls: [historicalAssistantToolCall]),
            ChatMessage(role: .tool, content: "tool-result", toolCalls: [historicalAssistantToolCall])
        ]
        chatService.messagesForSessionSubject.send(historicalMessages)
        Persistence.saveMessages(historicalMessages, for: session.id)

        await chatService.sendAndProcessMessage(
            content: "hero",
            aiTemperature: 0,
            aiTopP: 1,
            systemPrompt: "sys",
            maxChatHistory: 10,
            enableStreaming: false,
            enhancedPrompt: nil,
            enableMemory: true,
            enableMemoryWrite: true,
            enableMemoryActiveRetrieval: true,
            includeSystemTime: false
        )

        let sentMessages = mockAdapter.receivedMessages ?? []
        let systemPrompt = sentMessages.first(where: { $0.role == .system })?.content ?? ""
        #expect(systemPrompt.contains("<worldbook_after>"))
        #expect(systemPrompt.contains("wb-isolated"))
        #expect(!systemPrompt.contains("<memory>"))
        #expect(!systemPrompt.contains("memory-should-hide"))
        #expect(mockAdapter.receivedTools == nil)
        #expect(!sentMessages.contains(where: { $0.role == .tool }))
        #expect(!sentMessages.contains(where: { !($0.toolCalls?.isEmpty ?? true) }))

        ShortcutToolStore.saveTools(originalShortcutTools)
        await MainActor.run {
            ShortcutToolManager.shared.reloadFromDisk()
            ShortcutToolManager.shared.setChatToolsEnabled(originalShortcutToolsEnabled)
            AppToolManager.shared.restoreStateForTests(
                chatToolsEnabled: originalAppToolsEnabled,
                enabledKinds: originalAppToolKinds
            )
        }
        store.saveWorldbooks(originalBooks)

        await cleanup()
    }
    
    @Test("Update Message Content")
    func testUpdateMessageContent() {
        // Arrange
        let session = chatService.currentSessionSubject.value!
        let originalMessage = ChatMessage(role: .user, content: "Original Content")
        chatService.messagesForSessionSubject.send([originalMessage])
        Persistence.saveMessages([originalMessage], for: session.id)

        // Act
        let updatedMessage = ChatMessage(id: originalMessage.id, role: .user, content: "Updated Content")
        chatService.updateMessageContent(updatedMessage, with: updatedMessage.content)

        // Assert
        let finalMessages = Persistence.loadMessages(for: session.id)
        #expect(finalMessages.count == 1)
        #expect(finalMessages.first?.content == "Updated Content")
    }

    @Test("Retry Last Message")
    func testRetryLastMessage() async {
        // Arrange
        let firstUserMessage = "Hello, what is the weather?"
        await chatService.sendAndProcessMessage(content: firstUserMessage, aiTemperature: 0, aiTopP: 1, systemPrompt: "", maxChatHistory: 5, enableStreaming: false, enhancedPrompt: nil, enableMemory: false, enableMemoryWrite: false, includeSystemTime: false)
        let firstRequestMessages = mockAdapter.receivedMessages
        #expect(firstRequestMessages?.last?.content == firstUserMessage)
        
        // Act
        await chatService.retryLastMessage(aiTemperature: 0, aiTopP: 1, systemPrompt: "", maxChatHistory: 5, enableStreaming: false, enhancedPrompt: nil, enableMemory: false, enableMemoryWrite: false, includeSystemTime: false)
        let secondRequestMessages = mockAdapter.receivedMessages

        // Assert
        #expect(secondRequestMessages?.last?.content == firstUserMessage)
        #expect(secondRequestMessages?.count == firstRequestMessages?.count)
    }

    @Test("重试失败时应优先更新当前 loading 消息，避免误改历史空 assistant")
    func testRetryFailureTargetsCurrentLoadingMessage() async throws {
        await cleanup()

        let brokenToolCall = InternalToolCall(
            id: "call_broken_history",
            toolName: "search_memory",
            arguments: #"{"mode":"keyword","query":"历史"}"#
        )
        let userMessage = ChatMessage(role: .user, content: "第一条提问")
        let assistantToRetry = ChatMessage(role: .assistant, content: "第一条回答")
        let trailingUserMessage = ChatMessage(role: .user, content: "后续问题")
        let trailingEmptyAssistant = ChatMessage(role: .assistant, content: "", toolCalls: [brokenToolCall])

        let session = try #require(chatService.currentSessionSubject.value)
        let seededMessages = [userMessage, assistantToRetry, trailingUserMessage, trailingEmptyAssistant]
        chatService.updateMessages(seededMessages, for: session.id)

        let chatURL = URL(string: "https://fake.url/chat")!
        let serverErrorResponse = HTTPURLResponse(url: chatURL, statusCode: 500, httpVersion: "HTTP/1.1", headerFields: nil)!
        MockURLProtocol.mockResponses[chatURL] = .success((serverErrorResponse, Data("Internal Server Error".utf8)))

        await chatService.retryMessage(
            assistantToRetry,
            aiTemperature: 0,
            aiTopP: 1,
            systemPrompt: "",
            maxChatHistory: 10,
            enableStreaming: false,
            enhancedPrompt: nil,
            enableMemory: false,
            enableMemoryWrite: false,
            includeSystemTime: false
        )

        let finalMessages = chatService.messagesForSessionSubject.value
        let retriedMessage = finalMessages.first(where: { $0.id == assistantToRetry.id })
        let trailingAssistant = finalMessages.first(where: { $0.id == trailingEmptyAssistant.id })

        #expect(retriedMessage?.role == .assistant)
        #expect(retriedMessage?.content.contains("重试失败") == true)
        #expect(trailingAssistant?.role == .assistant)
        #expect(trailingAssistant?.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true)

        await cleanup()
    }

    @Test("发送请求前会剔除损坏的工具调用链，避免上游 400")
    func testPreparedMessagesDropBrokenToolChain() async throws {
        await cleanup()

        setupMockResponsesForChatAndTitle()
        mockAdapter.responseToReturn = ChatMessage(role: .assistant, content: "已收到")

        let unresolvedCall = InternalToolCall(
            id: "call_unresolved",
            toolName: "search_memory",
            arguments: #"{"mode":"keyword","query":"未闭合"}"#
        )
        let orphanToolResultCall = InternalToolCall(
            id: "call_orphan",
            toolName: "search_memory",
            arguments: #"{"mode":"keyword","query":"孤儿结果"}"#
        )

        let historyUser = ChatMessage(role: .user, content: "历史问题")
        let brokenAssistant = ChatMessage(role: .assistant, content: "", toolCalls: [unresolvedCall])
        let orphanToolMessage = ChatMessage(role: .tool, content: "孤儿工具结果", toolCalls: [orphanToolResultCall])

        let session = try #require(chatService.currentSessionSubject.value)
        chatService.updateMessages([historyUser, brokenAssistant, orphanToolMessage], for: session.id)

        await chatService.sendAndProcessMessage(
            content: "请继续回答",
            aiTemperature: 0,
            aiTopP: 1,
            systemPrompt: "",
            maxChatHistory: 10,
            enableStreaming: false,
            enhancedPrompt: nil,
            enableMemory: false,
            enableMemoryWrite: false,
            includeSystemTime: false
        )

        let sentMessages = mockAdapter.receivedMessages ?? []
        #expect(!sentMessages.contains(where: { $0.id == brokenAssistant.id }))
        #expect(!sentMessages.contains(where: { $0.id == orphanToolMessage.id }))
        #expect(!sentMessages.contains(where: { $0.role == .tool }))

        await cleanup()
    }
}

@Suite("ChatService 响应测速计算 Tests")
fileprivate struct ChatServiceResponseMetricsTests {
    @Test("流式 token/s 使用总时长减首字时间")
    func testStreamingTokenPerSecondUsesPostFirstTokenDuration() {
        let service = ChatService()
        let requestStartedAt = Date(timeIntervalSince1970: 1_000)
        let firstTokenAt = Date(timeIntervalSince1970: 1_002)
        let completedAt = Date(timeIntervalSince1970: 1_010)

        let speed = service.streamingTokenPerSecond(
            tokens: 80,
            requestStartedAt: requestStartedAt,
            firstTokenAt: firstTokenAt,
            snapshotAt: completedAt
        )

        #expect(speed != nil)
        #expect(abs((speed ?? 0) - 10.0) < 0.0001)
    }

    @Test("流式 token/s 在无首字时间时返回空")
    func testStreamingTokenPerSecondReturnsNilWithoutFirstToken() {
        let service = ChatService()
        let requestStartedAt = Date(timeIntervalSince1970: 1_000)
        let snapshotAt = Date(timeIntervalSince1970: 1_010)

        let speed = service.streamingTokenPerSecond(
            tokens: 80,
            requestStartedAt: requestStartedAt,
            firstTokenAt: nil,
            snapshotAt: snapshotAt
        )

        #expect(speed == nil)
    }
}

// MARK: - ChatSession Management Tests

@Suite("ChatSession Management Tests")
fileprivate struct ChatSessionTests {

    var chatService: ChatService! 

    init() async {
        // For these tests, we can use a standard ChatService instance
        // as session management does not have complex external dependencies.
        chatService = ChatService()
        Persistence.saveSessionFolders([])
        // Clear any persisted sessions from previous runs to ensure a clean state
        let sessions = chatService.chatSessionsSubject.value
        if !sessions.isEmpty {
            chatService.deleteSessions(sessions)
        }
        // After deletion, the service auto-creates one new temporary session.
        #expect(chatService.chatSessionsSubject.value.count == 1)
    }

    @Test("Create New Session")
    func testCreateNewSession() {
        // Arrange: The init() already provides a clean state with 1 session.
        let initialCurrentSession = chatService.currentSessionSubject.value
        
        chatService.messagesForSessionSubject.send([ChatMessage(role: .user, content: "dummy message")])
        #expect(chatService.messagesForSessionSubject.value.isEmpty == false)

        // Act
        chatService.createNewSession()

        // Assert
        let newSessions = chatService.chatSessionsSubject.value
        let newCurrentSession = chatService.currentSessionSubject.value
        let newMessages = chatService.messagesForSessionSubject.value

        #expect(newSessions.count == 1)
        #expect(newSessions.filter(\.isTemporary).count == 1)
        #expect(newSessions.first?.id == newCurrentSession?.id)
        #expect(newCurrentSession?.isTemporary == true)
        #expect(newCurrentSession?.id == initialCurrentSession?.id)
        #expect(newMessages.isEmpty == true)
    }

    @Test("Create New Session when no temporary session exists")
    func testCreateNewSessionWhenNoTemporarySessionExists() {
        // Arrange: 将初始临时会话“转正”，模拟已经在历史中有永久会话的场景。
        guard var onlySession = chatService.chatSessionsSubject.value.first else {
            Issue.record("缺少初始会话")
            return
        }
        onlySession.isTemporary = false
        chatService.chatSessionsSubject.send([onlySession])
        chatService.setCurrentSession(onlySession)
        Persistence.saveChatSessions([onlySession])

        // Act
        chatService.createNewSession()

        // Assert
        let sessions = chatService.chatSessionsSubject.value
        let temporarySessions = sessions.filter(\.isTemporary)
        #expect(sessions.count == 2)
        #expect(temporarySessions.count == 1)
        #expect(sessions.first?.isTemporary == true)
        #expect(chatService.currentSessionSubject.value?.id == sessions.first?.id)
    }
    
    @Test("Switch Session")
    func testSwitchSession() {
        // Arrange
        // The service starts with one session. Create a second one.
        guard var session1 = chatService.currentSessionSubject.value else {
            Issue.record("缺少初始会话")
            return
        }
        session1.isTemporary = false
        chatService.chatSessionsSubject.send([session1])
        chatService.setCurrentSession(session1)
        Persistence.saveChatSessions([session1])
        chatService.createNewSession()
        
        // Save a dummy message to session 1 to test if it loads correctly
        let messageForSession1 = ChatMessage(role: .user, content: "This is a test for session 1")
        Persistence.saveMessages([messageForSession1], for: session1.id)
        
        // Act
        chatService.setCurrentSession(session1)
        
        // Assert
        let currentSession = chatService.currentSessionSubject.value
        let currentMessages = chatService.messagesForSessionSubject.value
        
        #expect(currentSession?.id == session1.id)
        #expect(currentMessages.count == 1)
        #expect(currentMessages.first?.content == messageForSession1.content)
    }

    @Test("Delete Session")
    func testDeleteSession() {
        // Arrange
        guard var session1 = chatService.currentSessionSubject.value else {
            Issue.record("缺少初始会话")
            return
        }
        session1.isTemporary = false
        chatService.chatSessionsSubject.send([session1])
        chatService.setCurrentSession(session1)
        Persistence.saveChatSessions([session1])
        chatService.createNewSession() // Session 2 is now current
        let session2 = chatService.currentSessionSubject.value!
        let initialCount = chatService.chatSessionsSubject.value.count
        #expect(initialCount == 2)

        // Act: Delete the *current* session (session 2)
        chatService.deleteSessions([session2])
        
        // Assert
        let finalSessions = chatService.chatSessionsSubject.value
        let finalCurrentSession = chatService.currentSessionSubject.value
        
        #expect(finalSessions.count == initialCount - 1)
        #expect(finalSessions.contains(where: { $0.id == session2.id }) == false)
        // Check that it correctly fell back to the other session
        #expect(finalCurrentSession?.id == session1.id)
    }
    
    @Test("Delete last session creates a new temporary one")
    func testDeleteLastSession_CreatesNewTemporarySession() {
        // Arrange
        // The init() provides a state with exactly one temporary session.
        let initialSessions = chatService.chatSessionsSubject.value
        #expect(initialSessions.count == 1)
        let lastSession = initialSessions.first!

        // Act
        chatService.deleteSessions([lastSession])

        // Assert
        let finalSessions = chatService.chatSessionsSubject.value
        let newCurrentSession = chatService.currentSessionSubject.value

        #expect(finalSessions.count == 1, "Should still have one session in the list")
        #expect(newCurrentSession?.id != lastSession.id, "The new session should have a different ID")
        #expect(newCurrentSession?.isTemporary == true, "The new session should be temporary")
        #expect(newCurrentSession?.name == "新的对话", "The new session should have the default name")
    }

    @Test("Branch Session With Message Copy")
    func testBranchSession() {
        // Arrange
        let sourceSession = chatService.currentSessionSubject.value!
        let message = ChatMessage(role: .user, content: "message to be copied")
        Persistence.saveMessages([message], for: sourceSession.id)
        let initialCount = chatService.chatSessionsSubject.value.count

        // Act
        chatService.branchSession(from: sourceSession, copyMessages: true)
        
        // Assert
        let newSessions = chatService.chatSessionsSubject.value
        let newCurrentSession = chatService.currentSessionSubject.value
        let newSessionMessages = chatService.messagesForSessionSubject.value
        
        #expect(newSessions.count == initialCount + 1)
        #expect(newCurrentSession?.id != sourceSession.id)
        #expect(newCurrentSession?.name.contains("分支:") == true)
        #expect(newSessionMessages.count == 1)
        #expect(newSessionMessages.first?.content == message.content)
    }

    @Test("删除文件夹时会递归删除子文件夹并将会话回到未分类")
    func testDeleteFolderRecursivelyReassignsSessionsToUncategorized() {
        guard let rootFolder = chatService.createSessionFolder(name: "项目", parentID: nil) else {
            Issue.record("创建根文件夹失败")
            return
        }
        guard let childFolder = chatService.createSessionFolder(name: "子目录", parentID: rootFolder.id) else {
            Issue.record("创建子文件夹失败")
            return
        }

        let savedSession = chatService.createSavedSession(
            name: "分类会话",
            initialMessages: [],
            folderID: childFolder.id
        )
        #expect(savedSession.folderID == childFolder.id)
        #expect(chatService.sessionFoldersSubject.value.count == 2)

        chatService.deleteSessionFolder(folderID: rootFolder.id)

        let folders = chatService.sessionFoldersSubject.value
        #expect(folders.isEmpty)

        let updatedSession = chatService.chatSessionsSubject.value.first(where: { $0.id == savedSession.id })
        #expect(updatedSession != nil)
        #expect(updatedSession?.folderID == nil)
    }
}

// MARK: - Persistence & Config Tests

@Suite("Persistence Tests")
fileprivate struct PersistenceTests {

    private struct LegacySessionRecord: Decodable {
        struct SessionMeta: Decodable {
            let id: UUID
            let name: String
            let folderID: UUID?
            let lorebookIDs: [UUID]
        }

        struct SessionPrompts: Decodable {
            let topicPrompt: String?
            let enhancedPrompt: String?
        }

        let schemaVersion: Int
        let session: SessionMeta
        let prompts: SessionPrompts
        let messages: [ChatMessage]
    }

    private var chatsDirectory: URL {
        Persistence.getChatsDirectory()
    }

    private var currentSessionsDirectory: URL {
        chatsDirectory.appendingPathComponent("sessions")
    }

    private var currentIndexFileURL: URL {
        chatsDirectory.appendingPathComponent("index.json")
    }

    private var foldersFileURL: URL {
        chatsDirectory.appendingPathComponent("folders.json")
    }

    private var legacySessionDirectory: URL {
        chatsDirectory.appendingPathComponent("v3")
    }

    private var legacySessionIndexFileURL: URL {
        legacySessionDirectory.appendingPathComponent("index.json")
    }

    private var legacyRootDirectory: URL {
        chatsDirectory.appendingPathComponent("legacy")
    }

    private var requestLogsDirectory: URL {
        chatsDirectory.appendingPathComponent("RequestLogs")
    }

    private var chatStoreSQLiteURL: URL {
        chatsDirectory.appendingPathComponent("chat-store.sqlite")
    }

    private var chatStoreSQLiteWALURL: URL {
        chatsDirectory.appendingPathComponent("chat-store.sqlite-wal")
    }

    private var chatStoreSQLiteSHMURL: URL {
        chatsDirectory.appendingPathComponent("chat-store.sqlite-shm")
    }

    private var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private var configDirectory: URL {
        documentsDirectory.appendingPathComponent("Config")
    }

    private var memoryDirectory: URL {
        documentsDirectory.appendingPathComponent("Memory")
    }

    private var memoryRawMemoriesFileURL: URL {
        memoryDirectory.appendingPathComponent("memories.json")
    }

    private var memoryUserProfileFileURL: URL {
        memoryDirectory.appendingPathComponent("user_profile.json")
    }

    private var shortcutToolsDirectory: URL {
        documentsDirectory.appendingPathComponent("ShortcutTools")
    }

    private var shortcutToolsFileURL: URL {
        shortcutToolsDirectory.appendingPathComponent("tools.json")
    }

    private var configStoreSQLiteURL: URL {
        configDirectory.appendingPathComponent("config-store.sqlite")
    }

    private var configStoreSQLiteWALURL: URL {
        configDirectory.appendingPathComponent("config-store.sqlite-wal")
    }

    private var configStoreSQLiteSHMURL: URL {
        configDirectory.appendingPathComponent("config-store.sqlite-shm")
    }

    private var legacyConfigStoreSQLiteURL: URL {
        chatsDirectory.appendingPathComponent("config-store.sqlite")
    }

    private var legacyConfigStoreSQLiteWALURL: URL {
        chatsDirectory.appendingPathComponent("config-store.sqlite-wal")
    }

    private var legacyConfigStoreSQLiteSHMURL: URL {
        chatsDirectory.appendingPathComponent("config-store.sqlite-shm")
    }

    private var memoryStoreSQLiteURL: URL {
        memoryDirectory.appendingPathComponent("memory-store.sqlite")
    }

    private var memoryStoreSQLiteWALURL: URL {
        memoryDirectory.appendingPathComponent("memory-store.sqlite-wal")
    }

    private var memoryStoreSQLiteSHMURL: URL {
        memoryDirectory.appendingPathComponent("memory-store.sqlite-shm")
    }

    private var chatStoreBackupDirectory: URL {
        chatsDirectory.appendingPathComponent("StartupBackups")
    }

    private var chatStoreBackupSQLiteURL: URL {
        chatStoreBackupDirectory.appendingPathComponent("chat-store.sqlite")
    }

    private var configStoreBackupDirectory: URL {
        configDirectory.appendingPathComponent("StartupBackups")
    }

    private var configStoreBackupSQLiteURL: URL {
        configStoreBackupDirectory.appendingPathComponent("config-store.sqlite")
    }

    private var memoryStoreBackupDirectory: URL {
        memoryDirectory.appendingPathComponent("StartupBackups")
    }

    private var memoryStoreBackupSQLiteURL: URL {
        memoryStoreBackupDirectory.appendingPathComponent("memory-store.sqlite")
    }

    private var legacyMemoryStoreSQLiteURL: URL {
        chatsDirectory.appendingPathComponent("memory-store.sqlite")
    }

    private var legacyMemoryStoreSQLiteWALURL: URL {
        chatsDirectory.appendingPathComponent("memory-store.sqlite-wal")
    }

    private var legacyMemoryStoreSQLiteSHMURL: URL {
        chatsDirectory.appendingPathComponent("memory-store.sqlite-shm")
    }

    private var legacySessionsIndexURL: URL {
        chatsDirectory.appendingPathComponent("sessions.json")
    }

    private func currentSessionFileURL(_ sessionID: UUID) -> URL {
        currentSessionsDirectory
            .appendingPathComponent("\(sessionID.uuidString).json")
    }

    private func legacySessionFileURL(_ sessionID: UUID) -> URL {
        legacySessionDirectory
            .appendingPathComponent("sessions")
            .appendingPathComponent("\(sessionID.uuidString).json")
    }

    private func legacyMessageFileURL(_ sessionID: UUID) -> URL {
        chatsDirectory.appendingPathComponent("\(sessionID.uuidString).json")
    }

    private func removeIfExists(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func sqliteExists(_ url: URL, sql: String) -> Bool {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database else {
            return false
        }
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            return false
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return false
        }
        return sqlite3_column_int(statement, 0) > 0
    }

    private func sqliteCount(_ url: URL, sql: String) -> Int {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database else {
            return 0
        }
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            return 0
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return 0
        }
        return Int(sqlite3_column_int(statement, 0))
    }

    private func sqliteExecute(_ url: URL, sql: String) {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database else {
            return
        }
        defer { sqlite3_close(database) }
        _ = sqlite3_exec(database, sql, nil, nil, nil)
    }
    
    // Clean up files created during tests
    private func cleanup(sessions: [ChatSession]) {
        Persistence.saveChatSessions([])
        Persistence.clearRequestLogs()
        for session in sessions {
            Persistence.deleteSessionArtifacts(sessionID: session.id)
        }
        removeIfExists(currentIndexFileURL)
        removeIfExists(foldersFileURL)
        removeIfExists(currentSessionsDirectory)
        removeIfExists(requestLogsDirectory)
        removeIfExists(legacySessionDirectory)
        removeIfExists(legacySessionsIndexURL)
        removeIfExists(legacyRootDirectory)
        removeIfExists(chatStoreSQLiteURL)
        removeIfExists(chatStoreSQLiteWALURL)
        removeIfExists(chatStoreSQLiteSHMURL)
        removeIfExists(configStoreSQLiteURL)
        removeIfExists(configStoreSQLiteWALURL)
        removeIfExists(configStoreSQLiteSHMURL)
        removeIfExists(legacyConfigStoreSQLiteURL)
        removeIfExists(legacyConfigStoreSQLiteWALURL)
        removeIfExists(legacyConfigStoreSQLiteSHMURL)
        removeIfExists(memoryStoreSQLiteURL)
        removeIfExists(memoryStoreSQLiteWALURL)
        removeIfExists(memoryStoreSQLiteSHMURL)
        removeIfExists(memoryRawMemoriesFileURL)
        removeIfExists(memoryUserProfileFileURL)
        removeIfExists(shortcutToolsFileURL)
        removeIfExists(shortcutToolsDirectory)
        removeIfExists(chatStoreBackupSQLiteURL)
        removeIfExists(URL(fileURLWithPath: chatStoreBackupSQLiteURL.path + "-wal"))
        removeIfExists(URL(fileURLWithPath: chatStoreBackupSQLiteURL.path + "-shm"))
        removeIfExists(configStoreBackupSQLiteURL)
        removeIfExists(URL(fileURLWithPath: configStoreBackupSQLiteURL.path + "-wal"))
        removeIfExists(URL(fileURLWithPath: configStoreBackupSQLiteURL.path + "-shm"))
        removeIfExists(memoryStoreBackupSQLiteURL)
        removeIfExists(URL(fileURLWithPath: memoryStoreBackupSQLiteURL.path + "-wal"))
        removeIfExists(URL(fileURLWithPath: memoryStoreBackupSQLiteURL.path + "-shm"))
        removeIfExists(chatStoreBackupDirectory)
        removeIfExists(configStoreBackupDirectory)
        removeIfExists(memoryStoreBackupDirectory)
        removeIfExists(legacyMemoryStoreSQLiteURL)
        removeIfExists(legacyMemoryStoreSQLiteWALURL)
        removeIfExists(legacyMemoryStoreSQLiteSHMURL)
    }

    @Test("Save and Load Chat Sessions")
    func testSaveAndLoadChatSessions() {
        // 1. Arrange
        let session1 = ChatSession(id: UUID(), name: "Session 1", isTemporary: false)
        let session2 = ChatSession(id: UUID(), name: "Session 2", topicPrompt: "Test Topic", isTemporary: false)
        let sessionsToSave = [session1, session2]
        
        // 2. Act
        Persistence.saveChatSessions(sessionsToSave)
        let loadedSessions = Persistence.loadChatSessions()
        
        // 3. Assert
        #expect(loadedSessions.count == sessionsToSave.count)
        #expect(loadedSessions.first?.id == session1.id)
        #expect(loadedSessions.last?.name == session2.name)
        #expect(loadedSessions.last?.topicPrompt == "Test Topic")
        #expect(FileManager.default.fileExists(atPath: currentIndexFileURL.path))
        #expect(FileManager.default.fileExists(atPath: currentSessionFileURL(session1.id).path))
        #expect(FileManager.default.fileExists(atPath: currentSessionFileURL(session2.id).path))
        
        // Teardown
        cleanup(sessions: sessionsToSave)
    }

    @Test("Save and Load Session Folders with Session Assignment")
    func testSaveAndLoadSessionFoldersWithSessionAssignment() {
        let folder = SessionFolder(name: "工作")
        Persistence.saveSessionFolders([folder])

        let session = ChatSession(
            id: UUID(),
            name: "Folder Session",
            folderID: folder.id,
            isTemporary: false
        )
        Persistence.saveChatSessions([session])

        let loadedFolders = Persistence.loadSessionFolders()
        let loadedSessions = Persistence.loadChatSessions()

        #expect(loadedFolders.count == 1)
        #expect(loadedFolders.first?.id == folder.id)
        #expect(loadedSessions.count == 1)
        #expect(loadedSessions.first?.folderID == folder.id)

        cleanup(sessions: [session])
    }

    @Test("Save and Load Messages")
    func testSaveAndLoadMessages() {
        // 1. Arrange
        let sessionId = UUID()
        let requestedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let messagesToSave = [
            ChatMessage(role: .user, content: "Hello", requestedAt: requestedAt),
            ChatMessage(role: .assistant, content: "Hi there!")
        ]
        
        // 2. Act
        Persistence.saveMessages(messagesToSave, for: sessionId)
        let loadedMessages = Persistence.loadMessages(for: sessionId)
        
        // 3. Assert
        #expect(loadedMessages.count == messagesToSave.count)
        #expect(loadedMessages.first?.content == "Hello")
        #expect(loadedMessages.first?.requestedAt == requestedAt)
        #expect(loadedMessages.last?.role == .assistant)

        let sessionFileURL = currentSessionFileURL(sessionId)
        #expect(FileManager.default.fileExists(atPath: sessionFileURL.path))
        if let migratedData = try? Data(contentsOf: sessionFileURL),
           let record = try? JSONDecoder().decode(LegacySessionRecord.self, from: migratedData) {
            #expect(record.schemaVersion == 3)
            #expect(record.messages.count == 2)
            #expect(record.messages.first?.content == "Hello")
            #expect(record.messages.first?.requestedAt == requestedAt)
        } else {
            Issue.record("会话文件不存在或格式不正确。")
        }

        // Teardown
        cleanup(sessions: [ChatSession(id: sessionId, name: "cleanup", isTemporary: false)])
    }

    @Test("GRDB backend can count messages without loading full array")
    func testGRDBMessageCount() {
        let previousOverride = Persistence.grdbEnabledOverrideForTests
        Persistence.grdbEnabledOverrideForTests = true
        Persistence.resetGRDBStoreForTests()
        defer {
            Persistence.grdbEnabledOverrideForTests = previousOverride
            Persistence.resetGRDBStoreForTests()
        }

        let session = ChatSession(id: UUID(), name: "GRDB Count Session", isTemporary: false)
        let messages: [ChatMessage] = [
            ChatMessage(role: .user, content: "A"),
            ChatMessage(role: .assistant, content: "B"),
            ChatMessage(role: .assistant, content: "C")
        ]

        Persistence.saveChatSessions([session])
        Persistence.saveMessages(messages, for: session.id)

        let messageCount = Persistence.loadMessageCount(for: session.id)
        #expect(messageCount == 3)

        cleanup(sessions: [session])
    }

    @Test("GRDB saveMessages 仅增量更新变更行并支持位置变化")
    func testGRDBSaveMessagesUsesIncrementalWrites() {
        let previousOverride = Persistence.grdbEnabledOverrideForTests
        Persistence.grdbEnabledOverrideForTests = true
        Persistence.resetGRDBStoreForTests()
        defer {
            Persistence.grdbEnabledOverrideForTests = previousOverride
            Persistence.resetGRDBStoreForTests()
        }

        let session = ChatSession(id: UUID(), name: "增量写入会话", isTemporary: false)
        let messageA = ChatMessage(id: UUID(), role: .user, content: "A")
        let messageB = ChatMessage(id: UUID(), role: .assistant, content: "B")
        let messageC = ChatMessage(id: UUID(), role: .assistant, content: "C")

        Persistence.saveChatSessions([session])
        Persistence.saveMessages([messageA, messageB, messageC], for: session.id)

        let rowidBBefore = sqliteCount(
            chatStoreSQLiteURL,
            sql: "SELECT rowid FROM messages WHERE id = '\(messageB.id.uuidString)'"
        )
        let rowidCBefore = sqliteCount(
            chatStoreSQLiteURL,
            sql: "SELECT rowid FROM messages WHERE id = '\(messageC.id.uuidString)'"
        )

        let updatedMessageB = ChatMessage(id: messageB.id, role: .assistant, content: "B-updated")
        Persistence.saveMessages([updatedMessageB, messageC], for: session.id)

        let rowidBAfter = sqliteCount(
            chatStoreSQLiteURL,
            sql: "SELECT rowid FROM messages WHERE id = '\(messageB.id.uuidString)'"
        )
        let rowidCAfter = sqliteCount(
            chatStoreSQLiteURL,
            sql: "SELECT rowid FROM messages WHERE id = '\(messageC.id.uuidString)'"
        )

        #expect(rowidBBefore > 0)
        #expect(rowidCBefore > 0)
        #expect(rowidBAfter == rowidBBefore)
        #expect(rowidCAfter == rowidCBefore)
        #expect(
            sqliteCount(
                chatStoreSQLiteURL,
                sql: "SELECT COUNT(*) FROM messages WHERE session_id = '\(session.id.uuidString)'"
            ) == 2
        )

        let loaded = Persistence.loadMessages(for: session.id)
        #expect(loaded.map(\.id) == [messageB.id, messageC.id])
        #expect(loaded.map(\.content) == ["B-updated", "C"])

        cleanup(sessions: [session])
    }

    @Test("MemoryRawStore 保存时仅增量更新 SQLite 行")
    func testMemoryRawStoreUsesIncrementalWrites() throws {
        let previousOverride = Persistence.grdbEnabledOverrideForTests
        Persistence.grdbEnabledOverrideForTests = true
        Persistence.resetGRDBStoreForTests()
        defer {
            Persistence.grdbEnabledOverrideForTests = previousOverride
            Persistence.resetGRDBStoreForTests()
            cleanup(sessions: [])
        }

        cleanup(sessions: [])

        let memoryAID = UUID()
        let memoryBID = UUID()
        let createdAt = Date(timeIntervalSince1970: 1_710_000_000)
        let store = MemoryRawStore()

        let memoryA = MemoryItem(
            id: memoryAID,
            content: "记忆-A",
            embedding: [0.1, 0.2],
            createdAt: createdAt
        )
        let memoryB = MemoryItem(
            id: memoryBID,
            content: "记忆-B",
            embedding: [0.3, 0.4],
            createdAt: createdAt.addingTimeInterval(1)
        )
        try store.saveMemories([memoryA, memoryB])

        let rowidBBefore = sqliteCount(
            memoryStoreSQLiteURL,
            sql: "SELECT rowid FROM memory_items WHERE id = '\(memoryBID.uuidString)'"
        )

        let updatedMemoryA = MemoryItem(
            id: memoryAID,
            content: "记忆-A-已更新",
            embedding: [0.9, 0.8],
            createdAt: createdAt,
            updatedAt: createdAt.addingTimeInterval(10)
        )
        try store.saveMemories([updatedMemoryA, memoryB])

        let rowidBAfter = sqliteCount(
            memoryStoreSQLiteURL,
            sql: "SELECT rowid FROM memory_items WHERE id = '\(memoryBID.uuidString)'"
        )

        #expect(rowidBBefore > 0)
        #expect(rowidBAfter == rowidBBefore)
        #expect(sqliteCount(memoryStoreSQLiteURL, sql: "SELECT COUNT(*) FROM memory_items") == 2)

        let loaded = store.loadMemories()
        #expect(loaded.contains(where: { $0.id == memoryAID && $0.content == "记忆-A-已更新" }))
        #expect(loaded.contains(where: { $0.id == memoryBID && $0.content == "记忆-B" }))
    }

    @Test("GRDB 在仅收到临时会话快照时不会误删已有会话")
    func testGRDBSaveChatSessionsTemporarySnapshotFuse() {
        let previousOverride = Persistence.grdbEnabledOverrideForTests
        Persistence.grdbEnabledOverrideForTests = true
        Persistence.resetGRDBStoreForTests()
        defer {
            Persistence.grdbEnabledOverrideForTests = previousOverride
            Persistence.resetGRDBStoreForTests()
        }

        let existingSession = ChatSession(id: UUID(), name: "Existing Session", isTemporary: false)
        let existingMessages: [ChatMessage] = [
            ChatMessage(role: .user, content: "历史消息1"),
            ChatMessage(role: .assistant, content: "历史消息2")
        ]
        let temporarySession = ChatSession(id: UUID(), name: "新的对话", isTemporary: true)

        Persistence.saveChatSessions([existingSession])
        Persistence.saveMessages(existingMessages, for: existingSession.id)

        Persistence.saveChatSessions([temporarySession])

        let sessionsAfter = Persistence.loadChatSessions()
        #expect(sessionsAfter.contains(where: { $0.id == existingSession.id }))
        #expect(!sessionsAfter.contains(where: { $0.id == temporarySession.id }))

        let messagesAfter = Persistence.loadMessages(for: existingSession.id)
        #expect(messagesAfter.map(\.content) == existingMessages.map(\.content))

        cleanup(sessions: [existingSession])
    }

    @Test("GRDB 辅助 Blob 可读写并删除")
    func testGRDBAuxiliaryBlobLifecycle() {
        let previousOverride = Persistence.grdbEnabledOverrideForTests
        Persistence.grdbEnabledOverrideForTests = true
        Persistence.resetGRDBStoreForTests()
        defer {
            _ = Persistence.removeAuxiliaryBlob(forKey: "test_auxiliary_blob")
            Persistence.grdbEnabledOverrideForTests = previousOverride
            Persistence.resetGRDBStoreForTests()
            cleanup(sessions: [])
        }

        cleanup(sessions: [])
        let payload: [String: Int] = ["a": 1, "b": 2]
        let key = "test_auxiliary_blob"

        #expect(Persistence.saveAuxiliaryBlob(payload, forKey: key))
        #expect(Persistence.auxiliaryBlobExists(forKey: key))

        let loaded = Persistence.loadAuxiliaryBlob([String: Int].self, forKey: key)
        #expect(loaded == payload)

        #expect(Persistence.removeAuxiliaryBlob(forKey: key))
        #expect(!Persistence.auxiliaryBlobExists(forKey: key))
    }

    @Test("记忆存储在 SQLite 为空时会回退读取 legacy JSON 并补录")
    func testMemoryRawStoreFallbackToLegacyJSONWhenSQLiteEmpty() throws {
        cleanup(sessions: [])

        let previousOverride = Persistence.grdbEnabledOverrideForTests
        Persistence.grdbEnabledOverrideForTests = true
        Persistence.resetGRDBStoreForTests()
        defer {
            Persistence.grdbEnabledOverrideForTests = previousOverride
            Persistence.resetGRDBStoreForTests()
            cleanup(sessions: [])
        }

        try FileManager.default.createDirectory(at: memoryDirectory, withIntermediateDirectories: true)

        let legacyMemories = [
            MemoryItem(
                id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                content: "legacy-memory-entry",
                embedding: [],
                createdAt: Date(timeIntervalSince1970: 1_710_000_000)
            )
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let legacyData = try encoder.encode(legacyMemories)
        try legacyData.write(to: memoryRawMemoriesFileURL, options: .atomic)

        let loaded = MemoryRawStore().loadMemories()
        #expect(loaded.map(\.id) == legacyMemories.map(\.id))
        #expect(loaded.map(\.content) == legacyMemories.map(\.content))

        #expect(sqliteCount(memoryStoreSQLiteURL, sql: "SELECT COUNT(*) FROM memory_items") == legacyMemories.count)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let mirroredData = try Data(contentsOf: memoryRawMemoriesFileURL)
        let mirrored = try decoder.decode([MemoryItem].self, from: mirroredData)
        #expect(mirrored.map(\.id) == legacyMemories.map(\.id))
        #expect(mirrored.map(\.content) == legacyMemories.map(\.content))
    }

    @Test("快捷指令在 SQLite 为空时会回退读取 legacy JSON 并补录")
    func testShortcutToolsFallbackToLegacyJSONWhenSQLiteEmpty() throws {
        cleanup(sessions: [])

        let previousOverride = Persistence.grdbEnabledOverrideForTests
        Persistence.grdbEnabledOverrideForTests = true
        Persistence.resetGRDBStoreForTests()
        defer {
            Persistence.grdbEnabledOverrideForTests = previousOverride
            Persistence.resetGRDBStoreForTests()
            cleanup(sessions: [])
        }

        try FileManager.default.createDirectory(at: shortcutToolsDirectory, withIntermediateDirectories: true)

        let legacyTools = [
            ShortcutToolDefinition(
                id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                name: "legacy-shortcut-tool",
                metadata: ["displayName": .string("Legacy Tool")],
                source: "legacy-json",
                runModeHint: .bridge,
                isEnabled: true,
                generatedDescription: "legacy tool description",
                createdAt: Date(timeIntervalSince1970: 1_710_000_100),
                updatedAt: Date(timeIntervalSince1970: 1_710_000_100),
                lastImportedAt: Date(timeIntervalSince1970: 1_710_000_100)
            )
        ]
        let legacyData = try JSONEncoder().encode(legacyTools)
        try legacyData.write(to: shortcutToolsFileURL, options: .atomic)

        let loaded = ShortcutToolStore.loadTools()
        #expect(loaded.map(\.id) == legacyTools.map(\.id))
        #expect(loaded.map(\.name) == legacyTools.map(\.name))

        #expect(sqliteCount(configStoreSQLiteURL, sql: "SELECT COUNT(*) FROM shortcut_tools") == legacyTools.count)
        #expect(!FileManager.default.fileExists(atPath: shortcutToolsFileURL.path))
    }

    @Test("用户画像在 SQLite 为空时会回退读取 legacy JSON 并补录")
    func testConversationProfileFallbackToLegacyJSONWhenSQLiteEmpty() throws {
        cleanup(sessions: [])

        let previousOverride = Persistence.grdbEnabledOverrideForTests
        Persistence.grdbEnabledOverrideForTests = true
        Persistence.resetGRDBStoreForTests()
        defer {
            Persistence.grdbEnabledOverrideForTests = previousOverride
            Persistence.resetGRDBStoreForTests()
            cleanup(sessions: [])
        }

        try FileManager.default.createDirectory(at: memoryDirectory, withIntermediateDirectories: true)

        let legacyProfile = ConversationUserProfile(
            content: "legacy-user-profile",
            updatedAt: Date(timeIntervalSince1970: 1_710_000_200),
            sourceSessionID: UUID(uuidString: "33333333-3333-3333-3333-333333333333")
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let profileData = try encoder.encode(legacyProfile)
        try profileData.write(to: memoryUserProfileFileURL, options: .atomic)

        let loaded = ConversationMemoryManager.loadUserProfile()
        #expect(loaded?.content == legacyProfile.content)
        #expect(loaded?.updatedAt == legacyProfile.updatedAt)
        #expect(loaded?.sourceSessionID == legacyProfile.sourceSessionID)

        #expect(sqliteCount(memoryStoreSQLiteURL, sql: "SELECT COUNT(*) FROM conversation_user_profile") == 1)
        #expect(!FileManager.default.fileExists(atPath: memoryUserProfileFileURL.path))
    }

    @Test("GRDB 启动迁移后自动清理旧 JSON 会话文件")
    func testBootstrapGRDBImportAndCleanupLegacyJSON() throws {
        cleanup(sessions: [])

        let sessionID = UUID()
        let legacySession = ChatSession(id: sessionID, name: "Legacy JSON Session", isTemporary: false)
        let legacyMessages = [
            ChatMessage(role: .user, content: "legacy-user"),
            ChatMessage(role: .assistant, content: "legacy-assistant")
        ]

        let legacySessionsData = try JSONEncoder().encode([legacySession])
        try legacySessionsData.write(to: legacySessionsIndexURL, options: .atomic)

        let legacyMessagesData = try JSONEncoder().encode(legacyMessages)
        try legacyMessagesData.write(to: legacyMessageFileURL(sessionID), options: .atomic)

        let previousOverride = Persistence.grdbEnabledOverrideForTests
        Persistence.grdbEnabledOverrideForTests = true
        Persistence.resetGRDBStoreForTests()
        defer {
            Persistence.grdbEnabledOverrideForTests = previousOverride
            Persistence.resetGRDBStoreForTests()
            cleanup(sessions: [legacySession])
        }

        Persistence.bootstrapGRDBStoreOnLaunch()

        let loadedSessions = Persistence.loadChatSessions()
        #expect(loadedSessions.contains(where: { $0.id == sessionID }))

        let loadedMessages = Persistence.loadMessages(for: sessionID)
        #expect(loadedMessages.map(\.content) == ["legacy-user", "legacy-assistant"])

        #expect(FileManager.default.fileExists(atPath: chatStoreSQLiteURL.path))
        #expect(!FileManager.default.fileExists(atPath: legacySessionsIndexURL.path))
        #expect(!FileManager.default.fileExists(atPath: legacyMessageFileURL(sessionID).path))
    }

    @Test("启动备份会裁剪 chat-store 的 FTS 结构")
    func testLaunchBackupCreatesSlimChatStoreBackup() {
        cleanup(sessions: [])

        let defaults = UserDefaults.standard
        let previousBackupEnabled = defaults.object(forKey: Persistence.launchBackupEnabledKey)
        let previousOverride = Persistence.grdbEnabledOverrideForTests
        let session = ChatSession(id: UUID(), name: "Launch Backup Session", isTemporary: false)
        let messages = [
            ChatMessage(role: .user, content: "launch-backup-user"),
            ChatMessage(role: .assistant, content: "launch-backup-assistant")
        ]

        defaults.set(true, forKey: Persistence.launchBackupEnabledKey)
        Persistence.grdbEnabledOverrideForTests = true
        Persistence.resetGRDBStoreForTests()
        defer {
            if let previousBackupEnabled = previousBackupEnabled as? Bool {
                defaults.set(previousBackupEnabled, forKey: Persistence.launchBackupEnabledKey)
            } else {
                defaults.removeObject(forKey: Persistence.launchBackupEnabledKey)
            }
            Persistence.grdbEnabledOverrideForTests = previousOverride
            Persistence.resetGRDBStoreForTests()
            cleanup(sessions: [session])
        }

        Persistence.saveChatSessions([session])
        Persistence.saveMessages(messages, for: session.id)
        Persistence.bootstrapGRDBStoreOnLaunch()

        #expect(FileManager.default.fileExists(atPath: chatStoreBackupSQLiteURL.path))
        #expect(!sqliteExists(chatStoreBackupSQLiteURL, sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'messages_fts'"))
        #expect(!sqliteExists(chatStoreBackupSQLiteURL, sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger' AND name = 'messages_ai'"))
        #expect(!sqliteExists(chatStoreBackupSQLiteURL, sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger' AND name = 'messages_ad'"))
        #expect(!sqliteExists(chatStoreBackupSQLiteURL, sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger' AND name = 'messages_au'"))
        #expect(sqliteCount(chatStoreBackupSQLiteURL, sql: "SELECT COUNT(*) FROM messages") == messages.count)
    }

    @Test("启动检测到 chat-store 损坏时会按备份重建并重建 FTS")
    func testLaunchBackupRestoresCorruptedChatStoreAndRebuildsFTS() throws {
        cleanup(sessions: [])

        let defaults = UserDefaults.standard
        let previousBackupEnabled = defaults.object(forKey: Persistence.launchBackupEnabledKey)
        let previousOverride = Persistence.grdbEnabledOverrideForTests
        let session = ChatSession(id: UUID(), name: "Corrupted Launch Session", isTemporary: false)
        let messages = [
            ChatMessage(role: .user, content: "recover-user"),
            ChatMessage(role: .assistant, content: "recover-assistant")
        ]

        defaults.set(true, forKey: Persistence.launchBackupEnabledKey)
        Persistence.grdbEnabledOverrideForTests = true
        Persistence.resetGRDBStoreForTests()
        defer {
            if let previousBackupEnabled = previousBackupEnabled as? Bool {
                defaults.set(previousBackupEnabled, forKey: Persistence.launchBackupEnabledKey)
            } else {
                defaults.removeObject(forKey: Persistence.launchBackupEnabledKey)
            }
            Persistence.grdbEnabledOverrideForTests = previousOverride
            Persistence.resetGRDBStoreForTests()
            cleanup(sessions: [session])
        }

        Persistence.saveChatSessions([session])
        Persistence.saveMessages(messages, for: session.id)
        Persistence.bootstrapGRDBStoreOnLaunch()
        #expect(FileManager.default.fileExists(atPath: chatStoreBackupSQLiteURL.path))

        removeIfExists(chatStoreSQLiteWALURL)
        removeIfExists(chatStoreSQLiteSHMURL)
        try Data([0x00, 0x01, 0x02, 0x03, 0x04]).write(to: chatStoreSQLiteURL, options: .atomic)

        Persistence.resetGRDBStoreForTests()
        Persistence.bootstrapGRDBStoreOnLaunch()

        let restoredMessages = Persistence.loadMessages(for: session.id)
        #expect(restoredMessages.map(\.content) == messages.map(\.content))
        let recoveryNotice = Persistence.consumeLaunchRecoveryNotice()
        #expect(recoveryNotice?.contains("聊天数据库") == true)
        #expect(sqliteCount(chatStoreSQLiteURL, sql: "SELECT COUNT(*) FROM messages_fts") == messages.count)
        #expect(sqliteExists(chatStoreSQLiteURL, sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger' AND name = 'messages_ai'"))
        #expect(sqliteExists(chatStoreSQLiteURL, sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger' AND name = 'messages_ad'"))
        #expect(sqliteExists(chatStoreSQLiteURL, sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger' AND name = 'messages_au'"))
    }

    @Test("旧 JSON 快照消息为零且数据库已有消息时不会覆盖与清理")
    func testBootstrapGRDBSkipsZeroMessageSnapshotWhenDatabaseHasMessages() throws {
        cleanup(sessions: [])

        let sessionID = UUID()
        let persistedSession = ChatSession(id: sessionID, name: "Persisted Session", isTemporary: false)
        let persistedMessages = [
            ChatMessage(role: .user, content: "db-user"),
            ChatMessage(role: .assistant, content: "db-assistant")
        ]

        let previousOverride = Persistence.grdbEnabledOverrideForTests
        Persistence.grdbEnabledOverrideForTests = true
        Persistence.resetGRDBStoreForTests()
        defer {
            Persistence.grdbEnabledOverrideForTests = previousOverride
            Persistence.resetGRDBStoreForTests()
            cleanup(sessions: [persistedSession])
        }

        Persistence.saveChatSessions([persistedSession])
        Persistence.saveMessages(persistedMessages, for: sessionID)

        let legacySessionsData = try JSONEncoder().encode([persistedSession])
        try legacySessionsData.write(to: legacySessionsIndexURL, options: .atomic)
        let emptyLegacyMessagesData = try JSONEncoder().encode([ChatMessage]())
        try emptyLegacyMessagesData.write(to: legacyMessageFileURL(sessionID), options: .atomic)

        Persistence.resetGRDBStoreForTests()
        Persistence.bootstrapGRDBStoreOnLaunch()

        let loadedMessages = Persistence.loadMessages(for: sessionID)
        #expect(loadedMessages.map(\.content) == persistedMessages.map(\.content))
        #expect(FileManager.default.fileExists(atPath: legacySessionsIndexURL.path))
        #expect(FileManager.default.fileExists(atPath: legacyMessageFileURL(sessionID).path))
    }

    @Test("旧 JSON 快照有消息且数据库已有消息时不会触发覆盖导入")
    func testBootstrapGRDBSkipsImportWhenDatabaseAlreadyHasMessages() throws {
        cleanup(sessions: [])

        let sessionID = UUID()
        let persistedSession = ChatSession(id: sessionID, name: "Persisted Session", isTemporary: false)
        let persistedMessages = [
            ChatMessage(role: .user, content: "db-user"),
            ChatMessage(role: .assistant, content: "db-assistant")
        ]
        let legacyMessages = [
            ChatMessage(role: .user, content: "legacy-user")
        ]

        let previousOverride = Persistence.grdbEnabledOverrideForTests
        Persistence.grdbEnabledOverrideForTests = true
        Persistence.resetGRDBStoreForTests()
        defer {
            Persistence.grdbEnabledOverrideForTests = previousOverride
            Persistence.resetGRDBStoreForTests()
            cleanup(sessions: [persistedSession])
        }

        Persistence.saveChatSessions([persistedSession])
        Persistence.saveMessages(persistedMessages, for: sessionID)

        let legacySessionsData = try JSONEncoder().encode([persistedSession])
        try legacySessionsData.write(to: legacySessionsIndexURL, options: .atomic)
        let legacyMessagesData = try JSONEncoder().encode(legacyMessages)
        try legacyMessagesData.write(to: legacyMessageFileURL(sessionID), options: .atomic)

        Persistence.resetGRDBStoreForTests()
        Persistence.bootstrapGRDBStoreOnLaunch()

        let loadedMessages = Persistence.loadMessages(for: sessionID)
        #expect(loadedMessages.map(\.content) == persistedMessages.map(\.content))
        #expect(FileManager.default.fileExists(atPath: legacySessionsIndexURL.path))
        #expect(FileManager.default.fileExists(atPath: legacyMessageFileURL(sessionID).path))
    }

    @Test("旧 JSON 快照已导入但缺少标记时会自动清理遗留 JSON")
    func testBootstrapGRDBCleansLegacyJSONWhenSnapshotAlreadyImportedWithoutMeta() throws {
        cleanup(sessions: [])

        let sessionID = UUID()
        let persistedSession = ChatSession(id: sessionID, name: "Persisted Session", isTemporary: false)
        let persistedMessages = [
            ChatMessage(role: .user, content: "db-user"),
            ChatMessage(role: .assistant, content: "db-assistant")
        ]

        let previousOverride = Persistence.grdbEnabledOverrideForTests
        Persistence.grdbEnabledOverrideForTests = true
        Persistence.resetGRDBStoreForTests()
        defer {
            Persistence.grdbEnabledOverrideForTests = previousOverride
            Persistence.resetGRDBStoreForTests()
            cleanup(sessions: [persistedSession])
        }

        Persistence.saveChatSessions([persistedSession])
        Persistence.saveMessages(persistedMessages, for: sessionID)

        let legacySessionsData = try JSONEncoder().encode([persistedSession])
        try legacySessionsData.write(to: legacySessionsIndexURL, options: .atomic)
        let legacyMessagesData = try JSONEncoder().encode(persistedMessages)
        try legacyMessagesData.write(to: legacyMessageFileURL(sessionID), options: .atomic)

        sqliteExecute(
            chatStoreSQLiteURL,
            sql: """
            DELETE FROM meta
            WHERE key IN ('json_import_completed', 'json_cleanup_completed', 'json_import_completed_v1', 'json_cleanup_completed_v1')
            """
        )
        #expect(sqliteCount(chatStoreSQLiteURL, sql: "SELECT COUNT(*) FROM meta WHERE key = 'json_import_completed'") == 0)
        #expect(sqliteCount(chatStoreSQLiteURL, sql: "SELECT COUNT(*) FROM meta WHERE key = 'json_cleanup_completed'") == 0)

        Persistence.resetGRDBStoreForTests()
        Persistence.bootstrapGRDBStoreOnLaunch()

        let loadedMessages = Persistence.loadMessages(for: sessionID)
        #expect(loadedMessages.map(\.content) == persistedMessages.map(\.content))
        #expect(!FileManager.default.fileExists(atPath: legacySessionsIndexURL.path))
        #expect(!FileManager.default.fileExists(atPath: legacyMessageFileURL(sessionID).path))
        #expect(sqliteCount(chatStoreSQLiteURL, sql: "SELECT COUNT(*) FROM meta WHERE key = 'json_import_completed' AND value = '1'") == 1)
        #expect(sqliteCount(chatStoreSQLiteURL, sql: "SELECT COUNT(*) FROM meta WHERE key = 'json_cleanup_completed' AND value = '1'") == 1)
    }

    @Test("跨会话重复消息ID不会阻止 GRDB 启动迁移清理旧 JSON")
    func testBootstrapGRDBMigratesDuplicateMessageIDsAcrossSessions() throws {
        cleanup(sessions: [])

        let duplicatedMessageID = UUID()
        let firstSession = ChatSession(id: UUID(), name: "First Session", isTemporary: false)
        let secondSession = ChatSession(id: UUID(), name: "Second Session", isTemporary: false)

        let firstMessages = [
            ChatMessage(id: duplicatedMessageID, role: .user, content: "first-user"),
            ChatMessage(role: .assistant, content: "first-assistant")
        ]
        let secondMessages = [
            ChatMessage(id: duplicatedMessageID, role: .user, content: "second-user"),
            ChatMessage(role: .assistant, content: "second-assistant")
        ]

        let legacySessionsData = try JSONEncoder().encode([firstSession, secondSession])
        try legacySessionsData.write(to: legacySessionsIndexURL, options: .atomic)
        try JSONEncoder().encode(firstMessages).write(to: legacyMessageFileURL(firstSession.id), options: .atomic)
        try JSONEncoder().encode(secondMessages).write(to: legacyMessageFileURL(secondSession.id), options: .atomic)

        let previousOverride = Persistence.grdbEnabledOverrideForTests
        Persistence.grdbEnabledOverrideForTests = true
        Persistence.resetGRDBStoreForTests()
        defer {
            Persistence.grdbEnabledOverrideForTests = previousOverride
            Persistence.resetGRDBStoreForTests()
            cleanup(sessions: [firstSession, secondSession])
        }

        Persistence.bootstrapGRDBStoreOnLaunch()

        let loadedFirst = Persistence.loadMessages(for: firstSession.id)
        let loadedSecond = Persistence.loadMessages(for: secondSession.id)
        #expect(loadedFirst.map(\.content) == firstMessages.map(\.content))
        #expect(loadedSecond.map(\.content) == secondMessages.map(\.content))
        #expect(sqliteCount(chatStoreSQLiteURL, sql: "SELECT COUNT(*) FROM messages") == firstMessages.count + secondMessages.count)
        #expect(!FileManager.default.fileExists(atPath: legacySessionsIndexURL.path))
        #expect(!FileManager.default.fileExists(atPath: legacyMessageFileURL(firstSession.id).path))
        #expect(!FileManager.default.fileExists(atPath: legacyMessageFileURL(secondSession.id).path))
    }

    @Test("GRDB 在缺失会话索引时不会清理孤立消息 JSON 文件")
    func testBootstrapGRDBKeepsOrphanLegacyMessageJSONWithoutIndex() throws {
        struct LegacyRequestLogEnvelope: Encodable {
            let schemaVersion: Int
            let updatedAt: String
            let logs: [RequestLogEntry]
        }

        cleanup(sessions: [])

        let orphanSessionID = UUID()
        let orphanMessages = [
            ChatMessage(role: .user, content: "orphan-user"),
            ChatMessage(role: .assistant, content: "orphan-assistant")
        ]
        let orphanData = try JSONEncoder().encode(orphanMessages)
        try orphanData.write(to: legacyMessageFileURL(orphanSessionID), options: .atomic)

        try FileManager.default.createDirectory(
            at: requestLogsDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )
        let requestLog = RequestLogEntry(
            requestID: UUID(),
            sessionID: nil,
            providerID: nil,
            providerName: "migration-guard",
            modelID: "guard-model",
            requestedAt: Date(timeIntervalSince1970: 1_700_300_000),
            finishedAt: Date(timeIntervalSince1970: 1_700_300_001),
            isStreaming: false,
            status: .success,
            tokenUsage: nil
        )
        let legacyRequestLogData = try JSONEncoder().encode(
            LegacyRequestLogEnvelope(
                schemaVersion: 1,
                updatedAt: ISO8601DateFormatter().string(from: Date()),
                logs: [requestLog]
            )
        )
        try legacyRequestLogData.write(to: requestLogsDirectory.appendingPathComponent("index.json"), options: .atomic)

        let previousOverride = Persistence.grdbEnabledOverrideForTests
        Persistence.grdbEnabledOverrideForTests = true
        Persistence.resetGRDBStoreForTests()
        defer {
            Persistence.grdbEnabledOverrideForTests = previousOverride
            Persistence.resetGRDBStoreForTests()
            removeIfExists(legacyMessageFileURL(orphanSessionID))
            cleanup(sessions: [])
        }

        Persistence.bootstrapGRDBStoreOnLaunch()

        #expect(FileManager.default.fileExists(atPath: chatStoreSQLiteURL.path))
        #expect(FileManager.default.fileExists(atPath: legacyMessageFileURL(orphanSessionID).path))
    }

    @Test("Migrate Legacy Session Store To Current Layout And Cleanup Legacy Files")
    func testMigrateLegacySessionStoreToCurrentLayoutAndCleanupLegacyFiles() throws {
        let sessionId = UUID()
        let legacySession = ChatSession(
            id: sessionId,
            name: "Legacy Session",
            topicPrompt: "legacy-topic",
            enhancedPrompt: "legacy-enhanced",
            isTemporary: false
        )
        let legacyMessages = [
            ChatMessage(role: .user, content: "legacy-user"),
            ChatMessage(role: .assistant, content: "legacy-assistant")
        ]

        removeIfExists(currentIndexFileURL)
        removeIfExists(currentSessionsDirectory)
        removeIfExists(legacySessionDirectory)
        removeIfExists(legacyRootDirectory)
        removeIfExists(legacySessionsIndexURL)
        removeIfExists(legacyMessageFileURL(sessionId))

        let legacySessionsData = try JSONEncoder().encode([legacySession])
        try legacySessionsData.write(to: legacySessionsIndexURL, options: .atomic)
        let legacyMessagesData = try JSONEncoder().encode(legacyMessages)
        try legacyMessagesData.write(to: legacyMessageFileURL(sessionId), options: .atomic)

        let loadedSessions = Persistence.loadChatSessions()
        #expect(loadedSessions.count == 1)
        #expect(loadedSessions.first?.id == sessionId)
        #expect(loadedSessions.first?.topicPrompt == "legacy-topic")
        #expect(loadedSessions.first?.enhancedPrompt == "legacy-enhanced")

        let loadedMessages = Persistence.loadMessages(for: sessionId)
        #expect(loadedMessages.map(\.content) == ["legacy-user", "legacy-assistant"])

        let migratedFileURL = currentSessionFileURL(sessionId)
        #expect(FileManager.default.fileExists(atPath: migratedFileURL.path))
        let migratedData = try Data(contentsOf: migratedFileURL)
        let record = try JSONDecoder().decode(LegacySessionRecord.self, from: migratedData)
        #expect(record.schemaVersion == 3)
        #expect(record.session.id == sessionId)
        #expect(record.session.name == "Legacy Session")
        #expect(record.prompts.topicPrompt == "legacy-topic")
        #expect(record.prompts.enhancedPrompt == "legacy-enhanced")
        #expect(record.messages.last?.content == "legacy-assistant")

        #expect(!FileManager.default.fileExists(atPath: legacySessionsIndexURL.path))
        #expect(!FileManager.default.fileExists(atPath: legacyMessageFileURL(sessionId).path))
        #expect(!FileManager.default.fileExists(atPath: legacyRootDirectory.path))

        cleanup(sessions: [legacySession])
    }

    @Test("Migrate Legacy Directory To Root Layout And Delete Old Folder")
    func testMigrateLegacyDirectoryToRootLayoutAndDeleteOldFolder() throws {
        struct LegacySessionIndexFile: Encodable {
            struct Item: Encodable {
                let id: UUID
                let name: String
                let updatedAt: String
            }

            let schemaVersion: Int
            let updatedAt: String
            let sessions: [Item]
        }

        struct LegacySessionRecordFile: Encodable {
            struct SessionMeta: Encodable {
                let id: UUID
                let name: String
                let lorebookIDs: [UUID]
            }

            struct Prompts: Encodable {
                let topicPrompt: String?
                let enhancedPrompt: String?
            }

            let schemaVersion: Int
            let session: SessionMeta
            let prompts: Prompts
            let messages: [ChatMessage]
        }

        let sessionId = UUID()
        let sessionName = "Legacy Session"
        let now = ISO8601DateFormatter().string(from: Date())
        let messages = [
            ChatMessage(role: .user, content: "from-legacy-user"),
            ChatMessage(role: .assistant, content: "from-legacy-assistant")
        ]

        removeIfExists(currentIndexFileURL)
        removeIfExists(currentSessionsDirectory)
        removeIfExists(legacySessionDirectory)
        removeIfExists(legacySessionsIndexURL)
        removeIfExists(legacyRootDirectory)
        removeIfExists(legacyMessageFileURL(sessionId))

        try FileManager.default.createDirectory(
            at: legacySessionFileURL(sessionId).deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )

        let index = LegacySessionIndexFile(
            schemaVersion: 3,
            updatedAt: now,
            sessions: [.init(id: sessionId, name: sessionName, updatedAt: now)]
        )
        let indexData = try JSONEncoder().encode(index)
        try indexData.write(to: legacySessionIndexFileURL, options: .atomic)

        let recordData = try JSONEncoder().encode(
            LegacySessionRecordFile(
                schemaVersion: 3,
                session: .init(id: sessionId, name: sessionName, lorebookIDs: []),
                prompts: .init(topicPrompt: nil, enhancedPrompt: nil),
                messages: messages
            )
        )
        try recordData.write(to: legacySessionFileURL(sessionId), options: .atomic)

        let loadedSessions = Persistence.loadChatSessions()
        #expect(loadedSessions.count == 1)
        #expect(loadedSessions.first?.id == sessionId)
        #expect(loadedSessions.first?.name == sessionName)

        let loadedMessages = Persistence.loadMessages(for: sessionId)
        #expect(loadedMessages.map(\.content) == ["from-legacy-user", "from-legacy-assistant"])

        #expect(FileManager.default.fileExists(atPath: currentIndexFileURL.path))
        #expect(FileManager.default.fileExists(atPath: currentSessionFileURL(sessionId).path))
        #expect(!FileManager.default.fileExists(atPath: legacySessionDirectory.path))

        cleanup(sessions: [ChatSession(id: sessionId, name: sessionName, isTemporary: false)])
    }

    @Test("Append and Load Request Logs")
    func testAppendAndLoadRequestLogs() {
        cleanup(sessions: [])

        let requestA = RequestLogEntry(
            requestID: UUID(),
            sessionID: UUID(),
            providerID: UUID(),
            providerName: "OpenAI",
            modelID: "gpt-5",
            requestedAt: Date(timeIntervalSince1970: 1_700_000_000),
            finishedAt: Date(timeIntervalSince1970: 1_700_000_002),
            isStreaming: true,
            status: .success,
            tokenUsage: MessageTokenUsage(
                promptTokens: 100,
                completionTokens: 50,
                totalTokens: 150,
                thinkingTokens: 10,
                cacheWriteTokens: 0,
                cacheReadTokens: 0
            )
        )
        let requestB = RequestLogEntry(
            requestID: UUID(),
            sessionID: UUID(),
            providerID: UUID(),
            providerName: "Anthropic",
            modelID: "claude-sonnet-4",
            requestedAt: Date(timeIntervalSince1970: 1_700_000_010),
            finishedAt: Date(timeIntervalSince1970: 1_700_000_012),
            isStreaming: false,
            status: .failed,
            tokenUsage: nil
        )

        Persistence.appendRequestLog(requestA)
        Persistence.appendRequestLog(requestB)

        let queryWindow = RequestLogQuery(
            from: Date(timeIntervalSince1970: 1_699_999_999),
            to: Date(timeIntervalSince1970: 1_700_000_100)
        )
        let loaded = Persistence.loadRequestLogs(query: queryWindow)
        #expect(loaded.count == 2)
        #expect(loaded.first?.providerName == "Anthropic")
        #expect(loaded.last?.providerName == "OpenAI")
        #expect(loaded.last?.tokenUsage?.thinkingTokens == 10)

        let successOnly = Persistence.loadRequestLogs(
            query: .init(
                from: queryWindow.from,
                to: queryWindow.to,
                statuses: Set([.success])
            )
        )
        #expect(successOnly.count == 1)
        #expect(successOnly.first?.modelID == "gpt-5")

        cleanup(sessions: [])
    }

    @Test("Summarize Request Logs")
    func testSummarizeRequestLogs() {
        cleanup(sessions: [])

        let now = Date(timeIntervalSince1970: 1_700_100_000)
        let entries: [RequestLogEntry] = [
            .init(
                requestID: UUID(),
                sessionID: UUID(),
                providerID: UUID(),
                providerName: "OpenAI",
                modelID: "gpt-5",
                requestedAt: now,
                finishedAt: now.addingTimeInterval(1),
                isStreaming: true,
                status: .success,
                tokenUsage: .init(
                    promptTokens: 10,
                    completionTokens: 20,
                    totalTokens: 30,
                    thinkingTokens: 2,
                    cacheWriteTokens: nil,
                    cacheReadTokens: nil
                )
            ),
            .init(
                requestID: UUID(),
                sessionID: UUID(),
                providerID: UUID(),
                providerName: "OpenAI",
                modelID: "gpt-5",
                requestedAt: now.addingTimeInterval(2),
                finishedAt: now.addingTimeInterval(3),
                isStreaming: true,
                status: .failed,
                tokenUsage: nil
            ),
            .init(
                requestID: UUID(),
                sessionID: UUID(),
                providerID: UUID(),
                providerName: "Anthropic",
                modelID: "claude-sonnet-4",
                requestedAt: now.addingTimeInterval(4),
                finishedAt: now.addingTimeInterval(5),
                isStreaming: false,
                status: .cancelled,
                tokenUsage: .init(
                    promptTokens: 5,
                    completionTokens: 7,
                    totalTokens: nil,
                    thinkingTokens: nil,
                    cacheWriteTokens: 3,
                    cacheReadTokens: 4
                )
            )
        ]

        for entry in entries {
            Persistence.appendRequestLog(entry)
        }

        let summary = Persistence.summarizeRequestLogs(
            query: .init(
                from: now.addingTimeInterval(-1),
                to: now.addingTimeInterval(10)
            )
        )
        #expect(summary.totalRequests == 3)
        #expect(summary.successCount == 1)
        #expect(summary.failedCount == 1)
        #expect(summary.cancelledCount == 1)
        #expect(summary.tokenTotals.sentTokens == 15)
        #expect(summary.tokenTotals.receivedTokens == 27)
        #expect(summary.tokenTotals.thinkingTokens == 2)
        #expect(summary.tokenTotals.cacheWriteTokens == 3)
        #expect(summary.tokenTotals.cacheReadTokens == 4)
        #expect(summary.tokenTotals.totalTokens == 30)
        #expect(summary.byProvider.count == 2)
        #expect(summary.byModel.count == 2)

        cleanup(sessions: [])
    }

    @Test("Request Logs Retention Limit")
    func testRequestLogsRetentionLimit() {
        cleanup(sessions: [])

        let retentionLimit = 100
        Persistence.requestLogRetentionLimitOverride = retentionLimit
        defer { Persistence.requestLogRetentionLimitOverride = nil }

        let total = 120
        let dropped = total - retentionLimit
        let baseDate = Date(timeIntervalSince1970: 1_700_200_000)
        for index in 0..<total {
            let time = baseDate.addingTimeInterval(TimeInterval(index))
            Persistence.appendRequestLog(
                .init(
                    requestID: UUID(),
                    sessionID: UUID(),
                    providerID: UUID(),
                    providerName: "Retention",
                    modelID: "model-\(index)",
                    requestedAt: time,
                    finishedAt: time.addingTimeInterval(0.1),
                    isStreaming: false,
                    status: .success,
                    tokenUsage: nil
                )
            )
        }

        let loaded = Persistence.loadRequestLogs(
            query: .init(
                from: baseDate.addingTimeInterval(-1),
                to: baseDate.addingTimeInterval(TimeInterval(total + 1))
            )
        )
        #expect(loaded.count == retentionLimit)
        #expect(loaded.first?.modelID == "model-\(total - 1)")
        #expect(loaded.last?.modelID == "model-\(dropped)")

        cleanup(sessions: [])
    }
}

@Suite("ConfigLoader Tests")
fileprivate struct ConfigLoaderTests {
    private struct LegacyProviderSnapshot: Encodable {
        let id: UUID
        let name: String
        let baseURL: String
        let apiKeys: [String]
        let apiFormat: String
        let models: [Model]
        let headerOverrides: [String: String]
    }

    private struct LegacyProviderWithoutAPIKeysSnapshot: Encodable {
        let id: UUID
        let name: String
        let baseURL: String
        let apiFormat: String
        let models: [Model]
        let headerOverrides: [String: String]
    }
    
    // Clean up provider files
    private func cleanup(providers: [Provider]) {
        for provider in providers {
             ConfigLoader.deleteProvider(provider)
        }
    }

    private var providersDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Providers")
    }

    private func providerFileURL(for providerID: UUID) -> URL {
        providersDirectory.appendingPathComponent("\(providerID.uuidString).json")
    }

    private func writeLegacyProviderFile(_ provider: Provider, fileName: String) throws {
        ConfigLoader.setupInitialProviderConfigs()
        let fileURL = providersDirectory.appendingPathComponent(fileName)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let snapshot = LegacyProviderSnapshot(
            id: provider.id,
            name: provider.name,
            baseURL: provider.baseURL,
            apiKeys: provider.apiKeys,
            apiFormat: provider.apiFormat,
            models: provider.models,
            headerOverrides: provider.headerOverrides
        )
        let data = try encoder.encode(snapshot)
        try data.write(to: fileURL, options: .atomic)
    }

    private func writeLegacyProviderFileWithoutAPIKeys(_ provider: Provider, fileName: String) throws {
        ConfigLoader.setupInitialProviderConfigs()
        let fileURL = providersDirectory.appendingPathComponent(fileName)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let snapshot = LegacyProviderWithoutAPIKeysSnapshot(
            id: provider.id,
            name: provider.name,
            baseURL: provider.baseURL,
            apiFormat: provider.apiFormat,
            models: provider.models,
            headerOverrides: provider.headerOverrides
        )
        let data = try encoder.encode(snapshot)
        try data.write(to: fileURL, options: .atomic)
    }

    @Test("保存并加载提供商时将 API Key 写入 SQLite 主存储")
    func testSaveAndLoadProvider() throws {
        let provider = Provider(
            id: UUID(),
            name: "Test Provider",
            baseURL: "https://test.com",
            apiKeys: ["key1", "key2"],
            apiFormat: "openai-compatible",
            models: [Model(modelName: "test-model")]
        )

        ConfigLoader.saveProvider(provider)
        defer { cleanup(providers: [provider]) }

        let loadedProviders = ConfigLoader.loadProviders()
        let foundProvider = loadedProviders.first(where: { $0.id == provider.id })

        #expect(foundProvider != nil)
        #expect(foundProvider?.name == "Test Provider")
        #expect(foundProvider?.apiKeys == ["key1", "key2"])
        #expect(foundProvider?.models.first?.modelName == "test-model")
        #expect(!Persistence.auxiliaryBlobExists(forKey: "providers"))
    }

    @Test("同步包编码会包含 Provider JSON 中的 API Key")
    func testSyncPackageEncodingContainsAPIKeys() throws {
        let package = SyncPackage(
            options: [.providers],
            providers: [
                Provider(
                    id: UUID(),
                    name: "sync-provider",
                    baseURL: "https://sync.example.com",
                    apiKeys: ["sync-key"],
                    apiFormat: "openai-compatible",
                    models: [Model(modelName: "sync-model")]
                )
            ]
        )
        let data = try JSONEncoder().encode(package)
        let payload = try #require(String(data: data, encoding: .utf8))
        #expect(payload.contains("\"apiKeys\""))
        #expect(payload.contains("sync-key"))
    }

    @Test("加载旧版无 apiKeys 字段的 Provider 文件时会迁移到 SQLite")
    func testLoadProvidersMigratesLegacyCredentialStoreToSQLite() throws {
        let provider = Provider(
            id: UUID(),
            name: "legacy-\(UUID().uuidString)",
            baseURL: "https://legacy.example.com",
            apiKeys: [],
            apiFormat: "openai-compatible",
            models: [Model(modelName: "legacy-model", isActivated: true)]
        )
        let fileName = "\(provider.id.uuidString).json"

        _ = ProviderCredentialStore.shared.saveAPIKeys(["legacy-key-1", "legacy-key-2"], for: provider.id)
        try writeLegacyProviderFileWithoutAPIKeys(provider, fileName: fileName)
        defer {
            cleanup(providers: [provider])
            try? FileManager.default.removeItem(at: providerFileURL(for: provider.id))
        }

        let firstLoad = ConfigLoader.loadProviders().first(where: { $0.id == provider.id })
        #expect(firstLoad?.apiKeys == ["legacy-key-1", "legacy-key-2"])
        #expect(!Persistence.auxiliaryBlobExists(forKey: "providers"))
        #expect(ProviderCredentialStore.shared.loadAPIKeys(for: provider.id).isEmpty)

        let secondLoad = ConfigLoader.loadProviders().first(where: { $0.id == provider.id })
        #expect(secondLoad?.apiKeys == ["legacy-key-1", "legacy-key-2"])
    }

    @Test("加载提供商时会修复重复 ID 并规范化文件")
    func testLoadProvidersRepairDuplicateIDsAndNormalizeFiles() throws {
        let token = "repair-\(UUID().uuidString)"
        let duplicateProviderID = UUID()
        let duplicateModelID = UUID()

        let providerA = Provider(
            id: duplicateProviderID,
            name: "\(token)-A",
            baseURL: "https://example-a.com",
            apiKeys: ["key-a"],
            apiFormat: "openai-compatible",
            models: [
                Model(id: duplicateModelID, modelName: "a-1", isActivated: true),
                Model(id: duplicateModelID, modelName: "a-2", isActivated: false)
            ]
        )
        let providerB = Provider(
            id: duplicateProviderID,
            name: "\(token)-B",
            baseURL: "https://example-b.com",
            apiKeys: ["key-b"],
            apiFormat: "openai-compatible",
            models: [Model(modelName: "b-1", isActivated: true)]
        )

        let rawFileA = "\(token)-manual-a.json"
        let rawFileB = "\(token)-manual-b.json"

        try writeLegacyProviderFile(providerA, fileName: rawFileA)
        try writeLegacyProviderFile(providerB, fileName: rawFileB)

        let firstLoad = ConfigLoader.loadProviders().filter { $0.name.hasPrefix(token) }
        #expect(firstLoad.count == 2)
        #expect(Set(firstLoad.map(\.id)).count == 2)
        if let repairedA = firstLoad.first(where: { $0.name == "\(token)-A" }) {
            #expect(Set(repairedA.models.map(\.id)).count == repairedA.models.count)
            #expect(repairedA.apiKeys == ["key-a"])
        } else {
            Issue.record("未找到 \(token)-A")
        }
        if let repairedB = firstLoad.first(where: { $0.name == "\(token)-B" }) {
            #expect(repairedB.apiKeys == ["key-b"])
        } else {
            Issue.record("未找到 \(token)-B")
        }

        let secondLoad = ConfigLoader.loadProviders().filter { $0.name.hasPrefix(token) }
        #expect(secondLoad.count == 2)
        #expect(Set(secondLoad.map(\.id)).count == 2)

        cleanup(providers: secondLoad)
        try? FileManager.default.removeItem(at: providersDirectory.appendingPathComponent(rawFileA))
        try? FileManager.default.removeItem(at: providersDirectory.appendingPathComponent(rawFileB))
    }
}

// MARK: - Low-Level & Vector Search Tests

@Suite("Vector Search & Low-Level Tests")
fileprivate struct VectorSearchTests {
    
    // MARK: - TopK Extension Tests
    @Test("Test topK with integers in ascending order")
    func testTopK_ascending() {
        let data = [5, 2, 9, 1, 8, 6]
        let top3 = data.topK(3, by: <)
        #expect(top3 == [1, 2, 5])
    }
    
    @Test("Test topK with integers in descending order")
    func testTopK_descending() {
        let data = [5, 2, 9, 1, 8, 6]
        let top3 = data.topK(3, by: >)
        #expect(top3 == [9, 8, 6])
    }
    
    @Test("Test topK when k is larger than array count")
    func testTopK_kLargerThanCount() {
        let data = [5, 2, 9]
        let top5 = data.topK(5, by: <)
        #expect(top5 == [2, 5, 9])
    }
    
    @Test("Test topK when k is zero")
    func testTopK_kIsZero() {
        let data = [5, 2, 9, 1, 8, 6]
        let top0 = data.topK(0, by: <)
        #expect(top0.isEmpty)
    }
    
    @Test("Test topK with an empty array")
    func testTopK_emptyArray() {
        let data: [Int] = []
        let top3 = data.topK(3, by: <)
        #expect(top3.isEmpty)
    }
    
    @Test("Test topK with duplicate elements")
    func testTopK_withDuplicates() {
        let data = [5, 2, 9, 1, 8, 6, 9, 2]
        let top4 = data.topK(4, by: >)
        #expect(top4 == [9, 9, 8, 6])
    }
    
    // MARK: - JSON Store Tests
    
    /// A mock implementation of the EmbeddingsProtocol for testing purposes.
    class MockEmbeddings: EmbeddingsProtocol {
        typealias TokenizerType = Never
        typealias ModelType = Never
        var tokenizer: Never { fatalError("Not implemented") }
        var model: Never { fatalError("Not implemented") }
        
        let dimension: Int
        
        init(dimension: Int = 4) {
            self.dimension = dimension
        }
        
        func encode(sentence: String) async -> [Float]? {
            var embedding = [Float](repeating: 0.0, count: dimension)
            let hash = sentence.hashValue
            for i in 0..<dimension {
                embedding[i] = Float((hash >> (i * 8)) & 0xFF) / 255.0
            }
            return embedding
        }
    }
    
    struct JsonStoreTests {
        let store = JsonStore()
        let items = [
            IndexItem(id: "1", text: "item 1", embedding: [1.0, 0.0], metadata: [:]),
            IndexItem(id: "2", text: "item 2", embedding: [0.0, 1.0], metadata: [:])
        ]
        let testDir: URL
        let indexName = "testIndex"
        
        init() {
            testDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try? FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        }
        
        func cleanup() {
            try? FileManager.default.removeItem(at: testDir)
        }
        
        @Test("Save and Load Index")
        func testSaveAndLoadIndex() throws {
            let savedURL = try store.saveIndex(items: items, to: testDir, as: indexName)
            #expect(FileManager.default.fileExists(atPath: savedURL.path))
            
            let loadedItems = try store.loadIndex(from: savedURL)
            #expect(loadedItems.count == 2)
            #expect(loadedItems.first?.id == "1")
            cleanup()
        }
        
        @Test("List Indexes")
        func testListIndexes() throws {
            _ = try store.saveIndex(items: items, to: testDir, as: indexName)
            _ = try store.saveIndex(items: [], to: testDir, as: "anotherIndex")
            
            let indexes = store.listIndexes(at: testDir)
            #expect(indexes.count == 2)
            #expect(indexes.contains(where: { $0.lastPathComponent == "testIndex.json" }))
            cleanup()
        }
    }
    
    // MARK: - SimilarityIndex Tests
    struct SimilarityIndexTests {
        var index: SimilarityIndex!
        let testDir: URL
        let indexName = "similarityTestIndex"
        
        init() {
            testDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try? FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        }
        
        mutating func setup() async {
            let mockEmbeddings = MockEmbeddings(dimension: 4)
            index = await SimilarityIndex(name: indexName, model: mockEmbeddings, metric: CosineSimilarity(), vectorStore: JsonStore())
            await index.addItems(ids: ["a", "b", "c"], texts: ["apple", "banana", "cat"], metadata: [[:], [:], [:]], embeddings: nil)
        }
        
        func cleanup() {
            try? FileManager.default.removeItem(at: testDir)
        }
        
        @Test("Add and Get Item")
        mutating func testAddAndGetItem() async {
            await setup()
            #expect(self.index.indexItems.count == 3)
            let itemB = self.index.getItem(id: "b")
            #expect(itemB?.text == "banana")
            cleanup()
        }
        
        @Test("Update Item")
        mutating func testUpdateItem() async {
            await setup()
            index.updateItem(id: "b", text: "blueberry")
            let itemB = index.getItem(id: "b")
            #expect(itemB?.text == "blueberry")
            cleanup()
        }
        
        @Test("Remove Item")
        mutating func testRemoveItem() async {
            await setup()
            index.removeItem(id: "b")
            #expect(index.indexItems.count == 2)
            #expect(index.getItem(id: "b") == nil)
            cleanup()
        }
        
        @Test("Search Items")
        mutating func testSearchItems() async {
            await setup()
            let results = await index.search("apple", top: 1)
            #expect(results.count == 1)
            #expect(results.first?.id == "a")
            cleanup()
        }
        
        @Test("Save and Load Index")
        mutating func testSaveAndLoadIndex() async throws {
            await setup()
            let savedURL = try index.saveIndex(toDirectory: testDir)
            #expect(FileManager.default.fileExists(atPath: savedURL.path))
            
            let mockEmbeddings = MockEmbeddings(dimension: 4)
            let newIndex = await SimilarityIndex(name: indexName, model: mockEmbeddings, vectorStore: JsonStore())
            let loadedItems = try newIndex.loadIndex(fromDirectory: testDir)
            
            #expect(loadedItems != nil)
            #expect(newIndex.indexItems.count == 3)
            #expect(newIndex.getItem(id: "c")?.text == "cat")
            cleanup()
        }
    }
    
    // MARK: - Tokenizer Tests
    struct NativeTokenizerTests {
        @Test("Tokenize a simple sentence")
        func testTokenizeSentence() {
            let tokenizer = NativeTokenizer()
            let text = "This is a test."
            let tokens = tokenizer.tokenize(text: text)
            #expect(tokens == ["This", "is", "a", "test", "."])
        }
        
        @Test("Tokenize sentence with punctuation")
        func testTokenizeWithPunctuation() {
            let tokenizer = NativeTokenizer()
            let text = "Hello, world! How are you?"
            let tokens = tokenizer.tokenize(text: text)
            #expect(tokens == ["Hello", ",", "world", "!", "How", "are", "you", "?"])
        }
    }
    
    // MARK: - DistanceMetrics Tests
    struct DistanceMetricsTests {
        
        let vectorA: [Float] = [1.0, 2.0, 3.0]
        let vectorB: [Float] = [4.0, 5.0, 6.0]
        let vectorC: [Float] = [-1.0, -2.0, -3.0]
        let vectorD: [Float] = [3.0, -1.5, 0.5]
        let zeroVector: [Float] = [0.0, 0.0, 0.0]
        let differentLengthVector: [Float] = [1.0, 2.0]
        
        
    }
}

@Suite("历史会话检索支持 Tests")
fileprivate struct SessionHistorySearchSupportTests {
    @Test("按会话标题与主题提示检索")
    func testSearchHitsBySessionMetadata() {
        let target = ChatSession(
            id: UUID(),
            name: "周报讨论",
            topicPrompt: "产品复盘与改进点"
        )
        let other = ChatSession(
            id: UUID(),
            name: "随手记录",
            topicPrompt: "午饭吃什么"
        )

        let byTitle = SessionHistorySearchSupport.searchHits(
            sessions: [target, other],
            query: "周报",
            messageLoader: { _ in [] }
        )
        #expect(byTitle[target.id]?.source == .sessionName)
        #expect(byTitle[other.id] == nil)

        let byTopic = SessionHistorySearchSupport.searchHits(
            sessions: [target, other],
            query: "改进点",
            messageLoader: { _ in [] }
        )
        #expect(byTopic[target.id]?.source == .topicPrompt)
        #expect(byTopic[other.id] == nil)
    }

    @Test("按消息正文检索并返回命中来源")
    func testSearchHitsByMessageContent() {
        let session = ChatSession(id: UUID(), name: "旅行计划")
        let userMessage = ChatMessage(role: .user, content: "请帮我整理大阪旅行清单")
        let assistantMessage = ChatMessage(role: .assistant, content: "好的，我先给你一个 5 天行程草案。")

        let hits = SessionHistorySearchSupport.searchHits(
            sessions: [session],
            query: "旅行清单",
            messageLoader: { _ in [userMessage, assistantMessage] }
        )

        #expect(hits[session.id]?.source == .userMessage)
        #expect(hits[session.id]?.preview.contains("大阪旅行清单") == true)
        #expect(hits[session.id]?.matches.first?.messageOrdinal == 1)
    }

    @Test("检索支持正则表达式模式")
    func testSearchHitsSupportsRegexPattern() {
        let session = ChatSession(id: UUID(), name: "旅行计划")
        let userMessage = ChatMessage(role: .user, content: "请帮我整理大阪旅行清单")

        let hits = SessionHistorySearchSupport.searchHits(
            sessions: [session],
            query: "旅行.*清单",
            messageLoader: { _ in [userMessage] }
        )

        #expect(hits[session.id]?.source == .userMessage)
    }

    @Test("非法正则会回退到普通关键词匹配")
    func testSearchHitsFallsBackWhenRegexIsInvalid() {
        let session = ChatSession(id: UUID(), name: "处理 [abc 字符串")

        let hits = SessionHistorySearchSupport.searchHits(
            sessions: [session],
            query: "[abc",
            messageLoader: { _ in [] }
        )

        #expect(hits[session.id]?.source == .sessionName)
    }

    @Test("当前会话优先使用内存消息检索")
    func testSearchHitsPrefersCurrentSessionMessages() {
        let session = ChatSession(id: UUID(), name: "开发讨论")
        let persistedMessages = [ChatMessage(role: .assistant, content: "这是磁盘里的旧消息")]
        let inMemoryMessages = [ChatMessage(role: .assistant, content: "这是内存里的最新回复")]

        let hits = SessionHistorySearchSupport.searchHits(
            sessions: [session],
            query: "最新回复",
            currentSessionID: session.id,
            currentSessionMessages: inMemoryMessages,
            messageLoader: { _ in persistedMessages }
        )

        #expect(hits[session.id]?.source == .assistantMessage)
        #expect(hits[session.id]?.preview.contains("内存里的最新回复") == true)
    }

    @Test("同一会话多条消息命中时返回完整命中序号")
    func testSearchHitsReturnsAllMessageOrdinals() {
        let session = ChatSession(id: UUID(), name: "排期讨论")
        let messages = [
            ChatMessage(role: .user, content: "今天先整理需求池"),
            ChatMessage(role: .assistant, content: "收到，我先给你一个排期草案。"),
            ChatMessage(role: .user, content: "排期里要加上联调时间"),
            ChatMessage(role: .assistant, content: "好的，排期会补充风险说明。")
        ]

        let hits = SessionHistorySearchSupport.searchHits(
            sessions: [session],
            query: "排期",
            messageLoader: { _ in messages }
        )

        let ordinals = hits[session.id]?.matches.compactMap(\.messageOrdinal) ?? []
        #expect(ordinals == [2, 3, 4])
        #expect(hits[session.id]?.matchCount == 3)
    }
}
