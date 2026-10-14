import Foundation

public extension LocalLinuxMountRecord {
    /// 租约数与授权探测状态是运行数据；确认目录变更时比较可修改配置和不可复用的身份。
    func matchesConfiguration(_ other: LocalLinuxMountRecord) -> Bool {
        id == other.id && createdAt == other.createdAt && bookmark == other.bookmark
            && guestPath == other.guestPath && displayName == other.displayName
            && access == other.access && isEnabled == other.isEnabled
    }
}
