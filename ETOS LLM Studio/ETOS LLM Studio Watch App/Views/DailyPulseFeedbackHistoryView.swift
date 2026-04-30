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
                VStack(alignment: .leading, spacing: 6) {
                    Text(NSLocalizedString("还没有反馈历史", comment: ""))
                        .etFont(.footnote.weight(.semibold))
                    Text(NSLocalizedString("你对每日脉冲点过喜欢、降权、隐藏或保存之后，历史会显示在这里。", comment: ""))
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(pulseManager.feedbackHistory) { event in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(historyTitle(for: event))
                            .etFont(.caption.weight(.semibold))
                        Text(event.cardTitle)
                            .etFont(.caption2)
                        if !event.topicHint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text(event.topicHint)
                                .etFont(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            pulseManager.removeFeedbackHistoryEvent(id: event.id)
                        } label: {
                            Label(NSLocalizedString("删除", comment: ""), systemImage: "trash")
                        }
                    }
                }

                Button(role: .destructive) {
                    pulseManager.clearFeedbackHistory()
                } label: {
                    Label(NSLocalizedString("清空历史", comment: ""), systemImage: "trash")
                }
            }
        }
        .navigationTitle(NSLocalizedString("反馈历史", comment: ""))
    }

    private func historyTitle(for event: DailyPulseFeedbackEvent) -> String {
        switch event.action {
        case .liked:
            return String(format: NSLocalizedString("已喜欢 · %@", comment: ""), event.dayKey)
        case .disliked:
            return String(format: NSLocalizedString("已降权 · %@", comment: ""), event.dayKey)
        case .hidden:
            return String(format: NSLocalizedString("已隐藏 · %@", comment: ""), event.dayKey)
        case .saved:
            return String(format: NSLocalizedString("已保存为会话 · %@", comment: ""), event.dayKey)
        }
    }
}
