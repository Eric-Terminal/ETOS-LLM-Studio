// ============================================================================
// SimilarityIndex.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件源自 SimilaritySearchKit，定义了 SimilarityIndex 类。
// 这是向量搜索功能的核心，负责管理索引项、执行搜索和协调其他组件。
// 我已根据项目规范，将注释和文件头修改为中文格式。
// ============================================================================

import Foundation
import os.log

// MARK: - 类型别名

public typealias IndexItem = SimilarityIndex.IndexItem
public typealias SearchResult = SimilarityIndex.SearchResult
public typealias EmbeddingModelType = SimilarityIndex.EmbeddingModelType
public typealias SimilarityMetricType = SimilarityIndex.SimilarityMetricType
public typealias TextSplitterType = SimilarityIndex.TextSplitterType
public typealias VectorStoreType = SimilarityIndex.VectorStoreType

private let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "SimilarityIndex")

public class SimilarityIndex: Identifiable, Hashable {
    // MARK: - 属性

    /// 此索引实例的唯一标识符
    public var id: UUID = .init()
    public static func == (lhs: SimilarityIndex, rhs: SimilarityIndex) -> Bool {
        return lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    // 数组的引用保留也必须受保护；异步保存取得快照时，重嵌入可能正在清空或追加。
    // 锁只覆盖内存状态，嵌入生成、相似度计算和磁盘读写均在锁外完成。
    private let stateLock = NSRecursiveLock()
    private var storedItems: [IndexItem] = []
    public var indexItems: [IndexItem] {
        get { stateLock.withLock { storedItems } }
        set { stateLock.withLock { storedItems = newValue } }
    }

    /// 索引中嵌入向量的维度。
    /// 用于验证嵌入更新。
    private var storedDimension = 0
    public private(set) var dimension: Int {
        get { stateLock.withLock { storedDimension } }
        set { stateLock.withLock { storedDimension = newValue } }
    }

    /// 索引的名称。
    public var indexName: String

    public let indexModel: any EmbeddingsProtocol
    private var storedMetric: any DistanceMetricProtocol
    public var indexMetric: any DistanceMetricProtocol {
        get { stateLock.withLock { storedMetric } }
        set { stateLock.withLock { storedMetric = newValue } }
    }
    public let vectorStore: any VectorStoreProtocol

    /// 代表索引中一个项的对象。
    public struct IndexItem: Codable {
        /// 项的唯一标识符。
        public let id: String

        /// 与项关联的文本。
        public var text: String

        /// 项的嵌入向量。
        public var embedding: [Float]

        /// 包含项元数据的字典。
        public var metadata: [String: String]
    }

    /// 包含搜索结果信息的可识别对象。
    public struct SearchResult: Identifiable {
        /// 关联索引项的唯一标识符。
        public let id: String

        /// 查询与结果之间的相似度得分。
        public let score: Float

        /// 与结果关联的文本。
        public let text: String

        /// 包含结果元数据的字典。
        public let metadata: [String: String]
    }

    /// 可用嵌入模型的枚举。
    public enum EmbeddingModelType {
        /// DistilBERT，一个为问答任务微调的小型BERT模型。
        case distilbert

        /// MiniLM All，一个更小但更快的模型。
        case minilmAll

        /// Multi-QA MiniLM，一个为问答任务微调的快速模型。
        case minilmMultiQA

        /// 由苹果的 NaturalLanguage 库提供的原生模型。
        case native
    }

    /// 相似度度量类型的枚举。
    public enum SimilarityMetricType {
        case cosine     // 余弦相似度
    }

    /// 文本分割器类型的枚举。
    public enum TextSplitterType {
        case token      // 按词元
        case character  // 按字符
        case recursive  // 递归
    }

    /// 向量存储类型的枚举。
    public enum VectorStoreType {
        case json
        // 未来可能支持: mlmodel, protobuf, sqlite
    }

    // MARK: - 初始化方法

    public init(name: String? = nil, model: (any EmbeddingsProtocol)? = nil, metric: (any DistanceMetricProtocol)? = nil, vectorStore: (any VectorStoreProtocol)? = nil) async {
        // 使用默认值设置索引
        self.indexName = name ?? "SimilaritySearchKitIndex"
        self.indexModel = model ?? NativeEmbeddings()
        self.storedMetric = metric ?? CosineSimilarity()
        self.vectorStore = vectorStore ?? JsonStore()

        // 运行一次模型以发现维度大小
        await setupDimension()
    }

    private func setupDimension() async {
        if let testVector = await indexModel.encode(sentence: "测试句子") {
            dimension = testVector.count
        } else {
            logger.warning("未能生成测试输入向量")
        }
    }

    // MARK: - 编码

    public func getEmbedding(for text: String, embedding: [Float]? = nil) async -> [Float] {
        if let embedding = embedding {
            updateDimensionIfNeeded(with: embedding.count)
            return embedding
        } else {
            guard let encoded = await indexModel.encode(sentence: text) else {
                logger.error("编码文本失败: \(text)")
                return dimension > 0 ? Array(repeating: Float(0), count: dimension) : []
            }
            updateDimensionIfNeeded(with: encoded.count)
            return encoded
        }
    }

    // MARK: - 搜索

    public func search(_ query: String, top resultCount: Int? = nil, metric: DistanceMetricProtocol? = nil) async -> [SearchResult] {
        guard let queryEmbedding = await indexModel.encode(sentence: query) else {
            logger.error("为查询 '\(query)' 生成嵌入失败")
            return []
        }
        updateDimensionIfNeeded(with: queryEmbedding.count)
        return search(usingQueryEmbedding: queryEmbedding, top: resultCount, metric: metric)
    }
    
    public func search(usingQueryEmbedding queryEmbedding: [Float], top resultCount: Int? = nil, metric: DistanceMetricProtocol? = nil) -> [SearchResult] {
        let resultCount = resultCount ?? 5
        guard !queryEmbedding.isEmpty else { return [] }
        let snapshot = stateLock.withLock { () -> ([IndexItem], any DistanceMetricProtocol)? in
            guard !storedItems.isEmpty else { return nil }
            if storedDimension == 0 {
                storedDimension = queryEmbedding.count
            } else if storedDimension != queryEmbedding.count {
                logger.warning("查询嵌入维度 (\(queryEmbedding.count)) 与索引维度 (\(self.storedDimension)) 不匹配。")
                return nil
            }
            if let metric { storedMetric = metric }
            return (storedItems, storedMetric)
        }
        guard let (items, searchMetric) = snapshot else { return [] }
        let searchResults = searchMetric.findNearest(for: queryEmbedding, in: items.map(\.embedding), resultsCount: resultCount)

        // 分数和正文必须来自同一快照，不能在计算后用 ID 查询已被重嵌入替换的索引。
        return searchResults.map { score, index in
            let item = items[index]
            return SearchResult(id: item.id, score: score, text: item.text, metadata: item.metadata)
        }
    }

    private func updateDimensionIfNeeded(with newValue: Int) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard newValue > 0 else { return }
        if dimension == 0 {
            dimension = newValue
        } else if dimension != newValue {
            logger.info("检测到嵌入维度变化: \(self.dimension) -> \(newValue)，将使用最新维度。")
            dimension = newValue
        }
    }

    private func refreshDimensionFromIndexItems() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let storedDimension = indexItems.first(where: { !$0.embedding.isEmpty })?.embedding.count else {
            dimension = 0
            return
        }

        // 持久化索引保存的是预计算向量，加载后必须以实际索引维度为准。
        if dimension != storedDimension {
            logger.info("已从持久化索引恢复嵌入维度: \(self.dimension) -> \(storedDimension)。")
        }
        dimension = storedDimension
    }
}

// MARK: - 增删改查 (CRUD)

public extension SimilarityIndex {
    // MARK: 创建

    /// 添加一个带有可选预计算嵌入的项
    func addItem(id: String, text: String, metadata: [String: String], embedding: [Float]? = nil) async {
        let embeddingResult = await getEmbedding(for: text, embedding: embedding)

        let item = IndexItem(id: id, text: text, embedding: embeddingResult, metadata: metadata)
        stateLock.withLock {
            updateDimensionIfNeeded(with: embeddingResult.count)
            storedItems.append(item)
        }
    }

    func addItems(ids: [String], texts: [String], metadata: [[String: String]], embeddings: [[Float]?]? = nil, onProgress: ((String) -> Void)? = nil) async {
        // 检查所有输入数组是否具有相同的长度
        guard ids.count == texts.count, texts.count == metadata.count else {
            logger.error("输入数组长度不一致: ids=\(ids.count), texts=\(texts.count), metadata=\(metadata.count)")
            return
        }

        let useEmbeddings: [[Float]?]?
        if let embeddings = embeddings {
            if embeddings.count == ids.count {
                useEmbeddings = embeddings
            } else {
                logger.warning("嵌入数组的长度必须与ID数组的长度相同，将忽略嵌入。 \(embeddings.count) vs \(ids.count)")
                useEmbeddings = nil
            }
        } else {
            useEmbeddings = nil
        }

        for i in 0..<ids.count {
            let id = ids[i]
            let text = texts[i]
            let embedding = useEmbeddings?[i]
            let meta = metadata[i]

            await addItem(id: id, text: text, metadata: meta, embedding: embedding)
            onProgress?(id)
        }
    }

    func addItems(_ items: [IndexItem], completion: (() -> Void)? = nil) {
        Task {
            for item in items {
                await self.addItem(id: item.id, text: item.text, metadata: item.metadata, embedding: item.embedding)
            }
            completion?()
        }
    }

    // MARK: 读取

    func getItem(id: String) -> IndexItem? {
        return indexItems.first { $0.id == id }
    }


    // MARK: 更新

    func updateItem(id: String, text: String? = nil, embedding: [Float]? = nil, metadata: [String: String]? = nil) {
        stateLock.lock()
        defer { stateLock.unlock() }
        // 检查提供的嵌入是否具有正确的维度
        if let embedding = embedding, embedding.count != dimension {
            logger.warning("维度不匹配，期望 \(self.dimension)，实际为 \(embedding.count)")
        }

        // 查找具有指定ID的项
        if let index = storedItems.firstIndex(where: { $0.id == id }) {
            // 如果提供了文本，则更新文本
            if let text = text {
                storedItems[index].text = text
            }

            // 如果提供了嵌入，则更新嵌入
            if let embedding = embedding {
                storedItems[index].embedding = embedding
            }

            // 如果提供了元数据，则更新元数据
            if let metadata = metadata {
                storedItems[index].metadata = metadata
            }
        }
    }

    // MARK: 删除

    func removeItem(id: String) {
        stateLock.withLock { storedItems.removeAll { $0.id == id } }
    }

    func removeAll() {
        stateLock.withLock {
            storedItems.removeAll()
            storedDimension = 0
        }
    }
}

// MARK: - 持久化

public extension SimilarityIndex {
    func saveIndex(toDirectory path: URL? = nil, name: String? = nil) throws -> URL {
        let indexName = name ?? self.indexName
        let basePath: URL

        if let specifiedPath = path {
            basePath = specifiedPath
        } else {
            // 默认本地路径
            basePath = try getDefaultStoragePath()
        }

        let items = indexItems
        let savedVectorStore = try vectorStore.saveIndex(items: items, to: basePath, as: indexName)

        logger.info("已将 \(items.count) 个索引项保存到 \(savedVectorStore.absoluteString)")

        return savedVectorStore
    }

    func loadIndex(fromDirectory path: URL? = nil, name: String? = nil) throws -> [IndexItem]? {
        if let indexPath = try getIndexPath(fromDirectory: path, name: name) {
            let items = try vectorStore.loadIndex(from: indexPath)
            stateLock.withLock {
                storedItems = items
                refreshDimensionFromIndexItems()
            }
            return items
        }

        return nil
    }

    /// 此函数返回 loadIndex/saveIndex 函数数据存储的默认位置。
    /// - Parameters:
    ///   - fromDirectory: 可选的目录路径，文件名后缀会附加到此路径上
    ///   - name: 可选的名称
    ///
    /// - Returns: 一个可选的 URL
    func getIndexPath(fromDirectory path: URL? = nil, name: String? = nil) throws -> URL? {
        let indexName = name ?? self.indexName
        let basePath: URL

        if let specifiedPath = path {
            basePath = specifiedPath
        } else {
            // 默认本地路径
            basePath = try getDefaultStoragePath()
        }
        return vectorStore.listIndexes(at: basePath).first(where: { $0.lastPathComponent.contains(indexName) })
    }

    private func getDefaultStoragePath() throws -> URL {
        let appName = Bundle.main.bundleIdentifier ?? "SimilaritySearchKit"
        let fileManager = FileManager.default
        let appSupportDirectory = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)

        let appSpecificDirectory = appSupportDirectory.appendingPathComponent(appName)

        if !fileManager.fileExists(atPath: appSpecificDirectory.path) {
            try fileManager.createDirectory(at: appSpecificDirectory, withIntermediateDirectories: true, attributes: nil)
        }

        return appSpecificDirectory
    }

}
