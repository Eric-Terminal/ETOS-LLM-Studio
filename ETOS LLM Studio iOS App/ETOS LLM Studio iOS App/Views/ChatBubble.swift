// ============================================================================
// ChatBubble.swift
// ============================================================================
// 聊天气泡 (iOS 样式)
// - 根据消息角色切换配色
// - 支持 Markdown 与推理展开
// - 为工具调用提供可折叠区域
// ============================================================================

import SwiftUI
import MarkdownUI
import Shared

struct ChatBubble: View {
    let message: ChatMessage
    @Binding var isReasoningExpanded: Bool
    @Binding var isToolCallsExpanded: Bool
    let enableMarkdown: Bool
    let enableBackground: Bool
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if message.role == .assistant || message.role == .system || message.role == .tool {
                roleBadge
            } else {
                Spacer(minLength: 32)
            }
            
            VStack(alignment: .leading, spacing: 8) {
                contentStack
            }
            .padding(14)
            .background(bubbleBackground)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
            
            if message.role == .user {
                roleBadge
            } else {
                Spacer(minLength: 32)
            }
        }
    }
    
    // MARK: - Content
    
    @ViewBuilder
    private var contentStack: some View {
        if let reasoning = message.reasoningContent,
           !reasoning.isEmpty {
            DisclosureGroup(isExpanded: $isReasoningExpanded) {
                Text(reasoning)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } label: {
                Label("思考过程", systemImage: "brain.head.profile")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        
        if let toolCalls = message.toolCalls,
           !toolCalls.isEmpty {
            DisclosureGroup(isExpanded: $isToolCallsExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(toolCalls, id: \.id) { call in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(call.toolName)
                                .font(.footnote.weight(.semibold))
                            if let result = call.result, !result.isEmpty {
                                Text(result)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(8)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            } label: {
                Label("使用工具", systemImage: "wrench.and.screwdriver")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        
        if !message.content.isEmpty {
            renderContent(message.content)
                .font(.body)
                .foregroundStyle(message.role == .user ? Color.white : Color.primary)
                .textSelection(.enabled)
        } else if message.role == .assistant {
            HStack(spacing: 6) {
                ProgressView()
                Text("正在思考…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
    
    @ViewBuilder
    private func renderContent(_ content: String) -> some View {
        if enableMarkdown {
            Markdown(content)
                .padding(.top, message.reasoningContent == nil ? 0 : 4)
        } else {
            Text(content)
        }
    }
    
    // MARK: - Badge & Background
    
    private var bubbleBackground: some ShapeStyle {
        switch message.role {
        case .user:
            return enableBackground ? AnyShapeStyle(Color.accentColor.gradient) : AnyShapeStyle(Color.accentColor)
        case .error:
            return AnyShapeStyle(Color.red.opacity(0.15))
        case .assistant, .system, .tool:
            return enableBackground ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(Color(UIColor.secondarySystemBackground))
        @unknown default:
            return enableBackground ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(Color(UIColor.secondarySystemBackground))
        }
    }
    
    private var roleBadge: some View {
        let symbol: String
        let color: Color
        
        switch message.role {
        case .user:
            symbol = "person.fill"
            color = .accentColor
        case .assistant:
            symbol = "sparkles"
            color = .purple
        case .system:
            symbol = "gear"
            color = .indigo
        case .tool:
            symbol = "wrench.adjustable"
            color = .orange
        case .error:
            symbol = "exclamationmark.triangle.fill"
            color = .red
        @unknown default:
            symbol = "questionmark.circle"
            color = .gray
        }
        
        return Image(systemName: symbol)
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(color)
            .padding(8)
            .background(color.opacity(message.role == .user ? 0.15 : 0.08), in: Circle())
    }
}
