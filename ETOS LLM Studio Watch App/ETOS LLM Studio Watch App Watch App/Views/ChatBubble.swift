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
    @Binding var isExpanded: Bool // 用于控制思考过程的UI状态，由父视图传入
    
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
                .background(Color.red.opacity(0.5))
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
            // 重构: 使用 reasoningContent
            if let reasoning = message.reasoningContent, !reasoning.isEmpty {
                reasoningView(reasoning)
                
                if !message.content.isEmpty {
                   Divider().background(Color.gray)
                }
            }
            
            // 消息内容区域
            if !message.content.isEmpty {
                renderContent(message.content)
            }
            
            // 重构: 使用新的加载逻辑
            // 如果是助手角色且正文和思考过程均为空，则显示加载指示器
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
                // 重构: 直接操作传入的绑定，而不是修改模型
                withAnimation {
                    isExpanded.toggle()
                }
            }) {
                HStack {
                    Text("思考过程")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    Spacer()
                    // 重构: 依赖传入的 isExpanded 状态
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption)
                }
                .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)

            // 重构: 依赖传入的 isExpanded 状态
            if isExpanded {
                Text(reasoning)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.bottom, isExpanded ? 5 : 0)
    }
}