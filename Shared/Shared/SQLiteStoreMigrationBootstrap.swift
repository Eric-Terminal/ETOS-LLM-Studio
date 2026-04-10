// ============================================================================
// SQLiteStoreMigrationBootstrap.swift
// ============================================================================
// 启动阶段触发各 JSON 存储向 SQLite 的迁移。
// ============================================================================

import Foundation
import os.log

public enum SQLiteStoreMigrationBootstrap {
    private static let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "SQLiteMigration")

    public static func migrateJSONStoresIfNeeded() {
        Persistence.bootstrapGRDBStoreOnLaunch()

        _ = WorldbookStore.shared.loadWorldbooks()
        _ = ShortcutToolStore.loadTools()
        _ = FeedbackStore.loadTickets()
        _ = ConfigLoader.loadProviders()
        _ = MCPServerStore.loadServers()
        _ = MemoryRawStore().loadMemories()
        _ = ConversationMemoryManager.loadUserProfile()

        logger.info("已触发启动期 JSON→SQLite 迁移检查。")
    }
}
