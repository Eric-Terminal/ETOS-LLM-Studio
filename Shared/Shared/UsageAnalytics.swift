import Foundation

public enum UsageRequestSource: String, Codable, Hashable, CaseIterable, Sendable {
    case chat
    case dailyPulse
    case sessionTitle
    case reasoningSummary
    case conversationSummary
    case conversationProfile
    case shortcutDescription

    public var displayName: String {
        switch self {
        case .chat:
            return "聊天"
        case .dailyPulse:
            return "每日脉冲"
        case .sessionTitle:
            return "会话标题"
        case .reasoningSummary:
            return "思考摘要"
        case .conversationSummary:
            return "会话摘要"
        case .conversationProfile:
            return "用户画像"
        case .shortcutDescription:
            return "快捷指令描述"
        }
    }
}

public struct UsageAnalyticsEvent: Identifiable, Codable, Hashable, Sendable {
    public let eventID: UUID
    public var id: UUID { eventID }
    public var requestSource: UsageRequestSource
    public var sessionID: UUID?
    public var providerID: UUID?
    public var providerName: String
    public var modelID: String
    public var requestedAt: Date
    public var finishedAt: Date
    public var dayKey: String
    public var isStreaming: Bool
    public var status: RequestLogStatus
    public var httpStatusCode: Int?
    public var errorKind: String?
    public var tokenUsage: MessageTokenUsage?
    public var originDeviceID: String
    public var originPlatform: String

    public init(
        eventID: UUID = UUID(),
        requestSource: UsageRequestSource,
        sessionID: UUID?,
        providerID: UUID?,
        providerName: String,
        modelID: String,
        requestedAt: Date,
        finishedAt: Date,
        dayKey: String? = nil,
        isStreaming: Bool,
        status: RequestLogStatus,
        httpStatusCode: Int? = nil,
        errorKind: String? = nil,
        tokenUsage: MessageTokenUsage? = nil,
        originDeviceID: String = UsageAnalyticsRuntimeContext.currentDeviceIdentifier(),
        originPlatform: String = UsageAnalyticsRuntimeContext.platformName
    ) {
        self.eventID = eventID
        self.requestSource = requestSource
        self.sessionID = sessionID
        self.providerID = providerID
        self.providerName = providerName
        self.modelID = modelID
        self.requestedAt = requestedAt
        self.finishedAt = finishedAt
        self.dayKey = dayKey ?? UsageAnalyticsRuntimeContext.dayKey(for: requestedAt)
        self.isStreaming = isStreaming
        self.status = status
        self.httpStatusCode = httpStatusCode
        self.errorKind = errorKind
        self.tokenUsage = tokenUsage?.hasAnyData == true ? tokenUsage : nil
        self.originDeviceID = originDeviceID
        self.originPlatform = originPlatform
    }
}

public struct UsageDailyTotal: Codable, Hashable, Sendable {
    public var dayKey: String
    public var requestCount: Int
    public var successCount: Int
    public var failedCount: Int
    public var cancelledCount: Int
    public var tokenTotals: RequestLogTokenTotals

    public init(
        dayKey: String,
        requestCount: Int = 0,
        successCount: Int = 0,
        failedCount: Int = 0,
        cancelledCount: Int = 0,
        tokenTotals: RequestLogTokenTotals = .init()
    ) {
        self.dayKey = dayKey
        self.requestCount = requestCount
        self.successCount = successCount
        self.failedCount = failedCount
        self.cancelledCount = cancelledCount
        self.tokenTotals = tokenTotals
    }

    public var errorCount: Int {
        failedCount
    }
}

public struct UsageDailyModelTotal: Codable, Hashable, Sendable {
    public var dayKey: String
    public var providerName: String
    public var modelID: String
    public var requestSource: UsageRequestSource
    public var requestCount: Int
    public var successCount: Int
    public var failedCount: Int
    public var cancelledCount: Int
    public var tokenTotals: RequestLogTokenTotals

    public init(
        dayKey: String,
        providerName: String,
        modelID: String,
        requestSource: UsageRequestSource,
        requestCount: Int = 0,
        successCount: Int = 0,
        failedCount: Int = 0,
        cancelledCount: Int = 0,
        tokenTotals: RequestLogTokenTotals = .init()
    ) {
        self.dayKey = dayKey
        self.providerName = providerName
        self.modelID = modelID
        self.requestSource = requestSource
        self.requestCount = requestCount
        self.successCount = successCount
        self.failedCount = failedCount
        self.cancelledCount = cancelledCount
        self.tokenTotals = tokenTotals
    }

    public var bucketKey: String {
        "\(providerName)|\(modelID)|\(requestSource.rawValue)"
    }
}

public struct UsageStatsDayBundle: Codable, Hashable, Sendable {
    public var dayKey: String
    public var events: [UsageAnalyticsEvent]

    public init(dayKey: String, events: [UsageAnalyticsEvent]) {
        self.dayKey = dayKey
        self.events = events.sorted { lhs, rhs in
            if lhs.requestedAt == rhs.requestedAt {
                return lhs.eventID.uuidString < rhs.eventID.uuidString
            }
            return lhs.requestedAt < rhs.requestedAt
        }
    }

    public var checksum: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = (try? encoder.encode(self)) ?? Data()
        return data.sha256Hex
    }
}

public struct UsageStatsMergeResult: Hashable, Sendable {
    public var importedEvents: Int
    public var skippedEvents: Int
    public var affectedDayKeys: [String]

    public init(
        importedEvents: Int = 0,
        skippedEvents: Int = 0,
        affectedDayKeys: [String] = []
    ) {
        self.importedEvents = importedEvents
        self.skippedEvents = skippedEvents
        self.affectedDayKeys = affectedDayKeys
    }
}

public enum UsageAnalyticsRuntimeContext {
    public static let deviceIdentifierKey = "cloudSync.deviceIdentifier"

    public static var platformName: String {
        FeedbackEnvironmentCollector.platformName
    }

    public static func currentDeviceIdentifier(userDefaults: UserDefaults = .standard) -> String {
        if let existing = userDefaults.string(forKey: deviceIdentifierKey),
           !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return existing
        }

        let value = UUID().uuidString
        userDefaults.set(value, forKey: deviceIdentifierKey)
        return value
    }

    public static func dayKey(for date: Date, calendar: Calendar = calendar()) -> String {
        formatter(calendar: calendar).string(from: date)
    }

    public static func date(for dayKey: String, calendar: Calendar = calendar()) -> Date? {
        formatter(calendar: calendar).date(from: dayKey)
    }

    public static func weekInterval(containing date: Date, calendar: Calendar = calendar()) -> DateInterval {
        let start = calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 7, to: start) ?? start
        return DateInterval(start: start, end: end)
    }

    public static func monthInterval(containing date: Date, calendar: Calendar = calendar()) -> DateInterval {
        let start = calendar.dateInterval(of: .month, for: date)?.start ?? calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .month, value: 1, to: start) ?? start
        return DateInterval(start: start, end: end)
    }

    public static func dayKeys(in interval: DateInterval, calendar: Calendar = calendar()) -> [String] {
        guard interval.duration > 0 else { return [] }
        var keys: [String] = []
        var cursor = calendar.startOfDay(for: interval.start)
        let endDay = calendar.startOfDay(for: interval.end.addingTimeInterval(-1))

        while cursor <= endDay {
            keys.append(dayKey(for: cursor, calendar: calendar))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return keys
    }

    public static func calendar(timeZone: TimeZone = .autoupdatingCurrent) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    private static func formatter(calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }
}

public extension Notification.Name {
    static let usageAnalyticsStoreDidChange = Notification.Name("com.ETOS.usageAnalytics.storeDidChange")
}
