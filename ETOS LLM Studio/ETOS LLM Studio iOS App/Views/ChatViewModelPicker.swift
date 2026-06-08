// ============================================================================
// ChatViewModelPicker.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件承载 ChatView 的模型选择底部抽屉。
// ============================================================================

import SwiftUI
import ETOSCore

extension ChatView {
    var nativeModelPickerSheet: some View {
        NavigationStack {
            nativeModelPickerContent
            .navigationTitle(NSLocalizedString("选择模型", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("完成", comment: "")) {
                        dismissModelPickerSheet()
                    }
                }
            }
        }
    }

    var nativeModelPickerContent: some View {
        List {
            if viewModel.activatedConversationModels.isEmpty {
                VStack(spacing: 6) {
                    Text(NSLocalizedString("暂无可用模型", comment: ""))
                        .etFont(.headline)
                    Text(NSLocalizedString("请先在设置中启用模型", comment: ""))
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 28)
            } else {
                Section {
                    ForEach(topModelChoices, id: \.id) { runnable in
                        nativeModelPickerModelRow(runnable)
                    }
                } header: {
                    Text(NSLocalizedString("置顶模型", comment: ""))
                } footer: {
                    Text(NSLocalizedString("切换当前对话的模型", comment: ""))
                }

                if hasModelPickerRequestControls {
                    Section {
                        nativeModelPickerRequestControlRows
                    } header: {
                        Text(NSLocalizedString("请求控制", comment: ""))
                    } footer: {
                        Text(NSLocalizedString("点击控制名称后选择具体参数。", comment: ""))
                    }
                }

                if hasMoreModelChoices {
                    Section {
                        NavigationLink {
                            nativeModelPickerAllModelsList
                        } label: {
                            Label(NSLocalizedString("更多模型", comment: ""), systemImage: "ellipsis")
                        }
                    }
                }
            }
        }
    }

    var nativeModelPickerAllModelsList: some View {
        List {
            Section {
                ForEach(viewModel.activatedConversationModels, id: \.id) { runnable in
                    nativeModelPickerModelRow(runnable)
                }
            } header: {
                Text(NSLocalizedString("模型", comment: ""))
            }
        }
        .navigationTitle(NSLocalizedString("更多模型", comment: ""))
        .navigationBarTitleDisplayMode(.inline)
    }

    func nativeModelPickerModelRow(_ runnable: RunnableModel) -> some View {
        Button {
            viewModel.setSelectedModel(runnable)
            dismissModelPickerSheet()
        } label: {
            MarqueeTitleSubtitleSelectionRow(
                title: runnable.model.displayName,
                subtitle: "\(runnable.provider.name) · \(runnable.model.modelName)",
                isSelected: runnable.id == viewModel.selectedModel?.id,
                subtitleUIFont: .monospacedSystemFont(ofSize: 12, weight: .regular)
            )
        }
    }

    @ViewBuilder
    var nativeModelPickerRequestControlRows: some View {
        if let selectedModel = viewModel.selectedModel {
            ForEach(selectedModelRequestControls) { control in
                NavigationLink {
                    ChatRequestBodyControlDetailView(runnableModel: selectedModel, control: control)
                } label: {
                    Text(control.title)
                }
            }
        }
    }

    var topModelChoices: [RunnableModel] {
        Array(viewModel.activatedConversationModels.prefix(3))
    }

    var hasMoreModelChoices: Bool {
        viewModel.activatedConversationModels.count > topModelChoices.count
    }

    var selectedModelRequestControls: [ModelRequestBodyControl] {
        viewModel.selectedModel?.model.requestBodyControls.filter(\.isEnabled) ?? []
    }

    var hasModelPickerRequestControls: Bool {
        !selectedModelRequestControls.isEmpty
    }
}
