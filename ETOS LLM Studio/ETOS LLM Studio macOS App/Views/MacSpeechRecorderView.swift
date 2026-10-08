import ETOSCore
import SwiftUI

struct MacSpeechRecorderView: View {
    @ObservedObject var model: MacSpeechInputModel
    let source: MacSpeechInputSource
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var configuration = AppConfigStore.shared
    @State private var visible = false
    private var phase: MacSpeechInputModel.Phase { model.source?.id == source.id ? model.phase : .idle }
    private var available: Bool {
        workspace.canManageLocalModels && !model.isSuspended && configuration.enableSpeechInput
            && workspace.currentSession?.id == source.sessionID && workspace.incomingDocuments.contextID == source.composerContextID
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    MacSettingsIntroCard(id: "speech-recorder-\(source.id)", title: NSLocalizedString("使用说明", comment: ""),
                        details: NSLocalizedString("Mac 语音输入使用说明", comment: ""), documentID: "speech-input", isActive: available)
                    Text(source.sendsAudio ? NSLocalizedString("录制语音", comment: "") : NSLocalizedString("语音转文字", comment: ""))
                    if let speechModel = source.model { Text(speechModel.model.displayName).font(.caption).foregroundStyle(.secondary) }
                }
                Section {
                    switch phase {
                    case .idle:
                        Button(NSLocalizedString("开始录音", comment: "")) { model.begin(source) }
                    case .preparing, .processing, .transcribing:
                        ProgressView(NSLocalizedString("处理中", comment: ""))
                    case .recording:
                        if let start = model.recordedAt { Text(start, style: .timer).monospacedDigit() }
                        Button(NSLocalizedString("停止录音", comment: "")) { model.stopRecording(sourceID: source.id) }
                    case .preview:
                        if let attachment = model.attachment { MacAudioPreviewView(attachment: attachment, isActive: available && visible) }
                        if !source.sendsAudio {
                            Button(NSLocalizedString("转写", comment: "")) { model.transcribe(sourceID: source.id) }
                            TextEditor(text: Binding(get: { model.source?.id == source.id ? model.transcript : "" },
                                set: { if model.source?.id == source.id { model.transcript = $0 } })).frame(minHeight: 120)
                                .accessibilityLabel(NSLocalizedString("识别结果", comment: ""))
                        }
                        Button(NSLocalizedString("重新录音", comment: "")) { model.begin(source) }
                    }
                } footer: {
                    Text(NSLocalizedString("Mac 语音草稿说明", comment: "")).font(.footnote).foregroundStyle(.secondary)
                }
                if let error = model.error { Text(error).font(.footnote).foregroundStyle(.secondary) }
            }
            .formStyle(.grouped).disabled(!available)
            .navigationTitle(NSLocalizedString("语音输入", comment: ""))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(NSLocalizedString("取消", comment: "")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(source.sendsAudio ? NSLocalizedString("添加附件", comment: "") : NSLocalizedString("插入文字", comment: "")) {
                        guard available, let result = model.result(sourceID: source.id) else { return }
                        if workspace.applySpeechInput(result, source: source) { dismiss() }
                    }.disabled(!available || model.result(sourceID: source.id) == nil)
                }
            }
            .guideSettingsPageContext(
                id: GuidePageID(rawValue: "mac-speech-recorder-\(source.id)"), title: NSLocalizedString("语音输入", comment: ""),
                documents: [GuideDocumentReference(id: "speech-input", title: "Speech Input")], isActive: visible && available,
                settings: [
                    .readOnly("source_session_id", label: NSLocalizedString("对话", comment: ""), value: { .string(source.sessionID.uuidString) }),
                    .readOnly("phase", label: NSLocalizedString("状态", comment: ""), value: { .string(phase.rawValue) }),
                    .readOnly("send_audio", label: NSLocalizedString("模型支持时发送音频", comment: ""), value: { .bool(source.sendsAudio) }),
                    .readOnly("has_transcript", label: NSLocalizedString("识别结果", comment: ""), value: { .bool(!model.transcript.isEmpty) }),
                    .readOnly("requires_manual_send", label: NSLocalizedString("发送", comment: ""), value: { .bool(true) })
                ]
            )
        }
        .modifier(MacGuideInspector())
        .frame(minWidth: 500, minHeight: 420)
        .onAppear { visible = true; if !available { dismiss() } }
        .onDisappear { visible = false; model.close(sourceID: source.id) }
        .onChange(of: available) { _, available in if !available { dismiss() } }
        .onChange(of: model.source?.id) { _, id in if let id, id != source.id { dismiss() } }
    }
}
