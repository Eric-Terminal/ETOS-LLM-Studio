// ============================================================================
// ApplicationBackgroundTaskLease.swift
// ============================================================================

import UIKit

/// 为必须完成的短收尾工作持有可重复结束的后台任务，避免多个异步出口重复释放。
@MainActor
final class ApplicationBackgroundTaskLease {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    init(name: String) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            Task { @MainActor in
                self?.end()
            }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }

    deinit {
        let identifier = identifier
        if identifier != .invalid {
            Task { @MainActor in
                UIApplication.shared.endBackgroundTask(identifier)
            }
        }
    }
}
