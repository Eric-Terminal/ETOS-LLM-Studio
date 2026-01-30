//
//  MCPIntegrationView.swift
//  ETOS LLM Studio iOS App
//
//  创建一个用于管理 MCP Server 的交互界面。
//

import SwiftUI
import Foundation
import Shared

struct MCPIntegrationView: View {
    @StateObject private var manager = MCPManager.shared
    @State private var isPresentingEditor = false
    @State private var serverToEdit: MCPServerConfiguration?
    @State private var toolIdInput: String = ""
    @State private var toolPayloadInput: String = "{}"
    @State private var resourceIdInput: String = ""
    @State private var resourceQueryInput: String = "{}"
    @State private var localError: String?
    @State private var selectedToolServerID: UUID?
    @State private var selectedResourceServerID: UUID?
    
    var body: some View {
        List {
            Section("关于 MCP") {
                Text("配置 MCP 工具服务器，让助手调用远程能力。可在这里管理 Server、查看能力，并用 JSON 调试。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            
            Section("已配置服务器") {
                if manager.servers.isEmpty {
                    Text("尚未添加任何 MCP Server。点击右上角“＋”创建。")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(manager.servers) { server in
                        NavigationLink {
                            MCPServerDetailView(server: server)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(server.displayName)
                                        .font(.headline)
                                    Text(server.humanReadableEndpoint)
                                        .font(.caption)
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
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                manager.delete(server: server)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                            Button {
                                serverToEdit = server
                                isPresentingEditor = true
                            } label: {
                                Label("编辑", systemImage: "pencil")
                            }
                            .tint(.blue)
                        }
                    }
                }
            }
            
            Section("连接概览") {
                let connectedCount = manager.connectedServers().count
                let selectedCount = manager.selectedServers().count
                Text(
                    String(
                        format: NSLocalizedString("已连接 %d 台，参与聊天 %d 台。", comment: ""),
                        connectedCount,
                        selectedCount
                    )
                )
                    .font(.footnote)
                Button("刷新已连接服务器") {
                    manager.refreshMetadata()
                }
                .disabled(manager.isBusy || connectedCount == 0)
                
                if manager.isBusy {
                    ProgressView("正在同步…")
                }
            }
            
            if !manager.tools.isEmpty {
                Section(
                    String(format: NSLocalizedString("已公布工具 (%d)", comment: ""), manager.tools.count)
                ) {
                    ForEach(manager.tools) { available in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(available.tool.toolId)
                                .font(.headline)
                            Text(
                                String(
                                    format: NSLocalizedString("来源：%@", comment: ""),
                                    available.server.displayName
                                )
                            )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let desc = available.tool.description, !desc.isEmpty {
                                Text(desc)
                                    .font(.footnote)
                            }
                            Text(
                                String(
                                    format: NSLocalizedString("内部名称：%@", comment: ""),
                                    available.internalName
                                )
                            )
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .textSelection(.enabled)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            
            if !manager.resources.isEmpty {
                Section(
                    String(format: NSLocalizedString("可用资源 (%d)", comment: ""), manager.resources.count)
                ) {
                    ForEach(manager.resources) { available in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(available.resource.resourceId)
                                .font(.headline)
                            Text(
                                String(
                                    format: NSLocalizedString("来源：%@", comment: ""),
                                    available.server.displayName
                                )
                            )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let desc = available.resource.description, !desc.isEmpty {
                                Text(desc)
                                    .font(.footnote)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            if !manager.prompts.isEmpty {
                Section(
                    String(format: NSLocalizedString("提示词模板 (%d)", comment: ""), manager.prompts.count)
                ) {
                    ForEach(manager.prompts) { available in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(available.prompt.name)
                                .font(.headline)
                            Text(
                                String(
                                    format: NSLocalizedString("来源：%@", comment: ""),
                                    available.server.displayName
                                )
                            )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let desc = available.prompt.description, !desc.isEmpty {
                                Text(desc)
                                    .font(.footnote)
                            }
                            if let args = available.prompt.arguments, !args.isEmpty {
                                Text(
                                    String(
                                        format: NSLocalizedString("参数：%@", comment: ""),
                                        args.map { $0.name }.joined(separator: NSLocalizedString("，", comment: ""))
                                    )
                                )
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            if !manager.logEntries.isEmpty {
                Section {
                    ForEach(manager.logEntries.suffix(20).reversed(), id: \.self) { entry in
                        HStack {
                            logLevelIcon(entry.level)
                            VStack(alignment: .leading, spacing: 2) {
                                if let logger = entry.logger {
                                    Text(logger)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                if let data = entry.data {
                                    Text(data.prettyPrintedCompact())
                                        .font(.system(.caption2, design: .monospaced))
                                        .lineLimit(3)
                                }
                            }
                        }
                    }
                    Button("清空日志", role: .destructive) {
                        manager.clearLogEntries()
                    }
                } header: {
                    Text("服务器日志 (最近 20 条)")
                }
            }
            
            Section("快速调试") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("调用工具")
                        .font(.subheadline)
                        .bold()
                    Picker("目标服务器", selection: $selectedToolServerID) {
                        Text("请选择").tag(Optional<UUID>.none)
                        ForEach(manager.connectedServers()) { server in
                            Text(server.displayName).tag(Optional(server.id))
                        }
                    }
                    TextField("工具 ID", text: $toolIdInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextEditor(text: $toolPayloadInput)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(minHeight: 80)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.2)))
                    Button("执行工具") {
                        triggerToolExecution()
                    }
                    .disabled(manager.isBusy)
                }
                
                Divider()
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("读取资源")
                        .font(.subheadline)
                        .bold()
                    Picker("目标服务器", selection: $selectedResourceServerID) {
                        Text("请选择").tag(Optional<UUID>.none)
                        ForEach(manager.connectedServers()) { server in
                            Text(server.displayName).tag(Optional(server.id))
                        }
                    }
                    TextField("资源 ID", text: $resourceIdInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextEditor(text: $resourceQueryInput)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(minHeight: 80)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.2)))
                    Button("读取资源") {
                        triggerResourceRead()
                    }
                    .disabled(manager.isBusy)
                }
                
                if let error = localError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            
            if let output = manager.lastOperationOutput {
                Section("最新响应") {
                    ScrollView(.vertical) {
                        Text(output)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 120)
                }
            }
            
            if let error = manager.lastOperationError {
                Section("错误信息") {
                    Text(error)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("MCP 工具箱")
        .toolbar {
            Button {
                serverToEdit = nil
                isPresentingEditor = true
            } label: {
                Image(systemName: "plus")
            }
        }
        .sheet(isPresented: $isPresentingEditor, onDismiss: { serverToEdit = nil }) {
            NavigationStack {
                MCPServerEditor(existingServer: serverToEdit) { server in
                    manager.save(server: server)
                }
            }
        }
    }
    
    private func triggerToolExecution() {
        do {
            let payload = try decodeJSONDictionary(from: toolPayloadInput)
            guard let serverID = resolveServerSelection(forTool: true) else {
                localError = NSLocalizedString("请选择一个已连接的服务器。", comment: "")
                return
            }
            let toolID = toolIdInput.trimmingCharacters(in: .whitespacesAndNewlines)
            manager.executeTool(on: serverID, toolId: toolID, inputs: payload)
            localError = nil
        } catch {
            localError = error.localizedDescription
        }
    }
    
    private func triggerResourceRead() {
        do {
            let payload = try decodeJSONDictionary(from: resourceQueryInput)
            guard let serverID = resolveServerSelection(forTool: false) else {
                localError = NSLocalizedString("请选择一个已连接的服务器。", comment: "")
                return
            }
            let query = payload.isEmpty ? nil : payload
            let resourceID = resourceIdInput.trimmingCharacters(in: .whitespacesAndNewlines)
            manager.readResource(on: serverID, resourceId: resourceID, query: query)
            localError = nil
        } catch {
            localError = error.localizedDescription
        }
    }

    private func resolveServerSelection(forTool: Bool) -> UUID? {
        let explicit = forTool ? selectedToolServerID : selectedResourceServerID
        if let explicit { return explicit }
        if let preferred = manager.selectedServers().first?.id {
            if forTool {
                selectedToolServerID = preferred
            } else {
                selectedResourceServerID = preferred
            }
            return preferred
        }
        if let fallback = manager.connectedServers().first?.id {
            if forTool {
                selectedToolServerID = fallback
            } else {
                selectedResourceServerID = fallback
            }
            return fallback
        }
        return nil
    }
    
    private func decodeJSONDictionary(from text: String) throws -> [String: JSONValue] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [:] }
        let data = Data(trimmed.utf8)
        return try JSONDecoder().decode([String: JSONValue].self, from: data)
    }

    private func logLevelIcon(_ level: MCPLogLevel) -> some View {
        let (icon, color): (String, Color) = {
            switch level {
            case .debug:
                return ("ant", .gray)
            case .info:
                return ("info.circle", .blue)
            case .notice:
                return ("bell", .cyan)
            case .warning:
                return ("exclamationmark.triangle", .yellow)
            case .error:
                return ("xmark.circle", .red)
            case .critical, .alert, .emergency:
                return ("exclamationmark.octagon", .red)
            @unknown default:
                return ("questionmark.circle", .gray)
            }
        }()
        return Image(systemName: icon)
            .foregroundStyle(color)
    }
    
    private func statusDescription(for server: MCPServerConfiguration) -> String {
        let status = manager.status(for: server)
        switch status.connectionState {
        case .idle:
            return "未连接"
        case .connecting:
            return "正在连接..."
        case .ready:
            return status.isSelectedForChat
                ? NSLocalizedString("已连接并参与聊天", comment: "")
                : NSLocalizedString("已连接", comment: "")
        case .failed(let reason):
            return String(format: NSLocalizedString("失败：%@", comment: ""), reason)
        @unknown default:
            return "未知状态"
        }
    }
    
    private func statusIcon(for server: MCPServerConfiguration) -> String {
        let state = manager.status(for: server).connectionState
        switch state {
        case .connecting:
            return "arrow.triangle.2.circlepath"
        case .ready:
            return "checkmark.circle.fill"
        case .failed:
            return "exclamationmark.circle"
        case .idle:
            return "circle"
        @unknown default:
            return "questionmark.circle"
        }
    }
    
    private func statusColor(for server: MCPServerConfiguration) -> Color {
        let state = manager.status(for: server).connectionState
        switch state {
        case .ready:
            return .green
        case .connecting:
            return .blue
        case .failed:
            return .red
        case .idle:
            return .secondary
        @unknown default:
            return .secondary
        }
    }
}

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
            Section("服务器信息") {
                LabeledContent("名称", value: server.displayName)
                LabeledContent("Endpoint", value: server.humanReadableEndpoint)
                if let notes = server.notes {
                    LabeledContent("备注", value: notes)
                }
            }
            
            Section("连接控制") {
                Button("连接") {
                    manager.connect(to: server)
                }
                .disabled(status.connectionState == .ready || status.connectionState == .connecting)
                
                Button("断开连接") {
                    manager.disconnect(server: server)
                }
                .disabled(status.connectionState == .idle)
                
                Toggle("用于聊天", isOn: bindingForSelection())
                    .disabled(status.connectionState == .connecting)
                
                Button("刷新元数据") {
                    manager.refreshMetadata(for: server)
                }
                .disabled(status.connectionState != .ready || status.isBusy)
                
                if status.isBusy {
                    ProgressView()
                }
            }
            
            if let info = status.info {
                Section("服务器能力") {
                    Text(info.name + (info.version.map { " \($0)" } ?? ""))
                    if let capabilities = info.capabilities, !capabilities.isEmpty {
                        Text("Capabilities: \(capabilities.keys.joined(separator: ", "))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            
            if !status.tools.isEmpty {
                Section(
                    String(format: NSLocalizedString("工具 (%d)", comment: ""), status.tools.count)
                ) {
                    ForEach(status.tools) { tool in
                        Toggle(isOn: toolBinding(for: tool.toolId)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tool.toolId)
                                if let desc = tool.description {
                                    Text(desc)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
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
                                    .font(.caption2)
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
                Button("编辑") {
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
        .confirmationDialog("确定要删除此服务器？", isPresented: $showingDeleteConfirmation) {
            Button("删除", role: .destructive) {
                manager.delete(server: server)
                dismiss()
            }
            Button("取消", role: .cancel) { }
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

    private func toolBinding(for toolId: String) -> Binding<Bool> {
        Binding {
            manager.isToolEnabled(serverID: server.id, toolId: toolId)
        } set: { newValue in
            manager.setToolEnabled(serverID: server.id, toolId: toolId, isEnabled: newValue)
        }
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
    @State private var validationMessage: String?
    
    init(existingServer: MCPServerConfiguration?, onSave: @escaping (MCPServerConfiguration) -> Void) {
        self.existingServer = existingServer
        self.onSave = onSave
        
        if let server = existingServer {
            _displayName = State(initialValue: server.displayName)
            _notes = State(initialValue: server.notes ?? "")
            switch server.transport {
            case .http(let endpoint, let apiKey, _):
                _endpoint = State(initialValue: endpoint.absoluteString)
                _sseEndpoint = State(initialValue: "")
                _apiKey = State(initialValue: apiKey ?? "")
                _tokenEndpoint = State(initialValue: "")
                _clientID = State(initialValue: "")
                _clientSecret = State(initialValue: "")
                _oauthScope = State(initialValue: "")
                _transportOption = State(initialValue: .http)
            case .httpSSE(_, let sseEndpoint, let apiKey, _):
                _endpoint = State(initialValue: MCPServerConfiguration.inferMessageEndpoint(fromSSE: sseEndpoint).absoluteString)
                _sseEndpoint = State(initialValue: sseEndpoint.absoluteString)
                _apiKey = State(initialValue: apiKey ?? "")
                _tokenEndpoint = State(initialValue: "")
                _clientID = State(initialValue: "")
                _clientSecret = State(initialValue: "")
                _oauthScope = State(initialValue: "")
                _transportOption = State(initialValue: .sse)
            case .oauth(let endpoint, let tokenEndpoint, let clientID, let clientSecret, let scope):
                _endpoint = State(initialValue: endpoint.absoluteString)
                _sseEndpoint = State(initialValue: "")
                _tokenEndpoint = State(initialValue: tokenEndpoint.absoluteString)
                _clientID = State(initialValue: clientID)
                _clientSecret = State(initialValue: clientSecret)
                _oauthScope = State(initialValue: scope ?? "")
                _apiKey = State(initialValue: "")
                _transportOption = State(initialValue: .oauth)
            @unknown default:
                _endpoint = State(initialValue: "")
                _sseEndpoint = State(initialValue: "")
                _apiKey = State(initialValue: "")
                _tokenEndpoint = State(initialValue: "")
                _clientID = State(initialValue: "")
                _clientSecret = State(initialValue: "")
                _oauthScope = State(initialValue: "")
                _transportOption = State(initialValue: .http)
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
        }
    }
    
    var body: some View {
        Form {
            Section("基本信息") {
                TextField("显示名称", text: $displayName)
                Picker("传输类型", selection: $transportOption) {
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
                    TextField("Bearer API Key (可选)", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                if transportOption == .oauth {
                    TextField("OAuth Token Endpoint", text: $tokenEndpoint)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Client ID", text: $clientID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Client Secret", text: $clientSecret)
                    TextField("Scope (可选)", text: $oauthScope)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                TextEditor(text: $notes)
                    .frame(minHeight: 60)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.2)))
            }
            
            if let validationMessage {
                Section {
                    Text(validationMessage)
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
            }
        }
        .navigationTitle(existingServer == nil ? "新增 MCP Server" : "编辑 MCP Server")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    saveServer()
                }
                .disabled(displayName.trimmingCharacters(in: .whitespaces).isEmpty ||
                          (transportOption == .sse
                           ? sseEndpoint.trimmingCharacters(in: .whitespaces).isEmpty
                           : endpoint.trimmingCharacters(in: .whitespaces).isEmpty) ||
                          !oauthFieldsValid())
            }
        }
    }
    
    private func saveServer() {
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        
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
            transport = .http(endpoint: url, apiKey: trimmedKey.isEmpty ? nil : trimmedKey, additionalHeaders: [:])
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
                additionalHeaders: [:]
            )
        case .oauth:
            let trimmedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: trimmedEndpoint),
                  let scheme = url.scheme,
                  scheme.lowercased().hasPrefix("http") else {
                validationMessage = "请提供合法的 HTTP 或 HTTPS 地址。"
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
