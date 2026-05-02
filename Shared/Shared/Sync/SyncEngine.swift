// ============================================================================
// SyncEngine.swift
// ============================================================================
// 负责根据选项收集同步数据并执行合并逻辑
// - 构建 SyncPackage 供跨设备传输
// - 解析并合并来自对端的数据，处理冲突与去重
// ============================================================================

import Foundation
import Combine

public enum SyncEngine {
    static let legacyGlobalSystemPromptKey = "systemPrompt"
    static let appStorageExcludedExactKeys: Set<String> = [
        "cloudSync.deviceIdentifier",
        "cloudSync.appliedSnapshotChecksums"
    ]
    static let appStorageExcludedPrefixes: [String] = [
        "sync.delta.version-tracker.",
        "sync.delta.checkpoint."
    ]
    
    // MARK: - 打包导出
    
    /// 根据同步选项构建完整同步包
}
