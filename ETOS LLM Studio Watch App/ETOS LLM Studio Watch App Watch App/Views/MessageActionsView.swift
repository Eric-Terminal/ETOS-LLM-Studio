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
    @State private var showDeleteConfirm = false

    // MARK: - 视图主体
    
    var body: some View {
        // 有音频或图片附件的消息不显示编辑按钮
        let hasAttachments = message.audioFileName != nil || (message.imageFileNames?.isEmpty == false)
        
        Form {
            Section {
                if !hasAttachments {
                    Button {
                        onEdit()
                        dismiss()
                    } label: {
                        Label("编辑消息", systemImage: "pencil")
                    }
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
                    showDeleteConfirm = true
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
            
            if let usage = message.tokenUsage, usage.hasData {
                Section("Token 用量") {
                    if let prompt = usage.promptTokens {
                        LabeledContent("发送 Tokens", value: "\(prompt)")
                    }
                    if let completion = usage.completionTokens {
                        LabeledContent("接收 Tokens", value: "\(completion)")
                    }
                    if let total = usage.totalTokens, (usage.promptTokens != total || usage.completionTokens != total) {
                        LabeledContent("总计", value: "\(total)")
                    } else if let totalOnly = usage.totalTokens, usage.promptTokens == nil && usage.completionTokens == nil {
                        LabeledContent("总计", value: "\(totalOnly)")
                    }
                }
            }
        }
        .navigationTitle("操作")
        .navigationBarTitleDisplayMode(.inline)
        .alert("确认删除消息", isPresented: $showDeleteConfirm) {
            Button("删除", role: .destructive) {
                onDelete()
                dismiss()
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("删除后无法恢复这条消息。")
        }
    }
}
