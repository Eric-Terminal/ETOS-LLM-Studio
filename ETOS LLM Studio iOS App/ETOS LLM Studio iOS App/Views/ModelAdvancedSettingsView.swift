import SwiftUI
import Shared

struct ModelAdvancedSettingsView: View {
    @Binding var aiTemperature: Double
    @Binding var aiTopP: Double
    @Binding var systemPrompt: String
    @Binding var maxChatHistory: Int
    @Binding var lazyLoadMessageCount: Int
    @Binding var enableStreaming: Bool
    @Binding var enableAutoSessionNaming: Bool
    @Binding var currentSession: ChatSession?
    @Binding var enableSpeechInput: Bool
    @Binding var selectedSpeechModel: RunnableModel?
    @Binding var sendSpeechAsAudio: Bool
    var speechModels: [RunnableModel]
    
    private var numberFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }
    
    var body: some View {
        Form {
            Section("全局系统提示词") {
                TextField("自定义全局系统提示词", text: $systemPrompt, axis: .vertical)
                    .lineLimit(3...8)
            }
            
            Section("当前会话提示词") {
                TextField("话题提示词", text: Binding(
                    get: { currentSession?.topicPrompt ?? "" },
                    set: { newValue in
                        if var session = currentSession {
                            session.topicPrompt = newValue
                            currentSession = session
                            ChatService.shared.updateSession(session)
                        }
                    }
                ), axis: .vertical)
                .lineLimit(2...6)
                
                TextField("增强提示词", text: Binding(
                    get: { currentSession?.enhancedPrompt ?? "" },
                    set: { newValue in
                        if var session = currentSession {
                            session.enhancedPrompt = newValue
                            currentSession = session
                            ChatService.shared.updateSession(session)
                        }
                    }
                ), axis: .vertical)
                .lineLimit(2...6)
            }
            
            Section("语音输入") {
                Toggle("启用语言输入", isOn: $enableSpeechInput)
                if enableSpeechInput {
                    Toggle("直接发送音频给模型", isOn: $sendSpeechAsAudio)
                    
                    if speechModels.isEmpty {
                        Text("暂无已激活的模型可用于语音识别，请先在模型列表中启用模型。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("语音识别模型", selection: $selectedSpeechModel) {
                            Text("未选择").tag(Optional<RunnableModel>.none)
                            ForEach(speechModels) { runnable in
                                Text("\(runnable.model.displayName) · \(runnable.provider.name)")
                                    .tag(Optional<RunnableModel>.some(runnable))
                            }
                        }
                        .pickerStyle(.menu)
                        
                        let description = sendSpeechAsAudio
                        ? "语音会直接附带音频给当前模型，同时后台用该模型转写文本。"
                        : "语音内容会先发送到该模型转写，识别结果会自动补到输入框。"
                        Text(description)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            
            Section("输出样式") {
                Toggle("自动生成话题标题", isOn: $enableAutoSessionNaming)
                Toggle("启用流式输出", isOn: $enableStreaming)
            }
            
            Section("采样参数") {
                VStack(alignment: .leading) {
                    Text("Temperature \(String(format: "%.2f", aiTemperature))")
                        .font(.subheadline)
                    Slider(value: $aiTemperature, in: 0...2, step: 0.05)
                        .onChange(of: aiTemperature) { value in
                            aiTemperature = (value * 100).rounded() / 100
                        }
                }
                
                VStack(alignment: .leading) {
                    Text("Top P \(String(format: "%.2f", aiTopP))")
                        .font(.subheadline)
                    Slider(value: $aiTopP, in: 0...1, step: 0.05)
                        .onChange(of: aiTopP) { value in
                            aiTopP = (value * 100).rounded() / 100
                        }
                }
            }
            
            Section("上下文与懒加载") {
                LabeledContent("最大上下文消息数") {
                    TextField("数量", value: $maxChatHistory, formatter: numberFormatter)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                }
                
                LabeledContent("懒加载消息数") {
                    TextField("数量", value: $lazyLoadMessageCount, formatter: numberFormatter)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                }
                
                Text("设置进入历史会话时默认加载的最近消息数量。数值越小，长对话加载越快；设置为 0 表示加载全部历史。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("高级模型设置")
    }
}
