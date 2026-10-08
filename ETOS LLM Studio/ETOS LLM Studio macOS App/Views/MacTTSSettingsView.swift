import ETOSCore
import SwiftUI

struct MacTTSSettingsView: View {
    @ObservedObject var model: MacTTSModel
    let isActive: Bool
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @ObservedObject private var configuration = AppConfigStore.shared
    @State private var visible = false
    @State private var editor: TTSServiceConfiguration?
    @State private var deleting: (id: UUID, epoch: UUID)?
    @State private var confirmsReload = false
    @State private var previewID = UUID()
    private var available: Bool { isActive && workspace.canManageLocalModels && !model.isSuspended }
    private var active: Bool { available && visible && model.canEdit && editor == nil && deleting == nil && !confirmsReload && !model.isExportPanelOpen }

    var body: some View {
        Form {
            Section {
                MacSettingsIntroCard(id: "tts", title: NSLocalizedString("使用说明", comment: ""),
                    details: NSLocalizedString("Mac 朗读使用说明", comment: ""), documentID: "tts", isActive: available)
            }
            if model.isLoaded {
                Section {
                    Picker(NSLocalizedString("朗读方式", comment: ""), selection: $model.draft.playbackMode) {
                        Text(NSLocalizedString("系统朗读", comment: "")).tag(TTSPlaybackMode.system)
                        Text(NSLocalizedString("云端朗读", comment: "")).tag(TTSPlaybackMode.cloud)
                        Text(NSLocalizedString("自动", comment: "")).tag(TTSPlaybackMode.auto)
                    }
                    Toggle(NSLocalizedString("回复完成后自动朗读", comment: ""), isOn: $model.draft.autoPlayAfterAssistantResponse)
                    Slider(value: $model.draft.speechRate, in: 0.1...3) { Text(NSLocalizedString("朗读语速", comment: "")) }
                    Slider(value: $model.draft.pitch, in: 0.1...2) { Text(NSLocalizedString("音调", comment: "")) }
                    Slider(value: $model.draft.playbackSpeed, in: 0.5...2) { Text(NSLocalizedString("播放倍速", comment: "")) }
                    TextField(NSLocalizedString("Voice", comment: ""), text: $model.draft.voice)
                    Menu(NSLocalizedString("系统朗读", comment: "")) {
                        Button(NSLocalizedString("自动", comment: "")) { model.draft.voice = "" }
                        ForEach(model.voices) { voice in Button(voice.title) { model.draft.voice = voice.id } }
                    }
                    Toggle(NSLocalizedString("轻量预处理", comment: ""), isOn: $model.draft.watchUseLightweightPreprocess)
                    Stepper(value: $model.draft.watchSpeechMaxCharacters, in: 500...6_000, step: 250) {
                        LabeledContent(NSLocalizedString("手表朗读字数上限", comment: ""), value: "\(model.draft.watchSpeechMaxCharacters)")
                    }
                    Button(NSLocalizedString("试听", comment: "")) { model.preview(settings: model.draft, service: nil, owner: previewID) }
                } header: { Text(NSLocalizedString("朗读设置", comment: "")) } footer: {
                    Text(NSLocalizedString("Mac 朗读参数草稿说明", comment: "")).font(.footnote).foregroundStyle(.secondary)
                }
                .disabled(!available || !model.canEdit)
                Section {
                    Toggle(NSLocalizedString("后台继续朗读", comment: ""), isOn: $configuration.continueTTSPlaybackInBackground)
                    Toggle(NSLocalizedString("缓存网络音频用于重播", comment: ""), isOn: $configuration.ttsCacheNetworkAudioForReplay)
                    Toggle(NSLocalizedString("过滤代码和 HTML", comment: ""), isOn: $configuration.ttsFilterCodeAndHTML)
                    Picker(NSLocalizedString("朗读内容", comment: ""), selection: selectionMode) {
                        ForEach(TTSTextSelectionMode.allCases, id: \.self) { Text($0.localizedName).tag($0.rawValue) }
                    }
                } header: { Text(NSLocalizedString("行为", comment: "")) } footer: {
                    Text(NSLocalizedString("Mac 朗读行为立即保存说明", comment: "")).font(.footnote).foregroundStyle(.secondary)
                }.disabled(!available || !model.canEdit)
                Section {
                    ForEach(model.presentation?.rows ?? []) { row in
                        HStack {
                            Button { model.selectService(row.id) } label: {
                                Image(systemName: model.presentation?.snapshot.selectedServiceID == row.id ? "checkmark.circle.fill" : "circle")
                            }.accessibilityLabel(NSLocalizedString("选择", comment: ""))
                            VStack(alignment: .leading) {
                                Text(row.title)
                                Text(row.ready ? row.kind : NSLocalizedString("配置不完整", comment: "")).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(NSLocalizedString("编辑", comment: "")) { editor = model.presentation?.servicesByID[row.id] }
                            Menu {
                                Button(NSLocalizedString("上移", comment: "")) { model.moveService(row.id, offset: -1) }
                                Button(NSLocalizedString("下移", comment: "")) { model.moveService(row.id, offset: 1) }
                                Button(NSLocalizedString("删除", comment: ""), role: .destructive) { deleting = (row.id, model.epoch) }
                            } label: { Image(systemName: "ellipsis") }
                        }
                    }
                    Button(NSLocalizedString("添加语音服务", comment: "")) { editor = .defaultConfiguration(for: .openAICompatible) }
                } header: { Text(NSLocalizedString("云端语音服务", comment: "")) }
                .disabled(!available || !model.canEdit)
            }
            if model.isLoading || model.isSaving { ProgressView(NSLocalizedString("处理中", comment: "")) }
            Section { MacTTSPlaybackView(model: model, isActive: available) }
        }
        .buttonStyle(.borderless)
        .formStyle(.grouped)
        .navigationTitle(NSLocalizedString("语音输出", comment: ""))
        .toolbar {
            Button(NSLocalizedString("重新载入", comment: "")) { confirmsReload = true }
                .disabled(!available || model.isLoading || model.isSaving || model.isStopping || editor != nil || model.isExportPanelOpen)
            Button(NSLocalizedString("保存", comment: "")) { model.saveSettings() }.disabled(!active)
        }
        .confirmationDialog(NSLocalizedString("重新载入会丢弃当前草稿。", comment: ""), isPresented: $confirmsReload, titleVisibility: .visible) {
            Button(NSLocalizedString("重新载入", comment: ""), role: .destructive) { if available { model.reload() } }
        }
        .confirmationDialog(NSLocalizedString("删除语音服务", comment: ""), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button(NSLocalizedString("删除", comment: ""), role: .destructive) {
                if available, let deleting { model.deleteService(deleting.id, expectedEpoch: deleting.epoch) }
                deleting = nil
            }
        }
        .sheet(item: $editor) { service in
            MacTTSServiceEditor(model: model, service: service, sourceEpoch: model.epoch, isActive: available)
        }
        .guideSettingsPageContext(id: GuidePageID(rawValue: "mac-tts-\(model.epoch)"), title: NSLocalizedString("语音输出", comment: ""),
            documents: [GuideDocumentReference(id: "tts", title: "Text to Speech")], isActive: active, settings: guideSettings)
        .onAppear { visible = true; if available && !model.isLoaded { model.reload() } }
        .onDisappear { visible = false; model.stopPreview(owner: previewID) }
        .onChange(of: available) { _, value in if !value { editor = nil; deleting = nil; confirmsReload = false; model.stopPreview(owner: previewID) } }
        .onChange(of: model.epoch) { _, _ in deleting = nil; confirmsReload = false; model.stopPreview(owner: previewID) }
    }

    private var selectionMode: Binding<String> {
        Binding(get: { TTSTextSelectionMode(rawValue: configuration.ttsTextSelectionMode)?.rawValue
            ?? (model.draft.onlyReadQuotedContent ? TTSTextSelectionMode.quotedOnly.rawValue : TTSTextSelectionMode.fullText.rawValue) },
            set: { configuration.ttsTextSelectionMode = $0 })
    }

    private var guideSettings: [GuidePageSetting] {
        var result: [GuidePageSetting] = [
            .string("playback_mode", label: NSLocalizedString("朗读方式", comment: ""), allowedValues: ["system", "cloud", "auto"], get: { model.draft.playbackMode.rawValue }, set: { if let value = TTSPlaybackMode(rawValue: $0) { model.draft.playbackMode = value } }),
            .bool("auto_play", label: NSLocalizedString("回复完成后自动朗读", comment: ""), get: { model.draft.autoPlayAfterAssistantResponse }, set: { model.draft.autoPlayAfterAssistantResponse = $0 }),
            .double("speech_rate", label: NSLocalizedString("朗读语速", comment: ""), range: 0.1...3, get: { Double(model.draft.speechRate) }, set: { model.draft.speechRate = Float($0) }),
            .double("pitch", label: NSLocalizedString("音调", comment: ""), range: 0.1...2, get: { Double(model.draft.pitch) }, set: { model.draft.pitch = Float($0) }),
            .double("playback_speed", label: NSLocalizedString("播放倍速", comment: ""), range: 0.5...2, get: { Double(model.draft.playbackSpeed) }, set: { model.draft.playbackSpeed = Float($0) }),
            .string("system_voice", label: NSLocalizedString("Voice", comment: ""), get: { model.draft.voice }, set: { model.draft.voice = $0 }),
            .bool("watch_lightweight", label: NSLocalizedString("轻量预处理", comment: ""), get: { model.draft.watchUseLightweightPreprocess }, set: { model.draft.watchUseLightweightPreprocess = $0 }),
            .integer("watch_character_limit", label: NSLocalizedString("手表朗读字数上限", comment: ""), range: 500...6_000, get: { model.draft.watchSpeechMaxCharacters }, set: { model.draft.watchSpeechMaxCharacters = $0 }),
            .bool("background_playback", label: NSLocalizedString("后台继续朗读", comment: ""), get: { configuration.continueTTSPlaybackInBackground }, set: { configuration.continueTTSPlaybackInBackground = $0 }),
            .bool("cache_network_audio", label: NSLocalizedString("缓存网络音频用于重播", comment: ""), get: { configuration.ttsCacheNetworkAudioForReplay }, set: { configuration.ttsCacheNetworkAudioForReplay = $0 }),
            .bool("filter_code_and_html", label: NSLocalizedString("过滤代码和 HTML", comment: ""), get: { configuration.ttsFilterCodeAndHTML }, set: { configuration.ttsFilterCodeAndHTML = $0 }),
            .string("text_selection_mode", label: NSLocalizedString("朗读内容", comment: ""), allowedValues: TTSTextSelectionMode.allCases.map(\.rawValue), get: { selectionMode.wrappedValue }, set: { selectionMode.wrappedValue = $0 }),
            .readOnly("services", label: NSLocalizedString("服务", comment: ""), value: { model.presentation?.guideValue ?? .array([]) }),
            .readOnly("playback_status", label: NSLocalizedString("播放状态", comment: ""), value: { .string(model.player.playbackState.status.rawValue) }),
            .readOnly("application", label: NSLocalizedString("应用方式", comment: ""), value: { .string(NSLocalizedString("Mac 朗读行为立即保存说明", comment: "")) }),
            .readOnly("requires_manual_playback", label: NSLocalizedString("试听", comment: ""), value: { .bool(true) })
        ]
        if let ids = model.presentation?.identifiers, !ids.isEmpty {
            result.append(.string("selected_service", label: NSLocalizedString("云端语音服务", comment: ""), allowedValues: ids,
                get: { model.presentation?.snapshot.selectedServiceID?.uuidString ?? "" }, set: { model.selectService(UUID(uuidString: $0)) }))
        } else {
            result.append(.readOnly("selected_service", label: NSLocalizedString("云端语音服务", comment: ""), value: { .string("") }))
        }
        return result
    }
}
