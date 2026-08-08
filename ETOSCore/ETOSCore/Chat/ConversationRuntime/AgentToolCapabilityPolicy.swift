// ============================================================================
// AgentToolCapabilityPolicy.swift
// ============================================================================
// ETOS LLM Studio
//
// Agent 模式和具体工具能力分开判定。Browser Agent 是原生能力，不因 Linux
// 关闭而消失；只有 Linux 命令、Linux 文件和本地 stdio MCP 依赖该开关。
// ============================================================================

import Foundation

struct AgentToolCapabilityPolicy: Equatable, Sendable {
    let preparesAgentRun: Bool
    let includesConversationTools: Bool
    let includesBrowserTools: Bool
    let includesLocalLinuxTools: Bool

    static func resolve(
        mode: LocalAgentMode,
        isWorldbookContextIsolated: Bool,
        localLinuxEnabled: Bool
    ) -> AgentToolCapabilityPolicy {
        let isAgent = mode == .agent && !isWorldbookContextIsolated
        return AgentToolCapabilityPolicy(
            preparesAgentRun: isAgent,
            includesConversationTools: isAgent,
            includesBrowserTools: isAgent,
            includesLocalLinuxTools: isAgent && localLinuxEnabled
        )
    }
}
