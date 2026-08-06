// ============================================================================
// ConversationRuntimeControls.swift
// ============================================================================
// ETOS LLM Studio
//
// 用户对长期会话运行时的显式控制。用户是所有会话的最终所有者，因此这些
// 操作不经过模型 Capability 检查。
// ============================================================================

import Foundation

extension ChatService {
    func prepareConversationRuntimeForSessionDeletion(_ sessionID: UUID) {
        let affectedWaits = Persistence.loadPendingConversationWaits(targetSessionID: sessionID)
        let groupIDs = Set(affectedWaits.map(\.waitGroupID))
        for groupID in groupIDs {
            var group = Persistence.loadConversationWaits(waitGroupID: groupID)
            guard let first = group.first else { continue }
            for index in group.indices
                where group[index].targetSessionID == sessionID && group[index].status == .pending {
                group[index].status = .failed
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

            let succeeded = first.completionMode == .all
                ? group.allSatisfy { $0.status == .satisfied }
                : group.contains { $0.status == .satisfied }
            let resultWait = group.first(where: { $0.resultMessageID != nil })
            let continuationEvent = isComplete
                ? Persistence.loadConversationRun(id: first.waitingRunID).map { waitingRun in
                    ConversationEvent(
                        id: groupID,
                        destinationSessionID: waitingRun.sessionID,
                        sourceSessionID: resultWait?.targetSessionID ?? sessionID,
                        messageID: resultWait?.resultMessageID,
                        correlationID: groupID,
                        kind: succeeded ? .delegationCompleted : .delegationFailed,
                        deliveryPolicy: .triggerContinuation,
                        payloadJSON: JSONValue.dictionary([
                            "status": .string(succeeded ? "completed" : "failed"),
                            "error": .string(NSLocalizedString("目标会话已被用户删除。", comment: "Deleted conversation wait error"))
                        ]).prettyPrintedCompact()
                    )
                }
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
        for var delegation in Persistence.loadPendingConversationDelegations(targetSessionID: sessionID) {
            delegation.status = .failed
            delegation.completedAt = Date()
            _ = Persistence.saveConversationDelegation(delegation)
        }
        for run in Persistence.loadActiveConversationRuns() where run.sessionID == sessionID {
            for var wait in Persistence.loadConversationWaits(waitingRunID: run.id)
                where wait.status == .pending {
                wait.status = .cancelled
                _ = Persistence.saveConversationWait(wait)
            }
            _ = Persistence.updateConversationRunStatus(id: run.id, status: .cancelled)
        }
    }

    public func stopConversationRuntime(for sessionID: UUID) async {
        if hasActiveRequestContext(for: sessionID) {
            await cancelRequest(for: sessionID)
        }
        if let run = Persistence.loadLatestConversationRun(sessionID: sessionID),
           !run.status.isTerminal {
            for var wait in Persistence.loadConversationWaits(waitingRunID: run.id)
                where wait.status == .pending {
                wait.status = .cancelled
                _ = Persistence.saveConversationWait(wait)
            }
            _ = Persistence.updateConversationRunStatus(id: run.id, status: .cancelled)
        }
        for event in Persistence.loadPendingConversationEvents(destinationSessionID: sessionID) {
            _ = Persistence.updateConversationEventState(id: event.id, state: .cancelled)
        }
        await ConversationRunCoordinator.shared.signal()
    }

    @discardableResult
    public func continueConversationRuntime(for sessionID: UUID) async -> Bool {
        guard let run = Persistence.loadLatestConversationRun(sessionID: sessionID),
              run.status == .pausedByBudget,
              Persistence.extendConversationExecutionBudget(
                  rootRunID: run.rootRunID,
                  additionalExecutions: ConversationExecutionBudgetPolicy.configuredMaximumExecutions()
              ) else {
            return false
        }

        let messages = messagesSnapshot(for: sessionID)
        let waitingToolCallID = Persistence.loadConversationWaits(waitingRunID: run.id).first?.toolCallID
        if let loadingMessageID = run.loadingMessageID,
           let assistantMessage = messages.first(where: { $0.id == loadingMessageID }),
           let completedCall = assistantMessage.toolCalls?.first(where: {
               $0.result != nil && (waitingToolCallID == nil || $0.id == waitingToolCallID)
           }),
           let result = completedCall.result {
            _ = Persistence.updateConversationRunStatus(id: run.id, status: .waitingConversation)
            let resumed = await resumeConversationRun(
                run,
                toolCallID: completedCall.id,
                result: result,
                sourceSessionID: messages.last(where: {
                    $0.role == .tool && $0.toolCalls?.contains(where: { $0.id == completedCall.id }) == true
                })?.sourceSessionID,
                sourceMessageID: messages.last(where: {
                    $0.role == .tool && $0.toolCalls?.contains(where: { $0.id == completedCall.id }) == true
                })?.sourceMessageID
            )
            await ConversationRunCoordinator.shared.signal()
            return resumed
        }

        guard let triggerEventID = run.triggerEventID else { return false }
        _ = Persistence.updateConversationRunStatus(id: run.id, status: .queued)
        _ = Persistence.updateConversationEventState(id: triggerEventID, state: .pending)
        await ConversationRunCoordinator.shared.signal()
        return true
    }
}
