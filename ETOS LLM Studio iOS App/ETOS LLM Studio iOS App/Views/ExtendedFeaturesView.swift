import SwiftUI
import Shared

struct ExtendedFeaturesView: View {
    @EnvironmentObject var viewModel: ChatViewModel
    @AppStorage("enableMemory") private var enableMemory: Bool = true
    @AppStorage("enableMemoryWrite") private var enableMemoryWrite: Bool = true
    
    var body: some View {
        Form {
            Section {
                Toggle("启用记忆功能", isOn: $enableMemory)
            } header: {
                Text("长期记忆")
            } footer: {
                Text("启用后，AI 会在响应前自动检索相关记忆，并可选择写入新的记忆片段。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            
            if enableMemory {
                Section {
                    Toggle("允许写入新的记忆", isOn: $enableMemoryWrite)
                } header: {
                    Text("记忆写入")
                } footer: {
                    Text("关闭后仅读取记忆，不会请求保存新内容。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                
                Section {
                    NavigationLink {
                        MemorySettingsView().environmentObject(viewModel)
                    } label: {
                        Label("记忆库管理", systemImage: "brain.head.profile")
                    }
                } header: {
                    Text("记忆库管理")
                }
            }
        }
        .navigationTitle("拓展功能")
    }
}
