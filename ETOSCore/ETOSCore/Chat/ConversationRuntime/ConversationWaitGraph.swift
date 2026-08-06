// ============================================================================
// ConversationWaitGraph.swift
// ============================================================================
// ETOS LLM Studio
//
// 检测持久等待边是否形成环。递归深度不受限制，但同步等待图必须保持无环。
// ============================================================================

import Foundation

enum ConversationWaitGraph {
    static func wouldCreateCycle(
        waitingRunID: UUID,
        targetRunID: UUID,
        existingEdges: [(waitingRunID: UUID, targetRunID: UUID)]
    ) -> Bool {
        if waitingRunID == targetRunID {
            return true
        }

        var adjacency: [UUID: [UUID]] = [:]
        for edge in existingEdges {
            adjacency[edge.waitingRunID, default: []].append(edge.targetRunID)
        }
        adjacency[waitingRunID, default: []].append(targetRunID)

        var pending = [targetRunID]
        var visited = Set<UUID>()
        while let current = pending.popLast() {
            if current == waitingRunID {
                return true
            }
            guard visited.insert(current).inserted else { continue }
            pending.append(contentsOf: adjacency[current] ?? [])
        }
        return false
    }
}
