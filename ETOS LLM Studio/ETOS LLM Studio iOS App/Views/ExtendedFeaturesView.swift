import SwiftUI
import Shared

struct ExtendedFeaturesView: View {
    @EnvironmentObject var viewModel: ChatViewModel
    
    var body: some View {
        List {
            Section {
                NavigationLink {
                    LongTermMemoryFeatureView()
                        .environmentObject(viewModel)
                } label: {
                    Label("长期记忆系统", systemImage: "brain.head.profile")
                }
            } footer: {
                Text("让 AI 根据历史偏好与事件持续优化回答。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                NavigationLink {
                    MCPIntegrationView()
                } label: {
                    Label("MCP 工具集成", systemImage: "network")
                }
            } footer: {
                Text("配置 MCP 工具服务器，让助手调用外部能力。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                NavigationLink {
                    ShortcutIntegrationView()
                } label: {
                    Label("快捷指令工具集成", systemImage: "bolt.horizontal.circle")
                }
            } footer: {
                Text("把快捷指令作为可调用工具导入，支持权限确认与回调。")
                    .font(.footnote)
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
                    .font(.footnote)
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
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                NavigationLink {
                    ImageGenerationFeatureView()
                        .environmentObject(viewModel)
                } label: {
                    Label(NSLocalizedString("图片生成", comment: "Image generation feature entry title"), systemImage: "photo.on.rectangle.angled")
                }
            } footer: {
                Text("生图在独立页面发起，不影响主聊天输入区。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("拓展功能")
        .listStyle(.insetGrouped)
    }
}

// MARK: - 长期记忆设置

private struct LongTermMemoryFeatureView: View {
    @EnvironmentObject var viewModel: ChatViewModel
    
    @AppStorage("enableMemory") private var enableMemory: Bool = true
    @AppStorage("enableMemoryWrite") private var enableMemoryWrite: Bool = true
    
    var body: some View {
        Form {
            Section {
                Toggle("启用记忆功能", isOn: $enableMemory)
            } footer: {
                Text("启用后，AI 会在响应前自动检索相关记忆，并可选择写入新的记忆片段。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            
            if enableMemory {
                Section {
                    Toggle("允许写入新的记忆", isOn: $enableMemoryWrite)
                } footer: {
                    Text("关闭后仅读取记忆，不会请求保存新内容。")
                        .font(.footnote)
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
