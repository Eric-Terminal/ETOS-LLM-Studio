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
import Foundation
import Shared

struct ProviderEditView: View {
    @Environment(\.dismiss) private var dismiss
    
    // 正在编辑的提供商
    @State private var provider: Provider
    // 保存 API Key 文本，多个 key 用英文逗号分隔
    @State private var apiKeysText: String
    @State private var headerOverrideEntries: [HeaderOverrideEntry]
    @State private var useProviderProxyOverride: Bool
    @State private var providerProxyConfiguration: NetworkProxyConfiguration
    @State private var showApiKeys: Bool = false
    @State private var showProxyPassword: Bool = false
    
    var isNew: Bool
    
    init(provider: Provider, isNew: Bool = false) {
        self._provider = State(initialValue: provider)
        self._apiKeysText = State(initialValue: provider.apiKeys.joined(separator: ","))
        let serializedHeaders = HeaderExpressionParser.serialize(headers: provider.headerOverrides)
        self._headerOverrideEntries = State(initialValue: serializedHeaders.isEmpty
            ? [HeaderOverrideEntry(text: "")]
            : serializedHeaders.map { HeaderOverrideEntry(text: $0) })
        self._useProviderProxyOverride = State(initialValue: provider.proxyConfiguration != nil)
        self._providerProxyConfiguration = State(initialValue: provider.proxyConfiguration ?? NetworkProxyConfiguration())
        self.isNew = isNew
    }
    
    var body: some View {
        let preview = headerOverridesPreview

        Form {
            Section(header: Text(NSLocalizedString("基础信息", comment: "")), footer: Text(apiBaseURLHint)) {
                TextField(NSLocalizedString("提供商名称", comment: ""), text: $provider.name.watchKeyboardNewlineBinding())
                TextField(NSLocalizedString("API 地址", comment: ""), text: $provider.baseURL.watchKeyboardNewlineBinding())
                    .etFont(.caption)
                Picker(NSLocalizedString("API 格式", comment: ""), selection: $provider.apiFormat) {
                    Text(NSLocalizedString("OpenAI 兼容", comment: "")).tag("openai-compatible")
                    Text("Gemini").tag("gemini")
                    Text("Anthropic").tag("anthropic")
                }
            }
            
            Section(header: Text(NSLocalizedString("认证", comment: "")), footer: Text(apiKeysHint)) {
                Group {
                    if showApiKeys {
                        TextField("API Key", text: $apiKeysText.watchKeyboardNewlineBinding())
                    } else {
                        SecureField("API Key", text: $apiKeysText.watchKeyboardNewlineBinding())
                    }
                }
                
                Toggle(NSLocalizedString("显示明文", comment: ""), isOn: $showApiKeys)
            }

            Section(
                header: Text(NSLocalizedString("代理（提供商级）", comment: "")),
                footer: Text(providerProxyFooterText)
            ) {
                Toggle(NSLocalizedString("使用独立代理（优先于全局）", comment: ""), isOn: $useProviderProxyOverride)

                if useProviderProxyOverride {
                    Toggle(NSLocalizedString("启用代理", comment: ""), isOn: $providerProxyConfiguration.isEnabled)

                    Picker(NSLocalizedString("代理类型", comment: ""), selection: $providerProxyConfiguration.type) {
                        Text("HTTP / HTTPS").tag(NetworkProxyType.http)
                        Text("SOCKS5").tag(NetworkProxyType.socks5)
                    }

                    TextField(NSLocalizedString("代理地址", comment: ""), text: $providerProxyConfiguration.host.watchKeyboardNewlineBinding())
                        .etFont(.caption)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    TextField(NSLocalizedString("端口", comment: ""), value: $providerProxyConfiguration.port, formatter: numberFormatter)
                        .multilineTextAlignment(.trailing)
                        .onChange(of: providerProxyConfiguration.port) { _, newValue in
                            let clamped = max(1, min(65535, newValue))
                            if clamped != newValue {
                                providerProxyConfiguration.port = clamped
                            }
                        }

                    TextField(NSLocalizedString("用户名（可选）", comment: ""), text: $providerProxyConfiguration.username.watchKeyboardNewlineBinding())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Group {
                        if showProxyPassword {
                            TextField(NSLocalizedString("密码（可选）", comment: ""), text: $providerProxyConfiguration.password.watchKeyboardNewlineBinding())
                        } else {
                            SecureField(NSLocalizedString("密码（可选）", comment: ""), text: $providerProxyConfiguration.password.watchKeyboardNewlineBinding())
                        }
                    }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                    Toggle(NSLocalizedString("显示代理密码", comment: ""), isOn: $showProxyPassword)
                }
            }

            Section(header: Text(NSLocalizedString("请求头覆盖", comment: "")), footer: Text(headerOverridesHint)) {
                ForEach($headerOverrideEntries) { $entry in
                    HeaderOverrideRow(entry: $entry)
                        .onChange(of: entry.text) { _, _ in
                            validateHeaderOverrideEntry(withId: entry.id)
                        }
                }
                .onDelete(perform: deleteHeaderOverrideEntries)

                Button(NSLocalizedString("添加表达式", comment: "")) {
                    addHeaderOverrideEntry()
                }
            }

            Section(header: Text(NSLocalizedString("请求头预览", comment: ""))) {
                Text(preview.text)
                    .etFont(.footnote.monospaced())
                    .foregroundStyle(preview.isPlaceholder ? .secondary : .primary)
            }
            
            Section {
                Button(NSLocalizedString("保存", comment: ""), action: saveProvider)
                    .disabled(isSaveDisabled)
            }
        }
        .navigationTitle(isNew ? NSLocalizedString("添加提供商", comment: "") : NSLocalizedString("编辑提供商", comment: ""))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(NSLocalizedString("取消", comment: "")) { dismiss() }
            }
        }
    }
    
    private func saveProvider() {
        guard let headerOverrides = buildHeaderOverrides() else { return }
        // 保存前更新 apiKeys 数组
        provider.apiKeys = parsedApiKeys
        provider.headerOverrides = headerOverrides
        provider.proxyConfiguration = useProviderProxyOverride ? normalizedProxyConfiguration(providerProxyConfiguration) : nil
        
        // 持久化更改
        ConfigLoader.saveProvider(provider)
        
        // 重新加载服务以更新整个应用的 UI
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

    private var numberFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }

    private var providerProxyFooterText: String {
        if !useProviderProxyOverride {
            return NSLocalizedString("未设置独立代理时，将自动使用全局代理配置。", comment: "")
        }
        if let validationError = providerProxyValidationError {
            return validationError
        }
        return NSLocalizedString("支持 HTTP / HTTPS 和 SOCKS5。填写用户名后会自动启用代理鉴权。", comment: "")
    }

    private var providerProxyValidationError: String? {
        guard useProviderProxyOverride, providerProxyConfiguration.isEnabled else { return nil }
        let host = providerProxyConfiguration.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else {
            return NSLocalizedString("已启用独立代理，但代理地址为空。", comment: "")
        }
        guard (1...65535).contains(providerProxyConfiguration.port) else {
            return NSLocalizedString("代理端口必须在 1~65535 之间。", comment: "")
        }
        return nil
    }

    private var headerOverridesHint: String {
        NSLocalizedString("使用 key=value 添加或覆盖请求头，例如: User-Agent=Mozilla/5.0 (Windows NT 10.0; Win64; x64)。\n{api_key} 会替换为当前 API Key，例如: Authorization=Bearer {api_key}", comment: "")
    }

    private var parsedApiKeys: [String] {
        apiKeysText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private var isSaveDisabled: Bool {
        provider.name.isEmpty ||
        provider.baseURL.isEmpty ||
        parsedApiKeys.isEmpty ||
        providerProxyValidationError != nil ||
        headerOverrideEntries.contains { $0.error != nil }
    }

    private func normalizedProxyConfiguration(_ configuration: NetworkProxyConfiguration) -> NetworkProxyConfiguration {
        NetworkProxyConfiguration(
            isEnabled: configuration.isEnabled,
            type: configuration.type,
            host: configuration.host.trimmingCharacters(in: .whitespacesAndNewlines),
            port: max(1, min(65535, configuration.port)),
            username: configuration.username.trimmingCharacters(in: .whitespacesAndNewlines),
            password: configuration.password
        )
    }

    private func addHeaderOverrideEntry() {
        headerOverrideEntries.append(HeaderOverrideEntry(text: ""))
    }

    private func deleteHeaderOverrideEntries(at offsets: IndexSet) {
        headerOverrideEntries.remove(atOffsets: offsets)
        if headerOverrideEntries.isEmpty {
            addHeaderOverrideEntry()
        }
    }

    private func validateHeaderOverrideEntry(withId id: UUID) {
        guard let index = headerOverrideEntries.firstIndex(where: { $0.id == id }) else { return }
        var entry = headerOverrideEntries[index]
        let trimmed = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            entry.error = nil
            headerOverrideEntries[index] = entry
            return
        }

        do {
            _ = try HeaderExpressionParser.parse(trimmed)
            entry.error = nil
        } catch {
            entry.error = error.localizedDescription
        }
        headerOverrideEntries[index] = entry
    }

    private func buildHeaderOverrides() -> [String: String]? {
        var updatedEntries = headerOverrideEntries
        var parsedExpressions: [HeaderExpressionParser.ParsedExpression] = []
        var hasError = false

        for index in updatedEntries.indices {
            let trimmed = updatedEntries[index].text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                updatedEntries[index].error = nil
                continue
            }

            do {
                let parsed = try HeaderExpressionParser.parse(trimmed)
                parsedExpressions.append(parsed)
                updatedEntries[index].error = nil
            } catch {
                updatedEntries[index].error = error.localizedDescription
                hasError = true
            }
        }

        headerOverrideEntries = updatedEntries
        if hasError {
            return nil
        }
        return HeaderExpressionParser.buildHeaders(from: parsedExpressions)
    }

    private var headerOverridesPreview: HeaderOverridesPreview {
        let result = previewHeaderOverrides()
        if result.hasError {
            return HeaderOverridesPreview(
                text: NSLocalizedString("表达式有误，无法预览", comment: ""),
                isPlaceholder: true
            )
        }
        if result.headers.isEmpty {
            return HeaderOverridesPreview(
                text: NSLocalizedString("暂无请求头表达式", comment: ""),
                isPlaceholder: true
            )
        }
        return HeaderOverridesPreview(
            text: prettyPrintedJSON(result.headers),
            isPlaceholder: false
        )
    }

    private func previewHeaderOverrides() -> (headers: [String: String], hasError: Bool) {
        var headers: [String: String] = [:]
        var hasError = false

        for entry in headerOverrideEntries {
            let trimmed = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            do {
                let parsed = try HeaderExpressionParser.parse(trimmed)
                headers[parsed.key] = parsed.value
            } catch {
                hasError = true
            }
        }

        return (headers: headers, hasError: hasError)
    }

    private func prettyPrintedJSON(_ headers: [String: String]) -> String {
        guard JSONSerialization.isValidJSONObject(headers),
              let data = try? JSONSerialization.data(withJSONObject: headers, options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "\(headers)"
        }
        return string
    }
}

private struct HeaderOverridesPreview {
    let text: String
    let isPlaceholder: Bool
}

private struct HeaderOverrideEntry: Identifiable, Equatable {
    let id: UUID
    var text: String
    var error: String?

    init(id: UUID = UUID(), text: String, error: String? = nil) {
        self.id = id
        self.text = text
        self.error = error
    }
}

private struct HeaderOverrideRow: View {
    @Binding var entry: HeaderOverrideEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(NSLocalizedString("请求头表达式，例如 User-Agent=Mozilla/5.0", comment: ""), text: $entry.text.watchKeyboardNewlineBinding())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .etFont(.footnote.monospaced())

            if let error = entry.error {
                Text(error)
                    .etFont(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }
}
