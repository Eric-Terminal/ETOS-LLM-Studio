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
                    title: "语音输入模式",
                    summary: "录音可用系统内建识别或 OpenAI Audio Transcriptions 兼容模型转写，也可在聊天模型支持音频时直发。",
                    details: """
                    语音转写
                    • 关闭“模型支持时发送音频”时，录音会先发送给语音识别模型转写。
                    • 识别结果会自动补到输入框，方便发送前确认和修改。
                    • 模型列表里包含系统内建的 SFSpeechRecognizer，可直接使用系统语音识别。

                    语音识别模型格式
                    • 第三方语音识别模型需要兼容 OpenAI Audio Transcriptions 接口：POST /audio/transcriptions，multipart/form-data 上传 file 和 model，并返回 text 字段。
                    • 因为添加模型的界面不适合再增加专门协议开关，App 不会在模型能力里单独标记这个格式；请按提供商文档或自测结果判断是否支持。
                    • FunAudioLLM/SenseVoiceSmall 这类服务如果已经兼容该接口，就可以作为语音识别模型使用。

                    音频直发
                    • 开启“模型支持时发送音频”时，录音会作为音频附件发送给当前聊天模型。
                    • 只有当前聊天模型在模型设置中开启“可处理音频”，并且提供商实际支持音频输入时，才适合使用音频直发。
                    • 如果当前聊天模型不支持音频输入，请关闭该开关，改用语音识别模型转写。

                    模型选择
                    • 语音识别模型可以在本页选择，也可以在“提供商与模型管理 > 专用模型”中统一设置。
                    """,
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
