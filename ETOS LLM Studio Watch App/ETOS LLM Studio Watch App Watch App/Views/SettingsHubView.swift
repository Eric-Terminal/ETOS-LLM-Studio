// ============================================================================
// SettingsHubView.swift
// ============================================================================
// ETOS LLM Studio Watch App 设置中心视图
//
// 定义内容:
// - 提供导航到“提供商与模型管理”的入口
// - 提供导航到“模型行为配置”的入口
// - 提供导航到“记忆库管理”的入口
// ============================================================================

import SwiftUI
import Shared

struct SettingsHubView: View {
    @EnvironmentObject var viewModel: ChatViewModel
    
    var body: some View {
        List {
            NavigationLink(destination: ProviderListView().environmentObject(viewModel)) {
                Label("提供商与模型管理", systemImage: "list.bullet.rectangle.portrait")
            }
            
            NavigationLink(destination: ConfigurableModelListView(providers: $viewModel.providers)) {
                Label("模型行为配置", systemImage: "slider.horizontal.3")
            }
            
            NavigationLink(destination: StorageManagementView()) {
                Label("存储管理", systemImage: "internaldrive")
            }
            
            //if #available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *) {
            //    NavigationLink(destination: MemorySettingsView().environmentObject(viewModel)) {
            //        Label("记忆库管理", systemImage: "brain.head.profile")
            //    }
            //}
        }
        .navigationTitle("数据与模型设置")
    }
}