import SwiftUI
import Shared

struct SettingsView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    
    var body: some View {
        NavigationStack {
            List {
                Section("当前模型") {
                    Picker("模型", selection: $viewModel.selectedModel) {
                        ForEach(viewModel.activatedModels) { model in
                            Text("\(model.model.displayName) | \(model.provider.name)")
                                .tag(model as RunnableModel?)
                        }
                    }
                    .onChange(of: viewModel.selectedModel) { _, newValue in
                        ChatService.shared.setSelectedModel(newValue)
                    }
                    
                    Button {
                        viewModel.createNewSession()
                    } label: {
                        Label("开启新对话", systemImage: "bubble.left.and.sparkles")
                    }
                }
                
                Section("对话行为") {
                    NavigationLink {
                        SessionListView().environmentObject(viewModel)
                    } label: {
                        Label("历史会话管理", systemImage: "list.bullet.rectangle")
                    }
                    
                    let speechModelBinding = Binding<RunnableModel?>(
                        get: { viewModel.selectedSpeechModel },
                        set: { viewModel.setSelectedSpeechModel($0) }
                    )
                    NavigationLink {
                        ModelAdvancedSettingsView(
                            aiTemperature: $viewModel.aiTemperature,
                            aiTopP: $viewModel.aiTopP,
                            systemPrompt: $viewModel.systemPrompt,
                            maxChatHistory: $viewModel.maxChatHistory,
                            lazyLoadMessageCount: $viewModel.lazyLoadMessageCount,
                            enableStreaming: $viewModel.enableStreaming,
                            enableAutoSessionNaming: $viewModel.enableAutoSessionNaming,
                            currentSession: $viewModel.currentSession,
                            enableSpeechInput: $viewModel.enableSpeechInput,
                            selectedSpeechModel: speechModelBinding,
                            sendSpeechAsAudio: $viewModel.sendSpeechAsAudio,
                            includeSystemTimeInPrompt: $viewModel.includeSystemTimeInPrompt,
                            speechModels: viewModel.speechModels
                        )
                    } label: {
                        Label("高级模型设置", systemImage: "slider.vertical.3")
                    }
                    
                    NavigationLink {
                        SettingsHubView().environmentObject(viewModel)
                    } label: {
                        Label("数据与模型设置", systemImage: "square.stack.3d.up")
                    }
                    
                    NavigationLink {
                        ExtendedFeaturesView().environmentObject(viewModel)
                    } label: {
                        Label("拓展功能", systemImage: "puzzlepiece.extension")
                    }
                }
                
                Section("显示与体验") {
                    Toggle("渲染 Markdown", isOn: $viewModel.enableMarkdown)
                    Toggle("使用动态背景", isOn: $viewModel.enableBackground)
                    if #available(iOS 26.0, *) {
                        Toggle("液态玻璃效果", isOn: $viewModel.enableLiquidGlass)
                    }
                    
                    NavigationLink {
                        DisplaySettingsView(
                            enableMarkdown: $viewModel.enableMarkdown,
                            enableBackground: $viewModel.enableBackground,
                            backgroundBlur: $viewModel.backgroundBlur,
                            backgroundOpacity: $viewModel.backgroundOpacity,
                            enableAutoRotateBackground: $viewModel.enableAutoRotateBackground,
                            currentBackgroundImage: $viewModel.currentBackgroundImage,
                            enableLiquidGlass: $viewModel.enableLiquidGlass,
                            allBackgrounds: viewModel.backgroundImages
                        )
                    } label: {
                        Label("背景与视觉", systemImage: "sparkles.rectangle.stack")
                    }
                    
                    NavigationLink {
                        DeviceSyncSettingsView()
                    } label: {
                        Label("设备同步", systemImage: "arrow.triangle.2.circlepath")
                    }
                    
                    NavigationLink {
                        AboutView()
                    } label: {
                        Label("关于 ETOS LLM Studio", systemImage: "info.circle")
                    }
                }
            }
            .navigationTitle("设置")
        }
    }
}
