// ============================================================================
// MCPIntegrationServerEditor.swift
// ============================================================================
// ETOS LLM Studio Watch App MCP 服务器编辑器辅助视图
// ============================================================================

import SwiftUI
import Foundation
import ETOSCore

struct MCPServerEditor: View {
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
    @State private var showUnsavedChangesAlert = false

    init(existingServer: MCPServerConfiguration?, onSave: @escaping (MCPServerConfiguration) -> Void) {
        self.existingServer = existingServer
        self.onSave = onSave

        if let server = existingServer {
            _displayName = State(initialValue: server.displayName)
            _notes = State(initialValue: server.notes ?? "")
            switch server.transport {
            case .http(let endpoint, let apiKey, let additionalHeaders):
                let serializedHeaders = HeaderExpressionParser.serialize(headers: additionalHeaders)
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
            case .httpSSE(_, let sseEndpoint, let apiKey, let additionalHeaders):
                let serializedHeaders = HeaderExpressionParser.serialize(headers: additionalHeaders)
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
            case .builtInSearch:
                _endpoint = State(initialValue: MCPBuiltInSearchServer.endpoint)
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
                _transportOption = State(initialValue: .builtInSearch)
                _headerOverrideEntries = State(initialValue: [HeaderOverrideEntry(text: "")])
            case .builtInAppTool(let category):
                _endpoint = State(initialValue: MCPBuiltInAppToolServer.endpoint(for: category))
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
                _transportOption = State(initialValue: .builtInAppTool)
                _headerOverrideEntries = State(initialValue: [HeaderOverrideEntry(text: "")])
            case .builtInPersonalData:
                _endpoint = State(initialValue: MCPBuiltInPersonalDataServer.endpoint)
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
                _transportOption = State(initialValue: .builtInPersonalData)
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
                TextField(NSLocalizedString("显示名称", comment: ""), text: $displayName.watchKeyboardNewlineBinding())
                Picker(NSLocalizedString("传输类型", comment: ""), selection: $transportOption) {
                    if transportOption == .builtInSearch {
                        Text(TransportOption.builtInSearch.label).tag(TransportOption.builtInSearch)
                    }
                    if transportOption == .builtInAppTool {
                        Text(TransportOption.builtInAppTool.label).tag(TransportOption.builtInAppTool)
                    }
                    if transportOption == .builtInPersonalData {
                        Text(TransportOption.builtInPersonalData.label).tag(TransportOption.builtInPersonalData)
                    }
                    ForEach(TransportOption.editableCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .disabled(transportOption.isBuiltIn)
                if transportOption == .builtInSearch {
                    Text(NSLocalizedString("应用内置搜索服务，无需配置网络地址。", comment: "Built-in MCP search editor hint"))
                        .foregroundStyle(.secondary)
                        .etFont(.footnote)
                } else if transportOption == .builtInAppTool {
                    Text(NSLocalizedString("应用内建本地工具服务，无需配置网络地址。", comment: "Built-in app tool MCP editor hint"))
                        .foregroundStyle(.secondary)
                        .etFont(.footnote)
                } else if transportOption == .builtInPersonalData {
                    Text(NSLocalizedString("应用内建个人数据服务，无需配置网络地址；HealthKit 与 EventKit 权限仅在工具正式调用时申请。", comment: "Built-in personal data MCP editor hint"))
                        .foregroundStyle(.secondary)
                        .etFont(.footnote)
                } else if transportOption == .sse {
                    TextField(NSLocalizedString("SSE Endpoint", comment: "MCP SSE endpoint field"), text: $sseEndpoint.watchKeyboardNewlineBinding())
                } else {
                    TextField(NSLocalizedString("Streamable HTTP Endpoint", comment: "MCP streamable HTTP endpoint field"), text: $endpoint.watchKeyboardNewlineBinding())
                }
                if transportOption.requiresAPIKey {
                    TextField(NSLocalizedString("Bearer API Key (可选)", comment: ""), text: $apiKey.watchKeyboardNewlineBinding())
                }
                if transportOption == .oauth {
                    Picker(NSLocalizedString("授权类型", comment: ""), selection: $oauthGrantType) {
                        Text(NSLocalizedString("Client Credentials", comment: "OAuth grant type")).tag(MCPOAuthGrantType.clientCredentials)
                        Text(NSLocalizedString("Authorization Code", comment: "OAuth grant type")).tag(MCPOAuthGrantType.authorizationCode)
                    }
                    TextField(NSLocalizedString("OAuth Token Endpoint", comment: "OAuth token endpoint field"), text: $tokenEndpoint.watchKeyboardNewlineBinding())
                    TextField(NSLocalizedString("Client ID", comment: "OAuth client id field"), text: $clientID.watchKeyboardNewlineBinding())
                    SecureField(NSLocalizedString("Client Secret (可选)", comment: ""), text: $clientSecret.watchKeyboardNewlineBinding())
                    TextField(NSLocalizedString("Scope (可选)", comment: ""), text: $oauthScope.watchKeyboardNewlineBinding())
                    if oauthGrantType == .authorizationCode {
                        TextField(NSLocalizedString("Authorization Code", comment: "OAuth authorization code field"), text: $oauthAuthorizationCode.watchKeyboardNewlineBinding())
                        TextField(NSLocalizedString("Redirect URI", comment: "OAuth redirect URI field"), text: $oauthRedirectURI.watchKeyboardNewlineBinding())
                        TextField(NSLocalizedString("PKCE Code Verifier (可选)", comment: ""), text: $oauthCodeVerifier.watchKeyboardNewlineBinding())
                    }
                }
                TextField(NSLocalizedString("备注 (可选)", comment: ""), text: $notes.watchKeyboardNewlineBinding())
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

                    Button(NSLocalizedString("添加表达式", comment: "")) {
                        addHeaderOverrideEntry()
                    }
                }

                Section(header: Text(NSLocalizedString("请求头预览", comment: ""))) {
                    Text(headerOverridesPreview.text)
                        .etFont(.footnote.monospaced())
                        .foregroundStyle(headerOverridesPreview.isPlaceholder ? .secondary : .primary)
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
        .navigationTitle(existingServer == nil ? NSLocalizedString("新增服务器", comment: "") : NSLocalizedString("编辑服务器", comment: ""))
        .navigationBarBackButtonHidden(hasUnsavedChanges)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
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
            ToolbarItem(placement: .topBarTrailing) {
                Button(NSLocalizedString("保存", comment: "")) {
                    saveServer()
                }
                .disabled(isSaveDisabled)
            }
        }
        .alert(NSLocalizedString("未保存更改", comment: "Unsaved changes alert title"), isPresented: $showUnsavedChangesAlert) {
            if !isSaveDisabled {
                Button(NSLocalizedString("保存并离开", comment: "Save and leave button")) {
                    saveServer()
                }
            }
            Button(NSLocalizedString("放弃更改", comment: "Discard changes button"), role: .destructive) {
                dismiss()
            }
            Button(NSLocalizedString("继续编辑", comment: "Continue editing button"), role: .cancel) {}
        } message: {
            Text(NSLocalizedString("要保存当前编辑内容，还是放弃更改并离开？", comment: "Generic unsaved changes alert message"))
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
                validationMessage = NSLocalizedString("请提供合法的 HTTP/HTTPS 地址。", comment: "")
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
        case .builtInSearch:
            transport = .builtInSearch
        case .builtInAppTool:
            if case .builtInAppTool(let category) = existingServer?.transport {
                transport = .builtInAppTool(category: category)
            } else {
                transport = .builtInAppTool(category: .interaction)
            }
        case .builtInPersonalData:
            transport = .builtInPersonalData
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

    private var hasUnsavedChanges: Bool {
        currentSnapshot != Self.initialSnapshot(for: existingServer)
    }

    private var currentSnapshot: EditorSnapshot {
        EditorSnapshot(
            displayName: displayName,
            endpoint: endpoint,
            sseEndpoint: sseEndpoint,
            apiKey: apiKey,
            tokenEndpoint: tokenEndpoint,
            clientID: clientID,
            clientSecret: clientSecret,
            oauthScope: oauthScope,
            oauthGrantType: oauthGrantType,
            oauthAuthorizationCode: oauthAuthorizationCode,
            oauthRedirectURI: oauthRedirectURI,
            oauthCodeVerifier: oauthCodeVerifier,
            transportOption: transportOption,
            notes: notes,
            headerOverrideTexts: headerOverrideEntries.map(\.text)
        )
    }

    private func requestDismiss() {
        if hasUnsavedChanges {
            showUnsavedChangesAlert = true
        } else {
            dismiss()
        }
    }

    private static func initialSnapshot(for server: MCPServerConfiguration?) -> EditorSnapshot {
        guard let server else {
            return EditorSnapshot(
                displayName: "",
                endpoint: "",
                sseEndpoint: "",
                apiKey: "",
                tokenEndpoint: "",
                clientID: "",
                clientSecret: "",
                oauthScope: "",
                oauthGrantType: .clientCredentials,
                oauthAuthorizationCode: "",
                oauthRedirectURI: "",
                oauthCodeVerifier: "",
                transportOption: .http,
                notes: "",
                headerOverrideTexts: [""]
            )
        }

        let notes = server.notes ?? ""
        switch server.transport {
        case .http(let endpoint, let apiKey, let additionalHeaders):
            return EditorSnapshot(
                displayName: server.displayName,
                endpoint: endpoint.absoluteString,
                sseEndpoint: "",
                apiKey: apiKey ?? "",
                tokenEndpoint: "",
                clientID: "",
                clientSecret: "",
                oauthScope: "",
                oauthGrantType: .clientCredentials,
                oauthAuthorizationCode: "",
                oauthRedirectURI: "",
                oauthCodeVerifier: "",
                transportOption: .http,
                notes: notes,
                headerOverrideTexts: serializedHeaderTexts(for: additionalHeaders)
            )
        case .httpSSE(_, let sseEndpoint, let apiKey, let additionalHeaders):
            return EditorSnapshot(
                displayName: server.displayName,
                endpoint: MCPServerConfiguration.inferMessageEndpoint(fromSSE: sseEndpoint).absoluteString,
                sseEndpoint: sseEndpoint.absoluteString,
                apiKey: apiKey ?? "",
                tokenEndpoint: "",
                clientID: "",
                clientSecret: "",
                oauthScope: "",
                oauthGrantType: .clientCredentials,
                oauthAuthorizationCode: "",
                oauthRedirectURI: "",
                oauthCodeVerifier: "",
                transportOption: .sse,
                notes: notes,
                headerOverrideTexts: serializedHeaderTexts(for: additionalHeaders)
            )
        case .oauth(let endpoint, let tokenEndpoint, let clientID, let clientSecret, let scope, let grantType, let authorizationCode, let redirectURI, let codeVerifier):
            return EditorSnapshot(
                displayName: server.displayName,
                endpoint: endpoint.absoluteString,
                sseEndpoint: "",
                apiKey: "",
                tokenEndpoint: tokenEndpoint.absoluteString,
                clientID: clientID,
                clientSecret: clientSecret ?? "",
                oauthScope: scope ?? "",
                oauthGrantType: grantType,
                oauthAuthorizationCode: authorizationCode ?? "",
                oauthRedirectURI: redirectURI ?? "",
                oauthCodeVerifier: codeVerifier ?? "",
                transportOption: .oauth,
                notes: notes,
                headerOverrideTexts: [""]
            )
        case .builtInSearch:
            return EditorSnapshot(
                displayName: server.displayName,
                endpoint: MCPBuiltInSearchServer.endpoint,
                sseEndpoint: "",
                apiKey: "",
                tokenEndpoint: "",
                clientID: "",
                clientSecret: "",
                oauthScope: "",
                oauthGrantType: .clientCredentials,
                oauthAuthorizationCode: "",
                oauthRedirectURI: "",
                oauthCodeVerifier: "",
                transportOption: .builtInSearch,
                notes: notes,
                headerOverrideTexts: [""]
            )
        case .builtInAppTool(let category):
            return EditorSnapshot(
                displayName: server.displayName,
                endpoint: MCPBuiltInAppToolServer.endpoint(for: category),
                sseEndpoint: "",
                apiKey: "",
                tokenEndpoint: "",
                clientID: "",
                clientSecret: "",
                oauthScope: "",
                oauthGrantType: .clientCredentials,
                oauthAuthorizationCode: "",
                oauthRedirectURI: "",
                oauthCodeVerifier: "",
                transportOption: .builtInAppTool,
                notes: notes,
                headerOverrideTexts: [""]
            )
        case .builtInPersonalData:
            return EditorSnapshot(
                displayName: server.displayName,
                endpoint: MCPBuiltInPersonalDataServer.endpoint,
                sseEndpoint: "",
                apiKey: "",
                tokenEndpoint: "",
                clientID: "",
                clientSecret: "",
                oauthScope: "",
                oauthGrantType: .clientCredentials,
                oauthAuthorizationCode: "",
                oauthRedirectURI: "",
                oauthCodeVerifier: "",
                transportOption: .builtInPersonalData,
                notes: notes,
                headerOverrideTexts: [""]
            )
        @unknown default:
            return EditorSnapshot(
                displayName: server.displayName,
                endpoint: "",
                sseEndpoint: "",
                apiKey: "",
                tokenEndpoint: "",
                clientID: "",
                clientSecret: "",
                oauthScope: "",
                oauthGrantType: .clientCredentials,
                oauthAuthorizationCode: "",
                oauthRedirectURI: "",
                oauthCodeVerifier: "",
                transportOption: .http,
                notes: notes,
                headerOverrideTexts: [""]
            )
        }
    }

    private static func serializedHeaderTexts(for additionalHeaders: [String: String]) -> [String] {
        let serializedHeaders = HeaderExpressionParser.serialize(headers: additionalHeaders)
        return serializedHeaders.isEmpty ? [""] : serializedHeaders
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
        if displayName.trimmingCharacters(in: .whitespaces).isEmpty {
            return true
        }
        if transportOption.isBuiltIn {
            return false
        }
        return (transportOption == .sse
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
        case builtInSearch
        case builtInAppTool
        case builtInPersonalData

        var id: String { rawValue }
        static var editableCases: [TransportOption] { [.http, .sse, .oauth] }

        var label: String {
            switch self {
            case .http: return "Streamable HTTP"
            case .sse: return "SSE"
            case .oauth: return "OAuth 2.0"
            case .builtInSearch: return NSLocalizedString("内置搜索", comment: "Built-in MCP search transport label")
            case .builtInAppTool: return NSLocalizedString("内建本地工具", comment: "Built-in app tool MCP transport label")
            case .builtInPersonalData: return NSLocalizedString("内建个人数据", comment: "Built-in personal data MCP transport label")
            }
        }

        var isBuiltIn: Bool {
            switch self {
            case .builtInSearch, .builtInAppTool, .builtInPersonalData:
                return true
            case .http, .sse, .oauth:
                return false
            }
        }

        var requiresAPIKey: Bool {
            switch self {
            case .http, .sse: return true
            case .oauth, .builtInSearch, .builtInAppTool, .builtInPersonalData: return false
            }
        }
    }

    private struct EditorSnapshot: Equatable {
        var displayName: String
        var endpoint: String
        var sseEndpoint: String
        var apiKey: String
        var tokenEndpoint: String
        var clientID: String
        var clientSecret: String
        var oauthScope: String
        var oauthGrantType: MCPOAuthGrantType
        var oauthAuthorizationCode: String
        var oauthRedirectURI: String
        var oauthCodeVerifier: String
        var transportOption: TransportOption
        var notes: String
        var headerOverrideTexts: [String]
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
