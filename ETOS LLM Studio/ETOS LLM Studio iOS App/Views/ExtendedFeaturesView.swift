// ============================================================================
// ExtendedFeaturesView.swift
// ============================================================================
// ExtendedFeaturesView 界面 (iOS)
// - 负责该功能在 iOS 端的交互与展示
// - 遵循项目现有视图结构与状态流
// ============================================================================

import SwiftUI
import ETOSCore

struct ExtendedFeaturesView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @ObservedObject private var achievementCenter = AchievementCenter.shared
    @State private var isShowingIntroDetails = false

    var body: some View {
        List {
            Section {
                settingsIntroCard(
                    title: NSLocalizedString("拓展功能", comment: "Extended features intro title"),
                    summary: NSLocalizedString("这里集中放置进阶能力、调试入口与跨平台工具集成。", comment: "Extended features intro summary"),
                    details: NSLocalizedString("拓展功能说明正文", comment: "Extended features intro details"),
                    isExpanded: $isShowingIntroDetails
                )
            }

            if achievementCenter.hasUnlockedAchievements {
                Section {
                    // 彩蛋入口只在已有记录后出现，避免提前暴露隐藏日记。
                    NavigationLink {
                        AchievementJournalView()
                    } label: {
                        SettingsListIconLabel("成就日记", icon: .achievementJournal)
                    }
                }
            }

            Section {
                NavigationLink {
                    AppLockSettingsView()
                } label: {
                    SettingsListIconLabel("应用锁", icon: .security)
                }
            } header: {
                Text(NSLocalizedString("安全", comment: "设置安全分组"))
            } footer: {
                Text(NSLocalizedString("保护本机界面与离线数据库文件。", comment: "应用锁入口说明"))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                NavigationLink {
                    FeedbackCenterView()
                } label: {
                    SettingsListIconLabel("反馈助手", icon: .feedback)
                }
            } footer: {
                Text(NSLocalizedString("在 App 内提交并追踪反馈工单", comment: "反馈助手入口说明"))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                NavigationLink {
                    LocalModelManagementView()
                } label: {
                    SettingsListIconLabel("本地模型", icon: .localModels)
                }
            } footer: {
                Text(NSLocalizedString("管理本机 GGUF 权重、提供商开关与高级调参。", comment: "本地模型入口说明"))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                NavigationLink {
                    ImageGenerationFeatureView()
                        .environmentObject(viewModel)
                } label: {
                    SettingsListIconLabel("图片相册", icon: .imageGeneration)
                }
            } footer: {
                Text(NSLocalizedString("查看当前会话中助手返回的图片。", comment: "图片相册入口说明"))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                NavigationLink {
                    LocalDebugView()
                } label: {
                    SettingsListIconLabel("远程文件访问", icon: .remoteFiles)
                }
            } footer: {
                Text(NSLocalizedString("通过局域网远程访问和管理 Documents 目录，方便命令行工具操作。", comment: "远程文件访问入口说明"))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                NavigationLink {
                    StorageManagementView()
                } label: {
                    SettingsListIconLabel("存储管理", icon: .storage)
                }
            } footer: {
                Text(NSLocalizedString("管理本地模型、文件与缓存占用。", comment: "存储管理入口说明"))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                NavigationLink {
                    ThirdPartyImportView()
                } label: {
                    SettingsListIconLabel("导入数据", icon: .importData)
                }
            } footer: {
                Text(NSLocalizedString("支持导入 ETOS 数据包，也可从 Cherry Studio 等来源迁移。", comment: "导入数据入口说明"))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(NSLocalizedString("拓展功能", comment: "拓展功能页标题"))
        .listStyle(.insetGrouped)
    }

    private func settingsIntroCard(
        title: String,
        summary: String,
        details: String,
        isExpanded: Binding<Bool>
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(NSLocalizedString(title, comment: "设置介绍卡片标题"))
                .etFont(.headline.weight(.semibold))
            Text(NSLocalizedString(summary, comment: "设置介绍卡片摘要"))
                .etFont(.subheadline)
                .foregroundStyle(.secondary)
            Button {
                isExpanded.wrappedValue = true
            } label: {
                Text(NSLocalizedString("进一步了解…", comment: "设置介绍卡片展开按钮"))
                    .etFont(.footnote.weight(.medium))
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .sheet(isPresented: isExpanded) {
            NavigationStack {
                ScrollView {
                    Text(NSLocalizedString(details, comment: "设置介绍卡片详情"))
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .navigationTitle(NSLocalizedString(title, comment: "设置介绍卡片详情标题"))
                .navigationBarTitleDisplayMode(.inline)
            }
        }
    }
}

// MARK: - 记忆系统设置

struct LongTermMemoryFeatureView: View {
    @EnvironmentObject var viewModel: ChatViewModel
    
    @State private var isShowingIntroDetails = false
    
    var body: some View {
        Form {
            Section {
                settingsIntroCard(
                    title: NSLocalizedString("记忆系统", comment: "Memory system intro title"),
                    summary: NSLocalizedString("让 AI 在多轮对话里持续记住你的偏好、背景与目标。", comment: "Memory system intro summary"),
                    details: NSLocalizedString("记忆系统说明正文", comment: "Memory system intro details"),
                    isExpanded: $isShowingIntroDetails
                )
            }

            Section {
                Toggle(NSLocalizedString("启用记忆功能", comment: "启用记忆功能开关"), isOn: $viewModel.enableMemory)
            } footer: {
                Text(NSLocalizedString("启用后，AI 会在响应前自动检索相关记忆，并可选择写入新的记忆片段。", comment: "启用记忆功能说明"))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }
            
            if viewModel.enableMemory {
                Section {
                    Toggle(NSLocalizedString("允许写入新的记忆", comment: "允许写入新记忆开关"), isOn: $viewModel.enableMemoryWrite)
                } footer: {
                    Text(NSLocalizedString("关闭后仅读取记忆，不会请求保存新内容。", comment: "关闭记忆写入说明"))
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Toggle(NSLocalizedString("启用异步跨对话记忆", comment: "启用异步跨对话记忆开关"), isOn: $viewModel.enableConversationMemoryAsync)

                    if viewModel.enableConversationMemoryAsync {
                        NavigationLink {
                            ConversationMemorySettingsView()
                                .environmentObject(viewModel)
                        } label: {
                            SettingsListIconLabel("跨对话记忆与画像", icon: .conversationMemory)
                        }
                    }
                } header: {
                    Text(NSLocalizedString("跨对话记忆", comment: "跨对话记忆分组"))
                }
                
                Section {
                    NavigationLink {
                        MemorySettingsView().environmentObject(viewModel)
                    } label: {
                        SettingsListIconLabel("记忆库管理", icon: .memoryLibrary)
                    }
                }
            }
        }
        .navigationTitle(NSLocalizedString("记忆系统", comment: "记忆系统页标题"))
    }

    private func settingsIntroCard(
        title: String,
        summary: String,
        details: String,
        isExpanded: Binding<Bool>
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(NSLocalizedString(title, comment: "设置介绍卡片标题"))
                .etFont(.headline.weight(.semibold))
            Text(NSLocalizedString(summary, comment: "设置介绍卡片摘要"))
                .etFont(.subheadline)
                .foregroundStyle(.secondary)
            Button {
                isExpanded.wrappedValue = true
            } label: {
                Text(NSLocalizedString("进一步了解…", comment: "设置介绍卡片展开按钮"))
                    .etFont(.footnote.weight(.medium))
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .sheet(isPresented: isExpanded) {
            NavigationStack {
                ScrollView {
                    Text(NSLocalizedString(details, comment: "设置介绍卡片详情"))
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .navigationTitle(NSLocalizedString(title, comment: "设置介绍卡片详情标题"))
                .navigationBarTitleDisplayMode(.inline)
            }
        }
    }
}
