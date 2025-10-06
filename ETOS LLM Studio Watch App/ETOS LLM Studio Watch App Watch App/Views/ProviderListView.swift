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

    var body: some View {
        List {
            ForEach(viewModel.providers) { provider in
                NavigationLink(destination: ProviderDetailView(provider: provider)) {
                    Text(provider.name)
                }
                .swipeActions(edge: .leading) {
                    NavigationLink(destination: ProviderActionsView(provider: provider).environmentObject(viewModel)) {
                        Label("更多", systemImage: "ellipsis")
                    }
                    .tint(.gray)
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
    }
}