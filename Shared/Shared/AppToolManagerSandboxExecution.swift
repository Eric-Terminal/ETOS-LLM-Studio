// ============================================================================
// AppToolManagerSandboxExecution.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件承载本地拓展工具中的沙盒文件读写与目录操作执行逻辑。
// ============================================================================

import Foundation

extension AppToolManager {
    func executeListSandboxDirectory(argumentsJSON: String) async throws -> String {
        struct ListDirectoryArgs: Decodable {
            let path: String?
        }

        let argsData = argumentsJSON.data(using: .utf8)
        let args = argsData.flatMap { try? JSONDecoder().decode(ListDirectoryArgs.self, from: $0) }
        let relativePath = args?.path ?? ""
        let items = try await Self.runSandboxFileOperationOffMainThread {
            try SandboxFileToolSupport.listDirectory(relativePath: relativePath)
        }
        let payload: [String: Any] = [
            "path": relativePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Documents" : relativePath,
            "items": items.map { item in
                [
                    "path": item.path,
                    "name": item.name,
                    "isDirectory": item.isDirectory,
                    "size": item.size,
                    "modifiedAt": item.modifiedAt as Any
                ]
            }
        ]
        return prettyPrintedJSONString(from: payload)
    }

    func executeReadSandboxFile(argumentsJSON: String) async throws -> String {
        struct ReadFileArgs: Decodable {
            let path: String
        }

        guard let argsData = argumentsJSON.data(using: .utf8),
              let args = try? JSONDecoder().decode(ReadFileArgs.self, from: argsData) else {
            throw AppToolExecutionError.invalidArguments(
                NSLocalizedString("错误：无法解析 read_sandbox_file 的参数，请提供 path。", comment: "Read sandbox file invalid arguments")
            )
        }

        let content = try await Self.runSandboxFileOperationOffMainThread {
            try SandboxFileToolSupport.readTextFile(relativePath: args.path)
        }
        let payload: [String: Any] = [
            "path": args.path,
            "characterCount": content.count,
            "content": content
        ]
        return prettyPrintedJSONString(from: payload)
    }

    func executeWriteSandboxFile(argumentsJSON: String) async throws -> String {
        struct WriteFileArgs: Decodable {
            let path: String
            let content: String
            let create_parent_directories: Bool?
        }

        guard let argsData = argumentsJSON.data(using: .utf8),
              let args = try? JSONDecoder().decode(WriteFileArgs.self, from: argsData) else {
            throw AppToolExecutionError.invalidArguments(
                NSLocalizedString("错误：无法解析 write_sandbox_file 的参数，请提供 path 和 content。", comment: "Write sandbox file invalid arguments")
            )
        }

        let result = try await Self.runSandboxFileOperationOffMainThread {
            try SandboxFileToolSupport.writeTextFile(
                relativePath: args.path,
                content: args.content,
                createIntermediateDirectories: args.create_parent_directories ?? true
            )
        }
        refreshCurrentSessionMessagesIfNeeded(mutatedPaths: [result.path])
        let payload: [String: Any] = [
            "path": result.path,
            "size": result.size,
            "createdParentDirectories": result.createdParentDirectories
        ]
        return prettyPrintedJSONString(from: payload)
    }

    func executeSearchSandboxFiles(argumentsJSON: String) async throws -> String {
        struct SearchFilesArgs: Decodable {
            let path: String?
            let name_query: String?
            let content_query: String?
            let max_results: Int?
            let include_directories: Bool?
            let case_sensitive: Bool?
        }

        let argsData = argumentsJSON.data(using: .utf8)
        let args = argsData.flatMap { try? JSONDecoder().decode(SearchFilesArgs.self, from: $0) }
        let relativePath = args?.path ?? ""
        let results = try await Self.runSandboxFileOperationOffMainThread {
            try SandboxFileToolSupport.searchItems(
                relativePath: relativePath,
                nameQuery: args?.name_query,
                contentQuery: args?.content_query,
                maxResults: args?.max_results ?? 20,
                includeDirectories: args?.include_directories ?? false,
                caseSensitive: args?.case_sensitive ?? false
            )
        }
        let payload: [String: Any] = [
            "path": relativePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Documents" : relativePath,
            "count": results.count,
            "items": results.map { result in
                [
                    "path": result.path,
                    "name": result.name,
                    "isDirectory": result.isDirectory,
                    "size": result.size,
                    "modifiedAt": result.modifiedAt as Any,
                    "matchedByName": result.matchedByName,
                    "matchedByContent": result.matchedByContent
                ]
            }
        ]
        return prettyPrintedJSONString(from: payload)
    }

    func executeReadSandboxFileChunk(argumentsJSON: String) async throws -> String {
        struct ReadFileChunkArgs: Decodable {
            let path: String
            let start_line: Int?
            let max_lines: Int?
        }

        guard let argsData = argumentsJSON.data(using: .utf8),
              let args = try? JSONDecoder().decode(ReadFileChunkArgs.self, from: argsData) else {
            throw AppToolExecutionError.invalidArguments(
                NSLocalizedString("错误：无法解析 read_sandbox_file_chunk 的参数，请提供 path。", comment: "Read sandbox file chunk invalid arguments")
            )
        }

        let result = try await Self.runSandboxFileOperationOffMainThread {
            try SandboxFileToolSupport.readTextFileChunk(
                relativePath: args.path,
                startLine: args.start_line ?? 1,
                maxLines: args.max_lines ?? 200
            )
        }
        let payload: [String: Any] = [
            "path": result.path,
            "startLine": result.startLine,
            "endLine": result.endLine,
            "totalLines": result.totalLines,
            "hasMore": result.hasMore,
            "content": result.content
        ]
        return prettyPrintedJSONString(from: payload)
    }

    func executeMoveSandboxItem(argumentsJSON: String) async throws -> String {
        struct MoveItemArgs: Decodable {
            let source_path: String
            let destination_path: String
            let overwrite: Bool?
            let create_parent_directories: Bool?
        }

        guard let argsData = argumentsJSON.data(using: .utf8),
              let args = try? JSONDecoder().decode(MoveItemArgs.self, from: argsData) else {
            throw AppToolExecutionError.invalidArguments(
                NSLocalizedString("错误：无法解析 move_sandbox_item 的参数，请提供 source_path 和 destination_path。", comment: "Move sandbox item invalid arguments")
            )
        }

        let result = try await Self.runSandboxFileOperationOffMainThread {
            try SandboxFileToolSupport.moveItem(
                from: args.source_path,
                to: args.destination_path,
                overwrite: args.overwrite ?? false,
                createIntermediateDirectories: args.create_parent_directories ?? true
            )
        }
        refreshCurrentSessionMessagesIfNeeded(
            mutatedPaths: [result.sourcePath, result.destinationPath]
        )
        let payload: [String: Any] = [
            "sourcePath": result.sourcePath,
            "destinationPath": result.destinationPath,
            "wasDirectory": result.wasDirectory,
            "createdParentDirectories": result.createdParentDirectories,
            "overwroteDestination": result.overwroteDestination
        ]
        return prettyPrintedJSONString(from: payload)
    }

    func executeCopySandboxItem(argumentsJSON: String) async throws -> String {
        struct CopyItemArgs: Decodable {
            let source_path: String
            let destination_path: String
            let overwrite: Bool?
            let create_parent_directories: Bool?
        }

        guard let argsData = argumentsJSON.data(using: .utf8),
              let args = try? JSONDecoder().decode(CopyItemArgs.self, from: argsData) else {
            throw AppToolExecutionError.invalidArguments(
                NSLocalizedString("错误：无法解析 copy_sandbox_item 的参数，请提供 source_path 和 destination_path。", comment: "Copy sandbox item invalid arguments")
            )
        }

        let result = try await Self.runSandboxFileOperationOffMainThread {
            try SandboxFileToolSupport.copyItem(
                from: args.source_path,
                to: args.destination_path,
                overwrite: args.overwrite ?? false,
                createIntermediateDirectories: args.create_parent_directories ?? true
            )
        }
        refreshCurrentSessionMessagesIfNeeded(mutatedPaths: [result.destinationPath])
        let payload: [String: Any] = [
            "sourcePath": result.sourcePath,
            "destinationPath": result.destinationPath,
            "wasDirectory": result.wasDirectory,
            "createdParentDirectories": result.createdParentDirectories,
            "overwroteDestination": result.overwroteDestination
        ]
        return prettyPrintedJSONString(from: payload)
    }
}
