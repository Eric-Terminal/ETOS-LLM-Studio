import SwiftUI
import Foundation
import Shared

struct TTSSettingsView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @ObservedObject private var settingsStore = TTSSettingsStore.shared
    @State private var showCustomCloudParameters: Bool = false

    private static let customPickerTag = "__custom__"

    private var numberFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }

    var body: some View {
        List {
            Section("播放模式") {
                Picker("模式", selection: $settingsStore.playbackMode) {
                    Text("系统").tag(TTSPlaybackMode.system)
                    Text("云端").tag(TTSPlaybackMode.cloud)
                    Text("自动").tag(TTSPlaybackMode.auto)
                }

                Text("自动模式会优先使用本地系统 TTS，失败时会自动降级到云端。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("专用模型") {
                if viewModel.ttsModels.isEmpty {
                    Text("暂无可用 TTS 模型")
                        .foregroundStyle(.secondary)
                } else {
                    NavigationLink {
                        WatchTTSModelSelectionListView(
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

            Section("云端设置") {
                Picker("提供商", selection: $settingsStore.providerKind) {
                    Text("OpenAI").tag(TTSProviderKind.openAICompatible)
                    Text("Gemini").tag(TTSProviderKind.gemini)
                    Text("Qwen").tag(TTSProviderKind.qwen)
                    Text("MiniMax").tag(TTSProviderKind.miniMax)
                    Text("Groq").tag(TTSProviderKind.groq)
                }

                Button {
                    applyRecommendedCloudPreset()
                } label: {
                    Label("套用推荐参数", systemImage: "wand.and.stars")
                }
            }

            Section("云端快捷预设") {
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
            }

            Section("云端高级参数") {
                Toggle("手动覆盖参数", isOn: $showCustomCloudParameters)

                if showCustomCloudParameters {
                    TextField("Voice", text: $settingsStore.voice.watchKeyboardNewlineBinding())
                    if supportsResponseFormat {
                        TextField("格式", text: $settingsStore.responseFormat.watchKeyboardNewlineBinding())
                    }
                    if supportsLanguageType {
                        TextField("语言", text: $settingsStore.languageType.watchKeyboardNewlineBinding())
                    }
                    if supportsMiniMaxEmotion {
                        TextField("情感", text: $settingsStore.miniMaxEmotion.watchKeyboardNewlineBinding())
                    }
                }
            }

            Section("朗读行为") {
                Toggle("自动朗读回复", isOn: $settingsStore.autoPlayAfterAssistantResponse)
                Toggle("仅朗读引号", isOn: $settingsStore.onlyReadQuotedContent)
            }

            Section("watchOS 兼容") {
                Toggle("轻量预处理（推荐）", isOn: $settingsStore.watchUseLightweightPreprocess)

                HStack {
                    Text("最大字符")
                    Spacer()
                    TextField("数量", value: $settingsStore.watchSpeechMaxCharacters, formatter: numberFormatter)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 64)
                }

                Text("如果点朗读会卡住，建议保持轻量预处理开启，并下调最大字符。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("播放参数") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("语速 \(String(format: "%.2f", settingsStore.speechRate))")
                    Slider(value: Binding(
                        get: { Double(settingsStore.speechRate) },
                        set: { settingsStore.speechRate = Float($0) }
                    ), in: 0.1...3.0)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("音调 \(String(format: "%.2f", settingsStore.pitch))")
                    Slider(value: Binding(
                        get: { Double(settingsStore.pitch) },
                        set: { settingsStore.pitch = Float($0) }
                    ), in: 0.1...2.0)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("倍速 \(String(format: "%.2f", settingsStore.playbackSpeed))")
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
        return model.model.displayName
    }
}

private struct WatchTTSModelSelectionListView: View {
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
