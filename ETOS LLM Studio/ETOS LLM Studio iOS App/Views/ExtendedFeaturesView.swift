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
                    • 第三方导入：从外部应用迁移配置和会话。

                    使用建议
                    • 不常用的功能可按需开启，避免主流程过载。
                    • 涉及导入与清理时，建议先备份关键数据再执行。
                    """,
                    isExpanded: $isShowingIntroDetails
                )
            }

            Section {
                NavigationLink {
                    FeedbackCenterView()
                } label: {
                    Label(NSLocalizedString("反馈助手", comment: "反馈入口"), systemImage: "text.bubble")
                }
            } footer: {
                Text(NSLocalizedString("在 App 内提交并追踪反馈工单", comment: "In-app feedback description"))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                NavigationLink {
                    LocalDebugView()
                } label: {
                    Label("远程文件访问", systemImage: "terminal")
                }
            } footer: {
                Text("通过局域网远程访问和管理 Documents 目录,方便命令行工具操作。")
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                NavigationLink {
                    StorageManagementView()
                } label: {
                    Label("存储管理", systemImage: "internaldrive")
                }
            } footer: {
                Text("管理本地模型、文件与缓存占用。")
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                NavigationLink {
                    AgentSkillsView()
                } label: {
                    Label("Agent Skills", systemImage: "sparkles.square.filled.on.square")
                }
            } footer: {
                Text("管理可按需加载的技能包，并控制是否向模型暴露 use_skill 工具。")
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                NavigationLink {
                    ThirdPartyImportView()
                } label: {
                    Label("第三方导入", systemImage: "square.and.arrow.down.on.square")
                }
            } footer: {
                Text("从 Cherry Studio 等第三方应用导入提供商与会话。")
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("拓展功能")
        .listStyle(.insetGrouped)
    }

    private func settingsIntroCard(
        title: String,
        summary: String,
        details: String,
        isExpanded: Binding<Bool>
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .etFont(.headline.weight(.semibold))
            Text(summary)
                .etFont(.subheadline)
                .foregroundStyle(.secondary)
            Button {
                isExpanded.wrappedValue = true
            } label: {
                Text("进一步了解…")
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
                    Text(details)
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
            }
        }
    }
}

// MARK: - 长期记忆设置

struct LongTermMemoryFeatureView: View {
    @EnvironmentObject var viewModel: ChatViewModel
    
    @AppStorage("enableMemory") private var enableMemory: Bool = true
    @AppStorage("enableMemoryWrite") private var enableMemoryWrite: Bool = true
    @State private var isShowingIntroDetails = false
    
    var body: some View {
        Form {
            Section {
                settingsIntroCard(
                    title: "长期记忆系统",
                    summary: "让 AI 在多轮对话里持续记住你的偏好、背景与目标。",
                    details: """
                    能力说明
                    • 长期记忆会在每次回复前参与检索，帮助模型关联你过去的偏好与上下文。
                    • 与“世界书”不同，长期记忆是可持续积累、可读可写的动态知识。

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
                Toggle("启用记忆功能", isOn: $enableMemory)
            } footer: {
                Text("启用后，AI 会在响应前自动检索相关记忆，并可选择写入新的记忆片段。")
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }
            
            if enableMemory {
                Section {
                    Toggle("允许写入新的记忆", isOn: $enableMemoryWrite)
                } footer: {
                    Text("关闭后仅读取记忆，不会请求保存新内容。")
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                }
                
                Section {
                    NavigationLink {
                        MemorySettingsView().environmentObject(viewModel)
                    } label: {
                        Label("记忆库管理", systemImage: "folder.badge.gearshape")
                    }
                }
            }
        }
        .navigationTitle("长期记忆系统")
    }

    private func settingsIntroCard(
        title: String,
        summary: String,
        details: String,
        isExpanded: Binding<Bool>
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .etFont(.headline.weight(.semibold))
            Text(summary)
                .etFont(.subheadline)
                .foregroundStyle(.secondary)
            Button {
                isExpanded.wrappedValue = true
            } label: {
                Text("进一步了解…")
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
                    Text(details)
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
            }
        }
    }
}
