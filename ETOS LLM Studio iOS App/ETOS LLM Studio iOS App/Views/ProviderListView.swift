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
    @State private var providerToEdit: Provider?
    @State private var showEditSheet = false
    @State private var providerToDelete: Provider?
    @State private var showDeleteConfirm = false

    var body: some View {
        List {
            ForEach(viewModel.providers) { provider in
                NavigationLink(destination: ProviderDetailView(provider: provider)) {
                    Text(provider.name)
                }
                .contextMenu {
                    Button {
                        providerToEdit = provider
                        showEditSheet = true
                    } label: {
                        Label("编辑", systemImage: "pencil")
                    }

                    Button(role: .destructive) {
                        providerToDelete = provider
                        showDeleteConfirm = true
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
            }
        }
        .navigationTitle("提供商设置")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: { isAddingProvider = true }) {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $isAddingProvider) {
            // 传递一个全新的、空的提供商对象给编辑视图
            ProviderEditView(provider: Provider(name: "", baseURL: "", apiKeys: [""], apiFormat: "openai-compatible"), isNew: true)
                .environmentObject(viewModel)
        }
        .sheet(isPresented: $showEditSheet) {
            if let providerToEdit = providerToEdit {
                ProviderEditView(provider: providerToEdit, isNew: false)
                    .environmentObject(viewModel)
            }
        }
        .alert("确认删除", isPresented: $showDeleteConfirm, actions: {
            Button("删除", role: .destructive) {
                if let providerToDelete = providerToDelete {
                    deleteProvider(providerToDelete)
                }
            }
            Button("取消", role: .cancel) { }
        }, message: {
            Text("您确定要删除提供商 “\(providerToDelete?.name ?? "")” 吗？此操作无法撤销。")
        })
    }

    private func deleteProvider(_ provider: Provider) {
        // 使用 ConfigLoader 删除配置文件
        ConfigLoader.deleteProvider(provider)
        
        // 在 ChatService 中重新加载提供商以更新应用状态
        ChatService.shared.reloadProviders()
    }
}