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

    let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "TTSManager")
    let settingsStore = TTSSettingsStore.shared
    let urlSession: URLSession

    var selectedModel: RunnableModel?
    var queue: [QueueItem] = []
    var workerTask: Task<Void, Never>?
    var prefetchTasks: [UUID: Task<AudioClip, Error>] = [:]
    let prefetchWindowSize: Int = 1
    var isPausedByUser = false
    var activeBackend: ActiveBackend = .none

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
    var speechMonitorTask: Task<Void, Never>?
    var speechDidStart = false
#endif

    struct QueueItem: Identifiable {
        let id = UUID()
        let messageID: UUID?
        let text: String
    }

    /// 用于在朗读结束后执行“重试朗读”
    struct ReplayRequest {
        let messageID: UUID?
        let text: String
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
    }

    var lastReplayRequest: ReplayRequest?

    public init(urlSession: URLSession = NetworkSessionConfiguration.shared) {
        self.urlSession = urlSession
        super.init()
    }

    public func updateSelectedModel(_ model: RunnableModel?) {
        selectedModel = model
    }

    public func speak(_ text: String, messageID: UUID? = nil, flush: Bool = true) {
        logger.info("TTS 收到朗读请求：原始长度=\(text.count, privacy: .public)")
#if DEBUG
        print("[TTS] 收到朗读请求，原始长度=\(text.count)")
#endif

        let settings = settingsStore.snapshot
        let boundedText = boundedSpeechInput(text, settings: settings)
        if boundedText.count < text.count {
            logger.info("TTS 文本已截断：截断后长度=\(boundedText.count, privacy: .public)")
#if DEBUG
            print("[TTS] 文本已截断，截断后长度=\(boundedText.count)")
#endif
        }

        let processed = preprocessText(boundedText, settings: settings)
        guard !processed.isEmpty else { return }

        let chunks = splitText(processed)
        guard !chunks.isEmpty else { return }

        logger.info("TTS 入队：分段数=\(chunks.count, privacy: .public)，播放模式=\(settings.playbackMode.rawValue, privacy: .public)")

        lastReplayRequest = ReplayRequest(messageID: messageID, text: text)

        if flush {
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
        }

        let newItems = chunks.map { QueueItem(messageID: messageID, text: $0) }
        queue.append(contentsOf: newItems)

        if workerTask == nil || workerTask?.isCancelled == true {
            workerTask = Task { [weak self] in
                await self?.processQueue()
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
        speak(request.text, messageID: request.messageID, flush: true)
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
            break
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
            break
        }
#endif
    }

    public func stop() {
        stopCurrentPlayback(clearQueueOnly: false)
        clearPrefetchState()
        queue = []
        workerTask?.cancel()
        workerTask = nil
        isSpeaking = false
        currentSpeakingMessageID = nil
        playbackState = .init(speed: settingsStore.playbackSpeed)
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
