// ============================================================================
// MemoryManagerTests.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件负责记忆管理、嵌入补偿、进度事件与记忆检索的行为测试。
// ============================================================================

import Testing
import Foundation
import Combine
@testable import ETOSCore

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

    actor ReembeddingResultRecorder {
        private var results: [MemoryReembeddingItemResult] = []

        func append(_ result: MemoryReembeddingItemResult) {
            results.append(result)
        }

        func snapshot() -> [MemoryReembeddingItemResult] {
            results
        }
    }

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
            // 预期抛错。
        }

        try await Task.sleep(for: .milliseconds(100))

        let events = await recorder.snapshot().filter { $0.kind == .reembedAll }
        #expect(events.contains { $0.phase == .running && $0.processedMemories == 0 && $0.totalMemories == 1 })

        if let last = events.last {
            #expect(last.phase == .failed)
            #expect(last.processedMemories == last.totalMemories)
            #expect(last.failedMemories == 1)
        } else {
            Issue.record("未捕获到重嵌入失败进度事件。")
        }

        await cleanup(memoryManager: memoryManager)
    }

    @Test("Detailed Reembed Reports Per Memory Results")
    func testDetailedReembedReportsPerMemoryResults() async throws {
        let memoryManager = MemoryManager(embeddingGenerator: MockEmbeddingGenerator())
        await memoryManager.waitForInitialization()
        await cleanup(memoryManager: memoryManager)

        await memoryManager.addMemory(content: "用户喜欢手冲咖啡。")
        await memoryManager.addMemory(content: "用户偏好简洁回答。")

        let recorder = ReembeddingResultRecorder()
        let results = try await memoryManager.reembedAllMemoriesDetailed(concurrencyLimit: 2) { result in
            await recorder.append(result)
        }
        let callbackResults = await recorder.snapshot()

        #expect(results.count == 2)
        #expect(callbackResults.count == 2)
        #expect(results.allSatisfy { $0.succeeded })
        #expect(results.allSatisfy { $0.chunkCount > 0 })

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

    @Test("混合检索融合重要度、实体与时间有效性")
    func hybridRetrievalUsesMultipleSignalsAndValidity() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expired = MemoryItem(
            content: "用户以前喜欢深烘咖啡。",
            embedding: [],
            createdAt: now.addingTimeInterval(-100_000),
            importance: 0.9,
            entities: ["咖啡"],
            validUntil: now.addingTimeInterval(-10)
        )
        let current = MemoryItem(
            content: "用户现在喜欢浅烘咖啡。",
            embedding: [],
            createdAt: now,
            kind: .preference,
            importance: 0.8,
            entities: ["咖啡"]
        )
        let lowImportance = MemoryItem(
            content: "用户现在喜欢浅烘咖啡。",
            embedding: [],
            createdAt: now,
            kind: .preference,
            importance: 0.1,
            entities: ["咖啡"]
        )

        let currentMatches = MemoryHybridRetriever.rank(
            query: "用户现在喜欢什么咖啡",
            tokens: ["用户", "现在", "喜欢", "咖啡"],
            memories: [expired, lowImportance, current],
            semanticScores: [current.id: 0.8, lowImportance.id: 0.8, expired.id: 0.9],
            limit: 3,
            now: now
        )
        #expect(!currentMatches.contains { $0.memory.id == expired.id })
        #expect(currentMatches.first?.memory.id == current.id)

        let historicalMatches = MemoryHybridRetriever.rank(
            query: "用户以前喜欢什么咖啡",
            tokens: ["用户", "以前", "喜欢", "咖啡"],
            memories: [expired, current],
            semanticScores: [expired.id: 0.9, current.id: 0.7],
            limit: 2,
            now: now
        )
        #expect(historicalMatches.contains { $0.memory.id == expired.id })
    }

    @Test("结构化记忆元数据可编码并兼容往返")
    func structuredMemoryMetadataRoundTrip() throws {
        let original = MemoryItem(
            content: "用户偏好原生 SwiftUI 界面。",
            embedding: [0.1, 0.2],
            kind: .preference,
            source: .userStatement,
            importance: 0.85,
            confidence: 0.95,
            entities: ["SwiftUI", "Apple"],
            sourceSessionID: UUID(),
            accessCount: 4,
            lastAccessedAt: Date()
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MemoryItem.self, from: data)
        #expect(decoded == original)
    }

    @Test("长期记忆整理达到数量与时间门槛后才触发")
    func memoryConsolidationRespectsLowFrequencyPolicy() {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let memories = (0..<8).map { index in
            MemoryItem(
                content: "长期记忆 \(index)",
                embedding: [],
                createdAt: now.addingTimeInterval(Double(index - 20))
            )
        }

        #expect(LongTermMemoryConsolidationPlanner.shouldRun(
            memories: memories,
            state: MemoryConsolidationState(),
            now: now
        ))

        #expect(!LongTermMemoryConsolidationPlanner.shouldRun(
            memories: memories,
            state: MemoryConsolidationState(lastAttemptAt: now.addingTimeInterval(-60), lastSuccessAt: nil),
            now: now
        ))

        #expect(!LongTermMemoryConsolidationPlanner.shouldRun(
            memories: memories,
            state: MemoryConsolidationState(lastAttemptAt: nil, lastSuccessAt: now.addingTimeInterval(-10)),
            now: now
        ))
    }

    @Test("长期记忆整理只接受通过本地相似度校验的重复项")
    func memoryConsolidationRejectsUnrelatedModelSuggestions() {
        let keeper = MemoryItem(
            content: "用户偏好原生 SwiftUI 界面。",
            embedding: [1, 0, 0],
            kind: .preference,
            entities: ["SwiftUI"]
        )
        let duplicate = MemoryItem(
            content: "用户偏好原生 SwiftUI 界面",
            embedding: [0.99, 0.01, 0],
            kind: .preference,
            entities: ["SwiftUI"]
        )
        let unrelated = MemoryItem(
            content: "用户每周末跑步。",
            embedding: [0, 1, 0],
            kind: .preference,
            entities: ["跑步"]
        )
        let response = """
        {
          "groups": [
            {
              "keeper_id": "\(keeper.id.uuidString)",
              "duplicate_ids": ["\(duplicate.id.uuidString)", "\(unrelated.id.uuidString)"],
              "canonical_content": "用户偏好原生 SwiftUI 界面。"
            }
          ]
        }
        """

        let plan = LongTermMemoryConsolidationPlanner.plan(
            from: response,
            candidates: [keeper, duplicate, unrelated]
        )
        #expect(plan?.merges.count == 1)
        #expect(plan?.merges.first?.keeperID == keeper.id)
        #expect(plan?.merges.first?.duplicateIDs == [duplicate.id])
    }

    @Test("长期记忆整理拒绝跨类型合并")
    func memoryConsolidationRejectsCrossKindMerge() {
        let fact = MemoryItem(
            content: "用户使用 Swift。",
            embedding: [1, 0],
            kind: .semantic
        )
        let rule = MemoryItem(
            content: "用户使用 Swift。",
            embedding: [1, 0],
            kind: .procedural
        )
        let response = """
        {"groups":[{"keeper_id":"\(fact.id.uuidString)","duplicate_ids":["\(rule.id.uuidString)"],"canonical_content":"用户使用 Swift。"}]}
        """

        let plan = LongTermMemoryConsolidationPlanner.plan(
            from: response,
            candidates: [fact, rule]
        )
        #expect(plan?.merges.isEmpty == true)
    }

    @Test("长期记忆整理用新事实结束旧事实的有效期")
    func memoryConsolidationBuildsValidatedSupersession() {
        let oldDate = Date(timeIntervalSince1970: 1_800_000_000)
        let newDate = oldDate.addingTimeInterval(86_400)
        let oldMemory = MemoryItem(
            content: "用户当前使用模型 Alpha。",
            embedding: [0.9, 0.1],
            createdAt: oldDate,
            kind: .semantic,
            entities: ["模型"]
        )
        let newMemory = MemoryItem(
            content: "用户当前使用模型 Beta。",
            embedding: [0.88, 0.12],
            createdAt: newDate,
            kind: .semantic,
            entities: ["模型"]
        )
        let response = """
        {"groups":[],"supersessions":[{"older_id":"\(oldMemory.id.uuidString)","newer_id":"\(newMemory.id.uuidString)"}]}
        """

        let plan = LongTermMemoryConsolidationPlanner.plan(
            from: response,
            candidates: [oldMemory, newMemory]
        )
        #expect(plan?.supersessions.count == 1)
        #expect(plan?.supersessions.first?.validUntil == newDate)
    }
}
