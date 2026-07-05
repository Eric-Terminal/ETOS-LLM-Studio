// ============================================================================
// SyncModelEquivalence.swift
// ============================================================================
// ETOS LLM Studio
//
// 同步导入时用于去重、冲突判断和数据摘要计算的模型等价辅助。
// ============================================================================

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

// MARK: - 模型等价辅助

/// 同步后缀模式（用于识别和移除）
private let syncSuffixPattern = #/（同步副本）|（同步冲突）|（同步）|\s*\[[^\]]+ 分支\]/#

/// 去除字符串中所有同步后缀
private func removeSyncSuffixes(from name: String) -> String {
    var result = name
    while let match = result.firstMatch(of: syncSuffixPattern) {
        result.removeSubrange(match.range)
    }
    return result
}

extension Provider {
    /// 判断两个提供商是否逻辑等价（忽略 ID 与 API Key）
    func isEquivalent(to other: Provider) -> Bool {
        name == other.name &&
        baseURL == other.baseURL &&
        normalizedChatEndpointPath == other.normalizedChatEndpointPath &&
        apiFormat == other.apiFormat &&
        headerOverrides == other.headerOverrides &&
        proxyConfiguration == other.proxyConfiguration &&
        models.count == other.models.count &&
        zip(models, other.models).allSatisfy { $0.isEquivalent(to: $1) }
    }
    
    /// 去除所有同步后缀的基础名称
    var baseNameWithoutSyncSuffix: String {
        removeSyncSuffixes(from: name)
    }
}

extension Model {
    /// 判断两个模型是否逻辑等价（忽略 ID）
    func isEquivalent(to other: Model) -> Bool {
        modelName == other.modelName &&
        displayName == other.displayName &&
        isActivated == other.isActivated &&
        overrideParameters == other.overrideParameters &&
        kind == other.kind &&
        inputModalities == other.inputModalities &&
        outputModalities == other.outputModalities &&
        capabilities == other.capabilities &&
        requestBodyOverrideMode == other.requestBodyOverrideMode &&
        rawRequestBodyJSON == other.rawRequestBodyJSON &&
        requestBodyControls == other.requestBodyControls &&
        pricing?.normalized == other.pricing?.normalized
    }
}

extension ChatSession {
    /// 判断两个会话是否逻辑等价（忽略 ID 与临时状态）
    func isEquivalent(to other: ChatSession) -> Bool {
        name == other.name &&
        topicPrompt == other.topicPrompt &&
        enhancedPrompt == other.enhancedPrompt &&
        folderID == other.folderID &&
        worldbookContextIsolationEnabled == other.worldbookContextIsolationEnabled &&
        Set(lorebookIDs) == Set(other.lorebookIDs) &&
        Set(tagIDs) == Set(other.tagIDs)
    }
    
    /// 去除所有同步后缀的基础名称
    var baseNameWithoutSyncSuffix: String {
        removeSyncSuffixes(from: name)
    }
    
    /// 判断两个会话是否逻辑等价（忽略同步后缀、ID 与临时状态）
    /// 用于同步时判断是否为"同一个"会话的不同版本
    func isEquivalentIgnoringSyncSuffix(to other: ChatSession) -> Bool {
        baseNameWithoutSyncSuffix == other.baseNameWithoutSyncSuffix &&
        topicPrompt == other.topicPrompt &&
        enhancedPrompt == other.enhancedPrompt &&
        folderID == other.folderID &&
        worldbookContextIsolationEnabled == other.worldbookContextIsolationEnabled &&
        Set(lorebookIDs) == Set(other.lorebookIDs) &&
        Set(tagIDs) == Set(other.tagIDs)
    }
}

extension MCPServerConfiguration {
    /// 判断两个 MCP 服务器配置是否逻辑等价（忽略 ID）
    func isEquivalent(to other: MCPServerConfiguration) -> Bool {
        displayName == other.displayName &&
        notes == other.notes &&
        transport == other.transport &&
        isSelectedForChat == other.isSelectedForChat &&
        sortIndex == other.sortIndex &&
        Set(disabledToolIds) == Set(other.disabledToolIds) &&
        toolApprovalPolicies == other.toolApprovalPolicies
    }
    
    /// 去除所有同步后缀的基础名称
    var baseNameWithoutSyncSuffix: String {
        removeSyncSuffixes(from: displayName)
    }
}

extension ShortcutToolDefinition {
    /// 判断两个快捷指令工具配置是否逻辑等价（忽略 ID）
    func isEquivalent(to other: ShortcutToolDefinition) -> Bool {
        ShortcutToolNaming.normalizeExecutableName(name) == ShortcutToolNaming.normalizeExecutableName(other.name) &&
        externalID == other.externalID &&
        metadata == other.metadata &&
        source == other.source &&
        runModeHint == other.runModeHint &&
        isEnabled == other.isEnabled &&
        userDescription == other.userDescription &&
        generatedDescription == other.generatedDescription
    }
}

extension Array where Element == ChatMessage {
    /// 对比两组消息是否完全一致（逐条比较）
    func isContentEqual(to other: [ChatMessage]) -> Bool {
        guard count == other.count else { return false }
        for (lhs, rhs) in zip(self, other) {
            if lhs != rhs { return false }
        }
        return true
    }
}

// MARK: - 数据校验

extension Data {
    /// 计算数据的 SHA256 十六进制摘要，用于快速去重
    var sha256Hex: String {
#if canImport(CryptoKit)
        let digest = SHA256.hash(data: self)
        return digest.map { String(format: "%02x", $0) }.joined()
#else
        return "\(count)" // 回退方案：使用长度占位，确保可编译
#endif
    }
}
