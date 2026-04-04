// ============================================================================
// SpecializedModelSelectorView.swift
// ============================================================================
// SpecializedModelSelectorView 界面 (iOS)
// - 负责该功能在 iOS 端的交互与展示
// - 遵循项目现有视图结构与状态流
// ============================================================================

import SwiftUI
import Shared

struct SpecializedModelSelectorView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @AppStorage("imageGenerationModelIdentifier") private var imageGenerationModelIdentifier: String = ""

    var body: some View {
        Form {
            modelPickerSection(
                title: "语音模型",
                options: viewModel.speechModels,
                selectionID: speechModelIdentifierBinding,
                footer: "用于语音转文字；也可在“高级模型设置”中修改。"
            )

            modelPickerSection(
                title: "TTS 模型",
                options: viewModel.ttsModels,
                selectionID: ttsModelIdentifierBinding,
                footer: "用于文字转语音；也可在“TTS 设置”中修改。"
            )

            modelPickerSection(
                title: "嵌入模型",
                options: viewModel.embeddingModelOptions,
                selectionID: embeddingModelIdentifierBinding,
                footer: "用于记忆向量化与检索；也可在“记忆库管理”中修改。"
            )

            modelPickerSection(
                title: "标题生成模型",
                options: viewModel.titleGenerationModelOptions,
                selectionID: titleModelIdentifierBinding,
                footer: "留空时跟随当前对话模型。"
            )

            modelPickerSection(
                title: "每日脉冲模型",
                options: viewModel.dailyPulseModelOptions,
                selectionID: dailyPulseModelIdentifierBinding,
                footer: "用于每日脉冲生成；留空时跟随当前对话模型。"
            )

            modelPickerSection(
                title: "生图模型",
                options: viewModel.imageGenerationModelOptions,
                selectionID: imageGenerationModelIdentifierBinding,
                allowEmptySelection: false,
                footer: "用于图片生成功能；也可在“图片生成”中修改。"
            )
        }
        .navigationTitle("专用模型选择器")
        .onAppear(perform: syncImageGenerationSelection)
        .onChange(of: viewModel.activatedModels.map(\.id)) { _, _ in
            syncImageGenerationSelection()
        }
    }

    private var speechModelIdentifierBinding: Binding<String> {
        Binding(
            get: { viewModel.selectedSpeechModel?.id ?? "" },
            set: { newIdentifier in
                guard !newIdentifier.isEmpty else {
                    viewModel.setSelectedSpeechModel(nil)
                    return
                }
                let selected = viewModel.speechModels.first(where: { $0.id == newIdentifier })
                viewModel.setSelectedSpeechModel(selected)
            }
        )
    }

    private var embeddingModelIdentifierBinding: Binding<String> {
        Binding(
            get: { viewModel.selectedEmbeddingModel?.id ?? "" },
            set: { newIdentifier in
                guard !newIdentifier.isEmpty else {
                    viewModel.setSelectedEmbeddingModel(nil)
                    return
                }
                let selected = viewModel.embeddingModelOptions.first(where: { $0.id == newIdentifier })
                viewModel.setSelectedEmbeddingModel(selected)
            }
        )
    }

    private var ttsModelIdentifierBinding: Binding<String> {
        Binding(
            get: { viewModel.selectedTTSModel?.id ?? "" },
            set: { newIdentifier in
                guard !newIdentifier.isEmpty else {
                    viewModel.setSelectedTTSModel(nil)
                    return
                }
                let selected = viewModel.ttsModels.first(where: { $0.id == newIdentifier })
                viewModel.setSelectedTTSModel(selected)
            }
        )
    }

    private var titleModelIdentifierBinding: Binding<String> {
        Binding(
            get: { viewModel.selectedTitleGenerationModel?.id ?? "" },
            set: { newIdentifier in
                guard !newIdentifier.isEmpty else {
                    viewModel.setSelectedTitleGenerationModel(nil)
                    return
                }
                let selected = viewModel.titleGenerationModelOptions.first(where: { $0.id == newIdentifier })
                viewModel.setSelectedTitleGenerationModel(selected)
            }
        )
    }

    private var dailyPulseModelIdentifierBinding: Binding<String> {
        Binding(
            get: { viewModel.selectedDailyPulseModel?.id ?? "" },
            set: { newIdentifier in
                guard !newIdentifier.isEmpty else {
                    viewModel.setSelectedDailyPulseModel(nil)
                    return
                }
                let selected = viewModel.dailyPulseModelOptions.first(where: { $0.id == newIdentifier })
                viewModel.setSelectedDailyPulseModel(selected)
            }
        )
    }

    private var imageGenerationModelIdentifierBinding: Binding<String> {
        Binding(
            get: { imageGenerationModelIdentifier },
            set: { imageGenerationModelIdentifier = $0 }
        )
    }

    @ViewBuilder
    private func modelPickerSection(
        title: String,
        options: [RunnableModel],
        selectionID: Binding<String>,
        allowEmptySelection: Bool = true,
        footer: String
    ) -> some View {
        Section {
            if options.isEmpty {
                Text("暂无可用模型，请先在提供商管理中启用。")
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                NavigationLink {
                    RunnableModelIdentifierSelectionView(
                        title: title,
                        options: options,
                        selectionID: selectionID,
                        allowEmptySelection: allowEmptySelection
                    )
                } label: {
                    HStack {
                        Text(title)
                        MarqueeText(
                            content: selectedModelLabel(
                                for: selectionID.wrappedValue,
                                in: options,
                                allowEmptySelection: allowEmptySelection
                            ),
                            uiFont: .preferredFont(forTextStyle: .body)
                        )
                        .foregroundStyle(.secondary)
                        .allowsHitTesting(false)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            }
        } footer: {
            Text(footer)
        }
    }

    private func syncImageGenerationSelection() {
        let options = viewModel.imageGenerationModelOptions
        guard !options.isEmpty else {
            imageGenerationModelIdentifier = ""
            return
        }

        if let matched = viewModel.imageGenerationModel(with: imageGenerationModelIdentifier) {
            imageGenerationModelIdentifier = matched.id
            return
        }

        imageGenerationModelIdentifier = options[0].id
    }

    private func selectedModelLabel(
        for selectionID: String,
        in options: [RunnableModel],
        allowEmptySelection: Bool
    ) -> String {
        if let matched = options.first(where: { $0.id == selectionID }) {
            return "\(matched.model.displayName) | \(matched.provider.name)"
        }

        if allowEmptySelection {
            return "未选择"
        }

        return options.first.map { "\($0.model.displayName) | \($0.provider.name)" } ?? ""
    }
}

private struct RunnableModelIdentifierSelectionView: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let options: [RunnableModel]
    let selectionID: Binding<String>
    let allowEmptySelection: Bool

    var body: some View {
        List {
            if allowEmptySelection {
                Button {
                    select(nil)
                } label: {
                    MarqueeSelectionRow(title: "未选择", isSelected: selectionID.wrappedValue.isEmpty)
                }
            }

            ForEach(options) { runnable in
                Button {
                    select(runnable.id)
                } label: {
                    MarqueeTitleSubtitleSelectionRow(
                        title: runnable.model.displayName,
                        subtitle: "\(runnable.provider.name) · \(runnable.model.modelName)",
                        isSelected: selectionID.wrappedValue == runnable.id,
                        subtitleUIFont: .monospacedSystemFont(
                            ofSize: UIFont.preferredFont(forTextStyle: .caption2).pointSize,
                            weight: .regular
                        )
                    )
                }
            }
        }
        .navigationTitle(title)
    }

    private func select(_ identifier: String?) {
        selectionID.wrappedValue = identifier ?? ""
        dismiss()
    }
}
