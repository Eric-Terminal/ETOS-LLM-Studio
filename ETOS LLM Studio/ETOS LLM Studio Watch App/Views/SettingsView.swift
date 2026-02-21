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
                    let options = viewModel.activatedModels
                    if options.isEmpty {
                        Text("暂无可用模型，请先在“提供商与模型管理”中启用。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        NavigationLink {
                            ModelSelectionView(
                                models: options,
                                selectedModel: selectedModelBinding
                            )
                        } label: {
                            HStack {
                                Text("当前模型")
                                Spacer()
                                Text(selectedModelLabel(in: options))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }

                    Button {
                        viewModel.createNewSession()
                        dismiss()
                    } label: {
                        Label("开启新对话", systemImage: "plus.message")
                    }
                } header: {
                    Text("当前模型")
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
                        enableAdvancedRenderer: $viewModel.enableAdvancedRenderer,
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
            .onAppear {
                ensureSelectedModel(in: viewModel.activatedModels)
            }
            .onChange(of: viewModel.activatedModels.map(\.id)) { _, _ in
                ensureSelectedModel(in: viewModel.activatedModels)
            }
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

    private func ensureSelectedModel(in options: [RunnableModel]) {
        guard let first = options.first else { return }
        guard let selectedID = viewModel.selectedModel?.id,
              options.contains(where: { $0.id == selectedID }) else {
            viewModel.selectedModel = first
            ChatService.shared.setSelectedModel(first)
            return
        }
    }

    private var selectedModelBinding: Binding<RunnableModel?> {
        Binding(
            get: { viewModel.selectedModel },
            set: { model in
                viewModel.selectedModel = model
                ChatService.shared.setSelectedModel(model)
            }
        )
    }

    private func selectedModelLabel(in options: [RunnableModel]) -> String {
        if let selected = viewModel.selectedModel,
           options.contains(where: { $0.id == selected.id }) {
            return "\(selected.model.displayName) | \(selected.provider.name)"
        }
        guard let first = options.first else { return "" }
        return "\(first.model.displayName) | \(first.provider.name)"
    }
}

private struct ModelSelectionView: View {
    @Environment(\.dismiss) private var dismiss

    let models: [RunnableModel]
    @Binding var selectedModel: RunnableModel?

    var body: some View {
        List {
            ForEach(models) { model in
                Button {
                    select(model)
                } label: {
                    selectionRow(
                        title: "\(model.model.displayName) | \(model.provider.name)",
                        isSelected: selectedModel?.id == model.id
                    )
                }
            }
        }
        .navigationTitle("当前模型")
    }

    private func select(_ model: RunnableModel) {
        selectedModel = model
        dismiss()
    }

    @ViewBuilder
    private func selectionRow(title: String, isSelected: Bool) -> some View {
        HStack {
            Text(title)
            Spacer()
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.footnote)
                    .foregroundColor(.accentColor)
            }
        }
    }
}
