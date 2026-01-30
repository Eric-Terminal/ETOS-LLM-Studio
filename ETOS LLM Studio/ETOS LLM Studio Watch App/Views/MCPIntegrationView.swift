//
//  MCPIntegrationView.swift
//  ETOS LLM Studio Watch App
//

import SwiftUI
import Foundation
import Shared

struct MCPIntegrationView: View {
    @StateObject private var manager = MCPManager.shared
    
    var body: some View {
        List {
            Section("关于 MCP") {
                Text("配置 MCP 工具服务器，让助手调用远程能力。可在手表上查看与调试。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            
            Section("服务器管理") {
                if manager.servers.isEmpty {
                    Text("尚未添加服务器，点击下方入口新建。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(manager.servers) { server in
                        NavigationLink {
                            MCPServerDetailView(serverID: server.id)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(server.displayName)
                                        .font(.headline)
                                    Text(server.humanReadableEndpoint)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Text(statusDescription(for: server))
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                Spacer()
                                if manager.status(for: server).isSelectedForChat {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                }
                                Image(systemName: statusIcon(for: server))
                                    .foregroundStyle(statusColor(for: server))
                            }
                        }
                    }
                }
                
                NavigationLink {
                    MCPServerEditor(existingServer: nil) {
                        manager.save(server: $0)
                    }
                } label: {
                    Label("新增 MCP Server", systemImage: "plus.circle")
                }
            }
            
            Section("连接状态") {
                let connected = manager.connectedServers().count
                let selected = manager.selectedServers().count
                Text(
                    String(
                        format: NSLocalizedString("已连接 %d 台，聊天使用 %d 台。", comment: ""),
                        connected,
                        selected
                    )
                )
                    .font(.caption2)
                Button("刷新") {
                    manager.refreshMetadata()
                }
                .disabled(manager.isBusy || connected == 0)
                
                if manager.isBusy {
                    ProgressView("同步中…")
                }
            }
            
            Section("能力概览") {
                HStack {
                    Label(
                        String(format: NSLocalizedString("工具 %d", comment: ""), manager.tools.count),
                        systemImage: "hammer"
                    )
                    Spacer()
                    NavigationLink("查看列表") {
                        MCPToolListView()
                    }
                    .disabled(manager.tools.isEmpty)
                }
                HStack {
                    Label(
                        String(format: NSLocalizedString("资源 %d", comment: ""), manager.resources.count),
                        systemImage: "doc.plaintext"
                    )
                    Spacer()
                    NavigationLink("查看列表") {
                        MCPResourceListView()
                    }
                    .disabled(manager.resources.isEmpty)
                }
            }
            
            Section("调试面板") {
                NavigationLink {
                    MCPToolDebuggerView()
                } label: {
                    Label("调用工具", systemImage: "play.circle")
                }
                NavigationLink {
                    MCPResourceDebuggerView()
                } label: {
                    Label("读取资源", systemImage: "tray.and.arrow.down")
                }
                
                if manager.lastOperationOutput != nil || manager.lastOperationError != nil {
                    NavigationLink {
                        MCPResponseDetailView(
                            output: manager.lastOperationOutput,
                            error: manager.lastOperationError
                        )
                    } label: {
                        Label("查看最新响应", systemImage: "text.bubble")
                    }
                }
            }
        }
        .navigationTitle("MCP")
    }
    
    private func statusDescription(for server: MCPServerConfiguration) -> String {
        let status = manager.status(for: server)
        switch status.connectionState {
        case .idle:
            return "未连接"
        case .connecting:
            return "连接中"
        case .ready:
            return status.isSelectedForChat ? "聊天使用" : "已连接"
        case .failed(let reason):
            return String(format: NSLocalizedString("失败：%@", comment: ""), reason)
        @unknown default:
            return "未知状态"
        }
    }
    
    private func statusIcon(for server: MCPServerConfiguration) -> String {
        switch manager.status(for: server).connectionState {
        case .ready: return "checkmark.circle.fill"
        case .connecting: return "arrow.triangle.2.circlepath"
        case .failed: return "exclamationmark.circle"
        case .idle: return "circle"
        @unknown default: return "questionmark.circle"
        }
    }
    
    private func statusColor(for server: MCPServerConfiguration) -> Color {
        switch manager.status(for: server).connectionState {
        case .ready: return .green
        case .connecting: return .yellow
        case .failed: return .red
        case .idle: return .secondary
        @unknown default: return .secondary
        }
    }
}

// MARK: - Server Detail

private struct MCPServerDetailView: View {
    let serverID: UUID
    @ObservedObject private var manager = MCPManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showingDeleteConfirmation = false
    
    private var server: MCPServerConfiguration? {
        manager.servers.first(where: { $0.id == serverID })
    }
    
    var body: some View {
        List {
            if let server {
                let status = manager.status(for: server)
                Section("服务器信息") {
                    LabeledContent("名称", value: server.displayName)
                    LabeledContent("Endpoint", value: server.humanReadableEndpoint)
                    if let notes = server.notes {
                        LabeledContent("备注", value: notes)
                    }
                    Text(statusDescription(for: server))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                
                Section("连接控制") {
                    Button("连接") {
                        manager.connect(to: server)
                    }
                    .disabled(status.connectionState == .ready || status.connectionState == .connecting)
                    
                    Button("断开") {
                        manager.disconnect(server: server)
                    }
                    .disabled(status.connectionState == .idle)
                    
                    Toggle("用于聊天", isOn: Binding(
                        get: { manager.status(for: server).isSelectedForChat },
                        set: { newValue in
                            let current = manager.status(for: server).isSelectedForChat
                            if newValue != current {
                                manager.toggleSelection(for: server)
                            }
                        }
                    ))
                    .disabled(status.connectionState == .connecting)
                    
                    Button("刷新工具/资源") {
                        manager.refreshMetadata(for: server)
                    }
                    .disabled(status.connectionState != .ready || status.isBusy)
                    
                    if status.isBusy {
                        ProgressView()
                    }
                }

                Section("工具") {
                    if status.tools.isEmpty {
                        Text("当前服务器尚未公布任何工具。")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(status.tools) { tool in
                            Toggle(isOn: toolBinding(for: server.id, toolId: tool.toolId)) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(tool.toolId)
                                    if let desc = tool.description, !desc.isEmpty {
                                        Text(desc)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
                
                Section("管理") {
                    NavigationLink("编辑配置") {
                        MCPServerEditor(existingServer: server) {
                            manager.save(server: $0)
                        }
                    }
                    
                    Button("删除服务器", role: .destructive) {
                        showingDeleteConfirmation = true
                    }
                }
            } else {
                Section {
                    Text("该服务器已被删除。")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(server?.displayName ?? "服务器详情")
        .confirmationDialog("确定要删除此服务器？", isPresented: $showingDeleteConfirmation) {
            Button("删除", role: .destructive) {
                if let server {
                    manager.delete(server: server)
                }
                dismiss()
            }
            Button("取消", role: .cancel) {}
        }
    }

    private func toolBinding(for serverID: UUID, toolId: String) -> Binding<Bool> {
        Binding {
            manager.isToolEnabled(serverID: serverID, toolId: toolId)
        } set: { newValue in
            manager.setToolEnabled(serverID: serverID, toolId: toolId, isEnabled: newValue)
        }
    }
    
    private func statusDescription(for server: MCPServerConfiguration) -> String {
        let status = manager.status(for: server)
        switch status.connectionState {
        case .idle:
            return "未连接"
        case .connecting:
            return "连接中"
        case .ready:
            return status.isSelectedForChat ? "聊天使用" : "已连接"
        case .failed(let reason):
            return String(format: NSLocalizedString("失败：%@", comment: ""), reason)
        @unknown default:
            return "未知状态"
        }
    }
}

// MARK: - Tool & Resource Lists

private struct MCPToolListView: View {
    @ObservedObject private var manager = MCPManager.shared
    
    var body: some View {
        List {
            if manager.tools.isEmpty {
                Text("当前服务器尚未公布任何工具。")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(manager.tools) { tool in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(tool.tool.toolId)
                            .font(.headline)
                        Text(tool.server.displayName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if let description = tool.tool.description, !description.isEmpty {
                            Text(description)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Text(tool.internalName)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .navigationTitle("工具列表")
    }
}

private struct MCPResourceListView: View {
    @ObservedObject private var manager = MCPManager.shared
    
    var body: some View {
        List {
            if manager.resources.isEmpty {
                Text("当前服务器尚未暴露资源。")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(manager.resources) { resource in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(resource.resource.resourceId)
                            .font(.headline)
                        Text(resource.server.displayName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if let description = resource.resource.description, !description.isEmpty {
                            Text(description)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .navigationTitle("资源列表")
    }
}

// MARK: - Debugger Views

private struct MCPToolDebuggerView: View {
    @ObservedObject private var manager = MCPManager.shared
    @State private var toolIdInput: String = ""
    @State private var payloadInput: String = "{}"
    @State private var localError: String?
    @State private var selectedServerID: UUID?
    
    var body: some View {
        Form {
            Section("工具标识") {
                Picker("目标服务器", selection: $selectedServerID) {
                    Text("请选择").tag(Optional<UUID>.none)
                    ForEach(manager.connectedServers()) { server in
                        Text(server.displayName).tag(Optional(server.id))
                    }
                }
                TextField("例如 filesystem/readFile", text: $toolIdInput.watchKeyboardNewlineBinding())
            }
            
            Section("JSON 输入") {
                TextField("JSON 参数", text: $payloadInput.watchKeyboardNewlineBinding())
            }
            
            if let localError {
                Section {
                    Text(localError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            
            Button("执行工具") {
                executeTool()
            }
            .disabled(toolIdInput.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .navigationTitle("调用工具")
    }
    
    private func executeTool() {
        do {
            let inputs = try decodeJSONDictionary(from: payloadInput)
            guard let serverID = resolveServerID() else {
                localError = "请选择已连接服务器。"
                return
            }
            manager.executeTool(on: serverID, toolId: toolIdInput.trimmingCharacters(in: .whitespacesAndNewlines), inputs: inputs)
            localError = nil
        } catch {
            localError = error.localizedDescription
        }
    }
    
    private func resolveServerID() -> UUID? {
        if let selectedServerID {
            return selectedServerID
        }
        if let preferred = manager.selectedServers().first?.id ?? manager.connectedServers().first?.id {
            selectedServerID = preferred
            return preferred
        }
        return nil
    }
}

private struct MCPResourceDebuggerView: View {
    @ObservedObject private var manager = MCPManager.shared
    @State private var resourceIdInput: String = ""
    @State private var queryInput: String = "{}"
    @State private var localError: String?
    @State private var selectedServerID: UUID?
    
    var body: some View {
        Form {
            Section("资源标识") {
                Picker("目标服务器", selection: $selectedServerID) {
                    Text("请选择").tag(Optional<UUID>.none)
                    ForEach(manager.connectedServers()) { server in
                        Text(server.displayName).tag(Optional(server.id))
                    }
                }
                TextField("例如 documents/summary", text: $resourceIdInput.watchKeyboardNewlineBinding())
            }
            
            Section("查询 JSON (可选)") {
                TextField("JSON 查询", text: $queryInput.watchKeyboardNewlineBinding())
            }
            
            if let localError {
                Section {
                    Text(localError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            
            Button("读取资源") {
                readResource()
            }
            .disabled(resourceIdInput.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .navigationTitle("读取资源")
    }
    
    private func readResource() {
        do {
            let payload = try decodeJSONDictionary(from: queryInput)
            let query = payload.isEmpty ? nil : payload
            guard let serverID = resolveServerID() else {
                localError = "请选择已连接服务器。"
                return
            }
            manager.readResource(on: serverID, resourceId: resourceIdInput.trimmingCharacters(in: .whitespacesAndNewlines), query: query)
            localError = nil
        } catch {
            localError = error.localizedDescription
        }
    }
    
    private func resolveServerID() -> UUID? {
        if let selectedServerID {
            return selectedServerID
        }
        if let preferred = manager.selectedServers().first?.id ?? manager.connectedServers().first?.id {
            selectedServerID = preferred
            return preferred
        }
        return nil
    }
}

private struct MCPResponseDetailView: View {
    let output: String?
    let error: String?
    
    var body: some View {
        List {
            if let output {
                Section("Result") {
                    Text(output)
                        .font(.system(.footnote, design: .monospaced))
                }
            }
            
            if let error {
                Section("Error") {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
            }
        }
        .navigationTitle("最新响应")
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
                _transportOption = State(initialValue: .sse)
                _headerOverrideEntries = State(initialValue: serializedHeaders.isEmpty
                    ? [HeaderOverrideEntry(text: "")]
                    : serializedHeaders.map { HeaderOverrideEntry(text: $0) })
            case .oauth(let endpoint, let tokenEndpoint, let clientID, let clientSecret, let scope):
                _endpoint = State(initialValue: endpoint.absoluteString)
                _sseEndpoint = State(initialValue: "")
                _tokenEndpoint = State(initialValue: tokenEndpoint.absoluteString)
                _clientID = State(initialValue: clientID)
                _clientSecret = State(initialValue: clientSecret)
                _oauthScope = State(initialValue: scope ?? "")
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
            _transportOption = State(initialValue: .http)
            _headerOverrideEntries = State(initialValue: [HeaderOverrideEntry(text: "")])
        }
    }
    
    var body: some View {
        Form {
            Section("基本信息") {
                TextField("显示名称", text: $displayName.watchKeyboardNewlineBinding())
                Picker("传输类型", selection: $transportOption) {
                    ForEach(TransportOption.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                if transportOption == .sse {
                    TextField("SSE Endpoint", text: $sseEndpoint.watchKeyboardNewlineBinding())
                } else {
                    TextField("Streamable HTTP Endpoint", text: $endpoint.watchKeyboardNewlineBinding())
                }
                if transportOption.requiresAPIKey {
                    TextField("Bearer API Key (可选)", text: $apiKey.watchKeyboardNewlineBinding())
                }
                if transportOption == .oauth {
                    TextField("OAuth Token Endpoint", text: $tokenEndpoint.watchKeyboardNewlineBinding())
                    TextField("Client ID", text: $clientID.watchKeyboardNewlineBinding())
                    SecureField("Client Secret", text: $clientSecret.watchKeyboardNewlineBinding())
                    TextField("Scope (可选)", text: $oauthScope.watchKeyboardNewlineBinding())
                }
                TextField("备注 (可选)", text: $notes.watchKeyboardNewlineBinding())
            }

            if transportOption.requiresAPIKey {
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
                    Text(headerOverridesPreview.text)
                        .font(.footnote.monospaced())
                        .foregroundStyle(headerOverridesPreview.isPlaceholder ? .secondary : .primary)
                }
            }
            
            if let validationMessage {
                Section {
                    Text(validationMessage)
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
            }
        }
        .navigationTitle(existingServer == nil ? "新增服务器" : "编辑服务器")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("取消") { dismiss() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("保存") {
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
                validationMessage = "请提供合法的 Streamable HTTP 地址。"
                return
            }
            transport = .http(endpoint: url, apiKey: trimmedKey.isEmpty ? nil : trimmedKey, additionalHeaders: additionalHeaders)
        case .sse:
            let trimmedSSE = sseEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let sseURL = URL(string: trimmedSSE),
                  let sseScheme = sseURL.scheme,
                  sseScheme.lowercased().hasPrefix("http") else {
                validationMessage = "请提供合法的 SSE Endpoint。"
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
                validationMessage = "请提供合法的 HTTP/HTTPS 地址。"
                return
            }
            let tokenString = tokenEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let tokenURL = URL(string: tokenString) else {
                validationMessage = "请提供合法的 Token Endpoint。"
                return
            }
            let clientIDTrimmed = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
            let clientSecretTrimmed = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clientIDTrimmed.isEmpty, !clientSecretTrimmed.isEmpty else {
                validationMessage = "Client ID 与 Secret 不能为空。"
                return
            }
            let scopeTrimmed = oauthScope.trimmingCharacters(in: .whitespacesAndNewlines)
            transport = .oauth(
                endpoint: url,
                tokenEndpoint: tokenURL,
                clientID: clientIDTrimmed,
                clientSecret: clientSecretTrimmed,
                scope: scopeTrimmed.isEmpty ? nil : scopeTrimmed
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
            return !tokenEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !clientSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return true
    }

    private var headerOverridesHint: String {
        NSLocalizedString("使用 key=value 添加请求头，例如: Authorization=Bearer your_token。\nAuthorization 等鉴权头请手动填写。", comment: "")
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

// MARK: - Helpers

private func decodeJSONDictionary(from text: String) throws -> [String: JSONValue] {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [:] }
    let data = Data(trimmed.utf8)
    return try JSONDecoder().decode([String: JSONValue].self, from: data)
}
