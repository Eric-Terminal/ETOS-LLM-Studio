// ============================================================================
// DailyPulseBackgroundDeliveryScheduler.swift
// ============================================================================
// iOS 每日脉冲后台预准备调度器
//
// 功能特性:
// - 基于 BGAppRefreshTaskRequest 为每日脉冲申请后台预准备窗口
// - 在提醒关闭时自动取消后台任务
// - 今天内容存在后尽快生成明日整期，不再等待固定晚间窗口
// ============================================================================

import Foundation
import BackgroundTasks
import ETOSCore
import os.log

@MainActor
final class DailyPulseBackgroundDeliveryScheduler {
    static let shared = DailyPulseBackgroundDeliveryScheduler()
    static let taskIdentifier = "com.ericterminal.els.dailyPulse.refresh"

    private let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "DailyPulseBackground")
    private let nextDayBoundaryHour = 0

    private init() {}

    func activate() {
        refreshScheduleIfNeeded()
    }

    func refreshScheduleIfNeeded(referenceDate: Date = Date()) {
        let coordinator = DailyPulseDeliveryCoordinator.shared
        guard coordinator.reminderEnabled,
              DailyPulseManager.shared.isDailyPulseEnabled else {
            cancelScheduledRefresh()
            return
        }

        guard let scheduledDate = DailyPulseDeliveryCoordinator.nextBackgroundPreparationDate(
            referenceDate: referenceDate,
            hour: nextDayBoundaryHour,
            minute: 0,
            forceNextDay: DailyPulseManager.shared.tomorrowRun != nil,
            leadTimeMinutes: 0
        ) else {
            logger.error("每日脉冲预准备时间计算失败，跳过本次调度。")
            return
        }

        let request = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
        request.earliestBeginDate = scheduledDate

        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskIdentifier)
        do {
            try BGTaskScheduler.shared.submit(request)
            let scheduledText = DateFormatter.localizedString(
                from: scheduledDate,
                dateStyle: .short,
                timeStyle: .short
            )
            logger.info("每日脉冲预准备已调度：\(scheduledText, privacy: .public)")
        } catch {
            logger.error("每日脉冲预准备调度失败：\(error.localizedDescription, privacy: .public)")
        }
    }

    func cancelScheduledRefresh() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskIdentifier)
    }

    func handleAppRefresh() async {
        defer {
            refreshScheduleIfNeeded()
        }

        let coordinator = DailyPulseDeliveryCoordinator.shared
        let didPrepare = await DailyPulseManager.shared.generateForBackgroundDeliveryIfNeeded(
            reminderEnabled: coordinator.reminderEnabled,
            deliveryTimes: coordinator.deliveryTimes,
            referenceDate: Date()
        )

        if didPrepare {
            logger.info("每日脉冲后台预准备已完成。")
        } else {
            logger.info("每日脉冲后台预准备本次未生成新卡片。")
        }
    }
}
