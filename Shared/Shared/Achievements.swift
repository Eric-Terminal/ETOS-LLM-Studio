// ============================================================================
// Achievements.swift
// ============================================================================
// 隐藏成就日记骨架
//
// 维护约束:
// - 不要在公开文档、README 或普通设置说明中主动宣传这个入口。
// - 未解锁前不要展示入口，也不要展示未触发成就。
// - 后续只在明确触发条件达成后调用 AchievementCenter.unlock(id:)。
// ============================================================================

import Combine
import Foundation

#if canImport(UserNotifications)
import UserNotifications
#endif

public struct AchievementID: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: StringLiteralType) {
        self.rawValue = value
    }
}

public extension AchievementID {
    static let steadyCatch: Self = "steadyCatch"
    static let languageLubrication: Self = "languageLubrication"
    static let forbiddenPlace: Self = "forbiddenPlace"
    static let privacyReader: Self = "privacyReader"
    static let documentationReader: Self = "documentationReader"
    static let wildTemperature: Self = "wildTemperature"
    static let absoluteReason: Self = "absoluteReason"
    static let singleCharacterMessage: Self = "singleCharacterMessage"
    static let longConfession: Self = "longConfession"
    static let unstoppableConversation: Self = "unstoppableConversation"
    static let nightOwl: Self = "nightOwl"
    static let memoryPurge: Self = "memoryPurge"
    static let politeHuman: Self = "politeHuman"
    static let schrodingerQuestion: Self = "schrodingerQuestion"
    static let settingsResearcher: Self = "settingsResearcher"
    static let conversationArchaeologist: Self = "conversationArchaeologist"
    static let fishTankReview: Self = "fishTankReview"
}

public struct AchievementDefinition: Identifiable, Hashable, Sendable {
    public let id: AchievementID
    public let titleKey: String
    public let sentenceKey: String
    public let triggerNoteKey: String
    public let systemImageName: String

    public init(
        id: AchievementID,
        titleKey: String,
        sentenceKey: String,
        triggerNoteKey: String,
        systemImageName: String
    ) {
        self.id = id
        self.titleKey = titleKey
        self.sentenceKey = sentenceKey
        self.triggerNoteKey = triggerNoteKey
        self.systemImageName = systemImageName
    }
}

public enum AchievementCatalog {
    public static let definitions: [AchievementDefinition] = [
        AchievementDefinition(
            id: .steadyCatch,
            titleKey: "AI张开了双臂，尽管它没有手。",
            sentenceKey: "被稳稳的接住力",
            triggerNoteKey: "触发关键词：稳稳的接住你和相似表达",
            systemImageName: "hands.sparkles"
        ),
        AchievementDefinition(
            id: .languageLubrication,
            titleKey: "见证了一次完美的语言润滑。",
            sentenceKey: "谄媚这一块～",
            triggerNoteKey: "触发关键词：你说得太对了 / You're absolutely right / 你问到了问题的核心 / Great question / You're asking exactly the right question",
            systemImageName: "quote.bubble"
        ),
        AchievementDefinition(
            id: .forbiddenPlace,
            titleKey: "不该来的地方",
            sentenceKey: "连续点击7次，触发了某种不可名状的机制。",
            triggerNoteKey: "触发条件：连续点击版本号 7 次",
            systemImageName: "lock.open"
        ),
        AchievementDefinition(
            id: .privacyReader,
            titleKey: "我真的读了",
            sentenceKey: "法务部门在某处落下了一滴感动的泪水",
            triggerNoteKey: "触发条件：打开隐私政策链接",
            systemImageName: "doc.text.magnifyingglass"
        ),
        AchievementDefinition(
            id: .documentationReader,
            titleKey: "RTFM",
            sentenceKey: "翻开了文档，成为了时代的逆行者",
            triggerNoteKey: "触发条件：打开文档链接",
            systemImageName: "book"
        ),
        AchievementDefinition(
            id: .wildTemperature,
            titleKey: "放飞自我",
            sentenceKey: "解除了AI的所有束缚，后果自负。",
            triggerNoteKey: "触发条件：将 Temperature 调到 2.0",
            systemImageName: "flame"
        ),
        AchievementDefinition(
            id: .absoluteReason,
            titleKey: "绝对理性",
            sentenceKey: "要求AI成为一台没有灵魂的机器。",
            triggerNoteKey: "触发条件：将 Temperature 调到 0",
            systemImageName: "cpu"
        ),
        AchievementDefinition(
            id: .singleCharacterMessage,
            titleKey: "惜字如金",
            sentenceKey: "一个字，也算一条消息。",
            triggerNoteKey: "触发条件：发送一条只有 1 个字的消息",
            systemImageName: "1.circle"
        ),
        AchievementDefinition(
            id: .longConfession,
            titleKey: "倾诉欲爆表",
            sentenceKey: "一次性说完了所有想说的话。",
            triggerNoteKey: "触发条件：发送超过 1000 字的消息",
            systemImageName: "text.alignleft"
        ),
        AchievementDefinition(
            id: .unstoppableConversation,
            titleKey: "停不下来",
            sentenceKey: "和AI聊了很久很久，Token如奶油般化开。",
            triggerNoteKey: "触发条件：单个会话内连续对话超过 50 轮",
            systemImageName: "infinity"
        ),
        AchievementDefinition(
            id: .nightOwl,
            titleKey: "夜猫子",
            sentenceKey: "在不该清醒的时间，找了一个永远不会睡着的东西说话。",
            triggerNoteKey: "触发条件：凌晨 3 点后发送消息",
            systemImageName: "moon.stars"
        ),
        AchievementDefinition(
            id: .memoryPurge,
            titleKey: "断舍离",
            sentenceKey: "删除了所有的记忆，AI毫无察觉。",
            triggerNoteKey: "触发条件：清空所有对话记录",
            systemImageName: "trash.slash"
        ),
        AchievementDefinition(
            id: .politeHuman,
            titleKey: "有礼貌的人类",
            sentenceKey: "向一个不需要被感谢的程序道了谢。",
            triggerNoteKey: "触发条件：用支持的语言向 AI 道谢",
            systemImageName: "hands.clap"
        ),
        AchievementDefinition(
            id: .schrodingerQuestion,
            titleKey: "薛定谔的问题",
            sentenceKey: "坚持认为第三次AI会给出不同答案。",
            triggerNoteKey: "触发条件：连续重试同一条消息 3 次",
            systemImageName: "questionmark.bubble"
        ),
        AchievementDefinition(
            id: .settingsResearcher,
            titleKey: "研究者",
            sentenceKey: "在设置里找到了什么，或者什么都没找到。",
            triggerNoteKey: "触发条件：在设置页面停留超过 5 分钟",
            systemImageName: "magnifyingglass"
        ),
        AchievementDefinition(
            id: .conversationArchaeologist,
            titleKey: "考古学家",
            sentenceKey: "翻到了最早的对话记录。",
            triggerNoteKey: "触发条件：超过 300 个会话后翻到最后一页",
            systemImageName: "archivebox"
        ),
        AchievementDefinition(
            id: .fishTankReview,
            titleKey: "让AI评价鱼缸",
            sentenceKey: "AI使用了评价这款App的工具。套娃已完成。",
            triggerNoteKey: "触发条件：AI 调用 app_submit_feedback_ticket 工具",
            systemImageName: "bubble.left.and.text.bubble.right"
        )
    ]
}

public enum AchievementTriggerEvaluator {
    static let longMessageCharacterThreshold = 1_000
    static let longConversationTurnThreshold = 50
    static let repeatedRetryThreshold = 3
    public static let settingsResearchDuration: TimeInterval = 5 * 60
    public static let archaeologySessionThreshold = 300
    private static let politeHumanPhrases: Set<String> = [
        "谢谢",
        "謝謝",
        "多謝",
        "thanks",
        "thank you",
        "gracias",
        "merci",
        "ありがとう",
        "ありがとうございます",
        "спасибо",
        "شكرا",
        "شكراً",
        "شكرًا"
    ]

    static func shouldUnlockSteadyCatch(from assistantReply: String) -> Bool {
        if assistantReply.contains("稳稳的接住你") {
            return true
        }

        let folded = foldedText(assistantReply)
        return folded.contains("i've got you")
            || folded.contains("i am here to hold space for you")
    }

    static func shouldUnlockLanguageLubrication(from assistantReply: String) -> Bool {
        if assistantReply.contains("你说得太对了") || assistantReply.contains("你问到了问题的核心") {
            return true
        }

        let folded = foldedText(assistantReply)
        return folded.contains("you're absolutely right")
            || folded.contains("great question")
            || folded.contains("you're asking exactly the right question")
    }

    static func userMessageAchievementIDs(
        for content: String,
        userMessageCount: Int,
        sentAt: Date,
        calendar: Calendar = .current,
        includePoliteHuman: Bool = true
    ) -> [AchievementID] {
        var ids: [AchievementID] = []
        if includePoliteHuman && shouldUnlockPoliteHuman(from: content) {
            ids.append(.politeHuman)
        }
        if shouldUnlockSingleCharacterMessage(from: content) {
            ids.append(.singleCharacterMessage)
        }
        if shouldUnlockLongConfession(from: content) {
            ids.append(.longConfession)
        }
        if shouldUnlockUnstoppableConversation(userMessageCount: userMessageCount) {
            ids.append(.unstoppableConversation)
        }
        if shouldUnlockNightOwl(sentAt: sentAt, calendar: calendar) {
            ids.append(.nightOwl)
        }
        return ids
    }

    static func shouldUnlockSingleCharacterMessage(from content: String) -> Bool {
        content.trimmingCharacters(in: .whitespacesAndNewlines).count == 1
    }

    static func shouldUnlockPoliteHuman(from content: String) -> Bool {
        let normalized = normalizedPoliteHumanPhrase(content)
        guard !normalized.isEmpty else { return false }
        return politeHumanPhrases.contains(normalized)
    }

    static func shouldUnlockLongConfession(from content: String) -> Bool {
        content.trimmingCharacters(in: .whitespacesAndNewlines).count > longMessageCharacterThreshold
    }

    static func shouldUnlockUnstoppableConversation(userMessageCount: Int) -> Bool {
        userMessageCount > longConversationTurnThreshold
    }

    static func shouldUnlockNightOwl(sentAt: Date, calendar: Calendar = .current) -> Bool {
        let hour = calendar.component(.hour, from: sentAt)
        return hour >= 3 && hour < 6
    }

    static func shouldUnlockSchrodingerQuestion(consecutiveRetryCount: Int) -> Bool {
        consecutiveRetryCount >= repeatedRetryThreshold
    }

    public static func shouldUnlockSettingsResearcher(elapsedTime: TimeInterval) -> Bool {
        elapsedTime >= settingsResearchDuration
    }

    public static func shouldUnlockConversationArchaeologist(
        totalSessions: Int,
        pageIndex: Int,
        totalPages: Int
    ) -> Bool {
        totalSessions > archaeologySessionThreshold
            && totalPages > 1
            && pageIndex == totalPages - 1
    }

    static func shouldUnlockFishTankReview(appToolName: String) -> Bool {
        appToolName == "app_submit_feedback_ticket"
    }

    private static func normalizedPoliteHumanPhrase(_ text: String) -> String {
        let trimSet = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        return foldedText(text.trimmingCharacters(in: trimSet))
    }

    private static func foldedText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "’", with: "'")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }
}

public struct AchievementUnlockRecord: Identifiable, Codable, Hashable, Sendable {
    public let unlockID: UUID
    public var id: UUID { unlockID }
    public let achievementID: AchievementID
    public let unlockedAt: Date
    public let originDeviceID: String
    public let originPlatform: String

    public init(
        unlockID: UUID = UUID(),
        achievementID: AchievementID,
        unlockedAt: Date = Date(),
        originDeviceID: String = UsageAnalyticsRuntimeContext.currentDeviceIdentifier(),
        originPlatform: String = UsageAnalyticsRuntimeContext.platformName
    ) {
        self.unlockID = unlockID
        self.achievementID = achievementID
        self.unlockedAt = unlockedAt
        self.originDeviceID = originDeviceID
        self.originPlatform = originPlatform
    }
}

public struct AchievementJournalEntry: Identifiable, Hashable, Sendable {
    public var id: AchievementID { achievementID }
    public let achievementID: AchievementID
    public let titleKey: String
    public let sentenceKey: String
    public let triggerNoteKey: String
    public let systemImageName: String
    public let unlockedAt: Date
    public let unlockID: UUID

    public init(definition: AchievementDefinition, record: AchievementUnlockRecord) {
        self.achievementID = definition.id
        self.titleKey = definition.titleKey
        self.sentenceKey = definition.sentenceKey
        self.triggerNoteKey = definition.triggerNoteKey
        self.systemImageName = definition.systemImageName
        self.unlockedAt = record.unlockedAt
        self.unlockID = record.unlockID
    }

    public var localizedTitle: String {
        NSLocalizedString(titleKey, comment: "Achievement title")
    }

    public var localizedSentence: String {
        NSLocalizedString(sentenceKey, comment: "Achievement sentence")
    }

    public var localizedTriggerNote: String {
        NSLocalizedString(triggerNoteKey, comment: "Achievement trigger note")
    }
}

@MainActor
public final class AchievementCenter: ObservableObject {
    public typealias NotificationHandler = @MainActor (AchievementJournalEntry) async -> Void

    public static let shared = AchievementCenter()

    public nonisolated static let storageKeyPrefix = "achievementJournal.unlock."

    @Published public private(set) var journalEntries: [AchievementJournalEntry]
    @Published public private(set) var hasUnlockedAchievements: Bool

    private let defaults: UserDefaults
    private let definitionsByID: [AchievementID: AchievementDefinition]
    private let notificationHandler: NotificationHandler?
    private let encoder = JSONEncoder()
    private var unlockedAchievementIDs: Set<AchievementID>
    private var defaultsObserver: NSObjectProtocol?

    public init(
        defaults: UserDefaults = .standard,
        definitions: [AchievementDefinition] = AchievementCatalog.definitions,
        notificationHandler: NotificationHandler? = nil
    ) {
        self.defaults = defaults
        self.definitionsByID = Dictionary(uniqueKeysWithValues: definitions.map { ($0.id, $0) })
        self.notificationHandler = notificationHandler ?? Self.deliverUnlockNotification
        let entries = Self.makeJournalEntries(
            records: Self.loadUnlockRecords(from: defaults),
            definitionsByID: definitionsByID
        )
        self.journalEntries = entries
        self.hasUnlockedAchievements = !entries.isEmpty
        self.unlockedAchievementIDs = Set(entries.map(\.achievementID))
        observeDefaultsChanges()
    }

    deinit {
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
        }
    }

    @discardableResult
    public func unlock(id: AchievementID, unlockedAt: Date = Date()) async -> AchievementUnlockRecord? {
        guard let definition = definitionsByID[id] else { return nil }
        let existingRecords = Self.loadUnlockRecords(from: defaults)
        guard !existingRecords.contains(where: { $0.achievementID == id }) else {
            refreshFromStorage()
            return nil
        }

        let record = AchievementUnlockRecord(
            achievementID: id,
            unlockedAt: unlockedAt,
            originDeviceID: UsageAnalyticsRuntimeContext.currentDeviceIdentifier(userDefaults: defaults)
        )
        guard let data = try? encoder.encode(record) else { return nil }
        defaults.set(data, forKey: Self.storageKey(for: record))
        refreshFromStorage(records: existingRecords + [record])

        let entry = AchievementJournalEntry(definition: definition, record: record)
        await notificationHandler?(entry)
        return record
    }

    public func refreshFromStorage() {
        refreshFromStorage(records: Self.loadUnlockRecords(from: defaults))
    }

    public func hasUnlocked(id: AchievementID) -> Bool {
        unlockedAchievementIDs.contains(id)
    }

    public nonisolated static func isAchievementStorageKey(_ key: String) -> Bool {
        key.hasPrefix(storageKeyPrefix)
    }

    public nonisolated static func storageKey(for record: AchievementUnlockRecord) -> String {
        storageKey(achievementID: record.achievementID, unlockID: record.unlockID)
    }

    public nonisolated static func storageKey(achievementID: AchievementID, unlockID: UUID) -> String {
        "\(storageKeyPrefix)\(achievementID.rawValue).\(unlockID.uuidString)"
    }

    private func refreshFromStorage(records: [AchievementUnlockRecord]) {
        let entries = Self.makeJournalEntries(records: records, definitionsByID: definitionsByID)
        journalEntries = entries
        hasUnlockedAchievements = !entries.isEmpty
        unlockedAchievementIDs = Set(entries.map(\.achievementID))
    }

    private func observeDefaultsChanges() {
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshFromStorage()
            }
        }
    }

    private nonisolated static func loadUnlockRecords(
        from defaults: UserDefaults
    ) -> [AchievementUnlockRecord] {
        let decoder = JSONDecoder()
        var records: [AchievementUnlockRecord] = []
        for (key, value) in defaults.dictionaryRepresentation() {
            guard isAchievementStorageKey(key),
                  let data = value as? Data,
                  let record = try? decoder.decode(AchievementUnlockRecord.self, from: data) else {
                continue
            }
            records.append(record)
        }
        return records
    }

    private nonisolated static func makeJournalEntries(
        records: [AchievementUnlockRecord],
        definitionsByID: [AchievementID: AchievementDefinition]
    ) -> [AchievementJournalEntry] {
        let earliestRecords = records.reduce(into: [AchievementID: AchievementUnlockRecord]()) { partialResult, record in
            guard definitionsByID[record.achievementID] != nil else { return }
            if let existing = partialResult[record.achievementID] {
                if record.unlockedAt < existing.unlockedAt {
                    partialResult[record.achievementID] = record
                }
            } else {
                partialResult[record.achievementID] = record
            }
        }

        return earliestRecords.compactMap { achievementID, record in
            guard let definition = definitionsByID[achievementID] else { return nil }
            return AchievementJournalEntry(definition: definition, record: record)
        }
        .sorted { lhs, rhs in
            if lhs.unlockedAt == rhs.unlockedAt {
                return lhs.achievementID.rawValue < rhs.achievementID.rawValue
            }
            return lhs.unlockedAt > rhs.unlockedAt
        }
    }

    private static func deliverUnlockNotification(for entry: AchievementJournalEntry) async {
#if canImport(UserNotifications)
        let granted = await AppLocalNotificationCenter.shared.requestAuthorizationIfNeeded(options: [.alert, .sound, .badge])
        guard granted else { return }

        let content = UNMutableNotificationContent()
        content.title = String(
            format: NSLocalizedString("解锁成就：%@", comment: "Achievement unlock notification title"),
            entry.localizedTitle
        )
        content.body = entry.localizedSentence
        content.sound = .default
        content.threadIdentifier = "achievement.journal"
        content.userInfo = AppLocalNotificationCenter.achievementJournalUserInfo(
            achievementID: entry.achievementID.rawValue
        )

        let identifier = "achievement.journal.\(entry.achievementID.rawValue).\(entry.unlockID.uuidString)"
            .replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "-", options: .regularExpression)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        _ = await AppLocalNotificationCenter.shared.addNotificationRequest(request)
#endif
    }
}
