// ============================================================================
// SettingsHubView.swift
// ============================================================================
// ETOS LLM Studio Watch App 设置中心视图
//
// 定义内容:
// - 提供导航到“提供商与模型管理”的入口
// - 提供导航到“模型行为配置”的入口
// - 提供导航到“模型行为配置”的入口
// ============================================================================

import SwiftUI
import Shared

struct SettingsHubView: View {
    @EnvironmentObject var viewModel: ChatViewModel
    
    var body: some View {
        List {
            NavigationLink(destination: ConfigurableModelListView(providers: $viewModel.providers)) {
                Label("模型行为配置", systemImage: "slider.horizontal.3")
            }
        }
        .navigationTitle("数据与模型设置")
    }
}
