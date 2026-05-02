// ============================================================================
// ChatService.swift
// ============================================================================ 
// ETOS LLM Studio
//
// 本类作为应用的中央大脑，处理所有与平台无关的业务逻辑。
// 它被设计为单例，以便在应用的不同部分（iOS 和 watchOS）之间共享。
// ============================================================================ 

import Foundation
import Combine
import CryptoKit
import os.log
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

/// 一个组合了 Provider 和 Model 的可运行实体，包含了发起 API 请求所需的所有信息。

public class ChatService {
    
    let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "ChatService")
    static let toolNameRegex = try! NSRegularExpression(pattern: "[^a-zA-Z0-9_.-]", options: [])
    static let modelOrderStorageKey = "modelOrder.runnableModels"
    static let selectedRunnableModelStorageKey = "selectedRunnableModelID"
    static let titleGenerationModelStorageKey = "titleGenerationModelIdentifier"
    public static let ocrModelStorageKey = "ocrModelIdentifier"
    static let ttsModelStorageKey = "ttsModelIdentifier"
    static let conversationSummaryModelStorageKey = "conversationSummaryModelIdentifier"
    static let reasoningSummaryModelStorageKey = "reasoningSummaryModelIdentifier"
    static let lastActiveSessionIDStorageKey = "launch.lastActiveSessionID"
    public static let restoreLastSessionOnLaunchEnabledStorageKey = "launch.restoreLastSessionOnLaunchEnabled"
    static let conversationMemoryEnabledKey = "enableConversationMemoryAsync"
    static let conversationMemoryRecentLimitKey = "conversationMemoryRecentLimit"
    static let conversationMemoryRoundThresholdKey = "conversationMemoryRoundThreshold"
    static let conversationMemorySummaryMinIntervalMinutesKey = "conversationMemorySummaryMinIntervalMinutes"
    static let conversationProfileDailyUpdateEnabledKey = "enableConversationProfileDailyUpdate"
    static let reasoningSummaryEnabledKey = "enableReasoningSummary"

    var consecutiveRetrySignature: RetryAchievementSignature?
    var consecutiveRetryCount = 0
    public static let systemSpeechRecognizerProviderID = UUID(uuidString: "2FB43D6B-8E40-4D65-9EA6-C13AB41D8A2E")!
    public static let systemSpeechRecognizerModelID = UUID(uuidString: "EE2F84DF-F640-47B8-9A83-BE438905C4F3")!
    public static let systemOCRProviderID = UUID(uuidString: "4301D30F-D7C6-4A4F-A45B-F8721CD68099")!
    public static let systemOCRModelID = UUID(uuidString: "40B2DA2B-3E72-4A29-954E-29FECAD1C1DF")!
    public static let systemSpeechRecognizerRunnableModel: RunnableModel = {
        let provider = Provider(
            id: systemSpeechRecognizerProviderID,
            name: "SFSpeechRecognizer",
            baseURL: "local://sf-speech-recognizer",
            apiKeys: [],
            apiFormat: "local-speech"
        )
        let model = Model(
            id: systemSpeechRecognizerModelID,
            modelName: "sf-speech-recognizer",
            displayName: "SFSpeechRecognizer",
            isActivated: true,
            kind: .speechToText
        )
        return RunnableModel(provider: provider, model: model)
    }()

    public static let systemOCRRunnableModel: RunnableModel = {
        let provider = Provider(
            id: systemOCRProviderID,
            name: NSLocalizedString("系统 OCR", comment: "System OCR provider name"),
            baseURL: "local://system-ocr",
            apiKeys: [],
            apiFormat: "local-ocr"
        )
        let model = Model(
            id: systemOCRModelID,
            modelName: "vision-ocr",
            displayName: NSLocalizedString("系统 OCR", comment: "System OCR model display name"),
            isActivated: true,
            kind: .chat,
            inputModalities: [.text, .image],
            outputModalities: [.text],
            capabilities: []
        )
        return RunnableModel(provider: provider, model: model)
    }()

    // MARK: - 单例
    public static let shared = ChatService()

    // MARK: - 用于 UI 订阅的公开 Subjects
    
    public let chatSessionsSubject: CurrentValueSubject<[ChatSession], Never>
    public let sessionFoldersSubject: CurrentValueSubject<[SessionFolder], Never>
    public let currentSessionSubject: CurrentValueSubject<ChatSession?, Never>
    public let messagesForSessionSubject: CurrentValueSubject<[ChatMessage], Never>
    
    public let providersSubject: CurrentValueSubject<[Provider], Never>
    public let selectedModelSubject: CurrentValueSubject<RunnableModel?, Never>

    public let requestStatusSubject = PassthroughSubject<RequestStatus, Never>()
    public let imageGenerationStatusSubject = PassthroughSubject<ImageGenerationStatus, Never>()
    public let runningSessionIDsSubject = CurrentValueSubject<Set<UUID>, Never>([])
    public let sessionRequestStatusSubject = PassthroughSubject<SessionRequestStatusEvent, Never>()

    // MARK: - 私有状态
    
    var cancellables = Set<AnyCancellable>()
    /// 每个会话独立维护请求上下文，支持跨会话并发。
    var requestContextBySessionID: [UUID: RequestExecutionContext] = [:]
    let requestStateLock = NSRecursiveLock()
    /// 记录每个会话上一次注入周期性时间路标的时间，保证路标按周期出现且不会过于频繁。
    var periodicTimeLandmarkLastInjectedAtBySessionID: [UUID: Date] = [:]
    /// 重试时要添加新版本的assistant消息ID（如果有）
    var retryTargetMessageID: UUID?
    /// 重试 assistant 时保留原始消息快照，便于失败或取消时恢复，避免把错误写入版本历史。
    var retryTargetOriginalAssistantMessage: ChatMessage?
    var providers: [Provider]
    let startupTemporarySession: ChatSession
    let adapters: [String: APIAdapter]
    let memoryManager: MemoryManager
    let worldbookStore: WorldbookStore
    let worldbookImportService: WorldbookImportService
    let worldbookExportService: WorldbookExportService
    let worldbookEngine: WorldbookEngine
    let urlSession: URLSession
    let fileAttachmentTextExtractor: FileAttachmentTextExtractor
    let startupStateLoadLock = NSLock()
    var hasTriggeredStartupStateLoad = false
    var hasCompletedStartupStateLoad = false
    var startupStateLoadTask: Task<Void, Never>?
    let audioAttachmentDataCache: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.countLimit = 24
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()
    let imageAttachmentDataCache: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.countLimit = 96
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()
    let fileAttachmentDataCache: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.countLimit = 32
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()

    // MARK: - 初始化
    
    public init(
        adapters: [String: APIAdapter]? = nil,
        memoryManager: MemoryManager = .shared,
        worldbookStore: WorldbookStore = .shared,
        worldbookImportService: WorldbookImportService = WorldbookImportService(),
        worldbookExportService: WorldbookExportService = WorldbookExportService(),
        worldbookEngine: WorldbookEngine = WorldbookEngine(),
        fileAttachmentTextExtractor: FileAttachmentTextExtractor = FileAttachmentTextExtractor(),
        urlSession: URLSession = NetworkSessionConfiguration.shared
    ) {
        logger.info("ChatService 正在初始化...")
        
        self.memoryManager = memoryManager
        self.worldbookStore = worldbookStore
        self.worldbookImportService = worldbookImportService
        self.worldbookExportService = worldbookExportService
        self.worldbookEngine = worldbookEngine
        self.fileAttachmentTextExtractor = fileAttachmentTextExtractor
        self.urlSession = urlSession
        ConfigLoader.setupInitialProviderConfigs()
        ConfigLoader.setupBackgroundsDirectory()
        self.providers = ConfigLoader.loadProviders()
        let startupTemporarySession = ChatSession(id: UUID(), name: "新的对话", isTemporary: true)
        self.startupTemporarySession = startupTemporarySession
        self.adapters = adapters ?? [
            "openai-compatible": OpenAIAdapter(),
            "gemini": GeminiAdapter(),
            "anthropic": AnthropicAdapter(),
        ]

        let launchState = Self.isRunningUnitTests
            ? Self.loadLaunchPersistenceState(using: startupTemporarySession)
            : nil

        self.providersSubject = CurrentValueSubject(self.providers)
        self.selectedModelSubject = CurrentValueSubject(nil)
        self.chatSessionsSubject = CurrentValueSubject(
            launchState?.loadedSessions ?? [startupTemporarySession]
        )
        self.sessionFoldersSubject = CurrentValueSubject(
            launchState?.sessionFolders ?? []
        )
        self.currentSessionSubject = CurrentValueSubject(
            launchState?.initialSession ?? startupTemporarySession
        )
        self.messagesForSessionSubject = CurrentValueSubject(
            launchState?.initialMessages ?? []
        )
        self.reconcileStoredModelOrder()
        self.currentSessionSubject
            .sink { [weak self] session in
                self?.persistLastActiveSessionIDIfNeeded(session)
            }
            .store(in: &cancellables)
        
        let savedModelID = UserDefaults.standard.string(forKey: Self.selectedRunnableModelStorageKey)
        let allRunnable = activatedRunnableModels
        var initialModel: RunnableModel? = allRunnable.first { $0.id == savedModelID }
        if initialModel == nil {
            initialModel = allRunnable.first
        }
        self.selectedModelSubject.send(initialModel)
        
        ConfigLoader.fetchDownloadOnceConfigsIfNeeded { [weak self] in
            self?.reloadProviders()
        }

        logger.info("  - 初始选中模型为: \(initialModel?.model.displayName ?? "无")")
        if !Self.isRunningUnitTests {
            logger.info("  - 已切换为启动后异步加载持久化会话状态。")
        }
        logger.info("  - 初始化完成。")
        AppLog.developer(
            category: "chat_service",
            action: "initialize",
            message: "ChatService 初始化完成",
            payload: [
                "providerCount": "\(self.providers.count)",
                "selectedModel": initialModel?.model.displayName ?? "无"
            ]
        )
        AppLog.userOperation(
            category: "应用",
            action: "初始化聊天服务",
            payload: ["providerCount": "\(self.providers.count)"]
        )
    }
}
