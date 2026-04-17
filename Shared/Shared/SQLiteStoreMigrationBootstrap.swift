// ============================================================================
// SQLiteStoreMigrationBootstrap.swift
// ============================================================================
// 启动阶段触发各 JSON 存储向 SQLite 的迁移。
// ============================================================================

import Foundation
import Combine
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

@MainActor
public final class AppLaunchStateMachine: ObservableObject {
    public enum Phase: Equatable {
        case idle
        case preparingPersistence
        case warmingServices
        case ready
    }

    @Published public private(set) var phase: Phase = .idle
    private var bootstrapTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "LaunchState")

    public init() {}

    deinit {
        bootstrapTask?.cancel()
    }

    public func startIfNeeded() {
        guard phase == .idle else { return }
        guard bootstrapTask == nil else { return }
        phase = .preparingPersistence

        bootstrapTask = Task { [weak self] in
            await Task.detached(priority: .utility) {
                Persistence.bootstrapGRDBStoreOnLaunch()
            }.value

            guard !Task.isCancelled else {
                await MainActor.run {
                    self?.bootstrapTask = nil
                }
                return
            }
            await MainActor.run {
                self?.phase = .warmingServices
            }

            await Task.detached(priority: .utility) {
                let chatService = ChatService.shared
                chatService.loadInitialPersistenceStateIfNeeded()
            }.value

            guard !Task.isCancelled else {
                await MainActor.run {
                    self?.bootstrapTask = nil
                }
                return
            }
            await MainActor.run {
                self?.phase = .ready
                self?.bootstrapTask = nil
                self?.logger.info("启动状态机已完成持久化与服务预热。")
            }
        }
    }
}
