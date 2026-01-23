import SwiftUI
import Shared

struct ProviderEditView: View {
    @Environment(\.dismiss) private var dismiss
    
    @State private var provider: Provider
    @State private var apiKey: String
    let isNew: Bool
    
    init(provider: Provider, isNew: Bool = false) {
        _provider = State(initialValue: provider)
        _apiKey = State(initialValue: provider.apiKeys.first ?? "")
        self.isNew = isNew
    }
    
    var body: some View {
        Form {
            Section(header: Text("基础信息"), footer: Text(apiBaseURLHint)) {
                TextField("提供商名称", text: $provider.name)
                TextField("API 地址", text: $provider.baseURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Picker("API 格式", selection: $provider.apiFormat) {
                    Text("OpenAI 兼容").tag("openai-compatible")
                    Text("Gemini").tag("gemini")
                    Text("Anthropic").tag("anthropic")
                }
            }
            
            Section("认证") {
                SecureField("API Key", text: $apiKey)
            }
        }
        .navigationTitle(isNew ? "添加提供商" : "编辑提供商")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    saveProvider()
                }
                .disabled(provider.name.isEmpty || provider.baseURL.isEmpty || apiKey.isEmpty)
            }
        }
    }
    
    private func saveProvider() {
        var updated = provider
        updated.apiKeys = [apiKey]
        ConfigLoader.saveProvider(updated)
        ChatService.shared.reloadProviders()
        dismiss()
    }

    private var apiBaseURLHint: String {
        switch provider.apiFormat {
        case "gemini":
            return NSLocalizedString("API 地址应为基础地址，例如: https://generativelanguage.googleapis.com/v1beta", comment: "")
        case "anthropic":
            return NSLocalizedString("API 地址应为基础地址，例如: https://api.anthropic.com/v1", comment: "")
        default:
            return NSLocalizedString("API 地址应为基础地址，例如: https://api.openai.com/v1", comment: "")
        }
    }
}
