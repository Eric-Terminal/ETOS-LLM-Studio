// ============================================================================
// ProviderListView.swift
// ============================================================================
// ETOS LLM Studio Watch App 提供商列表视图
//
// 定义内容:
// - 显示所有已配置的 API 提供商
// - 提供添加和删除提供商的功能
// ============================================================================

import SwiftUI
import Shared

struct ProviderListView: View {
    // 从环境中访问共享视图模型
    @EnvironmentObject var viewModel: ChatViewModel
    
    // 用于显示添加新提供商表单的状态
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
        .navigationTitle("提供商设置")
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
            // 传递一个全新的、空的提供商对象给编辑视图
            NavigationStack {
                ProviderEditView(provider: Provider(name: "", baseURL: "", apiKeys: [""], apiFormat: "openai-compatible"), isNew: true)
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
