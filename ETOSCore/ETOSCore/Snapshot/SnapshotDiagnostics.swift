import Foundation
import os.log

/// 在耗时步骤开始前同步落盘，进程被系统终止后仍可从现有日志页面读取最后一个检查点。
/// 只在备份后台任务中调用；不记录聊天、密码、对象存储地址或凭证。
public final class SnapshotDiagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private let startedAt = ProcessInfo.processInfo.systemUptime
    private let operationID = UUID().uuidString.lowercased()
    private let logFileURL: URL
    private let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "Snapshot")

    public convenience init() {
        self.init(baseDirectory: StorageUtility.documentsDirectory.appendingPathComponent("AppLogs", isDirectory: true))
    }

    init(baseDirectory: URL, now: Date = Date()) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        let directory = baseDirectory.appendingPathComponent(formatter.string(from: now), isDirectory: true)
        formatter.dateFormat = "HH-mm-ss-SSS"
        logFileURL = directory.appendingPathComponent("run-\(formatter.string(from: now))-snapshot-\(operationID).jsonl")
    }

    public func record(
        _ stage: String,
        fileURL: URL? = nil,
        details: [String: String] = [:],
        level: AppLogLevel = .info
    ) {
        lock.lock()
        defer { lock.unlock() }

        var payload = details
        payload["operationID"] = operationID
        payload["elapsedMilliseconds"] = String(Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1_000))
        payload["systemVersion"] = ProcessInfo.processInfo.operatingSystemVersionString
        payload["appVersion"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        payload["appBuild"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        if let memoryBytes = LocalResourceUsageMonitor.currentMemoryFootprintBytes() {
            payload["memoryFootprintBytes"] = String(memoryBytes)
        }
        if let fileURL,
           let size = try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber {
            payload["fileBytes"] = size.stringValue
        }

        do {
            let directory = logFileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let freeBytes = try? FileManager.default.attributesOfFileSystem(forPath: directory.path)[.systemFreeSize] as? NSNumber {
                payload["freeDiskBytes"] = freeBytes.stringValue
            }
            let event = AppLogEvent(
                channel: .developer,
                level: level,
                category: "Snapshot",
                action: stage,
                message: "快照操作检查点",
                payload: payload
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            var data = try encoder.encode(event)
            data.append(0x0A)
            if !FileManager.default.fileExists(atPath: logFileURL.path) {
                try Data().write(to: logFileURL, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logFileURL.path)
            }
            let handle = try FileHandle(forWritingTo: logFileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            // 普通异步日志可能尚未写入就遭到内存终止，这里必须先完成持久化再进入下一步。
            try handle.synchronize()
        } catch {
            // 日志写入失败不能阻止用户备份，也不能把可能含路径的原始错误写入日志。
            logger.error("快照检查点写入失败：\(stage, privacy: .public)，错误码：\((error as NSError).code)")
        }
    }

    public func recordFailure(_ error: Error) {
        let error = error as NSError
        record("operation.failed", details: ["errorDomain": error.domain, "errorCode": String(error.code)], level: .error)
    }
}
