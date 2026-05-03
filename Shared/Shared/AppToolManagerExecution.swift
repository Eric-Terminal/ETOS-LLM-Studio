// ============================================================================
// AppToolManagerExecution.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件承载本地拓展工具执行入口，并按工具领域分发到具体执行文件。
// ============================================================================

import Foundation

extension AppToolManager {
    static func executeResolvedTool(
        kind: AppToolKind,
        argumentsJSON: String,
        current: AppToolManager
    ) async throws -> String {
        switch kind {
        case .showWidget:
            return try current.executeShowWidget(argumentsJSON: argumentsJSON)
        case .getSystemTime:
            return SystemTimeContextFormatter.description()
        case .askUserInput:
            return try current.executeAskUserInput(argumentsJSON: argumentsJSON)
        case .echoText:
            return try current.executeEchoText(argumentsJSON: argumentsJSON)
        case .fillUserInput:
            return try current.executeFillUserInput(argumentsJSON: argumentsJSON)
        case .editMemory:
            return try await current.executeEditMemory(argumentsJSON: argumentsJSON)
        case .submitFeedbackTicket:
            return try await current.executeSubmitFeedbackTicket(argumentsJSON: argumentsJSON)
        case .listSandboxDirectory:
            return try await current.executeListSandboxDirectory(argumentsJSON: argumentsJSON)
        case .readSandboxFile:
            return try await current.executeReadSandboxFile(argumentsJSON: argumentsJSON)
        case .writeSandboxFile:
            return try await current.executeWriteSandboxFile(argumentsJSON: argumentsJSON)
        case .searchSandboxFiles:
            return try await current.executeSearchSandboxFiles(argumentsJSON: argumentsJSON)
        case .readSandboxFileChunk:
            return try await current.executeReadSandboxFileChunk(argumentsJSON: argumentsJSON)
        case .moveSandboxItem:
            return try await current.executeMoveSandboxItem(argumentsJSON: argumentsJSON)
        case .copySandboxItem:
            return try await current.executeCopySandboxItem(argumentsJSON: argumentsJSON)
        case .createSandboxDirectory:
            return try await current.executeCreateSandboxDirectory(argumentsJSON: argumentsJSON)
        case .batchEditSandboxFile:
            return try await current.executeBatchEditSandboxFile(argumentsJSON: argumentsJSON)
        case .listMemories:
            return try await current.executeListMemories(argumentsJSON: argumentsJSON)
        case .listSQLiteTables:
            return try await current.executeListSQLiteTables(argumentsJSON: argumentsJSON)
        case .querySQLite:
            return try await current.executeQuerySQLite(argumentsJSON: argumentsJSON)
        case .mutateSQLite:
            return try await current.executeMutateSQLite(argumentsJSON: argumentsJSON)
        case .undoSandboxMutation:
            return try await current.executeUndoSandboxMutation()
        case .diffSandboxFile:
            return try await current.executeDiffSandboxFile(argumentsJSON: argumentsJSON)
        case .editSandboxFile:
            return try await current.executeEditSandboxFile(argumentsJSON: argumentsJSON)
        case .deleteSandboxItem:
            return try await current.executeDeleteSandboxItem(argumentsJSON: argumentsJSON)
        }
    }
}
