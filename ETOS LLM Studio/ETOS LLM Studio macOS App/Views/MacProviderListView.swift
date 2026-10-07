import ETOSCore
import SwiftUI

struct MacProviderListView: View {
    let isActive: Bool
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @State private var editingProvider: Provider?
    @State private var deletingProvider: Provider?

    var body: some View {
        List {
            Section {
                MacSettingsIntroCard(id: "providers", title: NSLocalizedString("使用说明", comment: ""), details: NSLocalizedString("添加提供商地址和 API Key 后，获取模型列表或手动添加模型。启用的聊天模型会出现在聊天窗口的模型选择器中。", comment: ""), documentID: "provider-model-basics")
                NavigationLink {
                    MacLocalModelLibraryView(isActive: isActive, library: workspace.localModels)
                } label: {
                    Label(NSLocalizedString("本地模型", comment: ""), systemImage: "internaldrive")
                }
            }
            ForEach(workspace.providers) { provider in
                Button { editingProvider = provider } label: {
                    VStack(alignment: .leading) {
                        Text(provider.name)
                        Text(provider.baseURL).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button(NSLocalizedString("删除", comment: ""), role: .destructive) { deletingProvider = provider }
                }
            }
        }
        .navigationTitle(NSLocalizedString("模型管理", comment: ""))
        .toolbar {
            Button {
                editingProvider = Provider(name: "", baseURL: "", apiKeys: [], apiFormat: "openai-compatible")
            } label: {
                Label(NSLocalizedString("添加提供商", comment: ""), systemImage: "plus")
            }
        }
        .sheet(item: $editingProvider) { provider in
            MacProviderEditor(provider: provider, original: workspace.providers.first { $0.id == provider.id })
        }
        .confirmationDialog(NSLocalizedString("确认删除提供商", comment: ""), isPresented: Binding(
            get: { deletingProvider != nil }, set: { if !$0 { deletingProvider = nil } }
        ), titleVisibility: .visible) {
            Button(NSLocalizedString("删除", comment: ""), role: .destructive) {
                if let deletingProvider, let service = workspace.service {
                    Task.detached { service.deleteProvider(deletingProvider) }
                }
                deletingProvider = nil
            }
        }
        .guidePageContext(
            descriptor: GuidePageDescriptor(id: "mac-providers", title: NSLocalizedString("模型管理", comment: ""), documents: [GuideDocumentReference(id: "provider-model-basics", title: "Provider and Model Basics")]),
            isActive: isActive,
            snapshot: {
                GuidePageSnapshot(fields: ["providers": GuideSnapshotField(
                    label: NSLocalizedString("提供商", comment: ""),
                    value: .array(workspace.providers.map { .dictionary(["id": .string($0.id.uuidString), "name": .string($0.name)]) }),
                    access: .readOnly
                )])
            }
        )
    }
}

private struct MacProviderEditor: View {
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @Environment(\.dismiss) private var dismiss
    private let original: Provider?
    @State private var draft: Provider
    @StateObject private var keys: ProviderAPIKeyEditorModel
    @State private var headers = ""
    @State private var modelToEdit: Model?
    @State private var isBusy = false
    @State private var error: String?
    @State private var didPrepare = false
    @State private var testSource: MacModelConnectivitySource?
    @State private var testPreparation: Task<Void, Never>?

    init(provider: Provider, original: Provider?) {
        self.original = original
        _draft = State(initialValue: provider)
        _keys = StateObject(wrappedValue: ProviderAPIKeyEditorModel(provider: provider))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(NSLocalizedString("名称", comment: ""), text: $draft.name)
                    TextField(NSLocalizedString("API 地址", comment: ""), text: $draft.baseURL)
                    Picker(NSLocalizedString("API 格式", comment: ""), selection: $draft.apiFormat) {
                        if LocalModelProviderBridge.isLocalProvider(draft) {
                            Text(NSLocalizedString("本地模型", comment: "")).tag(LocalModelProviderBridge.apiFormat)
                        }
                        Text(NSLocalizedString("OpenAI 兼容", comment: "")).tag("openai-compatible")
                        Text(NSLocalizedString("OpenAI Responses", comment: "")).tag("openai-responses")
                        Text(NSLocalizedString("Anthropic", comment: "")).tag("anthropic")
                        Text(NSLocalizedString("Gemini", comment: "")).tag("gemini")
                    }
                    TextField(NSLocalizedString("聊天端点后缀", comment: ""), text: $draft.chatEndpointPath)
                    Toggle(NSLocalizedString("多 Key 模式", comment: ""), isOn: $keys.draft.multiKeyEnabled)
                    NavigationLink(NSLocalizedString("管理 API Key", comment: "")) {
                        ProviderAPIKeyManagementForm(editor: keys, providerID: draft.id)
                    }
                } footer: {
                    Text(NSLocalizedString("修改保留为草稿，点击保存后生效。", comment: ""))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    ForEach($draft.models) { $model in
                        Button { modelToEdit = model } label: {
                            Label(model.displayName, systemImage: model.isActivated ? "checkmark.circle" : "circle")
                        }
                        .buttonStyle(.borderless)
                    }
                    Button(NSLocalizedString("添加模型", comment: "")) {
                        modelToEdit = Model(modelName: "", isActivated: true)
                    }
                    Button(NSLocalizedString("获取模型列表", comment: "")) { fetchModels() }
                        .disabled(isBusy)
                    if !LocalModelProviderBridge.isLocalProvider(draft) {
                        Button(NSLocalizedString("模型测试", comment: "")) {
                            testPreparation = Task {
                                do { testSource = try await prepareTestSource(model: nil) }
                                catch { if !Task.isCancelled { self.error = error.localizedDescription } }
                            }
                        }.disabled(!workspace.canRunModelTests)
                    }
                } header: { Text(NSLocalizedString("模型", comment: "")) }
                Section {
                    NavigationLink(NSLocalizedString("请求头 JSON", comment: "")) {
                        MacJSONDraftEditor(pageID: GuidePageID(rawValue: "mac-provider-headers-\(draft.id)"), title: NSLocalizedString("请求头 JSON", comment: ""), kind: .stringDictionary, text: $headers)
                    }
                } header: { Text(NSLocalizedString("请求头 JSON", comment: "")) }
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            }
            .formStyle(.grouped)
            .disabled(isBusy || !didPrepare || workspace.isRestoringData)
            .navigationTitle(NSLocalizedString("提供商配置", comment: ""))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(NSLocalizedString("取消", comment: "")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("保存", comment: "")) { save() }
                        .disabled(isBusy || draft.name.isEmpty || draft.baseURL.isEmpty || !keys.retryInputIsValid)
                }
            }
            .sheet(item: $modelToEdit) { model in
                MacModelEditor(model: model, providerAPIFormat: draft.apiFormat, supportsConnectivityTest: !LocalModelProviderBridge.isLocalProvider(draft), prepareTestSource: { model in
                    try await prepareTestSource(model: model)
                }) { updated in
                    if let index = draft.models.firstIndex(where: { $0.id == updated.id }) { draft.models[index] = updated }
                    else { draft.models.append(updated) }
                }
            }
            .sheet(item: $testSource) { MacModelConnectivityTestView(source: $0) }
            .task {
                guard !didPrepare else { return }
                let values = draft.headerOverrides
                let prepared = await Task.detached {
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    return (try? encoder.encode(values)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
                }.value
                guard !Task.isCancelled else { return }
                headers = prepared; didPrepare = true
            }
            .guideSettingsPageContext(
                id: GuidePageID(rawValue: "mac-provider-\(draft.id)"), title: NSLocalizedString("提供商配置", comment: ""),
                documents: [GuideDocumentReference(id: "provider-model-basics", title: "Provider and Model Basics")],
                settings: [
                    .readOnly("editing_mode", label: NSLocalizedString("编辑方式", comment: ""), value: { .string("draft_until_save") })
                ] + (isBusy || !didPrepare || workspace.isRestoringData ? [] : [
                    .string("name", label: NSLocalizedString("名称", comment: ""), get: { draft.name }, set: { draft.name = $0 }),
                    .string("base_url", label: NSLocalizedString("API 地址", comment: ""), get: { draft.baseURL }, set: { draft.baseURL = $0 }),
                    .string("api_format", label: NSLocalizedString("API 格式", comment: ""), allowedValues: ["openai-compatible", "openai-responses", "anthropic", "gemini"], get: { draft.apiFormat }, set: { draft.apiFormat = $0 }),
                    .string("chat_endpoint", label: NSLocalizedString("聊天端点后缀", comment: ""), get: { draft.chatEndpointPath }, set: { draft.chatEndpointPath = $0 }),
                    .bool("multi_key", label: NSLocalizedString("多 Key 模式", comment: ""), get: { keys.draft.multiKeyEnabled }, set: { keys.draft.multiKeyEnabled = $0 }),
                    .writeOnlyString("api_keys", label: NSLocalizedString("API Key", comment: ""), isConfigured: { keys.keyCount > 0 }, set: { keys.replaceKeys(from: $0) })
                ])
            )
        }
        .modifier(MacGuideInspector())
        .frame(minWidth: 560, minHeight: 600)
        .onDisappear { testPreparation?.cancel() }
        .onChange(of: workspace.isRestoringData) { _, restoring in if restoring { testPreparation?.cancel(); dismiss() } }
    }

    private func prepareTestSource(model: Model?) async throws -> MacModelConnectivitySource {
        guard !isBusy, didPrepare, workspace.canRunModelTests, !LocalModelProviderBridge.isLocalProvider(draft) else { throw GuideError.pageChanged }
        isBusy = true
        defer { isBusy = false }
        var provider = draft
        keys.apply(to: &provider)
        let text = headers, source = provider
        let prepared = try await Task.detached { try MacModelConnectivitySource.preparedProvider(source, headers: text) }.value
        try Task.checkCancellation()
        guard workspace.canRunModelTests else { throw GuideError.pageChanged }
        return MacModelConnectivitySource(provider: prepared, originalProvider: original, model: model)
    }

    private func fetchModels() {
        guard let service = workspace.service else { return }
        var provider = draft
        keys.apply(to: &provider)
        isBusy = true
        Task {
            defer { isBusy = false }
            do {
                let fetched = try await service.fetchModels(for: provider)
                let existingNames = Set(draft.models.map(\.modelName))
                draft.models.append(contentsOf: fetched.filter { !existingNames.contains($0.modelName) })
            } catch { self.error = error.localizedDescription }
        }
    }

    private func save() {
        guard let service = workspace.service else { return }
        if workspace.providers.first(where: { $0.id == draft.id }) != original {
            error = NSLocalizedString("配置已在其他页面修改，请重新打开后再编辑。", comment: "")
            return
        }
        var updated = draft
        guard LocalModelProviderBridge.isLocalProvider(updated) || GuideModelSetupValidation.isValidRemoteBaseURL(updated.baseURL) else {
            error = NSLocalizedString("请输入有效的 API 地址。", comment: "")
            return
        }
        keys.apply(to: &updated)
        let text = headers
        isBusy = true
        Task {
            defer { isBusy = false }
            do {
                let headers = try await Task.detached {
                    try JSONDecoder().decode([String: String].self, from: Data(text.utf8))
                }.value
                updated.headerOverrides = headers
                let saved = updated
                let original = self.original
                try await Task.detached {
                    guard service.providersSubject.value.first(where: { $0.id == saved.id }) == original else {
                        throw MCPConfigurationWriteError.changedExternally
                    }
                    service.saveProviderFromManagement(saved)
                }.value
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}
