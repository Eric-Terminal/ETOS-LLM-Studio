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
        let originalHistory = Persistence.loadDailyPulseFeedbackHistory()
        let originalCuration = Persistence.loadDailyPulsePendingCuration()
        let originalSignals = Persistence.loadDailyPulseExternalSignals()
        let originalTasks = Persistence.loadDailyPulseTasks()
        defer {
            Persistence.saveDailyPulseRuns(originalRuns)
            Persistence.saveDailyPulseFeedbackHistory(originalHistory)
            Persistence.saveDailyPulsePendingCuration(originalCuration)
            Persistence.saveDailyPulseExternalSignals(originalSignals)
            Persistence.saveDailyPulseTasks(originalTasks)
        }

        let expectedRun = makeRun(
            dayKey: "2026-03-22",
            generatedAt: Date(timeIntervalSince1970: 1_000),
            title: "今天该看的项目推进"
        )
        Persistence.saveDailyPulseRuns([expectedRun])
        Persistence.saveDailyPulseFeedbackHistory([
            DailyPulseFeedbackEvent(
                dayKey: "2026-03-22",
                topicHint: "项目推进",
                cardTitle: "今天该看的项目推进",
                action: .liked
            )
        ])
        Persistence.saveDailyPulsePendingCuration(
            DailyPulseCurationNote(targetDayKey: "2026-03-23", text: "明天帮我继续看项目推进")
        )
        Persistence.saveDailyPulseExternalSignals([
            DailyPulseExternalSignal(source: .announcement, title: "新版本发布", preview: "同步更稳了", capturedAt: Date(timeIntervalSince1970: 1_100))
        ])
        Persistence.saveDailyPulseTasks([
            DailyPulseTask(
                sourceDayKey: "2026-03-22",
                sourceCardID: expectedRun.cards.first?.id,
                title: "继续推进项目",
                details: "先整理阻塞点",
                suggestedPrompt: "帮我继续拆项目阻塞点"
            )
        ])

        let package = SyncEngine.buildPackage(options: [.dailyPulse])

        #expect(package.dailyPulseRuns.count == 1)
        #expect(package.dailyPulseFeedbackHistory.count == 1)
        #expect(package.dailyPulsePendingCuration?.text == "明天帮我继续看项目推进")
        #expect(package.dailyPulseExternalSignals.count == 1)
        #expect(package.dailyPulseTasks.count == 1)
        #expect(package.dailyPulseRuns.first?.dayKey == expectedRun.dayKey)
        #expect(package.dailyPulseRuns.first?.cards.first?.title == expectedRun.cards.first?.title)
    }

    @Test("每日脉冲同步会按日期合并并保留较强反馈")
    func mergeDailyPulseRunsKeepsFeedbackAndSavedSession() async {
        let originalRuns = Persistence.loadDailyPulseRuns()
        let originalHistory = Persistence.loadDailyPulseFeedbackHistory()
        let originalCuration = Persistence.loadDailyPulsePendingCuration()
        let originalSignals = Persistence.loadDailyPulseExternalSignals()
        let originalTasks = Persistence.loadDailyPulseTasks()
        defer {
            Persistence.saveDailyPulseRuns(originalRuns)
            Persistence.saveDailyPulseFeedbackHistory(originalHistory)
            Persistence.saveDailyPulsePendingCuration(originalCuration)
            Persistence.saveDailyPulseExternalSignals(originalSignals)
            Persistence.saveDailyPulseTasks(originalTasks)
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
        Persistence.saveDailyPulseFeedbackHistory([])
        Persistence.saveDailyPulsePendingCuration(nil)
        Persistence.saveDailyPulseExternalSignals([])
        Persistence.saveDailyPulseTasks([])

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
            dailyPulseRuns: [remoteMergedRun, remoteNewRun],
            dailyPulseFeedbackHistory: [
                DailyPulseFeedbackEvent(
                    dayKey: "2026-03-22",
                    topicHint: "继续推进项目",
                    cardTitle: "继续推进项目",
                    action: .saved
                )
            ],
            dailyPulsePendingCuration: DailyPulseCurationNote(targetDayKey: "2026-03-24", text: "明天优先跟进 reviewer 反馈"),
            dailyPulseExternalSignals: [
                DailyPulseExternalSignal(source: .shortcutResult, title: "今日摘要", preview: "还有 2 个待处理事项", capturedAt: Date(timeIntervalSince1970: 2_500))
            ],
            dailyPulseTasks: [
                DailyPulseTask(
                    sourceDayKey: "2026-03-22",
                    sourceCardID: remoteMergedRun.cards.first?.id,
                    title: "继续推进项目",
                    details: "同步 reviewer 意见",
                    suggestedPrompt: "帮我整理 reviewer 回复",
                    updatedAt: Date(timeIntervalSince1970: 2_500)
                )
            ]
        )

        let summary = await SyncEngine.apply(package: package)
        let mergedRuns = Persistence.loadDailyPulseRuns().sorted(by: { $0.generatedAt > $1.generatedAt })
        let mergedHistory = Persistence.loadDailyPulseFeedbackHistory()
        let mergedCuration = Persistence.loadDailyPulsePendingCuration()
        let mergedSignals = Persistence.loadDailyPulseExternalSignals()
        let mergedTasks = Persistence.loadDailyPulseTasks()

        #expect(summary.importedDailyPulseRuns >= 4)
        #expect(summary.skippedDailyPulseRuns == 0)
        #expect(mergedRuns.count == 2)
        #expect(mergedRuns.first?.dayKey == "2026-03-23")

        let mergedSameDay = mergedRuns.first(where: { $0.dayKey == "2026-03-22" })
        #expect(mergedSameDay?.headline == "远端脉冲")
        #expect(mergedSameDay?.cards.first?.feedback == .hidden)
        #expect(mergedSameDay?.cards.first?.savedSessionID == savedSessionID)
        #expect(mergedHistory.first?.action == .saved)
        #expect(mergedCuration?.text == "明天优先跟进 reviewer 反馈")
        #expect(mergedSignals.first?.title == "今日摘要")
        #expect(mergedTasks.first?.title == "继续推进项目")
    }

    @Test("每日脉冲同步写回后会保留最近上限")
    func mergeDailyPulseRunsRespectsRetentionLimit() async {
        let originalRuns = Persistence.loadDailyPulseRuns()
        let originalHistory = Persistence.loadDailyPulseFeedbackHistory()
        let originalCuration = Persistence.loadDailyPulsePendingCuration()
        let originalSignals = Persistence.loadDailyPulseExternalSignals()
        let originalTasks = Persistence.loadDailyPulseTasks()
        defer {
            Persistence.saveDailyPulseRuns(originalRuns)
            Persistence.saveDailyPulseFeedbackHistory(originalHistory)
            Persistence.saveDailyPulsePendingCuration(originalCuration)
            Persistence.saveDailyPulseExternalSignals(originalSignals)
            Persistence.saveDailyPulseTasks(originalTasks)
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
