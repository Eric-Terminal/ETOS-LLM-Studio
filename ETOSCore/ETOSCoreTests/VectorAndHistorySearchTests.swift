// ============================================================================
// VectorAndHistorySearchTests.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件负责低层工具函数、向量检索与会话历史检索支持测试。
// ============================================================================

import Testing
import Foundation
@testable import ETOSCore

@Suite("Vector Search & Low-Level Tests")
fileprivate struct VectorSearchTests {
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

        @Test("加载索引后应恢复持久化向量维度")
        mutating func testLoadIndexRestoresPersistedEmbeddingDimension() async throws {
            let sourceEmbeddings = MockEmbeddings(dimension: 4)
            index = await SimilarityIndex(name: indexName, model: sourceEmbeddings, metric: CosineSimilarity(), vectorStore: JsonStore())
            await index.addItem(id: "a", text: "apple", metadata: [:], embedding: [1, 0, 0, 0, 0, 0])
            await index.addItem(id: "b", text: "banana", metadata: [:], embedding: [0, 1, 0, 0, 0, 0])
            _ = try index.saveIndex(toDirectory: testDir)

            let restartEmbeddings = MockEmbeddings(dimension: 4)
            let restartedIndex = await SimilarityIndex(name: indexName, model: restartEmbeddings, metric: CosineSimilarity(), vectorStore: JsonStore())
            _ = try restartedIndex.loadIndex(fromDirectory: testDir)

            #expect(restartedIndex.dimension == 6)
            let results = restartedIndex.search(usingQueryEmbedding: [1, 0, 0, 0, 0, 0], top: 1)
            #expect(results.first?.id == "a")
            cleanup()
        }
    }

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

    @Test("命中结果会按单条消息拆分并保持顺序")
    func testFlattenedResultsBreaksOutEachMatch() {
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
        let results = SessionHistorySearchSupport.flattenedResults(
            sessions: [session],
            hits: hits
        )

        #expect(results.map(\.sessionID) == [session.id, session.id, session.id])
        #expect(results.compactMap(\.messageOrdinal) == [2, 3, 4])
        #expect(results.map(\.matchIndexInSession) == [0, 1, 2])
    }

    @Test("长命中预览会围绕首次命中保留前后二十字")
    func testSearchHitPreviewUsesContextAroundMatch() {
        let session = ChatSession(id: UUID(), name: "长文本预览")
        let message = ChatMessage(
            role: .assistant,
            content: "12345678901234567890你好abcdefghijABCDEFGHIJ额外补充内容"
        )

        let hits = SessionHistorySearchSupport.searchHits(
            sessions: [session],
            query: "你好",
            messageLoader: { _ in [message] }
        )

        #expect(
            hits[session.id]?.matches.first?.preview
            == "12345678901234567890你好abcdefghijABCDEFGHIJ…"
        )
    }

    @Test("命中靠近开头时会保留可用前缀并截断后文")
    func testSearchHitPreviewKeepsAvailablePrefixWhenMatchNearStart() {
        let session = ChatSession(id: UUID(), name: "前缀预览")
        let message = ChatMessage(
            role: .assistant,
            content: "你好这里是比较长的补充说明，用来验证后面还能继续截取二十个字"
        )

        let hits = SessionHistorySearchSupport.searchHits(
            sessions: [session],
            query: "你好",
            messageLoader: { _ in [message] }
        )

        #expect(
            hits[session.id]?.matches.first?.preview
            == "你好这里是比较长的补充说明，用来验证后面还能…"
        )
    }
}
