// ============================================================================
// SettingsView.swift
// ============================================================================
// ETOS LLM Studio iOS App 设置主视图
//
// 功能特性:
// - 组合所有设置项的入口
// - 包括模型设置、对话管理、显示设置等
// ============================================================================

import SwiftUI
import Shared

/// 设置视图
struct SettingsView: View {
    
    // MARK: - 视图模型
    
    @ObservedObject var viewModel: ChatViewModel

    // MARK: - 视图主体
    
    var body: some View {
        Form {
            Section {
                Picker("当前模型", selection: $viewModel.selectedModel) {
                    ForEach(viewModel.activatedModels) { model in
                        Text(model.model.displayName).tag(model as RunnableModel?)
                    }
                }
                .onChange(of: viewModel.selectedModel) { _, newValue in
                    ChatService.shared.setSelectedModel(newValue)
                }
                
                Button("开启新对话") {
                    viewModel.createNewSession()
                }
            }

            Section {
                NavigationLink(destination: ModelAdvancedSettingsView(
                    aiTemperature: $viewModel.aiTemperature,
                    aiTopP: $viewModel.aiTopP,
                    systemPrompt: $viewModel.systemPrompt,
                    maxChatHistory: $viewModel.maxChatHistory,
                    lazyLoadMessageCount: $viewModel.lazyLoadMessageCount,
                    enableStreaming: $viewModel.enableStreaming,
                    enableAutoSessionNaming: $viewModel.enableAutoSessionNaming, // 传递新增的绑定
                    currentSession: $viewModel.currentSession
                ).toolbar(.hidden, for: .tabBar)) {
                    Label("模型高级设置", systemImage: "brain.head.profile")
                }
                
                NavigationLink(destination: SettingsHubView().environmentObject(viewModel).toolbar(.hidden, for: .tabBar)) {
                    Label("数据与模型设置", systemImage: "key.icloud.fill")
                }
                
                NavigationLink(destination: ExtendedFeaturesView().environmentObject(viewModel).toolbar(.hidden, for: .tabBar)) {
                    Label("拓展功能", systemImage: "puzzlepiece.extension")
                }
                

                
                NavigationLink(destination: DisplaySettingsView(
                    enableMarkdown: $viewModel.enableMarkdown,
                    enableBackground: $viewModel.enableBackground,
                    backgroundBlur: $viewModel.backgroundBlur,
                    backgroundOpacity: $viewModel.backgroundOpacity,
                    enableAutoRotateBackground: $viewModel.enableAutoRotateBackground,
                    currentBackgroundImage: $viewModel.currentBackgroundImage,
                    enableLiquidGlass: $viewModel.enableLiquidGlass,
                    allBackgrounds: viewModel.backgroundImages
                ).toolbar(.hidden, for: .tabBar)) {
                    Label("显示与外观", systemImage: "photo.on.rectangle")
                }
                
                NavigationLink(destination: AboutView().toolbar(.hidden, for: .tabBar)) {
                    Label("关于", systemImage: "info.circle")
                }
            }
        }
        .navigationTitle("设置")
    }
}