// ============================================================================
// ProviderListView.swift
// ============================================================================
// ProviderListView 界面 (watchOS)
// - 负责该功能在 watchOS 端的交互与展示
// - 适配手表端交互与布局约束
// ============================================================================

import SwiftUI
import ETOSCore

struct ProviderListView: View {
    @EnvironmentObject private var viewModel: ChatViewModel

    var body: some View {
        List {
            Section(NSLocalizedString("管理入口", comment: "")) {
                NavigationLink {
                    WatchProviderManagementContentView()
                        .environmentObject(viewModel)
                } label: {
                    Label(NSLocalizedString("提供商管理", comment: ""), systemImage: "shippingbox")
                }

                NavigationLink {
                    WatchProviderModelOrderContentView()
                        .environmentObject(viewModel)
                } label: {
                    Label(NSLocalizedString("模型顺序", comment: ""), systemImage: "arrow.up.arrow.down")
                }

                NavigationLink {
                    SpecializedModelSelectorView()
                        .environmentObject(viewModel)
                } label: {
                    Label(NSLocalizedString("专用模型", comment: ""), systemImage: "slider.horizontal.3")
                }

                NavigationLink {
                    GlobalProxySettingsView()
                } label: {
                    Label(NSLocalizedString("全局代理设置", comment: ""), systemImage: "network")
                }
            }
        }
        .navigationTitle(NSLocalizedString("提供商与模型管理", comment: ""))
    }
}

private struct WatchProviderManagementContentView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @State private var isAddingProvider = false

    var body: some View {
        List {
            ForEach(providersBinding, id: \.id, editActions: .move) { $provider in
                NavigationLink {
                    ProviderActionsView(provider: provider)
                        .environmentObject(viewModel)
                } label: {
                    MarqueeTitleSubtitleLabel(
                        title: provider.name,
                        subtitle: provider.baseURL,
                        titleUIFont: .preferredFont(forTextStyle: .body),
                        subtitleUIFont: .preferredFont(forTextStyle: .caption2),
                        spacing: 2
                    )
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        deleteProvider(provider)
                    } label: {
                        Label(NSLocalizedString("删除", comment: ""), systemImage: "trash")
                    }
                }
            }
        }
        .navigationTitle(NSLocalizedString("提供商管理", comment: ""))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: { isAddingProvider = true }) {
                    Image(systemName: "plus")
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

    private func deleteProvider(_ provider: Provider) {
        ChatService.shared.deleteProvider(provider)
    }

    private var providersBinding: Binding<[Provider]> {
        Binding {
            viewModel.providers
        } set: { orderedProviders in
            ChatService.shared.setProviderOrder(orderedProviders.map(\.id))
        }
    }
}

private struct WatchProviderModelOrderContentView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @ObservedObject private var appConfig = AppConfigStore.shared

    var body: some View {
        List {
            Section(
                header: Text(NSLocalizedString("模型选择方式", comment: "")),
                footer: Text(NSLocalizedString("经典列表会直接显示全部模型；按提供商会先选择提供商，再显示对应模型。", comment: ""))
            ) {
                Picker(
                    NSLocalizedString("模型选择方式", comment: ""),
                    selection: modelPickerGroupingBinding
                ) {
                    Text(NSLocalizedString("经典列表", comment: ""))
                        .tag(false)
                    Text(NSLocalizedString("按提供商", comment: ""))
                        .tag(true)
                }
            }

            Section(
                header: Text(NSLocalizedString("提供商顺序", comment: "")),
                footer: Text(NSLocalizedString("拖拽右侧把手调整提供商顺序；轻点提供商可调整其模型顺序。", comment: ""))
            ) {
                if viewModel.providers.isEmpty {
                    Text(NSLocalizedString("暂无提供商。", comment: ""))
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(providersBinding, id: \.id, editActions: .move) { $provider in
                        NavigationLink {
                            WatchProviderModelOrderDetailView(provider: provider)
                                .environmentObject(viewModel)
                        } label: {
                            MarqueeTitleSubtitleLabel(
                                title: provider.name,
                                subtitle: provider.baseURL,
                                titleUIFont: .preferredFont(forTextStyle: .body),
                                subtitleUIFont: .preferredFont(forTextStyle: .caption2),
                                spacing: 2
                            )
                        }
                    }
                }
            }
        }
        .navigationTitle(NSLocalizedString("模型顺序", comment: ""))
    }

    private var modelPickerGroupingBinding: Binding<Bool> {
        Binding {
            appConfig.watchModelPickerGroupsByProvider
        } set: { groupsByProvider in
            appConfig.watchModelPickerGroupsByProvider = groupsByProvider
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

private struct WatchProviderModelOrderDetailView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    let provider: Provider

    var body: some View {
        List {
            Section(
                header: Text(NSLocalizedString("模型顺序", comment: "")),
                footer: Text(NSLocalizedString("拖拽右侧把手调整此提供商内的模型顺序。", comment: ""))
            ) {
                if modelsBinding.wrappedValue.isEmpty {
                    Text(NSLocalizedString("暂无可排序模型。", comment: ""))
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(modelsBinding, id: \.id, editActions: .move) { $runnable in
                        modelOrderRow(runnable: runnable)
                    }
                }
            }
        }
        .navigationTitle(provider.name)
    }

    @ViewBuilder
    private func modelOrderRow(runnable: RunnableModel) -> some View {
        HStack(alignment: .top, spacing: 6) {
            MarqueeTitleSubtitleLabel(
                title: runnable.model.displayName,
                subtitle: runnable.model.modelName,
                titleUIFont: .preferredFont(forTextStyle: .body),
                subtitleUIFont: .monospacedSystemFont(
                    ofSize: UIFont.preferredFont(forTextStyle: .caption2).pointSize,
                    weight: .regular
                ),
                spacing: 2
            )
            .frame(maxWidth: .infinity, alignment: .leading)

            if !runnable.model.isActivated {
                Text(NSLocalizedString("未启用", comment: ""))
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var modelsBinding: Binding<[RunnableModel]> {
        Binding {
            viewModel.configuredModelsByProviderID[provider.id] ?? []
        } set: { orderedModels in
            ChatService.shared.setConfiguredModelOrder(
                orderedModels.map(\.id),
                for: provider.id
            )
        }
    }
}
