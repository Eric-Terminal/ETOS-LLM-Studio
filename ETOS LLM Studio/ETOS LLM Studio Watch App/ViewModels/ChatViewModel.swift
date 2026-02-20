// ============================================================================
// ChatViewModel.swift
// ============================================================================ 
// ETOS LLM Studio Watch App 核心视图模型文件 (已重构)
//
// 功能特性:
// - 驱动主视图 (ContentView) 的所有业务逻辑
// - 管理应用状态，包括消息、会话、设置等
// - 处理网络请求、数据操作和用户交互
// ============================================================================

import Foundation
import SwiftUI
import WatchKit
import os.log
import Combine
import Shared
import AVFoundation
import AVFAudio
#if canImport(CoreImage)
import CoreImage
#endif

private let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "ChatViewModel")

@MainActor
class ChatViewModel: ObservableObject {
    // MARK: - @Published 属性 (UI 状态)
    
    @Published private(set) var messages: [ChatMessageRenderState] = []
    @Published private(set) var displayMessages: [ChatMessageRenderState] = []
    private(set) var allMessagesForSession: [ChatMessage] = []
    @Published var isHistoryFullyLoaded: Bool = false
    @Published var userInput: String = ""
    @Published var messageToEdit: ChatMessage?
    @Published var activeSheet: ActiveSheet?
    
    @Published var chatSessions: [ChatSession] = []
    @Published var currentSession: ChatSession?
    
    @Published var providers: [Provider] = []
    @Published var configuredModels: [RunnableModel] = []
    @Published var selectedModel: RunnableModel?
    @Published var activatedModels: [RunnableModel] = []
    
    @Published var memories: [MemoryItem] = []
    
    // 重构: 用于管理UI状态，与数据模型分离
    @Published var reasoningExpandedState: [UUID: Bool] = [:]
    @Published var toolCallsExpandedState: [UUID: Bool] = [:]
    @Published var isSendingMessage: Bool = false
    @Published var speechModels: [RunnableModel] = []
    @Published var selectedSpeechModel: RunnableModel?
    @Published var selectedEmbeddingModel: RunnableModel?
    @Published var isSpeechRecorderPresented: Bool = false
    @Published var isRecordingSpeech: Bool = false
    @Published var speechTranscriptionInProgress: Bool = false
    @Published var speechErrorMessage: String?
    @Published var showSpeechErrorAlert: Bool = false
    @Published var showDimensionMismatchAlert: Bool = false
    @Published var dimensionMismatchMessage: String = ""
    @Published var showMemoryEmbeddingErrorAlert: Bool = false
    @Published var memoryEmbeddingErrorMessage: String = ""
    @Published var memoryEmbeddingProgress: MemoryEmbeddingProgress?
    @Published var recordingDuration: TimeInterval = 0
    @Published var waveformSamples: [CGFloat] = Array(repeating: 0, count: 24)
    @Published var pendingAudioAttachment: AudioAttachment? = nil  // 待发送的音频附件
    @Published private(set) var latestAssistantMessageID: UUID?
    @Published private(set) var toolCallResultIDs: Set<String> = []
    @Published var imageGenerationFeedback: ImageGenerationFeedback = .idle
    @Published var mathRenderOverrides: Set<UUID> = []
    
    // MARK: - 用户偏好设置 (AppStorage)
    
    @AppStorage("enableMarkdown") var enableMarkdown: Bool = true
    @AppStorage("enableAdvancedRenderer") var enableAdvancedRenderer: Bool = false {
        didSet {
            if !enableAdvancedRenderer {
                mathRenderOverrides.removeAll()
            }
        }
    }
    @AppStorage("enableBackground") var enableBackground: Bool = true {
        didSet { refreshBlurredBackgroundImage() }
    }
    @AppStorage("backgroundBlur") var backgroundBlur: Double = 10.0 {
        didSet { refreshBlurredBackgroundImage() }
    }
    @AppStorage("backgroundOpacity") var backgroundOpacity: Double = 0.7
    @AppStorage("backgroundContentMode") var backgroundContentMode: String = "fill" // "fill" 或 "fit"
    @AppStorage("aiTemperature") var aiTemperature: Double = 1.0
    @AppStorage("aiTopP") var aiTopP: Double = 0.95
    @AppStorage("systemPrompt") var systemPrompt: String = ""
    @AppStorage("maxChatHistory") var maxChatHistory: Int = 0
    @AppStorage("enableStreaming") var enableStreaming: Bool = false
    @AppStorage("enableResponseSpeedMetrics") var enableResponseSpeedMetrics: Bool = false
    @AppStorage("lazyLoadMessageCount") var lazyLoadMessageCount: Int = 3
    @AppStorage("currentBackgroundImage") var currentBackgroundImage: String = "" {
        didSet { refreshBlurredBackgroundImage() }
    }
    @AppStorage("enableAutoRotateBackground") var enableAutoRotateBackground: Bool = false
    @AppStorage("enableAutoSessionNaming") var enableAutoSessionNaming: Bool = true
    @AppStorage("enableMemory") var enableMemory: Bool = true
    @AppStorage("enableMemoryWrite") var enableMemoryWrite: Bool = true
    @AppStorage("enableMemoryActiveRetrieval") var enableMemoryActiveRetrieval: Bool = false
    @AppStorage("enableLiquidGlass") var enableLiquidGlass: Bool = false
    @AppStorage("sendSpeechAsAudio") var sendSpeechAsAudio: Bool = false
    @AppStorage("enableSpeechInput") var enableSpeechInput: Bool = false
    @AppStorage("speechModelIdentifier") var speechModelIdentifier: String = ""
    @AppStorage("memoryEmbeddingModelIdentifier") var memoryEmbeddingModelIdentifier: String = ""
    @AppStorage("includeSystemTimeInPrompt") var includeSystemTimeInPrompt: Bool = true
    @AppStorage("audioRecordingFormat") var audioRecordingFormatRaw: String = AudioRecordingFormat.aac.rawValue
    
    var audioRecordingFormat: AudioRecordingFormat {
        get { AudioRecordingFormat(rawValue: audioRecordingFormatRaw) ?? .aac }
        set { audioRecordingFormatRaw = newValue.rawValue }
    }
    
    // MARK: - 公开属性
    
    @Published var backgroundImages: [String] = []
    @Published private(set) var currentBackgroundImageBlurredUIImage: UIImage?
    
    var currentBackgroundImageUIImage: UIImage? {
        guard !currentBackgroundImage.isEmpty else { return nil }
        return loadBackgroundImage(named: currentBackgroundImage)
    }
    
    var embeddingModelOptions: [RunnableModel] {
        configuredModels
    }

    func toggleMathRendering(for messageID: UUID) {
        if mathRenderOverrides.contains(messageID) {
            mathRenderOverrides.remove(messageID)
        } else {
            mathRenderOverrides.insert(messageID)
        }
    }

    func isMathRenderingEnabled(for messageID: UUID) -> Bool {
        guard enableAdvancedRenderer else { return false }
        return mathRenderOverrides.contains(messageID)
    }
    
    var historyLoadChunkSize: Int {
        incrementalHistoryBatchSize
    }

    var remainingHistoryCount: Int {
        max(0, allMessagesForSession.count - messages.count)
    }

    var historyLoadChunkCount: Int {
        min(remainingHistoryCount, historyLoadChunkSize)
    }

    var isMemoryEmbeddingInProgress: Bool {
        memoryEmbeddingProgress?.phase == .running
    }
    
    // MARK: - 私有属性
    
    private var extendedSession: WKExtendedRuntimeSession?
    private let chatService: ChatService
    private var cancellables = Set<AnyCancellable>()
    private var additionalHistoryLoaded: Int = 0
    private var lastSessionID: UUID?
    private let incrementalHistoryBatchSize = 5
    private var audioRecorder: AVAudioRecorder?
    private var speechRecordingURL: URL?
    private var recordingStartDate: Date?
    private var recordingTimer: Timer?
    private let waveformSampleCount: Int = 24
    private var allMessageStates: [ChatMessageRenderState] = []
    private var messageStateByID: [UUID: ChatMessageRenderState] = [:]
    private let backgroundImageCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 6
        return cache
    }()
    private let blurredBackgroundImageCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 6
        return cache
    }()
    private var backgroundBlurTask: Task<Void, Never>?

    enum ImageGenerationFeedbackPhase {
        case idle
        case running
        case success
        case failure
        case cancelled
    }

    struct ImageGenerationFeedback {
        var phase: ImageGenerationFeedbackPhase
        var prompt: String
        var startedAt: Date?
        var finishedAt: Date?
        var imageCount: Int
        var errorMessage: String?
        var referenceCount: Int

        static let idle = ImageGenerationFeedback(
            phase: .idle,
            prompt: "",
            startedAt: nil,
            finishedAt: nil,
            imageCount: 0,
            errorMessage: nil,
            referenceCount: 0
        )
    }
    
    // MARK: - 初始化

    /// 主应用使用的便利初始化方法
    convenience init() {
        self.init(chatService: .shared)
    }

    /// 用于测试和依赖注入的指定初始化方法
    internal init(chatService: ChatService) {
        logger.info("ChatViewModel initializing with specific service.")
        self.chatService = chatService
        self.backgroundImages = ConfigLoader.loadBackgroundImages()

        // 设置 Combine 订阅
        setupSubscriptions()
        
        // 监听应用返回前台事件，以重置可能卡住的状态
        NotificationCenter.default.addObserver(self, selector: #selector(handleDidBecomeActive), name: WKApplication.didBecomeActiveNotification, object: nil)

        // 自动轮换背景逻辑
        rotateBackgroundImageIfNeeded()
        refreshBlurredBackgroundImage()
        
        logger.info("ChatViewModel initialized and subscribed to ChatService.")
    }
    
    @objc private func handleDidBecomeActive() {
        logger.info("App became active, checking for interrupted state.")
        // [BUG FIX] This logic was too aggressive. It incorrectly assumed a request
        // was interrupted when the app became active while a request was in flight.
        // The underlying URLSession's timeout is the correct way to handle this.
        // if isSendingMessage {
        //     logger.warning("  - Message sending was interrupted. Resetting state.")
        //     isSendingMessage = false
        //     chatService.addErrorMessage("网络请求已中断，请重试。")
        // }
    }
    
    private func setupSubscriptions() {
        chatService.chatSessionsSubject
            .receive(on: DispatchQueue.main)
            .assign(to: \.chatSessions, on: self)
            .store(in: &cancellables)
            
        chatService.currentSessionSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] session in
                guard let self else { return }
                currentSession = session
                imageGenerationFeedback = .idle
            }
            .store(in: &cancellables)
            
        chatService.messagesForSessionSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] messages in
                self?.applyMessagesUpdate(messages)
            }
            .store(in: &cancellables)
        
        chatService.providersSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] providers in
                guard let self = self else { return }
                self.providers = providers
                self.configuredModels = self.chatService.configuredRunnableModels
                self.activatedModels = self.chatService.activatedRunnableModels
                self.speechModels = self.chatService.activatedSpeechModels
                self.syncSpeechModelSelection()
                self.syncEmbeddingModelSelection()
            }
            .store(in: &cancellables)

        chatService.selectedModelSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] model in
                guard let self else { return }
                selectedModel = model
            }
            .store(in: &cancellables)
            
        chatService.requestStatusSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                switch status {
                case .started:
                    self?.isSendingMessage = true
                    self?.startExtendedSession()
                case .finished, .error, .cancelled:
                    self?.isSendingMessage = false
                    self?.stopExtendedSession()
                @unknown default:
                    // 为未来可能的状态保留，不做任何操作
                    break
                }
            }
            .store(in: &cancellables)

        chatService.imageGenerationStatusSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.applyImageGenerationStatus(status)
            }
            .store(in: &cancellables)
        
        
            
        MemoryManager.shared.memoriesPublisher
            .receive(on: DispatchQueue.main)
            .assign(to: \.memories, on: self)
            .store(in: &cancellables)
        
        MemoryManager.shared.dimensionMismatchPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (queryDim, indexDim) in
                self?.dimensionMismatchMessage = "嵌入维度不匹配！\n查询维度: \(queryDim)\n索引维度: \(indexDim)\n\n请前往记忆库管理页面，点击“重新生成全部嵌入”按钮。"
                self?.showDimensionMismatchAlert = true
            }
            .store(in: &cancellables)
        
        MemoryManager.shared.embeddingProgressPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] progress in
                self?.memoryEmbeddingProgress = progress
            }
            .store(in: &cancellables)
        
        MemoryManager.shared.embeddingErrorPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] error in
                guard let self else { return }
                self.memoryEmbeddingErrorMessage = String(
                    format: NSLocalizedString(
                        "记忆已保存，但向量嵌入失败：%@",
                        comment: "Message shown when memory text is stored but embedding generation failed."
                    ),
                    error.localizedDescription
                )
                self.showMemoryEmbeddingErrorAlert = true
            }
            .store(in: &cancellables)
        
        NotificationCenter.default.publisher(for: .syncBackgroundsUpdated)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshBackgroundImages()
            }
            .store(in: &cancellables)
        
        syncSpeechModelSelection()
        syncEmbeddingModelSelection()
    }
    
    private func rotateBackgroundImageIfNeeded() {
        refreshBackgroundImages()
        guard enableAutoRotateBackground, !backgroundImages.isEmpty else { return }
        let availableBackgrounds = backgroundImages.filter { $0 != currentBackgroundImage }
        currentBackgroundImage = availableBackgrounds.randomElement() ?? backgroundImages.randomElement() ?? ""
        logger.info("自动轮换背景，新背景: \(self.currentBackgroundImage, privacy: .public)")
    }
    
    // MARK: - 公开方法 (视图操作)
    
    // MARK: 消息流
    
    func sendMessage() {
        logger.info("sendMessage called.")
        let userMessageContent = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasText = !userMessageContent.isEmpty
        let hasAudio = pendingAudioAttachment != nil
        
        // 必须有文字或音频附件才能发送
        guard (hasText || hasAudio), !isSendingMessage else { return }
        
        let audioToSend = pendingAudioAttachment
        userInput = ""
        pendingAudioAttachment = nil
        
        // 构建消息内容（仅使用用户输入文本）
        let messageContent = userMessageContent
        
        Task {
            await chatService.sendAndProcessMessage(
                content: messageContent,
                aiTemperature: aiTemperature,
                aiTopP: aiTopP,
                systemPrompt: systemPrompt,
                maxChatHistory: maxChatHistory,
                enableStreaming: enableStreaming,
                enhancedPrompt: currentSession?.enhancedPrompt,
                enableMemory: enableMemory,
                enableMemoryWrite: enableMemoryWrite,
                enableMemoryActiveRetrieval: enableMemoryActiveRetrieval,
                includeSystemTime: includeSystemTimeInPrompt,
                enableResponseSpeedMetrics: enableResponseSpeedMetrics,
                audioAttachment: audioToSend
            )
        }
    }

    func cancelSending() {
        Task {
            await chatService.cancelOngoingRequest()
        }
    }
    
    /// 清除待发送的音频附件
    func clearPendingAudioAttachment() {
        pendingAudioAttachment = nil
    }

    var imageGenerationModelOptions: [RunnableModel] {
        activatedModels.filter { supportsImageGeneration(for: $0) }
    }

    var supportsImageGenerationForSelectedModel: Bool {
        supportsImageGeneration(for: selectedModel)
    }

    func supportsImageGeneration(for runnableModel: RunnableModel?) -> Bool {
        guard let runnableModel else { return false }
        if runnableModel.model.supportsImageGeneration {
            return true
        }
        let lowered = runnableModel.model.modelName.lowercased()
        return lowered.contains("gpt-image")
            || lowered.contains("imagen")
            || lowered.contains("image")
            || lowered.contains("dall")
    }

    func imageGenerationModel(with identifier: String) -> RunnableModel? {
        guard !identifier.isEmpty else { return nil }
        return imageGenerationModelOptions.first(where: { $0.id == identifier })
    }

    func generateImage(
        prompt: String,
        referenceImages: [ImageAttachment] = [],
        model: RunnableModel? = nil,
        runtimeOverrideParameters: [String: JSONValue] = [:]
    ) {
        guard !isSendingMessage else { return }
        Task {
            await chatService.generateImageAndProcessMessage(
                prompt: prompt,
                imageAttachments: referenceImages,
                runnableModel: model,
                runtimeOverrideParameters: runtimeOverrideParameters
            )
        }
    }

    func clearImageGenerationFeedback() {
        imageGenerationFeedback = .idle
    }

    func retryLastImageGeneration(
        model: RunnableModel? = nil,
        referenceImages: [ImageAttachment] = [],
        runtimeOverrideParameters: [String: JSONValue] = [:]
    ) {
        let prompt = imageGenerationFeedback.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        generateImage(
            prompt: prompt,
            referenceImages: referenceImages,
            model: model,
            runtimeOverrideParameters: runtimeOverrideParameters
        )
    }

    func removeGeneratedImage(fileName: String, fromMessageID messageID: UUID) {
        guard let sessionID = currentSession?.id else { return }
        guard let messageIndex = allMessagesForSession.firstIndex(where: { $0.id == messageID }) else { return }

        var updatedMessages = allMessagesForSession
        var updatedMessage = updatedMessages[messageIndex]
        guard var imageFileNames = updatedMessage.imageFileNames else { return }

        imageFileNames.removeAll { $0 == fileName }
        updatedMessage.imageFileNames = imageFileNames.isEmpty ? nil : imageFileNames
        updatedMessages[messageIndex] = updatedMessage

        chatService.updateMessages(updatedMessages, for: sessionID)
        saveCurrentSessionDetails()

        let isStillReferenced = updatedMessages.contains { message in
            (message.imageFileNames ?? []).contains(fileName)
        }
        if !isStillReferenced {
            Persistence.deleteImage(fileName: fileName)
        }
    }
    
    func addErrorMessage(_ content: String) {
        chatService.addErrorMessage(content)
    }
    
    func retryMessage(_ message: ChatMessage) {
        Task {
            await chatService.retryMessage(
                message,
                aiTemperature: aiTemperature,
                aiTopP: aiTopP,
                systemPrompt: systemPrompt,
                maxChatHistory: maxChatHistory,
                enableStreaming: enableStreaming,
                enhancedPrompt: currentSession?.enhancedPrompt,
                enableMemory: enableMemory,
                enableMemoryWrite: enableMemoryWrite,
                enableMemoryActiveRetrieval: enableMemoryActiveRetrieval,
                includeSystemTime: includeSystemTimeInPrompt,
                enableResponseSpeedMetrics: enableResponseSpeedMetrics
            )
        }
    }
    
    func retryLastMessage() {
        // 移除 isSendingMessage 保护，允许中断当前正在发送的请求。
        // ChatService 中的 retryLastMessage 会处理重置消息历史的逻辑。
        Task {
            await chatService.retryLastMessage(
                aiTemperature: aiTemperature,
                aiTopP: aiTopP,
                systemPrompt: systemPrompt,
                maxChatHistory: maxChatHistory,
                enableStreaming: enableStreaming,
                enhancedPrompt: currentSession?.enhancedPrompt,
                enableMemory: enableMemory,
                enableMemoryWrite: enableMemoryWrite,
                enableMemoryActiveRetrieval: enableMemoryActiveRetrieval,
                includeSystemTime: includeSystemTimeInPrompt,
                enableResponseSpeedMetrics: enableResponseSpeedMetrics
            )
        }
    }
    
    // MARK: 语音输入
    
    func setSelectedSpeechModel(_ model: RunnableModel?) {
        selectedSpeechModel = model
        let newIdentifier = model?.id ?? ""
        if speechModelIdentifier != newIdentifier {
            speechModelIdentifier = newIdentifier
        }
    }
    
    func setSelectedEmbeddingModel(_ model: RunnableModel?) {
        selectedEmbeddingModel = model
        let newIdentifier = model?.id ?? ""
        if memoryEmbeddingModelIdentifier != newIdentifier {
            memoryEmbeddingModelIdentifier = newIdentifier
        }
    }
    
    func appendTranscribedText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if userInput.isEmpty {
            userInput = trimmed
        } else {
            let needsSpace = !(userInput.last?.isWhitespace ?? true)
            userInput += (needsSpace ? " " : "") + trimmed
        }
    }
    
    func clearUserInput() {
        userInput = ""
    }
    
    func beginSpeechInputFlow() {
        guard enableSpeechInput else {
            presentSpeechError("请先在高级设置中开启语言输入功能。")
            return
        }
        if !sendSpeechAsAudio {
            guard !speechModels.isEmpty else {
                presentSpeechError("暂无可用的模型，请先在模型设置中启用。")
                return
            }
            guard selectedSpeechModel != nil else {
                presentSpeechError("请选择一个语音转文字模型。")
                return
            }
        }
        speechErrorMessage = nil
        showSpeechErrorAlert = false
        isSpeechRecorderPresented = true
    }
    
    func startSpeechRecording() async {
        guard !isRecordingSpeech else { return }
        guard enableSpeechInput else {
            presentSpeechError("语言输入已被关闭。")
            isSpeechRecorderPresented = false
            return
        }
        if !sendSpeechAsAudio {
            guard selectedSpeechModel != nil else {
                presentSpeechError("尚未选择语音转文字模型。")
                isSpeechRecorderPresented = false
                return
            }
        }
        
        let permissionGranted = await requestMicrophonePermission()
        guard permissionGranted else {
            presentSpeechError("麦克风权限被拒绝，请到设置中开启。")
            isSpeechRecorderPresented = false
            return
        }
        
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            
            if let existingURL = speechRecordingURL {
                try? FileManager.default.removeItem(at: existingURL)
            }
            let targetURL = FileManager.default.temporaryDirectory.appendingPathComponent("speech-\(UUID().uuidString).\(audioRecordingFormat.fileExtension)")
            
            let settings: [String: Any]
            switch audioRecordingFormat {
            case .aac:
                settings = [
                    AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                    AVSampleRateKey: 44100,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: 64000
                ]
            case .wav:
                settings = [
                    AVFormatIDKey: Int(kAudioFormatLinearPCM),
                    AVSampleRateKey: 44100,
                    AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false
                ]
            @unknown default:
                settings = [
                    AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                    AVSampleRateKey: 44100,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: 64000
                ]
            }
            
            audioRecorder = try AVAudioRecorder(url: targetURL, settings: settings)
            audioRecorder?.isMeteringEnabled = true
            audioRecorder?.prepareToRecord()
            guard audioRecorder?.record() == true else {
                throw NSError(domain: "SpeechRecorder", code: -1, userInfo: [NSLocalizedDescriptionKey: "录音启动失败。"])
            }
            
            speechRecordingURL = targetURL
            isRecordingSpeech = true
            resetRecordingVisuals()
            startRecordingTimer()
        } catch {
            presentSpeechError(
                String(
                    format: NSLocalizedString("开始录音失败: %@", comment: ""),
                    error.localizedDescription
                )
            )
            isSpeechRecorderPresented = false
            stopRecordingTimer(resetVisuals: true)
            audioRecorder = nil
            speechRecordingURL = nil
        }
    }
    
    func finishSpeechRecording() {
        guard isRecordingSpeech else { return }
        isRecordingSpeech = false
        audioRecorder?.stop()
        stopRecordingTimer()
        guard let url = speechRecordingURL else {
            audioRecorder = nil
            speechRecordingURL = nil
            isSpeechRecorderPresented = false
            presentSpeechError("录音文件未找到，无法处理。")
            resetRecordingVisuals()
            return
        }
        
        speechTranscriptionInProgress = true
        if sendSpeechAsAudio {
            isSpeechRecorderPresented = false
        }
        Task {
            defer {
                speechTranscriptionInProgress = false
                isSpeechRecorderPresented = false
                audioRecorder = nil
                speechRecordingURL = nil
                try? FileManager.default.removeItem(at: url)
                resetRecordingVisuals()
            }
            do {
                let data = try Data(contentsOf: url)
                if sendSpeechAsAudio {
                    // 不立即发送，而是暂存为待发送附件
                    let attachment = AudioAttachment(
                        data: data,
                        mimeType: audioRecordingFormat.mimeType,
                        format: audioRecordingFormat.fileExtension,
                        fileName: url.lastPathComponent
                    )
                    await MainActor.run {
                        pendingAudioAttachment = attachment
                    }
                } else {
                    guard let speechModel = selectedSpeechModel else {
                        throw NSError(domain: "SpeechRecorder", code: -2, userInfo: [NSLocalizedDescriptionKey: "尚未选择语音转文字模型。"])
                    }
                    let transcript = try await chatService.transcribeAudio(
                        using: speechModel,
                        audioData: data,
                        fileName: url.lastPathComponent,
                        mimeType: audioRecordingFormat.mimeType
                    )
                    appendTranscribedText(transcript)
                }
            } catch {
                presentSpeechError(error.localizedDescription)
            }
        }
    }
    
    func cancelSpeechRecording() {
        if isRecordingSpeech {
            audioRecorder?.stop()
            isRecordingSpeech = false
        }
        speechTranscriptionInProgress = false
        if let url = speechRecordingURL {
            try? FileManager.default.removeItem(at: url)
        }
        audioRecorder = nil
        speechRecordingURL = nil
        isSpeechRecorderPresented = false
        stopRecordingTimer(resetVisuals: true)
    }
    
    private func resetRecordingVisuals() {
        recordingDuration = 0
        waveformSamples = Array(repeating: 0, count: waveformSampleCount)
    }
    
    private func startRecordingTimer() {
        stopRecordingTimer()
        recordingStartDate = Date()
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateRecordingMetrics()
            }
        }
        if let timer = recordingTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }
    
    private func stopRecordingTimer(resetVisuals: Bool = false) {
        recordingTimer?.invalidate()
        recordingTimer = nil
        recordingStartDate = nil
        if resetVisuals {
            resetRecordingVisuals()
        }
    }
    
    @MainActor
    private func updateRecordingMetrics() {
        guard let recorder = audioRecorder else { return }
        recorder.updateMeters()
        let power = recorder.averagePower(forChannel: 0)
        let normalizedLevel = max(0, min(1, (power + 60) / 60))
        recordingDuration = Date().timeIntervalSince(recordingStartDate ?? Date())
        var samples = waveformSamples
        samples.append(CGFloat(normalizedLevel))
        if samples.count > waveformSampleCount {
            samples.removeFirst(samples.count - waveformSampleCount)
        }
        waveformSamples = samples
    }
    
    // MARK: 会话和消息管理
    
    func deleteMessage(at offsets: IndexSet) {
        // 此方法已废弃，因为直接操作 messages 数组不安全
        // 应该通过 message ID 来删除
    }
    
    func deleteMessage(_ message: ChatMessage) {
        chatService.deleteMessage(message)
    }
    
    // MARK: - Message Version Management
    
    /// 切换到指定消息的上一个版本
    func switchToPreviousVersion(of message: ChatMessage) {
        guard var updatedMessage = findMessage(by: message.id),
              updatedMessage.hasMultipleVersions else { return }
        
        let newIndex = max(0, updatedMessage.getCurrentVersionIndex() - 1)
        updatedMessage.switchToVersion(newIndex)
        updateMessage(updatedMessage)
    }
    
    /// 切换到指定消息的下一个版本
    func switchToNextVersion(of message: ChatMessage) {
        guard var updatedMessage = findMessage(by: message.id),
              updatedMessage.hasMultipleVersions else { return }
        
        let newIndex = min(updatedMessage.getAllVersions().count - 1, updatedMessage.getCurrentVersionIndex() + 1)
        updatedMessage.switchToVersion(newIndex)
        updateMessage(updatedMessage)
    }
    
    /// 切换到指定版本
    func switchToVersion(_ index: Int, of message: ChatMessage) {
        guard var updatedMessage = findMessage(by: message.id) else { return }
        updatedMessage.switchToVersion(index)
        updateMessage(updatedMessage)
    }
    
    /// 删除指定消息的当前版本（如果只剩一个版本则删除整个消息）
    func deleteCurrentVersion(of message: ChatMessage) {
        guard var updatedMessage = findMessage(by: message.id) else { return }
        
        if updatedMessage.getAllVersions().count <= 1 {
            // 只剩一个版本，删除整个消息
            deleteMessage(updatedMessage)
        } else {
            // 删除当前版本
            updatedMessage.removeVersion(at: updatedMessage.getCurrentVersionIndex())
            updateMessage(updatedMessage)
        }
    }
    
    /// 添加新版本到消息（用于重试功能）
    func addVersionToMessage(_ message: ChatMessage, newContent: String) {
        guard var updatedMessage = findMessage(by: message.id) else { return }
        updatedMessage.addVersion(newContent)
        updateMessage(updatedMessage)
    }
    
    // MARK: - Helper Methods
    
    private func findMessage(by id: UUID) -> ChatMessage? {
        allMessagesForSession.first { $0.id == id }
    }
    
    private func updateMessage(_ message: ChatMessage) {
        guard let index = allMessagesForSession.firstIndex(where: { $0.id == message.id }) else { return }
        var updatedMessages = allMessagesForSession
        updatedMessages[index] = message
        chatService.updateMessages(updatedMessages, for: currentSession?.id ?? UUID())
        saveCurrentSessionDetails()
    }
    
    func deleteSession(at offsets: IndexSet) {
        let sessionsToDelete = offsets.map { chatSessions[$0] }
        chatService.deleteSessions(sessionsToDelete)
    }
    
    func deleteSessions(_ sessions: [ChatSession]) {
        chatService.deleteSessions(sessions)
    }
    
    @discardableResult
    func branchSession(from sourceSession: ChatSession, copyMessages: Bool) -> ChatSession {
        return chatService.branchSession(from: sourceSession, copyMessages: copyMessages)
    }
    
    @discardableResult
    func branchSessionFromMessage(upToMessage: ChatMessage, copyPrompts: Bool) -> ChatSession {
        guard let session = currentSession else {
            logger.error("无法创建分支会话：当前会话为空，将创建新会话作为回退。")
            chatService.createNewSession()
            if let fallbackSession = chatService.currentSessionSubject.value {
                return fallbackSession
            }
            logger.error("创建新会话失败，返回临时会话实例作为回退。")
            return ChatSession(id: UUID(), name: "新的对话", isTemporary: true)
        }
        return chatService.branchSessionFromMessage(from: session, upToMessage: upToMessage, copyPrompts: copyPrompts)
    }
    
    func deleteLastMessage(for session: ChatSession) {
        chatService.deleteLastMessage(for: session)
    }
    
    func createNewSession() {
        chatService.createNewSession()
    }
    
    // MARK: 记忆管理
    
    func addMemory(content: String) async {
        await MemoryManager.shared.addMemory(content: content)
    }

    func updateMemory(item: MemoryItem) async {
        await MemoryManager.shared.updateMemory(item: item)
    }
    
    func archiveMemory(_ item: MemoryItem) async {
        await MemoryManager.shared.archiveMemory(item)
    }
    
    func unarchiveMemory(_ item: MemoryItem) async {
        await MemoryManager.shared.unarchiveMemory(item)
    }

    func deleteMemories(at offsets: IndexSet) async {
        let itemsToDelete = offsets.map { memories[$0] }
        await MemoryManager.shared.deleteMemories(itemsToDelete)
    }
    
    func reembedAllMemories() async throws -> MemoryReembeddingSummary {
        try await MemoryManager.shared.reembedAllMemories()
    }
    
    // MARK: 视图状态与持久化
    
    private func applyMessagesUpdate(_ incomingMessages: [ChatMessage]) {
        allMessagesForSession = incomingMessages
        
        var newStates: [ChatMessageRenderState] = []
        newStates.reserveCapacity(incomingMessages.count)
        var newIDs = Set<UUID>()
        var newToolCallResultIDs = Set<String>()
        var newestAssistantID: UUID?
        
        for message in incomingMessages {
            newIDs.insert(message.id)
            
            let state: ChatMessageRenderState
            if let existing = messageStateByID[message.id] {
                state = existing
            } else {
                let created = ChatMessageRenderState(message: message)
                messageStateByID[message.id] = created
                state = created
            }
            state.update(with: message)
            newStates.append(state)
            
            if message.role != .tool, let toolCalls = message.toolCalls, !toolCalls.isEmpty {
                for call in toolCalls {
                    let trimmedResult = (call.result ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmedResult.isEmpty {
                        newToolCallResultIDs.insert(call.id)
                    }
                }
            }
            
            if message.role == .assistant {
                newestAssistantID = message.id
            }
        }
        
        if messageStateByID.count != newIDs.count {
            messageStateByID = messageStateByID.filter { newIDs.contains($0.key) }
        }
        
        allMessageStates = newStates
        updateDisplayedMessages()
        
        if toolCallResultIDs != newToolCallResultIDs {
            toolCallResultIDs = newToolCallResultIDs
            updateDisplayMessagesIfNeeded()
        }
        if latestAssistantMessageID != newestAssistantID {
            latestAssistantMessageID = newestAssistantID
        }
    }

    private func applyImageGenerationStatus(_ status: ChatService.ImageGenerationStatus) {
        switch status {
        case .started(let sessionID, _, let prompt, let startedAt, let referenceCount):
            guard sessionID == currentSession?.id else { return }
            imageGenerationFeedback = ImageGenerationFeedback(
                phase: .running,
                prompt: prompt,
                startedAt: startedAt,
                finishedAt: nil,
                imageCount: 0,
                errorMessage: nil,
                referenceCount: referenceCount
            )
        case .succeeded(let sessionID, _, let prompt, let imageFileNames, let finishedAt):
            guard sessionID == currentSession?.id else { return }
            imageGenerationFeedback = ImageGenerationFeedback(
                phase: .success,
                prompt: prompt,
                startedAt: imageGenerationFeedback.startedAt,
                finishedAt: finishedAt,
                imageCount: imageFileNames.count,
                errorMessage: nil,
                referenceCount: imageGenerationFeedback.referenceCount
            )
        case .failed(let sessionID, _, let prompt, let reason, let finishedAt):
            guard sessionID == nil || sessionID == currentSession?.id else { return }
            imageGenerationFeedback = ImageGenerationFeedback(
                phase: .failure,
                prompt: prompt,
                startedAt: imageGenerationFeedback.startedAt,
                finishedAt: finishedAt,
                imageCount: 0,
                errorMessage: reason,
                referenceCount: imageGenerationFeedback.referenceCount
            )
        case .cancelled(let sessionID, _, let prompt, let finishedAt):
            guard sessionID == nil || sessionID == currentSession?.id else { return }
            imageGenerationFeedback = ImageGenerationFeedback(
                phase: .cancelled,
                prompt: prompt,
                startedAt: imageGenerationFeedback.startedAt,
                finishedAt: finishedAt,
                imageCount: 0,
                errorMessage: nil,
                referenceCount: imageGenerationFeedback.referenceCount
            )
        default:
            imageGenerationFeedback = .idle
        }
    }
    
    func updateDisplayedMessages() {
        let filtered = visibleMessages(from: allMessageStates)
        
        if lastSessionID != currentSession?.id {
            lastSessionID = currentSession?.id
            additionalHistoryLoaded = 0
        }
        
        let lazyCount = lazyLoadMessageCount
        if lazyCount > 0 && filtered.count > lazyCount {
            let limit = lazyCount + additionalHistoryLoaded
            if filtered.count > limit {
                let subset = Array(filtered.suffix(limit))
                updateDisplayedStatesIfNeeded(subset)
                updateHistoryFullyLoadedIfNeeded(false)
            } else {
                updateDisplayedStatesIfNeeded(filtered)
                updateHistoryFullyLoadedIfNeeded(true)
                additionalHistoryLoaded = max(additionalHistoryLoaded, max(0, filtered.count - lazyCount))
            }
        } else {
            updateDisplayedStatesIfNeeded(filtered)
            updateHistoryFullyLoadedIfNeeded(true)
            additionalHistoryLoaded = 0
        }
    }
    
    func loadEntireHistory() {
        let filtered = visibleMessages(from: allMessageStates)
        additionalHistoryLoaded = max(0, filtered.count - lazyLoadMessageCount)
        updateDisplayedStatesIfNeeded(filtered)
        updateHistoryFullyLoadedIfNeeded(true)
    }
    
    func loadMoreHistoryChunk(count: Int? = nil) {
        guard !isHistoryFullyLoaded else { return }
        let increment = count ?? incrementalHistoryBatchSize
        additionalHistoryLoaded += increment
        updateDisplayedMessages()
    }
    
    /// 重置懒加载状态，恢复到初始加载数量
    func resetLazyLoadState() {
        additionalHistoryLoaded = 0
        updateDisplayedMessages()
    }

    func saveCurrentSessionDetails() {
        if let session = currentSession {
            chatService.updateSession(session)
        }
    }
    
    func commitEditedMessage(_ message: ChatMessage) {
        chatService.updateMessage(message)
        messageToEdit = nil
    }
    
    func updateSession(_ session: ChatSession) {
        chatService.updateSession(session)
    }
    
    func canRetry(message: ChatMessage) -> Bool {
        // 所有 user 和 assistant 消息都可以重试
        // 但如果正在发送，只允许重试最后一条或倍数第二条
        if isSendingMessage {
            guard let lastMessage = allMessagesForSession.last else { return false }
            if lastMessage.id == message.id { return true }
            if let secondLast = allMessagesForSession.dropLast().last, secondLast.role == .user {
                return secondLast.id == message.id
            }
            return false
        }

        // 不在发送时，所有 user 和 assistant 消息都可以重试
        return message.role == .user || message.role == .assistant || message.role == .error
    }
    
    // MARK: - 私有方法 (内部逻辑)
    
    private func refreshBackgroundImages() {
        let images = ConfigLoader.loadBackgroundImages()
        backgroundImages = images
        if !images.contains(currentBackgroundImage) {
            currentBackgroundImage = images.first ?? ""
        }
        refreshBlurredBackgroundImage()
    }
    
    private func requestMicrophonePermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            return false
        }
    }
    
    private func presentSpeechError(_ message: String) {
        speechErrorMessage = message
        showSpeechErrorAlert = true
    }
    
    private func syncSpeechModelSelection() {
        if let match = speechModels.first(where: { $0.id == speechModelIdentifier }) {
            if selectedSpeechModel?.id != match.id {
                selectedSpeechModel = match
            }
            return
        }
        guard !speechModelIdentifier.isEmpty else {
            selectedSpeechModel = nil
            return
        }
        guard !speechModels.isEmpty else {
            return
        }
        selectedSpeechModel = nil
        speechModelIdentifier = ""
    }
    
    private func syncEmbeddingModelSelection() {
        if let match = embeddingModelOptions.first(where: { $0.id == memoryEmbeddingModelIdentifier }) {
            if selectedEmbeddingModel?.id != match.id {
                selectedEmbeddingModel = match
            }
            return
        }
        guard !memoryEmbeddingModelIdentifier.isEmpty else {
            selectedEmbeddingModel = nil
            return
        }
        guard !embeddingModelOptions.isEmpty else {
            return
        }
        selectedEmbeddingModel = nil
        memoryEmbeddingModelIdentifier = ""
    }
    
    private func startExtendedSession() {
        extendedSession = WKExtendedRuntimeSession()
        extendedSession?.start()
    }
    
    private func stopExtendedSession() {
        extendedSession?.invalidate()
        extendedSession = nil
    }
    
    private func updateDisplayedStatesIfNeeded(_ newStates: [ChatMessageRenderState]) {
        let currentIDs = messages.map(\.id)
        let newIDs = newStates.map(\.id)
        guard currentIDs != newIDs else { return }
        messages = newStates
        updateDisplayMessagesIfNeeded(with: newStates)
    }
    
    private func updateHistoryFullyLoadedIfNeeded(_ newValue: Bool) {
        guard isHistoryFullyLoaded != newValue else { return }
        isHistoryFullyLoaded = newValue
    }
    
    private func visibleMessages(from source: [ChatMessageRenderState]) -> [ChatMessageRenderState] {
        source
    }

    private func updateDisplayMessagesIfNeeded(with source: [ChatMessageRenderState]? = nil) {
        let base = source ?? messages
        let filtered = filterDisplayMessages(base)
        let currentIDs = displayMessages.map(\.id)
        let newIDs = filtered.map(\.id)
        guard currentIDs != newIDs else { return }
        displayMessages = filtered
    }

    private func filterDisplayMessages(_ source: [ChatMessageRenderState]) -> [ChatMessageRenderState] {
        guard !toolCallResultIDs.isEmpty else { return source }
        return source.filter { state in
            let message = state.message
            guard message.role == .tool else { return true }
            guard let toolCalls = message.toolCalls, !toolCalls.isEmpty else { return true }
            return toolCalls.allSatisfy { !toolCallResultIDs.contains($0.id) }
        }
    }

    private func loadBackgroundImage(named name: String) -> UIImage? {
        if let cached = backgroundImageCache.object(forKey: name as NSString) {
            return cached
        }
        let fileURL = ConfigLoader.getBackgroundsDirectory().appendingPathComponent(name)
        guard let image = UIImage(contentsOfFile: fileURL.path) else { return nil }
        backgroundImageCache.setObject(image, forKey: name as NSString)
        return image
    }

    private func blurredCacheKey(for name: String, radius: Double) -> NSString {
        let scaled = Int((radius * 10).rounded())
        return "\(name)|blur:\(scaled)" as NSString
    }

    private func refreshBlurredBackgroundImage() {
        backgroundBlurTask?.cancel()
        guard enableBackground, !currentBackgroundImage.isEmpty else {
            currentBackgroundImageBlurredUIImage = nil
            return
        }
        guard let baseImage = loadBackgroundImage(named: currentBackgroundImage) else {
            currentBackgroundImageBlurredUIImage = nil
            return
        }
        guard let baseCGImage = baseImage.cgImage else {
            currentBackgroundImageBlurredUIImage = baseImage
            return
        }
        let baseScale = baseImage.scale
        let baseOrientation = baseImage.imageOrientation
        let radius = backgroundBlur
        if radius <= 0.01 {
            currentBackgroundImageBlurredUIImage = baseImage
            return
        }
        let cacheKey = blurredCacheKey(for: currentBackgroundImage, radius: radius)
        if let cached = blurredBackgroundImageCache.object(forKey: cacheKey) {
            currentBackgroundImageBlurredUIImage = cached
            return
        }
        currentBackgroundImageBlurredUIImage = baseImage
        let expectedName = currentBackgroundImage
        let expectedRadius = radius
        backgroundBlurTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let blurredCGImage: CGImage?
            #if canImport(CoreImage)
            let ciImage = CIImage(cgImage: baseCGImage)
            if let filter = CIFilter(name: "CIGaussianBlur") {
                filter.setValue(ciImage, forKey: kCIInputImageKey)
                filter.setValue(expectedRadius, forKey: kCIInputRadiusKey)
                if let output = filter.outputImage {
                    let cropped = output.cropped(to: ciImage.extent)
                    let context = CIContext()
                    blurredCGImage = context.createCGImage(cropped, from: ciImage.extent)
                } else {
                    blurredCGImage = nil
                }
            } else {
                blurredCGImage = nil
            }
            #else
            blurredCGImage = nil
            #endif
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self.enableBackground,
                      self.currentBackgroundImage == expectedName,
                      self.backgroundBlur == expectedRadius else { return }
                let blurredUIImage = blurredCGImage.map {
                    UIImage(cgImage: $0, scale: baseScale, orientation: baseOrientation)
                }
                if let blurredUIImage {
                    self.blurredBackgroundImageCache.setObject(blurredUIImage, forKey: cacheKey)
                }
                self.currentBackgroundImageBlurredUIImage = blurredUIImage ?? self.currentBackgroundImageUIImage
            }
        }
    }

}
