import SwiftUI
import Shared

struct TTSSettingsView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @ObservedObject private var settingsStore = TTSSettingsStore.shared

    var body: some View {
        Form {
            Section("播放模式") {
                Picker("模式", selection: $settingsStore.playbackMode) {
                    Text("系统").tag(TTSPlaybackMode.system)
                    Text("云端").tag(TTSPlaybackMode.cloud)
                    Text("自动").tag(TTSPlaybackMode.auto)
                }
                .pickerStyle(.segmented)

                Text("自动模式会优先系统 TTS，失败后自动回退云端。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("专用模型") {
                if viewModel.ttsModels.isEmpty {
                    Text("暂无可用模型，请先在“提供商与模型管理”中给模型开启“文字转语音”能力。")
                        .font(.footnote)
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

                TextField("Voice", text: $settingsStore.voice)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                TextField("响应格式（mp3/wav）", text: $settingsStore.responseFormat)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                TextField("语言类型（Qwen）", text: $settingsStore.languageType)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                TextField("情感（MiniMax）", text: $settingsStore.miniMaxEmotion)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            Section("朗读行为") {
                Toggle("回复完成后自动朗读", isOn: $settingsStore.autoPlayAfterAssistantResponse)
                Toggle("仅朗读引号内容", isOn: $settingsStore.onlyReadQuotedContent)
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
