// ============================================================================
// SpeechInputSettingsView.swift
// ============================================================================
// ETOS LLM Studio Watch App 语音输入设置视图
//
// 功能特性:
// - 管理语音输入开关、录制格式与识别模型
// - 从高级模型设置拆分到设置主页面快捷入口
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
            Section(
                header: Text("语音输入"),
                footer: Text(sendSpeechAsAudio ? "录音将直接附带音频给当前模型。" : "识别结果会自动追加到输入框，便于确认和补充。")
            ) {
                Toggle("启用语言输入", isOn: $enableSpeechInput)
                if enableSpeechInput {
                    Toggle("直接发送音频给模型", isOn: $sendSpeechAsAudio)
                    
                    if !sendSpeechAsAudio && speechModels.isEmpty {
                        Text("暂无可用的模型，请先在模型设置中启用。")
                            .etFont(.footnote)
                            .foregroundColor(.secondary)
                    } else if !sendSpeechAsAudio && !speechModels.isEmpty {
                        NavigationLink {
                            SpeechModelSelectionView(
                                speechModels: speechModels,
                                selectedSpeechModel: $selectedSpeechModel
                            )
                        } label: {
                            HStack {
                                Text("语音模型")
                                MarqueeText(
                                    content: selectedSpeechModelLabel,
                                    uiFont: .preferredFont(forTextStyle: .footnote)
                                )
                                .foregroundColor(.secondary)
                                .allowsHitTesting(false)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                            }
                        }
                    } else if sendSpeechAsAudio {
                        Picker("录制格式", selection: $audioRecordingFormat) {
                            ForEach(AudioRecordingFormat.allCases, id: \.self) { format in
                                Text(format.displayName).tag(format)
                            }
                        }
                        
                        Text(audioRecordingFormat.formatDescription)
                            .etFont(.footnote)
                            .foregroundColor(.secondary)
                    }

                    Text("也可以在“提供商与模型管理 > 专用模型”中统一设置。")
                        .etFont(.footnote)
                        .foregroundColor(.secondary)
                }
            }
        }
        .navigationTitle("语音输入")
    }
    
    private var selectedSpeechModelLabel: String {
        guard let model = selectedSpeechModel else {
            return "未选择"
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
                selectionRow(title: "未选择", isSelected: selectedSpeechModel == nil)
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
        .navigationTitle("语音模型")
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
