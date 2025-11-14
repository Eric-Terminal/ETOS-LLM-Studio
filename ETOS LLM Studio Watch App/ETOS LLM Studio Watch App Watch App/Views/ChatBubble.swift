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
import Combine
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
    
    @AppStorage("enableStreaming") private var enableStreaming = false
    @State private var currentQuoteIndex = Int.random(in: 0..<max(InspirationService.shared.localQuotes.count, 1))
    @State private var remoteQuotes: [String] = []
    @State private var isFetchingRemoteQuote = false
    private let quoteTimer = Timer.publish(every: 4, tolerance: 0.5, on: .main, in: .common).autoconnect()

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
        .onReceive(quoteTimer) { _ in
            guard shouldShowPlayfulThinking else { return }
            let quotes = availableThinkingQuotes
            guard !quotes.isEmpty else { return }
            currentQuoteIndex = (currentQuoteIndex + 1) % quotes.count
        }
        .onAppear {
            requestRemoteQuoteIfNeeded()
        }
        .onPlayfulThinkingChange(shouldShowPlayfulThinking) { isWaiting in
            if isWaiting {
                requestRemoteQuoteIfNeeded()
            }
        }
    }
    
    // MARK: - 气泡视图
    
    @ViewBuilder
    private var userBubble: some View {
        let content = renderContent(message.content)
            .padding(10)
            .foregroundColor(.white)

        if enableLiquidGlass {
            if #available(watchOS 26.0, *) {
                content
                    .glassEffect(.clear, in: RoundedRectangle(cornerRadius: 12))
                    .background(Color.blue.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                userBubbleFallback(content)
            }
        } else {
            userBubbleFallback(content)
        }
    }
    
    @ViewBuilder
    private var errorBubble: some View {
        let content = Text(message.content)
            .padding(10)
            .foregroundColor(.white)

        if enableLiquidGlass {
            if #available(watchOS 26.0, *) {
                content
                    .glassEffect(.clear, in: RoundedRectangle(cornerRadius: 12))
                    .background(Color.red.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                errorBubbleFallback(content)
            }
        } else {
            errorBubbleFallback(content)
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
            if shouldShowThinkingIndicator {
                HStack(spacing: shouldShowPlayfulThinking ? 0 : 4) {
                    if shouldShowPlayfulThinking {
                        Text(currentThinkingText)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .animation(.easeInOut(duration: 0.25), value: currentThinkingText)
                    } else {
                        ProgressView().controlSize(.small)
                        Text(currentThinkingText)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding(10)

        if enableLiquidGlass {
            if #available(watchOS 26.0, *) {
                content.glassEffect(.clear, in: RoundedRectangle(cornerRadius: 12))
            } else {
                assistantBubbleFallback(content)
            }
        } else {
            assistantBubbleFallback(content)
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
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Image(systemName: "wrench.and.screwdriver.fill")
                            Text(toolCall.toolName)
                        }
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        if let result = toolCall.result, !result.isEmpty {
                            Text(result)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.leading, 4)
                }
            }
        }
        .padding(.bottom, isToolCallsExpanded ? 5 : 0)
    }
    
    // MARK: - 回退样式
    
    @ViewBuilder
    private func userBubbleFallback<Content: View>(_ content: Content) -> some View {
        content
            .background(enableBackground ? Color.blue.opacity(0.7) : Color.blue)
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }
    
    @ViewBuilder
    private func errorBubbleFallback<Content: View>(_ content: Content) -> some View {
        content
            .background(enableBackground ? Color.red.opacity(0.7) : Color.red)
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }
    
    @ViewBuilder
    private func assistantBubbleFallback<Content: View>(_ content: Content) -> some View {
        content
            .background(enableBackground ? Color.black.opacity(0.3) : Color(white: 0.3))
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - 思考提示相关

private extension ChatBubble {
    
    var shouldShowThinkingIndicator: Bool {
        message.role == .assistant && message.content.isEmpty && (message.reasoningContent ?? "").isEmpty
    }
    
    var shouldShowPlayfulThinking: Bool {
        shouldShowThinkingIndicator && !enableStreaming
    }
    
    var currentThinkingText: String {
        guard shouldShowThinkingIndicator else { return "" }
        guard shouldShowPlayfulThinking else {
            return "正在思考..."
        }
        let quotes = availableThinkingQuotes
        guard !quotes.isEmpty else { return "正在思考..." }
        let safeIndex = currentQuoteIndex % quotes.count
        return quotes[safeIndex]
    }
    
    var availableThinkingQuotes: [String] {
        let sanitizedRemote = remoteQuotes
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let base = InspirationService.shared.localQuotes
        return sanitizedRemote + base
    }
    
    @MainActor
    func requestRemoteQuoteIfNeeded() {
        guard shouldShowPlayfulThinking else { return }
        guard !isFetchingRemoteQuote else { return }
        isFetchingRemoteQuote = true
        Task {
            let quote = await InspirationService.shared.fetchRandomQuote()
            await MainActor.run {
                isFetchingRemoteQuote = false
                guard let quote else { return }
                let text = quote.displayText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                if !remoteQuotes.contains(text) {
                    remoteQuotes.insert(text, at: 0)
                    if remoteQuotes.count > 5 {
                        remoteQuotes = Array(remoteQuotes.prefix(5))
                    }
                    currentQuoteIndex = 0
                }
            }
        }
    }
}

// MARK: - 辅助 View 扩展

private extension View {
    @ViewBuilder
    func onPlayfulThinkingChange(_ value: Bool, action: @escaping (Bool) -> Void) -> some View {
        if #available(watchOS 10.0, *) {
            self.onChange(of: value, initial: false) { _, newValue in
                action(newValue)
            }
        } else {
            self.onChange(of: value) { newValue in
                action(newValue)
            }
        }
    }
}
