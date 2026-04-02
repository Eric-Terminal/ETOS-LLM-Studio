// ============================================================================
// DailyPulseFeedbackHistoryView.swift
// ============================================================================
// iOS 每日脉冲反馈历史视图
//
// 功能特性:
// - 展示完整的 Daily Pulse 反馈历史
// - 支持逐条删除与清空历史
// - 让用户更细粒度地管理对后续 Pulse 的长期偏好信号
// ============================================================================

import SwiftUI
import Shared

struct DailyPulseFeedbackHistoryView: View {
    @ObservedObject private var pulseManager = DailyPulseManager.shared

    var body: some View {
        List {
            if pulseManager.feedbackHistory.isEmpty {
                ContentUnavailableView(
                    "还没有反馈历史",
                    systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90",
                    description: Text("你对每日脉冲点过喜欢、降权、隐藏或保存之后，历史会显示在这里。")
                )
            } else {
                ForEach(pulseManager.feedbackHistory) { event in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(historyTitle(for: event))
                            .etFont(.subheadline.weight(.medium))
                        Text(event.cardTitle)
                            .etFont(.footnote)
                        if !event.topicHint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text(event.topicHint)
                                .etFont(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            pulseManager.removeFeedbackHistoryEvent(id: event.id)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .navigationTitle("反馈历史")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !pulseManager.feedbackHistory.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("清空", role: .destructive) {
                        pulseManager.clearFeedbackHistory()
                    }
                }
            }
        }
    }

    private func historyTitle(for event: DailyPulseFeedbackEvent) -> String {
        switch event.action {
        case .liked:
            return "已喜欢 · \(event.dayKey)"
        case .disliked:
            return "已降权 · \(event.dayKey)"
        case .hidden:
            return "已隐藏 · \(event.dayKey)"
        case .saved:
            return "已保存为会话 · \(event.dayKey)"
        }
    }
}
