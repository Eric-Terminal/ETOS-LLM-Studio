import Foundation

enum SkillLibraryFileTransaction {
    /// 文件系统与配置库不能共享事务。保留原目录（含文件权限），配置写入失败时恢复；
    /// 备份导出/数据库恢复须等待调用者登记的整次操作完成。
    static func perform(original: URL?, target: URL, operation: () throws -> Void) throws {
        let fm = FileManager.default
        let backup = original.map { $0.deletingLastPathComponent().appendingPathComponent(".skill-edit-\(UUID().uuidString)") }
        if let original, let backup { try fm.copyItem(at: original, to: backup) }
        do {
            try operation()
        } catch {
            // 恢复失败时不清除备份，让用户仍可找回原始资源。
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            if let original, let backup {
                if fm.fileExists(atPath: original.path) { try fm.removeItem(at: original) }
                try fm.moveItem(at: backup, to: original)
            }
            throw error
        }
        if let backup { try? fm.removeItem(at: backup) }
    }
}
