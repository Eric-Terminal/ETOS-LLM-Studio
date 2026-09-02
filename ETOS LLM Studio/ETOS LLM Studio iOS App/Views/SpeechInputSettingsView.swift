// ============================================================================
// SpeechInputSettingsView.swift
// ============================================================================
// SpeechInputSettingsView 界面 (iOS)
// - 管理语音输入开关、录制格式与识别模型
// - 从“偏好设置”中拆分，便于在设置主页面快速访问
// ============================================================================

import SwiftUI
import ETOSCore

struct SpeechInputSettingsView: View {
    @Binding var enableSpeechInput: Bool
    @Binding var selectedSpeechModel: RunnableModel?
    @Binding var sendSpeechAsAudio: Bool
    @Binding var audioRecordingFormat: AudioRecordingFormat
    var speechModels: [RunnableModel]
    @State private var isShowingIntroDetails = false
    
    var body: some View {
        Form {
            Section {
                settingsIntroCard(
                    title: NSLocalizedString("语音输入模式", comment: "Speech input mode intro title"),
                    summary: NSLocalizedString("录音可用系统内建识别或 OpenAI Audio Transcriptions 兼容模型转写，也可在聊天模型支持音频时直发。", comment: "Speech input mode intro summary"),
                    details: NSLocalizedString("语音输入模式详情：转写接口与模型来源", comment: "Speech input mode intro details"),
                    isExpanded: $isShowingIntroDetails
                )
            }

            Section(NSLocalizedString("语音输入", comment: "")) {
                Toggle(NSLocalizedString("启用语音输入", comment: ""), isOn: $enableSpeechInput)
                if enableSpeechInput {
                    Toggle(NSLocalizedString("模型支持时发送音频", comment: ""), isOn: $sendSpeechAsAudio)
                    
                    if sendSpeechAsAudio {
                        Picker(NSLocalizedString("音频录制格式", comment: ""), selection: $audioRecordingFormat) {
                            ForEach(AudioRecordingFormat.allCases, id: \.self) { format in
                                Text(format.displayName).tag(format)
                            }
                        }
                        
                        Text(audioRecordingFormat.formatDescription)
                            .etFont(.footnote)
                            .foregroundStyle(.secondary)
                    } else if speechModels.isEmpty {
                        Text(NSLocalizedString("暂无已激活的模型可用于语音识别，请先在模型列表中启用模型。", comment: ""))
                            .etFont(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        NavigationLink {
                            SpeechModelSelectionView(
                                speechModels: speechModels,
                                selectedSpeechModel: $selectedSpeechModel
                            )
                        } label: {
                            HStack {
                                Text(NSLocalizedString("语音识别模型", comment: ""))
                                MarqueeText(
                                    content: selectedSpeechModelLabel,
                                    uiFont: .preferredFont(forTextStyle: .body)
                                )
                                .foregroundStyle(.secondary)
                                .allowsHitTesting(false)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(NSLocalizedString("语音输入", comment: ""))
        .guideSettingsPageContext(
            id: "settings-speech-input",
            title: NSLocalizedString("语音输入", comment: "语音输入向导标题"),
            documents: [GuideDocumentReference(id: "speech-input", title: "Speech Input")],
            settings: guideSettings
        )
    }

    private var guideSettings: [GuidePageSetting] {
        [
            .bool("enabled", label: NSLocalizedString("启用语音输入", comment: "语音输入向导字段"), get: { enableSpeechInput }, set: { enableSpeechInput = $0 }),
            .bool("send_audio_when_supported", label: NSLocalizedString("模型支持时发送音频", comment: "语音输入向导字段"), get: { sendSpeechAsAudio }, set: { sendSpeechAsAudio = $0 }),
            .string(
                "recording_format",
                label: NSLocalizedString("音频录制格式", comment: "语音输入向导字段"),
                allowedValues: AudioRecordingFormat.allCases.map(\.rawValue),
                allowsEmpty: false,
                get: { audioRecordingFormat.rawValue },
                set: { rawValue in
                    if let format = AudioRecordingFormat(rawValue: rawValue) { audioRecordingFormat = format }
                }
            ),
            speechModelSetting,
            .readOnly("available_speech_models", label: NSLocalizedString("可用语音识别模型", comment: "语音输入向导字段"), value: {
                .array(speechModels.map { model in
                    .dictionary([
                        "id": .string(model.id),
                        "display_name": .string(model.model.displayName),
                        "model_id": .string(model.model.modelName),
                        "provider": .string(model.provider.name)
                    ])
                })
            })
        ]
    }

    private var speechModelSetting: GuidePageSetting {
        .string(
            "speech_model_id",
            label: NSLocalizedString("语音识别模型", comment: "语音输入向导字段"),
            allowedValues: [""] + speechModels.map(\.id),
            get: { selectedSpeechModel?.id ?? "" },
            set: { modelID in selectedSpeechModel = speechModels.first(where: { $0.id == modelID }) }
        )
    }
    
    private var selectedSpeechModelLabel: String {
        guard let model = selectedSpeechModel else {
            return NSLocalizedString("未选择", comment: "")
        }
        return "\(model.model.displayName) | \(model.provider.name)"
    }

    private func settingsIntroCard(
        title: String,
        summary: String,
        details: String,
        isExpanded: Binding<Bool>
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(NSLocalizedString(title, comment: "语音输入介绍卡片标题"))
                .etFont(.headline.weight(.semibold))
            Text(NSLocalizedString(summary, comment: "语音输入介绍卡片摘要"))
                .etFont(.subheadline)
                .foregroundStyle(.secondary)
            Button {
                isExpanded.wrappedValue = true
            } label: {
                Text(NSLocalizedString("进一步了解…", comment: "语音输入介绍卡片展开按钮"))
                    .etFont(.footnote.weight(.medium))
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .sheet(isPresented: isExpanded) {
            NavigationStack {
                ScrollView {
                    Text(NSLocalizedString(details, comment: "语音输入介绍卡片详情"))
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .navigationTitle(NSLocalizedString(title, comment: "语音输入介绍卡片详情标题"))
                .navigationBarTitleDisplayMode(.inline)
            }
        }
    }
}

private struct SpeechModelSelectionView: View {
    @Environment(\.dismiss) private var dismiss
    
    let speechModels: [RunnableModel]
    @Binding var selectedSpeechModel: RunnableModel?
    
    var body: some View {
        List {
            Button {
                select(nil)
            } label: {
                selectionRow(title: NSLocalizedString("未选择", comment: ""), isSelected: selectedSpeechModel == nil)
            }
            
            ForEach(speechModels) { runnable in
                Button {
                    select(runnable)
                } label: {
                    let isSelected = selectedSpeechModel?.id == runnable.id
                    selectionRow(
                        title: runnable.model.displayName,
                        subtitle: "\(runnable.provider.name) · \(runnable.model.modelName)",
                        isSelected: isSelected
                    )
                }
            }
        }
        .navigationTitle(NSLocalizedString("语音识别模型", comment: ""))
        .guideSettingsPageContext(
            id: "settings-speech-model-selection",
            title: NSLocalizedString("语音识别模型", comment: "语音模型选择向导标题"),
            documents: [GuideDocumentReference(id: "speech-input", title: "Speech Input")],
            settings: [
                .string(
                    "selected_model_id",
                    label: NSLocalizedString("当前语音识别模型", comment: "语音模型选择向导字段"),
                    allowedValues: [""] + speechModels.map(\.id),
                    get: { selectedSpeechModel?.id ?? "" },
                    set: { modelID in selectedSpeechModel = speechModels.first(where: { $0.id == modelID }) }
                ),
                .readOnly("available_models", label: NSLocalizedString("可用模型", comment: "语音模型选择向导字段"), value: {
                    .array(speechModels.map { model in
                        .dictionary([
                            "id": .string(model.id),
                            "display_name": .string(model.model.displayName),
                            "model_id": .string(model.model.modelName),
                            "provider": .string(model.provider.name)
                        ])
                    })
                })
            ]
        )
    }
    
    private func select(_ model: RunnableModel?) {
        selectedSpeechModel = model
        dismiss()
    }
    
    @ViewBuilder
    private func selectionRow(title: String, subtitle: String? = nil, isSelected: Bool) -> some View {
        MarqueeTitleSubtitleSelectionRow(
            title: title,
            subtitle: subtitle,
            isSelected: isSelected,
            subtitleUIFont: .monospacedSystemFont(
                ofSize: UIFont.preferredFont(forTextStyle: .caption2).pointSize,
                weight: .regular
            )
        )
    }
}
