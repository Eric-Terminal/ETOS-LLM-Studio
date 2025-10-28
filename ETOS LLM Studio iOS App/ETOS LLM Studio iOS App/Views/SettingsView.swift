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
                            Text(model.model.displayName).tag(model as RunnableModel?)
                        }
                    }
                    .onChange(of: viewModel.selectedModel) { newValue in
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
                        ModelAdvancedSettingsView(
                            aiTemperature: $viewModel.aiTemperature,
                            aiTopP: $viewModel.aiTopP,
                            systemPrompt: $viewModel.systemPrompt,
                            maxChatHistory: $viewModel.maxChatHistory,
                            lazyLoadMessageCount: $viewModel.lazyLoadMessageCount,
                            enableStreaming: $viewModel.enableStreaming,
                            enableAutoSessionNaming: $viewModel.enableAutoSessionNaming,
                            currentSession: $viewModel.currentSession
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
                    Toggle("液态玻璃效果", isOn: $viewModel.enableLiquidGlass)
                    
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
                }
                
                Section("关于") {
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
