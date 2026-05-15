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
        didSet { Self.save(playbackMode.rawValue, forKey: Keys.playbackMode, defaults: defaults) }
    }

    @Published public var providerKind: TTSProviderKind {
        didSet { Self.save(providerKind.rawValue, forKey: Keys.providerKind, defaults: defaults) }
    }

    @Published public var autoPlayAfterAssistantResponse: Bool {
        didSet { Self.save(autoPlayAfterAssistantResponse, forKey: Keys.autoPlayAfterAssistantResponse, defaults: defaults) }
    }

    @Published public var onlyReadQuotedContent: Bool {
        didSet { Self.save(onlyReadQuotedContent, forKey: Keys.onlyReadQuotedContent, defaults: defaults) }
    }

    @Published public var watchUseLightweightPreprocess: Bool {
        didSet { Self.save(watchUseLightweightPreprocess, forKey: Keys.watchUseLightweightPreprocess, defaults: defaults) }
    }

    @Published public var watchSpeechMaxCharacters: Int {
        didSet {
            let clamped = watchSpeechMaxCharacters.clamped(to: 500...6_000)
            if clamped != watchSpeechMaxCharacters {
                watchSpeechMaxCharacters = clamped
                return
            }
            Self.save(clamped, forKey: Keys.watchSpeechMaxCharacters, defaults: defaults)
        }
    }

    @Published public var speechRate: Float {
        didSet {
            let clamped = speechRate.clamped(to: 0.1...3.0)
            if clamped != speechRate {
                speechRate = clamped
                return
            }
            Self.save(clamped, forKey: Keys.speechRate, defaults: defaults)
        }
    }

    @Published public var pitch: Float {
        didSet {
            let clamped = pitch.clamped(to: 0.1...2.0)
            if clamped != pitch {
                pitch = clamped
                return
            }
            Self.save(clamped, forKey: Keys.pitch, defaults: defaults)
        }
    }

    @Published public var playbackSpeed: Float {
        didSet {
            let clamped = playbackSpeed.clamped(to: 0.5...2.0)
            if clamped != playbackSpeed {
                playbackSpeed = clamped
                return
            }
            Self.save(clamped, forKey: Keys.playbackSpeed, defaults: defaults)
        }
    }

    @Published public var voice: String {
        didSet { Self.save(voice, forKey: Keys.voice, defaults: defaults) }
    }

    @Published public var responseFormat: String {
        didSet { Self.save(responseFormat, forKey: Keys.responseFormat, defaults: defaults) }
    }

    @Published public var languageType: String {
        didSet { Self.save(languageType, forKey: Keys.languageType, defaults: defaults) }
    }

    @Published public var miniMaxEmotion: String {
        didSet { Self.save(miniMaxEmotion, forKey: Keys.miniMaxEmotion, defaults: defaults) }
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

        let modeRaw = Self.textValue(forKey: Keys.playbackMode, defaults: defaults, defaultValue: TTSPlaybackMode.auto.rawValue)
        playbackMode = TTSPlaybackMode(rawValue: modeRaw) ?? .auto

        let providerRaw = Self.textValue(forKey: Keys.providerKind, defaults: defaults, defaultValue: TTSProviderKind.openAICompatible.rawValue)
        providerKind = TTSProviderKind(rawValue: providerRaw) ?? .openAICompatible

        autoPlayAfterAssistantResponse = Self.boolValue(forKey: Keys.autoPlayAfterAssistantResponse, defaults: defaults, defaultValue: false)
        onlyReadQuotedContent = Self.boolValue(forKey: Keys.onlyReadQuotedContent, defaults: defaults, defaultValue: false)
        watchUseLightweightPreprocess = Self.boolValue(forKey: Keys.watchUseLightweightPreprocess, defaults: defaults, defaultValue: true)

        let rawWatchSpeechMaxCharacters = Self.integerValue(forKey: Keys.watchSpeechMaxCharacters, defaults: defaults, defaultValue: 2_000)
        watchSpeechMaxCharacters = rawWatchSpeechMaxCharacters.clamped(to: 500...6_000)

        let rawSpeechRate = Self.floatValue(forKey: Keys.speechRate, defaults: defaults, defaultValue: 1.0)
        speechRate = rawSpeechRate.clamped(to: 0.1...3.0)

        let rawPitch = Self.floatValue(forKey: Keys.pitch, defaults: defaults, defaultValue: 1.0)
        pitch = rawPitch.clamped(to: 0.1...2.0)

        let rawPlaybackSpeed = Self.floatValue(forKey: Keys.playbackSpeed, defaults: defaults, defaultValue: 1.0)
        playbackSpeed = rawPlaybackSpeed.clamped(to: 0.5...2.0)

        voice = Self.textValue(forKey: Keys.voice, defaults: defaults, defaultValue: "alloy")
        responseFormat = Self.textValue(forKey: Keys.responseFormat, defaults: defaults, defaultValue: "mp3")
        languageType = Self.textValue(forKey: Keys.languageType, defaults: defaults, defaultValue: "Auto")
        miniMaxEmotion = Self.textValue(forKey: Keys.miniMaxEmotion, defaults: defaults, defaultValue: "calm")
    }

    private static func usesDatabase(defaults: UserDefaults) -> Bool {
        defaults === UserDefaults.standard
    }

    private static func boolValue(forKey key: String, defaults: UserDefaults, defaultValue: Bool) -> Bool {
        guard usesDatabase(defaults: defaults) else {
            return defaults.object(forKey: key) as? Bool ?? defaultValue
        }
        if let stored = Persistence.readAppConfigInteger(key: key) {
            return stored != 0
        }
        return defaultValue
    }

    private static func integerValue(forKey key: String, defaults: UserDefaults, defaultValue: Int) -> Int {
        guard usesDatabase(defaults: defaults) else {
            return defaults.object(forKey: key) as? Int ?? defaultValue
        }
        if let stored = Persistence.readAppConfigInteger(key: key) {
            return stored
        }
        return defaultValue
    }

    private static func floatValue(forKey key: String, defaults: UserDefaults, defaultValue: Float) -> Float {
        guard usesDatabase(defaults: defaults) else {
            if let value = defaults.object(forKey: key) as? Float {
                return value
            }
            if let value = defaults.object(forKey: key) as? NSNumber {
                return value.floatValue
            }
            return defaultValue
        }
        if let stored = Persistence.readAppConfigReal(key: key) {
            return Float(stored)
        }
        return defaultValue
    }

    private static func textValue(forKey key: String, defaults: UserDefaults, defaultValue: String) -> String {
        guard usesDatabase(defaults: defaults) else {
            return defaults.string(forKey: key) ?? defaultValue
        }
        if let stored = Persistence.readAppConfigText(key: key) {
            return stored
        }
        return defaultValue
    }

    private static func save(_ value: Bool, forKey key: String, defaults: UserDefaults) {
        guard usesDatabase(defaults: defaults) else {
            defaults.set(value, forKey: key)
            return
        }
        if Persistence.writeAppConfig(key: key, integer: value ? 1 : 0, typeHint: "bool") {
            defaults.removeObject(forKey: key)
        }
    }

    private static func save(_ value: Int, forKey key: String, defaults: UserDefaults) {
        guard usesDatabase(defaults: defaults) else {
            defaults.set(value, forKey: key)
            return
        }
        if Persistence.writeAppConfig(key: key, integer: value, typeHint: "integer") {
            defaults.removeObject(forKey: key)
        }
    }

    private static func save(_ value: Float, forKey key: String, defaults: UserDefaults) {
        guard usesDatabase(defaults: defaults) else {
            defaults.set(value, forKey: key)
            return
        }
        if Persistence.writeAppConfig(key: key, real: Double(value), typeHint: "real") {
            defaults.removeObject(forKey: key)
        }
    }

    private static func save(_ value: String, forKey key: String, defaults: UserDefaults) {
        guard usesDatabase(defaults: defaults) else {
            defaults.set(value, forKey: key)
            return
        }
        if Persistence.writeAppConfig(key: key, text: value, typeHint: "text") {
            defaults.removeObject(forKey: key)
        }
    }
}

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

private extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
