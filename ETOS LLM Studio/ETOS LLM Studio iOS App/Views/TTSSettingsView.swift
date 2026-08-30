import SwiftUI
import ETOSCore

struct TTSSettingsView: View {
    @ObservedObject private var settingsStore = TTSSettingsStore.shared
    @ObservedObject private var serviceStore = TTSServiceStore.shared
    @ObservedObject private var appConfig = AppConfigStore.shared
    @ObservedObject private var ttsManager = TTSManager.shared
    @State private var isAddingService = false

    var body: some View {
        Form {
            playbackSection
            cloudServicesSection

            behaviorSection
            watchCompatibilitySection
            playbackParametersSection
        }
        .navigationTitle(NSLocalizedString("TTS 设置", comment: ""))
        .sheet(isPresented: $isAddingService) {
            NavigationStack {
                TTSServiceEditorView(
                    service: .defaultConfiguration(for: .openAICompatible),
                    selectsAfterSaving: true
                )
            }
        }
        .toolbar {
            if serviceStore.services.count > 1 {
                EditButton()
            }
        }
    }

    private var playbackSection: some View {
        Section {
            Picker(NSLocalizedString("模式", comment: ""), selection: $settingsStore.playbackMode) {
                Text(NSLocalizedString("系统", comment: "")).tag(TTSPlaybackMode.system)
                Text(NSLocalizedString("云端", comment: "")).tag(TTSPlaybackMode.cloud)
                Text(NSLocalizedString("自动", comment: "")).tag(TTSPlaybackMode.auto)
            }
            .pickerStyle(.segmented)
            .tint(.blue)

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
                        TTSServiceEditorView(service: service, selectsAfterSaving: false)
                    } label: {
                        TTSServiceRow(
                            service: service,
                            isSelected: service.id == serviceStore.selectedServiceID
                        )
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
            Text(NSLocalizedString("每个服务分别保存协议和语音参数；可进入编辑页试听，使用编辑按钮调整顺序。", comment: "TTS 服务列表说明"))
        }
    }

    private var behaviorSection: some View {
        Section {
            Toggle(
                NSLocalizedString("后台继续朗读", comment: "TTS 后台继续播放开关"),
                isOn: $appConfig.continueTTSPlaybackInBackground
            )
            Toggle(
                NSLocalizedString("缓存网络音频用于重播", comment: "TTS network audio replay cache"),
                isOn: $appConfig.ttsCacheNetworkAudioForReplay
            )
            Toggle(NSLocalizedString("回复完成后自动朗读", comment: ""), isOn: $settingsStore.autoPlayAfterAssistantResponse)
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
                Text(NSLocalizedString("网络音频缓存只保留在内存中，用于重播时避免再次请求；应用退出后会自动清除。", comment: "TTS behavior explanation"))
            }
        }
    }

    private var watchCompatibilitySection: some View {
        Section {
            Toggle(NSLocalizedString("watchOS 使用轻量预处理（推荐）", comment: ""), isOn: $settingsStore.watchUseLightweightPreprocess)

            Stepper(value: $settingsStore.watchSpeechMaxCharacters, in: 500...6_000, step: 250) {
                HStack {
                    Text(NSLocalizedString("watchOS 最大朗读字符", comment: ""))
                    Spacer()
                    Text("\(settingsStore.watchSpeechMaxCharacters)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        } header: {
            Text(NSLocalizedString("watchOS 兼容与性能", comment: ""))
        } footer: {
            Text(NSLocalizedString("手表端朗读卡顿时，建议保持轻量预处理开启，并适当降低最大朗读字符。", comment: ""))
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
            HStack {
                Text(title)
                Spacer()
                Text(String(format: "%.2f", value.wrappedValue))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
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
}
private struct TTSServiceRow: View {
    let service: TTSServiceConfiguration
    let isSelected: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(service.name)
                Text(serviceSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.blue)
            }
        }
    }

    private var serviceSummary: String {
        let detail = service.trimmedModelID.isEmpty ? service.trimmedVoice : service.trimmedModelID
        return "\(service.providerKind.localizedName) · \(detail)"
    }
}

private struct TTSServiceEditorView: View {
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
        Form {
            Section(NSLocalizedString("服务", comment: "TTS 服务编辑分组")) {
                Picker(NSLocalizedString("接口类型", comment: ""), selection: providerKindBinding) {
                    ForEach(TTSProviderKind.allCases, id: \.self) { kind in
                        Text(kind.localizedName).tag(kind)
                    }
                }

                TextField(NSLocalizedString("名称", comment: ""), text: $draft.name)
            }

            Section {
                TextField(baseURLFieldLabel, text: $draft.baseURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                SecureField(NSLocalizedString("API Key", comment: ""), text: $draft.apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                if fields.contains(.modelID) {
                    TextField(NSLocalizedString("模型 ID", comment: ""), text: $draft.modelID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            } header: {
                Text(NSLocalizedString("接口", comment: "TTS 接口配置分组"))
            } footer: {
                Text(interfaceFooterText)
            }

            Section {
                if !voiceOptions.isEmpty {
                    Picker(NSLocalizedString("推荐 Voice", comment: ""), selection: voicePresetBinding) {
                        ForEach(voiceOptions, id: \.self) { voice in
                            Text(voice).tag(voice)
                        }
                        Text(NSLocalizedString("自定义", comment: "")).tag(Self.customPresetTag)
                    }
                }

                TextField(voiceFieldLabel, text: $draft.voice)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

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

                    TextField(NSLocalizedString("语言", comment: ""), text: $draft.languageType)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
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
            } header: {
                Text(NSLocalizedString("语音", comment: "TTS 语音参数分组"))
            } footer: {
                Text(NSLocalizedString("推荐项用于快速填写；Voice 仍可直接输入服务支持的自定义值。", comment: "TTS Voice 说明"))
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
        .navigationBarTitleDisplayMode(.inline)
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

    @ViewBuilder
    private var advancedParametersSection: some View {
        Section {
            if fields.contains(.workspace) {
                TextField(NSLocalizedString("Workspace ID", comment: "TTS workspace identifier"), text: advancedBinding(\.workspaceID))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            if fields.contains(.region) {
                TextField(NSLocalizedString("区域", comment: "TTS service region"), text: advancedBinding(\.region))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            if fields.contains(.instruction) {
                TextField(
                    NSLocalizedString("语音指令", comment: "TTS provider instruction"),
                    text: advancedBinding(\.instruction),
                    axis: .vertical
                )
                .lineLimit(2...5)
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
                    LabeledContent(NSLocalizedString("合成音调", comment: "TTS synthesis pitch")) {
                        Text("\(draft.advancedSettings.pitch)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
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
                TextField(NSLocalizedString("语言增强", comment: "MiniMax language boost"), text: advancedBinding(\.languageBoost))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            if fields.contains(.pronunciationDictionary) {
                TextField(
                    NSLocalizedString("发音词典（每行一项）", comment: "MiniMax pronunciation dictionary"),
                    text: pronunciationDictionaryBinding,
                    axis: .vertical
                )
                .lineLimit(2...6)
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
        } header: {
            Text(NSLocalizedString("高级参数", comment: "TTS advanced parameters section"))
        } footer: {
            Text(NSLocalizedString("这些参数由当前语音服务定义；不确定时保持推荐值即可。", comment: "TTS advanced parameters explanation"))
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
            "Base URL 填写版本根路径，应用会按接口类型补全语音合成端点。",
            comment: "TTS Base URL 说明"
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
            LabeledContent(title) {
                Text(String(format: "%.2f", value.wrappedValue))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
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
