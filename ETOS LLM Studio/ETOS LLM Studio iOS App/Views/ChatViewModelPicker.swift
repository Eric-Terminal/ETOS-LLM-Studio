// ============================================================================
// ChatViewModelPicker.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件承载 ChatView 的模型选择底部抽屉。
// ============================================================================

import SwiftUI
import Foundation
import ETOSCore
import UIKit

extension ChatView {
    var nativeModelPickerSheet: some View {
        NavigationStack {
            nativeModelPickerContent
            .navigationTitle(NSLocalizedString("选择模型", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(item: $quickModelSettingsTarget) { runnable in
                ChatQuickModelSettingsView(runnableModel: runnable)
            }
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
                    Text(NSLocalizedString("轻点切换模型，长按打开设置", comment: "模型选择列表操作提示"))
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
            } footer: {
                Text(NSLocalizedString("轻点切换模型，长按打开设置", comment: "模型选择列表操作提示"))
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
        .highPriorityGesture(
            LongPressGesture(minimumDuration: 0.45)
                .onEnded { _ in
                    presentQuickModelSettings(for: runnable)
                }
        )
        .accessibilityHint(NSLocalizedString("长按可打开模型设置", comment: "模型选择行的无障碍提示"))
        .accessibilityAction(named: Text(NSLocalizedString("打开模型设置", comment: "模型选择行的无障碍操作"))) {
            presentQuickModelSettings(for: runnable)
        }
    }

    func presentQuickModelSettings(for runnable: RunnableModel) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        activeChatPickerDetent = .large
        quickModelSettingsTarget = runnable
    }

    var topModelChoices: [RunnableModel] {
        Array(viewModel.activatedConversationModels.prefix(3))
    }

    var hasMoreModelChoices: Bool {
        viewModel.activatedConversationModels.count > topModelChoices.count
    }
}

private struct ChatQuickModelSettingsView: View {
    @State private var provider: Provider
    private let modelID: UUID

    init(runnableModel: RunnableModel) {
        _provider = State(initialValue: runnableModel.provider)
        modelID = runnableModel.model.id
    }

    var body: some View {
        if let modelIndex = provider.models.firstIndex(where: { $0.id == modelID }) {
            ModelSettingsView(
                model: $provider.models[modelIndex],
                provider: provider,
                onSave: saveProvider
            )
        }
    }

    private func saveProvider() {
        ChatService.shared.saveProviderFromManagement(provider)
    }
}
