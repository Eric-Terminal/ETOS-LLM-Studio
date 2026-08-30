// ============================================================================
// AgentToolCapabilityPolicy.swift
// ============================================================================
// ETOS LLM Studio
//
// Chat / Agent 只描述本地 Linux 是否加入本次请求。浏览器、会话协作等普通
// 聊天工具仍服从各自的工具开关，不能因为选择 Chat 就被一并关闭。
// ============================================================================

import Foundation

struct AgentToolCapabilityPolicy: Equatable, Sendable {
    let preparesAgentRun: Bool
    let includesConversationTools: Bool
    let includesBrowserTools: Bool
    let includesLocalLinuxTools: Bool

    static func resolve(
        mode: LocalAgentMode,
        isToolContextIsolated: Bool,
        localLinuxEnabled: Bool
    ) -> AgentToolCapabilityPolicy {
        let allowsChatTools = !isToolContextIsolated
        let includesLocalLinux = allowsChatTools && localLinuxEnabled && mode == .agent
        return AgentToolCapabilityPolicy(
            preparesAgentRun: includesLocalLinux,
            includesConversationTools: allowsChatTools,
            includesBrowserTools: allowsChatTools,
            includesLocalLinuxTools: includesLocalLinux
        )
    }
}
