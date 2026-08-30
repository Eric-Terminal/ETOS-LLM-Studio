// ============================================================================
// TTSServiceConfiguration.swift
// ============================================================================
// ETOS LLM Studio
//
// 独立管理网络 TTS 服务，避免把语音接口伪装成通用大语言模型。
// ============================================================================

import Combine
import Foundation

public struct TTSServiceConfiguration: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var providerKind: TTSProviderKind
    public var baseURL: String
    public var apiKey: String
    public var modelID: String
    public var voice: String
    public var responseFormat: String
    public var languageType: String
    public var miniMaxEmotion: String
    public var advanced: TTSServiceAdvancedConfiguration?

    public init(
        id: UUID = UUID(),
        name: String,
        providerKind: TTSProviderKind,
        baseURL: String,
        apiKey: String,
        modelID: String,
        voice: String,
        responseFormat: String,
        languageType: String,
        miniMaxEmotion: String,
        advanced: TTSServiceAdvancedConfiguration? = nil
    ) {
        self.id = id
        self.name = name
        self.providerKind = providerKind
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.modelID = modelID
        self.voice = voice
        self.responseFormat = responseFormat
        self.languageType = languageType
        self.miniMaxEmotion = miniMaxEmotion
        self.advanced = advanced
    }

    public var isReady: Bool {
        guard !trimmedName.isEmpty,
              !trimmedBaseURL.isEmpty,
              !trimmedAPIKey.isEmpty,
              hasValidBaseURL else { return false }
        if TTSProviderPresetCatalog.requiresModelID(for: providerKind), trimmedModelID.isEmpty {
            return false
        }
        if providerKind != .miMo || trimmedModelID != "mimo-v2.5-tts-voicedesign" {
            guard !trimmedVoice.isEmpty else { return false }
        }
        return true
    }

    private var hasValidBaseURL: Bool {
        guard let url = URL(string: trimmedBaseURL), url.host != nil else { return false }
        let allowedSchemes = providerKind == .qwenAudio ? ["ws", "wss"] : ["http", "https"]
        return url.scheme.map { allowedSchemes.contains($0.lowercased()) } == true
    }

    public var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var trimmedBaseURL: String {
        baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var trimmedAPIKey: String {
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var trimmedModelID: String {
        modelID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var trimmedVoice: String {
        voice.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var normalized: TTSServiceConfiguration {
        var result = self
        result.name = trimmedName
        result.baseURL = trimmedBaseURL
        result.apiKey = trimmedAPIKey
        result.modelID = trimmedModelID
        result.voice = trimmedVoice
        result.responseFormat = responseFormat.trimmingCharacters(in: .whitespacesAndNewlines)
        result.languageType = languageType.trimmingCharacters(in: .whitespacesAndNewlines)
        result.miniMaxEmotion = miniMaxEmotion.trimmingCharacters(in: .whitespacesAndNewlines)
        result.advanced = advancedSettings.normalized
        return result
    }

    public var advancedSettings: TTSServiceAdvancedConfiguration {
        advanced ?? TTSProviderPresetCatalog.recommendedPreset(for: providerKind).advanced
    }

    public static func defaultConfiguration(
        for kind: TTSProviderKind,
        id: UUID = UUID()
    ) -> TTSServiceConfiguration {
        let preset = TTSProviderPresetCatalog.recommendedPreset(for: kind)
        let serviceDefaults = defaults(for: kind)
        return TTSServiceConfiguration(
            id: id,
            name: serviceDefaults.name,
            providerKind: kind,
            baseURL: serviceDefaults.baseURL,
            apiKey: "",
            modelID: serviceDefaults.modelID,
            voice: preset.voice,
            responseFormat: preset.responseFormat,
            languageType: preset.languageType,
            miniMaxEmotion: preset.miniMaxEmotion,
            advanced: preset.advanced
        )
    }

    public func changingProviderKind(to kind: TTSProviderKind) -> TTSServiceConfiguration {
        guard providerKind != kind else { return self }
        return Self.defaultConfiguration(for: kind, id: id)
    }

    public static func migrated(
        from runnable: RunnableModel,
        settings: TTSSettingsSnapshot
    ) -> TTSServiceConfiguration {
        TTSServiceConfiguration(
            name: runnable.model.displayName,
            providerKind: settings.providerKind,
            baseURL: runnable.provider.baseURL,
            apiKey: runnable.provider.apiKeys.first ?? "",
            modelID: runnable.model.modelName,
            voice: settings.voice,
            responseFormat: settings.responseFormat,
            languageType: settings.languageType,
            miniMaxEmotion: settings.miniMaxEmotion
        ).normalized
    }

    private static func defaults(for kind: TTSProviderKind) -> (name: String, baseURL: String, modelID: String) {
        switch kind {
        case .openAICompatible:
            return (
                NSLocalizedString("OpenAI TTS", comment: "默认 TTS 服务名称"),
                "https://api.openai.com/v1",
                "gpt-4o-mini-tts"
            )
        case .gemini:
            return (
                NSLocalizedString("Gemini TTS", comment: "默认 TTS 服务名称"),
                "https://generativelanguage.googleapis.com/v1beta",
                "gemini-3.1-flash-tts-preview"
            )
        case .azure:
            return (
                NSLocalizedString("Azure TTS", comment: "默认 TTS 服务名称"),
                "",
                ""
            )
        case .qwen:
            return (
                NSLocalizedString("Qwen TTS", comment: "默认 TTS 服务名称"),
                "https://dashscope.aliyuncs.com/api/v1",
                "qwen3-tts-flash"
            )
        case .qwenAudio:
            return (
                NSLocalizedString("Qwen Audio TTS", comment: "默认 TTS 服务名称"),
                "wss://dashscope.aliyuncs.com/api-ws/v1/inference",
                "qwen-audio-3.0-tts-flash"
            )
        case .miniMax:
            return (
                NSLocalizedString("MiniMax TTS", comment: "默认 TTS 服务名称"),
                "https://api.minimaxi.com/v1",
                "speech-2.8-turbo"
            )
        case .groq:
            return (
                NSLocalizedString("Groq TTS", comment: "默认 TTS 服务名称"),
                "https://api.groq.com/openai/v1",
                "canopylabs/orpheus-v1-english"
            )
        case .xAI:
            return (
                NSLocalizedString("xAI TTS", comment: "默认 TTS 服务名称"),
                "https://api.x.ai/v1",
                ""
            )
        case .elevenLabs:
            return (
                NSLocalizedString("ElevenLabs TTS", comment: "默认 TTS 服务名称"),
                "https://api.elevenlabs.io",
                "eleven_multilingual_v2"
            )
        case .miMo:
            return (
                NSLocalizedString("MiMo TTS", comment: "默认 TTS 服务名称"),
                "https://api.xiaomimimo.com/v1",
                "mimo-v2.5-tts"
            )
        case .stepFun:
            return (
                NSLocalizedString("StepFun TTS", comment: "默认 TTS 服务名称"),
                "https://api.stepfun.com/v1",
                "stepaudio-2.5-tts"
            )
        case .fishAudio:
            return (
                NSLocalizedString("Fish Audio TTS", comment: "默认 TTS 服务名称"),
                "https://api.fish.audio",
                "s2.1-pro"
            )
        }
    }
}

@MainActor
public final class TTSServiceStore: ObservableObject {
    public static let shared = TTSServiceStore()

    @Published public private(set) var services: [TTSServiceConfiguration] = []
    @Published public private(set) var selectedServiceID: UUID?

    public var selectedService: TTSServiceConfiguration? {
        guard let selectedServiceID else { return nil }
        return services.first { $0.id == selectedServiceID }
    }

    private struct Payload: Codable, Equatable, Sendable {
        var services: [TTSServiceConfiguration]
        var selectedServiceID: UUID?
        var didMigrateLegacyModel: Bool
    }

    private struct LoadedPayload: Sendable {
        var payload: Payload
        var needsPersistence: Bool
    }

    private let appConfig: AppConfigStore
    private var configurationCancellable: AnyCancellable?
    private var reloadTask: Task<Void, Never>?
    private var persistenceRevision = 0

    private init() {
        let appConfig = AppConfigStore.shared
        self.appConfig = appConfig
        configurationCancellable = appConfig.$ttsServiceConfiguration
            .removeDuplicates()
            .sink { [weak self] rawValue in
                Task { @MainActor [weak self] in
                    self?.reload(from: rawValue)
                }
            }
    }

    deinit {
        reloadTask?.cancel()
        configurationCancellable?.cancel()
    }

    public func select(_ serviceID: UUID?) {
        let validID = serviceID.flatMap { candidate in
            services.contains(where: { $0.id == candidate }) ? candidate : nil
        }
        guard selectedServiceID != validID else { return }
        selectedServiceID = validID
        persistCurrentState(didMigrateLegacyModel: true)
    }

    public func upsert(_ service: TTSServiceConfiguration, selectAfterSaving: Bool = false) {
        let normalized = service.normalized
        if let index = services.firstIndex(where: { $0.id == normalized.id }) {
            services[index] = normalized
        } else {
            services.append(normalized)
        }
        if selectAfterSaving || selectedServiceID == nil {
            selectedServiceID = normalized.id
        }
        persistCurrentState(didMigrateLegacyModel: true)
    }

    public func delete(_ serviceID: UUID) {
        services.removeAll { $0.id == serviceID }
        if selectedServiceID == serviceID {
            selectedServiceID = services.first?.id
        }
        persistCurrentState(didMigrateLegacyModel: true)
    }

    public func move(from source: IndexSet, to destination: Int) {
        let movingServices = source.compactMap { index in
            services.indices.contains(index) ? services[index] : nil
        }
        guard !movingServices.isEmpty else { return }
        for index in source.sorted(by: >) where services.indices.contains(index) {
            services.remove(at: index)
        }
        let removedBeforeDestination = source.filter { $0 < destination }.count
        let insertionIndex = min(max(0, destination - removedBeforeDestination), services.count)
        services.insert(contentsOf: movingServices, at: insertionIndex)
        persistCurrentState(didMigrateLegacyModel: true)
    }

    private func reload(from rawValue: String) {
        reloadTask?.cancel()
        let legacySettings = TTSSettingsStore.shared.snapshot
        reloadTask = Task { [weak self] in
            let loaded = await Task.detached(priority: .userInitiated) {
                Self.loadPayload(from: rawValue, legacySettings: legacySettings)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.apply(loaded.payload)
            if loaded.needsPersistence {
                self.persistCurrentState(didMigrateLegacyModel: true)
            }
        }
    }

    private func apply(_ payload: Payload) {
        let normalized = Self.normalizedPayload(payload)
        services = normalized.services
        selectedServiceID = normalized.selectedServiceID
    }

    private func persistCurrentState(didMigrateLegacyModel: Bool) {
        let payload = Self.normalizedPayload(Payload(
            services: services,
            selectedServiceID: selectedServiceID,
            didMigrateLegacyModel: didMigrateLegacyModel
        ))
        apply(payload)
        persistenceRevision &+= 1
        let revision = persistenceRevision

        Task { [weak self] in
            let rawValue = await Task.detached(priority: .utility) {
                guard let data = try? JSONEncoder().encode(payload) else { return nil as String? }
                return String(data: data, encoding: .utf8)
            }.value
            guard let self,
                  revision == self.persistenceRevision,
                  let rawValue,
                  rawValue != self.appConfig.ttsServiceConfiguration else { return }
            self.appConfig.ttsServiceConfiguration = rawValue
        }
    }

    private nonisolated static func loadPayload(
        from rawValue: String,
        legacySettings: TTSSettingsSnapshot
    ) -> LoadedPayload {
        let decoded = rawValue.data(using: .utf8)
            .flatMap { try? JSONDecoder().decode(Payload.self, from: $0) }
            ?? Payload(services: [], selectedServiceID: nil, didMigrateLegacyModel: false)
        var payload = normalizedPayload(decoded)
        var needsPersistence = payload != decoded

        guard !payload.didMigrateLegacyModel else {
            return LoadedPayload(payload: payload, needsPersistence: needsPersistence)
        }

        payload.didMigrateLegacyModel = true
        needsPersistence = true
        guard payload.services.isEmpty,
              let legacyIdentifier = Persistence.readAppConfigText(
                key: AppConfigKey.ttsModelIdentifier.rawValue
              ),
              !legacyIdentifier.isEmpty else {
            return LoadedPayload(payload: payload, needsPersistence: needsPersistence)
        }

        let runnableModels = ConfigLoader.loadProviders().flatMap { provider in
            provider.models.map { RunnableModel(provider: provider, model: $0) }
        }
        guard let legacyModel = runnableModels.first(where: { $0.id == legacyIdentifier }) else {
            return LoadedPayload(payload: payload, needsPersistence: needsPersistence)
        }

        let migratedService = TTSServiceConfiguration.migrated(
            from: legacyModel,
            settings: legacySettings
        )
        payload.services = [migratedService]
        payload.selectedServiceID = migratedService.id
        return LoadedPayload(payload: payload, needsPersistence: needsPersistence)
    }

    private nonisolated static func normalizedPayload(_ payload: Payload) -> Payload {
        var seenIDs = Set<UUID>()
        let normalizedServices = payload.services.compactMap { service -> TTSServiceConfiguration? in
            guard seenIDs.insert(service.id).inserted else { return nil }
            return service.normalized
        }
        let selectedID = payload.selectedServiceID.flatMap { candidate in
            normalizedServices.contains(where: { $0.id == candidate }) ? candidate : nil
        } ?? normalizedServices.first?.id
        return Payload(
            services: normalizedServices,
            selectedServiceID: selectedID,
            didMigrateLegacyModel: payload.didMigrateLegacyModel
        )
    }
}
