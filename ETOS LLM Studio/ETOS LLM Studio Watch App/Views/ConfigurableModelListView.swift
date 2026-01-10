// ============================================================================
// ConfigurableModelListView.swift
// ============================================================================
// ETOS LLM Studio Watch App 可配置模型列表视图
//
// 定义内容:
// - 显示所有提供商及其下的模型列表
// - 允许用户导航到具体模型的行为配置页面
// ============================================================================

import SwiftUI
import Shared

struct ConfigurableModelListView: View {
    // 此视图获取提供商数据源的绑定
    @Binding var providers: [Provider]
    
    var body: some View {
        List {
            ForEach($providers) { $provider in
                // 仅显示那些至少有一个已保存（激活）模型的提供商
                if !provider.models.isEmpty {
                    Section(header: Text(provider.name)) {
                        ForEach($provider.models) { $model in
                            NavigationLink(destination: ModelBehaviorSettingsView(model: $model, onSave: {
                                // 当子视图保存参数时，我们在这里接收到通知
                                // 1. 保存整个提供商的配置到磁盘
                                ConfigLoader.saveProvider(provider)
                                // 2. 通知 ChatService 重新从磁盘加载所有配置，实现热重载
                                ChatService.shared.reloadProviders()
                            })) {
                                Text(model.displayName)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("模型行为配置")
    }
}