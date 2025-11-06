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
    @EnvironmentObject private var syncManager: WatchSyncManager
    @AppStorage("sync.options.providers") private var syncProviders = true
    @AppStorage("sync.options.sessions") private var syncSessions = true
    @AppStorage("sync.options.backgrounds") private var syncBackgrounds = true

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
                        enableAutoSessionNaming: $viewModel.enableAutoSessionNaming, // 传递新增的绑定
                        currentSession: $viewModel.currentSession,
                        enableSpeechInput: $viewModel.enableSpeechInput,
                        selectedSpeechModel: speechModelBinding,
                        sendSpeechAsAudio: $viewModel.sendSpeechAsAudio,
                        speechModels: viewModel.speechModels
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

                Section("设备同步") {
                    Toggle("同步提供商", isOn: $syncProviders)
                    Toggle("同步会话", isOn: $syncSessions)
                    Toggle("同步背景", isOn: $syncBackgrounds)
                    Button {
                        syncManager.performSync(direction: .pull, options: selectedSyncOptions)
                    } label: {
                        Label("从手机同步", systemImage: "arrow.down.backward")
                    }
                    .disabled(selectedSyncOptions.isEmpty || isSyncing)
                    Button {
                        syncManager.performSync(direction: .push, options: selectedSyncOptions)
                    } label: {
                        Label("推送到手机", systemImage: "arrow.up.forward")
                    }
                    .disabled(selectedSyncOptions.isEmpty || isSyncing)
                    syncStatusView
                }
            }
            .navigationTitle("设置")
        }
    }

    private var selectedSyncOptions: SyncOptions {
        var option: SyncOptions = []
        if syncProviders { option.insert(.providers) }
        if syncSessions { option.insert(.sessions) }
        if syncBackgrounds { option.insert(.backgrounds) }
        return option
    }
    
    private var isSyncing: Bool {
        if case .syncing = syncManager.state {
            return true
        }
        return false
    }
    
    @ViewBuilder
    private var syncStatusView: some View {
        switch syncManager.state {
        case .idle:
            Text("未同步").font(.caption).foregroundStyle(.secondary)
        case .syncing(let message):
            HStack {
                ProgressView()
                Text(message).font(.caption)
            }
        case .success(let summary):
            VStack(alignment: .leading, spacing: 2) {
                Label("同步成功", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
                Text(summaryDescription(summary))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        case .failed(let reason):
            VStack(alignment: .leading, spacing: 2) {
                Label("同步失败", systemImage: "xmark.circle")
                    .foregroundStyle(.red)
                Text(reason)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        @unknown default:
            Text("未知状态")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
    
    private func summaryDescription(_ summary: SyncMergeSummary) -> String {
        var parts: [String] = []
        if summary.importedProviders > 0 {
            parts.append("提供商 +\(summary.importedProviders)")
        }
        if summary.importedSessions > 0 {
            parts.append("会话 +\(summary.importedSessions)")
        }
        if summary.importedBackgrounds > 0 {
            parts.append("背景 +\(summary.importedBackgrounds)")
        }
        return parts.isEmpty ? "两端数据一致" : parts.joined(separator: "，")
    }
}
