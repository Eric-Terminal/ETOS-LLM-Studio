// ============================================================================
// SpecializedModelSelectorView.swift
// ============================================================================
// SpecializedModelSelectorView 界面 (watchOS)
// - 负责该功能在 watchOS 端的交互与展示
// - 适配手表端交互与布局约束
// ============================================================================

import SwiftUI
import ETOSCore

struct SpecializedModelSelectorView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @ObservedObject private var appConfig = AppConfigStore.shared

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

    private var reasoningSummaryModelBinding: Binding<RunnableModel?> {
        Binding(
            get: { viewModel.selectedReasoningSummaryModel },
            set: { viewModel.setSelectedReasoningSummaryModel($0) }
        )
    }

    private var ocrModelBinding: Binding<RunnableModel?> {
        Binding(
            get: { viewModel.selectedOCRModel },
            set: { viewModel.setSelectedOCRModel($0) }
        )
    }

    private var imageGenerationModelBinding: Binding<RunnableModel?> {
        Binding(
            get: { viewModel.imageGenerationModel(with: appConfig.imageGenerationModelIdentifier) },
            set: { setImageGenerationModelIdentifier($0?.id ?? "") }
        )
    }

    var body: some View {
        List {
            modelSelectionSection(
                title: NSLocalizedString("语音模型", comment: "Speech model specialized selector title"),
                options: viewModel.speechModels,
                selection: speechModelBinding,
                footer: NSLocalizedString("用于语音转文字，也可在偏好设置中修改。", comment: "Watch speech model specialized selector footer")
            )

            modelSelectionSection(
                title: NSLocalizedString("TTS 模型", comment: "TTS model specialized selector title"),
                options: viewModel.ttsModels,
                selection: ttsModelBinding,
                footer: NSLocalizedString("用于文字转语音，也可在 TTS 设置中修改。", comment: "Watch TTS model specialized selector footer")
            )

            modelSelectionSection(
                title: NSLocalizedString("嵌入模型", comment: "Embedding model specialized selector title"),
                options: viewModel.embeddingModelOptions,
                selection: embeddingModelBinding,
                footer: NSLocalizedString("用于记忆嵌入，也可在记忆库管理中修改。", comment: "Watch embedding model specialized selector footer")
            )

            modelSelectionSection(
                title: NSLocalizedString("标题生成模型", comment: "Title generation model specialized selector title"),
                options: viewModel.titleGenerationModelOptions,
                selection: titleModelBinding,
                footer: NSLocalizedString("留空时跟随当前对话模型。", comment: "Specialized selector empty follows chat model footer")
            )

            modelSelectionSection(
                title: NSLocalizedString("每日脉冲模型", comment: "Daily pulse model specialized selector title"),
                options: viewModel.dailyPulseModelOptions,
                selection: dailyPulseModelBinding,
                footer: NSLocalizedString("用于每日脉冲生成；留空时跟随当前对话模型。", comment: "Daily pulse model specialized selector footer")
            )

            modelSelectionSection(
                title: NSLocalizedString("思考摘要模型", comment: "Reasoning summary model specialized selector title"),
                options: viewModel.reasoningSummaryModelOptions,
                selection: reasoningSummaryModelBinding,
                footer: NSLocalizedString("用于为思考内容生成摘要；留空时跟随当前对话模型。", comment: "Reasoning summary model specialized selector footer")
            )

            modelSelectionSection(
                title: NSLocalizedString("OCR 模型", comment: "OCR model specialized selector title"),
                options: viewModel.ocrModelOptions,
                selection: ocrModelBinding,
                footer: NSLocalizedString("当前对话模型不支持图片输入时，用于先把图片识别为文字；手表端默认不选择。", comment: "Watch OCR model specialized selector footer")
            )

            modelSelectionSection(
                title: NSLocalizedString("生图模型", comment: "Image generation model specialized selector title"),
                options: viewModel.imageGenerationModelOptions,
                selection: imageGenerationModelBinding,
                allowEmptySelection: false,
                footer: NSLocalizedString("用于图片生成，也可在图片生成功能中修改。", comment: "Watch image generation model specialized selector footer")
            )
        }
        .navigationTitle(NSLocalizedString("专用模型", comment: ""))
        .onAppear(perform: syncImageGenerationSelection)
        .onChange(of: viewModel.activatedModelListVersion) { _, _ in
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
                Text(NSLocalizedString("暂无可用模型，请先启用。", comment: ""))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                NavigationLink {
                    WatchRunnableModelSelectionListView(
                        title: NSLocalizedString(title, comment: "专用模型选择标题"),
                        models: options,
                        selectedModel: selection,
                        allowEmptySelection: allowEmptySelection
                    )
                } label: {
                    HStack {
                        Text(NSLocalizedString(title, comment: "专用模型入口标题"))
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
            Text(NSLocalizedString(footer, comment: "专用模型说明"))
                .etFont(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func selectedModelLabel(_ selection: RunnableModel?, in options: [RunnableModel]) -> String {
        guard let selection,
              options.contains(where: { $0.id == selection.id }) else {
            return NSLocalizedString("未选择", comment: "")
        }
        return "\(selection.model.displayName) | \(selection.provider.name)"
    }

    private func syncImageGenerationSelection() {
        guard !appConfig.imageGenerationModelIdentifier.isEmpty else { return }
        if viewModel.imageGenerationModel(with: appConfig.imageGenerationModelIdentifier) == nil {
            setImageGenerationModelIdentifier("")
        }
    }

    private func setImageGenerationModelIdentifier(_ identifier: String) {
        AppConfigStore.persistSynchronously(.text(identifier), for: .imageGenerationModelIdentifier)
        appConfig.imageGenerationModelIdentifier = identifier
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
                    selectionRow(title: NSLocalizedString("未选择", comment: ""), isSelected: selectedModel == nil)
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
        .navigationTitle(NSLocalizedString(title, comment: "专用模型选择标题"))
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
