// ============================================================================
// ProviderListView.swift
// ============================================================================
// ProviderListView 界面 (iOS)
// - 负责该功能在 iOS 端的交互与展示
// - 遵循项目现有视图结构与状态流
// ============================================================================

import SwiftUI
import Foundation
import ETOSCore

private enum ProviderManagementTab: String, CaseIterable, Identifiable {
    case provider
    case modelOrder
    case specializedModel
    case globalProxy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .provider:
            return NSLocalizedString("提供商管理", comment: "")
        case .modelOrder:
            return NSLocalizedString("模型顺序", comment: "")
        case .specializedModel:
            return NSLocalizedString("专用模型", comment: "")
        case .globalProxy:
            return NSLocalizedString("全局代理", comment: "")
        }
    }

    var iconName: String {
        switch self {
        case .provider:
            return "shippingbox"
        case .modelOrder:
            return "arrow.up.arrow.down"
        case .specializedModel:
            return "slider.horizontal.3"
        case .globalProxy:
            return "network"
        }
    }
}

private enum ProviderConfigurationTab: String, CaseIterable, Identifiable {
    case models
    case provider

    var id: String { rawValue }

    var title: String {
        switch self {
        case .models:
            return NSLocalizedString("模型配置", comment: "")
        case .provider:
            return NSLocalizedString("提供商配置", comment: "")
        }
    }

    var iconName: String {
        switch self {
        case .models:
            return "square.stack.3d.up"
        case .provider:
            return "slider.horizontal.3"
        }
    }
}

struct ProviderListView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @State private var selectedTab: ProviderManagementTab = .provider
    @State private var isAddingProvider = false

    var body: some View {
        TabView(selection: $selectedTab) {
            ProviderManagementContentView()
                .environmentObject(viewModel)
                .tabItem {
                    Label(ProviderManagementTab.provider.title, systemImage: ProviderManagementTab.provider.iconName)
                }
                .tag(ProviderManagementTab.provider)

            ProviderModelOrderContentView()
                .environmentObject(viewModel)
                .tabItem {
                    Label(ProviderManagementTab.modelOrder.title, systemImage: ProviderManagementTab.modelOrder.iconName)
                }
                .tag(ProviderManagementTab.modelOrder)

            SpecializedModelSelectorView()
                .environmentObject(viewModel)
                .tabItem {
                    Label(ProviderManagementTab.specializedModel.title, systemImage: ProviderManagementTab.specializedModel.iconName)
                }
                .tag(ProviderManagementTab.specializedModel)

            GlobalProxySettingsView()
                .tabItem {
                    Label(ProviderManagementTab.globalProxy.title, systemImage: ProviderManagementTab.globalProxy.iconName)
                }
                .tag(ProviderManagementTab.globalProxy)
        }
        .navigationTitle(NSLocalizedString("提供商与模型管理", comment: ""))
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if selectedTab == .provider {
                    Button {
                        isAddingProvider = true
                    } label: {
                        Label(NSLocalizedString("添加提供商", comment: ""), systemImage: "plus")
                    }
                }
            }
        }
        .sheet(isPresented: $isAddingProvider) {
            NavigationStack {
                ProviderEditView(
                    provider: Provider(name: "", baseURL: "", apiKeys: [""], apiFormat: "openai-compatible"),
                    isNew: true
                )
                .environmentObject(viewModel)
            }
        }
    }
}

private struct ProviderManagementContentView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @State private var providerToDelete: Provider?
    @State private var showDeleteAlert = false

    var body: some View {
        List {
            Section {
                ForEach(providersBinding, id: \.id, editActions: .move) { $provider in
                    NavigationLink {
                        ProviderConfigurationTabsView(provider: provider)
                            .environmentObject(viewModel)
                    } label: {
                        MarqueeTitleSubtitleLabel(
                            title: provider.name,
                            subtitle: provider.baseURL,
                            titleUIFont: .preferredFont(forTextStyle: .body),
                            subtitleUIFont: .preferredFont(forTextStyle: .caption1)
                        )
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            providerToDelete = provider
                            showDeleteAlert = true
                        } label: {
                            Label(NSLocalizedString("删除", comment: ""), systemImage: "trash")
                        }
                    }
                }
            }
        }
        .alert(NSLocalizedString("确认删除提供商", comment: ""), isPresented: $showDeleteAlert) {
            Button(NSLocalizedString("删除", comment: ""), role: .destructive) {
                if let target = providerToDelete {
                    ChatService.shared.deleteProvider(target)
                }
                providerToDelete = nil
            }
            Button(NSLocalizedString("取消", comment: ""), role: .cancel) {
                providerToDelete = nil
            }
        } message: {
            if let target = providerToDelete {
                if LocalModelProviderBridge.isLocalProvider(target) {
                    Text(NSLocalizedString("本地权重文件会保留；稍后重新开启本地模型时会自动恢复这个提供商。", comment: "Local provider delete disables feature message"))
                } else {
                    Text(String(format: NSLocalizedString("删除“%@”后无法恢复。", comment: ""), target.name))
                }
            } else {
                Text(NSLocalizedString("此操作无法撤销。", comment: ""))
            }
        }
    }

    private var providersBinding: Binding<[Provider]> {
        Binding {
            viewModel.providers
        } set: { orderedProviders in
            ChatService.shared.setProviderOrder(orderedProviders.map(\.id))
        }
    }
}

private struct ProviderConfigurationTabsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var viewModel: ChatViewModel
    @State private var provider: Provider
    @State private var selectedTab: ProviderConfigurationTab = .models
    @State private var providerRevision = 0
    @State private var addModelRequest = 0
    @State private var fetchModelsRequest = 0
    @State private var saveProviderRequest = 0
    @State private var canSaveProviderConfiguration = false
    @State private var hasUnsavedProviderConfiguration = false
    @State private var showUnsavedProviderAlert = false
    @State private var dismissAfterProviderSave = false
    @State private var isShowingModelTest = false

    init(provider: Provider) {
        _provider = State(initialValue: provider)
    }

    var body: some View {
        TabView(selection: $selectedTab) {
                ProviderDetailView(
                    provider: provider,
                    showsToolbar: false,
                    addModelRequest: addModelRequest,
                    fetchModelsRequest: fetchModelsRequest,
                    allowsRemoteModelFetch: allowsRemoteModelFetch,
                    allowsModelTesting: allowsModelTesting,
                    allowsManualModelAdd: allowsManualModelAdd
                ) { updatedProvider in
                    updateProvider(updatedProvider)
                }
                .environmentObject(viewModel)
                .tabItem {
                    Label(ProviderConfigurationTab.models.title, systemImage: ProviderConfigurationTab.models.iconName)
                }
                .tag(ProviderConfigurationTab.models)

            ProviderEditView(
                provider: provider,
                isNew: false,
                dismissAfterSave: false,
                showsCancelButton: false,
                navigationTitleOverride: NSLocalizedString("提供商配置", comment: ""),
                saveRequest: saveProviderRequest,
                showsToolbarSaveButton: false,
                onSaveAvailabilityChange: { canSave in
                    canSaveProviderConfiguration = canSave
                    if !canSave {
                        dismissAfterProviderSave = false
                    }
                },
                onUnsavedChangesChange: { hasUnsavedProviderConfiguration = $0 }
            ) { updatedProvider in
                updateProvider(updatedProvider)
            }
            .id(providerRevision)
            .environmentObject(viewModel)
            .tabItem {
                Label(ProviderConfigurationTab.provider.title, systemImage: ProviderConfigurationTab.provider.iconName)
            }
            .tag(ProviderConfigurationTab.provider)
        }
        .navigationTitle(provider.name)
        .navigationBarBackButtonHidden(hasUnsavedProviderConfiguration)
        .toolbar {
            if hasUnsavedProviderConfiguration {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        showUnsavedProviderAlert = true
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .accessibilityLabel(NSLocalizedString("返回", comment: ""))
                }
            }
            if selectedTab == .models {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button {
                        isShowingModelTest = true
                    } label: {
                        Image(systemName: "checkmark.seal")
                    }
                    .accessibilityLabel(NSLocalizedString("模型测试", comment: "Model connectivity test button"))
                    .disabled(!allowsModelTesting)

                    if allowsRemoteModelFetch {
                        Button {
                            fetchModelsRequest += 1
                        } label: {
                            Image(systemName: "icloud.and.arrow.down")
                        }
                        .accessibilityLabel(NSLocalizedString("从云端获取", comment: ""))
                    }

                    Button {
                        addModelRequest += 1
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel(NSLocalizedString("添加模型", comment: ""))
                    .disabled(!allowsManualModelAdd)
                }
            } else {
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("保存", comment: "")) {
                        saveProviderRequest += 1
                    }
                    .disabled(!canSaveProviderConfiguration)
                }
            }
        }
        .alert(NSLocalizedString("未保存更改", comment: "Unsaved changes alert title"), isPresented: $showUnsavedProviderAlert) {
            if canSaveProviderConfiguration {
                Button(NSLocalizedString("保存并离开", comment: "Save and leave button")) {
                    dismissAfterProviderSave = true
                    saveProviderRequest += 1
                }
            }
            Button(NSLocalizedString("放弃更改", comment: "Discard changes button"), role: .destructive) {
                dismiss()
            }
            Button(NSLocalizedString("继续编辑", comment: "Continue editing button"), role: .cancel) {}
        } message: {
            Text(NSLocalizedString("要保存当前编辑内容，还是放弃更改并离开？", comment: "Generic unsaved changes alert message"))
        }
        .sheet(isPresented: $isShowingModelTest) {
            NavigationStack {
                ModelConnectivityTestView(provider: provider)
            }
        }
    }

    private var allowsRemoteModelFetch: Bool {
        !LocalModelProviderBridge.isLocalProvider(provider) && provider.apiFormat.lowercased() != "anthropic"
    }

    private var allowsModelTesting: Bool {
        !LocalModelProviderBridge.isLocalProvider(provider)
    }

    private var allowsManualModelAdd: Bool {
        !LocalModelProviderBridge.isLocalProvider(provider)
    }

    private func updateProvider(_ updatedProvider: Provider) {
        guard provider != updatedProvider else {
            hasUnsavedProviderConfiguration = false
            if dismissAfterProviderSave {
                dismissAfterProviderSave = false
                dismiss()
            }
            return
        }
        provider = updatedProvider
        hasUnsavedProviderConfiguration = false
        providerRevision += 1
        if dismissAfterProviderSave {
            dismissAfterProviderSave = false
            dismiss()
        }
    }
}

private struct ProviderModelOrderContentView: View {
    @EnvironmentObject private var viewModel: ChatViewModel

    var body: some View {
        List {
            Section(
                header: Text(NSLocalizedString("模型顺序", comment: "")),
                footer: Text(NSLocalizedString("拖拽右侧把手可调整全局模型顺序。模型选择列表会按这里的顺序展示。", comment: ""))
            ) {
                if viewModel.configuredModels.isEmpty {
                    Text(NSLocalizedString("暂无可排序模型。", comment: ""))
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.configuredModels, id: \.id) { runnable in
                        modelOrderRow(runnable: runnable)
                    }
                    .onMove { offsets, destination in
                        ChatService.shared.moveConfiguredModels(fromOffsets: offsets, toOffset: destination)
                    }
                }
            }
        }
        .environment(\.editMode, .constant(.active))
    }

    @ViewBuilder
    private func modelOrderRow(runnable: RunnableModel) -> some View {
        HStack(alignment: .top, spacing: 10) {
            MarqueeTitleSubtitleLabel(
                title: runnable.model.displayName,
                subtitle: "\(runnable.provider.name) · \(runnable.model.modelName)",
                titleUIFont: .preferredFont(forTextStyle: .body),
                subtitleUIFont: .monospacedSystemFont(
                    ofSize: UIFont.preferredFont(forTextStyle: .caption2).pointSize,
                    weight: .regular
                )
            )
            .frame(maxWidth: .infinity, alignment: .leading)

            if !runnable.model.isActivated {
                Text(NSLocalizedString("未启用", comment: ""))
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
