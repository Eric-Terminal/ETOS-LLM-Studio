// ============================================================================
// DailyPulseBackgroundDeliveryScheduler.swift
// ============================================================================
// iOS 每日脉冲后台预准备调度器
//
// 功能特性:
// - 基于 BGAppRefreshTaskRequest 为每日脉冲申请后台预准备窗口
// - 在提醒关闭时自动取消后台任务
// - 后台任务触发后尽量提前生成今天这一期
// ============================================================================

import Foundation
import BackgroundTasks
import Shared
import os.log

@MainActor
final class DailyPulseBackgroundDeliveryScheduler: ObservableObject {
    static let shared = DailyPulseBackgroundDeliveryScheduler()
    static let taskIdentifier = "com.ericterminal.els.dailyPulse.refresh"

    private let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "DailyPulseBackground")
    private let leadTimeMinutes = 15

    private init() {}

    func activate() {
        refreshScheduleIfNeeded()
    }

    func refreshScheduleIfNeeded(referenceDate: Date = Date()) {
        let coordinator = DailyPulseDeliveryCoordinator.shared
        guard coordinator.reminderEnabled else {
            cancelScheduledRefresh()
            return
        }

        guard let scheduledDate = DailyPulseDeliveryCoordinator.nextBackgroundPreparationDate(
            referenceDate: referenceDate,
            hour: coordinator.reminderHour,
            minute: coordinator.reminderMinute,
            forceNextDay: DailyPulseManager.shared.todayRun != nil,
            leadTimeMinutes: leadTimeMinutes
        ) else {
            logger.error("每日脉冲后台预准备时间计算失败，跳过本次调度。")
            return
        }

        let request = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
        request.earliestBeginDate = scheduledDate

        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskIdentifier)
        do {
            try BGTaskScheduler.shared.submit(request)
            logger.info("每日脉冲后台预准备已调度：\(scheduledDate.formatted(date: .abbreviated, time: .shortened), privacy: .public)")
        } catch {
            logger.error("每日脉冲后台预准备调度失败：\(error.localizedDescription, privacy: .public)")
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
            reminderHour: coordinator.reminderHour,
            reminderMinute: coordinator.reminderMinute,
            referenceDate: Date()
        )

        if didPrepare {
            logger.info("每日脉冲后台预准备已完成。")
        } else {
            logger.info("每日脉冲后台预准备本次未生成新卡片。")
        }
    }
}
