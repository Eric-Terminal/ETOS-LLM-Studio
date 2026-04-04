// ============================================================================
// SpecializedModelSelectorView.swift
// ============================================================================
// SpecializedModelSelectorView 界面 (watchOS)
// - 负责该功能在 watchOS 端的交互与展示
// - 适配手表端交互与布局约束
// ============================================================================

import SwiftUI
import Shared

struct SpecializedModelSelectorView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @AppStorage("imageGenerationModelIdentifier") private var imageGenerationModelIdentifier: String = ""

    private var speechModelBinding: Binding<RunnableModel?> {
        Binding(
            get: { viewModel.selectedSpeechModel },
            set: { viewModel.setSelectedSpeechModel($0) }
        )
    }

    private var embeddingModelBinding: Binding<RunnableModel?> {
        Binding(
            get: { viewModel.selectedEmbeddingModel },
            set: { viewModel.setSelectedEmbeddingModel($0) }
        )
    }

    private var ttsModelBinding: Binding<RunnableModel?> {
        Binding(
            get: { viewModel.selectedTTSModel },
            set: { viewModel.setSelectedTTSModel($0) }
        )
    }

    private var titleModelBinding: Binding<RunnableModel?> {
        Binding(
            get: { viewModel.selectedTitleGenerationModel },
            set: { viewModel.setSelectedTitleGenerationModel($0) }
        )
    }

    private var dailyPulseModelBinding: Binding<RunnableModel?> {
        Binding(
            get: { viewModel.selectedDailyPulseModel },
            set: { viewModel.setSelectedDailyPulseModel($0) }
        )
    }

    private var imageGenerationModelBinding: Binding<RunnableModel?> {
        Binding(
            get: { viewModel.imageGenerationModel(with: imageGenerationModelIdentifier) },
            set: { imageGenerationModelIdentifier = $0?.id ?? "" }
        )
    }

    var body: some View {
        List {
            modelSelectionSection(
                title: "语音模型",
                options: viewModel.speechModels,
                selection: speechModelBinding,
                footer: "用于语音转文字，也可在模型高级设置中修改。"
            )

            modelSelectionSection(
                title: "TTS 模型",
                options: viewModel.ttsModels,
                selection: ttsModelBinding,
                footer: "用于文字转语音，也可在 TTS 设置中修改。"
            )

            modelSelectionSection(
                title: "嵌入模型",
                options: viewModel.embeddingModelOptions,
                selection: embeddingModelBinding,
                footer: "用于记忆嵌入，也可在记忆库管理中修改。"
            )

            modelSelectionSection(
                title: "标题生成模型",
                options: viewModel.titleGenerationModelOptions,
                selection: titleModelBinding,
                footer: "留空时跟随当前对话模型。"
            )

            modelSelectionSection(
                title: "每日脉冲模型",
                options: viewModel.dailyPulseModelOptions,
                selection: dailyPulseModelBinding,
                footer: "用于每日脉冲生成；留空时跟随当前对话模型。"
            )

            modelSelectionSection(
                title: "生图模型",
                options: viewModel.imageGenerationModelOptions,
                selection: imageGenerationModelBinding,
                allowEmptySelection: false,
                footer: "用于图片生成，也可在图片生成功能中修改。"
            )
        }
        .navigationTitle("专用模型")
        .onAppear(perform: syncImageGenerationSelection)
        .onChange(of: viewModel.activatedModels.map(\.id)) { _, _ in
            syncImageGenerationSelection()
        }
    }

    @ViewBuilder
    private func modelSelectionSection(
        title: String,
        options: [RunnableModel],
        selection: Binding<RunnableModel?>,
        allowEmptySelection: Bool = true,
        footer: String
    ) -> some View {
        Section {
            if options.isEmpty {
                Text("暂无可用模型，请先启用。")
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                NavigationLink {
                    WatchRunnableModelSelectionListView(
                        title: title,
                        models: options,
                        selectedModel: selection,
                        allowEmptySelection: allowEmptySelection
                    )
                } label: {
                    HStack {
                        Text(title)
                        Spacer()
                        MarqueeText(
                            content: selectedModelLabel(selection.wrappedValue, in: options),
                            uiFont: .preferredFont(forTextStyle: .footnote)
                        )
                        .foregroundStyle(.secondary)
                        .allowsHitTesting(false)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            }
        } footer: {
            Text(footer)
                .etFont(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func selectedModelLabel(_ selection: RunnableModel?, in options: [RunnableModel]) -> String {
        guard let selection,
              options.contains(where: { $0.id == selection.id }) else {
            return "未选择"
        }
        return "\(selection.model.displayName) | \(selection.provider.name)"
    }

    private func syncImageGenerationSelection() {
        guard !imageGenerationModelIdentifier.isEmpty else { return }
        if viewModel.imageGenerationModel(with: imageGenerationModelIdentifier) == nil {
            imageGenerationModelIdentifier = ""
        }
    }
}

private struct WatchRunnableModelSelectionListView: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let models: [RunnableModel]
    @Binding var selectedModel: RunnableModel?
    let allowEmptySelection: Bool

    var body: some View {
        List {
            if allowEmptySelection {
                Button {
                    select(nil)
                } label: {
                    selectionRow(title: "未选择", isSelected: selectedModel == nil)
                }
            }

            ForEach(models) { runnable in
                Button {
                    select(runnable)
                } label: {
                    selectionRow(
                        title: runnable.model.displayName,
                        subtitle: "\(runnable.provider.name) · \(runnable.model.modelName)",
                        isSelected: selectedModel?.id == runnable.id
                    )
                }
            }
        }
        .navigationTitle(title)
    }

    private func select(_ model: RunnableModel?) {
        selectedModel = model
        dismiss()
    }

    @ViewBuilder
    private func selectionRow(title: String, subtitle: String? = nil, isSelected: Bool) -> some View {
        MarqueeTitleSubtitleSelectionRow(
            title: title,
            subtitle: subtitle,
            isSelected: isSelected,
            subtitleUIFont: .monospacedSystemFont(
                ofSize: UIFont.preferredFont(forTextStyle: .caption2).pointSize,
                weight: .regular
            )
        )
    }
}
