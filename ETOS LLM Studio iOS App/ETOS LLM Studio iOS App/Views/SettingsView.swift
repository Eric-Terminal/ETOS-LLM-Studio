import SwiftUI
import Shared

struct SettingsView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @EnvironmentObject private var syncManager: WatchSyncManager
    @AppStorage("sync.options.providers") private var syncProviders = true
    @AppStorage("sync.options.sessions") private var syncSessions = true
    @AppStorage("sync.options.backgrounds") private var syncBackgrounds = true
    
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

                Section("设备同步") {
                    Toggle("同步提供商", isOn: $syncProviders)
                    Toggle("同步会话", isOn: $syncSessions)
                    Toggle("同步背景图片", isOn: $syncBackgrounds)
                    
                    Button {
                        syncManager.performSync(direction: .push, options: selectedSyncOptions)
                    } label: {
                        Label("推送到手表", systemImage: "arrow.up.right.square")
                    }
                    .disabled(selectedSyncOptions.isEmpty || isSyncing)
                    
                    Button {
                        syncManager.performSync(direction: .pull, options: selectedSyncOptions)
                    } label: {
                        Label("请求手表数据", systemImage: "arrow.down.left.square")
                    }
                    .disabled(selectedSyncOptions.isEmpty || isSyncing)
                    
                    syncStatusView
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
            Text("未进行同步").font(.footnote).foregroundColor(.secondary)
        case .syncing(let message):
            HStack {
                ProgressView()
                Text(message).font(.footnote)
            }
        case .success(let summary):
            VStack(alignment: .leading, spacing: 4) {
                Label("同步完成", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(summaryDescription(summary))
                    .font(.caption)
                    .foregroundColor(.secondary)
                if let time = syncManager.lastUpdatedAt {
                    Text("时间：\(time.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        case .failed(let reason):
            VStack(alignment: .leading, spacing: 4) {
                Label("同步失败", systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                Text(reason)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
    
    private func summaryDescription(_ summary: SyncMergeSummary) -> String {
        var parts: [String] = []
        if summary.importedProviders > 0 {
            parts.append("新增提供商 \(summary.importedProviders)")
        }
        if summary.importedSessions > 0 {
            parts.append("新增会话 \(summary.importedSessions)")
        }
        if summary.importedBackgrounds > 0 {
            parts.append("新增背景 \(summary.importedBackgrounds)")
        }
        if parts.isEmpty {
            return "两端已是最新，无需更新。"
        }
        return parts.joined(separator: "，")
    }
}
