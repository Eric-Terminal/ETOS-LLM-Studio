
// ============================================================================
// ProviderActionsView.swift
// ============================================================================
// ETOS LLM Studio Watch App 提供商操作视图
//
// 定义内容:
// - 提供对单个提供商进行编辑或删除的选项
// ============================================================================

import SwiftUI
import Shared

struct ProviderActionsView: View {
    @EnvironmentObject var viewModel: ChatViewModel
    @Environment(\.presentationMode) var presentationMode
    
    let provider: Provider
    
    @State private var isShowingDeleteConfirm = false

    var body: some View {
        Form {
            Section {
                // 编辑按钮
                NavigationLink(destination: ProviderEditView(provider: provider, isNew: false).environmentObject(viewModel)) {
                    Label("编辑提供商", systemImage: "pencil")
                }
            }

            Section {
                // 删除按钮
                Button(role: .destructive, action: {
                    isShowingDeleteConfirm = true
                }) {
                    Label("删除提供商", systemImage: "trash.fill")
                }
            }
        }
        .navigationTitle(provider.name)
        .alert("确认删除", isPresented: $isShowingDeleteConfirm, actions: {
            Button("删除", role: .destructive) {
                deleteProvider()
            }
            Button("取消", role: .cancel) { }
        }, message: {
            Text("您确定要删除提供商 “\(provider.name)” 吗？此操作无法撤销。")
        })
    }

    private func deleteProvider() {
        // 使用 ConfigLoader 删除配置文件
        ConfigLoader.deleteProvider(provider)
        
        // 在 ChatService 中重新加载提供商以更新应用状态
        ChatService.shared.reloadProviders()
        
        // 自动返回上一级视图
        presentationMode.wrappedValue.dismiss()
    }
}
