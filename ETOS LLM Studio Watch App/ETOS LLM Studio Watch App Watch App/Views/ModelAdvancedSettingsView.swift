// ============================================================================
// ModelAdvancedSettingsView.swift
// ============================================================================
// ETOS LLM Studio Watch App 高级模型设置视图
//
// 功能特性:
// - 调整 Temperature, Top P, System Prompt 等参数
// - 管理上下文和懒加载数量
// ============================================================================

import SwiftUI
import Shared

/// 高级模型设置视图
struct ModelAdvancedSettingsView: View {
    
    // MARK: - 绑定
    
    @Binding var aiTemperature: Double
    @Binding var aiTopP: Double
    @Binding var systemPrompt: String
    @Binding var maxChatHistory: Int
    @Binding var lazyLoadMessageCount: Int
    @Binding var enableStreaming: Bool
    @Binding var enableAutoSessionNaming: Bool // 新增绑定
    @Binding var currentSession: ChatSession?
    @Binding var enableSpeechInput: Bool
    @Binding var selectedSpeechModel: RunnableModel?
    @Binding var sendSpeechAsAudio: Bool
    var speechModels: [RunnableModel]
    
    // MARK: - 私有属性
    
    private var numberFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }
    
    // MARK: - 视图主体
    
    var body: some View {
        Form {
            Section(header: Text("全局系统提示词")) {
                TextField("自定义全局系统提示词", text: $systemPrompt, axis: .vertical)
                    .lineLimit(5...10)
            }
            
            Section(header: Text("当前话题提示词"), footer: Text("仅对当前对话生效。")) {
                TextField("自定义话题提示词", text: Binding(
                    get: { currentSession?.topicPrompt ?? "" },
                    set: { newValue in
                        if var session = currentSession {
                            session.topicPrompt = newValue
                            currentSession = session
                            print("--- DEBUG: Topic Prompt set, preparing to save. ---")
                            // 关键修复：在修改后立即调用更新函数
                            ChatService.shared.updateSession(session)
                        }
                    }
                ), axis: .vertical)
                .lineLimit(5...10)
            }
            
            Section(header: Text("语音输入"), footer: Text(sendSpeechAsAudio ? "录音将附带音频给当前模型，同时使用下方所选模型后台转写文字。" : "识别结果会自动追加到输入框，便于确认和补充。")) {
                Toggle("启用语言输入", isOn: $enableSpeechInput)
                if enableSpeechInput {
                    Toggle("直接发送音频给模型", isOn: $sendSpeechAsAudio)
                    
                    if speechModels.isEmpty {
                        Text("暂无可用的模型，请先在模型设置中启用。")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    } else {
                        Picker("语音模型", selection: $selectedSpeechModel) {
                            Text("未选择").tag(Optional<RunnableModel>.none)
                            ForEach(speechModels) { runnable in
                                Text(runnable.model.displayName)
                                    .tag(Optional<RunnableModel>.some(runnable))
                            }
                        }
                        .pickerStyle(.navigationLink)
                    }
                }
            }
            
            Section(header: Text("增强提示词"), footer: Text("该提示词会附加在您的最后一条消息末尾，以增强指令效果。")) {
                TextField("自定义增强提示词", text: Binding(
                    get: { currentSession?.enhancedPrompt ?? "" },
                    set: { newValue in
                        if var session = currentSession {
                            session.enhancedPrompt = newValue
                            currentSession = session
                            // 关键修复：在修改后立即调用更新函数
                            ChatService.shared.updateSession(session)
                        }
                    }
                ), axis: .vertical)
                .lineLimit(5...10)
            }
            
            Section(header: Text("会话设置")) {
                Toggle("自动生成话题标题", isOn: $enableAutoSessionNaming)
            }
            
            Section(header: Text("输出设置")) {
                Toggle("流式输出", isOn: $enableStreaming)
            }
            
            Section(header: Text("参数调整")) {
                VStack(alignment: .leading) {
                    Text("模型温度 (Temperature): \(String(format: "%.2f", aiTemperature))")
                    Slider(value: $aiTemperature, in: 0.0...2.0, step: 0.05)
                        .onChange(of: aiTemperature) {
                            aiTemperature = (aiTemperature * 100).rounded() / 100
                        }
                }
                
                VStack(alignment: .leading) {
                    Text("核采样 (Top P): \(String(format: "%.2f", aiTopP))")
                    Slider(value: $aiTopP, in: 0.0...1.0, step: 0.05)
                        .onChange(of: aiTopP) {
                            aiTopP = (aiTopP * 100).rounded() / 100
                        }
                }
            }
            
            Section(header: Text("上下文管理"), footer: Text("设置发送到模型的最近消息数量。例如，设置为10将只发送最后5条用户消息和5条AI回复。设置为0表示不限制。")) {
                HStack {
                    Text("最大上下文消息数")
                    Spacer()
                    TextField("数量", value: $maxChatHistory, formatter: numberFormatter)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 60)
                }
            }
            
            Section(header: Text("性能设置")) {
                HStack {
                    Text("懒加载消息数")
                    Spacer()
                    TextField("数量", value: $lazyLoadMessageCount, formatter: numberFormatter)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 60)
                }
                
                Text("设置进入历史会话时默认加载的最近消息数量。可以有效降低长对话的内存和性能开销。设置为0表示不启用此功能，将加载所有消息。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("高级模型设置")
    }
}
