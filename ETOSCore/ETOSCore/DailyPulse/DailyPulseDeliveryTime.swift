// ============================================================================
// DailyPulseDeliveryTime.swift
// ============================================================================
// ETOS LLM Studio
//
// 描述每日脉冲一个批次的本地送达时间与卡片数量。
// ============================================================================

import Foundation

public struct DailyPulseDeliveryTime: Identifiable, Codable, Hashable, Sendable {
    public static let defaultCardCount = 3
    public static let minimumCardCount = 1
    public static let maximumCardCount = 6

    public var id: UUID
    public var hour: Int
    public var minute: Int
    public var cardCount: Int

    public init(
        id: UUID = UUID(),
        hour: Int,
        minute: Int,
        cardCount: Int = DailyPulseDeliveryTime.defaultCardCount
    ) {
        self.id = id
        self.hour = min(max(hour, 0), 23)
        self.minute = min(max(minute, 0), 59)
        self.cardCount = Self.normalizedCardCount(cardCount)
    }

    public var totalMinutes: Int {
        hour * 60 + minute
    }

    public var timeText: String {
        String(format: "%02d:%02d", hour, minute)
    }

    public static func normalizedCardCount(_ count: Int) -> Int {
        min(max(count, minimumCardCount), maximumCardCount)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case hour
        case minute
        case cardCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            hour: try container.decode(Int.self, forKey: .hour),
            minute: try container.decode(Int.self, forKey: .minute),
            cardCount: try container.decodeIfPresent(Int.self, forKey: .cardCount) ?? Self.defaultCardCount
        )
    }
}
