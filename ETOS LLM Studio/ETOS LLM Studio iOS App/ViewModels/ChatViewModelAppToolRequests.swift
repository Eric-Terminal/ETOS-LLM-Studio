// ============================================================================
// ChatViewModelAppToolRequests.swift
// ============================================================================
// 按来源会话接收交互类 App Tool 请求，并把用户补充准确送回原会话。
// ============================================================================

import Foundation
import ETOSCore

extension ChatViewModel {
    func receiveAskUserInputRequest(
        _ request: AppToolAskUserInputRequest,
        receipt: AppToolUIRequestDeliveryReceipt
    ) {
        guard let sessionID = request.sourceSessionID ?? currentSession?.id else { return }
        let isDisplayed = currentSession?.id == sessionID && activeAskUserInputRequest == nil
        guard receipt.claim(isDisplayed ? .displayed : .queued) else { return }

        var requests = askUserInputRequestsBySessionID[sessionID, default: []]
        guard !requests.contains(where: { $0.requestID == request.requestID }) else { return }
        requests.append(request)
        askUserInputRequestsBySessionID[sessionID] = requests
        refreshSessionScopedAppToolRequests()
    }

    func receiveToolInputDraftRequest(
        _ request: AppToolInputDraftRequest,
        receipt: AppToolUIRequestDeliveryReceipt
    ) {
        guard let sessionID = request.sourceSessionID ?? currentSession?.id else { return }
        if currentSession?.id == sessionID {
            guard receipt.claim(.applied) else { return }
            applyToolInputDraftRequest(request)
        } else {
            guard receipt.claim(.queued) else { return }
            toolInputDraftRequestsBySessionID[sessionID, default: []].append(request)
        }
    }

    func refreshSessionScopedAppToolRequests() {
        guard let sessionID = currentSession?.id else {
            activeAskUserInputRequest = nil
            return
        }
        activeAskUserInputRequest = askUserInputRequestsBySessionID[sessionID]?.first

        let drafts = toolInputDraftRequestsBySessionID.removeValue(forKey: sessionID) ?? []
        for draft in drafts {
            applyToolInputDraftRequest(draft)
        }
    }

    func submitAskUserInputAnswers(
        _ answers: [AppToolAskUserInputQuestionAnswer],
        for requestOverride: AppToolAskUserInputRequest? = nil
    ) {
        guard let request = requestOverride ?? activeAskUserInputRequest else { return }
        let submission = AppToolAskUserInputSubmission(
            requestID: request.requestID,
            cancelled: false,
            submittedAt: iso8601Formatter.string(from: Date()),
            answers: answers
        )
        enqueueToolSupplementMessage(
            AppToolAskUserInputSubmissionFormatter.messageContent(
                request: request,
                submission: submission
            ),
            targetSessionID: request.sourceSessionID
        )
        removeAskUserInputRequest(request)
    }

    func cancelAskUserInputRequest(using requestOverride: AppToolAskUserInputRequest? = nil) {
        guard let request = requestOverride ?? activeAskUserInputRequest else { return }
        let submission = AppToolAskUserInputSubmission(
            requestID: request.requestID,
            cancelled: true,
            submittedAt: iso8601Formatter.string(from: Date()),
            answers: []
        )
        enqueueToolSupplementMessage(
            AppToolAskUserInputSubmissionFormatter.messageContent(
                request: request,
                submission: submission
            ),
            targetSessionID: request.sourceSessionID
        )
        removeAskUserInputRequest(request)
    }

    private func removeAskUserInputRequest(_ request: AppToolAskUserInputRequest) {
        guard let sessionID = request.sourceSessionID ?? currentSession?.id else { return }
        var requests = askUserInputRequestsBySessionID[sessionID] ?? []
        requests.removeAll(where: { $0.requestID == request.requestID })
        if requests.isEmpty {
            askUserInputRequestsBySessionID.removeValue(forKey: sessionID)
        } else {
            askUserInputRequestsBySessionID[sessionID] = requests
        }
        refreshSessionScopedAppToolRequests()
    }

    private func enqueueToolSupplementMessage(_ content: String, targetSessionID: UUID?) {
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedSessionID = targetSessionID ?? currentSession?.id
        guard let resolvedSessionID, !trimmedContent.isEmpty else { return }
        pendingToolSupplementMessagesBySessionID[resolvedSessionID, default: []].append(trimmedContent)
        flushPendingToolSupplementMessagesIfPossible()
    }

    func flushPendingToolSupplementMessagesIfPossible() {
        for sessionID in pendingToolSupplementMessagesBySessionID.keys.sorted(by: {
            $0.uuidString < $1.uuidString
        }) {
            guard !runningSessionIDs.contains(sessionID),
                  !dispatchingToolSupplementSessionIDs.contains(sessionID),
                  !(currentSession?.id == sessionID && isSendDelayPending),
                  var messages = pendingToolSupplementMessagesBySessionID[sessionID],
                  !messages.isEmpty else { continue }

            let content = messages.removeFirst()
            if messages.isEmpty {
                pendingToolSupplementMessagesBySessionID.removeValue(forKey: sessionID)
            } else {
                pendingToolSupplementMessagesBySessionID[sessionID] = messages
            }
            dispatchingToolSupplementSessionIDs.insert(sessionID)
            sendToolSupplementMessage(content, targetSessionID: sessionID)
        }
    }

    private func sendToolSupplementMessage(_ content: String, targetSessionID: UUID) {
        let targetSession = chatSessions.first(where: { $0.id == targetSessionID })
            ?? chatService.chatSessionsSubject.value.first(where: { $0.id == targetSessionID })

        Task { [weak self] in
            guard let self else { return }
            await chatService.sendAndProcessMessage(
                content: content,
                aiTemperature: aiTemperature,
                aiTopP: aiTopP,
                systemPrompt: systemPrompt,
                maxChatHistory: maxChatHistory,
                enableStreaming: enableStreaming,
                enhancedPrompt: targetSession?.enhancedPrompt,
                enableMemory: enableMemory,
                enableMemoryWrite: enableMemoryWrite,
                enableMemoryActiveRetrieval: enableMemoryActiveRetrieval,
                includeSystemTime: includeSystemTimeInPrompt,
                systemTimeInjectionPosition: systemTimeInjectionPosition,
                enablePeriodicTimeLandmark: enablePeriodicTimeLandmark,
                periodicTimeLandmarkIntervalMinutes: periodicTimeLandmarkIntervalMinutes,
                enableResponseSpeedMetrics: enableResponseSpeedMetrics,
                audioAttachment: nil,
                imageAttachments: [],
                fileAttachments: [],
                targetSessionID: targetSessionID
            )
            dispatchingToolSupplementSessionIDs.remove(targetSessionID)
            flushPendingToolSupplementMessagesIfPossible()
        }
    }
}
