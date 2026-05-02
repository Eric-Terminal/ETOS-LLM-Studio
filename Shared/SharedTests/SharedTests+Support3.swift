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

@Suite("聊天界面架构默认值测试")
// MARK: - ChatSession Management Tests

@Suite("ChatSession Management Tests")
struct ChatSessionTests {

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

    @Test("移动文件夹时会更新父文件夹")
    func testMoveSessionFolderUpdatesParentFolder() {
        guard let firstRoot = chatService.createSessionFolder(name: "项目一", parentID: nil),
              let secondRoot = chatService.createSessionFolder(name: "项目二", parentID: nil),
              let childFolder = chatService.createSessionFolder(name: "子目录", parentID: firstRoot.id) else {
            Issue.record("创建测试文件夹失败")
            return
        }

        chatService.moveSessionFolder(folderID: childFolder.id, toParentID: secondRoot.id)

        let movedFolder = chatService.sessionFoldersSubject.value.first(where: { $0.id == childFolder.id })
        #expect(movedFolder?.parentID == secondRoot.id)
    }

    @Test("移动文件夹时会拒绝移动到自身或子目录")
    func testMoveSessionFolderRejectsSelfAndDescendantTargets() {
        guard let rootFolder = chatService.createSessionFolder(name: "项目", parentID: nil),
              let childFolder = chatService.createSessionFolder(name: "子目录", parentID: rootFolder.id) else {
            Issue.record("创建测试文件夹失败")
            return
        }

        chatService.moveSessionFolder(folderID: rootFolder.id, toParentID: rootFolder.id)
        chatService.moveSessionFolder(folderID: rootFolder.id, toParentID: childFolder.id)

        let rootAfterMove = chatService.sessionFoldersSubject.value.first(where: { $0.id == rootFolder.id })
        #expect(rootAfterMove?.parentID == nil)
    }
}


@Suite("ConfigLoader Tests")
struct ConfigLoaderTests {
    struct LegacyProviderSnapshot: Encodable {
        let id: UUID
        let name: String
        let baseURL: String
        let apiKeys: [String]
        let apiFormat: String
        let models: [Model]
        let headerOverrides: [String: String]
    }

    struct LegacyProviderWithoutAPIKeysSnapshot: Encodable {
        let id: UUID
        let name: String
        let baseURL: String
        let apiFormat: String
        let models: [Model]
        let headerOverrides: [String: String]
    }
    
    // Clean up provider files
    func cleanup(providers: [Provider]) {
        for provider in providers {
             ConfigLoader.deleteProvider(provider)
        }
    }

    var providersDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Providers")
    }

    func providerFileURL(for providerID: UUID) -> URL {
        providersDirectory.appendingPathComponent("\(providerID.uuidString).json")
    }

    func writeLegacyProviderFile(_ provider: Provider, fileName: String) throws {
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

    func writeLegacyProviderFileWithoutAPIKeys(_ provider: Provider, fileName: String) throws {
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

    @Test("旧 SQLite 模型没有能力记录时保留默认聊天能力")
    func testLegacySQLiteModelWithoutCapabilityRowsKeepsChatDefaults() throws {
        let providerID = UUID()
        let modelID = UUID()
        let providerName = "legacy-sqlite-\(providerID.uuidString)"

        let inserted = Persistence.withConfigDatabaseWrite { db in
            try db.execute(
                sql: """
                INSERT INTO providers (id, name, base_url, api_format, updated_at)
                VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [
                    providerID.uuidString,
                    providerName,
                    "https://legacy-sqlite.example.com/v1",
                    "openai-compatible",
                    Date().timeIntervalSince1970
                ]
            )
            try db.execute(
                sql: """
                INSERT INTO provider_api_keys (provider_id, key_index, api_key)
                VALUES (?, ?, ?)
                """,
                arguments: [providerID.uuidString, 0, "key"]
            )
            try db.execute(
                sql: """
                INSERT INTO provider_models (
                    id, provider_id, model_name, display_name, is_activated,
                    request_body_override_mode, raw_request_body_json, sort_index, updated_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    modelID.uuidString,
                    providerID.uuidString,
                    "legacy-chat",
                    "legacy-chat",
                    1,
                    Model.RequestBodyOverrideMode.expression.rawValue,
                    nil,
                    0,
                    Date().timeIntervalSince1970
                ]
            )
        }
        #expect(inserted != nil)
        defer {
            if let loaded = ConfigLoader.loadProviders().first(where: { $0.id == providerID }) {
                ConfigLoader.deleteProvider(loaded)
            }
        }

        let loadedModel = ConfigLoader.loadProviders()
            .first(where: { $0.id == providerID })?
            .models
            .first(where: { $0.id == modelID })

        #expect(loadedModel?.kind == .chat)
        #expect(loadedModel?.supportsToolCalling == true)
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
struct VectorSearchTests {
    
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
