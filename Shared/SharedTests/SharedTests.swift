// ============================================================================
// SharedTests.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件仅保留 Shared 测试所需的公共支撑类型与共用工具方法。
// 具体测试已按职责拆分到独立 Swift 文件中。
// ============================================================================

import Testing
import Foundation
import SQLite3
@testable import Shared

@Suite("ChatService Integration Tests")
struct ChatServiceTests {
    var memoryManager: MemoryManager!
    var mockAdapter: MockAPIAdapter!
    var chatService: ChatService!
    var dummyModel: RunnableModel!

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

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let mockSession = URLSession(configuration: config)

        chatService = ChatService(adapters: ["openai-compatible": mockAdapter], memoryManager: memoryManager, urlSession: mockSession)

        dummyModel = RunnableModel(
            provider: seededProviders[0],
            model: seededProviders[0].models[0]
        )
        chatService.setSelectedModel(dummyModel)
    }

    func cleanup() async {
        let allMems = await memoryManager.getAllMemories()
        if !allMems.isEmpty {
            await memoryManager.deleteMemories(allMems)
        }
        Persistence.clearRequestLogs()
        Persistence.deleteAppConfig(key: AppConfigKey.enableReasoningSummary.rawValue)
        Persistence.deleteAppConfig(key: AppConfigKey.speechModelIdentifier.rawValue)
        Persistence.deleteAppConfig(key: AppConfigKey.ttsModelIdentifier.rawValue)
        Persistence.deleteAppConfig(key: AppConfigKey.memoryEmbeddingModelIdentifier.rawValue)
        Persistence.deleteAppConfig(key: AppConfigKey.titleGenerationModelIdentifier.rawValue)
        Persistence.deleteAppConfig(key: AppConfigKey.dailyPulseModelIdentifier.rawValue)
        Persistence.deleteAppConfig(key: AppConfigKey.conversationSummaryModelIdentifier.rawValue)
        Persistence.deleteAppConfig(key: AppConfigKey.reasoningSummaryModelIdentifier.rawValue)
        Persistence.deleteAppConfig(key: AppConfigKey.reasoningContentEchoMode.rawValue)
        Persistence.deleteAppConfig(key: AppConfigKey.ocrModelIdentifier.rawValue)
        Persistence.deleteAppConfig(key: AppConfigKey.imageGenerationModelIdentifier.rawValue)
        Persistence.deleteAppConfig(key: AppConfigKey.imageGenerationParameterExpressionsByModel.rawValue)
        Persistence.deleteAppConfig(key: AppConfigKey.enableMemory.rawValue)
        Persistence.deleteAppConfig(key: AppConfigKey.enableMemoryWrite.rawValue)
        Persistence.deleteAppConfig(key: AppConfigKey.enableMemoryActiveRetrieval.rawValue)
        Persistence.deleteAppConfig(key: AppConfigKey.memoryTopK.rawValue)
        Persistence.deleteAppConfig(key: AppConfigKey.enableConversationMemoryAsync.rawValue)
        Persistence.deleteAppConfig(key: AppConfigKey.conversationMemoryRecentLimit.rawValue)
        Persistence.deleteAppConfig(key: AppConfigKey.conversationMemoryRoundThreshold.rawValue)
        Persistence.deleteAppConfig(key: AppConfigKey.conversationMemorySummaryMinIntervalMinutes.rawValue)
        Persistence.deleteAppConfig(key: AppConfigKey.enableConversationProfileDailyUpdate.rawValue)
        _ = ConversationMemoryManager.clearAllSessionSummaries()
        try? ConversationMemoryManager.clearUserProfile()
        MockURLProtocol.mockResponses = [:]
        mockAdapter.receivedMessages = nil
        mockAdapter.receivedTitleMessages = nil
        mockAdapter.receivedReasoningSummaryMessages = nil
        mockAdapter.receivedTools = nil
        mockAdapter.receivedAudioAttachments = nil
        mockAdapter.receivedImageAttachments = nil
        mockAdapter.receivedFileAttachments = nil
        mockAdapter.responseToReturn = nil
        mockAdapter.receivedChatModel = nil
        mockAdapter.receivedTitleModel = nil
        mockAdapter.receivedReasoningSummaryModel = nil
        ShortcutToolStore.saveTools([])
        await MainActor.run {
            ShortcutToolManager.shared.reloadFromDisk()
            ShortcutToolManager.shared.setChatToolsEnabled(false)
        }
        chatService.createNewSession()
    }

    func setupMockResponsesForChatAndTitle(title: String = "测试标题") {
        let chatURL = URL(string: "https://fake.url/chat")!
        let titleURL = URL(string: "https://fake.url/title-gen")!
        let chatHTTPResponse = HTTPURLResponse(url: chatURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        let titleHTTPResponse = HTTPURLResponse(url: titleURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        let titleJSON = #"{"choices":[{"message":{"content":"\#(title)"}}]}"#.data(using: .utf8) ?? Data()
        MockURLProtocol.mockResponses[chatURL] = .success((chatHTTPResponse, Data()))
        MockURLProtocol.mockResponses[titleURL] = .success((titleHTTPResponse, titleJSON))
        mockAdapter.responseToReturn = ChatMessage(role: .assistant, content: "聊天回复")
    }

    func setupMockReasoningSummaryResponse(summary: String) {
        let summaryURL = URL(string: "https://fake.url/reasoning-summary")!
        let summaryHTTPResponse = HTTPURLResponse(url: summaryURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        let summaryJSON = #"{"choices":[{"message":{"content":"\#(summary)"}}]}"#.data(using: .utf8) ?? Data()
        MockURLProtocol.mockResponses[summaryURL] = .success((summaryHTTPResponse, summaryJSON))
    }

    func createPermanentTestSession(name: String = "附件文本化测试") -> ChatSession {
        let session = chatService.createSavedSession(name: name)
        chatService.setCurrentSession(session)
        return session
    }

    func activatedChatModels() -> [RunnableModel] {
        chatService.activatedRunnableModels.filter { $0.model.isChatModel }
    }
}

@Suite("Persistence Tests")
struct PersistenceTests {
    var chatsDirectory: URL {
        Persistence.getChatsDirectory()
    }

    var currentSessionsDirectory: URL {
        chatsDirectory.appendingPathComponent("sessions")
    }

    var currentIndexFileURL: URL {
        chatsDirectory.appendingPathComponent("index.json")
    }

    var foldersFileURL: URL {
        chatsDirectory.appendingPathComponent("folders.json")
    }

    var legacySessionDirectory: URL {
        chatsDirectory.appendingPathComponent("v3")
    }

    var legacySessionIndexFileURL: URL {
        legacySessionDirectory.appendingPathComponent("index.json")
    }

    var legacyRootDirectory: URL {
        chatsDirectory.appendingPathComponent("legacy")
    }

    var requestLogsDirectory: URL {
        chatsDirectory.appendingPathComponent("RequestLogs")
    }

    var chatStoreSQLiteURL: URL {
        chatsDirectory.appendingPathComponent("chat-store.sqlite")
    }

    var chatStoreSQLiteWALURL: URL {
        chatsDirectory.appendingPathComponent("chat-store.sqlite-wal")
    }

    var chatStoreSQLiteSHMURL: URL {
        chatsDirectory.appendingPathComponent("chat-store.sqlite-shm")
    }

    var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    var configDirectory: URL {
        documentsDirectory.appendingPathComponent("Config")
    }

    var memoryDirectory: URL {
        documentsDirectory.appendingPathComponent("Memory")
    }

    var memoryRawMemoriesFileURL: URL {
        memoryDirectory.appendingPathComponent("memories.json")
    }

    var memoryUserProfileFileURL: URL {
        memoryDirectory.appendingPathComponent("user_profile.json")
    }

    var shortcutToolsDirectory: URL {
        documentsDirectory.appendingPathComponent("ShortcutTools")
    }

    var shortcutToolsFileURL: URL {
        shortcutToolsDirectory.appendingPathComponent("tools.json")
    }

    var configStoreSQLiteURL: URL {
        configDirectory.appendingPathComponent("config-store.sqlite")
    }

    var configStoreSQLiteWALURL: URL {
        configDirectory.appendingPathComponent("config-store.sqlite-wal")
    }

    var configStoreSQLiteSHMURL: URL {
        configDirectory.appendingPathComponent("config-store.sqlite-shm")
    }

    var legacyConfigStoreSQLiteURL: URL {
        chatsDirectory.appendingPathComponent("config-store.sqlite")
    }

    var legacyConfigStoreSQLiteWALURL: URL {
        chatsDirectory.appendingPathComponent("config-store.sqlite-wal")
    }

    var legacyConfigStoreSQLiteSHMURL: URL {
        chatsDirectory.appendingPathComponent("config-store.sqlite-shm")
    }

    var memoryStoreSQLiteURL: URL {
        memoryDirectory.appendingPathComponent("memory-store.sqlite")
    }

    var memoryStoreSQLiteWALURL: URL {
        memoryDirectory.appendingPathComponent("memory-store.sqlite-wal")
    }

    var memoryStoreSQLiteSHMURL: URL {
        memoryDirectory.appendingPathComponent("memory-store.sqlite-shm")
    }

    var chatStoreBackupDirectory: URL {
        chatsDirectory.appendingPathComponent("StartupBackups")
    }

    var chatStoreBackupSQLiteURL: URL {
        chatStoreBackupDirectory.appendingPathComponent("chat-store.sqlite")
    }

    var configStoreBackupDirectory: URL {
        configDirectory.appendingPathComponent("StartupBackups")
    }

    var configStoreBackupSQLiteURL: URL {
        configStoreBackupDirectory.appendingPathComponent("config-store.sqlite")
    }

    var memoryStoreBackupDirectory: URL {
        memoryDirectory.appendingPathComponent("StartupBackups")
    }

    var memoryStoreBackupSQLiteURL: URL {
        memoryStoreBackupDirectory.appendingPathComponent("memory-store.sqlite")
    }

    var legacyMemoryStoreSQLiteURL: URL {
        chatsDirectory.appendingPathComponent("memory-store.sqlite")
    }

    var legacyMemoryStoreSQLiteWALURL: URL {
        chatsDirectory.appendingPathComponent("memory-store.sqlite-wal")
    }

    var legacyMemoryStoreSQLiteSHMURL: URL {
        chatsDirectory.appendingPathComponent("memory-store.sqlite-shm")
    }

    var legacySessionsIndexURL: URL {
        chatsDirectory.appendingPathComponent("sessions.json")
    }

    func currentSessionFileURL(_ sessionID: UUID) -> URL {
        currentSessionsDirectory
            .appendingPathComponent("\(sessionID.uuidString).json")
    }

    func legacySessionFileURL(_ sessionID: UUID) -> URL {
        legacySessionDirectory
            .appendingPathComponent("sessions")
            .appendingPathComponent("\(sessionID.uuidString).json")
    }

    func legacyMessageFileURL(_ sessionID: UUID) -> URL {
        chatsDirectory.appendingPathComponent("\(sessionID.uuidString).json")
    }

    func removeIfExists(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    func sqliteExists(_ url: URL, sql: String) -> Bool {
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

    func sqliteCount(_ url: URL, sql: String) -> Int {
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

    func sqliteExecute(_ url: URL, sql: String) {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database else {
            return
        }
        defer { sqlite3_close(database) }
        _ = sqlite3_exec(database, sql, nil, nil, nil)
    }

    func readStoredZipEntries(from archiveURL: URL) throws -> [String: Data] {
        let archiveData = try Data(contentsOf: archiveURL)
        var offset = 0
        var entries: [String: Data] = [:]

        while offset + 30 <= archiveData.count {
            let signature = archiveData.littleEndianUInt32(at: offset)
            guard signature == 0x0403_4B50 else { break }

            let compressionMethod = archiveData.littleEndianUInt16(at: offset + 8)
            let compressedSize = Int(archiveData.littleEndianUInt32(at: offset + 18))
            let fileNameLength = Int(archiveData.littleEndianUInt16(at: offset + 26))
            let extraFieldLength = Int(archiveData.littleEndianUInt16(at: offset + 28))
            let fileNameStart = offset + 30
            let fileNameEnd = fileNameStart + fileNameLength
            let dataStart = fileNameEnd + extraFieldLength
            let dataEnd = dataStart + compressedSize

            guard compressionMethod == 0,
                  fileNameEnd <= archiveData.count,
                  dataEnd <= archiveData.count,
                  let path = String(data: archiveData[fileNameStart..<fileNameEnd], encoding: .utf8) else {
                break
            }

            entries[path] = archiveData.subdata(in: dataStart..<dataEnd)
            offset = dataEnd
        }

        return entries
    }

    func cleanup(sessions: [ChatSession]) {
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
}

private extension Data {
    func littleEndianUInt16(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func littleEndianUInt32(at offset: Int) -> UInt32 {
        UInt32(littleEndianUInt16(at: offset)) | (UInt32(littleEndianUInt16(at: offset + 2)) << 16)
    }
}
