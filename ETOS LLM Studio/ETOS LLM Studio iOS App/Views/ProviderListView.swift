import SwiftUI
import Foundation
import Shared

struct ProviderListView: View {
    @EnvironmentObject var viewModel: ChatViewModel
    @State private var isAddingProvider = false
    @State private var providerToEdit: Provider?
    @State private var providerToDelete: Provider?
    @State private var showDeleteAlert = false
    @State private var isEditingModelOrder = false
    
    var body: some View {
        List {
            if isEditingModelOrder {
                Section(
                    header: Text("模型顺序"),
                    footer: Text("这里维护全局模型顺序（隐藏索引）。上下移动后，模型选择列表会按新顺序展示。")
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
        .navigationTitle("提供商设置")
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                if !viewModel.configuredModels.isEmpty {
                    Button(isEditingModelOrder ? "完成" : "编辑") {
                        isEditingModelOrder.toggle()
                    }
                }
            }

            ToolbarItem(placement: .navigationBarTrailing) {
                if !isEditingModelOrder {
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
        .onChange(of: viewModel.configuredModels.count) { _, count in
            if count < 2 {
                isEditingModelOrder = false
            }
        }
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
            Spacer()
            VStack(spacing: 6) {
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
