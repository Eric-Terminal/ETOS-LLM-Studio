// ============================================================================
// EditMessageView.swift
// ============================================================================
// ETOS LLM Studio Watch App 消息编辑视图 (已重构)
//
// 功能特性:
// - 提供编辑消息内容和 AI 思考过程的界面
// - 保存修改后的消息
// ============================================================================

import SwiftUI
import Shared

/// 用于编辑单条消息内容的视图
struct EditMessageView: View {
    
    // MARK: - 属性与回调
    
    let message: ChatMessage // 重构: 不再是绑定，只是一个不可变的初始值
    var onSave: (ChatMessage) -> Void
    
    // MARK: - 状态
    
    @State private var newContent: String
    @State private var newReasoning: String
    
    // MARK: - 环境
    
    @Environment(\.dismiss) var dismiss

    // MARK: - 初始化器
    
    init(message: ChatMessage, onSave: @escaping (ChatMessage) -> Void) {
        self.message = message
        self.onSave = onSave
        // 使用 @State 的初始值包装器来设置初始状态
        _newContent = State(initialValue: message.content)
        // 重构: 使用新的属性名 reasoningContent
        _newReasoning = State(initialValue: message.reasoningContent ?? "")
    }

    // MARK: - 视图主体
    
    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("回复内容")) {
                    TextField("编辑消息", text: $newContent, axis: .vertical)
                        .lineLimit(5...15)
                        .listRowBackground(Color.clear)
                }
                
                // 重构: 使用 MessageRole 枚举进行判断
                if message.role == .assistant {
                    Section(header: Text("思考过程 (可选)")) {
                        TextField("编辑思考过程", text: $newReasoning, axis: .vertical)
                            .lineLimit(5...10)
                            .listRowBackground(Color.clear)
                    }
                }
                
                Button("保存") {
                    // 重构: 创建一个 message 的新副本并修改它
                    var updatedMessage = message
                    updatedMessage.content = newContent
                    updatedMessage.reasoningContent = newReasoning.isEmpty ? nil : newReasoning
                    
                    // 通过回调将修改后的新副本传回
                    onSave(updatedMessage)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .listRowBackground(Color.clear)
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