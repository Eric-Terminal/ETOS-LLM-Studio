import SwiftUI
import Foundation
import Shared

private enum ProviderManagementTab: String, CaseIterable, Identifiable {
    case provider
    case modelOrder
    case specializedModel

    var id: String { rawValue }

    var title: String {
        switch self {
        case .provider:
            return "提供商管理"
        case .modelOrder:
            return "模型顺序"
        case .specializedModel:
            return "专用模型"
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
        }
        .navigationTitle("提供商与模型管理")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if selectedTab == .provider {
                    Button {
                        isAddingProvider = true
                    } label: {
                        Label("添加提供商", systemImage: "plus")
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
    @State private var providerToEdit: Provider?
    @State private var providerToDelete: Provider?
    @State private var showDeleteAlert = false

    var body: some View {
        List {
            Section {
                ForEach(viewModel.providers) { provider in
                    NavigationLink {
                        ProviderDetailView(provider: provider)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(provider.name)
                            Text(provider.baseURL)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .contextMenu {
                        Button {
                            providerToEdit = provider
                        } label: {
                            Label("编辑提供商", systemImage: "pencil")
                        }

                        Button(role: .destructive) {
                            providerToDelete = provider
                            showDeleteAlert = true
                        } label: {
                            Label("删除提供商", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .sheet(item: $providerToEdit) { provider in
            NavigationStack {
                ProviderEditView(provider: provider, isNew: false)
                    .environmentObject(viewModel)
            }
        }
        .alert("确认删除提供商", isPresented: $showDeleteAlert) {
            Button("删除", role: .destructive) {
                if let target = providerToDelete {
                    ConfigLoader.deleteProvider(target)
                    ChatService.shared.reloadProviders()
                }
                providerToDelete = nil
            }
            Button("取消", role: .cancel) {
                providerToDelete = nil
            }
        } message: {
            if let target = providerToDelete {
                Text(String(format: NSLocalizedString("删除“%@”后无法恢复。", comment: ""), target.name))
            } else {
                Text("此操作无法撤销。")
            }
        }
    }
}

private struct ProviderModelOrderContentView: View {
    @EnvironmentObject private var viewModel: ChatViewModel

    var body: some View {
        List {
            Section(
                header: Text("模型顺序"),
                footer: Text("拖拽右侧把手可调整全局模型顺序。模型选择列表会按这里的顺序展示。")
            ) {
                if viewModel.configuredModels.isEmpty {
                    Text("暂无可排序模型。")
                        .font(.footnote)
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
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(runnable.model.displayName)
                    .lineLimit(1)
                Text("\(runnable.provider.name) · \(runnable.model.modelName)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !runnable.model.isActivated {
                    Text("未启用")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
