import Foundation
import Testing
@testable import ETOSCore

@Suite("向量索引并发快照")
struct SimilarityIndexConcurrencyTests {
    @Test("并发追加和后台 SQLite 保存保留完整索引项", .timeLimit(.minutes(1)))
    func concurrentIngestionAndPersistence() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SQLiteVectorStore()
        let index = await SimilarityIndex(name: "concurrent", model: FixedEmbeddings(), vectorStore: store)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for worker in 0..<8 {
                group.addTask {
                    for item in 0..<64 {
                        let id = "\(worker)-\(item)"
                        await index.addItem(id: id, text: "记录-\(id)", metadata: ["id": id], embedding: [1, 0])
                        await Task.yield()
                    }
                }
            }
            group.addTask {
                for _ in 0..<32 {
                    let url = try index.saveIndex(toDirectory: directory)
                    let saved = try store.loadIndex(from: url)
                    #expect(Set(saved.map(\.id)).count == saved.count)
                    #expect(saved.allSatisfy { $0.text == "记录-\($0.id)" && $0.metadata["id"] == $0.id && $0.embedding == [1, 0] })
                    await Task.yield()
                }
            }
            try await group.waitForAll()
        }
        let finalURL = try index.saveIndex(toDirectory: directory)
        #expect(try store.loadIndex(from: finalURL).count == 512)
        #expect(index.dimension == 2)
    }

    @Test("计算期间删除并替换索引仍返回与分数一致的原始正文")
    func searchUsesOneSnapshot() async {
        let index = await SimilarityIndex(model: FixedEmbeddings())
        await index.addItem(id: "original", text: "原始正文", metadata: ["version": "old"], embedding: [1, 0])
        let results = index.search(usingQueryEmbedding: [1, 0], metric: ReplacingMetric {
            index.removeAll()
            index.indexItems = [.init(id: "original", text: "替换后的正文", embedding: [0, 1], metadata: ["version": "new"])]
        })
        #expect(results.count == 1)
        #expect(results.first?.text == "原始正文")
        #expect(results.first?.metadata["version"] == "old")
        #expect(index.getItem(id: "original")?.text == "替换后的正文")
    }

    private struct FixedEmbeddings: EmbeddingsProtocol {
        typealias TokenizerType = Never
        typealias ModelType = Never
        var tokenizer: Never { fatalError("此夹具只使用预计算向量") }
        var model: Never { fatalError("此夹具只使用预计算向量") }
        func encode(sentence: String) async -> [Float]? { [1, 0] }
    }

    private struct ReplacingMetric: DistanceMetricProtocol {
        let replace: () -> Void
        func findNearest(for queryEmbedding: [Float], in neighborEmbeddings: [[Float]], resultsCount: Int) -> [(Float, Int)] {
            #expect(neighborEmbeddings == [[1, 0]])
            replace()
            return [(1, 0)]
        }
        func distance(between firstEmbedding: [Float], and secondEmbedding: [Float]) -> Float { 1 }
    }
}
