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
            Form {
                // MARK: 模型设置
                Section(header: Text("模型设置")) {
                    Picker("当前模型", selection: $selectedModel) {
                        ForEach(allModels) { config in
                            Text(config.name).tag(config)
                        }
                    }
                    
                    if currentSession != nil {
                        NavigationLink(destination: ModelAdvancedSettingsView(
                            aiTemperature: $aiTemperature,
                            aiTopP: $aiTopP,
                            systemPrompt: $systemPrompt,
                            maxChatHistory: $maxChatHistory,
                            lazyLoadMessageCount: $lazyLoadMessageCount,
                            enableStreaming: $enableStreaming,
                            currentSession: $currentSession
                        )) {
                            Text("高级设置")
                        }
                    }
                }
                
                // MARK: 对话管理
                Section(header: Text("对话管理")) {
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
                        Text("历史会话")
                    }
                    
                    Button("开启新对话") {
                        let newSession = ChatSession(id: UUID(), name: "新的对话", topicPrompt: nil, enhancedPrompt: nil, isTemporary: true)
                        sessions.insert(newSession, at: 0)
                        currentSession = newSession
                        dismiss()
                    }
                }

                // MARK: 显示设置
                Section(header: Text("显示设置")) {
                    Toggle("渲染 Markdown", isOn: $enableMarkdown)
                    Toggle("显示背景", isOn: $enableBackground)
                    
                    if enableBackground {
                        VStack(alignment: .leading) {
                            Text("背景模糊: \(String(format: "%.1f", backgroundBlur))")
                            Slider(value: $backgroundBlur, in: 0...25, step: 0.5)
                        }
                        
                        VStack(alignment: .leading) {
                            Text("背景不透明度: \(String(format: "%.2f", backgroundOpacity))")
                            Slider(value: $backgroundOpacity, in: 0.1...1.0, step: 0.05)
                        }
                        
                        Toggle("背景随机轮换", isOn: $enableAutoRotateBackground)
                        
                        if !enableAutoRotateBackground {
                            NavigationLink(destination: BackgroundPickerView(
                                allBackgrounds: allBackgrounds,
                                selectedBackground: $currentBackgroundImage
                            )) {
                                Text("选择背景")
                            }
                        }
                    }
                }
            }
            .navigationTitle("设置")
            .toolbar {
                Button("完成") { dismiss() }
            }
        }
    }
}
