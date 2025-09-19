// ============================================================================
// EditMessageView.swift
// ============================================================================
// ETOS LLM Studio Watch App 消息编辑视图
//
// 功能特性:
// - 提供编辑消息内容和 AI 思考过程的界面
// - 保存修改后的消息
// ============================================================================

import SwiftUI

/// 用于编辑单条消息内容的视图
struct EditMessageView: View {
    
    // MARK: - 绑定与属性
    
    @Binding var message: ChatMessage
    var onSave: (ChatMessage) -> Void
    
    // MARK: - 状态
    
    @State private var newContent: String
    @State private var newReasoning: String
    
    // MARK: - 环境
    
    @Environment(\.dismiss) var dismiss

    // MARK: - 初始化器
    
    init(message: Binding<ChatMessage>, onSave: @escaping (ChatMessage) -> Void) {
        _message = message
        self.onSave = onSave
        _newContent = State(initialValue: message.wrappedValue.content)
        _newReasoning = State(initialValue: message.wrappedValue.reasoning ?? "")
    }

    // MARK: - 视图主体
    
    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("回复内容")) {
                    TextField("编辑消息", text: $newContent, axis: .vertical)
                        .lineLimit(5...15)
                }
                
                if message.role == "assistant" {
                    Section(header: Text("思考过程 (可选)")) {
                        TextField("编辑思考过程", text: $newReasoning, axis: .vertical)
                            .lineLimit(5...10)
                    }
                }
                
                Button("保存") {
                    message.content = newContent
                    message.reasoning = newReasoning.isEmpty ? nil : newReasoning
                    onSave(message)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            .navigationTitle("编辑消息")
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
