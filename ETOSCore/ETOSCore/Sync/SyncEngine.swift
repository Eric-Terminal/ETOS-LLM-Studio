// ============================================================================
// SyncEngine.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件承载跨端同步引擎的共享常量，具体打包与合并逻辑由扩展文件实现。
// ============================================================================

import Foundation

public enum SyncEngine {
    static let legacyGlobalSystemPromptKey = "systemPrompt"
    static let conversationUserProfileRecordID = "conversation.user.profile"
    static let appStorageExcludedExactKeys: Set<String> = [
        "cloudSync.deviceIdentifier",
        "cloudSync.appliedSnapshotChecksums",
        "cloudSync.snapshotChangeToken",
        "cloudSync.recordZoneChangeToken.v3",
        "cloudSync.accountIdentifier.v3",
        "cloudSync.publishedRecordState.v3"
    ]
    static let appStorageExcludedPrefixes: [String] = [
        "sync.delta.version-tracker.",
        "sync.delta.checkpoint."
    ]

    public static var currentPlatformName: String {
        #if os(watchOS)
        return "watchOS"
        #elseif os(iOS)
        return "iOS"
        #else
        return "远端"
        #endif
    }
}
