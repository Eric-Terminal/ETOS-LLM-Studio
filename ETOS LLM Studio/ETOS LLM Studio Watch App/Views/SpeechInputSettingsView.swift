// ============================================================================
// SpeechInputSettingsView.swift
// ============================================================================
// ETOS LLM Studio Watch App 语音输入设置视图
//
// 功能特性:
// - 管理语音输入开关、录制格式与识别模型
// - 从偏好设置拆分到设置主页面快捷入口
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

            Section {
                Toggle(NSLocalizedString("启用语音输入", comment: ""), isOn: $enableSpeechInput)
                if enableSpeechInput {
                    Toggle(NSLocalizedString("模型支持时发送音频", comment: ""), isOn: $sendSpeechAsAudio)
                    
                    if !sendSpeechAsAudio && speechModels.isEmpty {
                        Text(NSLocalizedString("暂无可用的模型，请先在模型设置中启用。", comment: ""))
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
                                Text(NSLocalizedString("语音模型", comment: ""))
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
                        Picker(NSLocalizedString("录制格式", comment: ""), selection: $audioRecordingFormat) {
                            ForEach(AudioRecordingFormat.allCases, id: \.self) { format in
                                Text(format.displayName).tag(format)
                            }
                        }
                        
                        Text(audioRecordingFormat.formatDescription)
                            .etFont(.footnote)
                            .foregroundColor(.secondary)
                    }

                }
            } header: {
                Text(NSLocalizedString("语音输入", comment: ""))
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

    private func settingsIntroCard(
        title: String,
        summary: String,
        details: String,
        isExpanded: Binding<Bool>
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(NSLocalizedString(title, comment: "语音输入介绍卡片标题"))
                .etFont(.footnote.weight(.semibold))
            Text(NSLocalizedString(summary, comment: "语音输入介绍卡片摘要"))
                .etFont(.caption2)
                .foregroundStyle(.secondary)
            Button {
                isExpanded.wrappedValue = true
            } label: {
                Text(NSLocalizedString("进一步了解…", comment: "语音输入介绍卡片展开按钮"))
                    .etFont(.caption2.weight(.medium))
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .sheet(isPresented: isExpanded) {
            ScrollView {
                Text(NSLocalizedString(details, comment: "语音输入介绍卡片详情"))
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
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
        .navigationTitle(NSLocalizedString("语音模型", comment: ""))
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
