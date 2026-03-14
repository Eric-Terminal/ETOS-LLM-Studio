import Foundation
import Combine
import os.log
#if canImport(AVFoundation)
import AVFoundation
#endif

@MainActor
public final class TTSManager: NSObject, ObservableObject {
    public static let shared = TTSManager()

    @Published public private(set) var isSpeaking: Bool = false
    @Published public private(set) var playbackState: TTSPlaybackState = .init()
    @Published public private(set) var currentSpeakingMessageID: UUID?

    private let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "TTSManager")
    private let settingsStore = TTSSettingsStore.shared
    private let urlSession: URLSession

    private var selectedModel: RunnableModel?
    private var queue: [QueueItem] = []
    private var workerTask: Task<Void, Never>?
    private var prefetchTasks: [UUID: Task<AudioClip, Error>] = [:]
    private let prefetchWindowSize: Int = 1
    private var isPausedByUser = false
    private var activeBackend: ActiveBackend = .none

#if canImport(AVFoundation)
    private var audioPlayer: AVAudioPlayer?
    private var audioContinuation: CheckedContinuation<Void, Error>?
    private var progressTimer: Timer?
#endif

#if os(iOS)
    private lazy var speechSynthesizer: AVSpeechSynthesizer = {
        let synthesizer = AVSpeechSynthesizer()
        synthesizer.delegate = self
        return synthesizer
    }()
    private var speechContinuation: CheckedContinuation<Void, Error>?
#endif

    private struct QueueItem: Identifiable {
        let id = UUID()
        let messageID: UUID?
        let text: String
    }

    private enum ActiveBackend {
        case none
        case system
        case cloud
    }

    private struct AudioClip: Sendable {
        var data: Data
        var format: String
        var sampleRate: Int?
    }

    public init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
        super.init()
    }

    public func updateSelectedModel(_ model: RunnableModel?) {
        selectedModel = model
    }

    public func speak(_ text: String, messageID: UUID? = nil, flush: Bool = true) {
        let settings = settingsStore.snapshot
        let processed = preprocessText(text, settings: settings)
        guard !processed.isEmpty else { return }

        let chunks = splitText(processed)
        guard !chunks.isEmpty else { return }

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

    public func pause() {
        guard isSpeaking else { return }
        isPausedByUser = true
#if canImport(AVFoundation)
        switch activeBackend {
        case .cloud:
            audioPlayer?.pause()
            playbackState.status = .paused
        case .system:
#if os(iOS)
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
#if os(iOS)
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
                            try await speakByCloud(item, settings: settings)
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
#if os(iOS)
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

    private func speakBySystem(_ text: String, settings: TTSSettingsSnapshot) async throws {
#if os(iOS)
        activeBackend = .system
        playbackState.status = .playing
        playbackState.speed = settings.playbackSpeed
        playbackState.duration = estimateDuration(for: text, speechRate: settings.speechRate)
        playbackState.position = 0

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            speechContinuation = continuation
            let utterance = AVSpeechUtterance(string: text)
            utterance.rate = settings.speechRate.ttsClamped(to: 0.1...0.6)
            utterance.pitchMultiplier = settings.pitch.ttsClamped(to: 0.5...2.0)
            if !settings.voice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if let exact = AVSpeechSynthesisVoice(identifier: settings.voice) {
                    utterance.voice = exact
                }
            }
            speechSynthesizer.speak(utterance)
        }
#else
        throw NSError(domain: "TTS", code: -2, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("当前平台不支持系统 TTS。", comment: "")])
#endif
    }

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
        request.timeoutInterval = 120
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
        request.timeoutInterval = 120
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
        request.timeoutInterval = 120
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
        request.timeoutInterval = 120
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

    private func fetchData(for request: URLRequest) async throws -> Data {
        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "TTS", code: -20, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("无效的网络响应。", comment: "")])
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? NSLocalizedString("无响应体", comment: "")
            throw NSError(
                domain: "TTS",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: String(format: NSLocalizedString("TTS 请求失败（%d）：%@", comment: ""), httpResponse.statusCode, body)]
            )
        }
        return data
    }

    private func preprocessText(_ text: String, settings: TTSSettingsSnapshot) -> String {
        let stripped = stripMarkdown(text)
        let quoted = settings.onlyReadQuotedContent ? extractQuotedContent(from: stripped) : stripped
        return quoted.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func splitText(_ text: String, maxLength: Int = 160) -> [String] {
        Self.splitTextForPlayback(text, maxLength: maxLength)
    }

    public nonisolated static func splitTextForPlayback(_ text: String, maxLength: Int = 160) -> [String] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }

        let punctuation = CharacterSet(charactersIn: "。！？；!?;\n")
        var chunks: [String] = []
        var current = ""

        for scalar in text.unicodeScalars {
            current.unicodeScalars.append(scalar)
            let shouldSplit = punctuation.contains(scalar)
            if current.count >= maxLength || shouldSplit {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    chunks.append(trimmed)
                }
                current.removeAll(keepingCapacity: true)
            }
        }

        let remain = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !remain.isEmpty {
            chunks.append(remain)
        }

        return chunks
    }

    private func stopCurrentPlayback(clearQueueOnly: Bool) {
#if canImport(AVFoundation)
        audioPlayer?.stop()
        audioPlayer = nil
        if let continuation = audioContinuation {
            audioContinuation = nil
            continuation.resume(throwing: CancellationError())
        }
        stopProgressTimer()
#endif

#if os(iOS)
        if speechSynthesizer.isSpeaking {
            speechSynthesizer.stopSpeaking(at: .immediate)
        }
        if let continuation = speechContinuation {
            speechContinuation = nil
            continuation.resume(throwing: CancellationError())
        }
#endif

        activeBackend = .none
        isPausedByUser = false
        if !clearQueueOnly {
            playbackState = .init(speed: settingsStore.playbackSpeed)
            currentSpeakingMessageID = nil
        }
    }

    private func firstAPIKey(from provider: Provider) -> String? {
        provider.apiKeys
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
    }

    private func normalizedBaseURL(_ string: String) -> URL {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), !trimmed.isEmpty {
            return url
        }
        return URL(string: "https://api.openai.com/v1")!
    }

    private func parseSSEPayloads(from data: Data) -> [String] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var payloads: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let raw = String(line)
            guard raw.hasPrefix("data:") else { continue }
            let payload = raw.replacingOccurrences(of: "data:", with: "").trimmingCharacters(in: .whitespaces)
            guard !payload.isEmpty, payload != "[DONE]" else { continue }
            payloads.append(payload)
        }
        return payloads
    }

    private func extractQuotedContent(from text: String) -> String {
        let pattern = #"["“”'‘’]([^"“”'‘’]+)["“”'‘’]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return text
        }
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        let parts: [String] = matches.compactMap { match in
            guard match.numberOfRanges >= 2 else { return nil }
            return nsText.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        if parts.isEmpty { return text }
        return parts.joined(separator: "\n")
    }

    private func stripMarkdown(_ text: String) -> String {
        var output = text
        let patterns: [(String, String)] = [
            (#"```[\s\S]*?```|`[^`]*?`"#, ""),
            (#"!?\[([^\]]+)\]\([^\)]*\)"#, "$1"),
            (#"\*\*([^*]+?)\*\*"#, "$1"),
            (#"\*([^*]+?)\*"#, "$1"),
            (#"__([^_]+?)__"#, "$1"),
            (#"_([^_]+?)_"#, "$1"),
            (#"~~([^~]+?)~~"#, "$1"),
            (#"(?m)^#+\s*"#, ""),
            (#"(?m)^\s*[-*+]\s+"#, ""),
            (#"(?m)^\s*\d+\.\s+"#, ""),
            (#"(?m)^>\s*"#, "")
        ]
        for (pattern, replacement) in patterns {
            output = output.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        output = output.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return output
    }

    private func estimateDuration(for text: String, speechRate: Float) -> TimeInterval {
        let length = max(1, text.count)
        let normalizedRate = max(0.2, speechRate)
        return TimeInterval(Double(length) * 0.065 / Double(normalizedRate))
    }

#if canImport(AVFoundation)
    private func startProgressTimer() {
        stopProgressTimer()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, let audioPlayer = self.audioPlayer else { return }
            self.playbackState.position = audioPlayer.currentTime
            self.playbackState.duration = audioPlayer.duration
        }
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    private func pcmToWav(pcm: Data, sampleRate: Int, channels: Int = 1, bitsPerSample: Int = 16) -> Data {
        let byteRate = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8
        var header = Data()
        header.append("RIFF".data(using: .ascii)!)
        header.append(UInt32(36 + pcm.count).littleEndianData)
        header.append("WAVE".data(using: .ascii)!)
        header.append("fmt ".data(using: .ascii)!)
        header.append(UInt32(16).littleEndianData)
        header.append(UInt16(1).littleEndianData)
        header.append(UInt16(channels).littleEndianData)
        header.append(UInt32(sampleRate).littleEndianData)
        header.append(UInt32(byteRate).littleEndianData)
        header.append(UInt16(blockAlign).littleEndianData)
        header.append(UInt16(bitsPerSample).littleEndianData)
        header.append("data".data(using: .ascii)!)
        header.append(UInt32(pcm.count).littleEndianData)
        return header + pcm
    }
#endif
}

#if canImport(AVFoundation)
extension TTSManager: AVAudioPlayerDelegate {
    public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        playbackState.status = .ended
        if let continuation = audioContinuation {
            audioContinuation = nil
            continuation.resume()
        }
    }

    public func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        playbackState.status = .error
        playbackState.errorMessage = error?.localizedDescription
        if let continuation = audioContinuation {
            audioContinuation = nil
            continuation.resume(throwing: error ?? NSError(domain: "TTS", code: -11, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("音频解码失败。", comment: "")]))
        }
    }
}
#endif

#if os(iOS)
extension TTSManager: AVSpeechSynthesizerDelegate {
    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        playbackState.status = .ended
        if let continuation = speechContinuation {
            speechContinuation = nil
            continuation.resume()
        }
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        if let continuation = speechContinuation {
            speechContinuation = nil
            continuation.resume(throwing: CancellationError())
        }
    }
}
#endif

private extension Float {
    func ttsClamped(to range: ClosedRange<Float>) -> Float {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

private extension Data {
    init?(hexString: String) {
        let cleaned = hexString.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
        guard cleaned.count % 2 == 0 else { return nil }
        var bytes = Data(capacity: cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            let byteString = cleaned[index..<next]
            guard let value = UInt8(byteString, radix: 16) else { return nil }
            bytes.append(value)
            index = next
        }
        self = bytes
    }
}

private extension UInt16 {
    var littleEndianData: Data {
        var value = self.littleEndian
        return Data(bytes: &value, count: MemoryLayout<UInt16>.size)
    }
}

private extension UInt32 {
    var littleEndianData: Data {
        var value = self.littleEndian
        return Data(bytes: &value, count: MemoryLayout<UInt32>.size)
    }
}
