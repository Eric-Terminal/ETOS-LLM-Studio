import ETOSCore
import SwiftUI

struct MacMCPServerEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var manager = MCPManager.shared
    @State private var draft: MCPServerConfiguration
    @State private var configurationJSON = ""
    @State private var isValid = false
    @State private var isSaving = false
    @State private var error: String?
    @State private var didPrepare = false
    @State private var encodingRevision = UUID()
    private let original: MCPServerConfiguration?

    private var transportKind: String {
        switch draft.transport {
        case .localStdio: "stdio"
        case .http: "http"
        case .httpSSE: "sse"
        case .oauth: "oauth"
        case .builtInSearch, .builtInAppTool, .builtInPersonalData: "builtin"
        }
    }
    private var pageID: GuidePageID { GuidePageID(rawValue: "mac-mcp-editor-\(draft.id)-\(transportKind)") }

    init(server: MCPServerConfiguration, original: MCPServerConfiguration?) {
        _draft = State(initialValue: server)
        self.original = original
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(NSLocalizedString("显示名称", comment: ""), text: $draft.displayName)
                    TextField(NSLocalizedString("备注", comment: ""), text: Binding(get: { draft.notes ?? "" }, set: { draft.notes = $0 }))
                    Toggle(NSLocalizedString("用于聊天", comment: ""), isOn: $draft.isSelectedForChat)
                }
                Section {
                    MacSettingsIntroCard(id: "mcp-configuration", title: NSLocalizedString("配置说明", comment: ""), details: NSLocalizedString("stdio 使用 command、args、env 和 cwd；远程连接使用 endpoint。高级字段保留原有格式。已有环境变量引用保持不变，新增 env 值会在保存时转为数据库记录。", comment: ""), documentID: "macos-workspace")
                    Menu(NSLocalizedString("连接类型", comment: "")) {
                        Button(NSLocalizedString("本机 stdio", comment: "")) {
                            replaceTransport(.localStdio(configuration: .init(command: "")))
                        }
                        Button(NSLocalizedString("Streamable HTTP", comment: "")) {
                            replaceTransport(.http(endpoint: URL(string: "https://example.com/mcp")!, apiKey: nil, additionalHeaders: [:]))
                        }
                    }
                    .disabled(transportKind == "builtin")
                    TextEditor(text: $configurationJSON)
                        .font(.system(.body, design: .monospaced)).frame(minHeight: 220)
                        .accessibilityLabel(NSLocalizedString("连接配置 JSON", comment: ""))
                        .disabled(transportKind == "builtin" || isSaving)
                } footer: {
                    Text(NSLocalizedString("修改保留为草稿，点击保存后生效。", comment: ""))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            }
            .formStyle(.grouped)
            .navigationTitle(NSLocalizedString("MCP 服务器配置", comment: ""))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(NSLocalizedString("取消", comment: "")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("保存", comment: "")) {
                        isSaving = true
                        Task {
                            defer { isSaving = false }
                            do { try await manager.saveServerInBackground(draft, replacing: original); dismiss() }
                            catch { self.error = error.localizedDescription }
                        }
                    }
                    .disabled(isSaving || !isValid || draft.displayName.isEmpty)
                }
            }
            .task {
                guard !didPrepare else { return }
                didPrepare = true
                await encodeTransport(draft.transport)
            }
            .task(id: configurationJSON) {
                isValid = false
                let source = configurationJSON
                guard !source.isEmpty else { return }
                do {
                    let transport = try await Task.detached {
                        try JSONDecoder().decode(MCPServerConfiguration.Transport.self, from: Data(source.utf8))
                    }.value
                    guard !Task.isCancelled, source == configurationJSON else { return }
                    switch transport {
                    case .localStdio(let configuration):
                        guard !configuration.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                              configuration.workingDirectory.hasPrefix("/"),
                              configuration.startupTimeoutSeconds.isFinite,
                              (0...3600).contains(configuration.startupTimeoutSeconds) else {
                            throw MCPConfigurationWriteError.invalidTransport
                        }
                    case .http(let endpoint, _, _):
                        guard GuideModelSetupValidation.isValidRemoteBaseURL(endpoint.absoluteString) else { throw MCPConfigurationWriteError.invalidTransport }
                    case .httpSSE(let messageEndpoint, let sseEndpoint, _, _):
                        guard GuideModelSetupValidation.isValidRemoteBaseURL(messageEndpoint.absoluteString),
                              GuideModelSetupValidation.isValidRemoteBaseURL(sseEndpoint.absoluteString) else { throw MCPConfigurationWriteError.invalidTransport }
                    case .oauth(let endpoint, let tokenEndpoint, let clientID, _, _, _, _, _, _):
                        guard !clientID.isEmpty, GuideModelSetupValidation.isValidRemoteBaseURL(endpoint.absoluteString),
                              GuideModelSetupValidation.isValidRemoteBaseURL(tokenEndpoint.absoluteString) else { throw MCPConfigurationWriteError.invalidTransport }
                    case .builtInSearch, .builtInAppTool, .builtInPersonalData:
                        guard transport == original?.transport else { throw MCPConfigurationWriteError.invalidTransport }
                    }
                    draft.transport = transport
                    error = nil
                    isValid = true
                } catch {
                    guard !Task.isCancelled, source == configurationJSON else { return }
                    self.error = error.localizedDescription
                }
            }
            .guidePageContext(
                descriptor: GuidePageDescriptor(
                    id: pageID, title: NSLocalizedString("MCP 服务器配置", comment: ""),
                    documents: [GuideDocumentReference(id: "mcp-tools", title: "MCP Tools"), GuideDocumentReference(id: "macos-workspace", title: "macOS Workspace")],
                    tools: [GuidePageTool(definition: GuideToolCatalog.updateMCPServer, access: .proposeChange)]
                ),
                snapshot: {
                    var fields = GuideMCPServerSettingsSupport.snapshot(server: draft, status: MCPServerStatus()).fields
                    fields["editing_mode"] = GuideSnapshotField(label: NSLocalizedString("编辑方式", comment: ""), value: .string("draft_until_save"), access: .readOnly)
                    fields["json_valid"] = GuideSnapshotField(label: NSLocalizedString("配置有效", comment: ""), value: .bool(isValid), access: .readOnly)
                    return GuidePageSnapshot(fields: fields)
                },
                buildProposal: { call, _ in
                    guard isValid else { throw GuideError.invalidToolArguments }
                    return try GuideMCPServerSettingsSupport.buildProposal(call: call, pageID: pageID, server: draft)
                },
                execute: { proposal in
                    guard isValid else { throw GuideError.invalidToolArguments }
                    let application = try GuideMCPServerSettingsSupport.apply(proposal, to: draft)
                    draft = application.server
                    await encodeTransport(draft.transport)
                    return GuideActionExecution(message: NSLocalizedString("已更新草稿，请保存配置以生效。", comment: ""), undoProposal: application.execution.undoProposal)
                }
            )
        }
        .modifier(MacGuideInspector())
        .frame(minWidth: 560, minHeight: 560)
    }

    private func replaceTransport(_ transport: MCPServerConfiguration.Transport) {
        draft.transport = transport
        isValid = false
        Task { await encodeTransport(transport) }
    }

    private func encodeTransport(_ transport: MCPServerConfiguration.Transport) async {
        let revision = UUID()
        encodingRevision = revision
        let text = await Task.detached {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            return (try? encoder.encode(transport)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        }.value
        guard encodingRevision == revision, !Task.isCancelled else { return }
        configurationJSON = text
    }
}
