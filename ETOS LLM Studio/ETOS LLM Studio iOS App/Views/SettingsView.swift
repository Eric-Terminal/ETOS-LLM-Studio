// ============================================================================
// SettingsView.swift
// ============================================================================
// SettingsView 界面 (iOS)
// - 负责该功能在 iOS 端的交互与展示
// - 遵循项目现有视图结构与状态流
// ============================================================================

import SwiftUI
import Foundation
import Shared

struct SettingsView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var announcementManager = AnnouncementManager.shared
    
    var body: some View {
        List {
            Section("当前模型") {
                let options = viewModel.activatedModels
                if options.isEmpty {
                    Text("暂无可用模型，请先在“提供商与模型管理”中启用。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    NavigationLink {
                        CurrentModelSelectionView(
                            models: options,
                            selectedModel: selectedModelBinding
                        )
                    } label: {
                        HStack {
                            Text("模型")
                            MarqueeText(
                                content: selectedModelLabel(in: options),
                                uiFont: .preferredFont(forTextStyle: .body)
                            )
                            .foregroundStyle(.secondary)
                            .allowsHitTesting(false)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                }
                
                Button {
                    viewModel.createNewSession()
                    dismiss()
                    NotificationCenter.default.post(name: .requestSwitchToChatTab, object: nil)
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
            }

            Section("拓展能力") {
                NavigationLink {
                    ToolCenterView()
                        .environmentObject(viewModel)
                } label: {
                    Label(NSLocalizedString("工具中心", comment: "Tool center title"), systemImage: "slider.horizontal.3")
                }

                NavigationLink {
                    LongTermMemoryFeatureView()
                        .environmentObject(viewModel)
                } label: {
                    Label("长期记忆系统", systemImage: "brain.head.profile")
                }

                NavigationLink {
                    MCPIntegrationView()
                } label: {
                    Label("MCP 工具集成", systemImage: "network")
                }

                NavigationLink {
                    ShortcutIntegrationView()
                } label: {
                    Label("快捷指令工具集成", systemImage: "bolt.horizontal.circle")
                }

                NavigationLink {
                    ImageGenerationFeatureView()
                        .environmentObject(viewModel)
                } label: {
                    Label(NSLocalizedString("图片生成", comment: "Image generation feature entry title"), systemImage: "photo.on.rectangle.angled")
                }

                NavigationLink {
                    WorldbookSettingsView().environmentObject(viewModel)
                } label: {
                    Label("世界书", systemImage: "book.pages")
                }

                NavigationLink {
                    ExtendedFeaturesView()
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
                        enableExperimentalToolResultDisplay: $viewModel.enableExperimentalToolResultDisplay,
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

            Section(NSLocalizedString("后台通知", comment: "Background notification section title")) {
                Toggle(
                    NSLocalizedString("后台收到 AI 回复后通知我", comment: "Toggle for background AI reply notification"),
                    isOn: $viewModel.enableBackgroundReplyNotification
                )

                Button(NSLocalizedString("请求通知权限", comment: "Request notification permission button")) {
                    viewModel.requestBackgroundReplyNotificationPermission()
                }
                .disabled(!viewModel.enableBackgroundReplyNotification)

                Button(NSLocalizedString("打开系统通知设置", comment: "Open system notification settings button")) {
                    viewModel.openSystemNotificationSettings()
                }
            } footer: {
                Text(
                    NSLocalizedString(
                        "当应用在后台完成回复时，发送系统通知提醒。",
                        comment: "Background AI reply notification section footer"
                    )
                )
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
        .onAppear {
            ensureSelectedModel(in: viewModel.activatedModels)
        }
        .onChange(of: viewModel.activatedModels.map(\.id)) { _, _ in
            ensureSelectedModel(in: viewModel.activatedModels)
        }
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

private struct CurrentModelSelectionView: View {
    @Environment(\.dismiss) private var dismiss

    let models: [RunnableModel]
    @Binding var selectedModel: RunnableModel?

    var body: some View {
        List {
            ForEach(models) { model in
                Button {
                    select(model)
                } label: {
                    MarqueeTitleSubtitleSelectionRow(
                        title: model.model.displayName,
                        subtitle: "\(model.provider.name) · \(model.model.modelName)",
                        isSelected: selectedModel?.id == model.id,
                        subtitleUIFont: .monospacedSystemFont(
                            ofSize: UIFont.preferredFont(forTextStyle: .caption2).pointSize,
                            weight: .regular
                        )
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
}
