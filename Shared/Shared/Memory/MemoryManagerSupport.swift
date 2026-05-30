// ============================================================================
// MemoryManagerSupport.swift
// ============================================================================
// ETOS LLM Studio
//
// 记忆管理器的嵌入、检索、补偿和索引支撑逻辑。
// ============================================================================

import Foundation
import Combine
import NaturalLanguage
import os.log

extension MemoryManager {
    func preferredEmbeddingModelIdentifier() -> String? {
        Persistence.readAppConfigText(key: AppConfigKey.memoryEmbeddingModelIdentifier.rawValue)
    }

    public func isEmbeddingModelConfigured() -> Bool {
        hasConfiguredEmbeddingModel()
    }

    func hasConfiguredEmbeddingModel() -> Bool {
        if !(embeddingGenerator is CloudEmbeddingService) {
            return true
        }

        guard let selectedModelID = preferredEmbeddingModelIdentifier(),
              !selectedModelID.isEmpty else {
            return false
        }

        let localModelStore = LocalModelStore.shared
        let providers = LocalModelProviderBridge.applyingLocalProvider(
            to: ConfigLoader.loadProviders(),
            records: localModelStore.models,
            isEnabled: localModelStore.isProviderEnabled,
            preferRecordBasics: true
        )
        for provider in providers {
            for model in provider.models {
                let runnable = RunnableModel(provider: provider, model: model)
                if runnable.id == selectedModelID {
                    return model.supportsEmbedding
                }
            }
        }
        return false
    }

    func isHardError(_ error: Error) -> Bool {
        if let embeddingError = error as? MemoryEmbeddingError {
            switch embeddingError {
            case .httpStatus(let code, _):
                return (400...499).contains(code)
            case .noAvailableModel, .preferredModelUnavailable, .adapterMissing, .requestBuildFailed:
                return true
            default:
                return false
            }
        }
        return false
    }

    func notifyEmbeddingErrorIfNeeded(_ error: Error) {
        if let embeddingError = error as? MemoryEmbeddingError, isHardError(error) {
            internalEmbeddingErrorPublisher.send(embeddingError)
        }
    }

    func persistRawMemories() {
        let memoriesToPersist = cachedMemories
        persistenceQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.rawStore.saveMemories(memoriesToPersist)
                self.logger.info("原文记忆已保存。")
            } catch {
                self.logger.error("保存原文记忆失败: \(error.localizedDescription)")
            }
        }
    }

    func scheduleConsistencyCheck(after delay: TimeInterval = 0) {
        let shouldSchedule = autoRetryStateQueue.sync { () -> Bool in
            guard !autoReconcileSuspendedByHardError else { return false }
            guard !consistencyCheckScheduled else { return false }
            consistencyCheckScheduled = true
            return true
        }
        guard shouldSchedule else { return }

        Task {
            defer {
                autoRetryStateQueue.sync {
                    consistencyCheckScheduled = false
                }
            }
            if delay > 0 {
                let nanoseconds = UInt64(delay * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
            }
            _ = await reconcilePendingEmbeddings()
        }
    }

    @discardableResult
    func reconcilePendingEmbeddings() async -> Int {
        refreshAutoReconcileStateIfModelChanged()

        let suspendedByHardError = autoRetryStateQueue.sync { autoReconcileSuspendedByHardError }
        if suspendedByHardError {
            logger.warning("检测到嵌入硬错误，自动补偿已熔断，等待用户修正配置后再恢复。")
            return 0
        }

        let memoryIDs = Set(cachedMemories.map { $0.id })
        guard !memoryIDs.isEmpty else { return 0 }

        guard hasConfiguredEmbeddingModel() else {
            logger.info("尚未选择嵌入模型，跳过自动补偿嵌入。")
            return 0
        }

        removeOrphanedVectorEntries(validMemoryIDs: memoryIDs)
        let missingMemories = memoriesMissingEmbeddings(validMemoryIDs: memoryIDs).filter { shouldAttemptAutoReconcile(for: $0.id) }
        guard !missingMemories.isEmpty else { return 0 }

        logger.info("检测到 \(missingMemories.count) 条记忆缺少嵌入，尝试自动补偿。")
        let jobID = UUID()
        let totalMemories = missingMemories.count
        var processedMemories = 0
        var failedMemories = 0
        publishEmbeddingProgress(
            jobID: jobID,
            kind: .reconcilePending,
            phase: .running,
            processedMemories: 0,
            totalMemories: totalMemories,
            failedMemories: 0,
            currentMemoryPreview: nil,
            errorMessage: nil
        )

        for memory in missingMemories {
            let succeeded = await backfillEmbedding(for: memory)
            processedMemories += 1
            if !succeeded {
                failedMemories += 1
            }
            publishEmbeddingProgress(
                jobID: jobID,
                kind: .reconcilePending,
                phase: .running,
                processedMemories: processedMemories,
                totalMemories: totalMemories,
                failedMemories: failedMemories,
                currentMemoryPreview: embeddingProgressPreview(for: memory),
                errorMessage: nil
            )
        }

        if failedMemories == 0 {
            publishEmbeddingProgress(
                jobID: jobID,
                kind: .reconcilePending,
                phase: .completed,
                processedMemories: processedMemories,
                totalMemories: totalMemories,
                failedMemories: failedMemories,
                currentMemoryPreview: nil,
                errorMessage: nil
            )
        } else {
            publishEmbeddingProgress(
                jobID: jobID,
                kind: .reconcilePending,
                phase: .failed,
                processedMemories: processedMemories,
                totalMemories: totalMemories,
                failedMemories: failedMemories,
                currentMemoryPreview: nil,
                errorMessage: NSLocalizedString(
                    "部分记忆嵌入失败，系统将自动重试。",
                    comment: "Memory reconcile embedding progress failed message."
                )
            )
        }

        return missingMemories.count
    }

    func memoriesMissingEmbeddings(validMemoryIDs: Set<UUID>) -> [MemoryItem] {
        guard !similarityIndex.indexItems.isEmpty else {
            return cachedMemories.filter { validMemoryIDs.contains($0.id) }
        }

        let indexedParentIDs = Set(similarityIndex.indexItems.compactMap { item -> UUID? in
            if let parentId = item.metadata["parentMemoryId"], let uuid = UUID(uuidString: parentId) {
                return uuid
            }
            return UUID(uuidString: item.id)
        })

        return cachedMemories.filter { validMemoryIDs.contains($0.id) && !indexedParentIDs.contains($0.id) }
    }

    func backfillEmbedding(for memory: MemoryItem) async -> Bool {
        let chunkTexts = chunker.chunk(text: memory.content)
        guard !chunkTexts.isEmpty else {
            logger.error("记忆 \(memory.id.uuidString) 内容无法分块，跳过补偿。")
            return false
        }

        do {
            let embeddings = try await embeddingsWithRetry(for: chunkTexts)
            await ingest(memory: memory, chunkTexts: chunkTexts, embeddings: embeddings)
            logger.info("已补齐记忆嵌入：\(memory.id.uuidString)。")
            return true
        } catch {
            logger.error("补写记忆嵌入失败：\(error.localizedDescription)")
            notifyEmbeddingErrorIfNeeded(error)
            if shouldScheduleAutoRetry(for: memory.id, error: error) {
                scheduleConsistencyCheck(after: max(consistencyCheckDefaultDelay, embeddingRetryPolicy.initialDelay))
            }
            return false
        }
    }

    func refreshAutoReconcileStateIfModelChanged() {
        let currentIdentifier = preferredEmbeddingModelIdentifier() ?? ""
        let didReset = autoRetryStateQueue.sync { () -> Bool in
            if autoReconcileModelIdentifierSnapshot == currentIdentifier {
                return false
            }
            autoReconcileModelIdentifierSnapshot = currentIdentifier
            autoReconcileFailureCounts.removeAll()
            autoReconcileSuspendedByHardError = false
            consistencyCheckScheduled = false
            return true
        }
        if didReset {
            logger.info("嵌入模型已变更，自动补偿重试状态已重置。")
        }
    }

    func shouldAttemptAutoReconcile(for memoryID: UUID) -> Bool {
        autoRetryStateQueue.sync {
            (autoReconcileFailureCounts[memoryID] ?? 0) < maxAutoReconcileAttemptsPerMemory
        }
    }

    private enum AutoRetryDecision {
        case schedule
        case stopByLimit(currentAttempt: Int)
        case stopByHardError
        case stopByFuse
    }

    func shouldScheduleAutoRetry(for memoryID: UUID, error: Error) -> Bool {
        refreshAutoReconcileStateIfModelChanged()

        let decision = autoRetryStateQueue.sync { () -> AutoRetryDecision in
            if autoReconcileSuspendedByHardError {
                return .stopByFuse
            }

            if isHardError(error) {
                autoReconcileSuspendedByHardError = true
                autoReconcileFailureCounts[memoryID] = maxAutoReconcileAttemptsPerMemory
                return .stopByHardError
            }

            let currentAttempt = (autoReconcileFailureCounts[memoryID] ?? 0) + 1
            autoReconcileFailureCounts[memoryID] = currentAttempt

            if currentAttempt >= maxAutoReconcileAttemptsPerMemory {
                return .stopByLimit(currentAttempt: currentAttempt)
            }
            return .schedule
        }

        switch decision {
        case .schedule:
            return true
        case .stopByLimit(let currentAttempt):
            logger.error("记忆 \(memoryID.uuidString) 自动补偿重试次数达到上限（\(currentAttempt) 次），停止自动重试。")
            return false
        case .stopByHardError:
            logger.fault("检测到嵌入硬错误，自动补偿已熔断，停止后续自动重试。")
            return false
        case .stopByFuse:
            logger.warning("自动补偿处于熔断状态，跳过本次重试。")
            return false
        }
    }

    func resetAutoRetryState(for memoryID: UUID) {
        autoRetryStateQueue.sync {
            _ = autoReconcileFailureCounts.removeValue(forKey: memoryID)
        }
    }

    func resetAutoRetryState(for memoryIDs: Set<UUID>) {
        guard !memoryIDs.isEmpty else { return }
        autoRetryStateQueue.sync {
            for memoryID in memoryIDs {
                autoReconcileFailureCounts.removeValue(forKey: memoryID)
            }
        }
    }

    func resetAllAutoRetryState() {
        autoRetryStateQueue.sync {
            autoReconcileFailureCounts.removeAll()
            autoReconcileSuspendedByHardError = false
            consistencyCheckScheduled = false
        }
    }

    func publishEmbeddingProgress(
        jobID: UUID,
        kind: MemoryEmbeddingJobKind,
        phase: MemoryEmbeddingJobPhase,
        processedMemories: Int,
        totalMemories: Int,
        failedMemories: Int,
        currentMemoryPreview: String?,
        errorMessage: String?
    ) {
        internalEmbeddingProgressPublisher.send(
            MemoryEmbeddingProgress(
                jobID: jobID,
                kind: kind,
                phase: phase,
                processedMemories: processedMemories,
                totalMemories: totalMemories,
                failedMemories: failedMemories,
                currentMemoryPreview: currentMemoryPreview,
                errorMessage: errorMessage
            )
        )
    }

    func embeddingProgressPreview(for memory: MemoryItem, maxLength: Int = 24) -> String {
        let trimmed = memory.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.count <= maxLength {
            return trimmed
        }
        let endIndex = trimmed.index(trimmed.startIndex, offsetBy: maxLength)
        return String(trimmed[..<endIndex]) + "…"
    }

    func removeOrphanedVectorEntries(validMemoryIDs: Set<UUID>) {
        guard !similarityIndex.indexItems.isEmpty else { return }
        let orphanChunkIDs = similarityIndex.indexItems.compactMap { item -> String? in
            guard let parentId = item.metadata["parentMemoryId"],
                  let uuid = UUID(uuidString: parentId) else {
                return nil
            }
            return validMemoryIDs.contains(uuid) ? nil : item.id
        }
        guard !orphanChunkIDs.isEmpty else { return }

        for chunkId in orphanChunkIDs {
            similarityIndex.removeItem(id: chunkId)
        }
        logger.info("已移除 \(orphanChunkIDs.count) 条孤立的向量分块。")
        saveIndex()
    }

    func removeVectorEntries(for ids: Set<UUID>) {
        let idsAsString = Set(ids.map { $0.uuidString })
        let itemsToRemove = similarityIndex.indexItems.filter { item in
            if idsAsString.contains(item.id) { return true }
            if let parentID = item.metadata["parentMemoryId"], idsAsString.contains(parentID) {
                return true
            }
            return false
        }

        for item in itemsToRemove {
            similarityIndex.removeItem(id: item.id)
        }
    }

    func purgePersistedVectorStores() {
        let directory = MemoryStoragePaths.vectorStoreDirectory(rootDirectory: storageRootDirectory)
        let fileManager = FileManager.default
        do {
            let files = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            let sqliteFiles = files.filter {
                $0.pathExtension == "sqlite" &&
                $0.deletingPathExtension().lastPathComponent.contains(MemoryStoragePaths.vectorStoreName)
            }
            for file in sqliteFiles {
                try fileManager.removeItem(at: file)
                logger.info("已删除旧向量存储：\(file.lastPathComponent)")
            }
        } catch {
            logger.error("清理旧向量存储失败：\(error.localizedDescription)")
        }
    }

    func chunkMetadata(for memory: MemoryItem, chunkIndex: Int, chunkId: String) -> [String: String] {
        [
            "createdAt": dateFormatter.string(from: memory.createdAt),
            "parentMemoryId": memory.id.uuidString,
            "chunkIndex": String(chunkIndex),
            "chunkId": chunkId
        ]
    }

    func resolveUniqueMemories(from results: [SearchResult], limit: Int) -> [MemoryItem] {
        guard limit > 0 else { return [] }
        var uniqueMemories: [MemoryItem] = []
        var seenParentIDs = Set<UUID>()
        var seenChunkIDs = Set<String>()

        for result in results {
            if let parentIdString = result.metadata["parentMemoryId"],
               let parentId = UUID(uuidString: parentIdString) {
                guard !seenParentIDs.contains(parentId) else { continue }
                if let memory = cachedMemories.first(where: { $0.id == parentId }) {
                    guard !memory.isArchived else { continue }
                    uniqueMemories.append(memory)
                    seenParentIDs.insert(parentId)
                } else {
                    logger.error("找不到 parentMemoryId=\(parentId.uuidString) 对应的原文，使用分块文本作为回退。")
                    uniqueMemories.append(MemoryItem(from: result))
                    seenParentIDs.insert(parentId)
                }
            } else {
                logger.error("分块缺少 parentMemoryId 元数据，使用分块文本作为回退。")
                guard !seenChunkIDs.contains(result.id) else { continue }
                uniqueMemories.append(MemoryItem(from: result))
                seenChunkIDs.insert(result.id)
            }

            if uniqueMemories.count >= limit {
                break
            }
        }

        return uniqueMemories
    }

    func embeddingsWithRetry(for chunkTexts: [String]) async throws -> [[Float]] {
        let preferredModelID = preferredEmbeddingModelIdentifier()
        var attempt = 0
        var currentDelay = embeddingRetryPolicy.initialDelay

        while attempt < embeddingRetryPolicy.maxAttempts {
            attempt += 1
            do {
                let embeddings = try await embeddingGenerator.generateEmbeddings(
                    for: chunkTexts,
                    preferredModelID: preferredModelID
                )
                try validateEmbeddings(embeddings, matches: chunkTexts)
                return embeddings
            } catch {
                if isHardError(error) {
                    logger.fault("遇到硬错误，停止重试：\(error.localizedDescription)")
                    throw error
                }

                logger.error("嵌入生成失败（第 \(attempt) 次）：\(error.localizedDescription)")
                if attempt >= embeddingRetryPolicy.maxAttempts {
                    logger.fault("超过最大嵌入重试次数，放弃本次记忆写入。")
                    throw error
                }

                if currentDelay > 0 {
                    let nanoseconds = UInt64(currentDelay * 1_000_000_000)
                    try? await Task.sleep(nanoseconds: nanoseconds)
                } else {
                    await Task.yield()
                }
                currentDelay *= embeddingRetryPolicy.backoffMultiplier
            }
        }

        throw MemoryEmbeddingError.invalidResponse
    }

    func keywordTokens(from query: String) -> [String] {
        let normalized = normalizedKeywordSearchText(query)
        guard !normalized.isEmpty else { return [] }

        var tokens: [String] = []
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = normalized
        tokenizer.enumerateTokens(in: normalized.startIndex..<normalized.endIndex) { range, _ in
            let token = String(normalized[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !token.isEmpty {
                tokens.append(token)
            }
            return true
        }

        if tokens.isEmpty {
            let parts = normalized
                .split(whereSeparator: { character in
                    character.unicodeScalars.allSatisfy { scalar in
                        CharacterSet.whitespacesAndNewlines.contains(scalar)
                            || CharacterSet.punctuationCharacters.contains(scalar)
                            || CharacterSet.symbols.contains(scalar)
                    }
                })
                .map(String.init)
            tokens.append(contentsOf: parts)
        }

        if tokens.isEmpty {
            tokens.append(normalized)
        }

        var seen = Set<String>()
        var deduplicated: [String] = []
        for token in tokens {
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if seen.insert(trimmed).inserted {
                deduplicated.append(trimmed)
            }
        }
        return deduplicated
    }

    func normalizedKeywordSearchText(_ text: String) -> String {
        text
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func occurrenceCount(of token: String, in text: String) -> Int {
        guard !token.isEmpty, !text.isEmpty else { return 0 }
        var count = 0
        var searchRange = text.startIndex..<text.endIndex
        while let range = text.range(of: token, options: [], range: searchRange) {
            count += 1
            searchRange = range.upperBound..<text.endIndex
        }
        return count
    }

    func validateEmbeddings(_ embeddings: [[Float]], matches texts: [String]) throws {
        guard embeddings.count == texts.count else {
            throw MemoryEmbeddingError.resultCountMismatch(expected: texts.count, actual: embeddings.count)
        }

        guard embeddings.allSatisfy({ !$0.isEmpty }) else {
            throw MemoryEmbeddingError.invalidResponse
        }
    }

    func saveIndex() {
        let directory = MemoryStoragePaths.vectorStoreDirectory(rootDirectory: storageRootDirectory)
        persistenceQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                _ = try self.similarityIndex.saveIndex(
                    toDirectory: directory,
                    name: MemoryStoragePaths.vectorStoreName
                )
                self.logger.info("向量索引已保存。")
            } catch {
                self.logger.error("自动保存记忆索引失败: \(error.localizedDescription)")
            }
        }
    }

    func ingest(memory: MemoryItem, chunkTexts: [String], embeddings: [[Float]]) async {
        guard chunkTexts.count == embeddings.count else {
            logger.error("嵌入数量与分块数量不一致，取消写入。")
            return
        }

        for (index, chunkText) in chunkTexts.enumerated() {
            let chunkID = UUID().uuidString
            let metadata = chunkMetadata(for: memory, chunkIndex: index, chunkId: chunkID)

            await similarityIndex.addItem(
                id: chunkID,
                text: chunkText,
                metadata: metadata,
                embedding: embeddings[index]
            )
        }

        cacheMemory(memory)
        resetAutoRetryState(for: memory.id)
        saveIndex()
    }

    func cacheMemory(_ memory: MemoryItem) {
        if let index = cachedMemories.firstIndex(where: { $0.id == memory.id }) {
            cachedMemories[index] = memory
        } else {
            cachedMemories.append(memory)
        }
        cachedMemories.sort(by: { $0.createdAt > $1.createdAt })
        internalMemoriesPublisher.send(cachedMemories)
        persistRawMemories()
    }
}

extension MemoryItem {
    init(from indexItem: IndexItem) {
        self.id = UUID(uuidString: indexItem.id) ?? UUID()
        self.content = indexItem.text
        self.embedding = indexItem.embedding

        if let dateString = indexItem.metadata["createdAt"], let date = ISO8601DateFormatter().date(from: dateString) {
            self.createdAt = date
        } else {
            self.createdAt = Date()
        }

        self.isArchived = false
    }

    init(from searchResult: SearchResult) {
        self.id = UUID(uuidString: searchResult.id) ?? UUID()
        self.content = searchResult.text
        self.embedding = []

        if let dateString = searchResult.metadata["createdAt"], let date = ISO8601DateFormatter().date(from: dateString) {
            self.createdAt = date
        } else {
            self.createdAt = Date()
        }

        self.isArchived = false
    }
}
