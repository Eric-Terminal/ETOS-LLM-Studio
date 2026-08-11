// ============================================================================
// SystemEntryCoordinator.swift
// ETOS LLM Studio
// ============================================================================

import Foundation
import Combine

public enum ETOSSystemEntryError: LocalizedError {
    case emptyPrompt
    case sessionNotFound
    case requestInProgress
    case persistenceUnavailable

    public var errorDescription: String? {
        switch self {
        case .emptyPrompt:
            return NSLocalizedString("请输入要处理的内容。", comment: "Empty system-entry prompt")
        case .sessionNotFound:
            return NSLocalizedString("找不到指定会话。", comment: "Missing system-entry session")
        case .requestInProgress:
            return NSLocalizedString("该请求正在处理中。", comment: "System-entry request is already claimed")
        case .persistenceUnavailable:
            return NSLocalizedString("暂时无法写入本地数据库。", comment: "System-entry persistence unavailable")
        }
    }
}

public struct ETOSSystemEntryTaskResult: Sendable {
    public let sessionID: UUID
    public let wasAlreadyHandled: Bool

    public init(sessionID: UUID, wasAlreadyHandled: Bool) {
        self.sessionID = sessionID
        self.wasAlreadyHandled = wasAlreadyHandled
    }
}

public struct ETOSSystemEntryStatus: Sendable {
    public let sessionID: UUID
    public let sessionName: String
    public let status: ETOSTaskSnapshotStatus
    public let updatedAt: Date

    public init(sessionID: UUID, sessionName: String, status: ETOSTaskSnapshotStatus, updatedAt: Date) {
        self.sessionID = sessionID
        self.sessionName = sessionName
        self.status = status
        self.updatedAt = updatedAt
    }
}

/// 系统入口只负责参数收束和幂等治理，消息仍通过 ChatService 的正式发送链路执行。
@MainActor
public final class SystemEntryCoordinator {
    public static let shared = SystemEntryCoordinator()

    private let chatService: ChatService
    private let memoryManager: MemoryManager

    public init(chatService: ChatService = .shared, memoryManager: MemoryManager = .shared) {
        self.chatService = chatService
        self.memoryManager = memoryManager
    }

    public func startTask(
        prompt: String,
        mode: LocalAgentMode = .agent,
        title: String? = nil,
        requestID: UUID,
        kind: ETOSSystemEntryRequestKind = .appIntent,
        fileAttachments: [FileAttachment] = [],
        imageAttachments: [ImageAttachment] = []
    ) async throws -> ETOSSystemEntryTaskResult {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !fileAttachments.isEmpty || !imageAttachments.isEmpty else {
            throw ETOSSystemEntryError.emptyPrompt
        }

        if let receipt = await Task.detached(priority: .userInitiated, operation: {
            Persistence.loadSystemEntryReceipt(id: requestID)
        }).value {
            guard let sessionID = receipt.sessionID else { throw ETOSSystemEntryError.requestInProgress }
            return ETOSSystemEntryTaskResult(sessionID: sessionID, wasAlreadyHandled: true)
        }
        let claimed = await Task.detached(priority: .userInitiated) {
            Persistence.claimSystemEntryRequest(id: requestID, kind: kind)
        }.value
        guard claimed else {
            if let sessionID = await Task.detached(priority: .userInitiated, operation: {
                Persistence.loadSystemEntryReceipt(id: requestID)?.sessionID
            }).value {
                return ETOSSystemEntryTaskResult(sessionID: sessionID, wasAlreadyHandled: true)
            }
            throw ETOSSystemEntryError.persistenceUnavailable
        }

        let session = chatService.createSavedSession(
            name: resolvedTitle(title, prompt: trimmed),
            systemPrompt: textConfig(.systemPrompt)
        )
        let persisted = await Task.detached(priority: .userInitiated) {
            guard Persistence.saveLocalAgentMode(mode, sessionID: session.id) else { return false }
            return Persistence.saveSystemEntryReceipt(
                ETOSSystemEntryReceipt(id: requestID, kind: kind, sessionID: session.id)
            )
        }.value
        guard persisted else {
            throw ETOSSystemEntryError.persistenceUnavailable
        }
        await send(trimmed, to: session.id, fileAttachments: fileAttachments, imageAttachments: imageAttachments)
        return ETOSSystemEntryTaskResult(sessionID: session.id, wasAlreadyHandled: false)
    }

    public func continueTask(
        sessionID: UUID,
        prompt: String,
        requestID: UUID,
        kind: ETOSSystemEntryRequestKind = .appIntent,
        fileAttachments: [FileAttachment] = [],
        imageAttachments: [ImageAttachment] = []
    ) async throws -> ETOSSystemEntryTaskResult {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !fileAttachments.isEmpty || !imageAttachments.isEmpty else {
            throw ETOSSystemEntryError.emptyPrompt
        }
        let sessionExists = await Task.detached(priority: .userInitiated) {
            Persistence.loadChatSession(id: sessionID) != nil
        }.value
        guard sessionExists else { throw ETOSSystemEntryError.sessionNotFound }
        if let receipt = await Task.detached(priority: .userInitiated, operation: {
            Persistence.loadSystemEntryReceipt(id: requestID)
        }).value {
            guard let handledSessionID = receipt.sessionID else { throw ETOSSystemEntryError.requestInProgress }
            return ETOSSystemEntryTaskResult(sessionID: handledSessionID, wasAlreadyHandled: true)
        }
        let persisted = await Task.detached(priority: .userInitiated) {
            guard Persistence.claimSystemEntryRequest(id: requestID, kind: kind) else { return false }
            return Persistence.saveSystemEntryReceipt(
                ETOSSystemEntryReceipt(id: requestID, kind: kind, sessionID: sessionID)
            )
        }.value
        guard persisted else {
            throw ETOSSystemEntryError.persistenceUnavailable
        }
        await send(
            trimmed,
            to: sessionID,
            fileAttachments: fileAttachments,
            imageAttachments: imageAttachments
        )
        return ETOSSystemEntryTaskResult(sessionID: sessionID, wasAlreadyHandled: false)
    }

    public func stop(sessionID: UUID) async throws {
        let sessionExists = await Task.detached(priority: .userInitiated) {
            Persistence.loadChatSession(id: sessionID) != nil
        }.value
        guard sessionExists else { throw ETOSSystemEntryError.sessionNotFound }
        await chatService.cancelRequest(for: sessionID)
    }

    public func status(sessionID: UUID? = nil) async throws -> ETOSSystemEntryStatus {
        let storedSession = await Task.detached(priority: .userInitiated) {
            if let sessionID { return Persistence.loadChatSession(id: sessionID) }
            return Persistence.loadChatSessions().first
        }.value
        let session = sessionID == nil
            ? (chatService.currentSessionSubject.value ?? storedSession)
            : storedSession
        guard let session else { throw ETOSSystemEntryError.sessionNotFound }
        let run = await Task.detached(priority: .userInitiated) {
            Persistence.loadLatestConversationRun(sessionID: session.id)
        }.value
        return ETOSSystemEntryStatus(
            sessionID: session.id,
            sessionName: String(session.name.prefix(80)),
            status: snapshotStatus(run?.status, isRunning: chatService.runningSessionIDsSubject.value.contains(session.id)),
            updatedAt: run?.finishedAt ?? run?.startedAt ?? run?.createdAt ?? Date()
        )
    }

    public func saveMemory(_ content: String, shortcutName: String) async throws -> MemoryItem {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ETOSSystemEntryError.emptyPrompt }
        let item = await Task.detached(priority: .userInitiated) { [memoryManager] in
            let existingIDs = Set(await memoryManager.getAllMemories().map(\.id))
            await memoryManager.addMemory(
                MemoryWriteRequest(content: trimmed, sourceShortcutName: shortcutName)
            )
            return await memoryManager.getAllMemories().first {
                !existingIDs.contains($0.id) && $0.content == trimmed
            }
        }.value
        guard let item else {
            throw ETOSSystemEntryError.persistenceUnavailable
        }
        return item
    }

    public func searchMemory(_ query: String, limit: Int = 5) async throws -> [MemoryItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ETOSSystemEntryError.emptyPrompt }
        return await Task.detached(priority: .userInitiated) { [memoryManager] in
            await memoryManager.searchMemoriesByKeyword(
                query: trimmed,
                topK: min(max(limit, 1), 10)
            )
        }.value
    }

    private func send(
        _ content: String,
        to sessionID: UUID,
        fileAttachments: [FileAttachment] = [],
        imageAttachments: [ImageAttachment] = []
    ) async {
        await chatService.sendAndProcessMessage(
            content: content,
            aiTemperature: realConfig(.aiTemperature),
            aiTopP: realConfig(.aiTopP),
            systemPrompt: textConfig(.systemPrompt),
            maxChatHistory: AppConfigStore.integerValue(for: .maxChatHistory),
            enableStreaming: AppConfigStore.boolValue(for: .enableStreaming),
            enhancedPrompt: nil,
            enableMemory: AppConfigStore.boolValue(for: .enableMemory),
            enableMemoryWrite: AppConfigStore.boolValue(for: .enableMemoryWrite),
            enableMemoryActiveRetrieval: AppConfigStore.boolValue(for: .enableMemoryActiveRetrieval),
            includeSystemTime: AppConfigStore.boolValue(for: .includeSystemTimeInPrompt),
            systemTimeInjectionPosition: SystemTimeInjectionPosition(
                rawValue: textConfig(.systemTimeInjectionPosition)
            ) ?? .front,
            enablePeriodicTimeLandmark: AppConfigStore.boolValue(for: .enablePeriodicTimeLandmark),
            periodicTimeLandmarkIntervalMinutes: AppConfigStore.integerValue(for: .periodicTimeLandmarkIntervalMinutes),
            enableResponseSpeedMetrics: AppConfigStore.boolValue(for: .enableResponseSpeedMetrics),
            imageAttachments: imageAttachments,
            fileAttachments: fileAttachments,
            targetSessionID: sessionID
        )
    }

    private func resolvedTitle(_ title: String?, prompt: String) -> String {
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return String(title.prefix(80))
        }
        let firstLine = prompt.split(whereSeparator: \Character.isNewline).first.map(String.init) ?? ""
        return firstLine.isEmpty
            ? NSLocalizedString("新的 Agent 任务", comment: "Default external Agent task title")
            : String(firstLine.prefix(80))
    }

    private func textConfig(_ key: AppConfigKey) -> String {
        AppConfigStore.textValue(for: key)
    }

    private func realConfig(_ key: AppConfigKey) -> Double {
        if let stored = Persistence.readAppConfigReal(key: key.rawValue) { return stored }
        if case .real(let value) = key.defaultValue { return value }
        return 0
    }

    private func snapshotStatus(_ status: ConversationRunStatus?, isRunning: Bool) -> ETOSTaskSnapshotStatus {
        guard let status else { return isRunning ? .running : .completed }
        switch status {
        case .queued: return .queued
        case .running, .waitingTool, .waitingConversation: return .running
        case .waitingUser, .pausedByBudget: return .waitingForInput
        case .completed: return .completed
        case .failed, .interrupted: return .failed
        case .cancelled: return .cancelled
        }
    }
}
