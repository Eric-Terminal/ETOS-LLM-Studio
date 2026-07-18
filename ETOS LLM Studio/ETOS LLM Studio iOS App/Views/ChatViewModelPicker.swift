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

    @ViewBuilder
    var nativeModelPickerContent: some View {
        if viewModel.activatedConversationModels.isEmpty {
            nativeModelPickerEmptyList
        } else if appConfig.iOSModelPickerGroupsByProvider {
            providerGroupedModelPickerContent
        } else {
            classicModelPickerList
        }
    }

    var nativeModelPickerEmptyList: some View {
        List {
            VStack {
                Text(NSLocalizedString("暂无可用模型", comment: ""))
                    .etFont(.headline)
                Text(NSLocalizedString("请先在设置中启用模型", comment: ""))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical)
        }
    }

    var classicModelPickerList: some View {
        List {
            modelPickerSection(
                models: viewModel.activatedConversationModels,
                showsProviderName: true
            )
        }
    }

    var providerGroupedModelPickerContent: some View {
        List {
            modelPickerSection(
                models: selectedProviderModelChoices,
                showsProviderName: false
            )
        }
        // 固定栏与列表共享系统表面，避免额外材质叠层产生色差。
        .safeAreaInset(edge: .top, spacing: 0) {
            modelPickerProviderStrip
        }
        .onAppear(perform: prepareSelectedModelPickerProvider)
        .onReceive(viewModel.$activatedConversationModelGroups) { groups in
            normalizeSelectedModelPickerProvider(using: groups)
        }
    }

    var modelPickerProviderStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 12) {
                    ForEach(viewModel.activatedConversationModelGroups) { group in
                        modelPickerProviderButton(group)
                            .id(group.id)
                    }
                }
                .padding(.horizontal)
            }
            .scrollIndicators(.hidden)
            .onAppear {
                guard let selectedModelPickerProviderID else { return }
                proxy.scrollTo(selectedModelPickerProviderID, anchor: .center)
            }
            .onChange(of: selectedModelPickerProviderID) { _, providerID in
                guard let providerID else { return }
                if accessibilityReduceMotion {
                    proxy.scrollTo(providerID, anchor: .center)
                } else {
                    withAnimation(chatPickerAnimation) {
                        proxy.scrollTo(providerID, anchor: .center)
                    }
                }
            }
        }
        .frame(height: modelPickerProviderStripHeight)
    }

    func modelPickerProviderButton(_ group: RunnableModelProviderGroup) -> some View {
        let isSelected = group.id == selectedModelPickerProviderID
        return Button {
            selectedModelPickerProviderID = group.id
        } label: {
            VStack(spacing: 4) {
                Text(group.providerInitial)
                    .etFont(.subheadline)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                    .frame(width: modelPickerProviderIconSize, height: modelPickerProviderIconSize)
                    .background(
                        Circle()
                            .fill(isSelected ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.12))
                    )
                    .overlay {
                        Circle()
                            .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
                    }

                Text(group.provider.name)
                    .etFont(.caption2)
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                    .lineLimit(1)
                    .frame(width: 68)
            }
            .contentShape(Rectangle())
            .animation(accessibilityReduceMotion ? nil : chatPickerAnimation, value: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(group.provider.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    func modelPickerSection(
        models: [RunnableModel],
        showsProviderName: Bool
    ) -> some View {
        Section {
            ForEach(models, id: \.id) { runnable in
                nativeModelPickerModelRow(runnable, showsProviderName: showsProviderName)
            }
        } header: {
            Text(NSLocalizedString("模型", comment: ""))
        } footer: {
            Text(NSLocalizedString("轻点切换模型，长按打开设置", comment: "模型选择列表操作提示"))
        }
    }

    func nativeModelPickerModelRow(
        _ runnable: RunnableModel,
        showsProviderName: Bool
    ) -> some View {
        MarqueeTitleSubtitleSelectionRow(
            title: runnable.model.displayName,
            subtitle: showsProviderName
                ? "\(runnable.provider.name) · \(runnable.model.modelName)"
                : runnable.model.modelName,
            isSelected: runnable.id == viewModel.selectedModel?.id,
            subtitleUIFont: .monospacedSystemFont(ofSize: 12, weight: .regular)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .gesture(
            LongPressGesture(minimumDuration: 0.45)
                .exclusively(before: TapGesture())
                .onEnded { gesture in
                    switch gesture {
                    case .first(_):
                        presentQuickModelSettings(for: runnable)
                    case .second(_):
                        viewModel.setSelectedModel(runnable)
                        dismissModelPickerSheet()
                    }
                }
        )
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            viewModel.setSelectedModel(runnable)
            dismissModelPickerSheet()
        }
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

    var selectedProviderModelChoices: [RunnableModel] {
        guard let selectedModelPickerProviderID else { return [] }
        return viewModel.activatedConversationModelsByProviderID[selectedModelPickerProviderID] ?? []
    }

    func prepareSelectedModelPickerProvider() {
        normalizeSelectedModelPickerProvider(using: viewModel.activatedConversationModelGroups)
    }

    func normalizeSelectedModelPickerProvider(using groups: [RunnableModelProviderGroup]) {
        guard !groups.isEmpty else {
            selectedModelPickerProviderID = nil
            return
        }
        if let selectedModelPickerProviderID,
           viewModel.activatedConversationModelsByProviderID[selectedModelPickerProviderID] != nil {
            return
        }
        let currentProviderID = viewModel.selectedModel?.provider.id
        selectedModelPickerProviderID = currentProviderID.flatMap {
            viewModel.activatedConversationModelsByProviderID[$0] == nil ? nil : $0
        } ?? groups.first?.id
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
