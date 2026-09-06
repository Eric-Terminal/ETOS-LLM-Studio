import Foundation

public struct TTSProviderRecommendedPreset: Equatable, Sendable {
    public var voice: String
    public var responseFormat: String
    public var languageType: String
    public var miniMaxEmotion: String
    public var advanced: TTSServiceAdvancedConfiguration

    public init(
        voice: String,
        responseFormat: String,
        languageType: String,
        miniMaxEmotion: String,
        advanced: TTSServiceAdvancedConfiguration = .init()
    ) {
        self.voice = voice
        self.responseFormat = responseFormat
        self.languageType = languageType
        self.miniMaxEmotion = miniMaxEmotion
        self.advanced = advanced
    }
}

public enum TTSProviderConfigurationField: Hashable, Sendable {
    case modelID
    case responseFormat
    case language
    case emotion
    case speed
    case volume
    case pitch
    case sampleRate
    case bitrate
    case channels
    case instruction
    case workspace
    case region
    case languageBoost
    case subtitles
    case pronunciationDictionary
    case temperature
    case topP
    case latency
    case optimizeTextPreview
}

public enum TTSProviderPresetCatalog {
    public static func voiceOptions(for kind: TTSProviderKind) -> [String] {
        switch kind {
        case .openAICompatible:
            return ["alloy", "echo", "fable", "onyx", "nova", "shimmer"]
        case .gemini:
            return ["Kore", "Puck", "Charon", "Fenrir", "Aoede"]
        case .azure, .qwenAudio, .elevenLabs, .fishAudio:
            return []
        case .qwen:
            return [
                "Cherry", "Serene", "Ethan", "Chelsie", "Momo", "Vivian",
                "Moon", "Maia", "Kai", "Nofish", "Bella", "Jennifer",
                "Ryan", "Katerina", "Aiden", "Eldric Sage", "Mia", "Mochi",
                "Bellona", "Vincent", "Bunny", "Neil", "Elias", "Arthur", "Nini"
            ]
        case .miniMax:
            return [
                "male-qn-qingse", "male-qn-jingying", "male-qn-badao", "male-qn-daxuesheng",
                "female-shaonv", "female-yujie", "female-chengshu", "female-tianmei",
                "audiobook_male_1", "audiobook_female_1", "cartoon_pig"
            ]
        case .groq:
            return ["austin", "natalie", "kailin"]
        case .xAI:
            return ["eve", "ara", "rex", "sal", "leo"]
        case .miMo:
            return ["mimo_default"]
        case .stepFun:
            return ["cixingnansheng"]
        }
    }

    public static func responseFormatOptions(for kind: TTSProviderKind) -> [String] {
        switch kind {
        case .openAICompatible:
            return ["mp3", "wav"]
        case .groq:
            return ["wav", "mp3"]
        case .qwenAudio:
            return ["mp3", "wav", "pcm"]
        case .miniMax:
            return ["mp3", "pcm"]
        case .elevenLabs:
            return ["mp3_44100_128", "mp3_22050_32", "pcm_16000", "pcm_24000", "pcm_44100", "opus_48000_128"]
        case .stepFun:
            return ["mp3", "wav", "pcm", "flac"]
        case .fishAudio:
            return ["mp3", "wav", "pcm", "opus"]
        case .gemini, .azure, .qwen, .xAI, .miMo:
            return []
        }
    }

    public static func languageTypeOptions(for kind: TTSProviderKind) -> [String] {
        switch kind {
        case .qwen:
            return ["Auto", "Chinese", "English", "Japanese", "Korean"]
        case .azure:
            return ["zh-CN", "en-US", "ja-JP", "ko-KR"]
        case .xAI:
            return [
                "auto", "en", "zh", "ja", "ko", "fr", "de", "es-ES", "es-MX",
                "pt-BR", "pt-PT", "it", "ru", "ar-EG", "hi", "tr", "vi", "id", "bn"
            ]
        case .openAICompatible, .gemini, .qwenAudio, .miniMax, .groq,
             .elevenLabs, .miMo, .stepFun, .fishAudio:
            return []
        }
    }

    public static func miniMaxEmotionOptions(for kind: TTSProviderKind) -> [String] {
        switch kind {
        case .miniMax:
            return ["calm", "happy", "sad", "angry", "fearful", "disgusted", "surprised"]
        case .openAICompatible, .gemini, .azure, .qwen, .qwenAudio, .groq,
             .xAI, .elevenLabs, .miMo, .stepFun, .fishAudio:
            return []
        }
    }

    public static func configurationFields(for kind: TTSProviderKind) -> Set<TTSProviderConfigurationField> {
        switch kind {
        case .openAICompatible, .groq:
            return [.modelID, .responseFormat]
        case .gemini:
            return [.modelID]
        case .azure:
            return [.language]
        case .qwen:
            return [.modelID, .language]
        case .qwenAudio:
            return [.modelID, .responseFormat, .workspace, .region, .sampleRate]
        case .miniMax:
            return [
                .modelID, .responseFormat, .emotion, .speed, .volume, .pitch,
                .sampleRate, .bitrate, .channels, .languageBoost, .subtitles,
                .pronunciationDictionary
            ]
        case .xAI:
            return [.language]
        case .elevenLabs:
            return [.modelID, .responseFormat]
        case .miMo:
            return [.modelID, .instruction, .optimizeTextPreview]
        case .stepFun:
            return [.modelID, .responseFormat, .speed, .volume, .sampleRate, .instruction]
        case .fishAudio:
            return [.modelID, .responseFormat, .speed, .sampleRate, .temperature, .topP, .latency]
        }
    }

    public static func requiresModelID(for kind: TTSProviderKind) -> Bool {
        configurationFields(for: kind).contains(.modelID)
    }

    public static func recommendedPreset(for kind: TTSProviderKind) -> TTSProviderRecommendedPreset {
        switch kind {
        case .openAICompatible:
            return .init(
                voice: "alloy",
                responseFormat: "mp3",
                languageType: "Auto",
                miniMaxEmotion: "calm"
            )
        case .gemini:
            return .init(
                voice: "Kore",
                responseFormat: "mp3",
                languageType: "Auto",
                miniMaxEmotion: "calm"
            )
        case .azure:
            return .init(
                voice: "zh-CN-XiaoxiaoNeural",
                responseFormat: "mp3",
                languageType: "zh-CN",
                miniMaxEmotion: "calm"
            )
        case .qwen:
            return .init(
                voice: "Cherry",
                responseFormat: "mp3",
                languageType: "Auto",
                miniMaxEmotion: "calm"
            )
        case .qwenAudio:
            return .init(
                voice: "longanhuan_v3.6",
                responseFormat: "mp3",
                languageType: "Auto",
                miniMaxEmotion: "calm",
                advanced: .init(sampleRate: 22_050)
            )
        case .miniMax:
            return .init(
                voice: "female-shaonv",
                responseFormat: "mp3",
                languageType: "Auto",
                miniMaxEmotion: "calm",
                advanced: .init(sampleRate: 32_000)
            )
        case .groq:
            return .init(
                voice: "austin",
                responseFormat: "wav",
                languageType: "Auto",
                miniMaxEmotion: "calm"
            )
        case .xAI:
            return .init(
                voice: "eve",
                responseFormat: "mp3",
                languageType: "auto",
                miniMaxEmotion: "calm"
            )
        case .elevenLabs:
            return .init(
                voice: "",
                responseFormat: "mp3_44100_128",
                languageType: "Auto",
                miniMaxEmotion: "calm",
                advanced: .init(sampleRate: 44_100)
            )
        case .miMo:
            return .init(
                voice: "mimo_default",
                responseFormat: "pcm",
                languageType: "Auto",
                miniMaxEmotion: "calm"
            )
        case .stepFun:
            return .init(
                voice: "cixingnansheng",
                responseFormat: "mp3",
                languageType: "Auto",
                miniMaxEmotion: "calm"
            )
        case .fishAudio:
            return .init(
                voice: "",
                responseFormat: "mp3",
                languageType: "Auto",
                miniMaxEmotion: "calm",
                advanced: .init(sampleRate: 44_100)
            )
        }
    }
}
