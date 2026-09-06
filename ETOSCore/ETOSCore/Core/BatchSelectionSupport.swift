// ============================================================================
// BatchSelectionSupport.swift
// ============================================================================
// ETOSCore
//
// 为跨平台批量菜单提供选择集合与底层消息范围计算。
// ============================================================================

import Foundation

public enum BatchSelectionSupport {
    public static func invertedIDs(
        selectableIDs: Set<UUID>,
        selectedIDs: Set<UUID>
    ) -> Set<UUID> {
        selectableIDs.subtracting(selectedIDs)
    }

    /// 工具结果已经内联到调用气泡时，底层 `.tool` 消息不会单独出现在多选列表中。
    /// 删除可见调用气泡必须一并清理这些不可见记录，避免它们在调用消息消失后重新露出。
    public static func deletionIDs(
        selectedIDs: Set<UUID>,
        in messages: [ChatMessage]
    ) -> Set<UUID> {
        guard !selectedIDs.isEmpty else { return [] }

        let selectedResultCallIDs = Set(
            messages
                .filter { selectedIDs.contains($0.id) && $0.role != .tool }
                .flatMap { $0.toolCalls ?? [] }
                .compactMap { call -> String? in
                    let result = (call.result ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    return result.isEmpty ? nil : call.id
                }
        )
        guard !selectedResultCallIDs.isEmpty else { return selectedIDs }

        let hiddenToolMessageIDs = Set(
            messages.compactMap { message -> UUID? in
                guard message.role == .tool,
                      let calls = message.toolCalls,
                      !calls.isEmpty,
                      calls.allSatisfy({ selectedResultCallIDs.contains($0.id) }) else {
                    return nil
                }
                return message.id
            }
        )
        return selectedIDs.union(hiddenToolMessageIDs)
    }
}
