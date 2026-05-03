// ============================================================================
// MCPIntegrationViewSupport.swift
// ============================================================================
// ETOS LLM Studio
//
// MCP 工具箱的服务器详情与工具设置支撑视图。
// ============================================================================

import SwiftUI
import Foundation
import Shared

// MARK: - Server Detail

private struct MCPServerDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var manager = MCPManager.shared
    let server: MCPServerConfiguration
    @State private var isEditing = false
    @State private var showingDeleteConfirmation = false

    private var status: MCPServerStatus {
        manager.status(for: server)
    }

    var body: some View {
        Form {
            Section(NSLocalizedString("服务器信息", comment: "")) {
                LabeledContent(NSLocalizedString("名称", comment: ""), value: server.displayName)
                LabeledContent("Endpoint", value: server.humanReadableEndpoint)
                if let notes = server.notes {
                    LabeledContent(NSLocalizedString("备注", comment: ""), value: notes)
                }
            }

            Section(NSLocalizedString("连接控制", comment: "")) {
                Button(NSLocalizedString("连接", comment: "")) {
                    manager.connect(to: server)
                }
                .disabled(status.connectionState == .ready || status.connectionState == .connecting || isReconnecting(status.connectionState))

                Button(NSLocalizedString("断开连接", comment: "")) {
                    manager.disconnect(server: server)
                }
                .disabled(status.connectionState == .idle)

                Button(NSLocalizedString("终止远端会话", comment: "")) {
                    Task {
                        await manager.terminateRemoteSession(for: server.id)
                    }
                }
                .disabled(status.connectionState == .idle)

                Toggle(NSLocalizedString("用于聊天", comment: ""), isOn: bindingForSelection())
                    .disabled(status.connectionState == .connecting || isReconnecting(status.connectionState))

                Button(NSLocalizedString("刷新元数据", comment: "")) {
                    manager.refreshMetadata(for: server)
                }
                .disabled(status.connectionState != .ready || status.isBusy)

                if status.isBusy {
                    ProgressView()
                }
            }

            if let info = status.info {
                Section(NSLocalizedString("服务器能力", comment: "")) {
                    Text(info.name + (info.version.map { " \($0)" } ?? ""))
                    if let capabilities = info.capabilities, !capabilities.isEmpty {
                        Text("Capabilities: \(capabilities.keys.joined(separator: ", "))")
                            .etFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if !status.tools.isEmpty {
                Section(
                    String(format: NSLocalizedString("工具 (%d)", comment: ""), status.tools.count)
                ) {
                    ForEach(status.tools) { tool in
                        NavigationLink {
                            MCPToolSettingsDetailView(serverID: server.id, tool: tool)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(tool.toolId)
                                    Spacer()
                                    Text(
                                        manager.isToolEnabled(serverID: server.id, toolId: tool.toolId)
                                        ? NSLocalizedString("已启用", comment: "MCP tool enabled status")
                                        : NSLocalizedString("已停用", comment: "MCP tool disabled status")
                                    )
                                    .etFont(.caption)
                                    .foregroundStyle(
                                        manager.isToolEnabled(serverID: server.id, toolId: tool.toolId)
                                        ? .green
                                        : .secondary
                                    )
                                }
                                if let desc = tool.description {
                                    Text(desc)
                                        .etFont(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                if let schemaSummary = schemaSummary(for: tool.inputSchema) {
                                    Text(String(format: NSLocalizedString("输入 Schema：%@", comment: ""), schemaSummary))
                                        .etFont(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(3)
                                }
                            }
                        }
                    }
                }
            }

            if !status.resources.isEmpty {
                Section(
                    String(format: NSLocalizedString("资源 (%d)", comment: ""), status.resources.count)
                ) {
                    ForEach(status.resources) { resource in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(resource.resourceId)
                            if let desc = resource.description {
                                Text(desc)
                                    .etFont(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(server.displayName)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button(NSLocalizedString("编辑", comment: "")) {
                    isEditing = true
                }
                Button(role: .destructive) {
                    showingDeleteConfirmation = true
                } label: {
                    Image(systemName: "trash")
                }
            }
        }
        .sheet(isPresented: $isEditing) {
            NavigationStack {
                MCPServerEditor(existingServer: server) { updated in
                    manager.save(server: updated)
                }
            }
        }
        .confirmationDialog(NSLocalizedString("确定要删除此服务器？", comment: ""), isPresented: $showingDeleteConfirmation) {
            Button(NSLocalizedString("删除", comment: ""), role: .destructive) {
                manager.delete(server: server)
                dismiss()
            }
            Button(NSLocalizedString("取消", comment: ""), role: .cancel) { }
        }
    }

    private func bindingForSelection() -> Binding<Bool> {
        Binding {
            manager.status(for: server).isSelectedForChat
        } set: { newValue in
            let current = manager.status(for: server).isSelectedForChat
            if newValue != current {
                manager.toggleSelection(for: server)
            }
        }
    }

    private func schemaSummary(for schema: JSONValue?) -> String? {
        guard let schema else { return nil }
        guard case .dictionary(let schemaDict) = schema else {
            return schema.prettyPrintedCompact()
        }
        let typeLabel: String
        if let typeValue = schemaDict["type"], case .string(let typeString) = typeValue {
            typeLabel = typeString
        } else {
            typeLabel = "unknown"
        }
        var segments: [String] = ["type=\(typeLabel)"]
        if let propertiesValue = schemaDict["properties"],
           case .dictionary(let properties) = propertiesValue,
           !properties.isEmpty {
            segments.append("fields=\(properties.keys.sorted().prefix(6).joined(separator: ", "))")
        }
        if let requiredValue = schemaDict["required"],
           case .array(let requiredItems) = requiredValue {
            let requiredKeys = requiredItems.compactMap { item -> String? in
                if case .string(let key) = item { return key }
                return nil
            }
            if !requiredKeys.isEmpty {
                segments.append("required=\(requiredKeys.joined(separator: ", "))")
            }
        }
        return segments.joined(separator: " · ")
    }

    private func isReconnecting(_ state: MCPManager.ConnectionState) -> Bool {
        if case .reconnecting = state {
            return true
        }
        return false
    }
}

private struct MCPToolSettingsDetailView: View {
    let serverID: UUID
    let tool: MCPToolDescription
    @ObservedObject private var manager = MCPManager.shared

    var body: some View {
        List {
            Section(NSLocalizedString("工具信息", comment: "")) {
                Text(tool.toolId)
                    .etFont(.headline)
                if let desc = tool.description, !desc.isEmpty {
                    Text(desc)
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let schemaSummary = schemaSummary(for: tool.inputSchema) {
                    Text("Schema: \(schemaSummary)")
                        .etFont(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(3)
                }
            }

            Section(NSLocalizedString("启用状态", comment: "Enable status")) {
                Toggle(NSLocalizedString("启用", comment: "Enable"), isOn: toolBinding)
            }

            Section(
                header: Text(NSLocalizedString("审批策略", comment: "")),
                footer: Text(NSLocalizedString("默认“每次询问”，可按工具单独设置。", comment: ""))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            ) {
                Picker(NSLocalizedString("审批策略", comment: ""), selection: toolApprovalPolicyBinding) {
                    ForEach(MCPToolApprovalPolicy.allCases, id: \.self) { policy in
                        Text(policy.displayName).tag(policy)
                    }
                }
                .pickerStyle(.menu)
            }
        }
        .navigationTitle(NSLocalizedString("工具设置", comment: ""))
    }

    private var toolBinding: Binding<Bool> {
        Binding {
            manager.isToolEnabled(serverID: serverID, toolId: tool.toolId)
        } set: { newValue in
            manager.setToolEnabled(serverID: serverID, toolId: tool.toolId, isEnabled: newValue)
        }
    }

    private var toolApprovalPolicyBinding: Binding<MCPToolApprovalPolicy> {
        Binding {
            manager.approvalPolicy(serverID: serverID, toolId: tool.toolId)
        } set: { newValue in
            manager.setToolApprovalPolicy(serverID: serverID, toolId: tool.toolId, policy: newValue)
        }
    }

    private func schemaSummary(for schema: JSONValue?) -> String? {
        guard let schema else { return nil }
        guard case .dictionary(let schemaDict) = schema else {
            return schema.prettyPrintedCompact()
        }
        let typeLabel: String
        if let typeValue = schemaDict["type"], case .string(let typeString) = typeValue {
            typeLabel = typeString
        } else {
            typeLabel = "unknown"
        }
        var segments: [String] = ["type=\(typeLabel)"]
        if let propertiesValue = schemaDict["properties"],
           case .dictionary(let properties) = propertiesValue,
           !properties.isEmpty {
            segments.append("fields=\(properties.keys.sorted().prefix(6).joined(separator: ", "))")
        }
        if let requiredValue = schemaDict["required"],
           case .array(let requiredItems) = requiredValue {
            let requiredKeys = requiredItems.compactMap { item -> String? in
                if case .string(let key) = item { return key }
                return nil
            }
            if !requiredKeys.isEmpty {
                segments.append("required=\(requiredKeys.joined(separator: ", "))")
            }
        }
        return segments.joined(separator: " · ")
    }
}

// MARK: - Server Editor

private struct MCPServerEditor: View {
    @Environment(\.dismiss) private var dismiss
    private let existingServer: MCPServerConfiguration?
    private let onSave: (MCPServerConfiguration) -> Void

    @State private var displayName: String
    @State private var endpoint: String
    @State private var sseEndpoint: String
    @State private var apiKey: String
    @State private var tokenEndpoint: String
    @State private var clientID: String
    @State private var clientSecret: String
    @State private var oauthScope: String
    @State private var oauthGrantType: MCPOAuthGrantType
    @State private var oauthAuthorizationCode: String
    @State private var oauthRedirectURI: String
    @State private var oauthCodeVerifier: String
    @State private var transportOption: TransportOption
    @State private var notes: String
    @State private var headerOverrideEntries: [HeaderOverrideEntry]
    @State private var validationMessage: String?

    init(existingServer: MCPServerConfiguration?, onSave: @escaping (MCPServerConfiguration) -> Void) {
        self.existingServer = existingServer
        self.onSave = onSave

        if let server = existingServer {
            _displayName = State(initialValue: server.displayName)
            _notes = State(initialValue: server.notes ?? "")
            switch server.transport {
            case .http(let endpoint, let apiKey, _):
                let serializedHeaders = HeaderExpressionParser.serialize(headers: server.additionalHeaders)
                _endpoint = State(initialValue: endpoint.absoluteString)
                _sseEndpoint = State(initialValue: "")
                _apiKey = State(initialValue: apiKey ?? "")
                _tokenEndpoint = State(initialValue: "")
                _clientID = State(initialValue: "")
                _clientSecret = State(initialValue: "")
                _oauthScope = State(initialValue: "")
                _oauthGrantType = State(initialValue: .clientCredentials)
                _oauthAuthorizationCode = State(initialValue: "")
                _oauthRedirectURI = State(initialValue: "")
                _oauthCodeVerifier = State(initialValue: "")
                _transportOption = State(initialValue: .http)
                _headerOverrideEntries = State(initialValue: serializedHeaders.isEmpty
                    ? [HeaderOverrideEntry(text: "")]
                    : serializedHeaders.map { HeaderOverrideEntry(text: $0) })
            case .httpSSE(_, let sseEndpoint, let apiKey, _):
                let serializedHeaders = HeaderExpressionParser.serialize(headers: server.additionalHeaders)
                _endpoint = State(initialValue: MCPServerConfiguration.inferMessageEndpoint(fromSSE: sseEndpoint).absoluteString)
                _sseEndpoint = State(initialValue: sseEndpoint.absoluteString)
                _apiKey = State(initialValue: apiKey ?? "")
                _tokenEndpoint = State(initialValue: "")
                _clientID = State(initialValue: "")
                _clientSecret = State(initialValue: "")
                _oauthScope = State(initialValue: "")
                _oauthGrantType = State(initialValue: .clientCredentials)
                _oauthAuthorizationCode = State(initialValue: "")
                _oauthRedirectURI = State(initialValue: "")
                _oauthCodeVerifier = State(initialValue: "")
                _transportOption = State(initialValue: .sse)
                _headerOverrideEntries = State(initialValue: serializedHeaders.isEmpty
                    ? [HeaderOverrideEntry(text: "")]
                    : serializedHeaders.map { HeaderOverrideEntry(text: $0) })
            case .oauth(let endpoint, let tokenEndpoint, let clientID, let clientSecret, let scope, let grantType, let authorizationCode, let redirectURI, let codeVerifier):
                _endpoint = State(initialValue: endpoint.absoluteString)
                _sseEndpoint = State(initialValue: "")
                _tokenEndpoint = State(initialValue: tokenEndpoint.absoluteString)
                _clientID = State(initialValue: clientID)
                _clientSecret = State(initialValue: clientSecret ?? "")
                _oauthScope = State(initialValue: scope ?? "")
                _oauthGrantType = State(initialValue: grantType)
                _oauthAuthorizationCode = State(initialValue: authorizationCode ?? "")
                _oauthRedirectURI = State(initialValue: redirectURI ?? "")
                _oauthCodeVerifier = State(initialValue: codeVerifier ?? "")
                _apiKey = State(initialValue: "")
                _transportOption = State(initialValue: .oauth)
                _headerOverrideEntries = State(initialValue: [HeaderOverrideEntry(text: "")])
            @unknown default:
                _endpoint = State(initialValue: "")
                _sseEndpoint = State(initialValue: "")
                _apiKey = State(initialValue: "")
                _tokenEndpoint = State(initialValue: "")
                _clientID = State(initialValue: "")
                _clientSecret = State(initialValue: "")
                _oauthScope = State(initialValue: "")
                _oauthGrantType = State(initialValue: .clientCredentials)
                _oauthAuthorizationCode = State(initialValue: "")
                _oauthRedirectURI = State(initialValue: "")
                _oauthCodeVerifier = State(initialValue: "")
                _transportOption = State(initialValue: .http)
                _headerOverrideEntries = State(initialValue: [HeaderOverrideEntry(text: "")])
            }
        } else {
            _displayName = State(initialValue: "")
            _endpoint = State(initialValue: "")
            _sseEndpoint = State(initialValue: "")
            _apiKey = State(initialValue: "")
            _notes = State(initialValue: "")
            _tokenEndpoint = State(initialValue: "")
            _clientID = State(initialValue: "")
            _clientSecret = State(initialValue: "")
            _oauthScope = State(initialValue: "")
            _oauthGrantType = State(initialValue: .clientCredentials)
            _oauthAuthorizationCode = State(initialValue: "")
            _oauthRedirectURI = State(initialValue: "")
            _oauthCodeVerifier = State(initialValue: "")
            _transportOption = State(initialValue: .http)
            _headerOverrideEntries = State(initialValue: [HeaderOverrideEntry(text: "")])
        }
    }

    var body: some View {
        Form {
            Section(NSLocalizedString("基本信息", comment: "")) {
                TextField(NSLocalizedString("显示名称", comment: ""), text: $displayName)
                Picker(NSLocalizedString("传输类型", comment: ""), selection: $transportOption) {
                    ForEach(TransportOption.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                if transportOption == .sse {
                    TextField("SSE Endpoint", text: $sseEndpoint)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } else {
                    TextField("Streamable HTTP Endpoint", text: $endpoint)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                if transportOption.requiresAPIKey {
                    TextField(NSLocalizedString("Bearer API Key (可选)", comment: ""), text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                if transportOption == .oauth {
                    Picker(NSLocalizedString("授权类型", comment: ""), selection: $oauthGrantType) {
                        Text("Client Credentials").tag(MCPOAuthGrantType.clientCredentials)
                        Text("Authorization Code").tag(MCPOAuthGrantType.authorizationCode)
                    }
                    TextField("OAuth Token Endpoint", text: $tokenEndpoint)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Client ID", text: $clientID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField(NSLocalizedString("Client Secret (可选)", comment: ""), text: $clientSecret)
                    TextField(NSLocalizedString("Scope (可选)", comment: ""), text: $oauthScope)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if oauthGrantType == .authorizationCode {
                        TextField("Authorization Code", text: $oauthAuthorizationCode)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Redirect URI", text: $oauthRedirectURI)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                        TextField(NSLocalizedString("PKCE Code Verifier (可选)", comment: ""), text: $oauthCodeVerifier)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }
                TextEditor(text: $notes)
                    .frame(minHeight: 60)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.2)))
            }

            if transportOption.requiresAPIKey {
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
                    Text(headerOverridesPreview.text)
                        .etFont(.footnote.monospaced())
                        .foregroundStyle(headerOverridesPreview.isPlaceholder ? .secondary : .primary)
                        .textSelection(.enabled)
                }
            }

            if let validationMessage {
                Section {
                    Text(validationMessage)
                        .foregroundStyle(.red)
                        .etFont(.footnote)
                }
            }
        }
        .navigationTitle(existingServer == nil ? NSLocalizedString("新增 MCP Server", comment: "") : NSLocalizedString("编辑 MCP Server", comment: ""))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(NSLocalizedString("取消", comment: "")) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(NSLocalizedString("保存", comment: "")) {
                    saveServer()
                }
                .disabled(isSaveDisabled)
            }
        }
    }

    private func saveServer() {
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let additionalHeaders: [String: String]
        if transportOption.requiresAPIKey {
            guard let builtHeaders = buildHeaderOverrides() else { return }
            additionalHeaders = builtHeaders
        } else {
            additionalHeaders = [:]
        }

        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let transport: MCPServerConfiguration.Transport
        switch transportOption {
        case .http:
            let trimmedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: trimmedEndpoint),
                  let scheme = url.scheme,
                  scheme.lowercased().hasPrefix("http") else {
                validationMessage = NSLocalizedString("请提供合法的 Streamable HTTP 地址。", comment: "")
                return
            }
            transport = .http(endpoint: url, apiKey: trimmedKey.isEmpty ? nil : trimmedKey, additionalHeaders: additionalHeaders)
        case .sse:
            let trimmedSSE = sseEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let sseURL = URL(string: trimmedSSE),
                  let sseScheme = sseURL.scheme,
                  sseScheme.lowercased().hasPrefix("http") else {
                validationMessage = NSLocalizedString("请提供合法的 SSE Endpoint。", comment: "")
                return
            }
            transport = .httpSSE(
                messageEndpoint: MCPServerConfiguration.inferMessageEndpoint(fromSSE: sseURL),
                sseEndpoint: sseURL,
                apiKey: trimmedKey.isEmpty ? nil : trimmedKey,
                additionalHeaders: additionalHeaders
            )
        case .oauth:
            let trimmedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: trimmedEndpoint),
                  let scheme = url.scheme,
                  scheme.lowercased().hasPrefix("http") else {
                validationMessage = NSLocalizedString("请提供合法的 HTTP 或 HTTPS 地址。", comment: "")
                return
            }
            let tokenString = tokenEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let tokenURL = URL(string: tokenString) else {
                validationMessage = NSLocalizedString("请提供合法的 Token Endpoint。", comment: "")
                return
            }
            let clientIDTrimmed = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clientIDTrimmed.isEmpty else {
                validationMessage = NSLocalizedString("Client ID 不能为空。", comment: "")
                return
            }
            let scopeTrimmed = oauthScope.trimmingCharacters(in: .whitespacesAndNewlines)
            let clientSecretTrimmed = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
            let authorizationCodeTrimmed = oauthAuthorizationCode.trimmingCharacters(in: .whitespacesAndNewlines)
            let redirectURITrimmed = oauthRedirectURI.trimmingCharacters(in: .whitespacesAndNewlines)
            let codeVerifierTrimmed = oauthCodeVerifier.trimmingCharacters(in: .whitespacesAndNewlines)
            if oauthGrantType == .authorizationCode {
                guard !authorizationCodeTrimmed.isEmpty, !redirectURITrimmed.isEmpty else {
                    validationMessage = NSLocalizedString("授权码模式下，Authorization Code 与 Redirect URI 不能为空。", comment: "")
                    return
                }
            }
            transport = .oauth(
                endpoint: url,
                tokenEndpoint: tokenURL,
                clientID: clientIDTrimmed,
                clientSecret: clientSecretTrimmed.isEmpty ? nil : clientSecretTrimmed,
                scope: scopeTrimmed.isEmpty ? nil : scopeTrimmed,
                grantType: oauthGrantType,
                authorizationCode: authorizationCodeTrimmed.isEmpty ? nil : authorizationCodeTrimmed,
                redirectURI: redirectURITrimmed.isEmpty ? nil : redirectURITrimmed,
                codeVerifier: codeVerifierTrimmed.isEmpty ? nil : codeVerifierTrimmed
            )
        }

        var server = existingServer ?? MCPServerConfiguration(displayName: trimmedName, notes: notesOrNil(), transport: transport)
        server.displayName = trimmedName
        server.notes = notesOrNil()
        server.transport = transport

        onSave(server)
        dismiss()
    }

    private func notesOrNil() -> String? {
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func oauthFieldsValid() -> Bool {
        if transportOption == .oauth {
            let hasBaseFields = !tokenEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            guard hasBaseFields else { return false }
            if oauthGrantType == .authorizationCode {
                return !oauthAuthorizationCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                !oauthRedirectURI.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            return true
        }
        return true
    }

    private var headerOverridesHint: String {
        NSLocalizedString("使用 key=value 添加请求头，例如: Authorization=Bearer {token}。\n{token} 会替换为上方 Bearer API Key 输入的值。", comment: "")
    }

    private var isSaveDisabled: Bool {
        displayName.trimmingCharacters(in: .whitespaces).isEmpty ||
        (transportOption == .sse
         ? sseEndpoint.trimmingCharacters(in: .whitespaces).isEmpty
         : endpoint.trimmingCharacters(in: .whitespaces).isEmpty) ||
        !oauthFieldsValid() ||
        (transportOption.requiresAPIKey && headerOverrideEntries.contains { $0.error != nil })
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

    private enum TransportOption: String, CaseIterable, Identifiable {
        case http
        case sse
        case oauth

        var id: String { rawValue }

        var label: String {
            switch self {
            case .http: return "Streamable HTTP"
            case .sse: return "SSE"
            case .oauth: return "OAuth 2.0"
            }
        }

        var requiresAPIKey: Bool {
            switch self {
            case .http, .sse: return true
            case .oauth: return false
            }
        }
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
