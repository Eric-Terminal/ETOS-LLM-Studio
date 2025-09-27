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

/// 设置视图
struct SettingsView: View {
    
    // MARK: - 绑定与属性
    
    @Binding var selectedModel: AIModelConfig
    let allModels: [AIModelConfig]
    
    @Binding var sessions: [ChatSession]
    @Binding var currentSession: ChatSession?
    @Binding var aiTemperature: Double
    @Binding var aiTopP: Double
    @Binding var systemPrompt: String
    @Binding var maxChatHistory: Int
    @Binding var lazyLoadMessageCount: Int
    @Binding var enableStreaming: Bool
    @Binding var enableMarkdown: Bool
    @Binding var enableBackground: Bool
    @Binding var backgroundBlur: Double
    @Binding var backgroundOpacity: Double
    let allBackgrounds: [String]
    @Binding var currentBackgroundImage: String
    @Binding var enableAutoRotateBackground: Bool
    @Binding var enableLiquidGlass: Bool // New Binding
    
    // MARK: - 操作
    
    let deleteAction: (IndexSet) -> Void
    let branchAction: (ChatSession, Bool) -> Void
    let exportAction: (ChatSession) -> Void
    let deleteLastMessageAction: (ChatSession) -> Void
    let saveSessionsAction: () -> Void

    // MARK: - 环境
    
    @Environment(\.dismiss) var dismiss
    
    // MARK: - 视图主体
    
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("当前模型", selection: $selectedModel) {
                        ForEach(allModels) { config in
                            Text(config.name).tag(config)
                        }
                    }
                    .onChange(of: selectedModel) {
                        dismiss()
                    }
                    
                    Button("开启新对话") {
                        let newSession = ChatSession(id: UUID(), name: "新的对话", topicPrompt: nil, enhancedPrompt: nil, isTemporary: true)
                        sessions.insert(newSession, at: 0)
                        currentSession = newSession
                        dismiss()
                    }
                }

                Section {
                    NavigationLink(destination: ModelAdvancedSettingsView(
                        aiTemperature: $aiTemperature,
                        aiTopP: $aiTopP,
                        systemPrompt: $systemPrompt,
                        maxChatHistory: $maxChatHistory,
                        lazyLoadMessageCount: $lazyLoadMessageCount,
                        enableStreaming: $enableStreaming,
                        currentSession: $currentSession
                    )) {
                        Label("模型高级设置", systemImage: "brain.head.profile")
                    }
                    
                    NavigationLink(destination: SessionListView(
                        sessions: $sessions,
                        currentSession: $currentSession,
                        deleteAction: deleteAction,
                        branchAction: branchAction,
                        exportAction: exportAction,
                        deleteLastMessageAction: deleteLastMessageAction,
                        onSessionSelected: { selectedSession in
                            currentSession = selectedSession
                            dismiss()
                        },
                        saveSessionsAction: saveSessionsAction
                    )) {
                        Label("历史会话管理", systemImage: "list.bullet.rectangle")
                    }
                    
                    NavigationLink(destination: DisplaySettingsView(
                        enableMarkdown: $enableMarkdown,
                        enableBackground: $enableBackground,
                        backgroundBlur: $backgroundBlur,
                        backgroundOpacity: $backgroundOpacity,
                        enableAutoRotateBackground: $enableAutoRotateBackground,
                        currentBackgroundImage: $currentBackgroundImage,
                        enableLiquidGlass: $enableLiquidGlass, // Pass binding
                        allBackgrounds: allBackgrounds
                    )) {
                        Label("显示与外观", systemImage: "photo.on.rectangle")
                    }
                }
            }
            .navigationTitle("设置")
        }
    }
}