// ============================================================================
// ProviderEditView.swift
// ============================================================================
// ETOS LLM Studio Watch App 提供商编辑视图
//
// 定义内容:
// - 提供一个表单用于添加或编辑单个 API 提供商的配置
// - 包括名称、API 地址、API Key 等
// ============================================================================

import SwiftUI
import Shared

struct ProviderEditView: View {
    @Environment(\.dismiss) private var dismiss
    
    // 正在编辑的提供商
    @State private var provider: Provider
    // 将第一个 API Key 单独作为状态，以方便绑定
    @State private var apiKey: String
    
    var isNew: Bool
    
    init(provider: Provider, isNew: Bool = false) {
        self._provider = State(initialValue: provider)
        self._apiKey = State(initialValue: provider.apiKeys.first ?? "")
        self.isNew = isNew
    }
    
    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("基础信息"), footer: Text("API 地址应为基础地址，例如: https://api.openai.com/v1")) {
                    TextField("提供商名称", text: $provider.name)
                    TextField("API 地址", text: $provider.baseURL)
                        .font(.caption)
                    Picker("API 格式", selection: $provider.apiFormat) {
                        Text("OpenAI 兼容").tag("openai-compatible")
                    }
                }
                
                Section(header: Text("认证"), footer: Text("手表端仅支持编辑第一个 API Key。")) {
                    TextField("API Key", text: $apiKey)
                }
                
                Section {
                    Button("保存", action: saveProvider)
                }
            }
            .navigationTitle(isNew ? "添加提供商" : "编辑提供商")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }
    
    private func saveProvider() {
        // 保存前更新 apiKeys 数组
        provider.apiKeys = [apiKey]
        
        // 持久化更改
        ConfigLoader.saveProvider(provider)
        
        // 重新加载服务以更新整个应用的 UI
        ChatService.shared.reloadProviders()
        
        dismiss()
    }
}