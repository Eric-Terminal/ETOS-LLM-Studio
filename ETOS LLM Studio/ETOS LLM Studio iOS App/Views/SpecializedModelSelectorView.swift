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
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Picker(title, selection: selectionID) {
                    if allowEmptySelection {
                        Text("未选择").tag("")
                    }
                    ForEach(options) { runnable in
                        Text("\(runnable.model.displayName) | \(runnable.provider.name)")
                            .tag(runnable.id)
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
}
