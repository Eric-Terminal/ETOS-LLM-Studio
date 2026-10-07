import Foundation

public extension Notification.Name {
    static let localLinuxJobsDidChange = Notification.Name("localLinuxJobsDidChange")
    static let localLinuxJobOutputDidChange = Notification.Name("localLinuxJobOutputDidChange")
}

/// 通知只负责唤醒订阅页；任务、诊断和输出仍从各自的持久化来源读取。
enum LocalLinuxJobNotifications {
    static func recordsChanged(jobID: UUID? = nil) {
        NotificationCenter.default.post(name: .localLinuxJobsDidChange, object: jobID.map { $0 as NSUUID })
    }

    static func outputChanged(jobID: UUID) {
        NotificationCenter.default.post(name: .localLinuxJobOutputDidChange, object: jobID as NSUUID)
    }
}
