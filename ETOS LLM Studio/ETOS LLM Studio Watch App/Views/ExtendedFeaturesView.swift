// ============================================================================
// ExtendedFeaturesView.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件定义了“拓展功能”页面。
// 它为一些高级或实验性功能提供统一的入口和开关。
// ============================================================================

import SwiftUI
import Shared

public struct ExtendedFeaturesView: View {
    @EnvironmentObject var viewModel: ChatViewModel
    @ObservedObject private var achievementCenter = AchievementCenter.shared
    @AppStorage(ChatNavigationMode.storageKey) private var chatNavigationModeRawValue: String = ChatNavigationMode.defaultMode.rawValue
    @AppStorage(SettingsIconAppearancePreference.storageKey) private var useColorfulSettingsIcons: Bool = false
    @State private var isShowingIntroDetails = false
    
    public init() {}
    
    public var body: some View {
        List {
            Section {
                settingsIntroCard(
                    title: "拓展功能",
                    summary: "集中管理工具集成、语音能力与系统维护入口。",
                    details: """
                    这个页面适合做什么
                    • 统一进入进阶功能，不打断主聊天流程。
                    • 快速定位语音、工具集成、导入和维护能力。

                    入口建议
                    • 工具中心：排查工具是否在当前会话可用。
                    • 记忆系统 / 世界书：管理长期偏好与规则知识。
                    • MCP / 快捷指令：接入外部能力和自动化流程。
                    • 存储管理 / 远程文件访问：做维护与清理。

                    使用建议
                    • 先保证核心入口可用，再逐步开启实验功能。
                    """,
                    isExpanded: $isShowingIntroDetails
                )
            }

            if achievementCenter.hasUnlockedAchievements {
                Section {
                    // 彩蛋入口只在已有记录后出现，避免提前暴露隐藏日记。
                    NavigationLink {
                        AchievementJournalView()
                    } label: {
                        settingsNavigationLabel("成就日记", icon: .achievementJournal)
                            .etFont(.headline)
                            .padding(.vertical, 4)
                    }
                }
            }

            Section {
                NavigationLink {
                    ToolCenterView()
                        .environmentObject(viewModel)
                } label: {
                    settingsNavigationLabel("工具中心", icon: .toolCenter)
                        .etFont(.headline)
                        .padding(.vertical, 4)
                }
            } footer: {
                Text(NSLocalizedString("统一预览和调整聊天工具启用状态。", comment: "工具中心入口说明"))
                    .etFont(.footnote)
                    .foregroundColor(.secondary)
            }

            Section {
                NavigationLink {
                    TTSSettingsView()
                        .environmentObject(viewModel)
                } label: {
                    settingsNavigationLabel("语音朗读（TTS）", icon: .tts)
                        .etFont(.headline)
                        .padding(.vertical, 4)
                }

                NavigationLink {
                    SpeechInputSettingsView(
                        enableSpeechInput: $viewModel.enableSpeechInput,
                        selectedSpeechModel: speechModelBinding,
                        sendSpeechAsAudio: $viewModel.sendSpeechAsAudio,
                        audioRecordingFormat: $viewModel.audioRecordingFormat,
                        speechModels: viewModel.speechModels
                    )
                } label: {
                    settingsNavigationLabel("语音输入", icon: .speechInput)
                        .etFont(.headline)
                        .padding(.vertical, 4)
                }
            } footer: {
                Text(NSLocalizedString("统一管理语音输入与语音朗读。", comment: "语音能力入口说明"))
                    .etFont(.footnote)
                    .foregroundColor(.secondary)
            }

            Section {
                NavigationLink {
                    FeedbackCenterView()
                } label: {
                    settingsNavigationLabel("反馈助手", icon: .feedback)
                        .etFont(.headline)
                        .padding(.vertical, 4)
                }
            } footer: {
                Text(NSLocalizedString("在 App 内提交并追踪反馈工单", comment: "反馈助手入口说明"))
                    .etFont(.footnote)
                    .foregroundColor(.secondary)
            }

            Section {
                NavigationLink {
                    LongTermMemoryFeatureView()
                        .environmentObject(viewModel)
                } label: {
                    settingsNavigationLabel("记忆系统", icon: .memory)
                        .etFont(.headline)
                        .padding(.vertical, 4)
                }
            } footer: {
                Text(NSLocalizedString("让 AI 根据历史偏好与事件持续优化回答。", comment: "记忆系统入口说明"))
                    .etFont(.footnote)
                    .foregroundColor(.secondary)
            }

            Section {
                NavigationLink {
                    MCPIntegrationView()
                } label: {
                    settingsNavigationLabel("MCP 工具集成", icon: .mcp)
                        .etFont(.headline)
                        .padding(.vertical, 4)
                }
            } footer: {
                Text(NSLocalizedString("配置 MCP 工具服务器，让助手调用外部能力。", comment: "MCP 入口说明"))
                    .etFont(.footnote)
                    .foregroundColor(.secondary)
            }

            Section {
                NavigationLink {
                    ShortcutIntegrationView()
                } label: {
                    settingsNavigationLabel("快捷指令工具集成", icon: .shortcuts)
                        .etFont(.headline)
                        .padding(.vertical, 4)
                }
            } footer: {
                Text(NSLocalizedString("导入快捷指令工具并控制 AI 的调用权限。", comment: "快捷指令入口说明"))
                    .etFont(.footnote)
                    .foregroundColor(.secondary)
            }

            Section {
                NavigationLink {
                    AgentSkillsView()
                } label: {
                    settingsNavigationLabel("Agent Skills", icon: .agentSkills)
                        .etFont(.headline)
                        .padding(.vertical, 4)
                }
            } footer: {
                Text(NSLocalizedString("管理可按需加载的技能包，并控制是否向模型暴露 use_skill 工具。", comment: "Agent Skills 入口说明"))
                    .etFont(.footnote)
                    .foregroundColor(.secondary)
            }

            Section {
                NavigationLink {
                    WorldbookSettingsView(viewModel: viewModel)
                } label: {
                    settingsNavigationLabel("世界书", icon: .worldbook)
                        .etFont(.headline)
                        .padding(.vertical, 4)
                }
            } footer: {
                Text(NSLocalizedString("管理世界书并绑定到当前会话。", comment: "世界书入口说明"))
                    .etFont(.footnote)
                    .foregroundColor(.secondary)
            }

            Section {
                NavigationLink {
                    LocalDebugView()
                } label: {
                    settingsNavigationLabel("远程文件访问", icon: .remoteFiles)
                        .etFont(.headline)
                        .padding(.vertical, 4)
                }
            } footer: {
                Text(NSLocalizedString("通过局域网远程访问和管理 Documents 目录。", comment: "远程文件访问入口说明"))
                    .etFont(.footnote)
                    .foregroundColor(.secondary)
            }

            Section {
                NavigationLink {
                    StorageManagementView()
                } label: {
                    settingsNavigationLabel("存储管理", icon: .storage)
                        .etFont(.headline)
                        .padding(.vertical, 4)
                }
            } footer: {
                Text(NSLocalizedString("查看并清理本地模型、文件与缓存。", comment: "存储管理入口说明"))
                    .etFont(.footnote)
                    .foregroundColor(.secondary)
            }

            Section {
                NavigationLink {
                    ThirdPartyImportWatchHintView()
                } label: {
                    settingsNavigationLabel("导入数据", icon: .importData)
                        .etFont(.headline)
                        .padding(.vertical, 4)
                }
            } footer: {
                Text(NSLocalizedString("支持导入 ETOS 数据包，也可通过第三方来源迁移。", comment: "导入数据入口说明"))
                    .etFont(.footnote)
                    .foregroundColor(.secondary)
            }

            Section {
                NavigationLink {
                    ImageGenerationFeatureView()
                        .environmentObject(viewModel)
                } label: {
                    settingsNavigationLabel("图片生成", icon: .imageGeneration)
                        .etFont(.headline)
                        .padding(.vertical, 4)
                }
            } footer: {
                Text(NSLocalizedString("生图在独立页面发起，不影响主聊天输入区。", comment: "图片生成入口说明"))
                    .etFont(.footnote)
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle(NSLocalizedString("拓展功能", comment: "拓展功能页标题"))
    }

    private func settingsIntroCard(
        title: String,
        summary: String,
        details: String,
        isExpanded: Binding<Bool>
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(NSLocalizedString(title, comment: "设置介绍卡片标题"))
                .etFont(.footnote.weight(.semibold))
            Text(NSLocalizedString(summary, comment: "设置介绍卡片摘要"))
                .etFont(.caption2)
                .foregroundStyle(.secondary)
            Button {
                isExpanded.wrappedValue = true
            } label: {
                Text(NSLocalizedString("进一步了解…", comment: "设置介绍卡片展开按钮"))
                    .etFont(.caption2.weight(.medium))
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .sheet(isPresented: isExpanded) {
            ScrollView {
                Text(NSLocalizedString(details, comment: "设置介绍卡片详情"))
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        }
    }

    private var speechModelBinding: Binding<RunnableModel?> {
        Binding(
            get: { viewModel.selectedSpeechModel },
            set: { viewModel.setSelectedSpeechModel($0) }
        )
    }

    private var usesNativeSettingsIcons: Bool {
        ChatNavigationMode.resolvedMode(rawValue: chatNavigationModeRawValue) == .nativeNavigation
            && useColorfulSettingsIcons
    }

    @ViewBuilder
    private func settingsNavigationLabel(_ titleKey: String, icon: SettingsListIcon) -> some View {
        let title = NSLocalizedString(titleKey, comment: "设置列表入口标题")
        if usesNativeSettingsIcons {
            SettingsListIconLabel(title, icon: icon)
        } else {
            Label {
                Text(title)
            } icon: {
                Image(systemName: icon.legacySystemName)
            }
        }
    }
}

// MARK: - 记忆系统设置

struct LongTermMemoryFeatureView: View {
    @EnvironmentObject var viewModel: ChatViewModel
    
    @AppStorage("enableMemory") private var enableMemory: Bool = true
    @AppStorage("enableMemoryWrite") private var enableMemoryWrite: Bool = true
    @AppStorage("enableConversationMemoryAsync") private var enableConversationMemoryAsync: Bool = true
    @AppStorage(ChatNavigationMode.storageKey) private var chatNavigationModeRawValue: String = ChatNavigationMode.defaultMode.rawValue
    @AppStorage(SettingsIconAppearancePreference.storageKey) private var useColorfulSettingsIcons: Bool = false
    @State private var isShowingIntroDetails = false
    
    var body: some View {
        List {
            Section {
                settingsIntroCard(
                    title: "记忆系统",
                    summary: "让 AI 持续理解你的长期偏好和上下文。",
                    details: """
                    能力说明
                    • 记忆系统会在回复前检索历史信息，提升连续性。
                    • 写入开关仅影响“新增记忆”，不影响读取已有记忆。

                    推荐流程
                    1. 先开启总开关体验效果。
                    2. 对噪声敏感时可先关闭写入，仅保留读取。
                    3. 定期到记忆库管理清理低质量记忆。
                    """,
                    isExpanded: $isShowingIntroDetails
                )
            }

            Section {
                Toggle(NSLocalizedString("启用记忆功能", comment: "启用记忆功能开关"), isOn: $enableMemory)
            } footer: {
                Text(NSLocalizedString("启用后，AI 将拥有记忆系统能力。它会在每次对话前检索相关记忆，并能通过工具主动学习。", comment: "启用记忆功能说明"))
                    .etFont(.footnote)
                    .foregroundColor(.secondary)
            }
            
            if enableMemory {
                Section {
                    Toggle(NSLocalizedString("是否记录新的记忆", comment: "是否记录新记忆开关"), isOn: $enableMemoryWrite)
                } footer: {
                    Text(NSLocalizedString("关闭后仅读取记忆，不保存新内容。", comment: "关闭记忆写入说明"))
                        .etFont(.footnote)
                        .foregroundColor(.secondary)
                }

                Section {
                    Toggle(NSLocalizedString("启用异步跨对话记忆", comment: "启用异步跨对话记忆开关"), isOn: $enableConversationMemoryAsync)

                    if enableConversationMemoryAsync {
                        NavigationLink {
                            ConversationMemorySettingsView()
                                .environmentObject(viewModel)
                        } label: {
                            settingsNavigationLabel("跨对话记忆与画像", icon: .conversationMemory)
                        }
                    }
                } header: {
                    Text(NSLocalizedString("跨对话记忆", comment: "跨对话记忆分组"))
                } footer: {
                    Text(NSLocalizedString("会话摘要存入会话 JSON，用户画像存入 Memory/user_profile.json。", comment: "跨对话记忆说明"))
                        .etFont(.footnote)
                        .foregroundColor(.secondary)
                }
                
                Section {
                    if #available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *) {
                        NavigationLink(destination: MemorySettingsView().environmentObject(viewModel)) {
                            settingsNavigationLabel("记忆库管理", icon: .memoryLibrary)
                        }
                    } else {
                        settingsNavigationLabel("记忆库管理 (系统版本过低)", icon: .memoryLibrary)
                            .foregroundColor(.gray)
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
        VStack(alignment: .leading, spacing: 8) {
            Text(NSLocalizedString(title, comment: "设置介绍卡片标题"))
                .etFont(.footnote.weight(.semibold))
            Text(NSLocalizedString(summary, comment: "设置介绍卡片摘要"))
                .etFont(.caption2)
                .foregroundStyle(.secondary)
            Button {
                isExpanded.wrappedValue = true
            } label: {
                Text(NSLocalizedString("进一步了解…", comment: "设置介绍卡片展开按钮"))
                    .etFont(.caption2.weight(.medium))
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .sheet(isPresented: isExpanded) {
            ScrollView {
                Text(NSLocalizedString(details, comment: "设置介绍卡片详情"))
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        }
    }

    private var usesNativeSettingsIcons: Bool {
        ChatNavigationMode.resolvedMode(rawValue: chatNavigationModeRawValue) == .nativeNavigation
            && useColorfulSettingsIcons
    }

    @ViewBuilder
    private func settingsNavigationLabel(_ titleKey: String, icon: SettingsListIcon) -> some View {
        let title = NSLocalizedString(titleKey, comment: "设置列表入口标题")
        if usesNativeSettingsIcons {
            SettingsListIconLabel(title, icon: icon)
        } else {
            Label {
                Text(title)
            } icon: {
                Image(systemName: icon.legacySystemName)
            }
        }
    }
}
