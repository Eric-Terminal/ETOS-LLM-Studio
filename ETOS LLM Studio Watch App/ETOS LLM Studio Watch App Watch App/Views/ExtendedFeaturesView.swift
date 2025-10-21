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
    
    // 使用 AppStorage 来持久化记忆功能的开关状态
    @AppStorage("enableMemory") private var enableMemory: Bool = true
    @AppStorage("enableMemoryWrite") private var enableMemoryWrite: Bool = true
    
    public init() {}
    
    public var body: some View {
        List {
            Section(header: Text("长期记忆"), footer: Text("启用后，AI将拥有长期记忆能力。它会在每次对话前自动检索相关记忆，并能通过工具主动学习和保存新信息。")) {
                Toggle("启用记忆功能", isOn: $enableMemory)
                
                // 只有在功能启用时才显示管理入口
                if enableMemory {
                    Toggle("是否记录新的记忆", isOn: $enableMemoryWrite)
                    Text("关闭后仅读取记忆，不会请求保存新内容。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    
                    // 我们之前注释掉的 #available 检查仍然是必要的
                    if #available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *) {
                        NavigationLink(destination: MemorySettingsView().environmentObject(viewModel)) {
                            Label("记忆库管理", systemImage: "brain.head.profile")
                        }
                    } else {
                        Label("记忆库管理 (系统版本过低)", systemImage: "brain.head.profile")
                            .foregroundColor(.gray)
                    }
                }
            }
        }
        .navigationTitle("拓展功能")
    }
}
