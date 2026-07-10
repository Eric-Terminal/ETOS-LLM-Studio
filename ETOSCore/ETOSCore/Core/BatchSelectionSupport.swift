// ============================================================================
// BatchSelectionSupport.swift
// ============================================================================
// ETOSCore
//
// 为跨平台批量菜单提供统一的反选集合计算。
// ============================================================================

import Foundation

public enum BatchSelectionSupport {
    public static func invertedIDs(
        selectableIDs: Set<UUID>,
        selectedIDs: Set<UUID>
    ) -> Set<UUID> {
        selectableIDs.subtracting(selectedIDs)
    }
}
