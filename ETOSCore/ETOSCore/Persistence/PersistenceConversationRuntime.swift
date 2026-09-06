// ============================================================================
// PersistenceConversationRuntime.swift
// ============================================================================
// ETOS LLM Studio
//
// 长期会话协作持久化的公开门面；数据库细节按领域拆分在相邻文件中。
// ============================================================================

import Foundation
import os.log

extension Persistence {
    private static func markConversationRuntimeChanged() {
        WatchDatabaseSyncService.markDatabaseChanged(.chat)
        postCloudSyncLocalDataDidChange()
    }

    // MARK: - 消息

    public static func appendConversationMessage(
        _ message: ChatMessage,
        to sessionID: UUID
    ) throws -> ChatMessage {
        guard let store = activeGRDBStore() else {
            throw ConversationRuntimeError.persistenceUnavailable
        }
        let storedMessage = try store.appendConversationMessageAtomically(message, to: sessionID)
        markConversationRuntimeChanged()
        return storedMessage
    }

    public static func upsertConversationMessage(
        _ message: ChatMessage,
        to sessionID: UUID,
        afterMessageID: UUID? = nil
    ) throws -> ChatMessage {
        guard let store = activeGRDBStore() else {
            throw ConversationRuntimeError.persistenceUnavailable
        }
        let storedMessage = try store.upsertConversationMessageAtomically(
            message,
            to: sessionID,
            afterMessageID: afterMessageID
        )
        markConversationRuntimeChanged()
        return storedMessage
    }

    public static func deleteConversationMessage(id messageID: UUID, from sessionID: UUID) throws -> Bool {
        guard let store = activeGRDBStore() else {
            throw ConversationRuntimeError.persistenceUnavailable
        }
        let deleted = try store.deleteConversationMessageAtomically(id: messageID, from: sessionID)
        if deleted { markConversationRuntimeChanged() }
        return deleted
    }

    // MARK: - 来源与授权

    @discardableResult
    public static func saveConversationOrigin(_ origin: ConversationOrigin) -> Bool {
        guard let store = activeGRDBStore() else { return false }
        do {
            try store.upsertConversationOrigin(origin)
            markConversationRuntimeChanged()
            return true
        } catch {
            logger.error("保存会话来源失败: \(error.localizedDescription)")
            return false
        }
    }

    public static func loadConversationOrigin(childSessionID: UUID) -> ConversationOrigin? {
        try? activeGRDBStore()?.loadConversationOrigin(childSessionID: childSessionID)
    }

    public static func loadChildConversationOrigins(parentSessionID: UUID) -> [ConversationOrigin] {
        (try? activeGRDBStore()?.loadChildConversationOrigins(parentSessionID: parentSessionID)) ?? []
    }

    @discardableResult
    public static func saveConversationCapability(_ capability: ConversationCapability) -> Bool {
        guard let store = activeGRDBStore() else { return false }
        do {
            try store.upsertConversationCapability(capability)
            markConversationRuntimeChanged()
            return true
        } catch {
            logger.error("保存跨会话授权失败: \(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    public static func revokeConversationCapability(sourceSessionID: UUID, targetSessionID: UUID) -> Bool {
        guard let store = activeGRDBStore() else { return false }
        do {
            try store.revokeConversationCapability(
                sourceSessionID: sourceSessionID,
                targetSessionID: targetSessionID,
                revokedAt: Date()
            )
            markConversationRuntimeChanged()
            return true
        } catch {
            logger.error("撤销跨会话授权失败: \(error.localizedDescription)")
            return false
        }
    }

    public static func loadConversationCapability(
        sourceSessionID: UUID,
        targetSessionID: UUID
    ) -> ConversationCapability? {
        try? activeGRDBStore()?.loadConversationCapability(
            sourceSessionID: sourceSessionID,
            targetSessionID: targetSessionID
        )
    }

    public static func loadLinkedConversationContacts(sourceSessionID: UUID) -> [LinkedConversationContact] {
        (try? activeGRDBStore()?.loadLinkedConversationContacts(sourceSessionID: sourceSessionID)) ?? []
    }

    // MARK: - Run

    @discardableResult
    public static func saveConversationRun(_ run: ConversationRun) -> Bool {
        guard let store = activeGRDBStore() else { return false }
        do {
            try store.upsertConversationRun(run)
            markConversationRuntimeChanged()
            return true
        } catch {
            logger.error("保存会话 Run 失败: \(error.localizedDescription)")
            return false
        }
    }

    public static func loadConversationRun(id: UUID) -> ConversationRun? {
        try? activeGRDBStore()?.loadConversationRun(id: id)
    }

    public static func loadConversationRun(triggerEventID: UUID) -> ConversationRun? {
        try? activeGRDBStore()?.loadConversationRun(triggerEventID: triggerEventID)
    }

    public static func loadLatestConversationRun(sessionID: UUID) -> ConversationRun? {
        try? activeGRDBStore()?.loadLatestConversationRun(sessionID: sessionID)
    }

    public static func loadActiveConversationRuns() -> [ConversationRun] {
        (try? activeGRDBStore()?.loadActiveConversationRuns()) ?? []
    }

    public static func loadConversationRuntimeSessionStates() -> [ConversationRuntimeSessionState] {
        (try? activeGRDBStore()?.loadConversationRuntimeSessionStates()) ?? []
    }

    @discardableResult
    public static func updateConversationRunStatus(
        id: UUID,
        status: ConversationRunStatus,
        executorDeviceID: String? = nil,
        loadingMessageID: UUID? = nil,
        errorMessage: String? = nil
    ) -> Bool {
        guard let store = activeGRDBStore() else { return false }
        do {
            try store.updateConversationRunStatus(
                id: id,
                status: status,
                executorDeviceID: executorDeviceID,
                loadingMessageID: loadingMessageID,
                errorMessage: errorMessage
            )
            markConversationRuntimeChanged()
            return true
        } catch {
            logger.error("更新会话 Run 状态失败: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - 邮箱事件

    @discardableResult
    public static func saveConversationEvent(_ event: ConversationEvent) -> Bool {
        guard let store = activeGRDBStore() else { return false }
        do {
            try store.upsertConversationEvent(event)
            markConversationRuntimeChanged()
            return true
        } catch {
            logger.error("保存会话邮箱事件失败: \(error.localizedDescription)")
            return false
        }
    }

    public static func claimNextPendingConversationEvent(
        executorDeviceID: String,
        excludingDestinationSessionIDs: Set<UUID> = []
    ) -> ConversationEvent? {
        do {
            let event = try activeGRDBStore()?.claimNextPendingConversationEvent(
                executorDeviceID: executorDeviceID,
                excludingDestinationSessionIDs: excludingDestinationSessionIDs,
                at: Date()
            )
            if event != nil { markConversationRuntimeChanged() }
            return event
        } catch {
            logger.error("领取会话邮箱事件失败: \(error.localizedDescription)")
            return nil
        }
    }

    public static func loadConversationEvent(id: UUID) -> ConversationEvent? {
        try? activeGRDBStore()?.loadConversationEvent(id: id)
    }

    public static func loadPendingConversationEvents(
        destinationSessionID: UUID? = nil
    ) -> [ConversationEvent] {
        (try? activeGRDBStore()?.loadPendingConversationEvents(
            destinationSessionID: destinationSessionID
        )) ?? []
    }

    @discardableResult
    public static func updateConversationEventState(
        id: UUID,
        state: ConversationEventState,
        executorDeviceID: String? = nil
    ) -> Bool {
        guard let store = activeGRDBStore() else { return false }
        do {
            try store.updateConversationEventState(
                id: id,
                state: state,
                executorDeviceID: executorDeviceID
            )
            markConversationRuntimeChanged()
            return true
        } catch {
            logger.error("更新会话邮箱事件失败: \(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    public static func acknowledgeConversationEvents(
        destinationSessionID: UUID,
        sourceSessionID: UUID
    ) -> Bool {
        guard let store = activeGRDBStore() else { return false }
        do {
            try store.acknowledgeConversationEvents(
                destinationSessionID: destinationSessionID,
                sourceSessionID: sourceSessionID,
                at: Date()
            )
            markConversationRuntimeChanged()
            return true
        } catch {
            logger.error("确认会话邮箱事件失败: \(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    public static func resetOrphanedClaimedConversationEvents() -> Int {
        do {
            let count = try activeGRDBStore()?.resetOrphanedClaimedConversationEvents() ?? 0
            if count > 0 { markConversationRuntimeChanged() }
            return count
        } catch {
            logger.error("恢复未完成的会话邮箱事件失败: \(error.localizedDescription)")
            return 0
        }
    }

    // MARK: - 委托与等待

    @discardableResult
    public static func saveConversationDelegation(_ delegation: ConversationDelegation) -> Bool {
        guard let store = activeGRDBStore() else { return false }
        do {
            try store.upsertConversationDelegation(delegation)
            markConversationRuntimeChanged()
            return true
        } catch {
            logger.error("保存会话委托失败: \(error.localizedDescription)")
            return false
        }
    }

    public static func loadConversationDelegation(id: UUID) -> ConversationDelegation? {
        try? activeGRDBStore()?.loadConversationDelegation(id: id)
    }

    public static func loadPendingDelegations(targetRunID: UUID) -> [ConversationDelegation] {
        (try? activeGRDBStore()?.loadPendingDelegations(targetRunID: targetRunID)) ?? []
    }

    public static func loadResolvableConversationDelegations() -> [ConversationDelegation] {
        (try? activeGRDBStore()?.loadResolvableConversationDelegations()) ?? []
    }

    public static func loadPendingConversationDelegations(
        targetSessionID: UUID
    ) -> [ConversationDelegation] {
        (try? activeGRDBStore()?.loadPendingConversationDelegations(
            targetSessionID: targetSessionID
        )) ?? []
    }

    @discardableResult
    public static func saveConversationWait(_ wait: ConversationWait) -> Bool {
        guard let store = activeGRDBStore() else { return false }
        do {
            try store.upsertConversationWait(wait)
            markConversationRuntimeChanged()
            return true
        } catch {
            logger.error("保存会话等待关系失败: \(error.localizedDescription)")
            return false
        }
    }

    public static func loadConversationWaits(waitingRunID: UUID) -> [ConversationWait] {
        (try? activeGRDBStore()?.loadConversationWaits(waitingRunID: waitingRunID)) ?? []
    }

    public static func loadConversationWaits(waitGroupID: UUID) -> [ConversationWait] {
        (try? activeGRDBStore()?.loadConversationWaits(waitGroupID: waitGroupID)) ?? []
    }

    public static func loadPendingConversationWaits(targetRunID: UUID) -> [ConversationWait] {
        (try? activeGRDBStore()?.loadPendingConversationWaits(targetRunID: targetRunID)) ?? []
    }

    public static func loadPendingConversationWaits(targetSessionID: UUID) -> [ConversationWait] {
        (try? activeGRDBStore()?.loadPendingConversationWaits(targetSessionID: targetSessionID)) ?? []
    }

    public static func loadConversationRunsWithPendingWaits() -> [ConversationRun] {
        (try? activeGRDBStore()?.loadConversationRunsWithPendingWaits()) ?? []
    }

    public static func loadPendingConversationWaitEdges() -> [(waitingRunID: UUID, targetRunID: UUID)] {
        (try? activeGRDBStore()?.loadPendingConversationWaitEdges()) ?? []
    }

    // MARK: - 执行预算

    @discardableResult
    public static func saveConversationExecutionBudget(_ budget: ConversationExecutionBudget) -> Bool {
        guard let store = activeGRDBStore() else { return false }
        do {
            try store.upsertConversationExecutionBudget(budget)
            markConversationRuntimeChanged()
            return true
        } catch {
            logger.error("保存会话执行预算失败: \(error.localizedDescription)")
            return false
        }
    }

    public static func loadConversationExecutionBudget(
        rootRunID: UUID
    ) -> ConversationExecutionBudget? {
        try? activeGRDBStore()?.loadConversationExecutionBudget(rootRunID: rootRunID)
    }

    public static func consumeConversationExecutionBudget(
        rootRunID: UUID,
        defaultMaximum: Int
    ) throws -> ConversationExecutionBudget {
        guard let store = activeGRDBStore() else {
            throw ConversationRuntimeError.persistenceUnavailable
        }
        let budget = try store.consumeConversationExecutionBudget(
            rootRunID: rootRunID,
            defaultMaximum: defaultMaximum,
            at: Date()
        )
        markConversationRuntimeChanged()
        return budget
    }

    @discardableResult
    public static func extendConversationExecutionBudget(
        rootRunID: UUID,
        additionalExecutions: Int
    ) -> Bool {
        guard let store = activeGRDBStore() else { return false }
        do {
            try store.extendConversationExecutionBudget(
                rootRunID: rootRunID,
                additionalExecutions: additionalExecutions,
                at: Date()
            )
            markConversationRuntimeChanged()
            return true
        } catch {
            logger.error("扩展会话执行预算失败: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - 组合事务

    @discardableResult
    public static func createConversationRuntimeBundle(
        targetSession: ChatSession? = nil,
        targetMessages: [ChatMessage] = [],
        groupingFolder: SessionFolder? = nil,
        groupingRootSessionID: UUID? = nil,
        origin: ConversationOrigin?,
        capabilities: [ConversationCapability],
        targetRun: ConversationRun?,
        event: ConversationEvent?,
        delegation: ConversationDelegation?,
        waits: [ConversationWait],
        waitingRunID: UUID?
    ) -> Bool {
        guard let store = activeGRDBStore() else { return false }
        do {
            try store.createConversationRuntimeBundle(
                targetSession: targetSession,
                targetMessages: targetMessages,
                groupingFolder: groupingFolder,
                groupingRootSessionID: groupingRootSessionID,
                origin: origin,
                capabilities: capabilities,
                targetRun: targetRun,
                event: event,
                delegation: delegation,
                waits: waits,
                waitingRunID: waitingRunID
            )
            markConversationRuntimeChanged()
            return true
        } catch {
            logger.error("创建会话协作关系失败: \(error.localizedDescription)")
            return false
        }
    }
}
