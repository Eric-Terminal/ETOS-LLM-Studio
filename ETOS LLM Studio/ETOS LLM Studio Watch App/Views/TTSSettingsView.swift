import SwiftUI
import Shared

struct TTSSettingsView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @ObservedObject private var settingsStore = TTSSettingsStore.shared

    var body: some View {
        List {
            Section("播放模式") {
                Picker("模式", selection: $settingsStore.playbackMode) {
                    Text("系统").tag(TTSPlaybackMode.system)
                    Text("云端").tag(TTSPlaybackMode.cloud)
                    Text("自动").tag(TTSPlaybackMode.auto)
                }

                Text("watchOS 上系统 TTS 受限时会自动降级云端。")
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

                TextField("Voice", text: $settingsStore.voice.watchKeyboardNewlineBinding())
                TextField("格式", text: $settingsStore.responseFormat.watchKeyboardNewlineBinding())
                TextField("语言", text: $settingsStore.languageType.watchKeyboardNewlineBinding())
                TextField("情感", text: $settingsStore.miniMaxEmotion.watchKeyboardNewlineBinding())
            }

            Section("朗读行为") {
                Toggle("自动朗读回复", isOn: $settingsStore.autoPlayAfterAssistantResponse)
                Toggle("仅朗读引号", isOn: $settingsStore.onlyReadQuotedContent)
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
