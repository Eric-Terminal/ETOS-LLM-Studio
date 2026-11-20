// ============================================================================
// AppToolManagerMemoryFeedbackExecution.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件承载本地拓展工具中的记忆管理与反馈工单执行逻辑。
// ============================================================================

import Foundation

extension AppToolManager {
    @concurrent
    nonisolated func executeEditMemory(
        argumentsJSON: String,
        memoryManager: MemoryManager = .shared,
        context: MemoryMutationContext = MemoryMutationContext(origin: .tool, sourceToolName: "edit_memory")
    ) async throws -> String {
        struct EditMemoryArgs: Decodable {
            let label: String
            let expected_version: String
            let content: String?
            let is_archived: Bool?
            let kind: String?
            let importance: Double?
            let confidence: Double?
            let entities: [String]?
            let valid_from: String?
            let valid_until: String?
        }

        guard let argsData = argumentsJSON.data(using: .utf8),
              let args = try? JSONDecoder().decode(EditMemoryArgs.self, from: argsData) else {
            throw AppToolExecutionError.invalidArguments(
                NSLocalizedString("请提供 label 和 expected_version，分别取自同一条查询结果的 label 和 version。", comment: "记忆编辑参数缺失")
            )
        }

        let trimmedContent = args.content?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasContentUpdate = trimmedContent != nil
        let hasArchiveUpdate = args.is_archived != nil
        let hasMetadataUpdate = args.kind != nil || args.importance != nil || args.confidence != nil
            || args.entities != nil || args.valid_from != nil || args.valid_until != nil
        guard hasContentUpdate || hasArchiveUpdate || hasMetadataUpdate else {
            throw AppToolExecutionError.invalidArguments(
                NSLocalizedString("错误：edit_memory 没有提供任何可更新字段。", comment: "Memory edit tool missing update fields")
            )
        }

        if let trimmedContent, trimmedContent.isEmpty {
            throw AppToolExecutionError.invalidArguments(
                NSLocalizedString("错误：edit_memory 的 content 不能为空字符串。", comment: "Memory edit tool empty content")
            )
        }

        let formatter = ISO8601DateFormatter()

        if let kind = args.kind, MemoryKind(rawValue: kind) == nil {
            throw AppToolExecutionError.invalidArguments(
                NSLocalizedString("错误：edit_memory 的 kind 不受支持。", comment: "Memory edit unsupported kind")
            )
        }
        let validFrom = try parseMemoryDate(args.valid_from, field: "valid_from", formatter: formatter)
        let validUntil = try parseMemoryDate(args.valid_until, field: "valid_until", formatter: formatter)

        let memories = await memoryManager.getAllMemories()
        var matches = memories.lazy.filter { $0.toolLabel == args.label }.makeIterator()
        guard let existing = matches.next(), matches.next() == nil else {
            throw AppToolExecutionError.invalidArguments(
                NSLocalizedString("无法按此标签唯一定位记忆。请重新查询目标条目。", comment: "记忆标签缺失或重名")
            )
        }
        guard try existing.toolVersion == args.expected_version else {
            throw Self.memoryVersionConflict(existing)
        }

        var updated = existing
        if let trimmedContent { updated.content = trimmedContent }
        if let isArchived = args.is_archived { updated.isArchived = isArchived }
        if let kind = args.kind.flatMap(MemoryKind.init(rawValue:)) { updated.kind = kind }
        if let importance = args.importance { updated.importance = min(max(importance, 0), 1) }
        if let confidence = args.confidence { updated.confidence = min(max(confidence, 0), 1) }
        if let entities = args.entities { updated.entities = entities }
        if args.valid_from != nil { updated.validFrom = validFrom }
        if args.valid_until != nil { updated.validUntil = validUntil }

        let archiveOnly = !hasContentUpdate && !hasMetadataUpdate
        let receipt: (memory: MemoryItem, reembedded: Bool)
        if archiveOnly && existing.isArchived == updated.isArchived {
            receipt = (existing, false)
        } else {
            let operation: MemoryMutationOperation
            if archiveOnly {
                operation = updated.isArchived ? .archived : .restored
            } else {
                operation = .edited
            }
            let snapshot = MemoryVersionSnapshot(memory: existing)
            guard let saved = await memoryManager.saveMemoryEdit(
                item: updated, context: context, expectedSnapshot: snapshot, operation: operation
            ) else {
                if let current = await memoryManager.getAllMemories().first(where: { $0.id == existing.id }),
                   try current.toolVersion != args.expected_version {
                    throw Self.memoryVersionConflict(current)
                }
                throw AppToolExecutionError.invalidArguments(
                    NSLocalizedString("未能保存记忆。请重新查询并核对目标条目。", comment: "记忆编辑未提交")
                )
            }
            receipt = saved
        }

        let saved = receipt.memory
        return prettyPrintedJSONString(from: [
            "label": saved.toolLabel,
            "version": try saved.toolVersion,
            "content": saved.content,
            "isArchived": saved.isArchived,
            "kind": saved.kind.rawValue,
            "importance": saved.importance,
            "confidence": saved.confidence,
            "entities": saved.entities,
            "embeddingConfigured": memoryManager.isEmbeddingModelConfigured(),
            "reembedded": receipt.reembedded
        ])
    }

    private nonisolated static func memoryVersionConflict(_ current: MemoryItem) -> AppToolExecutionError {
        .invalidArguments(String(
            format: NSLocalizedString("记忆版本不匹配，未写入。请重新查询并核对当前内容：%@", comment: "记忆版本冲突及当前摘要"),
            String(current.content.prefix(160))
        ))
    }

    private nonisolated func parseMemoryDate(
        _ value: String?,
        field: String,
        formatter: ISO8601DateFormatter
    ) throws -> Date? {
        guard let value else { return nil }
        guard let date = formatter.date(from: value) else {
            throw AppToolExecutionError.invalidArguments(
                String(
                    format: NSLocalizedString("错误：edit_memory 的 %@ 必须是 ISO 8601 时间。", comment: "Memory edit invalid date"),
                    field
                )
            )
        }
        return date
    }

    func executeSubmitFeedbackTicket(argumentsJSON: String) async throws -> String {
        struct SubmitFeedbackArgs: Decodable {
            let category: String?
            let title: String
            let detail: String
            let reproduction_steps: String?
            let expected_behavior: String?
            let actual_behavior: String?
            let extra_context: String?
            let linux_runtime_diagnostic_id: String?
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

        var extraContext = args.extra_context
        if let rawDiagnosticID = args.linux_runtime_diagnostic_id?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawDiagnosticID.isEmpty {
            guard let diagnosticID = UUID(uuidString: rawDiagnosticID),
                  let diagnostic = Persistence.loadLocalLinuxDiagnostic(id: diagnosticID) else {
                throw AppToolExecutionError.invalidArguments(
                    NSLocalizedString("错误：找不到指定的 Linux 运行时诊断。", comment: "Submit feedback ticket missing Linux diagnostic")
                )
            }
            var safeDiagnostic: [String: Any] = [
                "diagnostic_id": diagnostic.id.uuidString,
                "category": diagnostic.category.rawValue,
                "request_id": diagnostic.requestID,
                "guest_architecture": diagnostic.guestArchitecture,
                "backend": diagnostic.backend,
                "build_identity": diagnostic.buildIdentity,
                "occurrence_count": diagnostic.occurrenceCount,
                "summary": diagnostic.redactedSummary
            ]
            safeDiagnostic["seed_version"] = diagnostic.seedVersion
            safeDiagnostic["exit_code"] = diagnostic.exitCode
            safeDiagnostic["signal"] = diagnostic.signal
            safeDiagnostic["linux_errno"] = diagnostic.linuxError
            safeDiagnostic["completion_reason"] = diagnostic.completionReason?.rawValue
            safeDiagnostic["guest_pc"] = diagnostic.guestProgramCounter
            safeDiagnostic["opcode"] = diagnostic.opcode
            safeDiagnostic["guest_process_id"] = diagnostic.guestProcessID
            safeDiagnostic["guest_thread_group_id"] = diagnostic.guestThreadGroupID
            safeDiagnostic["process_name"] = diagnostic.processName
            safeDiagnostic["syscall_number"] = diagnostic.systemCallNumber
            safeDiagnostic["syscall_name"] = diagnostic.systemCallName
            let serializedDiagnostic = prettyPrintedJSONString(from: safeDiagnostic)
            let prefix = extraContext?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let diagnosticHeading = NSLocalizedString("Linux 运行时诊断：", comment: "Feedback Linux runtime diagnostic heading")
            extraContext = prefix.isEmpty
                ? "\(diagnosticHeading)\n\(serializedDiagnostic)"
                : prefix + "\n\n\(diagnosticHeading)\n" + serializedDiagnostic
        }

        let draft = FeedbackDraft(
            category: category,
            title: args.title,
            detail: args.detail,
            reproductionSteps: args.reproduction_steps,
            expectedBehavior: args.expected_behavior,
            actualBehavior: args.actual_behavior,
            extraContext: extraContext
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
    }

    @concurrent
    nonisolated func executeListMemories(argumentsJSON: String, memoryManager: MemoryManager = .shared) async throws -> String {
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
        let limit = min(max(1, args?.limit ?? 10), 25)
        let keyword = args?.query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sortDescending = (args?.order ?? "desc").lowercased() != "asc"

        let allMemories = await memoryManager.getAllMemories()
        let filtered = allMemories.filter { memory in
            guard includeArchived || !memory.isArchived else { return false }
            guard !keyword.isEmpty else { return true }
            return memory.content.localizedCaseInsensitiveContains(keyword) || memory.toolLabel == keyword
        }

        let sorted = filtered.sorted { lhs, rhs in
            let leftDate = lhs.updatedAt ?? lhs.createdAt
            let rightDate = rhs.updatedAt ?? rhs.createdAt
            if leftDate == rightDate { return lhs.id.uuidString < rhs.id.uuidString }
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
            "items": try paged.map { item in
                var payload: [String: Any] = [
                    "label": item.toolLabel,
                    "version": try item.toolVersion,
                    "content": item.content,
                    "isArchived": item.isArchived,
                    "kind": item.kind.rawValue,
                    "source": item.source.rawValue,
                    "importance": item.importance,
                    "confidence": item.confidence,
                    "entities": item.entities,
                    "accessCount": item.accessCount,
                    "createdAt": formatter.string(from: item.createdAt),
                    "updatedAt": item.updatedAt.map(formatter.string(from:)) as Any
                ]
                if let validFrom = item.validFrom { payload["validFrom"] = formatter.string(from: validFrom) }
                if let validUntil = item.validUntil { payload["validUntil"] = formatter.string(from: validUntil) }
                return payload
            }
        ]
        return prettyPrintedJSONString(from: payload)
    }
}
