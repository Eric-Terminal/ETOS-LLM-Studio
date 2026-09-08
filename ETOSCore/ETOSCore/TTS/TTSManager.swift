import Foundation
import Combine
import os.log
#if canImport(AVFoundation)
import AVFoundation
#endif

@MainActor
public final class TTSManager: NSObject, ObservableObject {
    public static let shared = TTSManager()

    @Published public internal(set) var isSpeaking: Bool = false
    @Published public internal(set) var playbackState: TTSPlaybackState = .init()
    @Published public internal(set) var currentSpeakingMessageID: UUID?
    @Published var cachedNetworkAudioExport: TTSAudioExport?

    let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "TTSManager")
    let settingsStore = TTSSettingsStore.shared
    let urlSession: URLSession

    var queue: [QueueItem] = []
    var workerTask: Task<Void, Never>?
    var workerGeneration = 0
    var preparationTask: Task<Void, Never>?
    var preparationGeneration = 0
    var prefetchTasks: [UUID: Task<AudioClip, Error>] = [:]
    let prefetchWindowSize: Int = 1
    var activeNetworkItemIDs: [UUID] = []
    var activeNetworkItemTexts: [UUID: String] = [:]
    var activeNetworkClips: [UUID: AudioClip] = [:]
    var lastNetworkChunkTexts: [String] = []
    var lastNetworkAudioClips: [AudioClip] = []
    var pendingReplayChunkTexts: [String] = []
    var pendingReplayAudioClips: [AudioClip] = []
    var audioExportRevision = 0
    var isPausedByUser = false
    var activeBackend: ActiveBackend = .none
    private var isApplicationInBackground = false

#if canImport(AVFoundation)
    var audioPlayer: AVAudioPlayer?
    var audioContinuation: CheckedContinuation<Void, Error>?
    var progressTimer: Timer?
#endif

#if os(iOS) || os(watchOS)
    lazy var speechSynthesizer: AVSpeechSynthesizer = {
        let synthesizer = AVSpeechSynthesizer()
        synthesizer.delegate = self
        return synthesizer
    }()
    var speechContinuation: CheckedContinuation<Void, Error>?
    var activeSpeechUtterance: AVSpeechUtterance?
    var speechMonitorTask: Task<Void, Never>?
    var speechDidStart = false
    var ownsPlaybackAudioSession = false
#endif

    struct QueueItem: Identifiable {
        let id = UUID()
        let messageID: UUID?
        let text: String
        let playbackModeOverride: TTSPlaybackMode?
        let serviceOverride: TTSServiceConfiguration?
        let cachedClip: AudioClip?
    }

    /// 用于在朗读结束后执行“重试朗读”
    struct ReplayRequest {
        let messageID: UUID?
        let text: String
        let playbackModeOverride: TTSPlaybackMode?
        let serviceOverride: TTSServiceConfiguration?
    }

    enum ActiveBackend {
        case none
        case system
        case cloud
    }

    struct AudioClip: Sendable {
        var data: Data
        var format: String
        var sampleRate: Int?
        var channels: Int = 1
    }

    var lastReplayRequest: ReplayRequest?

    public init(urlSession: URLSession = NetworkSessionConfiguration.shared) {
        self.urlSession = urlSession
        super.init()
    }

    public func speak(
        _ text: String,
        messageID: UUID? = nil,
        flush: Bool = true,
        playbackModeOverride: TTSPlaybackMode? = nil,
        serviceOverride: TTSServiceConfiguration? = nil
    ) {
        guard TTSBackgroundPlaybackPolicy.allowsPlayback(
            isApplicationInBackground: isApplicationInBackground,
            continuePlaybackInBackground: AppConfigStore.shared.continueTTSPlaybackInBackground
        ) else {
            logger.info("应用位于后台且未允许后台继续朗读，忽略朗读请求。")
            return
        }

        let settings = settingsStore.snapshot
        let selectionMode = TTSTextSelectionMode(rawValue: AppConfigStore.shared.ttsTextSelectionMode)
            ?? (settings.onlyReadQuotedContent ? .quotedOnly : .fullText)
        let filterCodeAndHTML = AppConfigStore.shared.ttsFilterCodeAndHTML
#if os(watchOS)
        let maxCharacters = min(max(settings.watchSpeechMaxCharacters, 500), 6_000)
        let lightweight = settings.watchUseLightweightPreprocess
#else
        let maxCharacters = 12_000
        let lightweight = false
#endif
        let replayAudioClips = pendingReplayAudioClips
        let replayChunkTexts = pendingReplayChunkTexts
        pendingReplayAudioClips = []
        pendingReplayChunkTexts = []
        let request = ReplayRequest(
            messageID: messageID,
            text: text,
            playbackModeOverride: playbackModeOverride,
            serviceOverride: serviceOverride
        )

        if flush {
            preparationGeneration &+= 1
            preparationTask?.cancel()
            preparationTask = nil
            workerGeneration &+= 1
            workerTask?.cancel()
            workerTask = nil
            stopCurrentPlayback(clearQueueOnly: true)
            clearPrefetchState()
            queue = []
            playbackState.currentChunkIndex = 0
            playbackState.totalChunks = 0
            playbackState.position = 0
            playbackState.duration = 0
            playbackState.status = .idle
            audioExportRevision &+= 1
            cachedNetworkAudioExport = nil
            lastNetworkChunkTexts = []
            lastNetworkAudioClips = []
            activeNetworkItemTexts = [:]
            activeNetworkClips = [:]
            activeNetworkItemIDs = []
        }

        if workerTask == nil {
            isSpeaking = true
            currentSpeakingMessageID = messageID
            playbackState.status = .buffering
            playbackState.errorMessage = nil
        }
        let generation = preparationGeneration
        let previousPreparation = preparationTask
        preparationTask = Task { [weak self] in
            // 追加朗读保持请求顺序；停止或替换后，旧预处理结果不得重新启动播放。
            await previousPreparation?.value
            guard !Task.isCancelled else { return }
            let preparation = Task.detached(priority: .userInitiated) {
                guard !Task.isCancelled else { return [String]() }
                let processed = Self.preprocessText(
                    text, mode: selectionMode, filterCodeAndHTML: filterCodeAndHTML,
                    lightweight: lightweight, maxCharacters: maxCharacters
                )
                guard !Task.isCancelled else { return [String]() }
                return Self.splitTextForPlayback(processed)
            }
            let chunks = await withTaskCancellationHandler {
                await preparation.value
            } onCancel: {
                preparation.cancel()
            }
            guard !Task.isCancelled, let self, generation == self.preparationGeneration else { return }
            guard !chunks.isEmpty else {
                if self.workerTask == nil {
                    self.deactivateTTSAudioSessionIfNeeded()
                    self.isSpeaking = false
                    self.currentSpeakingMessageID = nil
                    self.playbackState.status = .idle
                }
                return
            }
            self.enqueuePreparedSpeech(
                chunks, request: request,
                replayChunkTexts: replayChunkTexts, replayAudioClips: replayAudioClips
            )
        }
    }

    private func enqueuePreparedSpeech(
        _ chunks: [String],
        request: ReplayRequest,
        replayChunkTexts: [String],
        replayAudioClips: [AudioClip]
    ) {
        logger.info("TTS 入队：分段数=\(chunks.count, privacy: .public)")
        lastReplayRequest = request
        let canReuseNetworkAudio = chunks == replayChunkTexts && chunks.count == replayAudioClips.count
        let newItems = chunks.enumerated().map { index, chunk in
            QueueItem(
                messageID: request.messageID,
                text: chunk,
                playbackModeOverride: request.playbackModeOverride,
                serviceOverride: request.serviceOverride,
                cachedClip: canReuseNetworkAudio ? replayAudioClips[index] : nil
            )
        }
        queue.append(contentsOf: newItems)
        activeNetworkItemIDs.append(contentsOf: newItems.map(\.id))
        for item in newItems {
            activeNetworkItemTexts[item.id] = item.text
        }

        if workerTask == nil || workerTask?.isCancelled == true {
            workerGeneration &+= 1
            let generation = workerGeneration
            workerTask = Task { [weak self] in
                await self?.processQueue(generation: generation)
            }
        }
    }

    public var canReplayLastRequest: Bool {
        guard let request = lastReplayRequest else { return false }
        return !request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 重新朗读上一条成功提交的文本，便于在播放结束后快速重试
    public func replayLastRequest() {
        guard let request = lastReplayRequest else { return }
        if AppConfigStore.shared.ttsCacheNetworkAudioForReplay {
            pendingReplayChunkTexts = lastNetworkChunkTexts
            pendingReplayAudioClips = lastNetworkAudioClips
        }
        speak(
            request.text,
            messageID: request.messageID,
            flush: true,
            playbackModeOverride: request.playbackModeOverride,
            serviceOverride: request.serviceOverride
        )
    }

    public func preview(_ text: String, using service: TTSServiceConfiguration) {
        speak(
            text,
            flush: true,
            playbackModeOverride: .cloud,
            serviceOverride: service.normalized
        )
    }

    public func pause() {
        guard isSpeaking else { return }
        isPausedByUser = true
#if canImport(AVFoundation)
        switch activeBackend {
        case .cloud:
            audioPlayer?.pause()
            playbackState.status = .paused
        case .system:
#if os(iOS) || os(watchOS)
            _ = speechSynthesizer.pauseSpeaking(at: .word)
            playbackState.status = .paused
#endif
        case .none:
            // 文本仍在后台预处理时也要显示暂停状态，才能让用户继续朗读。
            playbackState.status = .paused
        }
#endif
    }

    public func resume() {
        guard isSpeaking else { return }
        isPausedByUser = false
#if canImport(AVFoundation)
        switch activeBackend {
        case .cloud:
            audioPlayer?.play()
            playbackState.status = .playing
        case .system:
#if os(iOS) || os(watchOS)
            _ = speechSynthesizer.continueSpeaking()
            playbackState.status = .playing
#endif
        case .none:
            playbackState.status = .buffering
        }
#endif
    }

    public func stop() {
        preparationGeneration &+= 1
        preparationTask?.cancel()
        preparationTask = nil
        workerGeneration &+= 1
        workerTask?.cancel()
        workerTask = nil
        stopCurrentPlayback(clearQueueOnly: false)
        deactivateTTSAudioSessionIfNeeded()
        clearPrefetchState()
        queue = []
        activeNetworkItemIDs = []
        activeNetworkItemTexts = [:]
        activeNetworkClips = [:]
        isSpeaking = false
        currentSpeakingMessageID = nil
        playbackState = .init(speed: settingsStore.playbackSpeed)
    }

    /// 根视图在场景进入或离开后台时调用，确保朗读行为与用户设置一致。
    public func setApplicationIsInBackground(_ isInBackground: Bool) {
        isApplicationInBackground = isInBackground
        guard !TTSBackgroundPlaybackPolicy.allowsPlayback(
            isApplicationInBackground: isInBackground,
            continuePlaybackInBackground: AppConfigStore.shared.continueTTSPlaybackInBackground
        ) else { return }
        stop()
    }

    public func seekBy(seconds: TimeInterval) {
#if canImport(AVFoundation)
        guard let audioPlayer else { return }
        let destination = max(0, min(audioPlayer.duration, audioPlayer.currentTime + seconds))
        audioPlayer.currentTime = destination
        playbackState.position = destination
#endif
    }

    public func setPlaybackSpeed(_ speed: Float) {
#if canImport(AVFoundation)
        guard let audioPlayer else {
            playbackState.speed = speed
            return
        }
        audioPlayer.enableRate = true
        audioPlayer.rate = speed
        playbackState.speed = speed
#endif
    }

}
