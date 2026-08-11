// ============================================================================
// LocalLinuxBackgroundTaskManager.swift
// ============================================================================
// ETOS LLM Studio
//
// App 进入后台后使用系统给出的短暂执行窗口继续收尾。窗口耗尽时取消 guest
// 进程组并把任务归因为 interruptedBySuspension，重开 App 后不会自动重放。
// ============================================================================

import ETOSCore
import UIKit

@MainActor
final class LocalLinuxBackgroundTaskManager {
    static let shared = LocalLinuxBackgroundTaskManager()

    private var taskIdentifier: UIBackgroundTaskIdentifier = .invalid
    private var completionMonitor: Task<Void, Never>?

    private init() {}

    func sceneDidEnterBackground() {
        Task { [weak self] in
            guard await LocalLinuxJobScheduler.shared.hasActiveJobs() else { return }
            self?.beginIfNeeded()
        }
    }

    func sceneDidBecomeActive() {
        endIfNeeded()
    }

    private func beginIfNeeded() {
        guard taskIdentifier == .invalid else { return }
        taskIdentifier = UIApplication.shared.beginBackgroundTask(withName: "local-linux.jobs") { [weak self] in
            Task {
                await LocalLinuxJobScheduler.shared.interruptForSystemSuspension()
                await MainActor.run { self?.endIfNeeded() }
            }
        }
        completionMonitor?.cancel()
        completionMonitor = Task { [weak self] in
            for await _ in await LocalLinuxRuntimeController.shared.updates() {
                guard !Task.isCancelled else { return }
                if !(await LocalLinuxJobScheduler.shared.hasActiveJobs()) {
                    self?.endIfNeeded()
                    return
                }
            }
        }
    }

    private func endIfNeeded() {
        completionMonitor?.cancel()
        completionMonitor = nil
        guard taskIdentifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(taskIdentifier)
        taskIdentifier = .invalid
    }
}
