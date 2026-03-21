// ============================================================================
// DailyPulseSyncTests.swift
// ============================================================================
// DailyPulseSyncTests 测试文件
// - 覆盖每日脉冲同步包导出逻辑
// - 覆盖按日期合并与反馈保留逻辑
// - 覆盖同步写回后的保留上限裁剪
// ============================================================================

import Testing
import Foundation
@testable import Shared

@Suite("每日脉冲同步测试")
struct DailyPulseSyncTests {

    @Test("开启同步项时会导出每日脉冲运行记录")
    func exportDailyPulseRunsWhenOptionEnabled() {
        let originalRuns = Persistence.loadDailyPulseRuns()
        defer {
            Persistence.saveDailyPulseRuns(originalRuns)
        }

        let expectedRun = makeRun(
            dayKey: "2026-03-22",
            generatedAt: Date(timeIntervalSince1970: 1_000),
            title: "今天该看的项目推进"
        )
        Persistence.saveDailyPulseRuns([expectedRun])

        let package = SyncEngine.buildPackage(options: [.dailyPulse])

        #expect(package.dailyPulseRuns.count == 1)
        #expect(package.dailyPulseRuns.first?.dayKey == expectedRun.dayKey)
        #expect(package.dailyPulseRuns.first?.cards.first?.title == expectedRun.cards.first?.title)
    }

    @Test("每日脉冲同步会按日期合并并保留较强反馈")
    func mergeDailyPulseRunsKeepsFeedbackAndSavedSession() async {
        let originalRuns = Persistence.loadDailyPulseRuns()
        defer {
            Persistence.saveDailyPulseRuns(originalRuns)
        }

        let savedSessionID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let localRun = DailyPulseRun(
            dayKey: "2026-03-22",
            generatedAt: Date(timeIntervalSince1970: 1_000),
            headline: "本地脉冲",
            cards: [
                DailyPulseCard(
                    title: "继续推进项目",
                    whyRecommended: "本地原因",
                    summary: "本地摘要",
                    detailsMarkdown: "本地详情",
                    suggestedPrompt: "本地追问",
                    feedback: .liked,
                    savedSessionID: savedSessionID
                )
            ],
            sourceDigest: "local"
        )
        Persistence.saveDailyPulseRuns([localRun])

        let remoteMergedRun = DailyPulseRun(
            dayKey: "2026-03-22",
            generatedAt: Date(timeIntervalSince1970: 2_000),
            headline: "远端脉冲",
            cards: [
                DailyPulseCard(
                    title: "继续推进项目",
                    whyRecommended: "远端原因",
                    summary: "远端摘要",
                    detailsMarkdown: "远端详情",
                    suggestedPrompt: "远端追问",
                    feedback: .hidden
                )
            ],
            sourceDigest: "remote"
        )
        let remoteNewRun = makeRun(
            dayKey: "2026-03-23",
            generatedAt: Date(timeIntervalSince1970: 3_000),
            title: "学习新概念"
        )

        let package = SyncPackage(
            options: [.dailyPulse],
            dailyPulseRuns: [remoteMergedRun, remoteNewRun]
        )

        let summary = await SyncEngine.apply(package: package)
        let mergedRuns = Persistence.loadDailyPulseRuns().sorted(by: { $0.generatedAt > $1.generatedAt })

        #expect(summary.importedDailyPulseRuns == 2)
        #expect(summary.skippedDailyPulseRuns == 0)
        #expect(mergedRuns.count == 2)
        #expect(mergedRuns.first?.dayKey == "2026-03-23")

        let mergedSameDay = mergedRuns.first(where: { $0.dayKey == "2026-03-22" })
        #expect(mergedSameDay?.headline == "远端脉冲")
        #expect(mergedSameDay?.cards.first?.feedback == .hidden)
        #expect(mergedSameDay?.cards.first?.savedSessionID == savedSessionID)
    }

    @Test("每日脉冲同步写回后会保留最近上限")
    func mergeDailyPulseRunsRespectsRetentionLimit() async {
        let originalRuns = Persistence.loadDailyPulseRuns()
        defer {
            Persistence.saveDailyPulseRuns(originalRuns)
        }

        Persistence.saveDailyPulseRuns([])
        let incomingRuns = (0..<16).map { index in
            makeRun(
                dayKey: String(format: "2026-03-%02d", index + 1),
                generatedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                title: "卡片 \(index + 1)"
            )
        }
        let package = SyncPackage(
            options: [.dailyPulse],
            dailyPulseRuns: incomingRuns
        )

        let summary = await SyncEngine.apply(package: package)
        let mergedRuns = Persistence.loadDailyPulseRuns().sorted(by: { $0.generatedAt > $1.generatedAt })

        #expect(summary.importedDailyPulseRuns == 16)
        #expect(mergedRuns.count == DailyPulseManager.persistedRetentionLimit)
        #expect(mergedRuns.first?.dayKey == "2026-03-16")
        #expect(mergedRuns.last?.dayKey == "2026-03-03")
    }

    private func makeRun(dayKey: String, generatedAt: Date, title: String) -> DailyPulseRun {
        DailyPulseRun(
            dayKey: dayKey,
            generatedAt: generatedAt,
            headline: "今日脉冲",
            cards: [
                DailyPulseCard(
                    title: title,
                    whyRecommended: "测试原因",
                    summary: "测试摘要",
                    detailsMarkdown: "测试详情",
                    suggestedPrompt: "测试追问"
                )
            ],
            sourceDigest: "digest-\(dayKey)"
        )
    }
}
