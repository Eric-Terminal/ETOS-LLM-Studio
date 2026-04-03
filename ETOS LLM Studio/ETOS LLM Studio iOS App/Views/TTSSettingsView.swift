import SwiftUI
import Shared

struct TTSSettingsView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @ObservedObject private var settingsStore = TTSSettingsStore.shared
    @State private var showCustomCloudParameters: Bool = false

    private static let customPickerTag = "__custom__"

    var body: some View {
        Form {
            Section("播放模式") {
                Picker("模式", selection: $settingsStore.playbackMode) {
                    Text("系统").tag(TTSPlaybackMode.system)
                    Text("云端").tag(TTSPlaybackMode.cloud)
                    Text("自动").tag(TTSPlaybackMode.auto)
                }
                .pickerStyle(.segmented)
                .tint(.blue)

                Text("自动模式会优先系统 TTS，失败后自动回退云端。")
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("专用模型") {
                if viewModel.ttsModels.isEmpty {
                    Text("暂无可用模型，请先在“提供商与模型管理”中给模型开启“文字转语音”能力。")
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
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
                            Text("TTS 模型")
                            Spacer()
                            Text(selectedModelText)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }

            Section("云端提供商") {
                Picker("提供商类型", selection: $settingsStore.providerKind) {
                    Text("OpenAI 兼容").tag(TTSProviderKind.openAICompatible)
                    Text("Gemini").tag(TTSProviderKind.gemini)
                    Text("Qwen").tag(TTSProviderKind.qwen)
                    Text("MiniMax").tag(TTSProviderKind.miniMax)
                    Text("Groq").tag(TTSProviderKind.groq)
                }

                Button {
                    applyRecommendedCloudPreset()
                } label: {
                    Label("套用当前提供商推荐参数", systemImage: "wand.and.stars")
                }
            }

            Section {
                Picker("Voice", selection: voicePresetBinding) {
                    ForEach(providerVoiceOptions, id: \.self) { option in
                        Text(option).tag(option)
                    }
                    Text(customOptionLabel(for: settingsStore.voice)).tag(Self.customPickerTag)
                }

                if supportsResponseFormat {
                    Picker("格式", selection: responseFormatPresetBinding) {
                        ForEach(providerResponseFormatOptions, id: \.self) { option in
                            Text(option).tag(option)
                        }
                        Text(customOptionLabel(for: settingsStore.responseFormat)).tag(Self.customPickerTag)
                    }
                }

                if supportsLanguageType {
                    Picker("语言", selection: languageTypePresetBinding) {
                        ForEach(providerLanguageTypeOptions, id: \.self) { option in
                            Text(option).tag(option)
                        }
                        Text(customOptionLabel(for: settingsStore.languageType)).tag(Self.customPickerTag)
                    }
                }

                if supportsMiniMaxEmotion {
                    Picker("情感", selection: miniMaxEmotionPresetBinding) {
                        ForEach(providerMiniMaxEmotionOptions, id: \.self) { option in
                            Text(option).tag(option)
                        }
                        Text(customOptionLabel(for: settingsStore.miniMaxEmotion)).tag(Self.customPickerTag)
                    }
                }
            } header: {
                Text("云端快捷预设")
            } footer: {
                Text("预设适合快速上手；若需手动输入，可在下方高级参数中覆盖。")
            }

            Section("云端高级参数") {
                DisclosureGroup("手动覆盖参数（可选）", isExpanded: $showCustomCloudParameters) {
                    TextField("Voice", text: $settingsStore.voice)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    if supportsResponseFormat {
                        TextField("响应格式（mp3/wav）", text: $settingsStore.responseFormat)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                    if supportsLanguageType {
                        TextField("语言类型（Qwen）", text: $settingsStore.languageType)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                    if supportsMiniMaxEmotion {
                        TextField("情感（MiniMax）", text: $settingsStore.miniMaxEmotion)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }
            }

            Section("朗读行为") {
                Toggle("回复完成后自动朗读", isOn: $settingsStore.autoPlayAfterAssistantResponse)
                Toggle("仅朗读引号内容", isOn: $settingsStore.onlyReadQuotedContent)
            }

            Section {
                Toggle("watchOS 使用轻量预处理（推荐）", isOn: $settingsStore.watchUseLightweightPreprocess)

                Stepper(value: $settingsStore.watchSpeechMaxCharacters, in: 500...6_000, step: 250) {
                    HStack {
                        Text("watchOS 最大朗读字符")
                        Spacer()
                        Text("\(settingsStore.watchSpeechMaxCharacters)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            } header: {
                Text("watchOS 兼容与性能")
            } footer: {
                Text("手表端朗读卡顿时，建议保持轻量预处理开启，并适当降低最大朗读字符。")
            }

            Section("播放参数") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("系统语速")
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
                        Text("系统音调")
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

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("默认倍速")
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
        .navigationTitle("TTS 设置")
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
            return "自定义（当前为空）"
        }
        return "自定义（当前：\(trimmed)）"
    }

    private var selectedModelText: String {
        guard let model = viewModel.selectedTTSModel else { return "未选择" }
        return "\(model.model.displayName) | \(model.provider.name)"
    }
}

private struct TTSModelSelectionView: View {
    @Environment(\.dismiss) private var dismiss

    let models: [RunnableModel]
    @Binding var selectedModel: RunnableModel?

    var body: some View {
        List {
            Button {
                selectedModel = nil
                dismiss()
            } label: {
                MarqueeSelectionRow(title: "未选择", isSelected: selectedModel == nil)
            }

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
        .navigationTitle("TTS 模型")
    }
}
