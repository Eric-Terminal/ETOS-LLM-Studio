import SwiftUI
import Foundation
import ETOSCore

struct TTSSettingsView: View {
    @ObservedObject private var settingsStore = TTSSettingsStore.shared
    @ObservedObject private var serviceStore = TTSServiceStore.shared
    @ObservedObject private var appConfig = AppConfigStore.shared
    @ObservedObject private var ttsManager = TTSManager.shared
    @State private var isAddingService = false

    private var numberFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }

    var body: some View {
        List {
            playbackSection
            cloudServicesSection

            behaviorSection
            compatibilitySection
            playbackParametersSection
        }
        .navigationTitle(NSLocalizedString("TTS 设置", comment: ""))
        .navigationDestination(isPresented: $isAddingService) {
            WatchTTSServiceEditorView(
                service: .defaultConfiguration(for: .openAICompatible),
                selectsAfterSaving: true
            )
        }
        .guideSettingsPageContext(
            id: "watch-settings-tts",
            title: NSLocalizedString("TTS 设置", comment: "TTS 向导上下文标题"),
            documents: [GuideDocumentReference(id: "tts", title: "Text to Speech")],
            settings: guideSettings
        )
        .watchGuideEntry()
    }

    private var guideSettings: [GuidePageSetting] {
        [
            .string("playback_mode", label: NSLocalizedString("模式", comment: "向导设置字段"), allowedValues: TTSPlaybackMode.allCases.map(\.rawValue), get: { settingsStore.playbackMode.rawValue }, set: { settingsStore.playbackMode = TTSPlaybackMode(rawValue: $0) ?? settingsStore.playbackMode }),
            .string("selected_service_id", label: NSLocalizedString("当前服务", comment: "向导设置字段"), allowedValues: [""] + serviceStore.services.map { $0.id.uuidString }, get: { serviceStore.selectedServiceID?.uuidString ?? "" }, set: { serviceStore.select(UUID(uuidString: $0)) }),
            .bool("continue_in_background", label: NSLocalizedString("后台继续朗读", comment: "向导设置字段"), get: { appConfig.continueTTSPlaybackInBackground }, set: { appConfig.continueTTSPlaybackInBackground = $0 }),
            .bool("cache_network_audio", label: NSLocalizedString("缓存网络音频", comment: "向导设置字段"), get: { appConfig.ttsCacheNetworkAudioForReplay }, set: { appConfig.ttsCacheNetworkAudioForReplay = $0 }),
            .bool("auto_play_after_response", label: NSLocalizedString("自动朗读回复", comment: "向导设置字段"), get: { settingsStore.autoPlayAfterAssistantResponse }, set: { settingsStore.autoPlayAfterAssistantResponse = $0 }),
            .string("text_selection_mode", label: NSLocalizedString("朗读内容", comment: "向导设置字段"), allowedValues: TTSTextSelectionMode.allCases.map(\.rawValue), get: { textSelectionModeBinding.wrappedValue.rawValue }, set: { if let mode = TTSTextSelectionMode(rawValue: $0) { textSelectionModeBinding.wrappedValue = mode } }),
            .bool("watch_lightweight_preprocess", label: NSLocalizedString("轻量预处理", comment: "向导设置字段"), get: { settingsStore.watchUseLightweightPreprocess }, set: { settingsStore.watchUseLightweightPreprocess = $0 }),
            .integer("watch_max_characters", label: NSLocalizedString("最大字符", comment: "向导设置字段"), range: 500...6_000, get: { settingsStore.watchSpeechMaxCharacters }, set: { settingsStore.watchSpeechMaxCharacters = $0 }),
            .double("system_speech_rate", label: NSLocalizedString("系统语速", comment: "向导设置字段"), range: 0.1...3, get: { Double(settingsStore.speechRate) }, set: { settingsStore.speechRate = Float($0) }),
            .double("system_pitch", label: NSLocalizedString("系统音调", comment: "向导设置字段"), range: 0.1...2, get: { Double(settingsStore.pitch) }, set: { settingsStore.pitch = Float($0) }),
            .double("cloud_playback_speed", label: NSLocalizedString("默认倍速", comment: "向导设置字段"), range: 0.5...2, get: { Double(settingsStore.playbackSpeed) }, set: { settingsStore.playbackSpeed = Float($0) }),
            .readOnly("services", label: NSLocalizedString("云端语音服务", comment: "向导设置字段"), value: {
                .array(serviceStore.services.map { service in
                    .dictionary([
                        "id": .string(service.id.uuidString),
                        "name": .string(service.name),
                        "provider_kind": .string(service.providerKind.rawValue),
                        "base_url": .string(service.baseURL),
                        "model_id": .string(service.modelID),
                        "voice": .string(service.voice),
                        "api_key": .string(GuideSnapshotField.hiddenValue),
                        "ready": .bool(service.isReady)
                    ])
                })
            }),
            .readOnly("playback_status", label: NSLocalizedString("播放状态", comment: "向导设置字段"), value: { .string(ttsManager.playbackState.status.rawValue) })
        ]
    }

    private var playbackSection: some View {
        Section {
            Picker(NSLocalizedString("模式", comment: ""), selection: $settingsStore.playbackMode) {
                Text(NSLocalizedString("系统", comment: "")).tag(TTSPlaybackMode.system)
                Text(NSLocalizedString("云端", comment: "")).tag(TTSPlaybackMode.cloud)
                Text(NSLocalizedString("自动", comment: "")).tag(TTSPlaybackMode.auto)
            }

            Button(action: togglePreview) {
                Label(
                    ttsManager.isSpeaking
                        ? NSLocalizedString("停止试听", comment: "")
                        : NSLocalizedString("试听当前设置", comment: "TTS settings preview button"),
                    systemImage: ttsManager.isSpeaking ? "stop.circle" : "speaker.wave.2"
                )
            }
            .disabled(!canPreview)

            if ttsManager.playbackState.status == .error,
               let errorMessage = ttsManager.playbackState.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .etFont(.footnote)
                    .foregroundStyle(.red)
            }
        } header: {
            Text(NSLocalizedString("播放模式", comment: ""))
        } footer: {
            Text(NSLocalizedString("系统模式使用设备内置语音；云端模式使用选中的语音服务；自动模式优先系统，失败后回退云端。", comment: "TTS playback mode explanation"))
        }
    }

    private var cloudServicesSection: some View {
        Section {
            if serviceStore.services.isEmpty {
                Text(NSLocalizedString("尚未添加云端语音服务。", comment: "TTS 服务空状态"))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Picker(NSLocalizedString("当前服务", comment: "当前 TTS 服务"), selection: selectedServiceBinding) {
                    ForEach(serviceStore.services) { service in
                        Text(service.name).tag(Optional(service.id))
                    }
                }

                ForEach(serviceStore.services) { service in
                    NavigationLink {
                        WatchTTSServiceEditorView(service: service, selectsAfterSaving: false)
                    } label: {
                        VStack(alignment: .leading) {
                            HStack {
                                Text(service.name)
                                    .lineLimit(1)
                                if service.id == serviceStore.selectedServiceID {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.blue)
                                }
                            }
                            Text(serviceSummary(service))
                                .etFont(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .onDelete(perform: deleteServices)
                .onMove(perform: serviceStore.move)
            }

            Button {
                isAddingService = true
            } label: {
                Label(NSLocalizedString("添加语音服务", comment: ""), systemImage: "plus")
            }
        } header: {
            Text(NSLocalizedString("云端语音服务", comment: ""))
        } footer: {
            Text(NSLocalizedString("每个服务分别保存协议和语音参数；进入服务可试听当前配置。", comment: "watchOS TTS 服务列表说明"))
        }
    }

    private var behaviorSection: some View {
        Section {
            Toggle(
                NSLocalizedString("后台继续朗读", comment: "watchOS TTS 后台继续播放开关"),
                isOn: $appConfig.continueTTSPlaybackInBackground
            )
            Toggle(
                NSLocalizedString("缓存网络音频", comment: "watchOS TTS network audio replay cache"),
                isOn: $appConfig.ttsCacheNetworkAudioForReplay
            )
            Toggle(NSLocalizedString("自动朗读回复", comment: ""), isOn: $settingsStore.autoPlayAfterAssistantResponse)
            Picker(NSLocalizedString("朗读内容", comment: "TTS text selection picker"), selection: textSelectionModeBinding) {
                ForEach(TTSTextSelectionMode.allCases, id: \.self) { mode in
                    Text(mode.localizedName).tag(mode)
                }
            }
        } header: {
            Text(NSLocalizedString("朗读行为", comment: ""))
        } footer: {
            VStack(alignment: .leading) {
                Text(NSLocalizedString("所选内容为空时会朗读全文。", comment: "TTS text selection fallback explanation"))
                Text(NSLocalizedString("网络音频缓存只保留在内存中，用于重播时避免再次请求。", comment: "watchOS TTS behavior explanation"))
            }
        }
    }

    private var compatibilitySection: some View {
        Section(NSLocalizedString("watchOS 兼容", comment: "")) {
            Toggle(NSLocalizedString("轻量预处理（推荐）", comment: ""), isOn: $settingsStore.watchUseLightweightPreprocess)

            HStack {
                Text(NSLocalizedString("最大字符", comment: ""))
                Spacer()
                TextField(
                    NSLocalizedString("数量", comment: ""),
                    value: $settingsStore.watchSpeechMaxCharacters,
                    formatter: numberFormatter
                )
                .multilineTextAlignment(.trailing)
                .frame(width: 64)
            }

            Text(NSLocalizedString("如果点朗读会卡住，建议保持轻量预处理开启，并下调最大字符。", comment: ""))
                .etFont(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var playbackParametersSection: some View {
        Section(NSLocalizedString("播放参数", comment: "")) {
            if usesSystemPlayback {
                parameterSlider(
                    title: NSLocalizedString("系统语速", comment: ""),
                    value: Binding(
                        get: { Double(settingsStore.speechRate) },
                        set: { settingsStore.speechRate = Float($0) }
                    ),
                    range: 0.1...3.0
                )

                parameterSlider(
                    title: NSLocalizedString("系统音调", comment: ""),
                    value: Binding(
                        get: { Double(settingsStore.pitch) },
                        set: { settingsStore.pitch = Float($0) }
                    ),
                    range: 0.1...2.0
                )
            }

            if usesCloudPlayback {
                parameterSlider(
                    title: NSLocalizedString("默认倍速", comment: ""),
                    value: Binding(
                        get: { Double(settingsStore.playbackSpeed) },
                        set: { settingsStore.playbackSpeed = Float($0) }
                    ),
                    range: 0.5...2.0
                )
            }
        }
    }

    private func parameterSlider(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>
    ) -> some View {
        VStack(alignment: .leading) {
            Text(String(format: NSLocalizedString("%@ %.2f", comment: "TTS 参数与数值"), title, value.wrappedValue))
            Slider(value: value, in: range)
        }
    }

    private var selectedServiceBinding: Binding<UUID?> {
        Binding(
            get: { serviceStore.selectedServiceID },
            set: { serviceStore.select($0) }
        )
    }

    private var textSelectionModeBinding: Binding<TTSTextSelectionMode> {
        Binding(
            get: {
                TTSTextSelectionMode(rawValue: appConfig.ttsTextSelectionMode)
                    ?? (settingsStore.onlyReadQuotedContent ? .quotedOnly : .fullText)
            },
            set: { mode in
                appConfig.ttsTextSelectionMode = mode.rawValue
                settingsStore.onlyReadQuotedContent = false
            }
        )
    }

    private var usesSystemPlayback: Bool {
        settingsStore.playbackMode != .cloud
    }

    private var usesCloudPlayback: Bool {
        settingsStore.playbackMode != .system
    }

    private var canPreview: Bool {
        settingsStore.playbackMode != .cloud || serviceStore.selectedService?.isReady == true
    }

    private func togglePreview() {
        if ttsManager.isSpeaking {
            ttsManager.stop()
            return
        }
        ttsManager.speak(NSLocalizedString("这是 TTS 试听。", comment: "TTS preview sample"), flush: true)
    }

    private func deleteServices(at offsets: IndexSet) {
        let serviceIDs = offsets.map { serviceStore.services[$0].id }
        serviceIDs.forEach(serviceStore.delete)
    }

    private func serviceSummary(_ service: TTSServiceConfiguration) -> String {
        let detail = service.trimmedModelID.isEmpty ? service.trimmedVoice : service.trimmedModelID
        return "\(service.providerKind.localizedName) · \(detail)"
    }
}
private struct WatchTTSServiceEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var serviceStore = TTSServiceStore.shared
    @ObservedObject private var ttsManager = TTSManager.shared
    @State private var draft: TTSServiceConfiguration

    let selectsAfterSaving: Bool

    init(service: TTSServiceConfiguration, selectsAfterSaving: Bool) {
        _draft = State(initialValue: service)
        self.selectsAfterSaving = selectsAfterSaving
    }

    var body: some View {
        List {
            Section(NSLocalizedString("服务", comment: "TTS 服务编辑分组")) {
                Picker(NSLocalizedString("接口类型", comment: ""), selection: providerKindBinding) {
                    ForEach(TTSProviderKind.allCases, id: \.self) { kind in
                        Text(kind.localizedName).tag(kind)
                    }
                }

                TextField(NSLocalizedString("名称", comment: ""), text: $draft.name.watchKeyboardNewlineBinding())
            }

            Section {
                TextField(baseURLFieldLabel, text: $draft.baseURL.watchKeyboardNewlineBinding())
                SecureField(NSLocalizedString("API Key", comment: ""), text: $draft.apiKey.watchKeyboardNewlineBinding())
                if fields.contains(.modelID) {
                    TextField(NSLocalizedString("模型 ID", comment: ""), text: $draft.modelID.watchKeyboardNewlineBinding())
                }
            } header: {
                Text(NSLocalizedString("接口", comment: "TTS 接口配置分组"))
            } footer: {
                Text(interfaceFooterText)
            }

            Section(NSLocalizedString("语音", comment: "TTS 语音参数分组")) {
                if !voiceOptions.isEmpty {
                    Picker(NSLocalizedString("推荐 Voice", comment: ""), selection: voicePresetBinding) {
                        ForEach(voiceOptions, id: \.self) { voice in
                            Text(voice).tag(voice)
                        }
                        Text(NSLocalizedString("自定义", comment: "")).tag(Self.customPresetTag)
                    }
                }

                TextField(voiceFieldLabel, text: $draft.voice.watchKeyboardNewlineBinding())

                if !responseFormatOptions.isEmpty {
                    Picker(NSLocalizedString("格式", comment: ""), selection: $draft.responseFormat) {
                        ForEach(responseFormatOptions, id: \.self) { format in
                            Text(format).tag(format)
                        }
                    }
                }

                if !languageTypeOptions.isEmpty {
                    Picker(NSLocalizedString("推荐语言", comment: "TTS recommended language"), selection: languagePresetBinding) {
                        ForEach(languageTypeOptions, id: \.self) { language in
                            Text(language).tag(language)
                        }
                        Text(NSLocalizedString("自定义", comment: "")).tag(Self.customPresetTag)
                    }
                    TextField(NSLocalizedString("语言", comment: ""), text: $draft.languageType.watchKeyboardNewlineBinding())
                }

                if !miniMaxEmotionOptions.isEmpty {
                    Picker(NSLocalizedString("情感", comment: ""), selection: $draft.miniMaxEmotion) {
                        ForEach(miniMaxEmotionOptions, id: \.self) { emotion in
                            Text(emotion).tag(emotion)
                        }
                    }
                }

                Button {
                    applyRecommendedParameters()
                } label: {
                    Label(NSLocalizedString("恢复推荐参数", comment: ""), systemImage: "wand.and.stars")
                }
            }

            if hasAdvancedFields {
                advancedParametersSection
            }

            Section {
                Button(action: togglePreview) {
                    Label(
                        ttsManager.isSpeaking
                            ? NSLocalizedString("停止试听", comment: "")
                            : NSLocalizedString("试听此服务", comment: "TTS per-service preview button"),
                        systemImage: ttsManager.isSpeaking ? "stop.circle" : "speaker.wave.2"
                    )
                }
                .disabled(!draft.isReady)
            } footer: {
                Text(NSLocalizedString("试听会直接使用当前页面中的参数，无需先保存。", comment: "TTS draft preview explanation"))
            }
        }
        .navigationTitle(selectsAfterSaving
            ? NSLocalizedString("添加语音服务", comment: "")
            : NSLocalizedString("编辑语音服务", comment: ""))
        .guideSettingsPageContext(
            id: "watch-settings-tts-service-editor",
            title: selectsAfterSaving
                ? NSLocalizedString("添加语音服务", comment: "TTS service guide title")
                : String(format: NSLocalizedString("语音服务：%@", comment: "TTS service guide title"), draft.name),
            documents: [GuideDocumentReference(id: "tts", title: "Text to Speech")],
            settings: guideSettings
        )
        .watchGuideEntry()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(NSLocalizedString("取消", comment: "")) {
                    dismiss()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(NSLocalizedString("保存", comment: "")) {
                    serviceStore.upsert(draft, selectAfterSaving: selectsAfterSaving)
                    dismiss()
                }
                .disabled(!draft.isReady)
            }
        }
    }

    private var guideSettings: [GuidePageSetting] {
        var result: [GuidePageSetting] = [
            .string("provider_kind", label: NSLocalizedString("接口类型", comment: "向导设置字段"), allowedValues: TTSProviderKind.allCases.map(\.rawValue), get: { draft.providerKind.rawValue }, set: { if let kind = TTSProviderKind(rawValue: $0) { providerKindBinding.wrappedValue = kind } }),
            .string("name", label: NSLocalizedString("名称", comment: "向导设置字段"), allowsEmpty: false, get: { draft.name }, set: { draft.name = $0 }),
            .string("base_url", label: baseURLFieldLabel, allowsEmpty: false, get: { draft.baseURL }, set: { draft.baseURL = $0 }),
            .writeOnlyString("api_key", label: NSLocalizedString("API Key", comment: "向导设置字段"), isConfigured: { !draft.trimmedAPIKey.isEmpty }, set: { draft.apiKey = $0 }),
            .string("model_id", label: NSLocalizedString("模型 ID", comment: "向导设置字段"), get: { draft.modelID }, set: { draft.modelID = $0 }),
            .string("voice", label: voiceFieldLabel, get: { draft.voice }, set: { draft.voice = $0 }),
            .string("response_format", label: NSLocalizedString("格式", comment: "向导设置字段"), allowedValues: responseFormatOptions.isEmpty ? nil : responseFormatOptions, get: { draft.responseFormat }, set: { draft.responseFormat = $0 }),
            .string("language", label: NSLocalizedString("语言", comment: "向导设置字段"), allowedValues: languageTypeOptions.isEmpty ? nil : languageTypeOptions, get: { draft.languageType }, set: { draft.languageType = $0 }),
            .string("emotion", label: NSLocalizedString("情感", comment: "向导设置字段"), allowedValues: miniMaxEmotionOptions.isEmpty ? nil : miniMaxEmotionOptions, get: { draft.miniMaxEmotion }, set: { draft.miniMaxEmotion = $0 })
        ]
        if fields.contains(.workspace) {
            result.append(.string("workspace_id", label: NSLocalizedString("Workspace ID", comment: "向导设置字段"), get: { draft.advancedSettings.workspaceID }, set: { advancedBinding(\.workspaceID).wrappedValue = $0 }))
        }
        if fields.contains(.region) {
            result.append(.string("region", label: NSLocalizedString("区域", comment: "向导设置字段"), get: { draft.advancedSettings.region }, set: { advancedBinding(\.region).wrappedValue = $0 }))
        }
        if fields.contains(.instruction) {
            result.append(.string("instruction", label: NSLocalizedString("语音指令", comment: "向导设置字段"), get: { draft.advancedSettings.instruction }, set: { advancedBinding(\.instruction).wrappedValue = $0 }))
        }
        if fields.contains(.speed) {
            result.append(.double("synthesis_speed", label: NSLocalizedString("合成语速", comment: "向导设置字段"), range: 0.5...2, get: { draft.advancedSettings.speed }, set: { advancedBinding(\.speed).wrappedValue = $0 }))
        }
        if fields.contains(.volume) {
            result.append(.double("synthesis_volume", label: NSLocalizedString("合成音量", comment: "向导设置字段"), range: 0...10, get: { draft.advancedSettings.volume }, set: { advancedBinding(\.volume).wrappedValue = $0 }))
        }
        if fields.contains(.pitch) {
            result.append(.integer("synthesis_pitch", label: NSLocalizedString("合成音调", comment: "向导设置字段"), range: -12...12, get: { draft.advancedSettings.pitch }, set: { advancedBinding(\.pitch).wrappedValue = $0 }))
        }
        if fields.contains(.sampleRate) {
            result.append(.integer("sample_rate", label: NSLocalizedString("采样率", comment: "向导设置字段"), range: 8_000...48_000, get: { draft.advancedSettings.sampleRate }, set: { advancedBinding(\.sampleRate).wrappedValue = $0 }))
        }
        if fields.contains(.bitrate) {
            result.append(.integer("bitrate", label: NSLocalizedString("比特率", comment: "向导设置字段"), range: 32_000...256_000, get: { draft.advancedSettings.bitrate }, set: { advancedBinding(\.bitrate).wrappedValue = $0 }))
        }
        if fields.contains(.channels) {
            result.append(.integer("channels", label: NSLocalizedString("声道", comment: "向导设置字段"), range: 1...2, get: { draft.advancedSettings.channels }, set: { advancedBinding(\.channels).wrappedValue = $0 }))
        }
        if fields.contains(.languageBoost) {
            result.append(.string("language_boost", label: NSLocalizedString("语言增强", comment: "向导设置字段"), get: { draft.advancedSettings.languageBoost }, set: { advancedBinding(\.languageBoost).wrappedValue = $0 }))
        }
        if fields.contains(.pronunciationDictionary) {
            result.append(.string("pronunciation_dictionary", label: NSLocalizedString("发音词典", comment: "向导设置字段"), get: { pronunciationDictionaryBinding.wrappedValue }, set: { pronunciationDictionaryBinding.wrappedValue = $0 }))
        }
        if fields.contains(.temperature) {
            result.append(.double("temperature", label: NSLocalizedString("随机性", comment: "向导设置字段"), range: 0...1, get: { draft.advancedSettings.temperature }, set: { advancedBinding(\.temperature).wrappedValue = $0 }))
        }
        if fields.contains(.topP) {
            result.append(.double("top_p", label: NSLocalizedString("Top P", comment: "向导设置字段"), range: 0...1, get: { draft.advancedSettings.topP }, set: { advancedBinding(\.topP).wrappedValue = $0 }))
        }
        if fields.contains(.latency) {
            result.append(.string("latency", label: NSLocalizedString("延迟模式", comment: "向导设置字段"), allowedValues: ["normal", "balanced", "low"], get: { draft.advancedSettings.latency }, set: { advancedBinding(\.latency).wrappedValue = $0 }))
        }
        if fields.contains(.subtitles) {
            result.append(.bool("subtitles", label: NSLocalizedString("返回字幕", comment: "向导设置字段"), get: { draft.advancedSettings.subtitleEnabled }, set: { advancedBinding(\.subtitleEnabled).wrappedValue = $0 }))
        }
        if fields.contains(.optimizeTextPreview) {
            result.append(.bool("optimize_text_preview", label: NSLocalizedString("优化文本预览", comment: "向导设置字段"), get: { draft.advancedSettings.optimizeTextPreview }, set: { advancedBinding(\.optimizeTextPreview).wrappedValue = $0 }))
        }
        result.append(.readOnly("requires_save", label: NSLocalizedString("应用方式", comment: "向导设置字段"), value: { .string(NSLocalizedString("修改后需要保存", comment: "向导草稿应用方式")) }))
        return result
    }

    @ViewBuilder
    private var advancedParametersSection: some View {
        Section(NSLocalizedString("高级参数", comment: "TTS advanced parameters section")) {
            if fields.contains(.workspace) {
                TextField(
                    NSLocalizedString("Workspace ID", comment: "TTS workspace identifier"),
                    text: advancedBinding(\.workspaceID).watchKeyboardNewlineBinding()
                )
            }

            if fields.contains(.region) {
                TextField(
                    NSLocalizedString("区域", comment: "TTS service region"),
                    text: advancedBinding(\.region).watchKeyboardNewlineBinding()
                )
            }

            if fields.contains(.instruction) {
                TextField(
                    NSLocalizedString("语音指令", comment: "TTS provider instruction"),
                    text: advancedBinding(\.instruction).watchKeyboardNewlineBinding()
                )
            }

            if fields.contains(.speed) {
                advancedSlider(
                    title: NSLocalizedString("合成语速", comment: "TTS synthesis speed"),
                    value: advancedBinding(\.speed),
                    range: 0.5...2
                )
            }

            if fields.contains(.volume) {
                advancedSlider(
                    title: NSLocalizedString("合成音量", comment: "TTS synthesis volume"),
                    value: advancedBinding(\.volume),
                    range: 0...10
                )
            }

            if fields.contains(.pitch) {
                Stepper(value: advancedBinding(\.pitch), in: -12...12) {
                    Text(String(
                        format: NSLocalizedString("合成音调 %d", comment: "TTS synthesis pitch and value"),
                        draft.advancedSettings.pitch
                    ))
                }
            }

            if fields.contains(.sampleRate) {
                Picker(NSLocalizedString("采样率", comment: "TTS audio sample rate"), selection: advancedBinding(\.sampleRate)) {
                    ForEach([8_000, 16_000, 22_050, 24_000, 32_000, 44_100, 48_000], id: \.self) { value in
                        Text("\(value) Hz").tag(value)
                    }
                }
            }

            if fields.contains(.bitrate) {
                Picker(NSLocalizedString("比特率", comment: "TTS audio bitrate"), selection: advancedBinding(\.bitrate)) {
                    ForEach([32_000, 64_000, 128_000, 256_000], id: \.self) { value in
                        Text("\(value / 1_000) kbps").tag(value)
                    }
                }
            }

            if fields.contains(.channels) {
                Picker(NSLocalizedString("声道", comment: "TTS audio channels"), selection: advancedBinding(\.channels)) {
                    Text(NSLocalizedString("单声道", comment: "Mono audio")).tag(1)
                    Text(NSLocalizedString("立体声", comment: "Stereo audio")).tag(2)
                }
            }

            if fields.contains(.languageBoost) {
                TextField(
                    NSLocalizedString("语言增强", comment: "MiniMax language boost"),
                    text: advancedBinding(\.languageBoost).watchKeyboardNewlineBinding()
                )
            }

            if fields.contains(.pronunciationDictionary) {
                TextField(
                    NSLocalizedString("发音词典", comment: "MiniMax pronunciation dictionary"),
                    text: pronunciationDictionaryBinding.watchKeyboardNewlineBinding()
                )
            }

            if fields.contains(.temperature) {
                advancedSlider(
                    title: NSLocalizedString("随机性", comment: "Fish Audio temperature"),
                    value: advancedBinding(\.temperature),
                    range: 0...1
                )
            }

            if fields.contains(.topP) {
                advancedSlider(
                    title: NSLocalizedString("Top P", comment: "Fish Audio top-p"),
                    value: advancedBinding(\.topP),
                    range: 0...1
                )
            }

            if fields.contains(.latency) {
                Picker(NSLocalizedString("延迟模式", comment: "Fish Audio latency mode"), selection: advancedBinding(\.latency)) {
                    Text(NSLocalizedString("标准", comment: "Normal latency")).tag("normal")
                    Text(NSLocalizedString("均衡", comment: "Balanced latency")).tag("balanced")
                    Text(NSLocalizedString("低延迟", comment: "Low latency")).tag("low")
                }
            }

            if fields.contains(.subtitles) {
                Toggle(NSLocalizedString("返回字幕", comment: "TTS subtitle option"), isOn: advancedBinding(\.subtitleEnabled))
            }

            if fields.contains(.optimizeTextPreview) {
                Toggle(NSLocalizedString("优化文本预览", comment: "MiMo voice design option"), isOn: advancedBinding(\.optimizeTextPreview))
            }
        }
    }

    private static let customPresetTag = "__custom__"

    private var fields: Set<TTSProviderConfigurationField> {
        TTSProviderPresetCatalog.configurationFields(for: draft.providerKind)
    }

    private var hasAdvancedFields: Bool {
        !fields.subtracting([.modelID, .responseFormat, .language, .emotion]).isEmpty
    }

    private var baseURLFieldLabel: String {
        draft.providerKind == .qwenAudio
            ? NSLocalizedString("WebSocket URL", comment: "TTS WebSocket endpoint")
            : NSLocalizedString("Base URL", comment: "")
    }

    private var interfaceFooterText: String {
        if draft.providerKind == .qwenAudio {
            return NSLocalizedString(
                "可直接使用默认 WebSocket 地址；填写 Workspace ID 后会按区域生成专属地址。",
                comment: "Qwen Audio WebSocket explanation"
            )
        }
        return NSLocalizedString(
            "填写版本根路径，应用会补全语音合成端点。",
            comment: "watchOS TTS Base URL 说明"
        )
    }

    private var voiceFieldLabel: String {
        switch draft.providerKind {
        case .fishAudio:
            return NSLocalizedString("Reference ID", comment: "Fish Audio reference identifier")
        case .xAI, .elevenLabs:
            return NSLocalizedString("Voice ID", comment: "TTS voice identifier")
        default:
            return NSLocalizedString("Voice", comment: "TTS voice text field")
        }
    }

    private var providerKindBinding: Binding<TTSProviderKind> {
        Binding(
            get: { draft.providerKind },
            set: { draft = draft.changingProviderKind(to: $0) }
        )
    }

    private var voiceOptions: [String] {
        TTSProviderPresetCatalog.voiceOptions(for: draft.providerKind)
    }

    private var responseFormatOptions: [String] {
        TTSProviderPresetCatalog.responseFormatOptions(for: draft.providerKind)
    }

    private var languageTypeOptions: [String] {
        TTSProviderPresetCatalog.languageTypeOptions(for: draft.providerKind)
    }

    private var miniMaxEmotionOptions: [String] {
        TTSProviderPresetCatalog.miniMaxEmotionOptions(for: draft.providerKind)
    }

    private var voicePresetBinding: Binding<String> {
        Binding(
            get: { voiceOptions.contains(draft.voice) ? draft.voice : Self.customPresetTag },
            set: { newValue in
                guard newValue != Self.customPresetTag else { return }
                draft.voice = newValue
            }
        )
    }

    private var languagePresetBinding: Binding<String> {
        Binding(
            get: { languageTypeOptions.contains(draft.languageType) ? draft.languageType : Self.customPresetTag },
            set: { newValue in
                guard newValue != Self.customPresetTag else { return }
                draft.languageType = newValue
            }
        )
    }

    private var pronunciationDictionaryBinding: Binding<String> {
        Binding(
            get: { draft.advancedSettings.pronunciationDictionary.joined(separator: "\n") },
            set: { value in
                var advanced = draft.advancedSettings
                advanced.pronunciationDictionary = value.components(separatedBy: .newlines)
                draft.advanced = advanced
            }
        )
    }

    private func advancedBinding<Value>(
        _ keyPath: WritableKeyPath<TTSServiceAdvancedConfiguration, Value>
    ) -> Binding<Value> {
        Binding(
            get: { draft.advancedSettings[keyPath: keyPath] },
            set: { value in
                var advanced = draft.advancedSettings
                advanced[keyPath: keyPath] = value
                draft.advanced = advanced
            }
        )
    }

    private func advancedSlider(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>
    ) -> some View {
        VStack(alignment: .leading) {
            Text(String(
                format: NSLocalizedString("%@ %.2f", comment: "TTS parameter and value"),
                title,
                value.wrappedValue
            ))
            Slider(value: value, in: range)
        }
    }

    private func applyRecommendedParameters() {
        let defaults = TTSServiceConfiguration.defaultConfiguration(for: draft.providerKind)
        let preset = TTSProviderPresetCatalog.recommendedPreset(for: draft.providerKind)
        draft.modelID = defaults.modelID
        draft.voice = preset.voice
        draft.responseFormat = preset.responseFormat
        draft.languageType = preset.languageType
        draft.miniMaxEmotion = preset.miniMaxEmotion
        draft.advanced = preset.advanced
    }

    private func togglePreview() {
        if ttsManager.isSpeaking {
            ttsManager.stop()
        } else {
            ttsManager.preview(
                NSLocalizedString("这是 TTS 试听。", comment: "TTS preview sample"),
                using: draft
            )
        }
    }
}
