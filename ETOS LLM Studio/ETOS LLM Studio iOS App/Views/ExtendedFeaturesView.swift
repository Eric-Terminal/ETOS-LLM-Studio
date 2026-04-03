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
                    details: "适合统一管理实验性能力、数据导入和本地维护工具。常用入口可优先放在上方，按需逐步开启。",
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
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.wrappedValue.toggle()
                }
            } label: {
                Text(isExpanded.wrappedValue ? "收起介绍" : "进一步了解…")
                    .etFont(.footnote.weight(.medium))
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)

            if isExpanded.wrappedValue {
                Text(details)
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
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
                    details: "开启后会在回复前检索相关记忆；你也可以按需控制是否允许写入新记忆，并进入记忆库管理做精细维护。",
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
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.wrappedValue.toggle()
                }
            } label: {
                Text(isExpanded.wrappedValue ? "收起介绍" : "进一步了解…")
                    .etFont(.footnote.weight(.medium))
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)

            if isExpanded.wrappedValue {
                Text(details)
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }
}
