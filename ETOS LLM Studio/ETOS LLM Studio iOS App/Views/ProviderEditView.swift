import SwiftUI
import Shared

struct ProviderEditView: View {
    @Environment(\.dismiss) private var dismiss
    
    @State private var provider: Provider
    @State private var apiKeysText: String
    @State private var showApiKeys: Bool = false
    let isNew: Bool
    
    init(provider: Provider, isNew: Bool = false) {
        _provider = State(initialValue: provider)
        _apiKeysText = State(initialValue: provider.apiKeys.joined(separator: ","))
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
            
            Section(header: Text("认证"), footer: Text(apiKeysHint)) {
                Group {
                    if showApiKeys {
                        TextField("API Key", text: $apiKeysText)
                    } else {
                        SecureField("API Key", text: $apiKeysText)
                    }
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                
                Toggle("显示明文", isOn: $showApiKeys)
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
                .disabled(provider.name.isEmpty || provider.baseURL.isEmpty || parsedApiKeys.isEmpty)
            }
        }
    }
    
    private func saveProvider() {
        var updated = provider
        updated.apiKeys = parsedApiKeys
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

    private var apiKeysHint: String {
        NSLocalizedString("多个 API Key 用英文逗号分隔。", comment: "")
    }

    private var parsedApiKeys: [String] {
        apiKeysText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
