// ============================================================================
// AchievementJournalView.swift
// ============================================================================
// 隐藏成就日记（watchOS）
//
// 维护约束:
// - 只展示已解锁记录，不展示未触发成就。
// - 不要在入口外暴露彩蛋存在感，避免破坏惊喜。
// ============================================================================

import SwiftUI
import Shared

struct AchievementJournalView: View {
    @ObservedObject private var achievementCenter = AchievementCenter.shared

    var body: some View {
        List {
            if achievementCenter.journalEntries.isEmpty {
                Text("这里还没有留下记录。")
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(achievementCenter.journalEntries) { entry in
                    AchievementJournalRow(entry: entry)
                }
            }
        }
        .navigationTitle("成就日记")
        .onAppear {
            achievementCenter.refreshFromStorage()
        }
    }
}

private struct AchievementJournalRow: View {
    let entry: AchievementJournalEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: entry.systemImageName)
                    .etFont(.caption)
                    .foregroundStyle(.tint)
                Text(entry.localizedTitle)
                    .etFont(.headline)
                    .lineLimit(3)
            }

            Text(entry.localizedSentence)
                .etFont(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(4)

            Text(entry.localizedTriggerNote)
                .etFont(.caption2)
                .foregroundStyle(.tertiary)

            Text(entry.unlockedAt, format: .dateTime.year().month().day().hour().minute())
                .etFont(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}
