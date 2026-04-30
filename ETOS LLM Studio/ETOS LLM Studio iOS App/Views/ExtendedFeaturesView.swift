// ============================================================================
// ExtendedFeaturesView.swift
// ============================================================================
// ExtendedFeaturesView 界面 (iOS)
// - 负责该功能在 iOS 端的交互与展示
// - 遵循项目现有视图结构与状态流
// ============================================================================

import SwiftUI
import Shared

struct ExtendedFeaturesView: View {
    @ObservedObject private var achievementCenter = AchievementCenter.shared
    @State private var isShowingIntroDetails = false

    var body: some View {
        List {
            Section {
                settingsIntroCard(
                    title: "拓展功能",
                    summary: "这里集中放置进阶能力、调试入口与跨平台工具集成。",
                    details: """
                    这个页面适合做什么
                    • 集中管理非核心聊天流程的进阶能力。
                    • 快速进入维护、导入、调试等工具入口。

                    各入口怎么选
                    • 反馈助手：提交问题和追踪处理进度。
                    • 远程文件访问：在局域网内访问 Documents 做排查或批量处理。
                    • 存储管理：清理模型、文件、缓存，回收空间。
                    • 导入数据：导入 ETOS 导出包或第三方应用迁移数据。

                    使用建议
                    • 不常用的功能可按需开启，避免主流程过载。
                    • 涉及导入与清理时，建议先备份关键数据再执行。
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
                        SettingsListIconLabel("成就日记", icon: .achievementJournal)
                    }
                }
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
    
    @AppStorage("enableMemory") private var enableMemory: Bool = true
    @AppStorage("enableMemoryWrite") private var enableMemoryWrite: Bool = true
    @AppStorage("enableConversationMemoryAsync") private var enableConversationMemoryAsync: Bool = true
    @State private var isShowingIntroDetails = false
    
    var body: some View {
        Form {
            Section {
                settingsIntroCard(
                    title: "记忆系统",
                    summary: "让 AI 在多轮对话里持续记住你的偏好、背景与目标。",
                    details: """
                    能力说明
                    • 记忆系统会在每次回复前参与检索，帮助模型关联你过去的偏好与上下文。
                    • 与“世界书”不同，记忆系统是可持续积累、可读可写的动态知识。

                    关键开关
                    • 启用记忆功能：总开关。关闭后不会检索、也不会写入新记忆。
                    • 允许写入新的记忆：仅控制“写入”，关闭后仍可读取已有记忆。

                    推荐用法
                    1. 先开启总开关观察回答是否更贴合长期习惯。
                    2. 如果担心噪声记忆，先关闭写入，仅保留读取。
                    3. 通过“记忆库管理”定期清理低质量或过时记忆。

                    常见问题
                    • 回答变得重复：可能记忆冗余，建议进入记忆库整理。
                    • 明明开了但没效果：先确认会话未被世界书隔离策略屏蔽相关工具。
                    """,
                    isExpanded: $isShowingIntroDetails
                )
            }

            Section {
                Toggle(NSLocalizedString("启用记忆功能", comment: "启用记忆功能开关"), isOn: $enableMemory)
            } footer: {
                Text(NSLocalizedString("启用后，AI 会在响应前自动检索相关记忆，并可选择写入新的记忆片段。", comment: "启用记忆功能说明"))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }
            
            if enableMemory {
                Section {
                    Toggle(NSLocalizedString("允许写入新的记忆", comment: "允许写入新记忆开关"), isOn: $enableMemoryWrite)
                } footer: {
                    Text(NSLocalizedString("关闭后仅读取记忆，不会请求保存新内容。", comment: "关闭记忆写入说明"))
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Toggle(NSLocalizedString("启用异步跨对话记忆", comment: "启用异步跨对话记忆开关"), isOn: $enableConversationMemoryAsync)

                    if enableConversationMemoryAsync {
                        NavigationLink {
                            ConversationMemorySettingsView()
                                .environmentObject(viewModel)
                        } label: {
                            SettingsListIconLabel("跨对话记忆与画像", icon: .conversationMemory)
                        }
                    }
                } header: {
                    Text(NSLocalizedString("跨对话记忆", comment: "跨对话记忆分组"))
                } footer: {
                    Text(NSLocalizedString("会话摘要会写入会话 JSON；用户画像会保存到 Memory 目录下，并限制为每天最多更新一次。", comment: "跨对话记忆说明"))
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
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
