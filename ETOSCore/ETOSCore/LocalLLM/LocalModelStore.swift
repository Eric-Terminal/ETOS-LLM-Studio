// ============================================================================
// LocalModelStore.swift
// ============================================================================
// ETOS LLM Studio
//
// 管理本机 GGUF 权重文件和对应的本地元数据。
// ============================================================================

import Foundation
import Combine
import os.log

/// 同步磁盘接口由后台任务调用；跨线程列表读取仅取得已提交的内存快照。
public final class LocalModelStore: ObservableObject, @unchecked Sendable {
    public static let shared = LocalModelStore()
    public static let directoryName = "LocalModels"

    private static let metadataFileName = "local-models.json"
    private let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "LocalModelStore")
    private let fileManager: FileManager
    private let directoryOverride: URL?
    // 文件与元数据写入串行化；展示快照使用独立的短锁，读取列表不会等待大权重复制。
    private let storageLock = NSRecursiveLock()
    private let snapshotLock = NSLock()
    private var records: [LocalModelRecord] = []
    private var snapshot: [LocalModelRecord] = []
    public let objectWillChange = ObservableObjectPublisher()

    public var models: [LocalModelRecord] {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return snapshot
    }

    public init(fileManager: FileManager = .default, directoryURL: URL? = nil) {
        self.fileManager = fileManager
        self.directoryOverride = directoryURL
        self.records = loadModels()
        self.snapshot = records
    }

    public var directoryURL: URL {
        if let directoryOverride {
            ensureDirectoryExists(directoryOverride)
            return directoryOverride
        }
        return Self.localModelsDirectoryURL(fileManager: fileManager)
    }

    public static func localModelsDirectoryURL(fileManager: FileManager = .default) -> URL {
        let documents = StorageUtility.documentsDirectory
        let directory = documents.appendingPathComponent(directoryName, isDirectory: true)
        if !fileManager.fileExists(atPath: directory.path) {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    @discardableResult
    public func reload() -> Bool {
        storageLock.lock()
        defer { storageLock.unlock() }
        let reloadedModels = loadModels()
        guard reloadedModels != records else { return false }
        records = reloadedModels
        publishModels(notifyProvider: false)
        return true
    }

    public var isProviderEnabled: Bool {
        AppConfigStore.boolValue(for: .localModelsEnabled)
    }

    public func setProviderEnabled(_ isEnabled: Bool) {
        AppConfigStore.persistSynchronously(.bool(isEnabled), for: .localModelsEnabled)
        DispatchQueue.main.async {
            if AppConfigStore.shared.localModelsEnabled != isEnabled {
                AppConfigStore.shared.localModelsEnabled = isEnabled
            }
        }
        notifyProviderChanged()
    }

    /// 文件任务返回后，先排空它已经提交的 UI 更新，再等待 AppConfig 的数据库写入。
    public func waitForPendingUIUpdates() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    public func fileURL(for record: LocalModelRecord) -> URL {
        directoryURL.appendingPathComponent(record.relativePath)
    }

    public func fileExists(for record: LocalModelRecord) -> Bool {
        fileManager.fileExists(atPath: fileURL(for: record).path)
    }

    public func mmprojURL(for record: LocalModelRecord) -> URL? {
        guard let relativePath = record.mmprojRelativePath?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
            return nil
        }
        return directoryURL.appendingPathComponent(relativePath)
    }

    public func mmprojFileExists(for record: LocalModelRecord) -> Bool {
        guard let url = mmprojURL(for: record) else { return false }
        return fileManager.fileExists(atPath: url.path)
    }

    public func loraURL(for record: LocalModelRecord) -> URL? {
        guard let relativePath = record.loraRelativePath?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
            return nil
        }
        return directoryURL.appendingPathComponent(relativePath)
    }

    public func loraFileExists(for record: LocalModelRecord) -> Bool {
        guard let url = loraURL(for: record) else { return false }
        return fileManager.fileExists(atPath: url.path)
    }

    public func importModel(from sourceURL: URL, displayName: String? = nil, mmprojURL: URL? = nil) throws -> LocalModelRecord {
        storageLock.lock()
        defer { storageLock.unlock() }
        let didStartSecurityScope = sourceURL.startAccessingSecurityScopedResource()
        let didStartProjectorSecurityScope = mmprojURL?.startAccessingSecurityScopedResource() ?? false
        defer {
            if didStartSecurityScope {
                sourceURL.stopAccessingSecurityScopedResource()
            }
            if didStartProjectorSecurityScope {
                mmprojURL?.stopAccessingSecurityScopedResource()
            }
        }

        let sourceFileName = sourceURL.lastPathComponent
        let destinationFileName = uniqueFileName(for: sourceFileName)
        let destinationURL = directoryURL.appendingPathComponent(destinationFileName)
        var importedProjector: ImportedProjectorFile?
        do {
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
            importedProjector = try mmprojURL.map { try copyProjectorFile(from: $0) }
            return try registerImportedFile(
                fileName: destinationFileName,
                displayName: displayName ?? sourceURL.deletingPathExtension().lastPathComponent,
                importedProjector: importedProjector
            )
        } catch {
            try? fileManager.removeItem(at: destinationURL)
            if let importedProjector {
                try? fileManager.removeItem(
                    at: directoryURL.appendingPathComponent(importedProjector.relativePath)
                )
            }
            throw error
        }
    }

    public func registerDownloadedModel(fileAt sourceURL: URL, suggestedFileName: String, displayName: String? = nil) throws -> LocalModelRecord {
        storageLock.lock()
        defer { storageLock.unlock() }
        let destinationFileName = uniqueFileName(for: suggestedFileName)
        let destinationURL = directoryURL.appendingPathComponent(destinationFileName)
        try fileManager.moveItem(at: sourceURL, to: destinationURL)
        do {
            return try registerImportedFile(
                fileName: destinationFileName,
                displayName: displayName ?? URL(fileURLWithPath: suggestedFileName).deletingPathExtension().lastPathComponent
            )
        } catch {
            try? fileManager.removeItem(at: destinationURL)
            throw error
        }
    }

    public func update(_ record: LocalModelRecord) {
        storageLock.lock()
        defer { storageLock.unlock() }
        do {
            try saveRecord(record)
        } catch {
            logger.error("写入本地模型元数据失败: \(error.localizedDescription)")
        }
    }

    /// 版本检查和落盘共用写锁，旧编辑器不能复活已删除的权重或覆盖另一处修改。
    @discardableResult
    public func saveDraft(_ draft: LocalModelRecord, replacing original: LocalModelRecord) throws -> LocalModelRecord {
        storageLock.lock()
        defer { storageLock.unlock() }
        guard draft.id == original.id, records.first(where: { $0.id == original.id }) == original else {
            throw LocalModelDraftWriteError.changedExternally
        }
        return try saveRecord(draft)
    }

    @discardableResult
    private func saveRecord(_ record: LocalModelRecord) throws -> LocalModelRecord {
        var updated = record
        updated.displayName = updated.sanitizedDisplayName
        updated.normalizeGenerationParameters()
        updated.updatedAt = Date()

        var nextRecords = records
        let oldRecord = records.first { $0.id == updated.id }
        if let index = nextRecords.firstIndex(where: { $0.id == updated.id }) {
            nextRecords[index] = updated
        } else {
            nextRecords.append(updated)
        }
        // 先原子写元数据，再发布和清理旧附件；失败时旧快照及其文件仍然可用。
        try persistModels(nextRecords)
        records = nextRecords
        if let oldRecord {
            removeProjectorFileIfUnreferenced(from: oldRecord, replacingWith: updated)
            removeLoRAFileIfUnreferenced(from: oldRecord, replacingWith: updated)
        }
        publishModels()
        return updated
    }

    public func updateFromProviderModel(_ model: Model) {
        storageLock.lock()
        defer { storageLock.unlock() }
        guard let index = records.firstIndex(where: { $0.id == LocalModelProviderBridge.localRecordID(from: model) }) else {
            return
        }

        var record = records[index]
        record.displayName = model.displayName.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? record.sanitizedDisplayName
        record.isActivated = model.isActivated
        record.contextSize = model.overrideParameters.localIntValue(for: "context_size")
            ?? model.overrideParameters.localIntValue(for: "n_ctx")
        record.maxOutputTokens = model.overrideParameters.localIntValue(for: "max_output_tokens")
            ?? model.overrideParameters.localIntValue(for: "max_tokens")
        record.gpuLayers = model.overrideParameters.localIntValue(for: "n_gpu_layers")
        record.batchSize = model.overrideParameters.localIntValue(for: "batch_size")
            ?? model.overrideParameters.localIntValue(for: "n_batch")
        record.ubatchSize = model.overrideParameters.localIntValue(for: "ubatch_size")
            ?? model.overrideParameters.localIntValue(for: "n_ubatch")
        record.kvOffload = model.overrideParameters.localBoolValue(for: "kv_offload")
        record.flashAttention = model.overrideParameters.localFlashAttentionValue(for: "flash_attn")
        record.seed = model.overrideParameters.localUInt32Value(for: "seed")
        record.temperature = model.overrideParameters.localDoubleValue(for: "temperature")
        record.topK = model.overrideParameters.localIntValue(for: "top_k")
        record.topP = model.overrideParameters.localDoubleValue(for: "top_p")
        record.minP = model.overrideParameters.localDoubleValue(for: "min_p")
        record.repeatLastN = model.overrideParameters.localIntValue(for: "repeat_last_n")
        record.repeatPenalty = model.overrideParameters.localDoubleValue(for: "repeat_penalty")
        record.frequencyPenalty = model.overrideParameters.localDoubleValue(for: "frequency_penalty")
        record.presencePenalty = model.overrideParameters.localDoubleValue(for: "presence_penalty")
        record.grammar = model.overrideParameters.localStringValue(for: "grammar").flatMap {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
        record.ignoreEOS = model.overrideParameters.localBoolValue(for: "ignore_eos")
        record.imageMinTokens = model.overrideParameters.localIntValue(for: "image_min_tokens")
        record.imageMaxTokens = model.overrideParameters.localIntValue(for: "image_max_tokens")
        if let samplerSequence = model.overrideParameters.localStringValue(for: "sampler_seq") {
            let samplerKinds = LocalLLMSamplerKind.parse(samplerSequence)
            record.samplerKinds = samplerKinds.isEmpty ? nil : samplerKinds
        } else {
            record.samplerKinds = nil
        }
        record.advancedArguments = model.overrideParameters.localStringValue(for: "llama_cli_args")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? LocalModelRecord.defaultAdvancedArguments
        update(record)
    }

    public func delete(_ record: LocalModelRecord, deleteFile: Bool = true) {
        storageLock.lock()
        defer { storageLock.unlock() }
        do {
            try deleteRecord(record, deleteFile: deleteFile)
        } catch {
            logger.error("删除本地模型元数据失败: \(error.localizedDescription)")
        }
    }

    public func deleteDraft(_ original: LocalModelRecord, deleteFile: Bool = true) throws {
        storageLock.lock()
        defer { storageLock.unlock() }
        guard records.first(where: { $0.id == original.id }) == original else {
            throw LocalModelDraftWriteError.changedExternally
        }
        try deleteRecord(original, deleteFile: deleteFile)
    }

    private func deleteRecord(_ record: LocalModelRecord, deleteFile: Bool) throws {
        let storedRecord = records.first(where: { $0.id == record.id })
        var nextRecords = records.filter { $0.id != record.id }
        for index in nextRecords.indices {
            if nextRecords[index].speechDecoderModelID == record.id {
                nextRecords[index].speechDecoderModelID = nil
            }
            if nextRecords[index].speechVADModelID == record.id {
                nextRecords[index].speechVADModelID = nil
            }
        }
        try persistModels(nextRecords)
        records = nextRecords
        if deleteFile {
            if !records.contains(where: { $0.relativePath == (storedRecord ?? record).relativePath }) {
                try? fileManager.removeItem(at: fileURL(for: storedRecord ?? record))
            }
            let projectorPaths = Set([record.mmprojRelativePath, storedRecord?.mmprojRelativePath].compactMap { $0 })
            for relativePath in projectorPaths
                where !records.contains(where: { $0.mmprojRelativePath == relativePath }) {
                deleteProjectorFile(relativePath: relativePath)
            }
            let loraPaths = Set([record.loraRelativePath, storedRecord?.loraRelativePath].compactMap { $0 })
            for relativePath in loraPaths
                where !records.contains(where: { $0.loraRelativePath == relativePath }) {
                deleteLoRAFile(relativePath: relativePath)
            }
        }
        publishModels()
    }

    public func activatedModelsWithExistingFiles() -> [LocalModelRecord] {
        models.filter { $0.isActivated && fileExists(for: $0) }
    }

    @discardableResult
    public func copyMultimodalProjector(from sourceURL: URL, into record: inout LocalModelRecord) throws -> LocalModelRecord {
        storageLock.lock()
        defer { storageLock.unlock() }
        let didStartSecurityScope = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didStartSecurityScope {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }
        let importedProjector = try copyProjectorFile(from: sourceURL)
        record.mmprojFileName = importedProjector.fileName
        record.mmprojRelativePath = importedProjector.relativePath
        record.mmprojFileSize = importedProjector.fileSize
        record.normalizeGenerationParameters()
        return record
    }

    public func deleteProjectorFile(relativePath: String) {
        storageLock.lock()
        defer { storageLock.unlock() }
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !records.contains(where: { $0.mmprojRelativePath == trimmed }) else { return }
        try? fileManager.removeItem(at: directoryURL.appendingPathComponent(trimmed))
    }

    @discardableResult
    public func copyLoRAAdapter(from sourceURL: URL, into record: inout LocalModelRecord) throws -> LocalModelRecord {
        storageLock.lock()
        defer { storageLock.unlock() }
        let didStartSecurityScope = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didStartSecurityScope {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let importedAdapter = try copyLoRAFile(
            from: sourceURL,
            compatibleWith: record.ggufArchitecture
        )
        record.loraFileName = importedAdapter.fileName
        record.loraRelativePath = importedAdapter.relativePath
        record.loraFileSize = importedAdapter.fileSize
        record.loraScale = LocalModelRecord.defaultLoRAScale
        record.normalizeGenerationParameters()
        return record
    }

    public func copyLoRAAdapter(
        from sourceURL: URL,
        for record: LocalModelRecord,
        suggestedFileName: String? = nil
    ) async throws -> LocalModelRecord {
        return try await Task.detached(priority: .userInitiated) {
            try self.copyLoRADraft(from: sourceURL, for: record, suggestedFileName: suggestedFileName)
        }.value
    }

    private func copyLoRADraft(from sourceURL: URL, for record: LocalModelRecord, suggestedFileName: String?) throws -> LocalModelRecord {
        storageLock.lock()
        defer { storageLock.unlock() }
        let didStartSecurityScope = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didStartSecurityScope {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }
        let importedAdapter = try Self.copyLoRAFile(
            from: sourceURL,
            to: directoryURL,
            compatibleWith: record.ggufArchitecture,
            suggestedFileName: suggestedFileName,
            fileManager: fileManager
        )
        var updatedRecord = record
        updatedRecord.loraFileName = importedAdapter.fileName
        updatedRecord.loraRelativePath = importedAdapter.relativePath
        updatedRecord.loraFileSize = importedAdapter.fileSize
        updatedRecord.loraScale = LocalModelRecord.defaultLoRAScale
        updatedRecord.normalizeGenerationParameters()
        return updatedRecord
    }

    public func deleteLoRAFile(relativePath: String) {
        storageLock.lock()
        defer { storageLock.unlock() }
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !records.contains(where: { $0.loraRelativePath == trimmed }) else { return }
        try? fileManager.removeItem(at: directoryURL.appendingPathComponent(trimmed))
    }

    private func registerImportedFile(
        fileName: String,
        displayName: String,
        importedProjector: ImportedProjectorFile? = nil
    ) throws -> LocalModelRecord {
        let destinationURL = directoryURL.appendingPathComponent(fileName)
        let attributes = try fileManager.attributesOfItem(atPath: destinationURL.path)
        let size = attributes[.size] as? Int64 ?? 0
        let architecture = try LocalGGUFMetadata.validatedArchitecture(at: destinationURL)
        let now = Date()
        var record = LocalModelRecord(
            displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent,
            fileName: fileName,
            relativePath: fileName,
            fileSize: size,
            mmprojFileName: importedProjector?.fileName,
            mmprojRelativePath: importedProjector?.relativePath,
            mmprojFileSize: importedProjector?.fileSize,
            ggufArchitecture: architecture,
            createdAt: now,
            updatedAt: now
        )
        autoLinkSpeechCompanions(to: &record)
        var nextRecords = records
        nextRecords.append(record)
        linkNewSpeechCompanion(record, in: &nextRecords)
        try persistModels(nextRecords)
        records = nextRecords
        publishModels(notifyProvider: false)
        if !isProviderEnabled {
            setProviderEnabled(true)
        } else {
            notifyProviderChanged()
        }
        return record
    }

    private func autoLinkSpeechCompanions(to record: inout LocalModelRecord) {
        guard let architecture = record.speechArchitecture else { return }
        if architecture.requiresDecoderModel {
            record.speechDecoderModelID = records.first {
                $0.ggufArchitecture == "qwen3" && fileExists(for: $0)
            }?.id
        }
        if architecture.isTranscriptionModel {
            record.speechVADModelID = records.first {
                $0.speechArchitecture == .fsmnVAD && fileExists(for: $0)
            }?.id
        }
    }

    private func linkNewSpeechCompanion(_ record: LocalModelRecord, in models: inout [LocalModelRecord]) {
        if record.ggufArchitecture == "qwen3" {
            for index in models.indices where
                models[index].speechArchitecture == .funASRNanoEncoder
                    && models[index].speechDecoderModelID == nil {
                models[index].speechDecoderModelID = record.id
            }
        }
        if record.speechArchitecture == .fsmnVAD {
            for index in models.indices where
                models[index].isSpeechTranscriptionModel
                    && models[index].speechVADModelID == nil {
                models[index].speechVADModelID = record.id
            }
        }
    }

    private struct ImportedProjectorFile {
        var fileName: String
        var relativePath: String
        var fileSize: Int64
    }

    private struct ImportedLoRAFile {
        var fileName: String
        var relativePath: String
        var fileSize: Int64
    }

    private func copyProjectorFile(from sourceURL: URL) throws -> ImportedProjectorFile {
        let sourceFileName = sourceURL.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "mmproj.gguf"
        let destinationFileName = uniqueFileName(for: sourceFileName)
        let destinationURL = directoryURL.appendingPathComponent(destinationFileName)
        do {
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
            let attributes = try fileManager.attributesOfItem(atPath: destinationURL.path)
            return ImportedProjectorFile(
                fileName: destinationFileName,
                relativePath: destinationFileName,
                fileSize: attributes[.size] as? Int64 ?? 0
            )
        } catch {
            try? fileManager.removeItem(at: destinationURL)
            throw error
        }
    }

    private func copyLoRAFile(from sourceURL: URL, compatibleWith architecture: String?) throws -> ImportedLoRAFile {
        try Self.copyLoRAFile(
            from: sourceURL,
            to: directoryURL,
            compatibleWith: architecture,
            suggestedFileName: nil,
            fileManager: fileManager
        )
    }

    private static func copyLoRAFile(
        from sourceURL: URL,
        to destinationDirectory: URL,
        compatibleWith architecture: String?,
        suggestedFileName: String?,
        fileManager: FileManager
    ) throws -> ImportedLoRAFile {
        try LocalGGUFMetadata.validateLoRAAdapter(at: sourceURL, compatibleWith: architecture)
        let suggestedBaseName = suggestedFileName.map { URL(fileURLWithPath: $0).lastPathComponent }
        let sourceFileName = suggestedBaseName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? sourceURL.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? "adapter.gguf"
        let destinationFileName = uniqueFileName(
            for: sourceFileName,
            in: destinationDirectory,
            fileManager: fileManager
        )
        let destinationURL = destinationDirectory.appendingPathComponent(destinationFileName)
        do {
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
            let attributes = try fileManager.attributesOfItem(atPath: destinationURL.path)
            return ImportedLoRAFile(
                fileName: destinationFileName,
                relativePath: destinationFileName,
                fileSize: attributes[.size] as? Int64 ?? 0
            )
        } catch {
            try? fileManager.removeItem(at: destinationURL)
            throw error
        }
    }

    private func removeProjectorFileIfUnreferenced(from oldRecord: LocalModelRecord, replacingWith newRecord: LocalModelRecord) {
        guard let oldRelativePath = oldRecord.mmprojRelativePath,
              !oldRelativePath.isEmpty,
              oldRelativePath != newRecord.mmprojRelativePath else {
            return
        }
        let isStillReferenced = records.contains { record in
            record.id != oldRecord.id && record.mmprojRelativePath == oldRelativePath
        }
        if !isStillReferenced {
            deleteProjectorFile(relativePath: oldRelativePath)
        }
    }

    private func removeLoRAFileIfUnreferenced(from oldRecord: LocalModelRecord, replacingWith newRecord: LocalModelRecord) {
        guard let oldRelativePath = oldRecord.loraRelativePath,
              !oldRelativePath.isEmpty,
              oldRelativePath != newRecord.loraRelativePath else {
            return
        }
        let isStillReferenced = records.contains { record in
            record.id != oldRecord.id && record.loraRelativePath == oldRelativePath
        }
        if !isStillReferenced {
            deleteLoRAFile(relativePath: oldRelativePath)
        }
    }

    private func loadModels() -> [LocalModelRecord] {
        let metadataURL = metadataURL()
        guard let data = try? Data(contentsOf: metadataURL) else { return [] }
        do {
            let snapshot = try JSONDecoder.localModelDecoder.decode(LocalModelStoreSnapshot.self, from: data)
            var models = snapshot.schemaVersion < 2
                ? snapshot.models.map { $0.removingLegacyForcedDefaultOverrides() }
                : snapshot.models
            for index in models.indices where models[index].ggufArchitecture == nil {
                let url = directoryURL.appendingPathComponent(models[index].relativePath)
                models[index].ggufArchitecture = LocalGGUFMetadata.architecture(at: url)
            }
            let qwenDecoderID = models.first {
                $0.ggufArchitecture == "qwen3"
                    && fileManager.fileExists(
                        atPath: directoryURL.appendingPathComponent($0.relativePath).path
                    )
            }?.id
            let vadModelID = models.first {
                $0.speechArchitecture == .fsmnVAD
                    && fileManager.fileExists(
                        atPath: directoryURL.appendingPathComponent($0.relativePath).path
                    )
            }?.id
            for index in models.indices {
                if models[index].speechArchitecture == .funASRNanoEncoder,
                   models[index].speechDecoderModelID == nil {
                    models[index].speechDecoderModelID = qwenDecoderID
                }
                if models[index].isSpeechTranscriptionModel,
                   models[index].speechVADModelID == nil {
                    models[index].speechVADModelID = vadModelID
                }
            }
            return models.sorted { lhs, rhs in
                if lhs.createdAt == rhs.createdAt {
                    return lhs.id.uuidString < rhs.id.uuidString
                }
                return lhs.createdAt < rhs.createdAt
            }
        } catch {
            logger.error("读取本地模型元数据失败: \(error.localizedDescription)")
            return []
        }
    }

    private func persistModels(_ models: [LocalModelRecord]) throws {
        let snapshot = LocalModelStoreSnapshot(models: models)
        let data = try JSONEncoder.localModelEncoder.encode(snapshot)
        try data.write(to: metadataURL(), options: [.atomic, .completeFileProtection])
    }

    private func publishModels(notifyProvider: Bool = true) {
        snapshotLock.lock()
        snapshot = records
        snapshotLock.unlock()
        // 磁盘任务不进入 UI 发布链；回调读取最新快照，不会把排队的旧版本重新写回。
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.objectWillChange.send()
        }
        // 提供商监听器包含数据库读写，必须在调用方的存储任务内完成，不能搬到 UI 队列。
        if notifyProvider { notifyProviderChanged() }
    }

    private func notifyProviderChanged() {
        NotificationCenter.default.post(name: .localModelStoreDidChange, object: nil)
    }

    private func metadataURL() -> URL {
        directoryURL.appendingPathComponent(Self.metadataFileName)
    }

    private func ensureDirectoryExists(_ directory: URL) {
        if !fileManager.fileExists(atPath: directory.path) {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    private func uniqueFileName(for originalName: String) -> String {
        Self.uniqueFileName(for: originalName, in: directoryURL, fileManager: fileManager)
    }

    private static func uniqueFileName(for originalName: String, in directory: URL, fileManager: FileManager) -> String {
        let normalizedOriginal = originalName.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "model.gguf"
        let nsName = normalizedOriginal as NSString
        let base = nsName.deletingPathExtension.nilIfEmpty ?? "model"
        let ext = nsName.pathExtension.nilIfEmpty ?? "gguf"
        var candidate = "\(base).\(ext)"
        var suffix = 2
        while fileManager.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
            candidate = "\(base)-\(suffix).\(ext)"
            suffix += 1
        }
        return candidate
    }
}

public extension Notification.Name {
    static let localModelStoreDidChange = Notification.Name("com.ETOS.localModelStore.didChange")
}

private extension JSONDecoder {
    static var localModelDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private extension JSONEncoder {
    static var localModelEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

private extension Dictionary where Key == String, Value == JSONValue {
    func localIntValue(for key: String) -> Int? {
        guard let value = self[key] else { return nil }
        switch value {
        case .int(let rawValue):
            return rawValue
        case .double(let rawValue):
            return Int(rawValue)
        case .string(let rawValue):
            return Int(rawValue.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    func localUInt32Value(for key: String) -> UInt32? {
        guard let value = self[key] else { return nil }
        switch value {
        case .int(let rawValue):
            if rawValue == -1 {
                return LocalModelRecord.defaultSeed
            }
            return UInt32(exactly: rawValue)
        case .double(let rawValue):
            if rawValue == -1 {
                return LocalModelRecord.defaultSeed
            }
            return UInt32(exactly: rawValue)
        case .string(let rawValue):
            let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "-1" {
                return LocalModelRecord.defaultSeed
            }
            return UInt32(trimmed)
        default:
            return nil
        }
    }

    func localDoubleValue(for key: String) -> Double? {
        guard let value = self[key] else { return nil }
        switch value {
        case .double(let rawValue):
            return rawValue
        case .int(let rawValue):
            return Double(rawValue)
        case .string(let rawValue):
            return Double(rawValue.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    func localBoolValue(for key: String) -> Bool? {
        guard let value = self[key] else { return nil }
        switch value {
        case .bool(let rawValue):
            return rawValue
        case .int(let rawValue):
            return rawValue != 0
        case .double(let rawValue):
            return rawValue != 0
        case .string(let rawValue):
            switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "yes", "1", "on":
                return true
            case "false", "no", "0", "off":
                return false
            default:
                return nil
            }
        default:
            return nil
        }
    }

    func localFlashAttentionValue(for key: String) -> LocalLLMFlashAttentionMode? {
        guard let value = self[key] else { return nil }
        switch value {
        case .int(let rawValue):
            return LocalLLMFlashAttentionMode(rawValue: Int32(rawValue))
        case .double(let rawValue):
            return LocalLLMFlashAttentionMode(rawValue: Int32(rawValue))
        case .string(let rawValue):
            return LocalLLMFlashAttentionMode.parse(rawValue)
        case .bool(let rawValue):
            return rawValue ? .enabled : .disabled
        default:
            return nil
        }
    }

    func localStringValue(for key: String) -> String? {
        guard let value = self[key] else { return nil }
        switch value {
        case .string(let rawValue):
            return rawValue
        case .int(let rawValue):
            return String(rawValue)
        case .double(let rawValue):
            return String(rawValue)
        case .bool(let rawValue):
            return rawValue ? "true" : "false"
        default:
            return nil
        }
    }
}
