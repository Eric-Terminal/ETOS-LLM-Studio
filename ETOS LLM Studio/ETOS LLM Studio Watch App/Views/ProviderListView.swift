// ============================================================================
// ProviderListView.swift
// ============================================================================
// ProviderListView 界面 (watchOS)
// - 负责该功能在 watchOS 端的交互与展示
// - 适配手表端交互与布局约束
// ============================================================================

import SwiftUI
import Shared

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
            ForEach(viewModel.providers) { provider in
                NavigationLink(destination: ProviderDetailView(provider: provider)) {
                    MarqueeTitleSubtitleLabel(
                        title: provider.name,
                        subtitle: provider.baseURL,
                        titleUIFont: .preferredFont(forTextStyle: .body),
                        subtitleUIFont: .preferredFont(forTextStyle: .caption2),
                        spacing: 2
                    )
                }
                .swipeActions(edge: .leading) {
                    NavigationLink(destination: ProviderEditView(provider: provider, isNew: false)) {
                        Label(NSLocalizedString("编辑", comment: ""), systemImage: "pencil")
                    }
                    .tint(.blue)
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
}

private struct WatchProviderModelOrderContentView: View {
    @EnvironmentObject private var viewModel: ChatViewModel

    var body: some View {
        List {
            Section(
                header: Text(NSLocalizedString("模型顺序", comment: "")),
                footer: Text(NSLocalizedString("维护全局模型顺序，模型选择列表会按这里的顺序展示。", comment: ""))
            ) {
                if viewModel.configuredModels.isEmpty {
                    Text(NSLocalizedString("暂无可排序模型。", comment: ""))
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(viewModel.configuredModels.enumerated()), id: \.element.id) { position, runnable in
                        modelOrderRow(
                            runnable: runnable,
                            position: position,
                            total: viewModel.configuredModels.count
                        )
                    }
                }
            }
        }
        .navigationTitle(NSLocalizedString("模型顺序", comment: ""))
    }

    private func moveModelUp(at position: Int) {
        guard position > 0 else { return }
        ChatService.shared.moveConfiguredModel(fromPosition: position, toPosition: position - 1)
    }

    private func moveModelDown(at position: Int, total: Int) {
        guard position + 1 < total else { return }
        ChatService.shared.moveConfiguredModel(fromPosition: position, toPosition: position + 1)
    }

    @ViewBuilder
    private func modelOrderRow(runnable: RunnableModel, position: Int, total: Int) -> some View {
        HStack(spacing: 6) {
            MarqueeTitleSubtitleLabel(
                title: runnable.model.displayName,
                subtitle: "\(runnable.provider.name) · \(runnable.model.modelName)",
                titleUIFont: .preferredFont(forTextStyle: .body),
                subtitleUIFont: .monospacedSystemFont(
                    ofSize: UIFont.preferredFont(forTextStyle: .caption2).pointSize,
                    weight: .regular
                ),
                spacing: 2
            )
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                if !runnable.model.isActivated {
                    Text(NSLocalizedString("未启用", comment: ""))
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            VStack(spacing: 4) {
                Button {
                    moveModelUp(at: position)
                } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.borderless)
                .disabled(position == 0)

                Button {
                    moveModelDown(at: position, total: total)
                } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.borderless)
                .disabled(position + 1 >= total)
            }
        }
    }
}
