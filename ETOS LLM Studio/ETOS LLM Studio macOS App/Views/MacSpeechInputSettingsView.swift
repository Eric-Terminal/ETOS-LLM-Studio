import ETOSCore
import SwiftUI

struct MacSpeechInputSettingsView: View {
    @ObservedObject var model: MacSpeechInputModel
    let isActive: Bool
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @ObservedObject private var configuration = AppConfigStore.shared
    @State private var visible = false
    private var available: Bool { isActive && workspace.canManageLocalModels && !model.isSuspended }

    var body: some View {
        Form {
            Section {
                MacSettingsIntroCard(id: "speech-input", title: NSLocalizedString("使用说明", comment: ""),
                    details: NSLocalizedString("Mac 语音输入使用说明", comment: ""), documentID: "speech-input", isActive: available)
            }
            Section {
                Toggle(NSLocalizedString("启用语音输入", comment: ""), isOn: $configuration.enableSpeechInput)
                Toggle(NSLocalizedString("模型支持时发送音频", comment: ""), isOn: $configuration.sendSpeechAsAudio)
                Picker(NSLocalizedString("音频录制格式", comment: ""), selection: $configuration.audioRecordingFormat) {
                    Text(NSLocalizedString("AAC (M4A)", comment: "")).tag(AudioRecordingFormat.aac.rawValue)
                    Text(NSLocalizedString("WAV", comment: "")).tag(AudioRecordingFormat.wav.rawValue)
                }
                NavigationLink(NSLocalizedString("语音识别模型", comment: "")) {
                    MacSpeechModelSelectionView(model: model, isActive: available)
                }
            } footer: {
                Text(NSLocalizedString("Mac 语音草稿说明", comment: "")).font(.footnote).foregroundStyle(.secondary)
            }
            .disabled(!available)
        }
        .formStyle(.grouped)
        .navigationTitle(NSLocalizedString("语音输入", comment: ""))
        .guideSettingsPageContext(
            id: "mac-speech-input-settings", title: NSLocalizedString("语音输入", comment: ""),
            documents: [GuideDocumentReference(id: "speech-input", title: "Speech Input")], isActive: available && visible,
            settings: [
                .bool("enabled", label: NSLocalizedString("启用语音输入", comment: ""), get: { configuration.enableSpeechInput }, set: { configuration.enableSpeechInput = $0 }),
                .bool("send_audio_when_supported", label: NSLocalizedString("模型支持时发送音频", comment: ""), get: { configuration.sendSpeechAsAudio }, set: { configuration.sendSpeechAsAudio = $0 }),
                .string("recording_format", label: NSLocalizedString("音频录制格式", comment: ""), allowedValues: ["aac", "wav"], get: { configuration.audioRecordingFormat }, set: { configuration.audioRecordingFormat = $0 }),
                .readOnly("model_requires_navigation", label: NSLocalizedString("语音识别模型", comment: ""), value: { .bool(true) })
            ]
        )
        .onAppear { visible = true }.onDisappear { visible = false }
    }
}

private struct MacSpeechModelSelectionView: View {
    @ObservedObject var model: MacSpeechInputModel
    let isActive: Bool
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @ObservedObject private var configuration = AppConfigStore.shared
    @State private var visible = false
    private var available: Bool { isActive && workspace.canManageLocalModels && !model.isSuspended }

    var body: some View {
        List {
            Button { configuration.speechModelIdentifier = "" } label: {
                Label(NSLocalizedString("自动选择", comment: ""), systemImage: model.catalog.byID[configuration.speechModelIdentifier] == nil ? "checkmark.circle.fill" : "circle")
            }.buttonStyle(.plain)
            ForEach(model.catalog.rows) { row in
                Button { configuration.speechModelIdentifier = row.id } label: {
                    HStack {
                        Image(systemName: configuration.speechModelIdentifier == row.id ? "checkmark.circle.fill" : "circle")
                        VStack(alignment: .leading) {
                            Text(row.title)
                            Text(row.subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.buttonStyle(.plain)
            }
        }
        .disabled(!available)
        .navigationTitle(NSLocalizedString("语音识别模型", comment: ""))
        .guideSettingsPageContext(
            id: GuidePageID(rawValue: "mac-speech-models-\(model.catalogID)"), title: NSLocalizedString("语音识别模型", comment: ""),
            documents: [GuideDocumentReference(id: "speech-input", title: "Speech Input")], isActive: available && visible,
            settings: [
                .string("selected_model_id", label: NSLocalizedString("当前语音识别模型", comment: ""), allowedValues: model.catalog.identifiers,
                    get: { configuration.speechModelIdentifier }, set: { configuration.speechModelIdentifier = $0 }),
                .readOnly("available_models", label: NSLocalizedString("可用模型", comment: ""), value: { model.catalog.guideValue })
            ]
        )
        .onAppear { visible = true }.onDisappear { visible = false }
    }
}
