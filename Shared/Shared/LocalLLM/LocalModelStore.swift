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

    public func registerDownloadedModel(data: Data, suggestedFileName: String, displayName: String? = nil) throws -> LocalModelRecord {
        let destinationFileName = uniqueFileName(for: suggestedFileName)
        let destinationURL = directoryURL.appendingPathComponent(destinationFileName)
        try data.write(to: destinationURL, options: [.atomic])
        return try registerImportedFile(
            fileName: destinationFileName,
            displayName: displayName ?? URL(fileURLWithPath: suggestedFileName).deletingPathExtension().lastPathComponent
        )
    }

    public func update(_ record: LocalModelRecord) {
        var updated = record
        updated.displayName = updated.sanitizedDisplayName
        updated.contextSize = max(1, updated.contextSize)
        updated.maxOutputTokens = max(1, updated.maxOutputTokens)
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
        if let contextSize = model.overrideParameters.localIntValue(for: "context_size") {
            record.contextSize = max(1, contextSize)
        }
        if let maxOutputTokens = model.overrideParameters.localIntValue(for: "max_output_tokens") ?? model.overrideParameters.localIntValue(for: "max_tokens") {
            record.maxOutputTokens = max(1, maxOutputTokens)
        }
        if let gpuLayers = model.overrideParameters.localIntValue(for: "n_gpu_layers") {
            record.gpuLayers = gpuLayers
        }
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
            return snapshot.models.sorted { lhs, rhs in
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
}
