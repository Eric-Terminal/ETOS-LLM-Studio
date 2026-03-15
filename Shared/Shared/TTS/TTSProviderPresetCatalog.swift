import Foundation

public struct TTSProviderRecommendedPreset: Equatable, Sendable {
    public var voice: String
    public var responseFormat: String
    public var languageType: String
    public var miniMaxEmotion: String

    public init(
        voice: String,
        responseFormat: String,
        languageType: String,
        miniMaxEmotion: String
    ) {
        self.voice = voice
        self.responseFormat = responseFormat
        self.languageType = languageType
        self.miniMaxEmotion = miniMaxEmotion
    }
}

public enum TTSProviderPresetCatalog {
    public static func voiceOptions(for kind: TTSProviderKind) -> [String] {
        switch kind {
        case .openAICompatible:
            return ["alloy", "echo", "fable", "onyx", "nova", "shimmer"]
        case .gemini:
            return ["Kore", "Puck", "Charon", "Fenrir", "Aoede"]
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
        }
    }

    public static func responseFormatOptions(for kind: TTSProviderKind) -> [String] {
        switch kind {
        case .openAICompatible:
            return ["mp3", "wav"]
        case .groq:
            return ["wav", "mp3"]
        case .gemini, .qwen, .miniMax:
            return []
        }
    }

    public static func languageTypeOptions(for kind: TTSProviderKind) -> [String] {
        switch kind {
        case .qwen:
            return ["Auto", "Chinese", "English", "Japanese", "Korean"]
        case .openAICompatible, .gemini, .miniMax, .groq:
            return []
        }
    }

    public static func miniMaxEmotionOptions(for kind: TTSProviderKind) -> [String] {
        switch kind {
        case .miniMax:
            return ["calm", "happy", "sad", "angry", "fearful", "disgusted", "surprised"]
        case .openAICompatible, .gemini, .qwen, .groq:
            return []
        }
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
        case .qwen:
            return .init(
                voice: "Cherry",
                responseFormat: "mp3",
                languageType: "Auto",
                miniMaxEmotion: "calm"
            )
        case .miniMax:
            return .init(
                voice: "female-shaonv",
                responseFormat: "mp3",
                languageType: "Auto",
                miniMaxEmotion: "calm"
            )
        case .groq:
            return .init(
                voice: "austin",
                responseFormat: "wav",
                languageType: "Auto",
                miniMaxEmotion: "calm"
            )
        }
    }
}
