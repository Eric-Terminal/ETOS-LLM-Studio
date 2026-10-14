import ETOSCore
import SwiftUI

struct MacTTSServiceEditor: View {
    @ObservedObject var model: MacTTSModel
    @StateObject private var draft: MacTTSServiceDraft
    @State private var sourceEpoch: UUID
    let isActive: Bool
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var visible = false
    @State private var working = false
    @State private var previewID = UUID()
    private var available: Bool { isActive && workspace.canManageLocalModels && !model.isSuspended && sourceEpoch == model.epoch }
    private var active: Bool { available && visible && model.canEdit && !draft.isPreparing && !working && !model.isExportPanelOpen }

    init(model: MacTTSModel, service: TTSServiceConfiguration, sourceEpoch: UUID, isActive: Bool) {
        self.model = model; self.isActive = isActive
        _draft = StateObject(wrappedValue: MacTTSServiceDraft(service)); _sourceEpoch = State(initialValue: sourceEpoch)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    MacSettingsIntroCard(id: "tts-service", title: NSLocalizedString("使用说明", comment: ""),
                        details: NSLocalizedString("Mac 语音服务使用说明", comment: ""), documentID: "tts", isActive: available)
                }
                if draft.isPreparing { ProgressView(NSLocalizedString("正在加载…", comment: "")) }
                else {
                    Section {
                        Picker(NSLocalizedString("接口类型", comment: ""), selection: Binding(get: { draft.service.providerKind }, set: { model.stopPreview(owner: previewID); draft.changeProvider($0) })) {
                            ForEach(TTSProviderKind.allCases, id: \.self) { Text($0.localizedName).tag($0) }
                        }
                        TextField(NSLocalizedString("名称", comment: ""), text: $draft.service.name)
                        TextField(draft.service.providerKind == .qwenAudio ? NSLocalizedString("WebSocket URL", comment: "") : NSLocalizedString("Base URL", comment: ""), text: $draft.service.baseURL)
                        SecureField(NSLocalizedString("API Key", comment: ""), text: $draft.service.apiKey)
                        if draft.fields.contains(.modelID) { TextField(NSLocalizedString("模型 ID", comment: ""), text: $draft.service.modelID) }
                    } header: { Text(NSLocalizedString("服务", comment: "")) }
                    Section {
                        TextField(NSLocalizedString("Voice / Voice ID / Reference ID", comment: ""), text: $draft.service.voice)
                        if !draft.voiceOptions.isEmpty {
                            Menu(NSLocalizedString("推荐 Voice", comment: "")) { ForEach(draft.voiceOptions, id: \.self) { value in Button(value) { draft.service.voice = value } } }
                        }
                        if draft.fields.contains(.responseFormat) {
                            TextField(NSLocalizedString("格式", comment: ""), text: $draft.service.responseFormat)
                            Menu(NSLocalizedString("格式", comment: "")) { ForEach(draft.formatOptions, id: \.self) { value in Button(value) { draft.service.responseFormat = value } } }
                        }
                        if draft.fields.contains(.language) {
                            TextField(NSLocalizedString("语言", comment: ""), text: $draft.service.languageType)
                            Menu(NSLocalizedString("推荐语言", comment: "")) { ForEach(draft.languageOptions, id: \.self) { value in Button(value) { draft.service.languageType = value } } }
                        }
                        if draft.fields.contains(.emotion) {
                            TextField(NSLocalizedString("情感", comment: ""), text: $draft.service.miniMaxEmotion)
                            Menu(NSLocalizedString("情感", comment: "")) { ForEach(draft.emotionOptions, id: \.self) { value in Button(value) { draft.service.miniMaxEmotion = value } } }
                        }
                        Button(NSLocalizedString("恢复推荐参数", comment: "")) { draft.resetRecommendations() }
                    } header: { Text(NSLocalizedString("语音", comment: "")) }
                    if draft.hasAdvancedFields { MacTTSAdvancedFields(draft: draft) }
                    Section {
                        Button(NSLocalizedString("试听此服务", comment: "")) {
                            working = true
                            Task {
                                let service = await draft.preparedService()
                                working = false
                                if active { model.preview(settings: model.draft, service: service, owner: previewID) }
                            }
                        }.disabled(!draft.isReady)
                        MacTTSPlaybackView(model: model, isActive: available)
                    } footer: {
                        Text(NSLocalizedString("试听会直接使用当前页面中的参数，无需先保存。", comment: "")).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped).buttonStyle(.borderless)
            .disabled(!available || model.isSaving || working)
            .navigationTitle(NSLocalizedString("编辑语音服务", comment: ""))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(NSLocalizedString("关闭", comment: "")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("保存", comment: "")) {
                        working = true
                        Task {
                            let service = await draft.preparedService()
                            working = false
                            guard active else { return }
                            if await model.saveService(service, expectedEpoch: sourceEpoch) { dismiss() }
                        }
                    }.disabled(!active || !draft.isReady)
                }
            }
            .guideSettingsPageContext(id: GuidePageID(rawValue: "mac-tts-service-\(draft.service.id)-\(sourceEpoch)-\(draft.service.providerKind.rawValue)"),
                title: NSLocalizedString("编辑语音服务", comment: ""), documents: [GuideDocumentReference(id: "tts", title: "Text to Speech")],
                isActive: active, settings: guideSettings)
            .modifier(MacGuideInspector())
        }
        .frame(minWidth: 560, minHeight: 560)
        .onAppear { visible = true; draft.resume() }
        .onDisappear { visible = false; draft.cancel(); model.stopPreview(owner: previewID) }
        .onChange(of: available) { _, value in if !value { model.stopPreview(owner: previewID); dismiss() } }
    }

    private var guideSettings: [GuidePageSetting] {
        var fields: [GuidePageSetting] = [
            .string("provider_kind", label: NSLocalizedString("接口类型", comment: ""), allowedValues: TTSProviderKind.allCases.map(\.rawValue), get: { draft.service.providerKind.rawValue }, set: { if let kind = TTSProviderKind(rawValue: $0) { model.stopPreview(owner: previewID); draft.changeProvider(kind) } }),
            .string("name", label: NSLocalizedString("名称", comment: ""), get: { draft.service.name }, set: { draft.service.name = $0 }),
            .string("base_url", label: NSLocalizedString("Base URL", comment: ""), get: { draft.service.baseURL }, set: { draft.service.baseURL = $0 }),
            .writeOnlyString("api_key", label: NSLocalizedString("API Key", comment: ""), isConfigured: { !draft.service.apiKey.isEmpty }, set: { draft.service.apiKey = $0 }),
            .string("voice", label: NSLocalizedString("Voice", comment: ""), get: { draft.service.voice }, set: { draft.service.voice = $0 }),
            .readOnly("requires_save", label: NSLocalizedString("应用方式", comment: ""), value: { .string(NSLocalizedString("修改后需要保存", comment: "")) }),
            .readOnly("playback_status", label: NSLocalizedString("播放状态", comment: ""), value: { .string(model.player.playbackState.status.rawValue) }),
            .readOnly("requires_manual_preview", label: NSLocalizedString("试听", comment: ""), value: { .bool(true) })
        ]
        if draft.fields.contains(.modelID) { fields.append(.string("model_id", label: NSLocalizedString("模型 ID", comment: ""), get: { draft.service.modelID }, set: { draft.service.modelID = $0 })) }
        if draft.fields.contains(.responseFormat) { fields.append(.string("response_format", label: NSLocalizedString("格式", comment: ""), get: { draft.service.responseFormat }, set: { draft.service.responseFormat = $0 })) }
        if draft.fields.contains(.language) { fields.append(.string("language", label: NSLocalizedString("语言", comment: ""), get: { draft.service.languageType }, set: { draft.service.languageType = $0 })) }
        if draft.fields.contains(.emotion) { fields.append(.string("emotion", label: NSLocalizedString("情感", comment: ""), get: { draft.service.miniMaxEmotion }, set: { draft.service.miniMaxEmotion = $0 })) }
        return fields + MacTTSAdvancedFields.guideSettings(draft)
    }
}
