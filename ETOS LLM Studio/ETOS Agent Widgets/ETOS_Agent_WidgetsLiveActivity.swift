// ============================================================================
// ETOS_Agent_WidgetsLiveActivity.swift
// ETOS Agent Widgets
// ============================================================================

import ActivityKit
import ETOSCore
import SwiftUI
import WidgetKit

struct ETOS_Agent_WidgetsLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ETOSAgentActivityAttributes.self) { context in
            HStack {
                Image(systemName: statusIcon(context.state.status))
                    .foregroundStyle(statusColor(context.state.status))
                VStack(alignment: .leading) {
                    Text(context.attributes.title)
                        .font(.headline)
                        .lineLimit(1)
                    Text(detail(context.state))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if context.state.requiresApp {
                    Image(systemName: "iphone")
                        .foregroundStyle(.orange)
                }
            }
            .padding()
            .activityBackgroundTint(.clear)
            .widgetURL(ETOSSystemEntryURL.openSession(context.attributes.sessionID))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: statusIcon(context.state.status))
                        .foregroundStyle(statusColor(context.state.status))
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.title).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if context.state.requiresApp { Image(systemName: "iphone") }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(detail(context.state))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } compactLeading: {
                Image(systemName: statusIcon(context.state.status))
            } compactTrailing: {
                if context.state.requiresApp { Image(systemName: "iphone") }
            } minimal: {
                Image(systemName: statusIcon(context.state.status))
            }
            .widgetURL(ETOSSystemEntryURL.openSession(context.attributes.sessionID))
            .keylineTint(statusColor(context.state.status))
        }
    }

    private func detail(_ state: ETOSAgentActivityAttributes.ContentState) -> String {
        if state.requiresApp {
            return NSLocalizedString("需要在 App 中继续", comment: "Live Activity requires app")
        }
        if let tool = state.currentToolDisplayName { return tool }
        switch state.status {
        case .queued: return NSLocalizedString("等待运行", comment: "Live Activity queued")
        case .running: return NSLocalizedString("正在运行", comment: "Live Activity running")
        case .waitingForApproval: return NSLocalizedString("等待批准", comment: "Live Activity waiting approval")
        case .waitingForInput: return NSLocalizedString("等待输入", comment: "Live Activity waiting input")
        case .completed: return NSLocalizedString("已完成", comment: "Live Activity completed")
        case .failed: return NSLocalizedString("运行失败", comment: "Live Activity failed")
        case .cancelled: return NSLocalizedString("已取消", comment: "Live Activity cancelled")
        }
    }

    private func statusIcon(_ status: ETOSTaskSnapshotStatus) -> String {
        switch status {
        case .queued: return "clock"
        case .running: return "sparkles"
        case .waitingForApproval, .waitingForInput: return "person.crop.circle.badge.questionmark"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .cancelled: return "xmark.circle"
        }
    }

    private func statusColor(_ status: ETOSTaskSnapshotStatus) -> Color {
        switch status {
        case .completed: return .green
        case .failed: return .red
        case .waitingForApproval, .waitingForInput: return .orange
        case .queued, .running, .cancelled: return .secondary
        }
    }
}
