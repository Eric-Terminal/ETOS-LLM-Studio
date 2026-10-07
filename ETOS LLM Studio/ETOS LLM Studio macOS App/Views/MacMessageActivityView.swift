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
    let reasoning: String
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        if activity.suppressesReasoningContent {
            header
        } else {
            DisclosureGroup { Text(reasoning).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) } label: { header }
        }
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
