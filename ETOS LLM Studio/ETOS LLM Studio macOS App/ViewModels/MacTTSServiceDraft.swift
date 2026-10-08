import Combine
import ETOSCore
import Foundation

@MainActor
final class MacTTSServiceDraft: ObservableObject {
    @Published var service: TTSServiceConfiguration { didSet { validate() } }
    @Published var advanced = TTSServiceAdvancedConfiguration()
    @Published var pronunciationText = ""
    @Published private(set) var fields = Set<TTSProviderConfigurationField>()
    @Published private(set) var hasAdvancedFields = false
    @Published private(set) var voiceOptions: [String] = []
    @Published private(set) var formatOptions: [String] = []
    @Published private(set) var languageOptions: [String] = []
    @Published private(set) var emotionOptions: [String] = []
    @Published private(set) var isPreparing = true
    @Published private(set) var isReady = false
    private var hasPrepared = false
    private var preparation: Task<Void, Never>?
    private var validation: Task<Void, Never>?
    private var revision = UUID()

    init(_ service: TTSServiceConfiguration) { self.service = service }
    func resume() { if hasPrepared { validate() } else { prepare() } }

    private func prepare() {
        let source = service
        preparation?.cancel(); validation?.cancel(); revision = UUID()
        let revision = revision
        isPreparing = true; isReady = false
        preparation = Task { [weak self] in
            let prepared = await Task.detached {
                let service = source.normalized
                let kind = service.providerKind
                return (service, service.advancedSettings, service.advancedSettings.pronunciationDictionary.joined(separator: "\n"),
                    TTSProviderPresetCatalog.configurationFields(for: kind), TTSProviderPresetCatalog.voiceOptions(for: kind),
                    TTSProviderPresetCatalog.responseFormatOptions(for: kind), TTSProviderPresetCatalog.languageTypeOptions(for: kind),
                    TTSProviderPresetCatalog.miniMaxEmotionOptions(for: kind), service.isReady)
            }.value
            guard let self, !Task.isCancelled, self.revision == revision else { return }
            service = prepared.0; advanced = prepared.1; pronunciationText = prepared.2
            fields = prepared.3; voiceOptions = prepared.4; formatOptions = prepared.5
            hasAdvancedFields = !fields.subtracting([.modelID, .responseFormat, .language, .emotion]).isEmpty
            languageOptions = prepared.6; emotionOptions = prepared.7
            isReady = prepared.8; isPreparing = false; hasPrepared = true
        }
    }

    func changeProvider(_ kind: TTSProviderKind) {
        guard service.providerKind != kind else { return }
        // 协议默认项是固定的小目录；同步更新草稿，后续同一提案的字段不会被迟到准备结果覆盖。
        preparation?.cancel(); validation?.cancel(); revision = UUID(); isPreparing = true
        service = service.changingProviderKind(to: kind)
        advanced = service.advancedSettings; pronunciationText = ""
        fields = TTSProviderPresetCatalog.configurationFields(for: kind)
        hasAdvancedFields = !fields.subtracting([.modelID, .responseFormat, .language, .emotion]).isEmpty
        voiceOptions = TTSProviderPresetCatalog.voiceOptions(for: kind)
        formatOptions = TTSProviderPresetCatalog.responseFormatOptions(for: kind)
        languageOptions = TTSProviderPresetCatalog.languageTypeOptions(for: kind)
        emotionOptions = TTSProviderPresetCatalog.miniMaxEmotionOptions(for: kind)
        isPreparing = false; hasPrepared = true; validate()
    }

    func resetRecommendations() {
        var source = service
        let recommended = TTSServiceConfiguration.defaultConfiguration(for: source.providerKind)
        source.modelID = recommended.modelID; source.voice = recommended.voice; source.responseFormat = recommended.responseFormat
        source.languageType = recommended.languageType; source.miniMaxEmotion = recommended.miniMaxEmotion; source.advanced = recommended.advanced
        service = source; advanced = recommended.advancedSettings; pronunciationText = ""
    }

    func preparedService() async -> TTSServiceConfiguration {
        let service = service, advanced = advanced, pronunciationText = pronunciationText
        return await Task.detached {
            var result = service, parameters = advanced
            // 数字输入来自系统边界；限制到设置页与向导共同提供的范围，避免 PCM 头整数溢出。
            parameters.sampleRate = min(max(parameters.sampleRate, 8_000), 48_000)
            parameters.bitrate = min(max(parameters.bitrate, 32_000), 256_000)
            parameters.pronunciationDictionary = pronunciationText.components(separatedBy: .newlines)
            result.advanced = parameters
            return result.normalized
        }.value
    }

    private func validate() {
        guard !isPreparing else { return }
        validation?.cancel()
        let service = service
        isReady = false
        validation = Task { [weak self] in
            let valid = await Task.detached { service.isReady }.value
            guard let self, !Task.isCancelled else { return }
            isReady = valid
        }
    }

    func cancel() { revision = UUID(); preparation?.cancel(); validation?.cancel() }
}
