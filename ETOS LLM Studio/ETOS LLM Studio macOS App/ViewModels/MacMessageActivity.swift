import ETOSCore
import Foundation

/// 请求状态和标题随消息在后台准备，正文视图不查询服务、数据库或解析思考内容。
struct MacMessageActivity: Equatable, Sendable {
    let isCurrentResponse: Bool
    let isActive: Bool
    let pendingText: String?
    let retryText: String?
    let hasReasoning: Bool
    let canPreviewReasoning: Bool
    let reasoningHeader: String
    let reasoningLiveSince: Date?
    let animatesReasoning: Bool
    let suppressesReasoningContent: Bool
    let usesRainbow: Bool

    init(message: ChatMessage, activeResponseID: UUID?) {
        isCurrentResponse = message.id == activeResponseID
        isActive = isCurrentResponse && message.role == .assistant && message.responseMetrics?.responseCompletedAt == nil
        let streaming = isActive && message.isReceivingStream
        hasReasoning = !(message.reasoningContent ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasContent = !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !(message.imageFileNames ?? []).isEmpty || !(message.fileFileNames ?? []).isEmpty || message.audioFileName != nil
        canPreviewReasoning = isActive && hasReasoning && !hasContent
        let waitingForFirstContent = isActive && !hasContent && !hasReasoning && (message.toolCalls ?? []).isEmpty
        pendingText = waitingForFirstContent ? (message.requestRetryStatus?.thinkingText ?? NSLocalizedString("正在思考...", comment: "")) : nil
        retryText = isActive && !waitingForFirstContent ? message.requestRetryStatus?.thinkingText : nil
        let metrics = message.responseMetrics
        let completed = metrics?.reasoningCompletedAt ?? metrics?.responseCompletedAt
        animatesReasoning = streaming && hasReasoning && completed == nil
        reasoningLiveSince = animatesReasoning ? (metrics?.reasoningStartedAt ?? metrics?.requestStartedAt ?? message.requestedAt) : nil
        suppressesReasoningContent = ChatReasoningRenderPolicy.shouldSuppressReasoningContentRender(message: message, isStreaming: streaming)
        usesRainbow = message.usesRainbowThinkingSweep

        let summary = metrics?.reasoningSummary?.trimmingCharacters(in: .whitespacesAndNewlines)
        let duration = metrics?.reasoningDuration.map { $0 > 0 ? max(1, Int($0.rounded(.down))) : 0 }
        let title = duration.map { String(format: NSLocalizedString("已经思考%d秒", comment: ""), $0) } ?? NSLocalizedString("思考过程", comment: "")
        if let summary, !summary.isEmpty {
            reasoningHeader = duration.map { String(format: NSLocalizedString("%ds: %@", comment: ""), $0, summary) }
                ?? String(format: NSLocalizedString("%@：%@", comment: ""), title, summary)
        } else { reasoningHeader = title }
    }
}
