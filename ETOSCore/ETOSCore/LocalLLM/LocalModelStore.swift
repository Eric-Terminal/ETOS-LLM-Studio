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

public final class LocalModelStore: ObservableObject {
    public static let shared = LocalModelStore()
    public static let directoryName = "LocalModels"

    private static let metadataFileName = "local-models.json"
    private let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "LocalModelStore")
    private let fileManager: FileManager
    private let directoryOverride: URL?

    @Published public private(set) var models: [LocalModelRecord]

    public init(fileManager: FileManager = .default, directoryURL: URL? = nil) {
        self.fileManager = fileManager
        self.directoryOverride = directoryURL
        self.models = []
        self.models = loadModels()
    }

    public var directoryURL: URL {
        if let directoryOverride {
            ensureDirectoryExists(directoryOverride)
            return directoryOverride
        }
        return Self.localModelsDirectoryURL(fileManager: fileManager)
    }

    public static func localModelsDirectoryURL(fileManager: FileManager = .default) -> URL {
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let directory = documents.appendingPathComponent(directoryName, isDirectory: true)
        if !fileManager.fileExists(atPath: directory.path) {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    public func reload() {
        models = loadModels()
    }

    public var isProviderEnabled: Bool {
        AppConfigStore.boolValue(for: .localModelsEnabled)
    }

    public func setProviderEnabled(_ isEnabled: Bool) {
        AppConfigStore.persistSynchronously(.bool(isEnabled), for: .localModelsEnabled)
        Task { @MainActor in
            if AppConfigStore.shared.localModelsEnabled != isEnabled {
                AppConfigStore.shared.localModelsEnabled = isEnabled
            }
        }
        NotificationCenter.default.post(name: .localModelStoreDidChange, object: nil)
    }

    public func fileURL(for record: LocalModelRecord) -> URL {
        directoryURL.appendingPathComponent(record.relativePath)
    }

    public func fileExists(for record: LocalModelRecord) -> Bool {
        fileManager.fileExists(atPath: fileURL(for: record).path)
    }

    public func importModel(from sourceURL: URL, displayName: String? = nil) throws -> LocalModelRecord {
        let didStartSecurityScope = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didStartSecurityScope {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let sourceFileName = sourceURL.lastPathComponent
        let destinationFileName = uniqueFileName(for: sourceFileName)
        let destinationURL = directoryURL.appendingPathComponent(destinationFileName)
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
        return try registerImportedFile(
            fileName: destinationFileName,
            displayName: displayName ?? sourceURL.deletingPathExtension().lastPathComponent
        )
    }

    public func registerDownloadedModel(fileAt sourceURL: URL, suggestedFileName: String, displayName: String? = nil) throws -> LocalModelRecord {
        let destinationFileName = uniqueFileName(for: suggestedFileName)
        let destinationURL = directoryURL.appendingPathComponent(destinationFileName)
        try fileManager.moveItem(at: sourceURL, to: destinationURL)
        return try registerImportedFile(
            fileName: destinationFileName,
            displayName: displayName ?? URL(fileURLWithPath: suggestedFileName).deletingPathExtension().lastPathComponent
        )
    }

    public func update(_ record: LocalModelRecord) {
        var updated = record
        updated.displayName = updated.sanitizedDisplayName
        updated.normalizeGenerationParameters()
        updated.updatedAt = Date()

        if let index = models.firstIndex(where: { $0.id == updated.id }) {
            models[index] = updated
        } else {
            models.append(updated)
        }
        persistModels()
        NotificationCenter.default.post(name: .localModelStoreDidChange, object: nil)
    }

    public func updateFromProviderModel(_ model: Model) {
        guard let index = models.firstIndex(where: { $0.id == LocalModelProviderBridge.localRecordID(from: model) }) else {
            return
        }

        var record = models[index]
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
        models.removeAll { $0.id == record.id }
        if deleteFile {
            try? fileManager.removeItem(at: fileURL(for: record))
        }
        persistModels()
        NotificationCenter.default.post(name: .localModelStoreDidChange, object: nil)
    }

    public func activatedModelsWithExistingFiles() -> [LocalModelRecord] {
        models.filter { $0.isActivated && fileExists(for: $0) }
    }

    private func registerImportedFile(fileName: String, displayName: String) throws -> LocalModelRecord {
        let destinationURL = directoryURL.appendingPathComponent(fileName)
        let attributes = try fileManager.attributesOfItem(atPath: destinationURL.path)
        let size = attributes[.size] as? Int64 ?? 0
        let now = Date()
        let record = LocalModelRecord(
            displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent,
            fileName: fileName,
            relativePath: fileName,
            fileSize: size,
            createdAt: now,
            updatedAt: now
        )
        models.append(record)
        persistModels()
        if !isProviderEnabled {
            setProviderEnabled(true)
        }
        NotificationCenter.default.post(name: .localModelStoreDidChange, object: nil)
        return record
    }

    private func loadModels() -> [LocalModelRecord] {
        let metadataURL = metadataURL()
        guard let data = try? Data(contentsOf: metadataURL) else { return [] }
        do {
            let snapshot = try JSONDecoder.localModelDecoder.decode(LocalModelStoreSnapshot.self, from: data)
            let models = snapshot.schemaVersion < 2
                ? snapshot.models.map { $0.removingLegacyForcedDefaultOverrides() }
                : snapshot.models
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

    private func persistModels() {
        do {
            let snapshot = LocalModelStoreSnapshot(models: models)
            let data = try JSONEncoder.localModelEncoder.encode(snapshot)
            try data.write(to: metadataURL(), options: [.atomic, .completeFileProtection])
        } catch {
            logger.error("写入本地模型元数据失败: \(error.localizedDescription)")
        }
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
        let normalizedOriginal = originalName.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "model.gguf"
        let nsName = normalizedOriginal as NSString
        let base = nsName.deletingPathExtension.nilIfEmpty ?? "model"
        let ext = nsName.pathExtension.nilIfEmpty ?? "gguf"
        var candidate = "\(base).\(ext)"
        var suffix = 2
        while fileManager.fileExists(atPath: directoryURL.appendingPathComponent(candidate).path) {
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
