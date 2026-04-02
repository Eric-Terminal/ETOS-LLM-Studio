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
    var body: some View {
        List {
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
}

// MARK: - 长期记忆设置

struct LongTermMemoryFeatureView: View {
    @EnvironmentObject var viewModel: ChatViewModel
    
    @AppStorage("enableMemory") private var enableMemory: Bool = true
    @AppStorage("enableMemoryWrite") private var enableMemoryWrite: Bool = true
    
    var body: some View {
        Form {
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
}
