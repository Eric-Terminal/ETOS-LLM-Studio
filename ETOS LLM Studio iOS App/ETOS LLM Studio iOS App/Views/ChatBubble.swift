// ============================================================================
// ChatBubble.swift
// ============================================================================
// ETOS LLM Studio Watch App 聊天气泡视图 (已重构)
//
// 功能特性:
// - 根据角色（用户/AI/错误）显示不同样式的气泡
// - 支持 Markdown 渲染
// - 思考过程的展开/折叠状态由外部传入的绑定控制
// ============================================================================

import SwiftUI
import MarkdownUI
import Shared

/// 聊天消息气泡组件
struct ChatBubble: View {
    
    // MARK: - 属性与绑定
    
    let message: ChatMessage
    @Binding var isReasoningExpanded: Bool
    @Binding var isToolCallsExpanded: Bool
    
    let enableMarkdown: Bool
    let enableBackground: Bool
    let enableLiquidGlass: Bool

    // MARK: - 视图主体
    
    var body: some View {
        HStack {
            // 重构: 使用 MessageRole 枚举进行判断
            switch message.role {
            case .user:
                Spacer()
                userBubble
            case .error:
                errorBubble
                Spacer()
            case .assistant, .system, .tool: // system 和 tool 也使用 assistant 样式
                assistantBubble
                Spacer()
            @unknown default:
                // 为未来可能增加的 role 类型提供一个默认的回退，防止编译错误
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
                .background(Color.blue.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 12))
        } else {
            if enableBackground {
                content
                    .background(Color.blue.opacity(0.7))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                content
                    .background(Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
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
                .background(Color.red.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 12))
        } else {
            if enableBackground {
                content
                    .background(Color.red.opacity(0.7))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                content
                    .background(Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
    }
    
    @ViewBuilder
    private var assistantBubble: some View {
        let content = VStack(alignment: .leading, spacing: 8) {
            
            let hasReasoning = message.reasoningContent != nil && !message.reasoningContent!.isEmpty
            let hasToolCalls = message.toolCalls != nil && !message.toolCalls!.isEmpty
            
            // 思考过程区域
            if let reasoning = message.reasoningContent, !reasoning.isEmpty {
                reasoningView(reasoning)
            }
            
            // 工具调用区域
            if let toolCalls = message.toolCalls, !toolCalls.isEmpty {
                // 如果思考过程和工具调用同时存在，添加一个分隔线
                if hasReasoning {
                    Divider().background(Color.gray.opacity(0.5))
                }
                toolCallsView(toolCalls)
            }
            
            // 如果有附加信息（思考或工具），且有实际内容，则添加主分隔线
            if (hasReasoning || hasToolCalls) && !message.content.isEmpty {
               Divider().background(Color.gray)
            }
            
            // 消息内容区域
            if !message.content.isEmpty {
                renderContent(message.content)
            }
            
            // 加载指示器
            if message.role == .assistant && message.content.isEmpty && (message.reasoningContent ?? "").isEmpty {
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
            if enableBackground {
                content
                    .background(Color.black.opacity(0.3))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                content
                    .background(Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
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
                    isReasoningExpanded.toggle()
                }
            }) {
                HStack {
                    Text("思考过程")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    Spacer()
                    Image(systemName: isReasoningExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption)
                }
                .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)

            if isReasoningExpanded {
                Text(reasoning)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.bottom, isReasoningExpanded ? 5 : 0)
    }
    
    @ViewBuilder
    private func toolCallsView(_ toolCalls: [InternalToolCall]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Button(action: {
                withAnimation {
                    isToolCallsExpanded.toggle()
                }
            }) {
                HStack {
                    Text("使用工具")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    Spacer()
                    Image(systemName: isToolCallsExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption)
                }
                .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)

            if isToolCallsExpanded {
                ForEach(toolCalls, id: \.id) { toolCall in
                    HStack {
                        Image(systemName: "wrench.and.screwdriver.fill")
                        Text(toolCall.toolName)
                    }
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .padding(.leading, 4)
                }
            }
        }
        .padding(.bottom, isToolCallsExpanded ? 5 : 0)
    }
}