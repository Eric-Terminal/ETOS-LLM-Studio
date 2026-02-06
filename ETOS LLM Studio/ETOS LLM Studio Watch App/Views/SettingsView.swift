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
    
    // MARK: - 公告管理器
    
    @ObservedObject var announcementManager = AnnouncementManager.shared

    // MARK: - 环境
    
    @Environment(\.dismiss) var dismiss
    
    // MARK: - 视图主体
    
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("当前模型", selection: $viewModel.selectedModel) {
                        ForEach(viewModel.activatedModels) { model in
                            Text("\(model.model.displayName) | \(model.provider.name)")
                                .tag(model as RunnableModel?)
                        }
                    }
                    .onChange(of: viewModel.selectedModel) { _, newValue in
                        ChatService.shared.setSelectedModel(newValue)
                        dismiss()
                    }
                    
                    Button {
                        viewModel.createNewSession()
                        dismiss()
                    } label: {
                        Label("开启新对话", systemImage: "plus.message")
                    }
                }

                Section {
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

                    NavigationLink(destination: ProviderListView().environmentObject(viewModel)) {
                        Label("提供商与模型管理", systemImage: "list.bullet.rectangle.portrait")
                    }
                    
                    let speechModelBinding = Binding<RunnableModel?>(
                        get: { viewModel.selectedSpeechModel },
                        set: { viewModel.setSelectedSpeechModel($0) }
                    )
                    NavigationLink(destination: ModelAdvancedSettingsView(
                        aiTemperature: $viewModel.aiTemperature,
                        aiTopP: $viewModel.aiTopP,
                        systemPrompt: $viewModel.systemPrompt,
                        maxChatHistory: $viewModel.maxChatHistory,
                        lazyLoadMessageCount: $viewModel.lazyLoadMessageCount,
                        enableStreaming: $viewModel.enableStreaming,
                        enableResponseSpeedMetrics: $viewModel.enableResponseSpeedMetrics,
                        enableAutoSessionNaming: $viewModel.enableAutoSessionNaming, // 传递新增的绑定
                        currentSession: $viewModel.currentSession,
                        enableSpeechInput: $viewModel.enableSpeechInput,
                        selectedSpeechModel: speechModelBinding,
                        sendSpeechAsAudio: $viewModel.sendSpeechAsAudio,
                        includeSystemTimeInPrompt: $viewModel.includeSystemTimeInPrompt,
                        audioRecordingFormat: $viewModel.audioRecordingFormat,
                        speechModels: viewModel.speechModels
                    )) {
                        Label("模型高级设置", systemImage: "brain.head.profile")
                    }
                    
                    NavigationLink(destination: ExtendedFeaturesView().environmentObject(viewModel)) {
                        Label("拓展功能", systemImage: "puzzlepiece.extension")
                    }
                    NavigationLink(destination: DisplaySettingsView(
                        enableMarkdown: $viewModel.enableMarkdown,
                        enableBackground: $viewModel.enableBackground,
                        backgroundBlur: $viewModel.backgroundBlur,
                        backgroundOpacity: $viewModel.backgroundOpacity,
                        enableAutoRotateBackground: $viewModel.enableAutoRotateBackground,
                        currentBackgroundImage: $viewModel.currentBackgroundImage,
                        backgroundContentMode: $viewModel.backgroundContentMode,
                        enableLiquidGlass: $viewModel.enableLiquidGlass,
                        allBackgrounds: viewModel.backgroundImages
                    )) {
                        Label("显示与外观", systemImage: "photo.on.rectangle")
                    }
                    
                    NavigationLink(destination: DeviceSyncSettingsView()) {
                        Label("设备同步", systemImage: "arrow.triangle.2.circlepath")
                    }
                    
                    NavigationLink(destination: AboutView()) {
                        Label("关于", systemImage: "info.circle")
                    }
                }
                
                // MARK: - 公告通知 Section
                if announcementManager.shouldShowInSettings {
                    Section {
                        ForEach(announcementManager.currentAnnouncements, id: \.uniqueKey) { announcement in
                            NavigationLink(destination: AnnouncementDetailView(
                                announcement: announcement,
                                announcementManager: announcementManager
                            )) {
                                HStack {
                                    announcementIcon(for: announcement.type)
                                    Text(announcement.title)
                                        .lineLimit(2)
                                }
                            }
                        }
                    } header: {
                        Text("系统公告")
                    }
                }
            }
            .navigationTitle("设置")
        }
    }
    
    // MARK: - 辅助方法
    
    /// 根据公告类型返回对应图标
    @ViewBuilder
    private func announcementIcon(for type: AnnouncementType) -> some View {
        switch type {
        case .info:
            Image(systemName: "info.circle.fill")
                .foregroundColor(.blue)
        case .warning:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
        case .blocking:
            Image(systemName: "exclamationmark.octagon.fill")
                .foregroundColor(.red)
        @unknown default:
            Image(systemName: "bell.fill")
                .foregroundColor(.gray)
        }
    }
}
