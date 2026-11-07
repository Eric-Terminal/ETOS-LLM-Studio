// ============================================================================
// DateComparisonBoundaryTests.swift
// ============================================================================
// 日期比较改用时间戳后，保留自动重试、送达、同步与有效期的原有边界。
// ============================================================================

import Foundation
import Testing
@testable import ETOSCore

@Suite("日期比较边界回归")
struct DateComparisonBoundaryTests {
    @Test("恢复失败记录后自动生成仅在冷却截止时刻及之后重试")
    func restoredFailureRespectsRetryBoundary() throws {
        let retryAfter = Date(timeIntervalSince1970: 1_794_067_200.5)
        let state = DailyPulseGenerationRuntimeState(
            checkpoints: [],
            attempts: [DailyPulseGenerationAttempt(
                dayKey: "2026-11-07",
                lastAttemptAt: retryAfter.addingTimeInterval(-900),
                retryAfter: retryAfter,
                consecutiveFailureCount: 1
            )]
        )
        let restored = try JSONDecoder().decode(
            DailyPulseGenerationRuntimeState.self,
            from: JSONEncoder().encode(state)
        )
        let attempt = try #require(restored.attempts.first)
        let cases: [(TimeInterval, Bool)] = [(-0.001, false), (0, true), (0.001, true)]

        for trigger in [DailyPulseTrigger.automatic, .delivery] {
            for (offset, expected) in cases {
                #expect(DailyPulseManager.shouldAttemptGeneration(
                    trigger: trigger,
                    attempt: attempt,
                    referenceDate: retryAfter.addingTimeInterval(offset)
                ) == expected)
            }
        }
    }

    @Test("无失败记录和手动生成保持立即重试")
    func missingAttemptAndManualTriggerBypassCooldown() {
        let now = Date(timeIntervalSince1970: 1_794_067_200)
        let attempt = DailyPulseManager.failedGenerationAttempt(
            dayKey: "2026-11-07",
            previousAttempt: nil,
            referenceDate: now
        )

        for trigger in [DailyPulseTrigger.automatic, .delivery, .manual] {
            #expect(DailyPulseManager.shouldAttemptGeneration(trigger: trigger, attempt: nil, referenceDate: now))
        }
        #expect(DailyPulseManager.shouldAttemptGeneration(trigger: .manual, attempt: attempt, referenceDate: now))
    }

    @Test("每日脉冲送达包含整点且保留后台准备的整点选择")
    func deliveryIncludesExactReminderTime() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let reminder = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 7, hour: 9)))
        let cases: [(TimeInterval, Bool)] = [(-0.001, false), (0, true), (0.001, true)]

        for (offset, expected) in cases {
            #expect(DailyPulseDeliveryCoordinator.hasReachedReminderTime(
                referenceDate: reminder.addingTimeInterval(offset),
                hour: 9,
                minute: 0,
                calendar: calendar
            ) == expected)
        }
        #expect(DailyPulseDeliveryCoordinator.nextBackgroundPreparationDate(
            referenceDate: reminder,
            hour: 9,
            minute: 0,
            forceNextDay: false,
            leadTimeMinutes: 0,
            calendar: calendar
        ) == reminder)
    }

    @Test("送达上下文包含截止时刻的会话并将未来会话留给下一批")
    func deliveryContextRespectsActivityBoundary() {
        let delivery = Date(timeIntervalSince1970: 1_794_067_200.5)
        let excerpts = [
            DailyPulseSessionExcerpt(name: "之前", lines: ["内容"], lastActivityAt: delivery.addingTimeInterval(-0.001)),
            DailyPulseSessionExcerpt(name: "截止", lines: ["内容"], lastActivityAt: delivery),
            DailyPulseSessionExcerpt(name: "之后", lines: ["内容"], lastActivityAt: delivery.addingTimeInterval(0.001)),
            DailyPulseSessionExcerpt(name: "无时间", lines: ["内容"])
        ]

        let batches = DailyPulseManager.partitionedSessionExcerpts(
            excerpts,
            cardCounts: [4, 4],
            scheduledDeliveryDates: [delivery, delivery.addingTimeInterval(1)]
        )

        #expect(batches.map { $0.map(\.name) } == [["之前", "截止", "无时间"], ["之后"]])
    }

    @Test("每日脉冲合并在时间相同时仍优先使用传入记录")
    func pulseMergeKeepsIncomingRecordOnTie() {
        let now = Date(timeIntervalSince1970: 1_794_067_200.5)
        let local = DailyPulseRun(dayKey: "2026-11-07", generatedAt: now, headline: "本地", cards: [], sourceDigest: "local")
        var incoming = local
        incoming.headline = "传入"
        incoming.sourceDigest = "incoming"

        let merged = DailyPulseManager.mergeRun(local: local, incoming: incoming)

        #expect(merged.headline == "传入")
        #expect(merged.sourceDigest == "incoming")
    }

    @Test("同步墓碑过滤更早和相同时刻的记录但允许更新的记录")
    func tombstoneIncludesEqualTimestamp() {
        let deletedAt = Date(timeIntervalSince1970: 1_794_067_200.5)
        let recordID = UUID().uuidString
        let key = SyncRecordDescriptor.key(type: .provider, recordID: recordID)
        let cases: [(TimeInterval, Bool)] = [(-0.001, true), (0, true), (0.001, false)]

        for (offset, expected) in cases {
            let updatedAt = deletedAt.addingTimeInterval(offset)
            for remoteDates in [[String: Date](), [key: updatedAt]] {
                #expect(SyncDeltaEngine.isFilteredOut(
                    type: .provider,
                    recordID: recordID,
                    incomingGeneratedAt: updatedAt,
                    tombstonesByKey: [key: deletedAt],
                    remoteRecordDatesByKey: remoteDates
                ) == expected)
            }
        }
    }

    @Test("记忆有效期包含开始时刻但不包含结束时刻")
    func memoryValidityExcludesExpiration() {
        let start = Date(timeIntervalSince1970: 1_794_067_200.5)
        let end = start.addingTimeInterval(60)
        let memory = MemoryItem(content: "有效期内的记忆", embedding: [], validFrom: start, validUntil: end)

        #expect(!memory.isValid(at: start.addingTimeInterval(-0.001)))
        #expect(memory.isValid(at: start))
        #expect(memory.isValid(at: end.addingTimeInterval(-0.001)))
        #expect(!memory.isValid(at: end))
        #expect(!memory.isValid(at: end.addingTimeInterval(0.001)))
    }

    @Test("用量日期枚举包含最后有效日且排除区间结束日")
    func usageDayKeysRespectExclusiveIntervalEnd() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let start = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 7)))
        let end = try #require(calendar.date(byAdding: .day, value: 2, to: start))

        #expect(UsageAnalyticsRuntimeContext.dayKeys(
            in: DateInterval(start: start, end: end),
            calendar: calendar
        ) == ["2026-11-07", "2026-11-08"])
    }
}
