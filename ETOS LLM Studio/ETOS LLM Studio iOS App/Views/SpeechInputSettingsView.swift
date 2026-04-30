// ============================================================================
// SpeechInputSettingsView.swift
// ============================================================================
// SpeechInputSettingsView 界面 (iOS)
// - 管理语音输入开关、录制格式与识别模型
// - 从“偏好设置”中拆分，便于在设置主页面快速访问
// ============================================================================

import SwiftUI
import Shared

struct SpeechInputSettingsView: View {
    @Binding var enableSpeechInput: Bool
    @Binding var selectedSpeechModel: RunnableModel?
    @Binding var sendSpeechAsAudio: Bool
    @Binding var audioRecordingFormat: AudioRecordingFormat
    var speechModels: [RunnableModel]
    
    var body: some View {
        Form {
            Section(NSLocalizedString("语音输入", comment: "")) {
                Toggle(NSLocalizedString("启用语言输入", comment: ""), isOn: $enableSpeechInput)
                if enableSpeechInput {
                    Toggle(NSLocalizedString("直接发送音频给模型", comment: ""), isOn: $sendSpeechAsAudio)
                    
                    if sendSpeechAsAudio {
                        Text(NSLocalizedString("语音会直接附带音频给当前模型。", comment: ""))
                            .etFont(.footnote)
                            .foregroundStyle(.secondary)
                        
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
                        
                        Text(NSLocalizedString("语音内容会先发送到该模型转写，识别结果会自动补到输入框。", comment: ""))
                            .etFont(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    
                    Text(NSLocalizedString("也可以在“提供商与模型管理 > 专用模型”中统一设置。", comment: ""))
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(NSLocalizedString("语音输入", comment: ""))
    }
    
    private var selectedSpeechModelLabel: String {
        guard let model = selectedSpeechModel else {
            return NSLocalizedString("未选择", comment: "")
        }
        return "\(model.model.displayName) | \(model.provider.name)"
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
