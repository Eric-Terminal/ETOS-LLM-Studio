// ============================================================================
// EditSessionNameView.swift
// ============================================================================
// ETOS LLM Studio Watch App 会话名称编辑视图
//
// 功能特性:
// - 提供编辑会话（话题）名称的界面
// - 保存修改后的名称
// ============================================================================

import SwiftUI

/// 用于编辑会话名称的视图
struct EditSessionNameView: View {
    
    // MARK: - 绑定与属性
    
    @Binding var session: ChatSession
    var onSave: () -> Void
    
    // MARK: - 状态
    
    @State private var newName: String
    
    // MARK: - 环境
    
    @Environment(\.dismiss) var dismiss

    // MARK: - 初始化器
    
    init(session: Binding<ChatSession>, onSave: @escaping () -> Void) {
        _session = session
        self.onSave = onSave
        _newName = State(initialValue: session.wrappedValue.name)
    }

    // MARK: - 视图主体
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                TextField("输入新名称", text: $newName)
                    .textFieldStyle(.plain)
                    .padding()

                Button("保存") {
                    session.name = newName
                    onSave()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            .navigationTitle("编辑话题")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }
            }
        }
    }
}
