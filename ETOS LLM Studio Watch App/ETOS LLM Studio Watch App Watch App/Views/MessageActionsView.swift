// ============================================================================
// MessageActionsView.swift
// ============================================================================
// ETOS LLM Studio Watch App 消息操作菜单视图
//
// 功能特性:
// - 提供编辑、重试、删除单条消息的快捷操作
// ============================================================================

import SwiftUI
import Shared

struct MessageActionsView: View {
    
    // MARK: - 属性与操作
    
    let message: ChatMessage
    let canRetry: Bool
    let onEdit: () -> Void
    let onRetry: () -> Void
    let onDelete: () -> Void
    
    let messageIndex: Int?
    let totalMessages: Int
    
    // MARK: - 环境
    
    @Environment(\.dismiss) var dismiss

    // MARK: - 视图主体
    
    var body: some View {
        Form {
            Section {
                Button {
                    onEdit()
                    dismiss()
                } label: {
                    Label("编辑消息", systemImage: "pencil")
                }

                if canRetry {
                    Button {
                        onRetry()
                        dismiss()
                    } label: {
                        Label("重试", systemImage: "arrow.clockwise")
                    }
                }
            }
            
            Section {
                Button(role: .destructive) {
                    onDelete()
                    dismiss()
                } label: {
                    Label("删除消息", systemImage: "trash.fill")
                }
            }
            
            Section(header: Text("详细信息")) {
                if let index = messageIndex {
                    VStack(alignment: .leading) {
                        Text("会话位置")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("第 \(index + 1) / \(totalMessages) 条")
                            .font(.caption2)
                    }
                }
                
                VStack(alignment: .leading) {
                    Text("消息 ID")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(message.id.uuidString)
                        .font(.caption2)
                }
            }
        }
        .navigationTitle("操作")
        .navigationBarTitleDisplayMode(.inline)
    }
}
