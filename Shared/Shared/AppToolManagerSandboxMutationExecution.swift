// ============================================================================
// AppToolManagerSandboxMutationExecution.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件承载本地拓展工具中的沙盒变更、差异比较与撤销执行逻辑。
// ============================================================================

import Foundation

extension AppToolManager {
    func executeCreateSandboxDirectory(argumentsJSON: String) async throws -> String {
        struct CreateDirectoryArgs: Decodable {
            let path: String
            let create_parent_directories: Bool?
        }

        guard let argsData = argumentsJSON.data(using: .utf8),
              let args = try? JSONDecoder().decode(CreateDirectoryArgs.self, from: argsData) else {
            throw AppToolExecutionError.invalidArguments(
                NSLocalizedString("错误：无法解析 create_sandbox_directory 的参数，请提供 path。", comment: "Create sandbox directory invalid arguments")
            )
        }

        let result = try await Self.runSandboxFileOperationOffMainThread {
            try SandboxFileToolSupport.createDirectory(
                relativePath: args.path,
                createIntermediateDirectories: args.create_parent_directories ?? true
            )
        }
        let payload: [String: Any] = [
            "path": result.path,
            "created": result.created,
            "createdParentDirectories": result.createdParentDirectories
        ]
        return prettyPrintedJSONString(from: payload)
    }

    func executeBatchEditSandboxFile(argumentsJSON: String) async throws -> String {
        struct BatchRuleArgs: Decodable {
            let old_text: String
            let new_text: String
        }
        struct BatchEditArgs: Decodable {
            let path: String
            let rules: [BatchRuleArgs]
            let replace_all: Bool?
            let ignore_missing: Bool?
        }

        guard let argsData = argumentsJSON.data(using: .utf8),
              let args = try? JSONDecoder().decode(BatchEditArgs.self, from: argsData) else {
            throw AppToolExecutionError.invalidArguments(
                NSLocalizedString("错误：无法解析 batch_edit_sandbox_file 的参数，请提供 path 和 rules。", comment: "Batch edit sandbox file invalid arguments")
            )
        }

        let rules = args.rules.map { rule in
            SandboxBatchEditRule(oldText: rule.old_text, newText: rule.new_text)
        }
        let result = try await Self.runSandboxFileOperationOffMainThread {
            try SandboxFileToolSupport.batchReplaceText(
                relativePath: args.path,
                rules: rules,
                replaceAll: args.replace_all ?? false,
                ignoreMissing: args.ignore_missing ?? false
            )
        }
        refreshCurrentSessionMessagesIfNeeded(mutatedPaths: [result.path])
        let payload: [String: Any] = [
            "path": result.path,
            "replacements": result.replacements,
            "rulesApplied": result.rulesApplied,
            "size": result.size
        ]
        return prettyPrintedJSONString(from: payload)
    }

    func executeUndoSandboxMutation() async throws -> String {
        let result = try await Self.runSandboxFileOperationOffMainThread {
            try SandboxFileToolSupport.undoLastMutation()
        }
        let payload: [String: Any] = [
            "operation": result.operation,
            "recordedAt": result.recordedAt
        ]
        return prettyPrintedJSONString(from: payload)
    }

    func executeDiffSandboxFile(argumentsJSON: String) async throws -> String {
        struct DiffFileArgs: Decodable {
            let path: String
            let updated_content: String
        }

        guard let argsData = argumentsJSON.data(using: .utf8),
              let args = try? JSONDecoder().decode(DiffFileArgs.self, from: argsData) else {
            throw AppToolExecutionError.invalidArguments(
                NSLocalizedString("错误：无法解析 diff_sandbox_file 的参数，请提供 path 和 updated_content。", comment: "Diff sandbox file invalid arguments")
            )
        }

        return try await Self.runSandboxFileOperationOffMainThread {
            try SandboxFileToolSupport.diffTextFile(
                relativePath: args.path,
                updatedContent: args.updated_content
            )
        }
    }

    func executeEditSandboxFile(argumentsJSON: String) async throws -> String {
        struct EditFileArgs: Decodable {
            let path: String
            let old_text: String
            let new_text: String
            let replace_all: Bool?
        }

        guard let argsData = argumentsJSON.data(using: .utf8),
              let args = try? JSONDecoder().decode(EditFileArgs.self, from: argsData) else {
            throw AppToolExecutionError.invalidArguments(
                NSLocalizedString("错误：无法解析 edit_sandbox_file 的参数，请提供 path、old_text 和 new_text。", comment: "Edit sandbox file invalid arguments")
            )
        }

        let result = try await Self.runSandboxFileOperationOffMainThread {
            try SandboxFileToolSupport.replaceText(
                relativePath: args.path,
                oldText: args.old_text,
                newText: args.new_text,
                replaceAll: args.replace_all ?? false
            )
        }
        refreshCurrentSessionMessagesIfNeeded(mutatedPaths: [result.path])
        let payload: [String: Any] = [
            "path": result.path,
            "replacements": result.replacements,
            "size": result.size
        ]
        return prettyPrintedJSONString(from: payload)
    }

    func executeDeleteSandboxItem(argumentsJSON: String) async throws -> String {
        struct DeleteFileArgs: Decodable {
            let path: String
        }

        guard let argsData = argumentsJSON.data(using: .utf8),
              let args = try? JSONDecoder().decode(DeleteFileArgs.self, from: argsData) else {
            throw AppToolExecutionError.invalidArguments(
                NSLocalizedString("错误：无法解析 delete_sandbox_item 的参数，请提供 path。", comment: "Delete sandbox item invalid arguments")
            )
        }

        let result = try await Self.runSandboxFileOperationOffMainThread {
            try SandboxFileToolSupport.deleteItem(relativePath: args.path)
        }
        refreshCurrentSessionMessagesIfNeeded(mutatedPaths: [result.path])
        let payload: [String: Any] = [
            "path": result.path,
            "wasDirectory": result.wasDirectory
        ]
        return prettyPrintedJSONString(from: payload)
    }
}
