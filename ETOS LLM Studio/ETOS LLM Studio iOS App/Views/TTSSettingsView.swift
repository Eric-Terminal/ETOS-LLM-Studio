import SwiftUI
import ETOSCore

struct TTSSettingsView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @ObservedObject private var settingsStore = TTSSettingsStore.shared
    @ObservedObject private var appConfig = AppConfigStore.shared
    @ObservedObject private var ttsManager = TTSManager.shared
    @State private var showCustomCloudParameters: Bool = false

    private static let customPickerTag = "__custom__"

    var body: some View {
        Form {
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
                Text(NSLocalizedString("系统模式使用设备内置语音；云端模式使用下方模型；自动模式优先系统，失败后回退云端。", comment: "TTS playback mode explanation"))
            }

            if usesCloudPlayback {
                Section {
                    if viewModel.ttsModels.isEmpty {
                        Text(NSLocalizedString("暂无可用模型，请先在“提供商与模型管理”中给模型开启“文字转语音”能力。", comment: ""))
                            .etFont(.footnote)
                            .foregroundStyle(.secondary)

                        NavigationLink {
                            ProviderListView()
                        } label: {
                            Label(NSLocalizedString("提供商与模型管理", comment: ""), systemImage: "shippingbox")
                        }
                    } else {
                        NavigationLink {
                            TTSModelSelectionView(
                                models: viewModel.ttsModels,
                                selectedModel: Binding(
                                    get: { viewModel.selectedTTSModel },
                                    set: { viewModel.setSelectedTTSModel($0) }
                                )
                            )
                        } label: {
                            HStack {
                                Text(NSLocalizedString("TTS 模型", comment: ""))
                                Spacer()
                                Text(selectedModelText)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                } header: {
                    Text(NSLocalizedString("语音模型", comment: ""))
                }

                Section(NSLocalizedString("云端设置", comment: "")) {
                    Picker(NSLocalizedString("TTS 接口类型", comment: ""), selection: $settingsStore.providerKind) {
                        Text(NSLocalizedString("OpenAI 兼容", comment: "")).tag(TTSProviderKind.openAICompatible)
                        Text(NSLocalizedString("Gemini", comment: "TTS provider")).tag(TTSProviderKind.gemini)
                        Text(NSLocalizedString("Qwen", comment: "TTS provider")).tag(TTSProviderKind.qwen)
                        Text(NSLocalizedString("MiniMax", comment: "TTS provider")).tag(TTSProviderKind.miniMax)
                        Text(NSLocalizedString("Groq", comment: "TTS provider")).tag(TTSProviderKind.groq)
                    }

                    Button {
                        applyRecommendedCloudPreset()
                    } label: {
                        Label(NSLocalizedString("套用当前提供商推荐参数", comment: ""), systemImage: "wand.and.stars")
                    }
                }

                Section {
                    Picker(NSLocalizedString("Voice", comment: "TTS voice picker"), selection: voicePresetBinding) {
                        ForEach(providerVoiceOptions, id: \.self) { option in
                            Text(option).tag(option)
                        }
                        Text(customOptionLabel(for: settingsStore.voice)).tag(Self.customPickerTag)
                    }

                    if supportsResponseFormat {
                        Picker(NSLocalizedString("格式", comment: ""), selection: responseFormatPresetBinding) {
                            ForEach(providerResponseFormatOptions, id: \.self) { option in
                                Text(option).tag(option)
                            }
                            Text(customOptionLabel(for: settingsStore.responseFormat)).tag(Self.customPickerTag)
                        }
                    }

                    if supportsLanguageType {
                        Picker(NSLocalizedString("语言", comment: ""), selection: languageTypePresetBinding) {
                            ForEach(providerLanguageTypeOptions, id: \.self) { option in
                                Text(option).tag(option)
                            }
                            Text(customOptionLabel(for: settingsStore.languageType)).tag(Self.customPickerTag)
                        }
                    }

                    if supportsMiniMaxEmotion {
                        Picker(NSLocalizedString("情感", comment: ""), selection: miniMaxEmotionPresetBinding) {
                            ForEach(providerMiniMaxEmotionOptions, id: \.self) { option in
                                Text(option).tag(option)
                            }
                            Text(customOptionLabel(for: settingsStore.miniMaxEmotion)).tag(Self.customPickerTag)
                        }
                    }
                } header: {
                    Text(NSLocalizedString("云端快捷预设", comment: ""))
                } footer: {
                    Text(NSLocalizedString("预设适合快速上手；若需手动输入，可在下方高级参数中覆盖。", comment: ""))
                }

                Section(NSLocalizedString("云端高级参数", comment: "")) {
                    DisclosureGroup(NSLocalizedString("手动覆盖参数（可选）", comment: ""), isExpanded: $showCustomCloudParameters) {
                        TextField(NSLocalizedString("Voice", comment: "TTS voice text field"), text: $settingsStore.voice)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()

                        if supportsResponseFormat {
                            TextField(NSLocalizedString("响应格式（mp3/wav）", comment: ""), text: $settingsStore.responseFormat)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }

                        if supportsLanguageType {
                            TextField(NSLocalizedString("语言类型（Qwen）", comment: ""), text: $settingsStore.languageType)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }

                        if supportsMiniMaxEmotion {
                            TextField(NSLocalizedString("情感（MiniMax）", comment: ""), text: $settingsStore.miniMaxEmotion)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                    }
                }
            }

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
                Text(NSLocalizedString(
                    "开启后，正在播放的朗读会在切换到其他 App 后继续，全部内容读完后自动停止；此选项不会自动开始朗读。",
                    comment: "TTS 后台继续播放说明"
                ))
            }

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

            Section(NSLocalizedString("播放参数", comment: "")) {
                if usesSystemPlayback {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(NSLocalizedString("系统语速", comment: ""))
                            Spacer()
                            Text(String(format: "%.2f", settingsStore.speechRate))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: Binding(
                            get: { Double(settingsStore.speechRate) },
                            set: { settingsStore.speechRate = Float($0) }
                        ), in: 0.1...3.0)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(NSLocalizedString("系统音调", comment: ""))
                            Spacer()
                            Text(String(format: "%.2f", settingsStore.pitch))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: Binding(
                            get: { Double(settingsStore.pitch) },
                            set: { settingsStore.pitch = Float($0) }
                        ), in: 0.1...2.0)
                    }
                }

                if usesCloudPlayback {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(NSLocalizedString("默认倍速", comment: ""))
                            Spacer()
                            Text(String(format: "%.2f", settingsStore.playbackSpeed))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: Binding(
                            get: { Double(settingsStore.playbackSpeed) },
                            set: { settingsStore.playbackSpeed = Float($0) }
                        ), in: 0.5...2.0)
                    }
                }
            }
        }
        .navigationTitle(NSLocalizedString("TTS 设置", comment: ""))
    }

    private var usesSystemPlayback: Bool {
        settingsStore.playbackMode != .cloud
    }

    private var usesCloudPlayback: Bool {
        settingsStore.playbackMode != .system
    }

    private var canPreview: Bool {
        settingsStore.playbackMode != .cloud || !viewModel.ttsModels.isEmpty
    }

    private func togglePreview() {
        if ttsManager.isSpeaking {
            ttsManager.stop()
            return
        }

        ttsManager.updateSelectedModel(viewModel.selectedTTSModel ?? viewModel.ttsModels.first)
        ttsManager.speak(NSLocalizedString("这是 TTS 试听。", comment: "TTS preview sample"), flush: true)
    }

    private var providerVoiceOptions: [String] {
        TTSProviderPresetCatalog.voiceOptions(for: settingsStore.providerKind)
    }

    private var providerResponseFormatOptions: [String] {
        TTSProviderPresetCatalog.responseFormatOptions(for: settingsStore.providerKind)
    }

    private var providerLanguageTypeOptions: [String] {
        TTSProviderPresetCatalog.languageTypeOptions(for: settingsStore.providerKind)
    }

    private var providerMiniMaxEmotionOptions: [String] {
        TTSProviderPresetCatalog.miniMaxEmotionOptions(for: settingsStore.providerKind)
    }

    private var supportsResponseFormat: Bool {
        !providerResponseFormatOptions.isEmpty
    }

    private var supportsLanguageType: Bool {
        !providerLanguageTypeOptions.isEmpty
    }

    private var supportsMiniMaxEmotion: Bool {
        !providerMiniMaxEmotionOptions.isEmpty
    }

    private var voicePresetBinding: Binding<String> {
        Binding(
            get: {
                providerVoiceOptions.contains(settingsStore.voice) ? settingsStore.voice : Self.customPickerTag
            },
            set: { newValue in
                guard newValue != Self.customPickerTag else { return }
                settingsStore.voice = newValue
            }
        )
    }

    private var responseFormatPresetBinding: Binding<String> {
        Binding(
            get: {
                providerResponseFormatOptions.contains(settingsStore.responseFormat) ? settingsStore.responseFormat : Self.customPickerTag
            },
            set: { newValue in
                guard newValue != Self.customPickerTag else { return }
                settingsStore.responseFormat = newValue
            }
        )
    }

    private var languageTypePresetBinding: Binding<String> {
        Binding(
            get: {
                providerLanguageTypeOptions.contains(settingsStore.languageType) ? settingsStore.languageType : Self.customPickerTag
            },
            set: { newValue in
                guard newValue != Self.customPickerTag else { return }
                settingsStore.languageType = newValue
            }
        )
    }

    private var miniMaxEmotionPresetBinding: Binding<String> {
        Binding(
            get: {
                providerMiniMaxEmotionOptions.contains(settingsStore.miniMaxEmotion) ? settingsStore.miniMaxEmotion : Self.customPickerTag
            },
            set: { newValue in
                guard newValue != Self.customPickerTag else { return }
                settingsStore.miniMaxEmotion = newValue
            }
        )
    }

    private func applyRecommendedCloudPreset() {
        let preset = TTSProviderPresetCatalog.recommendedPreset(for: settingsStore.providerKind)
        settingsStore.voice = preset.voice
        settingsStore.responseFormat = preset.responseFormat
        settingsStore.languageType = preset.languageType
        settingsStore.miniMaxEmotion = preset.miniMaxEmotion
    }

    private func customOptionLabel(for value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return NSLocalizedString("自定义（当前为空）", comment: "")
        }
        return String(format: NSLocalizedString("自定义（当前：%@）", comment: ""), trimmed)
    }

    private var selectedModelText: String {
        guard let model = viewModel.selectedTTSModel ?? viewModel.ttsModels.first else {
            return NSLocalizedString("未选择", comment: "")
        }
        return "\(model.model.displayName) | \(model.provider.name)"
    }
}

private struct TTSModelSelectionView: View {
    @Environment(\.dismiss) private var dismiss

    let models: [RunnableModel]
    @Binding var selectedModel: RunnableModel?

    var body: some View {
        List {
            ForEach(models) { runnable in
                Button {
                    selectedModel = runnable
                    dismiss()
                } label: {
                    MarqueeTitleSubtitleSelectionRow(
                        title: runnable.model.displayName,
                        subtitle: "\(runnable.provider.name) · \(runnable.model.modelName)",
                        isSelected: selectedModel?.id == runnable.id,
                        subtitleUIFont: .monospacedSystemFont(
                            ofSize: UIFont.preferredFont(forTextStyle: .caption2).pointSize,
                            weight: .regular
                        )
                    )
                }
            }
        }
        .navigationTitle(NSLocalizedString("TTS 模型", comment: ""))
    }
}
