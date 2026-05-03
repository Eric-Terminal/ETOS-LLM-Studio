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

    private func processQueue() async {
        while !Task.isCancelled {
            if isPausedByUser {
                try? await Task.sleep(nanoseconds: 80_000_000)
                continue
            }

            guard !queue.isEmpty else { break }
            let item = queue.removeFirst()
            currentSpeakingMessageID = item.messageID
            isSpeaking = true

            logger.info("TTS 开始朗读分段：剩余分段=\(self.queue.count, privacy: .public)")

            playbackState.currentChunkIndex += 1
            playbackState.totalChunks = max(playbackState.currentChunkIndex, playbackState.currentChunkIndex + queue.count)
            playbackState.status = .buffering
            playbackState.errorMessage = nil

            let settings = settingsStore.snapshot

            do {
                let effectiveMode = resolvePlaybackMode(settings.playbackMode)
                if effectiveMode != .cloud {
                    clearPrefetchState()
                }
                switch effectiveMode {
                case .system, .auto:
                    do {
                        try await speakBySystem(item.text, settings: settings)
                    } catch {
                        if settings.playbackMode == .auto {
#if os(watchOS)
                            // watchOS 上系统 TTS 异常时不自动切云端，避免网络不稳定导致长时间卡在加载态。
                            throw error
#else
                            try await speakByCloud(item, settings: settings)
#endif
                        } else {
                            throw error
                        }
                    }
                case .cloud:
                    try await speakByCloud(item, settings: settings)
                }
            } catch {
                if error is CancellationError || Task.isCancelled {
                    break
                }
                logger.error("TTS 处理失败: \(error.localizedDescription, privacy: .public)")
                playbackState.status = .error
                playbackState.errorMessage = error.localizedDescription
                queue.removeAll()
                break
            }
        }

        if !Task.isCancelled && playbackState.status != .error {
            playbackState.status = .ended
            playbackState.position = 0
            playbackState.duration = 0
        }

        isSpeaking = false
        currentSpeakingMessageID = nil
        activeBackend = .none
        clearPrefetchState()
        workerTask = nil
    }

    private func resolvePlaybackMode(_ mode: TTSPlaybackMode) -> TTSPlaybackMode {
#if os(iOS) || os(watchOS)
        if mode == .auto {
            return .system
        }
        return mode
#else
        if mode == .system {
            return .cloud
        }
        if mode == .auto {
            return .cloud
        }
        return mode
#endif
    }

    private func speakByCloud(_ item: QueueItem, settings: TTSSettingsSnapshot) async throws {
        let candidates = [item] + Array(queue.prefix(prefetchWindowSize))
        scheduleCloudPrefetch(for: candidates, settings: settings)
        let clip = try await resolveCloudClip(for: item, settings: settings)
        try await playAudio(clip: clip, speed: settings.playbackSpeed)
    }

    private func resolveCloudClip(for item: QueueItem, settings: TTSSettingsSnapshot) async throws -> AudioClip {
        if let task = prefetchTasks[item.id] {
            prefetchTasks.removeValue(forKey: item.id)
            return try await task.value
        }

        let model = try resolveCloudModel()
        return try await synthesizeCloudAudio(text: item.text, settings: settings, model: model)
    }

    private func scheduleCloudPrefetch(for candidates: [QueueItem], settings: TTSSettingsSnapshot) {
        guard !candidates.isEmpty else { return }

        for item in candidates {
            if prefetchTasks[item.id] != nil {
                continue
            }

            let text = item.text
            prefetchTasks[item.id] = Task { [weak self] in
                guard let self else { throw CancellationError() }
                let model = try self.resolveCloudModel()
                return try await self.synthesizeCloudAudio(text: text, settings: settings, model: model)
            }
        }
    }

    private func clearPrefetchState() {
        for task in prefetchTasks.values {
            task.cancel()
        }
        prefetchTasks.removeAll()
    }

    private func resolveCloudModel() throws -> RunnableModel {
        guard let model = selectedModel ?? ChatService.shared.resolveSelectedTTSModel() else {
            throw NSError(domain: "TTS", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("未选择可用的 TTS 模型。", comment: "")])
        }
        return model
    }

    private var cloudRequestTimeoutSeconds: TimeInterval {
#if os(watchOS)
        25
#else
        120
#endif
    }

    private func speakBySystem(_ text: String, settings: TTSSettingsSnapshot) async throws {
#if os(iOS) || os(watchOS)
        activeBackend = .system
        playbackState.status = .playing
        playbackState.speed = settings.playbackSpeed
        playbackState.duration = estimateDuration(for: text, speechRate: settings.speechRate)
        playbackState.position = 0

        logger.info("系统 TTS 开始：文本长度=\(text.count, privacy: .public)")

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            speechContinuation = continuation
            speechDidStart = false
            let utterance = AVSpeechUtterance(string: text)
            utterance.rate = settings.speechRate.ttsClamped(to: 0.1...0.6)
            utterance.pitchMultiplier = settings.pitch.ttsClamped(to: 0.5...2.0)
            if !settings.voice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if let exact = AVSpeechSynthesisVoice(identifier: settings.voice) {
                    utterance.voice = exact
                }
            }
            speechSynthesizer.speak(utterance)
            startSpeechCompletionMonitor(estimatedDuration: playbackState.duration)
        }
#else
        throw NSError(domain: "TTS", code: -2, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("当前平台不支持系统 TTS。", comment: "")])
#endif
    }

#if os(iOS) || os(watchOS)
    /// 兜底监控系统 TTS 的回调，避免在 watchOS 上出现无回调导致队列永久卡住。
    private func startSpeechCompletionMonitor(estimatedDuration: TimeInterval) {
        stopSpeechMonitor(resetDidStart: false)
        let startupGrace: TimeInterval = 5
        let hardDeadline = min(75, max(30, estimatedDuration * 2.2 + 8))

        speechMonitorTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let startedAt = Date()
            var speechBeganAt: Date?

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)

                guard let continuation = self.speechContinuation else { break }
                let elapsed = Date().timeIntervalSince(startedAt)
                let isSpeakingNow = self.speechSynthesizer.isSpeaking
                let isPausedNow = self.speechSynthesizer.isPaused

                if elapsed >= hardDeadline {
                    self.logger.error("系统 TTS 长时间无回调，自动恢复播放队列。")
                    if isSpeakingNow {
                        self.speechSynthesizer.stopSpeaking(at: .immediate)
                    }
                    self.speechContinuation = nil
                    self.stopSpeechMonitor()
                    continuation.resume(throwing: NSError(
                        domain: "TTS",
                        code: -14,
                        userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("系统朗读长时间无响应，已自动恢复。", comment: "")]
                    ))
                    break
                }

                if isSpeakingNow {
                    self.speechDidStart = true
                    if speechBeganAt == nil {
                        speechBeganAt = Date()
                    }
                    if let speechBeganAt, self.playbackState.duration > 0 {
                        let speakingElapsed = Date().timeIntervalSince(speechBeganAt)
                        self.playbackState.position = min(self.playbackState.duration, speakingElapsed)
                    }
                    continue
                }

                if isPausedNow {
                    continue
                }

                if self.speechDidStart {
                    self.logger.warning("系统 TTS 未收到 didFinish 回调，已通过状态轮询自动收尾。")
                    self.playbackState.status = .ended
                    self.playbackState.position = self.playbackState.duration
                    self.speechContinuation = nil
                    self.stopSpeechMonitor()
                    continuation.resume()
                    break
                }

                if elapsed >= startupGrace {
                    self.logger.error("系统 TTS 启动失败，自动恢复播放流程。")
                    self.speechContinuation = nil
                    self.stopSpeechMonitor()
                    continuation.resume(throwing: NSError(
                        domain: "TTS",
                        code: -13,
                        userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("系统朗读未能启动，请重试或切换云端。", comment: "")]
                    ))
                    break
                }
            }
        }
    }

    private func stopSpeechMonitor(resetDidStart: Bool = true) {
        speechMonitorTask?.cancel()
        speechMonitorTask = nil
        if resetDidStart {
            speechDidStart = false
        }
    }
#endif

    private func synthesizeCloudAudio(text: String, settings: TTSSettingsSnapshot, model: RunnableModel) async throws -> AudioClip {
        switch settings.providerKind {
        case .openAICompatible:
            return try await synthesizeOpenAICompatible(text: text, settings: settings, model: model)
        case .gemini:
            return try await synthesizeGemini(text: text, settings: settings, model: model)
        case .qwen:
            return try await synthesizeQwen(text: text, settings: settings, model: model)
        case .miniMax:
            return try await synthesizeMiniMax(text: text, settings: settings, model: model)
        case .groq:
            return try await synthesizeGroq(text: text, settings: settings, model: model)
        }
    }

    private func synthesizeOpenAICompatible(text: String, settings: TTSSettingsSnapshot, model: RunnableModel) async throws -> AudioClip {
        guard let key = firstAPIKey(from: model.provider) else {
            throw NSError(domain: "TTS", code: -3, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("当前提供商未配置 API Key。", comment: "")])
        }

        let url = normalizedBaseURL(model.provider.baseURL).appendingPathComponent("audio/speech")
        let payload: [String: Any] = [
            "model": model.model.modelName,
            "input": text,
            "voice": settings.voice,
            "response_format": settings.responseFormat
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = cloudRequestTimeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let data = try await fetchData(for: request)
        return AudioClip(data: data, format: settings.responseFormat.lowercased(), sampleRate: nil)
    }

    private func synthesizeGroq(text: String, settings: TTSSettingsSnapshot, model: RunnableModel) async throws -> AudioClip {
        var groqSettings = settings
        if groqSettings.responseFormat.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            groqSettings.responseFormat = "wav"
        }
        return try await synthesizeOpenAICompatible(text: text, settings: groqSettings, model: model)
    }

    private func synthesizeGemini(text: String, settings: TTSSettingsSnapshot, model: RunnableModel) async throws -> AudioClip {
        guard let key = firstAPIKey(from: model.provider) else {
            throw NSError(domain: "TTS", code: -3, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("当前提供商未配置 API Key。", comment: "")])
        }

        let baseURL = normalizedBaseURL(model.provider.baseURL).absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let url = URL(string: "\(baseURL)/models/\(model.model.modelName):generateContent")!

        let payload: [String: Any] = [
            "contents": [[
                "parts": [["text": text]]
            ]],
            "generationConfig": [
                "responseModalities": ["AUDIO"],
                "speechConfig": [
                    "voiceConfig": [
                        "prebuiltVoiceConfig": [
                            "voiceName": settings.voice
                        ]
                    ]
                ]
            ],
            "model": model.model.modelName
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = cloudRequestTimeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let data = try await fetchData(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let firstCandidate = candidates.first,
              let content = firstCandidate["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let firstPart = parts.first,
              let inlineData = firstPart["inlineData"] as? [String: Any],
              let base64 = inlineData["data"] as? String,
              let pcmData = Data(base64Encoded: base64) else {
            throw NSError(domain: "TTS", code: -4, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Gemini TTS 响应解析失败。", comment: "")])
        }

        return AudioClip(data: pcmData, format: "pcm", sampleRate: 24_000)
    }

    private func synthesizeQwen(text: String, settings: TTSSettingsSnapshot, model: RunnableModel) async throws -> AudioClip {
        guard let key = firstAPIKey(from: model.provider) else {
            throw NSError(domain: "TTS", code: -3, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("当前提供商未配置 API Key。", comment: "")])
        }

        let url = normalizedBaseURL(model.provider.baseURL)
            .appendingPathComponent("services")
            .appendingPathComponent("aigc")
            .appendingPathComponent("multimodal-generation")
            .appendingPathComponent("generation")

        let payload: [String: Any] = [
            "model": model.model.modelName,
            "input": [
                "text": text,
                "voice": settings.voice,
                "language_type": settings.languageType
            ]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = cloudRequestTimeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("enable", forHTTPHeaderField: "X-DashScope-SSE")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let data = try await fetchData(for: request)
        let ssePayloads = parseSSEPayloads(from: data)
        var output = Data()
        for payload in ssePayloads {
            guard let payloadData = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
                  let outputObj = json["output"] as? [String: Any],
                  let audioObj = outputObj["audio"] as? [String: Any],
                  let audioBase64 = audioObj["data"] as? String,
                  let chunkData = Data(base64Encoded: audioBase64) else {
                continue
            }
            output.append(chunkData)
        }

        if output.isEmpty {
            throw NSError(domain: "TTS", code: -5, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Qwen TTS 未返回可播放音频。", comment: "")])
        }
        return AudioClip(data: output, format: "pcm", sampleRate: 24_000)
    }

    private func synthesizeMiniMax(text: String, settings: TTSSettingsSnapshot, model: RunnableModel) async throws -> AudioClip {
        guard let key = firstAPIKey(from: model.provider) else {
            throw NSError(domain: "TTS", code: -3, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("当前提供商未配置 API Key。", comment: "")])
        }

        let url = normalizedBaseURL(model.provider.baseURL).appendingPathComponent("t2a_v2")
        let payload: [String: Any] = [
            "model": model.model.modelName,
            "text": text,
            "stream": true,
            "output_format": "hex",
            "stream_options": ["exclude_aggregated_audio": true],
            "voice_setting": [
                "voice_id": settings.voice,
                "emotion": settings.miniMaxEmotion,
                "speed": settings.playbackSpeed
            ]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = cloudRequestTimeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let data = try await fetchData(for: request)
        let ssePayloads = parseSSEPayloads(from: data)
        var output = Data()

        for payload in ssePayloads {
            guard let payloadData = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
                  let dataObj = json["data"] as? [String: Any],
                  let hexAudio = dataObj["audio"] as? String,
                  let chunk = Data(hexString: hexAudio) else {
                continue
            }
            output.append(chunk)
        }

        if output.isEmpty {
            throw NSError(domain: "TTS", code: -6, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("MiniMax TTS 未返回可播放音频。", comment: "")])
        }

        return AudioClip(data: output, format: "mp3", sampleRate: 32_000)
    }

#if canImport(AVFoundation)
    private func playAudio(clip: AudioClip, speed: Float) async throws {
        activeBackend = .cloud
        playbackState.status = .buffering

        var audioData = clip.data
        if clip.format.lowercased() == "pcm" {
            audioData = pcmToWav(pcm: clip.data, sampleRate: clip.sampleRate ?? 24_000)
        }

        let player = try AVAudioPlayer(data: audioData)
        player.delegate = self
        player.enableRate = true
        player.rate = speed
        player.prepareToPlay()
        audioPlayer = player

        playbackState.duration = player.duration
        playbackState.position = 0
        playbackState.speed = speed
        playbackState.status = .playing

        startProgressTimer()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            audioContinuation = continuation
            if !player.play() {
                continuation.resume(throwing: NSError(domain: "TTS", code: -10, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("音频播放启动失败。", comment: "")]))
                audioContinuation = nil
                stopProgressTimer()
                return
            }
        }

        stopProgressTimer()
        playbackState.position = 0
        playbackState.duration = 0
    }
#endif

}
