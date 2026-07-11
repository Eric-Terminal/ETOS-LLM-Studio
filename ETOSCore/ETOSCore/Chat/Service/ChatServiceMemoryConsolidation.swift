// ============================================================================
// ChatServiceMemoryConsolidation.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责在聊天完成后低频整理长期记忆，并安全应用重复项合并计划。
// ============================================================================

import Foundation
import os.log

private extension MemoryConsolidationState {
    static func load() -> MemoryConsolidationState {
        guard let data = Persistence.readAppConfigData(
            key: AppConfigKey.memoryAutoConsolidationState.rawValue
        ), let state = try? JSONDecoder().decode(MemoryConsolidationState.self, from: data) else {
            return MemoryConsolidationState()
        }
        return state
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        Persistence.writeAppConfig(
            key: AppConfigKey.memoryAutoConsolidationState.rawValue,
            data: data
        )
    }
}

extension ChatService {
    func scheduleLongTermMemoryConsolidationIfNeeded(
        for sessionID: UUID?,
        enableMemory: Bool
    ) {
        guard enableMemory else { return }

        Task { [weak self] in
            let writeEnabled = Persistence.readAppConfigInteger(
                key: AppConfigKey.enableMemoryWrite.rawValue
            ) ?? 1
            let consolidationEnabled = Persistence.readAppConfigInteger(
                key: AppConfigKey.enableMemoryAutoConsolidation.rawValue
            ) ?? 1
            guard writeEnabled != 0, consolidationEnabled != 0 else { return }
            await self?.performLongTermMemoryConsolidationIfNeeded(sessionID: sessionID)
        }
    }

    private func performLongTermMemoryConsolidationIfNeeded(sessionID: UUID?) async {
        guard await MemoryConsolidationExecutionGate.shared.claim() else { return }
        defer {
            Task {
                await MemoryConsolidationExecutionGate.shared.release()
            }
        }

        let now = Date()
        let memories = await memoryManager.getAllMemories()
        var state = MemoryConsolidationState.load()
        guard LongTermMemoryConsolidationPlanner.shouldRun(
            memories: memories,
            state: state,
            now: now
        ), let runnableModel = resolvedConversationSummaryModel() else {
            return
        }

        let candidates = LongTermMemoryConsolidationPlanner.candidates(from: memories, now: now)
        guard let candidateJSON = LongTermMemoryConsolidationPlanner.candidateJSON(from: candidates) else {
            return
        }

        // 先记录尝试时间，避免网络故障时在每次聊天后重复请求。
        state.lastAttemptAt = now
        state.save()

        do {
            let response = try await generateDetachedChatCompletion(
                systemPrompt: NSLocalizedString(
                    "长期记忆整理系统提示词",
                    comment: "Long-term memory consolidation system prompt"
                ),
                userPrompt: String(
                    format: NSLocalizedString(
                        "长期记忆整理用户提示词",
                        comment: "Long-term memory consolidation user prompt"
                    ),
                    candidateJSON
                ),
                temperature: 0.1,
                runnableModel: runnableModel,
                requestSource: .memoryConsolidation,
                sessionID: sessionID
            )

            guard let plan = LongTermMemoryConsolidationPlanner.plan(
                from: response,
                candidates: candidates
            ) else {
                logger.warning("长期记忆整理返回了无效 JSON，已跳过本次修改。")
                return
            }

            let result = await applyMemoryConsolidationPlan(plan, now: now)
            state.lastSuccessAt = now
            state.save()
            logger.info(
                "长期记忆整理完成：合并组数 \(plan.merges.count)，归档重复项 \(result.archivedCount) 条，结束旧事实 \(result.expiredCount) 条。"
            )
        } catch {
            logger.warning("长期记忆整理失败：\(error.localizedDescription)")
        }
    }

    private func applyMemoryConsolidationPlan(
        _ plan: MemoryConsolidationPlan,
        now: Date
    ) async -> (archivedCount: Int, expiredCount: Int) {
        var archivedCount = 0
        var expiredCount = 0

        for operation in plan.merges {
            let latestMemories = await memoryManager.getAllMemories()
            let memoriesByID = Dictionary(uniqueKeysWithValues: latestMemories.map { ($0.id, $0) })
            guard var keeper = memoriesByID[operation.keeperID],
                  keeper.isValid(at: now) else {
                continue
            }

            let duplicates = operation.duplicateIDs.compactMap { memoriesByID[$0] }.filter {
                $0.isValid(at: now)
                    && LongTermMemoryConsolidationPlanner.isLikelyDuplicate(keeper, $0)
            }
            guard !duplicates.isEmpty else { continue }

            let mergedMemories = [keeper] + duplicates
            keeper.content = operation.canonicalContent
            keeper.importance = mergedMemories.map(\.importance).max() ?? keeper.importance
            keeper.confidence = mergedMemories.map(\.confidence).max() ?? keeper.confidence
            keeper.entities = Array(Set(mergedMemories.flatMap(\.entities))).sorted()
            await memoryManager.updateMemory(item: keeper)

            for duplicate in duplicates {
                await memoryManager.archiveMemory(duplicate)
                archivedCount += 1
            }
        }

        for operation in plan.supersessions {
            let latestMemories = await memoryManager.getAllMemories()
            let memoriesByID = Dictionary(uniqueKeysWithValues: latestMemories.map { ($0.id, $0) })
            guard var older = memoriesByID[operation.olderID],
                  let newer = memoriesByID[operation.newerID],
                  older.isValid(at: now),
                  newer.isValid(at: now),
                  newer.createdAt > older.createdAt,
                  LongTermMemoryConsolidationPlanner.isLikelySameSubject(older, newer) else {
                continue
            }

            older.validUntil = operation.validUntil
            await memoryManager.updateMemory(item: older)
            expiredCount += 1
        }

        return (archivedCount, expiredCount)
    }
}

private actor MemoryConsolidationExecutionGate {
    static let shared = MemoryConsolidationExecutionGate()

    private var isRunning = false

    func claim() -> Bool {
        guard !isRunning else { return false }
        isRunning = true
        return true
    }

    func release() {
        isRunning = false
    }
}
