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
                Toggle(NSLocalizedString("启用生图模式", comment: "Enable image generation mode toggle title"), isOn: $viewModel.isImageGenerationModeEnabled)

                if viewModel.isImageGenerationModeEnabled {
                    Text(NSLocalizedString("已开启生图模式，请返回主页面，在输入框输入提示词后发送。", comment: "Guide user to return to main chat page for image generation"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    if !viewModel.supportsImageGenerationForSelectedModel {
                        Text(NSLocalizedString("当前模型不支持生图，请先切换到支持生图的模型。", comment: "Selected model not support image generation warning"))
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
            } footer: {
                Text(NSLocalizedString("该开关为临时状态，不会保存到本地；重启 App 后会自动关闭。", comment: "Image mode toggle not persisted note"))
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
