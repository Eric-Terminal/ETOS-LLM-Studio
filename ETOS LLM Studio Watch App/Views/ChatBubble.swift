// ============================================================================
// ChatBubble.swift
// ============================================================================
// ETOS LLM Studio Watch App 聊天气泡视图
//
// 功能特性:
// - 根据角色（用户/AI/错误）显示不同样式的气泡
// - 支持 Markdown 渲染
// - 支持 AI 思考过程的展开和折叠
// ============================================================================

import SwiftUI
import MarkdownUI

/// 聊天消息气泡组件
struct ChatBubble: View {
    
    // MARK: - 绑定与属性
    
    @Binding var message: ChatMessage
    let enableMarkdown: Bool
    let enableBackground: Bool
    let enableLiquidGlass: Bool

    // MARK: - 视图主体
    
    var body: some View {
        HStack {
            if message.role == "user" {
                Spacer()
                userBubble
            } else if message.role == "error" {
                errorBubble
                Spacer()
            } else { // assistant
                assistantBubble
                Spacer()
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
    }
    
    // MARK: - 气泡视图
    
    @ViewBuilder
    private var userBubble: some View {
        let content = renderContent(message.content)
            .padding(10)
            .foregroundColor(.white)

        if enableLiquidGlass {
            content
                .glassEffect(.clear, in: RoundedRectangle(cornerRadius: 12))
                .background(.blue.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 12))
        } else {
            content
                .background(enableBackground ? Color.blue.opacity(0.7) : Color.blue)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
    
    @ViewBuilder
    private var errorBubble: some View {
        let content = Text(message.content)
            .padding(10)
            .foregroundColor(.white)

        if enableLiquidGlass {
            content
                .glassEffect(.clear, in: RoundedRectangle(cornerRadius: 12))
                .background(.red.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 12))
        } else {
            content
                .background(enableBackground ? Color.red.opacity(0.7) : Color.red)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
    
    @ViewBuilder
    private var assistantBubble: some View {
        let content = VStack(alignment: .leading, spacing: 8) {
            // 思考过程区域
            if let reasoning = message.reasoning, !reasoning.isEmpty {
                reasoningView(reasoning)
                
                if !message.content.isEmpty {
                   Divider().background(Color.gray)
                }
            }
            
            // 消息内容区域
            if !message.content.isEmpty {
                renderContent(message.content)
            }
            
            // 加载中指示器
            if message.isLoading {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.small)
                    Text("正在思考...").font(.caption).foregroundColor(.secondary)
                }
            }
        }
        .padding(10)

        if enableLiquidGlass {
            content.glassEffect(.clear, in: RoundedRectangle(cornerRadius: 12))
        } else {
            content
                .background(enableBackground ? Color.black.opacity(0.3) : Color(white: 0.3))
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
    
    // MARK: - 辅助视图
    
    @ViewBuilder
    private func renderContent(_ content: String) -> some View {
        if enableMarkdown {
            Markdown(content)
        } else {
            Text(content)
        }
    }
    
    @ViewBuilder
    private func reasoningView(_ reasoning: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Button(action: {
                withAnimation {
                    message.isReasoningExpanded = !(message.isReasoningExpanded ?? false)
                }
            }) {
                HStack {
                    Text("思考过程")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    Spacer()
                    Image(systemName: message.isReasoningExpanded == true ? "chevron.down" : "chevron.right")
                        .font(.caption)
                }
                .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)

            if message.isReasoningExpanded == true {
                Text(reasoning)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.bottom, message.isReasoningExpanded == true ? 5 : 0)
    }
}
