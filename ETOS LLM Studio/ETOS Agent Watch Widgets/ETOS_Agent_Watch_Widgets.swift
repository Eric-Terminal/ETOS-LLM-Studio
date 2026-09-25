// ============================================================================
// ETOS_Agent_Watch_Widgets.swift
// ETOS Agent Watch Widgets
// ============================================================================

import AppIntents
import ETOSCore
import SwiftUI
import WidgetKit

private struct ETOSWatchWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: ETOSWidgetSnapshot
}

private struct ETOSWatchWidgetProvider: TimelineProvider {
    var suggestsRecentTask = false

    @available(watchOS 11.0, *)
    func relevance() async -> WidgetRelevance<Void> {
        guard suggestsRecentTask,
              let interval = loadSnapshot().recentRuns.first?.smartStackRelevanceInterval() else {
            return WidgetRelevance([])
        }
        if #available(watchOS 26.0, *) {
            return WidgetRelevance([WidgetRelevanceAttribute(context: .date(interval: interval, kind: .default))])
        }
        return WidgetRelevance([WidgetRelevanceAttribute(context: .date(from: interval.start, to: interval.end))])
    }

    func placeholder(in context: Context) -> ETOSWatchWidgetEntry {
        ETOSWatchWidgetEntry(
            date: Date(),
            snapshot: ETOSWidgetSnapshot(recentRuns: [
                ETOSRunSnapshot(
                    id: UUID(),
                    sessionID: UUID(),
                    title: NSLocalizedString("整理本周资料", comment: "Watch widget placeholder task"),
                    status: .running,
                    startedAt: Date()
                )
            ])
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (ETOSWatchWidgetEntry) -> Void) {
        completion(ETOSWatchWidgetEntry(date: Date(), snapshot: loadSnapshot()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ETOSWatchWidgetEntry>) -> Void) {
        completion(
            Timeline(
                entries: [ETOSWatchWidgetEntry(date: Date(), snapshot: loadSnapshot())],
                policy: .after(Date().addingTimeInterval(30 * 60))
            )
        )
    }

    private func loadSnapshot() -> ETOSWidgetSnapshot {
        guard let layout = ETOSSharedStorageLayout.resolve() else {
            return ETOSWidgetSnapshot(recentRuns: [])
        }
        return (try? ETOSSharedFileStore.read(
            ETOSWidgetSnapshot.self,
            from: layout.runSnapshots.appendingPathComponent("widget.json")
        )) ?? ETOSWidgetSnapshot(recentRuns: [])
    }
}

private struct ETOSWatchNewAgentView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryInline:
            Label(NSLocalizedString("新建 Agent 任务", comment: "Watch widget new Agent"), systemImage: "sparkles")
        case .accessoryRectangular:
            HStack {
                Image(systemName: "sparkles")
                    .font(.title2)
                    .foregroundStyle(.tint)
                Text(NSLocalizedString("新建 Agent 任务", comment: "Watch widget new Agent"))
                    .font(.headline)
                    .lineLimit(2)
            }
        default:
            Image(systemName: "sparkles")
                .font(.title2)
                .foregroundStyle(.tint)
        }
    }
}

private struct ETOSWatchRecentTaskView: View {
    let entry: ETOSWatchWidgetEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let run = entry.snapshot.recentRuns.first
        switch family {
        case .accessoryInline:
            Label(
                run?.title ?? NSLocalizedString("暂无最近任务", comment: "Empty watch recent task"),
                systemImage: run.map { icon(for: $0.status) } ?? "clock"
            )
        case .accessoryRectangular:
            VStack(alignment: .leading) {
                Label(
                    run.map { statusTitle($0.status) } ?? NSLocalizedString("最近任务", comment: "Watch recent tasks title"),
                    systemImage: run.map { icon(for: $0.status) } ?? "clock.arrow.circlepath"
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(run?.title ?? NSLocalizedString("暂无最近任务", comment: "Empty watch recent task"))
                    .font(.headline)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        default:
            Image(systemName: run.map { icon(for: $0.status) } ?? "clock")
                .font(.title2)
                .foregroundStyle(run.map { color(for: $0.status) } ?? .secondary)
        }
    }

    private func icon(for status: ETOSTaskSnapshotStatus) -> String {
        switch status {
        case .queued: return "clock"
        case .running: return "sparkles"
        case .waitingForApproval, .waitingForInput: return "person.crop.circle.badge.questionmark"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .cancelled: return "xmark.circle"
        }
    }

    private func statusTitle(_ status: ETOSTaskSnapshotStatus) -> String {
        switch status {
        case .queued: return NSLocalizedString("排队中", comment: "任务等待运行")
        case .running: return NSLocalizedString("运行中", comment: "任务正在生成回复")
        case .waitingForApproval: return NSLocalizedString("等待批准", comment: "任务等待批准")
        case .waitingForInput: return NSLocalizedString("等待输入", comment: "任务等待用户输入")
        case .completed: return NSLocalizedString("已完成", comment: "任务已完成")
        case .failed: return NSLocalizedString("失败", comment: "任务运行失败")
        case .cancelled: return NSLocalizedString("已取消", comment: "任务已取消")
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

private struct ETOSWatchDailyPulseView: View {
    let entry: ETOSWatchWidgetEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryInline:
            Label(NSLocalizedString("Daily Pulse", comment: "Watch Daily Pulse title"), systemImage: "sun.max.fill")
        case .accessoryRectangular:
            VStack(alignment: .leading) {
                Label(NSLocalizedString("Daily Pulse", comment: "Watch Daily Pulse title"), systemImage: "sun.max.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Text(entry.snapshot.dailyPulseTitle ?? NSLocalizedString("Daily Pulse", comment: "Watch Daily Pulse fallback"))
                    .font(.headline)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        default:
            Image(systemName: "sun.max.fill")
                .font(.title2)
                .foregroundStyle(.orange)
        }
    }
}

struct ETOSWatchNewAgentWidget: Widget {
    let kind = "ETOSWatchNewAgentWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ETOSWatchWidgetProvider()) { _ in
            ETOSWatchNewAgentView()
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(URL(string: "etosllmstudio://open/new-agent"))
        }
        .configurationDisplayName(NSLocalizedString("新建 Agent 任务", comment: "Watch new Agent widget name"))
        .description(NSLocalizedString("快速打开 ETOS Agent 任务入口。", comment: "Watch new Agent widget description"))
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct ETOSWatchRecentTaskWidget: Widget {
    let kind = "ETOSWatchRecentTaskWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ETOSWatchWidgetProvider(suggestsRecentTask: true)) { entry in
            ETOSWatchRecentTaskView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(entry.snapshot.recentRuns.first.map { ETOSSystemEntryURL.openSession($0.sessionID) })
        }
        .configurationDisplayName(NSLocalizedString("最近任务", comment: "Watch recent task widget name"))
        .description(NSLocalizedString("查看最近对话和 Agent 任务。", comment: "最近任务小组件说明"))
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct ETOSWatchDailyPulseWidget: Widget {
    let kind = "ETOSWatchDailyPulseWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ETOSWatchWidgetProvider()) { entry in
            ETOSWatchDailyPulseView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(URL(string: "etosllmstudio://open/daily-pulse"))
        }
        .configurationDisplayName(NSLocalizedString("Daily Pulse", comment: "Watch Daily Pulse widget name"))
        .description(NSLocalizedString("查看每日脉冲摘要。", comment: "Watch Daily Pulse widget description"))
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}
