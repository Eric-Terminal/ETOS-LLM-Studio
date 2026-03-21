import Foundation
import Combine

public enum TTSPlaybackMode: String, CaseIterable, Codable, Sendable {
    case system
    case cloud
    case auto
}

public enum TTSProviderKind: String, CaseIterable, Codable, Sendable {
    case openAICompatible = "openai-compatible"
    case gemini
    case qwen
    case miniMax = "minimax"
    case groq
}

public enum TTSPlaybackStatus: String, Codable, Sendable {
    case idle
    case buffering
    case playing
    case paused
    case ended
    case error
}

public struct TTSPlaybackState: Equatable, Sendable {
    public var status: TTSPlaybackStatus = .idle
    public var position: TimeInterval = 0
    public var duration: TimeInterval = 0
    public var speed: Float = 1.0
    public var currentChunkIndex: Int = 0
    public var totalChunks: Int = 0
    public var errorMessage: String?

    public init(
        status: TTSPlaybackStatus = .idle,
        position: TimeInterval = 0,
        duration: TimeInterval = 0,
        speed: Float = 1.0,
        currentChunkIndex: Int = 0,
        totalChunks: Int = 0,
        errorMessage: String? = nil
    ) {
        self.status = status
        self.position = position
        self.duration = duration
        self.speed = speed
        self.currentChunkIndex = currentChunkIndex
        self.totalChunks = totalChunks
        self.errorMessage = errorMessage
    }
}

public struct TTSSettingsSnapshot: Equatable, Sendable {
    public var playbackMode: TTSPlaybackMode
    public var providerKind: TTSProviderKind
    public var autoPlayAfterAssistantResponse: Bool
    public var onlyReadQuotedContent: Bool
    public var watchUseLightweightPreprocess: Bool
    public var watchSpeechMaxCharacters: Int
    public var speechRate: Float
    public var pitch: Float
    public var playbackSpeed: Float
    public var voice: String
    public var responseFormat: String
    public var languageType: String
    public var miniMaxEmotion: String

    public init(
        playbackMode: TTSPlaybackMode,
        providerKind: TTSProviderKind,
        autoPlayAfterAssistantResponse: Bool,
        onlyReadQuotedContent: Bool,
        watchUseLightweightPreprocess: Bool,
        watchSpeechMaxCharacters: Int,
        speechRate: Float,
        pitch: Float,
        playbackSpeed: Float,
        voice: String,
        responseFormat: String,
        languageType: String,
        miniMaxEmotion: String
    ) {
        self.playbackMode = playbackMode
        self.providerKind = providerKind
        self.autoPlayAfterAssistantResponse = autoPlayAfterAssistantResponse
        self.onlyReadQuotedContent = onlyReadQuotedContent
        self.watchUseLightweightPreprocess = watchUseLightweightPreprocess
        self.watchSpeechMaxCharacters = watchSpeechMaxCharacters
        self.speechRate = speechRate
        self.pitch = pitch
        self.playbackSpeed = playbackSpeed
        self.voice = voice
        self.responseFormat = responseFormat
        self.languageType = languageType
        self.miniMaxEmotion = miniMaxEmotion
    }
}

@MainActor
public final class TTSSettingsStore: ObservableObject {
    public static let shared = TTSSettingsStore()

    private enum Keys {
        static let playbackMode = "tts.playbackMode"
        static let providerKind = "tts.providerKind"
        static let autoPlayAfterAssistantResponse = "tts.autoPlayAfterAssistantResponse"
        static let onlyReadQuotedContent = "tts.onlyReadQuotedContent"
        static let watchUseLightweightPreprocess = "tts.watchUseLightweightPreprocess"
        static let watchSpeechMaxCharacters = "tts.watchSpeechMaxCharacters"
        static let speechRate = "tts.speechRate"
        static let pitch = "tts.pitch"
        static let playbackSpeed = "tts.playbackSpeed"
        static let voice = "tts.voice"
        static let responseFormat = "tts.responseFormat"
        static let languageType = "tts.languageType"
        static let miniMaxEmotion = "tts.miniMaxEmotion"
    }

    private let defaults: UserDefaults

    @Published public var playbackMode: TTSPlaybackMode {
        didSet { defaults.set(playbackMode.rawValue, forKey: Keys.playbackMode) }
    }

    @Published public var providerKind: TTSProviderKind {
        didSet { defaults.set(providerKind.rawValue, forKey: Keys.providerKind) }
    }

    @Published public var autoPlayAfterAssistantResponse: Bool {
        didSet { defaults.set(autoPlayAfterAssistantResponse, forKey: Keys.autoPlayAfterAssistantResponse) }
    }

    @Published public var onlyReadQuotedContent: Bool {
        didSet { defaults.set(onlyReadQuotedContent, forKey: Keys.onlyReadQuotedContent) }
    }

    @Published public var watchUseLightweightPreprocess: Bool {
        didSet { defaults.set(watchUseLightweightPreprocess, forKey: Keys.watchUseLightweightPreprocess) }
    }

    @Published public var watchSpeechMaxCharacters: Int {
        didSet {
            let clamped = watchSpeechMaxCharacters.clamped(to: 500...6_000)
            if clamped != watchSpeechMaxCharacters {
                watchSpeechMaxCharacters = clamped
                return
            }
            defaults.set(clamped, forKey: Keys.watchSpeechMaxCharacters)
        }
    }

    @Published public var speechRate: Float {
        didSet {
            let clamped = speechRate.clamped(to: 0.1...3.0)
            if clamped != speechRate {
                speechRate = clamped
                return
            }
            defaults.set(clamped, forKey: Keys.speechRate)
        }
    }

    @Published public var pitch: Float {
        didSet {
            let clamped = pitch.clamped(to: 0.1...2.0)
            if clamped != pitch {
                pitch = clamped
                return
            }
            defaults.set(clamped, forKey: Keys.pitch)
        }
    }

    @Published public var playbackSpeed: Float {
        didSet {
            let clamped = playbackSpeed.clamped(to: 0.5...2.0)
            if clamped != playbackSpeed {
                playbackSpeed = clamped
                return
            }
            defaults.set(clamped, forKey: Keys.playbackSpeed)
        }
    }

    @Published public var voice: String {
        didSet { defaults.set(voice, forKey: Keys.voice) }
    }

    @Published public var responseFormat: String {
        didSet { defaults.set(responseFormat, forKey: Keys.responseFormat) }
    }

    @Published public var languageType: String {
        didSet { defaults.set(languageType, forKey: Keys.languageType) }
    }

    @Published public var miniMaxEmotion: String {
        didSet { defaults.set(miniMaxEmotion, forKey: Keys.miniMaxEmotion) }
    }

    public var snapshot: TTSSettingsSnapshot {
        TTSSettingsSnapshot(
            playbackMode: playbackMode,
            providerKind: providerKind,
            autoPlayAfterAssistantResponse: autoPlayAfterAssistantResponse,
            onlyReadQuotedContent: onlyReadQuotedContent,
            watchUseLightweightPreprocess: watchUseLightweightPreprocess,
            watchSpeechMaxCharacters: watchSpeechMaxCharacters,
            speechRate: speechRate,
            pitch: pitch,
            playbackSpeed: playbackSpeed,
            voice: voice,
            responseFormat: responseFormat,
            languageType: languageType,
            miniMaxEmotion: miniMaxEmotion
        )
    }

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let modeRaw = defaults.string(forKey: Keys.playbackMode) ?? TTSPlaybackMode.auto.rawValue
        playbackMode = TTSPlaybackMode(rawValue: modeRaw) ?? .auto

        let providerRaw = defaults.string(forKey: Keys.providerKind) ?? TTSProviderKind.openAICompatible.rawValue
        providerKind = TTSProviderKind(rawValue: providerRaw) ?? .openAICompatible

        autoPlayAfterAssistantResponse = defaults.object(forKey: Keys.autoPlayAfterAssistantResponse) as? Bool ?? false
        onlyReadQuotedContent = defaults.object(forKey: Keys.onlyReadQuotedContent) as? Bool ?? false
        watchUseLightweightPreprocess = defaults.object(forKey: Keys.watchUseLightweightPreprocess) as? Bool ?? true

        let rawWatchSpeechMaxCharacters = defaults.object(forKey: Keys.watchSpeechMaxCharacters) as? Int ?? 2_000
        watchSpeechMaxCharacters = rawWatchSpeechMaxCharacters.clamped(to: 500...6_000)

        let rawSpeechRate = defaults.object(forKey: Keys.speechRate) as? Float ?? 1.0
        speechRate = rawSpeechRate.clamped(to: 0.1...3.0)

        let rawPitch = defaults.object(forKey: Keys.pitch) as? Float ?? 1.0
        pitch = rawPitch.clamped(to: 0.1...2.0)

        let rawPlaybackSpeed = defaults.object(forKey: Keys.playbackSpeed) as? Float ?? 1.0
        playbackSpeed = rawPlaybackSpeed.clamped(to: 0.5...2.0)

        voice = defaults.string(forKey: Keys.voice) ?? "alloy"
        responseFormat = defaults.string(forKey: Keys.responseFormat) ?? "mp3"
        languageType = defaults.string(forKey: Keys.languageType) ?? "Auto"
        miniMaxEmotion = defaults.string(forKey: Keys.miniMaxEmotion) ?? "calm"
    }
}

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

private extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
