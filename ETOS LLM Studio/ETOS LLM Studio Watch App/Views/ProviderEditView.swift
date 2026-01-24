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
    // 保存 API Key 文本，多个 key 用英文逗号分隔
    @State private var apiKeysText: String
    @State private var headerOverrideEntries: [HeaderOverrideEntry]
    @State private var showApiKeys: Bool = false
    
    var isNew: Bool
    
    init(provider: Provider, isNew: Bool = false) {
        self._provider = State(initialValue: provider)
        self._apiKeysText = State(initialValue: provider.apiKeys.joined(separator: ","))
        let serializedHeaders = HeaderExpressionParser.serialize(headers: provider.headerOverrides)
        self._headerOverrideEntries = State(initialValue: serializedHeaders.isEmpty
            ? [HeaderOverrideEntry(text: "")]
            : serializedHeaders.map { HeaderOverrideEntry(text: $0) })
        self.isNew = isNew
    }
    
    var body: some View {
        let preview = headerOverridesPreview

        Form {
            Section(header: Text("基础信息"), footer: Text(apiBaseURLHint)) {
                TextField("提供商名称", text: $provider.name.watchKeyboardNewlineBinding())
                TextField("API 地址", text: $provider.baseURL.watchKeyboardNewlineBinding())
                    .font(.caption)
                Picker("API 格式", selection: $provider.apiFormat) {
                    Text("OpenAI 兼容").tag("openai-compatible")
                    Text("Gemini").tag("gemini")
                    Text("Anthropic").tag("anthropic")
                }
            }
            
            Section(header: Text("认证"), footer: Text(apiKeysHint)) {
                Group {
                    if showApiKeys {
                        TextField("API Key", text: $apiKeysText.watchKeyboardNewlineBinding())
                    } else {
                        SecureField("API Key", text: $apiKeysText.watchKeyboardNewlineBinding())
                    }
                }
                
                Toggle("显示明文", isOn: $showApiKeys)
            }

            Section(header: Text("请求头覆盖"), footer: Text(headerOverridesHint)) {
                ForEach($headerOverrideEntries) { $entry in
                    HeaderOverrideRow(entry: $entry)
                        .onChange(of: entry.text) { _, _ in
                            validateHeaderOverrideEntry(withId: entry.id)
                        }
                }
                .onDelete(perform: deleteHeaderOverrideEntries)

                Button("添加表达式") {
                    addHeaderOverrideEntry()
                }
            }

            Section(header: Text("请求头预览")) {
                Text(preview.text)
                    .font(.footnote.monospaced())
                    .foregroundStyle(preview.isPlaceholder ? .secondary : .primary)
            }
            
            Section {
                Button("保存", action: saveProvider)
                    .disabled(isSaveDisabled)
            }
        }
        .navigationTitle(isNew ? "添加提供商" : "编辑提供商")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
        }
    }
    
    private func saveProvider() {
        guard let headerOverrides = buildHeaderOverrides() else { return }
        // 保存前更新 apiKeys 数组
        provider.apiKeys = parsedApiKeys
        provider.headerOverrides = headerOverrides
        
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
        headerOverrideEntries.contains { $0.error != nil }
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
            TextField("请求头表达式，例如 User-Agent=Mozilla/5.0", text: $entry.text.watchKeyboardNewlineBinding())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.footnote.monospaced())

            if let error = entry.error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }
}
