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
    
    public init() {}
    
    public var body: some View {
        List {
            Section {
                NavigationLink {
                    LongTermMemoryFeatureView()
                        .environmentObject(viewModel)
                } label: {
                    Label("长期记忆系统", systemImage: "brain.head.profile")
                        .font(.headline)
                        .padding(.vertical, 4)
                }
            } footer: {
                Text("让 AI 根据历史偏好与事件持续优化回答。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }

            Section {
                NavigationLink {
                    MCPIntegrationView()
                } label: {
                    Label("MCP 工具集成", systemImage: "network")
                        .font(.headline)
                        .padding(.vertical, 4)
                }
            } footer: {
                Text("配置 MCP 工具服务器，让助手调用外部能力。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }

            Section {
                NavigationLink {
                    ShortcutIntegrationView()
                } label: {
                    Label("快捷指令工具集成", systemImage: "bolt.horizontal.circle")
                        .font(.headline)
                        .padding(.vertical, 4)
                }
            } footer: {
                Text("导入快捷指令工具并控制 AI 的调用权限。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }

            Section {
                NavigationLink {
                    WorldbookSettingsView(viewModel: viewModel)
                } label: {
                    Label("世界书", systemImage: "book.pages")
                        .font(.headline)
                        .padding(.vertical, 4)
                }
            } footer: {
                Text("管理世界书并绑定到当前会话。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }

            Section {
                NavigationLink {
                    LocalDebugView()
                } label: {
                    Label("远程文件访问", systemImage: "terminal")
                        .font(.headline)
                        .padding(.vertical, 4)
                }
            } footer: {
                Text("通过局域网远程访问和管理 Documents 目录。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }

            Section {
                NavigationLink {
                    StorageManagementView()
                } label: {
                    Label("存储管理", systemImage: "internaldrive")
                        .font(.headline)
                        .padding(.vertical, 4)
                }
            } footer: {
                Text("查看并清理本地模型、文件与缓存。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }

            Section {
                NavigationLink {
                    ImageGenerationFeatureView()
                        .environmentObject(viewModel)
                } label: {
                    Label(NSLocalizedString("图片生成", comment: "Image generation feature entry title"), systemImage: "photo.on.rectangle.angled")
                        .font(.headline)
                        .padding(.vertical, 4)
                }
            } footer: {
                Text("生图在独立页面发起，不影响主聊天输入区。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("拓展功能")
    }
}

// MARK: - 长期记忆设置

private struct LongTermMemoryFeatureView: View {
    @EnvironmentObject var viewModel: ChatViewModel
    
    @AppStorage("enableMemory") private var enableMemory: Bool = true
    @AppStorage("enableMemoryWrite") private var enableMemoryWrite: Bool = true
    
    var body: some View {
        List {
            Section {
                Toggle("启用记忆功能", isOn: $enableMemory)
            } footer: {
                Text("启用后，AI 将拥有长期记忆能力。它会在每次对话前检索相关记忆，并能通过工具主动学习。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            
            if enableMemory {
                Section {
                    Toggle("是否记录新的记忆", isOn: $enableMemoryWrite)
                } footer: {
                    Text("关闭后仅读取记忆，不保存新内容。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                
                Section {
                    if #available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *) {
                        NavigationLink(destination: MemorySettingsView().environmentObject(viewModel)) {
                            Label("记忆库管理", systemImage: "folder.badge.gearshape")
                        }
                    } else {
                        Label("记忆库管理 (系统版本过低)", systemImage: "folder.badge.gearshape")
                            .foregroundColor(.gray)
                    }
                }
            }
        }
        .navigationTitle("长期记忆系统")
    }
}
