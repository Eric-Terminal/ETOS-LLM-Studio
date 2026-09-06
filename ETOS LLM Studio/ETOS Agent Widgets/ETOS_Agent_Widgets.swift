// ============================================================================
// ETOS_Agent_Widgets.swift
// ETOS Agent Widgets
// ============================================================================

import ETOSCore
import SwiftUI
import WidgetKit

private struct ETOSWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: ETOSWidgetSnapshot
}

private struct ETOSWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> ETOSWidgetEntry {
        ETOSWidgetEntry(date: Date(), snapshot: placeholderSnapshot)
    }

    func getSnapshot(in context: Context, completion: @escaping (ETOSWidgetEntry) -> Void) {
        completion(ETOSWidgetEntry(date: Date(), snapshot: loadSnapshot() ?? placeholderSnapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ETOSWidgetEntry>) -> Void) {
        let entry = ETOSWidgetEntry(date: Date(), snapshot: loadSnapshot() ?? emptySnapshot)
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(30 * 60))))
    }

    private func loadSnapshot() -> ETOSWidgetSnapshot? {
        guard let layout = ETOSSharedStorageLayout.resolve() else { return nil }
        return try? ETOSSharedFileStore.read(
            ETOSWidgetSnapshot.self,
            from: layout.runSnapshots.appendingPathComponent("widget.json")
        )
    }

    private var emptySnapshot: ETOSWidgetSnapshot {
        ETOSWidgetSnapshot(recentRuns: [])
    }

    private var placeholderSnapshot: ETOSWidgetSnapshot {
        ETOSWidgetSnapshot(recentRuns: [
            ETOSRunSnapshot(
                id: UUID(),
                sessionID: UUID(),
                title: NSLocalizedString("整理本周资料", comment: "Widget placeholder task"),
                status: .running,
                currentToolDisplayName: NSLocalizedString("浏览器", comment: "Widget placeholder tool"),
                startedAt: Date()
            )
        ])
    }
}

private struct NewAgentWidgetView: View {
    let entry: ETOSWidgetEntry

    var body: some View {
        Link(destination: URL(string: "etosllmstudio://open/new-agent")!) {
            VStack(alignment: .leading) {
                Image(systemName: "sparkles")
                    .font(.title2)
                    .foregroundStyle(.tint)
                Spacer()
                Text(NSLocalizedString("新建 Agent 任务", comment: "New Agent widget title"))
                    .font(.headline)
                Text(NSLocalizedString("打开 ETOS 输入任务", comment: "New Agent widget subtitle"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct RecentTasksWidgetView: View {
    let entry: ETOSWidgetEntry

    var body: some View {
        VStack(alignment: .leading) {
            Label(NSLocalizedString("最近任务", comment: "Recent tasks widget title"), systemImage: "clock.arrow.circlepath")
                .font(.headline)
            if entry.snapshot.recentRuns.isEmpty {
                Spacer()
                Text(NSLocalizedString("还没有 Agent 任务", comment: "Empty recent tasks widget"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ForEach(entry.snapshot.recentRuns.prefix(3)) { run in
                    Link(destination: ETOSSystemEntryURL.openSession(run.sessionID)) {
                        HStack {
                            Image(systemName: icon(for: run.status))
                                .foregroundStyle(color(for: run.status))
                            Text(run.title)
                                .lineLimit(1)
                            Spacer()
                        }
                        .font(.caption)
                    }
                }
                Spacer(minLength: 0)
                Text(entry.snapshot.updatedAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func icon(for status: ETOSTaskSnapshotStatus) -> String {
        switch status {
        case .queued: return "clock"
        case .running: return "progress.indicator"
        case .waitingForApproval, .waitingForInput: return "person.crop.circle.badge.questionmark"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .cancelled: return "xmark.circle"
        }
    }

    private func color(for status: ETOSTaskSnapshotStatus) -> Color {
        switch status {
        case .completed: return .green
        case .failed: return .red
        case .waitingForApproval, .waitingForInput: return .orange
        case .queued, .running, .cancelled: return .secondary
        }
    }
}

private struct DailyPulseWidgetView: View {
    let entry: ETOSWidgetEntry

    var body: some View {
        Link(destination: URL(string: "etosllmstudio://open/daily-pulse")!) {
            VStack(alignment: .leading) {
                Label(NSLocalizedString("Daily Pulse", comment: "Daily Pulse brand name"), systemImage: "sun.max.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Spacer()
                Text(entry.snapshot.dailyPulseTitle
                    ?? NSLocalizedString("打开今日脉搏", comment: "Daily Pulse widget fallback"))
                    .font(.subheadline)
                    .lineLimit(3)
                Spacer()
                Text(NSLocalizedString("在 ETOS 中查看", comment: "Open Daily Pulse widget action"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct ETOSNewAgentWidget: Widget {
    let kind = "ETOSNewAgentWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ETOSWidgetProvider()) { entry in
            NewAgentWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName(NSLocalizedString("新建 Agent 任务", comment: "New Agent widget name"))
        .description(NSLocalizedString("快速打开 ETOS 的 Agent 任务入口。", comment: "New Agent widget description"))
        .supportedFamilies([.systemSmall])
    }
}

struct ETOSRecentTasksWidget: Widget {
    let kind = "ETOSRecentTasksWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ETOSWidgetProvider()) { entry in
            RecentTasksWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName(NSLocalizedString("最近 Agent 任务", comment: "Recent tasks widget name"))
        .description(NSLocalizedString("查看最近任务状态并回到对应会话。", comment: "Recent tasks widget description"))
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct ETOSDailyPulseWidget: Widget {
    let kind = "ETOSDailyPulseWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ETOSWidgetProvider()) { entry in
            DailyPulseWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName(NSLocalizedString("Daily Pulse", comment: "Daily Pulse widget name"))
        .description(NSLocalizedString("查看今天的 Daily Pulse 摘要。", comment: "Daily Pulse widget description"))
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
