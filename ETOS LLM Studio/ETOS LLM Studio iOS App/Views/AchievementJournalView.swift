// ============================================================================
// AchievementJournalView.swift
// ============================================================================
// 隐藏成就日记
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
                Section {
                    Text("这里还没有留下记录。")
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("已点亮") {
                    ForEach(achievementCenter.journalEntries) { entry in
                        AchievementJournalRow(entry: entry)
                    }
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
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: entry.systemImageName)
                .etFont(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 6) {
                Text(entry.localizedTitle)
                    .etFont(.headline)

                Text(entry.localizedSentence)
                    .etFont(.subheadline)
                    .foregroundStyle(.secondary)

                Text(entry.localizedTriggerNote)
                    .etFont(.caption)
                    .foregroundStyle(.tertiary)

                Text(entry.unlockedAt, format: .dateTime.year().month().day().hour().minute())
                    .etFont(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}
