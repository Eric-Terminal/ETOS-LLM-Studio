import ETOSCore
import SwiftUI

struct MacGuideTranscript: View {
    @ObservedObject private var controller: GuideConversationController
    @ObservedObject private var stream: GuideStreamingState
    @StateObject private var presentation: GuideMessagePresentation
    @State private var followsBottom = true
    @State private var nearBottom = true

    init(controller: GuideConversationController) {
        self.controller = controller
        stream = controller.streamingState
        _presentation = StateObject(wrappedValue: GuideMessagePresentation(controller: controller))
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading) {
                    if controller.isRestoringHistory {
                        ProgressView().controlSize(.small)
                    } else if controller.messages.isEmpty {
                        Text(NSLocalizedString("使用助手", value: "App Guide", comment: "助手空状态标题")).font(.headline)
                        Text(NSLocalizedString("可以问我怎么配置模型，或让我带你找到需要的设置。", value: "Ask how to set up a model or find a setting.", comment: "助手空状态说明"))
                            .font(.footnote).foregroundStyle(.secondary)
                        GuideSuggestedQuestions(controller: controller)
                    }
                    ForEach(controller.messages) { message in
                        let streaming = stream.messageID == message.id
                        let text = streaming ? stream.content : message.content
                        let tools = presentation.tools[message.id] ?? GuideMessageTools()
                        let active = controller.isResponding && controller.messages.last?.id == message.id
                        let awaiting = controller.pendingProposal?.toolCallID
                        let isLatestError = message.role == .error && controller.lastErrorMessageID == message.id
                        if isLatestError || !text.isEmpty || tools.isVisible(active: active, awaiting: awaiting) {
                            MacGuideBubble(message: message, content: text, streaming: streaming,
                                           tools: tools, active: active, awaiting: awaiting,
                                           isLatestError: isLatestError,
                                           canRetryWithBuiltIn: isLatestError && controller.canRetryWithBuiltIn,
                                           retry: controller.retryLastResponse, retryWithBuiltIn: controller.retryWithBuiltIn)
                                .equatable()
                        }
                    }
                    if presentation.isWaitingForReply(controller) {
                        ProgressView().controlSize(.small)
                    }
                    Color.clear.frame(height: 1).id("guide-bottom")
                }
                .padding()
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.visibleRect.maxY >= geometry.contentSize.height - 1
            } action: { _, value in nearBottom = value }
            .onScrollPhaseChange { _, phase in
                if phase == .interacting { followsBottom = false }
                if phase == .idle { followsBottom = nearBottom }
            }
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height } action: { _, _ in
                if followsBottom { proxy.scrollTo("guide-bottom", anchor: .bottom) }
            }
            .onChange(of: controller.messages.last?.id) { _, _ in
                if controller.messages.last?.role == .user { followsBottom = true }
                if followsBottom { proxy.scrollTo("guide-bottom", anchor: .bottom) }
            }
            .onAppear { proxy.scrollTo("guide-bottom", anchor: .bottom) }
        }
    }
}

private struct MacGuideBubble: View, Equatable {
    let message: GuideConversationMessage
    let content: String
    let streaming: Bool
    let tools: GuideMessageTools
    let active: Bool
    let awaiting: String?
    let isLatestError: Bool
    let canRetryWithBuiltIn: Bool
    let retry: () -> Void
    let retryWithBuiltIn: () -> Void
    @State private var prepared: MacPreparedMessageText?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.message.id == rhs.message.id && lhs.content == rhs.content && lhs.streaming == rhs.streaming &&
        lhs.tools == rhs.tools && lhs.active == rhs.active && lhs.awaiting == rhs.awaiting &&
        lhs.isLatestError == rhs.isLatestError && lhs.canRetryWithBuiltIn == rhs.canRetryWithBuiltIn
    }

    private var bubbleBackground: AnyShapeStyle {
        switch message.role {
        case .user: AnyShapeStyle(Color.accentColor.opacity(0.14))
        case .tool: AnyShapeStyle(Color.green.opacity(0.12))
        case .error: AnyShapeStyle(Color.red.opacity(0.12))
        case .assistant: AnyShapeStyle(.regularMaterial)
        @unknown default: AnyShapeStyle(.regularMaterial)
        }
    }

    var body: some View {
        let outgoing = message.role == .user
        VStack(alignment: .leading) {
            if message.role == .tool {
                Label(NSLocalizedString("页面操作", value: "Page Actions", comment: "向导工具消息标签"), systemImage: "checkmark.circle")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if !content.isEmpty {
                if !streaming, let prepared, prepared.source == content {
                    MacMessageTextView(text: prepared)
                } else {
                    Text(verbatim: content).textSelection(.enabled)
                        .foregroundStyle(message.role == .error ? Color.red : .primary)
                }
            }
            GuideToolStatusLine(tools, active: active, awaiting: awaiting)
            GuideDestinationButtons(tools.destinations)
            if isLatestError {
                Button(NSLocalizedString("重试", value: "Retry", comment: "重试助手回答"), action: retry)
                if canRetryWithBuiltIn {
                    Button(NSLocalizedString("使用内置向导重试", value: "Retry with Built-in Guide", comment: "切换助手重试"), action: retryWithBuiltIn)
                }
            }
        }
        .padding()
        .background(bubbleBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(outgoing ? .leading : .trailing)
        .frame(maxWidth: .infinity, alignment: outgoing ? .trailing : .leading)
        // 流式片段立即显示，正文定稿后只在后台解析一次 Markdown。
        .task(id: streaming || message.role != .assistant ? nil : message.content) {
            guard !streaming, message.role == .assistant, !message.content.isEmpty else { return }
            let source = message.content
            let rendered = await Task.detached { MacPreparedMessageText(source, markdown: true) }.value
            if !Task.isCancelled { prepared = rendered }
        }
    }
}
