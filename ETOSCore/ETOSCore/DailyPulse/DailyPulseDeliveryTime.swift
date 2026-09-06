// ============================================================================
// DailyPulseDeliveryTime.swift
// ============================================================================
// ETOS LLM Studio
//
// 描述一张每日脉冲卡片的本地送达时间。
// ============================================================================

import Foundation

public struct DailyPulseDeliveryTime: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var hour: Int
    public var minute: Int

    public init(
        id: UUID = UUID(),
        hour: Int,
        minute: Int
    ) {
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

    private enum CodingKeys: String, CodingKey {
        case id
        case hour
        case minute
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            hour: try container.decode(Int.self, forKey: .hour),
            minute: try container.decode(Int.self, forKey: .minute)
        )
    }
}
