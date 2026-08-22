// ============================================================================
// ProviderEditView.swift
// ============================================================================
// ProviderEditView 界面 (iOS)
// - 负责该功能在 iOS 端的交互与展示
// - 遵循项目现有视图结构与状态流
// ============================================================================

import SwiftUI
import Foundation
import ETOSCore

struct ProviderEditView: View {
    @Environment(\.dismiss) private var dismiss
    
    @State private var provider: Provider
    @State private var apiKeysText: String
    @State private var headerOverrideEntries: [HeaderOverrideEntry]
    @State private var useProviderProxyOverride: Bool
    @State private var providerProxyConfiguration: NetworkProxyConfiguration
    @State private var showApiKeys: Bool = false
    @State private var showProxyPassword: Bool = false
    @State private var showUnsavedChangesAlert = false
    let isNew: Bool
    let dismissAfterSave: Bool
    let showsCancelButton: Bool
    let navigationTitleOverride: String?
    let saveRequest: Int
    let showsToolbarSaveButton: Bool
    let onSaveAvailabilityChange: (Bool) -> Void
    let onUnsavedChangesChange: (Bool) -> Void
    let onSave: (Provider) -> Void
    private let savedProvider: Provider
    private let savedApiKeysText: String
    private let savedHeaderOverrideTexts: [String]
    private let savedUseProviderProxyOverride: Bool
    private let savedProviderProxyConfiguration: NetworkProxyConfiguration
    private var isLocalProvider: Bool {
        LocalModelProviderBridge.isLocalProvider(provider)
    }
    
    init(
        provider: Provider,
        isNew: Bool = false,
        dismissAfterSave: Bool = true,
        showsCancelButton: Bool = true,
        navigationTitleOverride: String? = nil,
        saveRequest: Int = 0,
        showsToolbarSaveButton: Bool = true,
        onSaveAvailabilityChange: @escaping (Bool) -> Void = { _ in },
        onUnsavedChangesChange: @escaping (Bool) -> Void = { _ in },
        onSave: @escaping (Provider) -> Void = { _ in }
    ) {
        _provider = State(initialValue: provider)
        let apiKeysText = provider.apiKeys.joined(separator: ",")
        _apiKeysText = State(initialValue: apiKeysText)
        let serializedHeaders = HeaderExpressionParser.serialize(headers: provider.headerOverrides)
        let headerOverrideTexts = serializedHeaders.isEmpty ? [""] : serializedHeaders
        _headerOverrideEntries = State(initialValue: serializedHeaders.isEmpty
            ? [HeaderOverrideEntry(text: "")]
            : serializedHeaders.map { HeaderOverrideEntry(text: $0) })
        let useProviderProxyOverride = provider.proxyConfiguration != nil
        let providerProxyConfiguration = provider.proxyConfiguration ?? NetworkProxyConfiguration()
        _useProviderProxyOverride = State(initialValue: useProviderProxyOverride)
        _providerProxyConfiguration = State(initialValue: providerProxyConfiguration)
        self.isNew = isNew
        self.dismissAfterSave = dismissAfterSave
        self.showsCancelButton = showsCancelButton
        self.navigationTitleOverride = navigationTitleOverride
        self.saveRequest = saveRequest
        self.showsToolbarSaveButton = showsToolbarSaveButton
        self.onSaveAvailabilityChange = onSaveAvailabilityChange
        self.onUnsavedChangesChange = onUnsavedChangesChange
        self.onSave = onSave
        self.savedProvider = provider
        self.savedApiKeysText = apiKeysText
        self.savedHeaderOverrideTexts = headerOverrideTexts
        self.savedUseProviderProxyOverride = useProviderProxyOverride
        self.savedProviderProxyConfiguration = providerProxyConfiguration
    }
    
    var body: some View {
        let preview = headerOverridesPreview

        Form {
            Section(header: Text(NSLocalizedString("基础信息", comment: "")), footer: Text(apiBaseURLHint)) {
                TextField(NSLocalizedString("提供商名称", comment: ""), text: $provider.name)
                TextField(NSLocalizedString("API 地址", comment: ""), text: $provider.baseURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if showsChatEndpointPathField {
                    TextField(NSLocalizedString("聊天端点后缀", comment: "Provider chat endpoint path field"), text: $provider.chatEndpointPath)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Picker(NSLocalizedString("API 格式", comment: ""), selection: $provider.apiFormat) {
                    Text(NSLocalizedString("OpenAI 兼容", comment: "")).tag("openai-compatible")
                    Text(NSLocalizedString("OpenAI Responses", comment: "")).tag("openai-responses")
                    Text(NSLocalizedString("Gemini", comment: "Provider API format")).tag("gemini")
                    Text(NSLocalizedString("Anthropic", comment: "Provider API format")).tag("anthropic")
                }
                .disabled(isLocalProvider)
            }
            
            Section(header: Text(NSLocalizedString("认证", comment: "")), footer: Text(apiKeysHint)) {
                Group {
                    if showApiKeys {
                        TextField(NSLocalizedString("API Key", comment: "Provider API key field"), text: $apiKeysText)
                    } else {
                        SecureField(NSLocalizedString("API Key", comment: "Provider API key field"), text: $apiKeysText)
                    }
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                
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
                        Text(NSLocalizedString("HTTP / HTTPS", comment: "HTTP proxy type")).tag(NetworkProxyType.http)
                        Text(NSLocalizedString("SOCKS5", comment: "SOCKS5 proxy type")).tag(NetworkProxyType.socks5)
                    }

                    TextField(NSLocalizedString("代理地址", comment: ""), text: $providerProxyConfiguration.host)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    TextField(NSLocalizedString("端口", comment: ""), value: $providerProxyConfiguration.port, formatter: numberFormatter)
                        .keyboardType(.numberPad)
                        .onChange(of: providerProxyConfiguration.port) { _, newValue in
                            let clamped = max(1, min(65535, newValue))
                            if clamped != newValue {
                                providerProxyConfiguration.port = clamped
                            }
                        }

                    TextField(NSLocalizedString("用户名（可选）", comment: ""), text: $providerProxyConfiguration.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Group {
                        if showProxyPassword {
                            TextField(NSLocalizedString("密码（可选）", comment: ""), text: $providerProxyConfiguration.password)
                        } else {
                            SecureField(NSLocalizedString("密码（可选）", comment: ""), text: $providerProxyConfiguration.password)
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

                Button {
                    addHeaderOverrideEntry()
                } label: {
                    Label(NSLocalizedString("添加表达式", comment: ""), systemImage: "plus")
                }
            }

            Section(header: Text(NSLocalizedString("请求头预览", comment: ""))) {
                Text(preview.text)
                    .etFont(.footnote.monospaced())
                    .foregroundStyle(preview.isPlaceholder ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

        }
        .navigationTitle(navigationTitle)
        .navigationBarBackButtonHidden(hasUnsavedChanges)
        .toolbar {
            if showsCancelButton {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        requestDismiss()
                    } label: {
                        if hasUnsavedChanges {
                            Image(systemName: "chevron.left")
                        } else {
                            Text(NSLocalizedString("取消", comment: ""))
                        }
                    }
                    .accessibilityLabel(NSLocalizedString("返回", comment: ""))
                }
            }
            if showsToolbarSaveButton {
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("保存", comment: "")) {
                        saveProvider()
                    }
                    .disabled(isSaveDisabled)
                }
            }
        }
        .alert(NSLocalizedString("未保存更改", comment: "Unsaved changes alert title"), isPresented: $showUnsavedChangesAlert) {
            if !isSaveDisabled {
                Button(NSLocalizedString("保存并离开", comment: "Save and leave button")) {
                    saveProvider()
                }
            }
            Button(NSLocalizedString("放弃更改", comment: "Discard changes button"), role: .destructive) {
                dismiss()
            }
            Button(NSLocalizedString("继续编辑", comment: "Continue editing button"), role: .cancel) {}
        } message: {
            Text(NSLocalizedString("要保存当前编辑内容，还是放弃更改并离开？", comment: "Generic unsaved changes alert message"))
        }
        .onAppear {
            notifySaveAvailability()
            notifyUnsavedChanges()
        }
        .onChange(of: saveRequest) { _, _ in
            guard !isSaveDisabled else {
                notifySaveAvailability()
                return
            }
            saveProvider()
        }
        .onChange(of: isSaveDisabled) { _, _ in
            notifySaveAvailability()
        }
        .onChange(of: hasUnsavedChanges) { _, _ in
            notifyUnsavedChanges()
        }
        .guidePageContext(
            descriptor: GuidePageDescriptor(
                id: providerGuidePageID,
                title: NSLocalizedString("提供商配置", comment: "提供商配置向导上下文标题"),
                documents: [GuideDocumentReference(id: "provider-model-basics", title: "Provider and Model Basics")],
                tools: [GuidePageTool(definition: GuideToolCatalog.updateProviderConfiguration, access: .proposeChange)]
            ),
            snapshot: providerGuideSnapshot,
            buildProposal: buildProviderGuideProposal,
            execute: executeProviderGuideProposal
        )
    }

    private var providerGuidePageID: GuidePageID {
        GuidePageID(rawValue: "provider-configuration-\(provider.id)")
    }
    
    private func saveProvider() {
        guard persistProviderEdits() else { return }
        if dismissAfterSave {
            dismiss()
        }
    }

    @discardableResult
    private func persistProviderEdits() -> Bool {
        guard let headerOverrides = buildHeaderOverrides() else {
            notifySaveAvailability()
            return false
        }
        var updated = provider
        updated.chatEndpointPath = Provider.normalizedChatEndpointPath(updated.chatEndpointPath)
        updated.apiKeys = parsedApiKeys
        updated.headerOverrides = headerOverrides
        updated.proxyConfiguration = useProviderProxyOverride ? normalizedProxyConfiguration(providerProxyConfiguration) : nil
        ChatService.shared.saveProviderFromManagement(updated)
        provider = updated
        onSave(updated)
        notifySaveAvailability()
        onUnsavedChangesChange(false)
        return true
    }

    private func providerGuideSnapshot() async -> GuidePageSnapshot {
        GuidePageSnapshot(fields: [
            "name": GuideSnapshotField(
                label: NSLocalizedString("提供商名称", comment: "提供商向导快照字段"),
                value: .string(provider.name)
            ),
            "base_url": GuideSnapshotField(
                label: NSLocalizedString("API 地址", comment: "提供商向导快照字段"),
                value: .string(provider.baseURL)
            ),
            "chat_endpoint_path": GuideSnapshotField(
                label: NSLocalizedString("聊天端点后缀", comment: "提供商向导快照字段"),
                value: .string(provider.chatEndpointPath)
            ),
            "api_format": GuideSnapshotField(
                label: NSLocalizedString("API 格式", comment: "提供商向导快照字段"),
                value: .string(provider.apiFormat)
            ),
            "api_key": GuideSnapshotField(
                label: NSLocalizedString("API Key", comment: "提供商向导快照字段"),
                value: .string(apiKeysText),
                access: .writeOnly
            ),
            "uses_provider_proxy": GuideSnapshotField(
                label: NSLocalizedString("使用独立代理", comment: "提供商向导快照字段"),
                value: .bool(useProviderProxyOverride),
                access: .readOnly
            )
        ])
    }

    private func buildProviderGuideProposal(
        call: InternalToolCall,
        snapshot: GuidePageSnapshot
    ) throws -> GuideActionProposal {
        guard call.toolName == GuideToolCatalog.updateProviderConfiguration.name else {
            throw GuideError.unsupportedTool(call.toolName)
        }
        let arguments = try GuideToolArguments.decode(call.arguments)
        if let format = try GuideToolArguments.optionalString("api_format", in: arguments),
           !["openai-compatible", "openai-responses", "gemini", "anthropic"].contains(format) {
            throw GuideError.invalidToolArguments
        }

        let labels: [String: String] = [
            "name": NSLocalizedString("提供商名称", comment: "提供商向导修改字段"),
            "base_url": NSLocalizedString("API 地址", comment: "提供商向导修改字段"),
            "chat_endpoint_path": NSLocalizedString("聊天端点后缀", comment: "提供商向导修改字段"),
            "api_format": NSLocalizedString("API 格式", comment: "提供商向导修改字段"),
            "api_key": NSLocalizedString("API Key", comment: "提供商向导修改字段")
        ]
        try GuideToolArguments.requireOnlyKeys(Set(labels.keys), in: arguments)
        _ = try GuideToolArguments.optionalString("name", in: arguments)
        _ = try GuideToolArguments.optionalString("base_url", in: arguments)
        _ = try GuideToolArguments.optionalString("chat_endpoint_path", in: arguments)
        _ = try GuideToolArguments.optionalString("api_format", in: arguments)
        _ = try GuideToolArguments.optionalString("api_key", in: arguments)
        let mutations = labels.compactMap { key, label -> GuideSettingMutation? in
            guard let newValue = arguments[key] else { return nil }
            let sensitive = key == "api_key"
            let oldValue = snapshot.fields[key]?.value
            guard sensitive || oldValue != newValue else { return nil }
            return GuideSettingMutation(
                path: key,
                label: label,
                oldValue: oldValue,
                newValue: newValue,
                isSensitive: sensitive
            )
        }
        guard !mutations.isEmpty else { throw GuideError.invalidToolArguments }
        return GuideActionProposal(
            pageID: providerGuidePageID,
            toolCallID: call.id,
            toolName: call.toolName,
            summary: NSLocalizedString("修改提供商配置", comment: "提供商向导提案摘要"),
            mutations: mutations,
            arguments: arguments
        )
    }

    private func executeProviderGuideProposal(_ proposal: GuideActionProposal) async throws -> GuideActionExecution {
        guard proposal.toolName == GuideToolCatalog.updateProviderConfiguration.name else {
            throw GuideError.unsupportedTool(proposal.toolName)
        }
        let originalProvider = provider
        let originalAPIKeysText = apiKeysText
        let oldArguments = currentProviderGuideArguments(for: proposal.arguments.keys)

        do {
            if let value = try GuideToolArguments.optionalString("name", in: proposal.arguments) { provider.name = value }
            if let value = try GuideToolArguments.optionalString("base_url", in: proposal.arguments) { provider.baseURL = value }
            if let value = try GuideToolArguments.optionalString("chat_endpoint_path", in: proposal.arguments) {
                provider.chatEndpointPath = value
            }
            if let value = try GuideToolArguments.optionalString("api_format", in: proposal.arguments) { provider.apiFormat = value }
            if let value = try GuideToolArguments.optionalString("api_key", in: proposal.arguments) { apiKeysText = value }
            guard !isSaveDisabled else { throw GuideError.invalidToolArguments }
        } catch {
            provider = originalProvider
            apiKeysText = originalAPIKeysText
            throw error
        }

        let undoSnapshot = await providerGuideSnapshot()
        let undoCall = InternalToolCall(
            id: UUID().uuidString,
            toolName: proposal.toolName,
            arguments: GuideToolArguments.encodedResult(.dictionary(oldArguments))
        )
        let undoProposal = try buildProviderGuideProposal(call: undoCall, snapshot: undoSnapshot)
        guard persistProviderEdits() else {
            provider = originalProvider
            apiKeysText = originalAPIKeysText
            throw GuideError.invalidToolArguments
        }
        return GuideActionExecution(
            message: NSLocalizedString("已保存提供商配置。", comment: "提供商向导执行结果"),
            undoProposal: undoProposal
        )
    }

    private func currentProviderGuideArguments(for keys: Dictionary<String, JSONValue>.Keys) -> [String: JSONValue] {
        var values: [String: JSONValue] = [:]
        for key in keys {
            switch key {
            case "name": values[key] = .string(provider.name)
            case "base_url": values[key] = .string(provider.baseURL)
            case "chat_endpoint_path": values[key] = .string(provider.chatEndpointPath)
            case "api_format": values[key] = .string(provider.apiFormat)
            case "api_key": values[key] = .string(apiKeysText)
            default: break
            }
        }
        return values
    }

    private var hasUnsavedChanges: Bool {
        provider != savedProvider ||
        apiKeysText != savedApiKeysText ||
        headerOverrideEntries.map(\.text) != savedHeaderOverrideTexts ||
        useProviderProxyOverride != savedUseProviderProxyOverride ||
        providerProxyConfiguration != savedProviderProxyConfiguration
    }

    private func requestDismiss() {
        if hasUnsavedChanges {
            showUnsavedChangesAlert = true
        } else {
            dismiss()
        }
    }

    private var navigationTitle: String {
        navigationTitleOverride ?? (isNew ? NSLocalizedString("添加提供商", comment: "") : NSLocalizedString("编辑提供商", comment: ""))
    }

    private var apiBaseURLHint: String {
        if isLocalProvider {
            return NSLocalizedString("本地提供商只用于模型管理和排序；API 地址、认证、请求头和代理会被保留但不会参与本地推理。", comment: "Local provider base URL hint")
        }
        switch provider.apiFormat {
        case "gemini":
            return NSLocalizedString("API 地址应为基础地址，例如: https://generativelanguage.googleapis.com/v1beta", comment: "")
        case "anthropic":
            return NSLocalizedString("API 地址应为基础地址，例如: https://api.anthropic.com/v1", comment: "")
        case "openai-responses":
            return NSLocalizedString("API 地址应为基础地址，例如: https://api.openai.com/v1；聊天请求会使用 Responses API。", comment: "")
        case "openai-compatible":
            return NSLocalizedString("API 地址应为基础地址，例如: https://api.openai.com/v1；聊天端点后缀会拼接在其后。", comment: "OpenAI-compatible base URL hint")
        default:
            return NSLocalizedString("API 地址应为基础地址，例如: https://api.openai.com/v1", comment: "")
        }
    }

    private var showsChatEndpointPathField: Bool {
        !isLocalProvider && provider.apiFormat == "openai-compatible"
    }

    private var apiKeysHint: String {
        if isLocalProvider {
            return NSLocalizedString("本地推理不会读取 API Key。这里保留字段只是为了沿用提供商配置界面。", comment: "Local provider API key hint")
        }
        return NSLocalizedString("多个 API Key 用英文逗号分隔。", comment: "")
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
        (!isLocalProvider && parsedApiKeys.isEmpty) ||
        providerProxyValidationError != nil ||
        headerOverrideEntries.contains { $0.error != nil }
    }

    private func notifySaveAvailability() {
        onSaveAvailabilityChange(!isSaveDisabled)
    }

    private func notifyUnsavedChanges() {
        onUnsavedChangesChange(hasUnsavedChanges)
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
        VStack(alignment: .leading, spacing: 6) {
            TextField(NSLocalizedString("请求头表达式，例如 User-Agent=Mozilla/5.0", comment: ""), text: $entry.text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .etFont(.body.monospaced())

            if let error = entry.error {
                Text(error)
                    .etFont(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }
}
