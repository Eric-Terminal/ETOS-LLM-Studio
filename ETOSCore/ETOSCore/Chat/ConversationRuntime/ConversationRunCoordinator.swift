// ============================================================================
// ConversationRunCoordinator.swift
// ============================================================================
// ETOS LLM Studio
//
// 以 GRDB 邮箱为事实来源调度跨会话 Run。Observation 只负责唤醒；事件领取、
// 预算、等待满足与恢复状态都持久化，因此不依赖常驻轮询或内存 continuation。
// ============================================================================

import Foundation
import Combine
import GRDB
import os.log

actor ConversationRunCoordinator {
    static let shared = ConversationRunCoordinator()

    private enum EventExecutionOutcome {
        case processed
        case deferred
    }

    private let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "ConversationRunCoordinator")
    private weak var chatService: ChatService?
    private var observation: AnyDatabaseCancellable?
    private var runningEventIDs = Set<UUID>()
    private var runningEventSessionIDs: [UUID: UUID] = [:]
    private var isDraining = false
    private var needsAnotherDrain = false
    private var didRecover = false

    func start(chatService: ChatService) async {
        self.chatService = chatService
        if !didRecover {
            recoverInterruptedState()
            didRecover = true
        }
        if observation == nil {
            observation = Persistence.observeConversationRuntime(
                onError: { error in
                    Logger(
                        subsystem: "com.ETOS.LLM.Studio",
                        category: "ConversationRunCoordinator"
                    ).error("会话运行时观察失败：\(error.localizedDescription)")
                },
                onChange: { _ in
                    Task {
                        await ConversationRunCoordinator.shared.signal()
                    }
                }
            )
        }
        await signal()
    }

    func signal() async {
        guard chatService != nil else { return }
        if isDraining {
            needsAnotherDrain = true
            return
        }
        isDraining = true
        repeat {
            needsAnotherDrain = false
            await reconcileTerminalRuns()
            await publishRuntimeStates()
            await drainPendingEvents()
        } while needsAnotherDrain
        isDraining = false
    }

    private func recoverInterruptedState() {
        for run in Persistence.loadActiveConversationRuns() {
            switch run.status {
            case .running, .waitingTool:
                _ = Persistence.updateConversationRunStatus(
                    id: run.id,
                    status: .interrupted,
                    errorMessage: NSLocalizedString(
                        "App 上次退出时回复仍在执行，已保留现场但不会自动重放。",
                        comment: "Recovered interrupted conversation run"
                    )
                )
                if let eventID = run.triggerEventID {
                    _ = Persistence.updateConversationEventState(id: eventID, state: .processed)
                }
            case .queued, .waitingConversation, .waitingUser, .pausedByBudget:
                break
            case .completed, .failed, .cancelled, .interrupted:
                break
            }
        }
        let resetCount = Persistence.resetOrphanedClaimedConversationEvents()
        if resetCount > 0 {
            logger.info("已恢复 \(resetCount) 个未完成的会话邮箱事件。")
        }
    }

    private func drainPendingEvents() async {
        guard let chatService else { return }
        let concurrencyLimit = max(
            1,
            Persistence.readAppConfigInteger(
                key: AppConfigKey.conversationRuntimeConcurrencyLimit.rawValue
            ) ?? defaultConcurrencyLimit
        )

        while occupiedModelSessionCount(chatService: chatService) < concurrencyLimit,
              let event = Persistence.claimNextPendingConversationEvent(
                  executorDeviceID: UsageAnalyticsRuntimeContext.currentDeviceIdentifier(),
                  excludingDestinationSessionIDs: chatService.activeRequestSessionIDs()
              ) {
            runningEventIDs.insert(event.id)
            runningEventSessionIDs[event.id] = event.destinationSessionID
            Task { [weak self, weak chatService] in
                guard let self, let chatService else { return }
                let outcome = await self.execute(event: event, chatService: chatService)
                await self.finish(event: event, outcome: outcome)
            }
        }
    }

    private func execute(
        event: ConversationEvent,
        chatService: ChatService
    ) async -> EventExecutionOutcome {
        switch event.deliveryPolicy {
        case .deliverOnly:
            return .processed
        case .respondWhenIdle:
            guard !chatService.hasActiveRequestContext(for: event.destinationSessionID) else {
                return .deferred
            }
            guard var run = Persistence.loadConversationRun(triggerEventID: event.id),
                  let inputMessageID = event.messageID else {
                return .processed
            }
            if run.status == .pausedByBudget || run.status.isTerminal {
                return .processed
            }
            do {
                _ = try ConversationExecutionBudgetPolicy.consume(rootRunID: run.rootRunID)
            } catch ConversationRuntimeError.executionBudgetExhausted {
                _ = Persistence.updateConversationRunStatus(id: run.id, status: .pausedByBudget)
                return .processed
            } catch {
                _ = Persistence.updateConversationRunStatus(
                    id: run.id,
                    status: .failed,
                    errorMessage: error.localizedDescription
                )
                return .processed
            }

            run.status = .running
            run.startedAt = run.startedAt ?? Date()
            run.executorDeviceID = UsageAnalyticsRuntimeContext.currentDeviceIdentifier()
            _ = Persistence.saveConversationRun(run)
            let configuration = run.requestConfiguration
            await chatService.sendAndProcessMessage(
                content: "",
                aiTemperature: configuration.temperature,
                aiTopP: configuration.topP,
                systemPrompt: configuration.systemPrompt,
                maxChatHistory: configuration.maxChatHistory,
                enableStreaming: configuration.enableStreaming,
                enhancedPrompt: configuration.enhancedPrompt,
                enableMemory: configuration.enableMemory,
                enableMemoryWrite: configuration.enableMemoryWrite,
                enableMemoryActiveRetrieval: configuration.enableMemoryActiveRetrieval,
                includeSystemTime: configuration.includeSystemTime,
                systemTimeInjectionPosition: configuration.systemTimeInjectionPosition,
                enablePeriodicTimeLandmark: configuration.enablePeriodicTimeLandmark,
                periodicTimeLandmarkIntervalMinutes: configuration.periodicTimeLandmarkIntervalMinutes,
                enableResponseSpeedMetrics: configuration.enableResponseSpeedMetrics,
                targetSessionID: run.sessionID,
                messageAuthorKind: .conversation,
                sourceSessionID: event.sourceSessionID,
                conversationEventID: event.id,
                conversationRun: run,
                existingInputMessageID: inputMessageID
            )
            return .processed
        case .triggerContinuation:
            guard !chatService.hasActiveRequestContext(for: event.destinationSessionID) else {
                return .deferred
            }
            guard let waitGroupID = event.correlationID,
                  let firstWait = Persistence.loadConversationWaits(waitGroupID: waitGroupID).first,
                  let waitingRun = Persistence.loadConversationRun(id: firstWait.waitingRunID) else {
                return .processed
            }
            guard waitingRun.status == .waitingConversation || waitingRun.status == .pausedByBudget else {
                return .processed
            }
            let waits = Persistence.loadConversationWaits(waitGroupID: waitGroupID)
            let result = waitResultJSON(waits: waits, chatService: chatService)
            let sourceMessageID = waits.compactMap(\.resultMessageID).first
            let sourceSessionID = waits.first(where: { $0.resultMessageID != nil })?.targetSessionID
            let resumed = await chatService.resumeConversationRun(
                waitingRun,
                toolCallID: firstWait.toolCallID,
                result: result,
                sourceSessionID: sourceSessionID,
                sourceMessageID: sourceMessageID
            )
            return resumed ? .processed : .deferred
        }
    }

    private func finish(event: ConversationEvent, outcome: EventExecutionOutcome) async {
        runningEventIDs.remove(event.id)
        runningEventSessionIDs.removeValue(forKey: event.id)
        switch outcome {
        case .processed:
            _ = Persistence.updateConversationEventState(
                id: event.id,
                state: .processed,
                executorDeviceID: UsageAnalyticsRuntimeContext.currentDeviceIdentifier()
            )
            await reconcileTerminalRuns()
            await publishRuntimeStates()
            await signal()
        case .deferred:
            _ = Persistence.updateConversationEventState(id: event.id, state: .pending)
        }
    }

    private func reconcileTerminalRuns() async {
        guard let chatService else { return }
        for delegation in Persistence.loadResolvableConversationDelegations() {
            guard let targetRunID = delegation.targetRunID,
                  let targetRun = Persistence.loadConversationRun(id: targetRunID) else {
                continue
            }
            await resolve(delegation: delegation, targetRun: targetRun, chatService: chatService)
        }
        for targetRun in Persistence.loadConversationRunsWithPendingWaits() {
            satisfyWaits(for: targetRun, chatService: chatService)
        }
    }

    private func resolve(
        delegation: ConversationDelegation,
        targetRun: ConversationRun,
        chatService: ChatService
    ) async {
        let reply = replyMessage(for: targetRun, chatService: chatService)
        let succeeded = targetRun.status == .completed
        if delegation.executionMode == .background || delegation.executionMode == .backgroundContinue {
            let deliveredMessage = await deliveredBackgroundMessage(
                delegation: delegation,
                targetRun: targetRun,
                reply: reply,
                chatService: chatService
            )
            let eventID = delegation.id
            let shouldContinue = delegation.executionMode == .backgroundContinue
            var continuationRun: ConversationRun?
            if shouldContinue,
               Persistence.loadConversationRun(triggerEventID: eventID) == nil,
               let sourceRun = Persistence.loadConversationRun(id: delegation.sourceRunID) {
                continuationRun = ConversationRun(
                    sessionID: delegation.sourceSessionID,
                    rootRunID: sourceRun.rootRunID,
                    parentRunID: sourceRun.id,
                    triggerEventID: eventID,
                    status: .queued,
                    requestConfiguration: sourceRun.requestConfiguration
                )
            }
            let deliveryEvent = ConversationEvent(
                id: eventID,
                destinationSessionID: delegation.sourceSessionID,
                sourceSessionID: delegation.targetSessionID,
                sourceRunID: targetRun.id,
                messageID: deliveredMessage?.id,
                correlationID: delegation.id,
                kind: succeeded ? .delegationCompleted : .delegationFailed,
                deliveryPolicy: shouldContinue ? .respondWhenIdle : .deliverOnly,
                payloadJSON: delegationResultJSON(targetRun: targetRun, reply: reply)
            )
            guard Persistence.createConversationRuntimeBundle(
                origin: nil,
                capabilities: [],
                targetRun: continuationRun,
                event: deliveryEvent,
                delegation: nil,
                waits: [],
                waitingRunID: nil
            ) else {
                return
            }
        }

        var updated = delegation
        updated.replyMessageID = reply?.id
        updated.status = succeeded ? .completed : .failed
        updated.completedAt = Date()
        _ = Persistence.saveConversationDelegation(updated)
        satisfyWaits(for: targetRun, chatService: chatService)
    }

    private func satisfyWaits(for targetRun: ConversationRun, chatService: ChatService) {
        let pendingWaits = Persistence.loadPendingConversationWaits(targetRunID: targetRun.id)
        guard !pendingWaits.isEmpty else { return }
        let reply = replyMessage(for: targetRun, chatService: chatService)
        let succeeded = targetRun.status == .completed
        let affectedGroupIDs = Set(pendingWaits.map(\.waitGroupID))

        for groupID in affectedGroupIDs {
            var group = Persistence.loadConversationWaits(waitGroupID: groupID)
            guard let first = group.first,
                  let waitingRun = Persistence.loadConversationRun(id: first.waitingRunID) else {
                continue
            }
            for index in group.indices
                where group[index].targetRunID == targetRun.id && group[index].status == .pending {
                group[index].status = succeeded ? .satisfied : .failed
                group[index].resultMessageID = reply?.id
            }
            let isComplete: Bool
            switch first.completionMode {
            case .all:
                isComplete = group.allSatisfy { $0.status != .pending }
            case .any:
                isComplete = group.contains { $0.status == .satisfied }
                    || group.allSatisfy { $0.status != .pending }
                if group.contains(where: { $0.status == .satisfied }) {
                    for index in group.indices where group[index].status == .pending {
                        group[index].status = .cancelled
                    }
                }
            }
            let groupSucceeded: Bool
            switch first.completionMode {
            case .all:
                groupSucceeded = group.allSatisfy { $0.status == .satisfied }
            case .any:
                groupSucceeded = group.contains { $0.status == .satisfied }
            }
            let continuationEvent: ConversationEvent? = isComplete
                ? ConversationEvent(
                    id: groupID,
                    destinationSessionID: waitingRun.sessionID,
                    sourceSessionID: targetRun.sessionID,
                    sourceRunID: targetRun.id,
                    messageID: reply?.id,
                    correlationID: groupID,
                    kind: groupSucceeded ? .delegationCompleted : .delegationFailed,
                    deliveryPolicy: .triggerContinuation,
                    payloadJSON: waitResultJSON(waits: group, chatService: chatService)
                )
                : nil
            _ = Persistence.createConversationRuntimeBundle(
                origin: nil,
                capabilities: [],
                targetRun: nil,
                event: continuationEvent,
                delegation: nil,
                waits: group,
                waitingRunID: nil
            )
        }
    }

    private func replyMessage(for run: ConversationRun, chatService: ChatService) -> ChatMessage? {
        let messages = chatService.messagesSnapshot(for: run.sessionID)
        guard let loadingMessageID = run.loadingMessageID,
              let message = messages.first(where: { $0.id == loadingMessageID }),
              message.role == .assistant else {
            return nil
        }
        return message
    }

    private func deliveredBackgroundMessage(
        delegation: ConversationDelegation,
        targetRun: ConversationRun,
        reply: ChatMessage?,
        chatService: ChatService
    ) async -> ChatMessage? {
        if let reply,
           let existing = chatService.messagesSnapshot(for: delegation.sourceSessionID).first(where: {
               $0.authorKind == .conversation
                   && $0.sourceSessionID == delegation.targetSessionID
                   && $0.sourceMessageID == reply.id
           }) {
            return existing
        }
        let content = reply?.content.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedContent = (content?.isEmpty == false)
            ? content!
            : targetRun.errorMessage ?? NSLocalizedString("目标会话没有返回正文。", comment: "Empty background conversation reply")
        return try? await chatService.appendConversationMessage(
            ChatMessage(
                role: .user,
                content: resolvedContent,
                authorKind: .conversation,
                sourceSessionID: delegation.targetSessionID,
                sourceMessageID: reply?.id,
                conversationEventID: delegation.id
            ),
            to: delegation.sourceSessionID
        )
    }

    private func delegationResultJSON(targetRun: ConversationRun, reply: ChatMessage?) -> String {
        JSONValue.dictionary([
            "conversation_id": .string(targetRun.sessionID.uuidString),
            "run_id": .string(targetRun.id.uuidString),
            "status": .string(targetRun.status.rawValue),
            "reply": .string(reply?.content ?? ""),
            "error": targetRun.errorMessage.map { .string($0) } ?? .null
        ]).prettyPrintedCompact()
    }

    private func waitResultJSON(waits: [ConversationWait], chatService: ChatService) -> String {
        let items: [JSONValue] = waits.map { wait in
            let run = wait.targetRunID.flatMap { Persistence.loadConversationRun(id: $0) }
            let reply = run.flatMap { replyMessage(for: $0, chatService: chatService) }
            return .dictionary([
                "conversation_id": .string(wait.targetSessionID.uuidString),
                "run_id": wait.targetRunID.map { .string($0.uuidString) } ?? .null,
                "status": .string(wait.status.rawValue),
                "reply": .string(reply?.content ?? ""),
                "reply_message_id": wait.resultMessageID.map { .string($0.uuidString) } ?? .null,
                "error": run?.errorMessage.map { .string($0) } ?? .null
            ])
        }
        let succeeded: Bool
        if let completionMode = waits.first?.completionMode {
            switch completionMode {
            case .all:
                succeeded = waits.allSatisfy { $0.status == .satisfied }
            case .any:
                succeeded = waits.contains { $0.status == .satisfied }
            }
        } else {
            succeeded = false
        }
        return JSONValue.dictionary([
            "status": .string(succeeded ? "completed" : "failed"),
            "results": .array(items)
        ]).prettyPrintedCompact()
    }

    private var defaultConcurrencyLimit: Int {
        #if os(watchOS)
        return 1
        #else
        return 3
        #endif
    }

    private func occupiedModelSessionCount(chatService: ChatService) -> Int {
        var sessionIDs = chatService.activeRequestSessionIDs()
        sessionIDs.formUnion(runningEventSessionIDs.values)
        return sessionIDs.count
    }

    private func publishRuntimeStates() async {
        guard let chatService else { return }
        let states = Dictionary(
            uniqueKeysWithValues: Persistence.loadConversationRuntimeSessionStates().map { ($0.sessionID, $0) }
        )
        await MainActor.run {
            chatService.conversationRuntimeStatesSubject.send(states)
        }
    }
}
