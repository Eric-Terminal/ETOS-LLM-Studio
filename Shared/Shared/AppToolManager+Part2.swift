import Foundation
import Combine
import os.log
import SQLite3

extension AppToolManager {
    public func executeToolFromChat(toolName: String, argumentsJSON: String) async throws -> String {
        guard let kind = AppToolKind.resolve(from: toolName) else {
            throw AppToolExecutionError.unknownTool
        }
        if !Self.builtInToolKinds.contains(kind) && !chatToolsEnabled {
            throw AppToolExecutionError.toolGroupDisabled
        }
        guard isToolEnabled(kind) else {
            throw AppToolExecutionError.toolDisabled(kind.displayName)
        }
        if approvalPolicy(for: kind) == .alwaysDeny {
            throw AppToolExecutionError.toolDeniedByPolicy(kind.displayName)
        }

        switch kind {
        case .showWidget:
            struct ShowWidgetArgs: Decodable {
                let title: String?
                let widget_code: String
                let loading_messages: [String]?
            }

            guard let argsData = argumentsJSON.data(using: .utf8),
                  let args = try? JSONDecoder().decode(ShowWidgetArgs.self, from: argsData) else {
                throw AppToolExecutionError.invalidArguments(
                    NSLocalizedString("错误：无法解析 show_widget 的参数，请提供 widget_code。", comment: "Show widget tool invalid arguments")
                )
            }

            let widgetCode = args.widget_code.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !widgetCode.isEmpty else {
                throw AppToolExecutionError.invalidArguments(
                    NSLocalizedString("错误：show_widget 的 widget_code 不能为空。", comment: "Show widget tool empty widget code")
                )
            }

            let normalizedTitle = args.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedLoadingMessages = (args.loading_messages ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            let payload: [String: Any] = [
                "title": normalizedTitle as Any,
                "widget_code": widgetCode,
                "loading_messages": normalizedLoadingMessages
            ]
            return prettyPrintedJSONString(from: payload)
        case .getSystemTime:
            return SystemTimeContextFormatter.description()
        case .askUserInput:
            struct AskUserInputArgs: Decodable {
                struct Question: Decodable {
                    struct Option: Decodable {
                        let id: String?
                        let label: String
                        let description: String?
                    }

                    let id: String?
                    let question: String
                    let type: String
                    let options: [Option]
                    let allow_other: Bool?
                    let required: Bool?
                }

                let request_id: String?
                let title: String?
                let description: String?
                let submit_label: String?
                let questions: [Question]
            }

            guard let argsData = argumentsJSON.data(using: .utf8),
                  let args = try? JSONDecoder().decode(AskUserInputArgs.self, from: argsData) else {
                throw AppToolExecutionError.invalidArguments(
                    NSLocalizedString("错误：无法解析 ask_user_input 的参数，请提供 questions。", comment: "Ask user input tool invalid arguments")
                )
            }

            let normalizedQuestions = args.questions.enumerated().compactMap { questionIndex, question -> AppToolAskUserInputQuestion? in
                let questionText = question.question.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !questionText.isEmpty else { return nil }

                let normalizedTypeRaw = question.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard let type = AppToolAskUserInputQuestionType(rawValue: normalizedTypeRaw) else { return nil }

                let questionID = Self.normalizedQuestionID(question.id, fallbackIndex: questionIndex)
                var seenOptionIDs: Set<String> = []
                let normalizedOptions = question.options.enumerated().compactMap { optionIndex, option -> AppToolAskUserInputOption? in
                    let label = option.label.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !label.isEmpty else { return nil }
                    let baseID = Self.normalizedOptionalText(option.id) ?? "option_\(optionIndex + 1)"
                    let optionID = Self.uniqueIdentifier(from: baseID, seen: &seenOptionIDs)
                    return AppToolAskUserInputOption(
                        id: optionID,
                        label: label,
                        description: Self.normalizedOptionalText(option.description)
                    )
                }
                guard !normalizedOptions.isEmpty else { return nil }

                return AppToolAskUserInputQuestion(
                    id: questionID,
                    question: questionText,
                    type: type,
                    options: normalizedOptions,
                    allowOther: question.allow_other ?? false,
                    required: question.required ?? true
                )
            }

            guard !normalizedQuestions.isEmpty else {
                throw AppToolExecutionError.invalidArguments(
                    NSLocalizedString("错误：ask_user_input 至少需要一个有效问题，且每个问题都要包含非空 question、合法 type 和非空 options。", comment: "Ask user input tool invalid normalized questions")
                )
            }

            let requestID = Self.normalizedRequestID(args.request_id)
            let request = AppToolAskUserInputRequest(
                requestID: requestID,
                title: Self.normalizedOptionalText(args.title),
                description: Self.normalizedOptionalText(args.description),
                submitLabel: Self.normalizedOptionalText(args.submit_label) ?? NSLocalizedString("提交", comment: "Ask user input default submit label"),
                questions: normalizedQuestions
            )

            NotificationCenter.default.post(
                name: .appToolAskUserInputRequested,
                object: nil,
                userInfo: request.userInfo
            )

            let payload: [String: Any] = [
                "request_id": request.requestID,
                "question_count": request.questions.count,
                "displayed": true,
                "await_user_supplement": true
            ]
            return prettyPrintedJSONString(from: payload)
        case .echoText:
            struct EchoArgs: Decodable {
                let text: String
            }

            guard let argsData = argumentsJSON.data(using: .utf8),
                  let args = try? JSONDecoder().decode(EchoArgs.self, from: argsData) else {
                throw AppToolExecutionError.invalidArguments(
                    NSLocalizedString("错误：无法解析 echo_text 的参数，请提供 text 字段。", comment: "Echo tool invalid arguments")
                )
            }

            let text = args.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                throw AppToolExecutionError.invalidArguments(
                    NSLocalizedString("错误：echo_text 的 text 不能为空。", comment: "Echo tool empty text")
                )
            }

            return String(
                format: NSLocalizedString("文本回显结果：%@", comment: "Echo tool result format"),
                text
            )
        case .fillUserInput:
            struct FillUserInputArgs: Decodable {
                let text: String
                let mode: String?
            }

            guard let argsData = argumentsJSON.data(using: .utf8),
                  let args = try? JSONDecoder().decode(FillUserInputArgs.self, from: argsData) else {
                throw AppToolExecutionError.invalidArguments(
                    NSLocalizedString("错误：无法解析 fill_user_input 的参数，请提供 text。", comment: "Fill user input tool invalid arguments")
                )
            }

            let content = args.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else {
                throw AppToolExecutionError.invalidArguments(
                    NSLocalizedString("错误：fill_user_input 的 text 不能为空。", comment: "Fill user input tool empty text")
                )
            }

            let mode = AppToolInputDraftMode(rawValue: (args.mode ?? AppToolInputDraftMode.replace.rawValue).lowercased()) ?? .replace
            let request = AppToolInputDraftRequest(text: args.text, mode: mode)
            NotificationCenter.default.post(
                name: .appToolFillUserInputRequested,
                object: nil,
                userInfo: request.userInfo
            )

            let payload: [String: Any] = [
                "mode": mode.rawValue,
                "characterCount": args.text.count,
                "applied": true
            ]
            return prettyPrintedJSONString(from: payload)
        case .editMemory:
            struct EditMemoryArgs: Decodable {
                let memory_id: String
                let content: String?
                let is_archived: Bool?
            }

            guard let argsData = argumentsJSON.data(using: .utf8),
                  let args = try? JSONDecoder().decode(EditMemoryArgs.self, from: argsData) else {
                throw AppToolExecutionError.invalidArguments(
                    NSLocalizedString("错误：无法解析 edit_memory 的参数，请至少提供 memory_id。", comment: "Memory edit tool invalid arguments")
                )
            }

            guard let memoryID = UUID(uuidString: args.memory_id.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw AppToolExecutionError.invalidArguments(
                    NSLocalizedString("错误：edit_memory 的 memory_id 不是合法的 UUID。", comment: "Memory edit tool invalid memory id")
                )
            }

            let memories = await MemoryManager.shared.getAllMemories()
            guard let existing = memories.first(where: { $0.id == memoryID }) else {
                throw AppToolExecutionError.invalidArguments(
                    String(
                        format: NSLocalizedString("错误：未找到 ID 为 %@ 的记忆。", comment: "Memory edit tool memory not found"),
                        args.memory_id
                    )
                )
            }

            let trimmedContent = args.content?.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasContentUpdate = trimmedContent != nil
            let hasArchiveUpdate = args.is_archived != nil
            guard hasContentUpdate || hasArchiveUpdate else {
                throw AppToolExecutionError.invalidArguments(
                    NSLocalizedString("错误：edit_memory 至少要提供 content 或 is_archived 中的一个。", comment: "Memory edit tool missing update fields")
                )
            }

            if let trimmedContent, trimmedContent.isEmpty {
                throw AppToolExecutionError.invalidArguments(
                    NSLocalizedString("错误：edit_memory 的 content 不能为空字符串。", comment: "Memory edit tool empty content")
                )
            }

            let embeddingConfigured = MemoryManager.shared.isEmbeddingModelConfigured()
            let resultPayload: [String: Any]

            if hasContentUpdate {
                var updated = existing
                updated.content = trimmedContent ?? existing.content
                if let isArchived = args.is_archived {
                    updated.isArchived = isArchived
                }
                await MemoryManager.shared.updateMemory(item: updated)
                resultPayload = [
                    "memory_id": existing.id.uuidString,
                    "content": updated.content,
                    "isArchived": updated.isArchived,
                    "embeddingConfigured": embeddingConfigured,
                    "reembedded": embeddingConfigured
                ]
            } else if let isArchived = args.is_archived {
                if isArchived {
                    await MemoryManager.shared.archiveMemory(existing)
                } else {
                    await MemoryManager.shared.unarchiveMemory(existing)
                }
                resultPayload = [
                    "memory_id": existing.id.uuidString,
                    "content": existing.content,
                    "isArchived": isArchived,
                    "embeddingConfigured": embeddingConfigured,
                    "reembedded": false
                ]
            } else {
                throw AppToolExecutionError.invalidArguments(
                    NSLocalizedString("错误：edit_memory 至少要提供 content 或 is_archived 中的一个。", comment: "Memory edit tool missing update fields")
                )
            }

            return prettyPrintedJSONString(from: resultPayload)
        case .submitFeedbackTicket:
            struct SubmitFeedbackArgs: Decodable {
                let category: String?
                let title: String
                let detail: String
                let reproduction_steps: String?
                let expected_behavior: String?
                let actual_behavior: String?
                let extra_context: String?
            }

            guard let argsData = argumentsJSON.data(using: .utf8),
                  let args = try? JSONDecoder().decode(SubmitFeedbackArgs.self, from: argsData) else {
                throw AppToolExecutionError.invalidArguments(
                    NSLocalizedString("错误：无法解析 submit_feedback_ticket 的参数，请至少提供 title 和 detail。", comment: "Submit feedback ticket invalid arguments")
                )
            }

            let normalizedCategoryRaw = args.category?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let category: FeedbackCategory
            if let normalizedCategoryRaw, !normalizedCategoryRaw.isEmpty {
                guard let parsedCategory = FeedbackCategory(rawValue: normalizedCategoryRaw) else {
                    throw AppToolExecutionError.invalidArguments(
                        NSLocalizedString("错误：submit_feedback_ticket 的 category 仅支持 bug 或 suggestion。", comment: "Submit feedback ticket invalid category")
                    )
                }
                category = parsedCategory
            } else {
                category = .bug
            }

            let title = args.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = args.detail.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, !detail.isEmpty else {
                throw AppToolExecutionError.invalidArguments(
                    NSLocalizedString("错误：submit_feedback_ticket 的 title 和 detail 不能为空。", comment: "Submit feedback ticket empty title or detail")
                )
            }

            let draft = FeedbackDraft(
                category: category,
                title: args.title,
                detail: args.detail,
                reproductionSteps: args.reproduction_steps,
                expectedBehavior: args.expected_behavior,
                actualBehavior: args.actual_behavior,
                extraContext: args.extra_context
            )
            let ticket = try await FeedbackService.shared.submit(draft: draft)
            let formatter = ISO8601DateFormatter()
            let payload: [String: Any] = [
                "issueNumber": ticket.issueNumber,
                "category": ticket.category.rawValue,
                "title": ticket.title,
                "status": ticket.lastKnownStatus.rawValue,
                "createdAt": formatter.string(from: ticket.createdAt),
                "publicURL": ticket.publicURL?.absoluteString as Any,
                "moderationBlocked": ticket.moderationBlocked as Any,
                "moderationMessage": ticket.moderationMessage as Any
            ]
            if AchievementTriggerEvaluator.shouldUnlockFishTankReview(appToolName: AppToolKind.submitFeedbackTicket.toolName),
               !AchievementCenter.shared.hasUnlocked(id: .fishTankReview) {
                await AchievementCenter.shared.unlock(id: .fishTankReview)
            }
            return prettyPrintedJSONString(from: payload)
        case .listSandboxDirectory:
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
        case .readSandboxFile:
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
        case .writeSandboxFile:
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
        case .searchSandboxFiles:
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
        case .readSandboxFileChunk:
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
        case .moveSandboxItem:
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
        case .copySandboxItem:
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
        case .createSandboxDirectory:
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
        case .batchEditSandboxFile:
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
        case .listMemories:
            struct ListMemoriesArgs: Decodable {
                let query: String?
                let include_archived: Bool?
                let offset: Int?
                let limit: Int?
                let order: String?
            }

            let argsData = argumentsJSON.data(using: .utf8)
            let args = argsData.flatMap { try? JSONDecoder().decode(ListMemoriesArgs.self, from: $0) }

            let includeArchived = args?.include_archived ?? true
            let offset = max(0, args?.offset ?? 0)
            let limit = min(max(1, args?.limit ?? 20), 200)
            let keyword = args?.query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let sortDescending = (args?.order ?? "desc").lowercased() != "asc"

            let allMemories = await MemoryManager.shared.getAllMemories()
            let filtered = allMemories.filter { memory in
                guard includeArchived || !memory.isArchived else { return false }
                guard !keyword.isEmpty else { return true }
                return memory.content.localizedCaseInsensitiveContains(keyword)
            }

            let sorted = filtered.sorted { lhs, rhs in
                let leftDate = lhs.updatedAt ?? lhs.createdAt
                let rightDate = rhs.updatedAt ?? rhs.createdAt
                if sortDescending {
                    return leftDate > rightDate
                }
                return leftDate < rightDate
            }

            let paged = Array(sorted.dropFirst(offset).prefix(limit))
            let formatter = ISO8601DateFormatter()
            let payload: [String: Any] = [
                "total": sorted.count,
                "offset": offset,
                "limit": limit,
                "items": paged.map { item in
                    [
                        "memory_id": item.id.uuidString,
                        "content": item.content,
                        "isArchived": item.isArchived,
                        "createdAt": formatter.string(from: item.createdAt),
                        "updatedAt": item.updatedAt.map(formatter.string(from:)) as Any
                    ]
                }
            ]
            return prettyPrintedJSONString(from: payload)
        case .listSQLiteTables:
            struct ListSQLiteTablesArgs: Decodable {
                let database: String
                let include_internal: Bool?
                let include_create_sql: Bool?
            }

            guard let argsData = argumentsJSON.data(using: .utf8),
                  let args = try? JSONDecoder().decode(ListSQLiteTablesArgs.self, from: argsData) else {
                throw AppToolExecutionError.invalidArguments(
                    NSLocalizedString("错误：无法解析 list_sqlite_tables 的参数，请提供 database。", comment: "List SQLite tables invalid arguments")
                )
            }

            guard let database = Self.parseSQLiteDatabase(rawValue: args.database) else {
                throw AppToolExecutionError.invalidArguments(
                    NSLocalizedString("错误：list_sqlite_tables 的 database 必须是 chat、config 或 memory。", comment: "List SQLite tables invalid database")
                )
            }

            do {
                let payload = try await Self.runSQLiteOperationOffMainThread {
                    try Self.listSQLiteTables(
                        in: database,
                        includeInternal: args.include_internal ?? false,
                        includeCreateSQL: args.include_create_sql ?? false
                    )
                }
                return prettyPrintedJSONString(from: payload)
            } catch let appToolError as AppToolExecutionError {
                throw appToolError
            } catch {
                throw AppToolExecutionError.invalidArguments(
                    String(
                        format: NSLocalizedString("错误：list_sqlite_tables 执行失败：%@", comment: "List SQLite tables execution error"),
                        error.localizedDescription
                    )
                )
            }
        case .querySQLite:
            struct QuerySQLiteArgs: Decodable {
                let database: String
                let sql: String
                let parameters: [JSONValue]?
                let max_rows: Int?
            }

            guard let argsData = argumentsJSON.data(using: .utf8),
                  let args = try? JSONDecoder().decode(QuerySQLiteArgs.self, from: argsData) else {
                throw AppToolExecutionError.invalidArguments(
                    NSLocalizedString("错误：无法解析 query_sqlite 的参数，请提供 database 和 sql。", comment: "Query SQLite invalid arguments")
                )
            }

            guard let database = Self.parseSQLiteDatabase(rawValue: args.database) else {
                throw AppToolExecutionError.invalidArguments(
                    NSLocalizedString("错误：query_sqlite 的 database 必须是 chat、config 或 memory。", comment: "Query SQLite invalid database")
                )
            }

            let maxRows = Self.sanitizedSQLiteMaxRows(args.max_rows)
            do {
                let payload = try await Self.runSQLiteOperationOffMainThread {
                    try Self.querySQLite(
                        in: database,
                        sql: args.sql,
                        parameters: args.parameters ?? [],
                        maxRows: maxRows
                    )
                }
                return prettyPrintedJSONString(from: payload)
            } catch let appToolError as AppToolExecutionError {
                throw appToolError
            } catch {
                throw AppToolExecutionError.invalidArguments(
                    String(
                        format: NSLocalizedString("错误：query_sqlite 执行失败：%@", comment: "Query SQLite execution error"),
                        error.localizedDescription
                    )
                )
            }
        case .mutateSQLite:
            struct MutateSQLiteArgs: Decodable {
                let database: String
                let sql: String
                let parameters: [JSONValue]?
                let allow_without_where: Bool?
                let returning_max_rows: Int?
            }

            guard let argsData = argumentsJSON.data(using: .utf8),
                  let args = try? JSONDecoder().decode(MutateSQLiteArgs.self, from: argsData) else {
                throw AppToolExecutionError.invalidArguments(
                    NSLocalizedString("错误：无法解析 mutate_sqlite 的参数，请提供 database 和 sql。", comment: "Mutate SQLite invalid arguments")
                )
            }

            guard let database = Self.parseSQLiteDatabase(rawValue: args.database) else {
                throw AppToolExecutionError.invalidArguments(
                    NSLocalizedString("错误：mutate_sqlite 的 database 必须是 chat、config 或 memory。", comment: "Mutate SQLite invalid database")
                )
            }

            let returningMaxRows = Self.sanitizedSQLiteMaxRows(args.returning_max_rows)
            do {
                let payload = try await Self.runSQLiteOperationOffMainThread {
                    try Self.mutateSQLite(
                        in: database,
                        sql: args.sql,
                        parameters: args.parameters ?? [],
                        allowWithoutWhere: args.allow_without_where ?? false,
                        returningMaxRows: returningMaxRows
                    )
                }
                return prettyPrintedJSONString(from: payload)
            } catch let appToolError as AppToolExecutionError {
                throw appToolError
            } catch {
                throw AppToolExecutionError.invalidArguments(
                    String(
                        format: NSLocalizedString("错误：mutate_sqlite 执行失败：%@", comment: "Mutate SQLite execution error"),
                        error.localizedDescription
                    )
                )
            }
        case .undoSandboxMutation:
            let result = try await Self.runSandboxFileOperationOffMainThread {
                try SandboxFileToolSupport.undoLastMutation()
            }
            let payload: [String: Any] = [
                "operation": result.operation,
                "recordedAt": result.recordedAt
            ]
            return prettyPrintedJSONString(from: payload)
        case .diffSandboxFile:
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
        case .editSandboxFile:
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
        case .deleteSandboxItem:
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

}
