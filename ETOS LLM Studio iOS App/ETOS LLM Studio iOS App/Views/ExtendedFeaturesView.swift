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
                        .font(.headline)
                        .padding(.vertical, 4)
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
                        .font(.headline)
                        .padding(.vertical, 4)
                }
            } footer: {
                Text("连接符合 Model Context Protocol 的工具服务器，直接在客户端管理和调试。")
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
