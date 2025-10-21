// ============================================================================
// SettingsView.swift
// ============================================================================
// ETOS LLM Studio Watch App 设置主视图
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

    // MARK: - 环境
    
    @Environment(\.dismiss) var dismiss
    
    // MARK: - 视图主体
    
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("当前模型", selection: $viewModel.selectedModel) {
                        ForEach(viewModel.activatedModels) { model in
                            Text(model.model.displayName).tag(model as RunnableModel?)
                        }
                    }
                    .onChange(of: viewModel.selectedModel) { _, newValue in
                        ChatService.shared.setSelectedModel(newValue)
                        dismiss()
                    }
                    
                    Button("开启新对话") {
                        viewModel.createNewSession()
                        dismiss()
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
                    )) {
                        Label("模型高级设置", systemImage: "brain.head.profile")
                    }
                    
                    NavigationLink(destination: SettingsHubView().environmentObject(viewModel)) {
                        Label("数据与模型设置", systemImage: "key.icloud.fill")
                    }
                    
                    NavigationLink(destination: ExtendedFeaturesView().environmentObject(viewModel)) {
                        Label("拓展功能", systemImage: "puzzlepiece.extension")
                    }
                    
                    NavigationLink(destination: SessionListView(
                        sessions: $viewModel.chatSessions,
                        currentSession: $viewModel.currentSession,
                        deleteAction: { indexSet in
                            viewModel.deleteSession(at: indexSet)
                        },
                        branchAction: { session, copyMessages in
                            let newSession = viewModel.branchSession(from: session, copyMessages: copyMessages)
                            return newSession
                        },
                        exportAction: { session in
                            viewModel.activeSheet = .export(session)
                        },
                        deleteLastMessageAction: { session in
                            viewModel.deleteLastMessage(for: session)
                        },
                        onSessionSelected: { selectedSession in
                            ChatService.shared.setCurrentSession(selectedSession)
                            dismiss()
                        },
                        updateSessionAction: { session in
                            viewModel.updateSession(session)
                        }
                    )) {
                        Label("历史会话管理", systemImage: "list.bullet.rectangle")
                    }
                    
                    NavigationLink(destination: DisplaySettingsView(
                        enableMarkdown: $viewModel.enableMarkdown,
                        enableBackground: $viewModel.enableBackground,
                        backgroundBlur: $viewModel.backgroundBlur,
                        backgroundOpacity: $viewModel.backgroundOpacity,
                        enableAutoRotateBackground: $viewModel.enableAutoRotateBackground,
                        currentBackgroundImage: $viewModel.currentBackgroundImage,
                        enableLiquidGlass: $viewModel.enableLiquidGlass, // 传递绑定
                        allBackgrounds: viewModel.backgroundImages
                    )) {
                        Label("显示与外观", systemImage: "photo.on.rectangle")
                    }
                    
                    NavigationLink(destination: AboutView()) {
                        Label("关于", systemImage: "info.circle")
                    }
                }
            }
            .navigationTitle("设置")
        }
    }
}
