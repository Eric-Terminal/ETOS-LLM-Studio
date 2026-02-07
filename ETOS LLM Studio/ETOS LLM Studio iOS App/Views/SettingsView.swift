import SwiftUI
import Shared

struct SettingsView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @ObservedObject private var announcementManager = AnnouncementManager.shared
    
    var body: some View {
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
                    Label("开启新对话", systemImage: "plus.message")
                }
            }
            
            Section("对话行为") {
                NavigationLink {
                    SessionListView().environmentObject(viewModel)
                } label: {
                    Label("历史会话管理", systemImage: "list.bullet.rectangle")
                }

                NavigationLink {
                    ProviderListView().environmentObject(viewModel)
                } label: {
                    Label("提供商与模型管理", systemImage: "list.bullet.rectangle.portrait")
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
                        enableResponseSpeedMetrics: $viewModel.enableResponseSpeedMetrics,
                        enableAutoSessionNaming: $viewModel.enableAutoSessionNaming,
                        currentSession: $viewModel.currentSession,
                        enableSpeechInput: $viewModel.enableSpeechInput,
                        selectedSpeechModel: speechModelBinding,
                        sendSpeechAsAudio: $viewModel.sendSpeechAsAudio,
                        includeSystemTimeInPrompt: $viewModel.includeSystemTimeInPrompt,
                        audioRecordingFormat: Binding(
                            get: { viewModel.audioRecordingFormat },
                            set: { viewModel.audioRecordingFormat = $0 }
                        ),
                        speechModels: viewModel.speechModels
                    )
                } label: {
                    Label("高级模型设置", systemImage: "slider.vertical.3")
                }
                
                NavigationLink {
                    ExtendedFeaturesView().environmentObject(viewModel)
                } label: {
                    Label("拓展功能", systemImage: "puzzlepiece.extension")
                }
            }
            
            Section("显示与体验") {
                Toggle("渲染 Markdown", isOn: $viewModel.enableMarkdown)
                if viewModel.enableMarkdown {
                    Toggle("使用高级渲染器", isOn: $viewModel.enableAdvancedRenderer)
                }
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
                        backgroundContentMode: $viewModel.backgroundContentMode,
                        enableLiquidGlass: $viewModel.enableLiquidGlass,
                        enableAdvancedRenderer: $viewModel.enableAdvancedRenderer,
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
            
            // MARK: - 公告通知 Section
            if announcementManager.shouldShowInSettings {
                Section("系统公告") {
                    ForEach(announcementManager.currentAnnouncements, id: \.uniqueKey) { announcement in
                        NavigationLink {
                            AnnouncementDetailView(
                                announcement: announcement,
                                announcementManager: announcementManager
                            )
                        } label: {
                            HStack {
                                announcementIcon(for: announcement.type)
                                Text(announcement.title)
                                    .lineLimit(2)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("设置")
        .onChange(of: viewModel.enableMarkdown) { _, isEnabled in
            if !isEnabled, viewModel.enableAdvancedRenderer {
                viewModel.enableAdvancedRenderer = false
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
}
