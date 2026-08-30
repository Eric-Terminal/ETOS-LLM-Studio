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

            if usesCloudPlayback {
                cloudServicesSection
            }

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
            }

            Button {
                isAddingService = true
            } label: {
                Label(NSLocalizedString("添加语音服务", comment: ""), systemImage: "plus")
            }
        } header: {
            Text(NSLocalizedString("云端语音服务", comment: ""))
        } footer: {
            Text(NSLocalizedString("每个服务分别保存接口类型、地址、密钥、模型和音色。向左轻扫服务可删除。", comment: "TTS 服务列表说明"))
        }
    }

    private var behaviorSection: some View {
        Section {
            Toggle(
                NSLocalizedString("后台继续朗读", comment: "TTS 后台继续播放开关"),
                isOn: $appConfig.continueTTSPlaybackInBackground
            )
            Toggle(NSLocalizedString("回复完成后自动朗读", comment: ""), isOn: $settingsStore.autoPlayAfterAssistantResponse)
            Toggle(NSLocalizedString("仅朗读引号内容", comment: ""), isOn: $settingsStore.onlyReadQuotedContent)
        } header: {
            Text(NSLocalizedString("朗读行为", comment: ""))
        } footer: {
            Text(NSLocalizedString("开启后，正在播放的朗读会在切换到其他 App 后继续，全部内容读完后自动停止；此选项不会自动开始朗读。", comment: "TTS 后台继续播放说明"))
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
                Text("\(service.providerKind.localizedName) · \(service.modelID)")
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
}

private struct TTSServiceEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var serviceStore = TTSServiceStore.shared
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
                TextField(NSLocalizedString("Base URL", comment: ""), text: $draft.baseURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                SecureField(NSLocalizedString("API Key", comment: ""), text: $draft.apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                TextField(NSLocalizedString("模型 ID", comment: ""), text: $draft.modelID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text(NSLocalizedString("接口", comment: "TTS 接口配置分组"))
            } footer: {
                Text(NSLocalizedString("Base URL 填写版本根路径，应用会按接口类型补全语音合成端点。", comment: "TTS Base URL 说明"))
            }

            Section {
                Picker(NSLocalizedString("推荐 Voice", comment: ""), selection: voicePresetBinding) {
                    ForEach(voiceOptions, id: \.self) { voice in
                        Text(voice).tag(voice)
                    }
                    Text(NSLocalizedString("自定义", comment: "")).tag(Self.customPresetTag)
                }

                TextField(NSLocalizedString("Voice", comment: "TTS voice text field"), text: $draft.voice)
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
                    Picker(NSLocalizedString("语言", comment: ""), selection: $draft.languageType) {
                        ForEach(languageTypeOptions, id: \.self) { language in
                            Text(language).tag(language)
                        }
                    }
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

    private static let customPresetTag = "__custom__"

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

    private func applyRecommendedParameters() {
        let preset = TTSProviderPresetCatalog.recommendedPreset(for: draft.providerKind)
        draft.voice = preset.voice
        draft.responseFormat = preset.responseFormat
        draft.languageType = preset.languageType
        draft.miniMaxEmotion = preset.miniMaxEmotion
    }
}
