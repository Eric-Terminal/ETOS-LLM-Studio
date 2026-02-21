import SwiftUI
import Shared

private enum WatchProviderManagementTab: String, CaseIterable, Identifiable {
    case provider
    case specializedModel

    var id: String { rawValue }

    var title: String {
        switch self {
        case .provider:
            return "提供商管理"
        case .specializedModel:
            return "专用模型"
        }
    }
}

struct ProviderListView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @State private var selectedTab: WatchProviderManagementTab = .provider

    var body: some View {
        Group {
            switch selectedTab {
            case .provider:
                WatchProviderManagementContentView()
                    .environmentObject(viewModel)
            case .specializedModel:
                SpecializedModelSelectorView()
                    .environmentObject(viewModel)
            }
        }
        .navigationTitle("提供商与模型管理")
        .safeAreaInset(edge: .top) {
            HStack(spacing: 6) {
                ForEach(WatchProviderManagementTab.allCases) { tab in
                    Button {
                        selectedTab = tab
                    } label: {
                        Text(tab.title)
                            .font(.footnote)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(selectedTab == tab ? Color.accentColor.opacity(0.2) : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)
            .padding(.bottom, 2)
            .background(.thinMaterial)
        }
    }
}

private struct WatchProviderManagementContentView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @State private var isAddingProvider = false
    @State private var isEditingModelOrder = false

    var body: some View {
        List {
            if isEditingModelOrder {
                Section(
                    header: Text("模型顺序"),
                    footer: Text("维护全局模型顺序，模型选择列表会按这里的顺序展示。")
                ) {
                    if viewModel.configuredModels.isEmpty {
                        Text("暂无可排序模型。")
                            .font(.footnote)
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
            } else {
                ForEach(viewModel.providers) { provider in
                    NavigationLink(destination: ProviderDetailView(provider: provider)) {
                        Text(provider.name)
                    }
                    .swipeActions(edge: .leading) {
                        NavigationLink(destination: ProviderEditView(provider: provider, isNew: false)) {
                            Label("编辑", systemImage: "pencil")
                        }
                        .tint(.blue)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            deleteProvider(provider)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if !viewModel.configuredModels.isEmpty {
                    Button(isEditingModelOrder ? "完成" : "编辑") {
                        isEditingModelOrder.toggle()
                    }
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                if !isEditingModelOrder {
                    Button(action: { isAddingProvider = true }) {
                        Image(systemName: "plus")
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
        .onChange(of: viewModel.configuredModels.count) { _, count in
            if count < 2 {
                isEditingModelOrder = false
            }
        }
    }

    private func deleteProvider(_ provider: Provider) {
        ConfigLoader.deleteProvider(provider)
        ChatService.shared.reloadProviders()
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
            VStack(alignment: .leading, spacing: 2) {
                Text(runnable.model.displayName)
                    .lineLimit(1)
                Text(runnable.provider.name)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !runnable.model.isActivated {
                    Text("未启用")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
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
