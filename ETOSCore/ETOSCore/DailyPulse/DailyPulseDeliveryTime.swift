// ============================================================================
// DailyPulseDeliveryTime.swift
// ============================================================================
// ETOS LLM Studio
//
// 描述每日脉冲单个卡片的本地送达时间。
// ============================================================================

import Foundation

public struct DailyPulseDeliveryTime: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var hour: Int
    public var minute: Int

    public init(id: UUID = UUID(), hour: Int, minute: Int) {
        self.id = id
        self.hour = min(max(hour, 0), 23)
        self.minute = min(max(minute, 0), 59)
    }

    public var totalMinutes: Int {
        hour * 60 + minute
    }

    public var timeText: String {
        String(format: "%02d:%02d", hour, minute)
    }
}
