// ============================================================================
// DailyPulseFeedbackHistoryView.swift
// ============================================================================
// watchOS 每日脉冲反馈历史视图
//
// 功能特性:
// - 展示完整的 Daily Pulse 反馈历史
// - 支持逐条删除与清空历史
// - 保持与 iOS 端一致的反馈管理能力
// ============================================================================

import SwiftUI
import Shared

struct DailyPulseFeedbackHistoryView: View {
    @ObservedObject private var pulseManager = DailyPulseManager.shared

    var body: some View {
        List {
            if pulseManager.feedbackHistory.isEmpty {
                Text("还没有反馈历史。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(pulseManager.feedbackHistory) { event in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(historyTitle(for: event))
                            .font(.caption.weight(.semibold))
                        Text(event.cardTitle)
                            .font(.caption2)
                        if !event.topicHint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text(event.topicHint)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Button(role: .destructive) {
                            pulseManager.removeFeedbackHistoryEvent(id: event.id)
                        } label: {
                            Label("删除这条", systemImage: "trash")
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.vertical, 4)
                }

                Button(role: .destructive) {
                    pulseManager.clearFeedbackHistory()
                } label: {
                    Label("清空历史", systemImage: "trash")
                }
            }
        }
        .navigationTitle("反馈历史")
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
            return "已保存 · \(event.dayKey)"
        }
    }
}
