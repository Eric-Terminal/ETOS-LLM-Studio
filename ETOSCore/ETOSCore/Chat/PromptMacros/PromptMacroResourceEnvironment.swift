import Foundation

enum PromptMacroResourceEnvironment {
    static func captureStorage() -> [String: String] {
        // 使用 App 文档目录所在卷的原始可用容量，双端单位一致；磁盘读取由请求后台任务负责。
        let capacity = try? StorageUtility.documentsDirectory.resourceValues(forKeys: [
            .volumeAvailableCapacityKey, .volumeTotalCapacityKey
        ])
        return storageValues(
            freeBytes: capacity?.volumeAvailableCapacity.map { Int64($0) },
            totalBytes: capacity?.volumeTotalCapacity.map { Int64($0) }
        )
    }

    static func storageValues(freeBytes: Int64?, totalBytes: Int64?) -> [String: String] {
        let free = freeBytes.flatMap { $0 >= 0 ? $0 : nil }
        let total = totalBytes.flatMap { $0 > 0 ? $0 : nil }
        let freePercent: String
        if let free, let total, free <= total {
            freePercent = PromptMacroEnvironment.percentageValue(Float(Double(free) / Double(total)))
        } else {
            freePercent = "unknown"
        }
        return [
            "storage_free_bytes": free.map { String($0) } ?? "unknown",
            "storage_total_bytes": total.map { String($0) } ?? "unknown",
            "storage_free_gb": free.map { gigabytes(Double($0)) } ?? "unknown",
            "storage_total_gb": total.map { gigabytes(Double($0)) } ?? "unknown",
            "storage_free_percent": freePercent
        ]
    }

    static func gigabytes(_ bytes: Double) -> String {
        // 宏数值固定使用小数点，便于用户直接嵌入提示词；GB 按十进制计算。
        String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), bytes / 1_000_000_000)
    }
}
