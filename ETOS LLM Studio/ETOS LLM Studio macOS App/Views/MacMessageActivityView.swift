import ETOSCore
import SwiftUI

struct MacMessageWaitingView: View {
    let activity: MacMessageActivity
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        if let pending = activity.pendingText {
            if activity.isActive, scenePhase == .active {
                ThinkingSweepForeground(baseColor: .secondary, highlightColor: .primary.opacity(0.85)) {
                    Text(pending).font(.callout).monospacedDigit()
                }
                .environment(\.thinkingSweepUsesRainbow, activity.usesRainbow)
            } else { Text(pending).font(.callout).monospacedDigit().foregroundStyle(.secondary) }
        }
        if let retry = activity.retryText { Text(retry).font(.caption).monospacedDigit().foregroundStyle(.secondary) }
    }
}

struct MacMessageReasoningView: View {
    let activity: MacMessageActivity
    let reasoning: MacPreparedMessageText
    let viewportHeight: CGFloat
    @ObservedObject private var configuration = AppConfigStore.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var isExpanded = false
    @State private var contentHeight: CGFloat = 0

    private var shouldPreview: Bool { configuration.enableAutoReasoningPreview && activity.canPreviewReasoning }
    private var previewHeight: CGFloat {
        let percent = configuration.reasoningPreviewHeightPercent
        let fraction = configuration.enableResponsiveReasoningPreviewHeight ? 0.3 : min(100, max(1, percent)) / 100
        let limit = max(1, viewportHeight * fraction)
        return configuration.enableResponsiveReasoningPreviewHeight ? min(max(1, contentHeight), limit) : limit
    }

    var body: some View {
        Group {
            if activity.suppressesReasoningContent && !shouldPreview {
                header
            } else {
                DisclosureGroup(isExpanded: $isExpanded) {
                    if shouldPreview {
                        // 流式阶段只展示已准备的纯文本，不提前恢复 Core 抑制的完整 Markdown 渲染。
                        ScrollView {
                            Text(reasoning.plain).frame(maxWidth: .infinity, alignment: .leading)
                                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                        }
                        .frame(height: previewHeight)
                        .textSelection(.enabled)
                    } else { MacMessageTextView(text: reasoning) }
                } label: { header }
                .font(.callout).foregroundStyle(.secondary)
            }
        }
        .onChange(of: shouldPreview, initial: true) { _, preview in isExpanded = preview }
    }

    @ViewBuilder
    private var header: some View {
        if activity.animatesReasoning, scenePhase == .active {
            ThinkingSweepForeground(baseColor: .secondary, highlightColor: .primary.opacity(0.85)) { title }
                .environment(\.thinkingSweepUsesRainbow, activity.usesRainbow)
        } else { title.foregroundStyle(.secondary) }
    }

    private var title: some View {
        HStack {
            Label(activity.reasoningHeader, systemImage: "brain.head.profile")
            if let started = activity.reasoningLiveSince, scenePhase == .active {
                // 使用系统时间文本更新，不另建轮询任务，也不在渲染链路格式化长标题。
                Text(started, style: .timer).monospacedDigit()
            }
        }.font(.callout)
    }
}
