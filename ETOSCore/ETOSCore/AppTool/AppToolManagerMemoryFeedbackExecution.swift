// ============================================================================
// AppToolManagerMemoryFeedbackExecution.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件承载本地拓展工具中的记忆管理与反馈工单执行逻辑。
// ============================================================================

import Foundation

extension AppToolManager {
    func executeEditMemory(argumentsJSON: String) async throws -> String {
        struct EditMemoryArgs: Decodable {
            let memory_id: String
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

        let embeddingConfigured = MemoryManager.shared.isEmbeddingModelConfigured()
        let resultPayload: [String: Any]
        let formatter = ISO8601DateFormatter()

        if let kind = args.kind, MemoryKind(rawValue: kind) == nil {
            throw AppToolExecutionError.invalidArguments(
                NSLocalizedString("错误：edit_memory 的 kind 不受支持。", comment: "Memory edit unsupported kind")
            )
        }
        let validFrom = try parseMemoryDate(args.valid_from, field: "valid_from", formatter: formatter)
        let validUntil = try parseMemoryDate(args.valid_until, field: "valid_until", formatter: formatter)

        if hasContentUpdate || hasMetadataUpdate {
            var updated = existing
            updated.content = trimmedContent ?? existing.content
            if let isArchived = args.is_archived {
                updated.isArchived = isArchived
            }
            if let kind = args.kind.flatMap(MemoryKind.init(rawValue:)) { updated.kind = kind }
            if let importance = args.importance { updated.importance = min(max(importance, 0), 1) }
            if let confidence = args.confidence { updated.confidence = min(max(confidence, 0), 1) }
            if let entities = args.entities { updated.entities = entities }
            if args.valid_from != nil { updated.validFrom = validFrom }
            if args.valid_until != nil { updated.validUntil = validUntil }
            await MemoryManager.shared.updateMemory(item: updated)
            resultPayload = [
                "memory_id": existing.id.uuidString,
                "content": updated.content,
                "isArchived": updated.isArchived,
                "kind": updated.kind.rawValue,
                "importance": updated.importance,
                "confidence": updated.confidence,
                "entities": updated.entities,
                "embeddingConfigured": embeddingConfigured,
                "reembedded": embeddingConfigured && hasContentUpdate
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
                NSLocalizedString("错误：edit_memory 没有提供任何可更新字段。", comment: "Memory edit tool missing update fields")
            )
        }

        return prettyPrintedJSONString(from: resultPayload)
    }

    private func parseMemoryDate(
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
    }

    func executeListMemories(argumentsJSON: String) async throws -> String {
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
                var payload: [String: Any] = [
                    "memory_id": item.id.uuidString,
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
