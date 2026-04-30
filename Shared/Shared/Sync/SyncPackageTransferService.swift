// ============================================================================
// SyncPackageTransferService.swift
// ============================================================================
// 同步数据包导出与导入编解码服务
// - 导出：使用 ETOS 包装信封写出 JSON，便于识别版本与导出时间
// - 导入：优先解析 ETOS 包装信封，失败后回退解析旧版纯 SyncPackage JSON
// ============================================================================

import Foundation

/// ETOS 同步导出信封。
public struct SyncPackageExportEnvelope: Codable {
    public var schemaVersion: Int
    public var exportedAt: Date
    public var envelope: SyncEnvelopeV2

    public init(
        schemaVersion: Int,
        exportedAt: Date,
        envelope: SyncEnvelopeV2
    ) {
        self.schemaVersion = schemaVersion
        self.exportedAt = exportedAt
        self.envelope = envelope
    }
}

/// 同步导出结果。
public struct SyncPackageExportOutput: Sendable {
    public let data: Data
    public let suggestedFileName: String

    public init(data: Data, suggestedFileName: String) {
        self.data = data
        self.suggestedFileName = suggestedFileName
    }
}

/// 同步导出文件结果。
public struct SyncPackageExportFileOutput: Sendable {
    public let fileURL: URL
    public let suggestedFileName: String

    public init(fileURL: URL, suggestedFileName: String) {
        self.fileURL = fileURL
        self.suggestedFileName = suggestedFileName
    }
}

public enum SyncPackageTransferError: LocalizedError {
    case invalidEnvelope
    case unsupportedSchemaVersion(Int)
    case unableToCreateOutputFile
    case fileWriteFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidEnvelope:
            return "导出包格式无效。"
        case .unsupportedSchemaVersion(let version):
            return "导出包版本过新（schemaVersion=\(version)），当前版本暂不支持。"
        case .unableToCreateOutputFile:
            return "无法创建导出文件。"
        case .fileWriteFailed(let reason):
            return "写入导出文件失败：\(reason)"
        }
    }
}

public enum SyncPackageTransferService {
    public static let currentSchemaVersion: Int = 2
    private static let temporaryExportFileMarker = "-ETOS-数据导出-"

    /// 导出同步包为 ETOS JSON 信封（schema v2）。
    /// - 注意：导出包始终使用 manifest + delta 结构，不再写出旧版纯 SyncPackage。
    public static func exportPackage(
        _ package: SyncPackage,
        exportedAt: Date = Date()
    ) throws -> SyncPackageExportOutput {
        let manifest = makeManifest(from: package, generatedAt: exportedAt)
        let delta = SyncDeltaPackage(
            generatedAt: exportedAt,
            options: package.options,
            package: package
        )
        let v2 = SyncEnvelopeV2(
            schemaVersion: currentSchemaVersion,
            exportedAt: exportedAt,
            manifest: manifest,
            delta: delta
        )
        let envelope = SyncPackageExportEnvelope(
            schemaVersion: currentSchemaVersion,
            exportedAt: exportedAt,
            envelope: v2
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(envelope)

        return SyncPackageExportOutput(
            data: data,
            suggestedFileName: suggestedFileName(exportedAt: exportedAt)
        )
    }

    /// 导出同步包到临时目录文件，避免生成完整 JSON 数据块后再写盘。
    public static func exportPackageToTemporaryFile(
        _ package: SyncPackage,
        exportedAt: Date = Date(),
        fileManager: FileManager = .default
    ) throws -> SyncPackageExportFileOutput {
        try exportPackageToFile(
            package,
            destinationDirectory: fileManager.temporaryDirectory,
            exportedAt: exportedAt,
            fileManager: fileManager
        )
    }

    /// 导出同步包到指定目录文件，返回可直接分享或上传的文件 URL。
    public static func exportPackageToFile(
        _ package: SyncPackage,
        destinationDirectory: URL,
        exportedAt: Date = Date(),
        fileManager: FileManager = .default
    ) throws -> SyncPackageExportFileOutput {
        cleanupTemporaryExportFiles(fileManager: fileManager)

        let fileName = suggestedFileName(exportedAt: exportedAt)
        let fileURL = destinationDirectory
            .appendingPathComponent("\(UUID().uuidString)-\(fileName)", isDirectory: false)
        try exportPackage(package, to: fileURL, exportedAt: exportedAt, fileManager: fileManager)
        return SyncPackageExportFileOutput(fileURL: fileURL, suggestedFileName: fileName)
    }

    /// 将同步包直接写入指定文件 URL，写入完成后再原子替换目标文件。
    public static func exportPackage(
        _ package: SyncPackage,
        to fileURL: URL,
        exportedAt: Date = Date(),
        fileManager: FileManager = .default
    ) throws {
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let temporaryURL = fileURL.appendingPathExtension("tmp")
        try? fileManager.removeItem(at: temporaryURL)

        do {
            let writer = try SyncPackageJSONFileWriter(fileURL: temporaryURL)
            try writeExportEnvelope(package, exportedAt: exportedAt, to: writer)
            writer.close()

            if fileManager.fileExists(atPath: fileURL.path) {
                try fileManager.removeItem(at: fileURL)
            }
            try fileManager.moveItem(at: temporaryURL, to: fileURL)
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }

    /// 清理陈旧的临时导出文件，用于兜底处理分享未完成或 App 异常退出后的残留。
    public static func cleanupTemporaryExportFiles(
        olderThan age: TimeInterval = 24 * 60 * 60,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) {
        guard let fileURLs = try? fileManager.contentsOfDirectory(
            at: fileManager.temporaryDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else {
            return
        }

        for fileURL in fileURLs where isTemporaryExportFile(fileURL) {
            let modifiedAt = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? .distantPast
            guard now.timeIntervalSince(modifiedAt) >= age else { continue }
            try? fileManager.removeItem(at: fileURL)
        }
    }

    /// 解析同步包：
    /// 1. 解析 ETOS v2 导出信封
    /// 2. 不再兼容旧版纯 SyncPackage JSON
    public static func decodePackage(from data: Data) throws -> SyncPackage {
        let decoder = JSONDecoder()
        guard let envelope = try? decoder.decode(SyncPackageExportEnvelope.self, from: data) else {
            throw SyncPackageTransferError.invalidEnvelope
        }
        guard envelope.schemaVersion > 0 else {
            throw SyncPackageTransferError.invalidEnvelope
        }
        guard envelope.schemaVersion <= currentSchemaVersion else {
            throw SyncPackageTransferError.unsupportedSchemaVersion(envelope.schemaVersion)
        }
        guard envelope.envelope.schemaVersion <= currentSchemaVersion else {
            throw SyncPackageTransferError.unsupportedSchemaVersion(envelope.envelope.schemaVersion)
        }
        return envelope.envelope.delta.package
    }

    /// 解析完整 V2 信封。
    public static func decodeEnvelope(from data: Data) throws -> SyncEnvelopeV2 {
        let decoder = JSONDecoder()
        guard let exportEnvelope = try? decoder.decode(SyncPackageExportEnvelope.self, from: data) else {
            throw SyncPackageTransferError.invalidEnvelope
        }
        guard exportEnvelope.schemaVersion > 0 else {
            throw SyncPackageTransferError.invalidEnvelope
        }
        guard exportEnvelope.schemaVersion <= currentSchemaVersion else {
            throw SyncPackageTransferError.unsupportedSchemaVersion(exportEnvelope.schemaVersion)
        }
        guard exportEnvelope.envelope.schemaVersion <= currentSchemaVersion else {
            throw SyncPackageTransferError.unsupportedSchemaVersion(exportEnvelope.envelope.schemaVersion)
        }
        return exportEnvelope.envelope
    }

    /// 默认导出文件名。
    public static func suggestedFileName(exportedAt: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: exportedAt)
        return "ETOS-数据导出-\(stamp).json"
    }

    private static func makeManifest(from package: SyncPackage, generatedAt: Date) -> SyncManifest {
        var descriptors: [SyncRecordDescriptor] = []

        if package.options.contains(.providers) {
            descriptors.append(contentsOf: package.providers.map {
                SyncRecordDescriptor(
                    type: .provider,
                    recordID: $0.id.uuidString,
                    checksum: checksum(for: $0),
                    updatedAt: generatedAt
                )
            })
        }

        if package.options.contains(.sessions) {
            descriptors.append(contentsOf: package.sessions.map {
                SyncRecordDescriptor(
                    type: .session,
                    recordID: $0.session.id.uuidString,
                    checksum: checksum(for: $0),
                    updatedAt: latestTimestamp(for: $0, fallback: generatedAt)
                )
            })
        }

        if package.options.contains(.backgrounds) {
            descriptors.append(contentsOf: package.backgrounds.map {
                SyncRecordDescriptor(
                    type: .background,
                    recordID: $0.filename,
                    checksum: $0.checksum,
                    updatedAt: generatedAt
                )
            })
        }

        if package.options.contains(.memories) {
            descriptors.append(contentsOf: package.memories.map {
                SyncRecordDescriptor(
                    type: .memory,
                    recordID: $0.id.uuidString,
                    checksum: checksum(for: $0),
                    updatedAt: generatedAt
                )
            })
        }

        if package.options.contains(.mcpServers) {
            descriptors.append(contentsOf: package.mcpServers.map {
                SyncRecordDescriptor(
                    type: .mcpServer,
                    recordID: $0.id.uuidString,
                    checksum: checksum(for: $0),
                    updatedAt: generatedAt
                )
            })
        }

        if package.options.contains(.audioFiles) {
            descriptors.append(contentsOf: package.audioFiles.map {
                SyncRecordDescriptor(
                    type: .audioFile,
                    recordID: $0.filename,
                    checksum: $0.checksum,
                    updatedAt: generatedAt
                )
            })
        }

        if package.options.contains(.imageFiles) {
            descriptors.append(contentsOf: package.imageFiles.map {
                SyncRecordDescriptor(
                    type: .imageFile,
                    recordID: $0.filename,
                    checksum: $0.checksum,
                    updatedAt: generatedAt
                )
            })
        }

        if package.options.contains(.skills) {
            descriptors.append(contentsOf: package.skills.map {
                SyncRecordDescriptor(
                    type: .skill,
                    recordID: $0.name,
                    checksum: $0.checksum,
                    updatedAt: generatedAt
                )
            })
        }

        if package.options.contains(.shortcutTools) {
            descriptors.append(contentsOf: package.shortcutTools.map {
                SyncRecordDescriptor(
                    type: .shortcutTool,
                    recordID: $0.id.uuidString,
                    checksum: checksum(for: $0),
                    updatedAt: generatedAt
                )
            })
        }

        if package.options.contains(.worldbooks) {
            descriptors.append(contentsOf: package.worldbooks.map {
                SyncRecordDescriptor(
                    type: .worldbook,
                    recordID: $0.id.uuidString,
                    checksum: checksum(for: $0),
                    updatedAt: generatedAt
                )
            })
        }

        if package.options.contains(.feedbackTickets) {
            descriptors.append(contentsOf: package.feedbackTickets.map {
                SyncRecordDescriptor(
                    type: .feedbackTicket,
                    recordID: $0.id,
                    checksum: checksum(for: $0),
                    updatedAt: generatedAt
                )
            })
        }

        if package.options.contains(.dailyPulse) {
            descriptors.append(contentsOf: package.dailyPulseRuns.map {
                SyncRecordDescriptor(
                    type: .dailyPulseRun,
                    recordID: $0.dayKey,
                    checksum: checksum(for: $0),
                    updatedAt: $0.generatedAt
                )
            })
        }

        if package.options.contains(.usageStats) {
            descriptors.append(contentsOf: package.usageStatsDayBundles.map {
                SyncRecordDescriptor(
                    type: .usageStatsDay,
                    recordID: $0.dayKey,
                    checksum: $0.checksum,
                    updatedAt: $0.events.map(\.finishedAt).max()
                        ?? $0.events.map(\.requestedAt).max()
                        ?? generatedAt
                )
            })
        }

        if package.options.contains(.fontFiles) {
            descriptors.append(contentsOf: package.fontFiles.map {
                SyncRecordDescriptor(
                    type: .fontFile,
                    recordID: $0.assetID.uuidString,
                    checksum: $0.checksum,
                    updatedAt: generatedAt
                )
            })
            if let routeData = package.fontRouteConfigurationData {
                descriptors.append(
                    SyncRecordDescriptor(
                        type: .fontRouteConfiguration,
                        recordID: "global.font.route",
                        checksum: routeData.sha256Hex,
                        updatedAt: generatedAt
                    )
                )
            }
        }

        if package.options.contains(.appStorage), let snapshot = package.appStorageSnapshot {
            descriptors.append(
                SyncRecordDescriptor(
                    type: .appStorage,
                    recordID: "global.app.storage",
                    checksum: snapshot.sha256Hex,
                    updatedAt: generatedAt
                )
            )
        }

        return SyncManifest(
            schemaVersion: currentSchemaVersion,
            generatedAt: generatedAt,
            options: package.options,
            records: descriptors
        )
    }

    private static func checksum<T: Encodable>(for value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(value)) ?? Data()
        return data.sha256Hex
    }

    private static func latestTimestamp(for session: SyncedSession, fallback: Date) -> Date {
        session.messages
            .compactMap { $0.requestedAt }
            .max() ?? fallback
    }

    private static func writeExportEnvelope(
        _ package: SyncPackage,
        exportedAt: Date,
        to writer: SyncPackageJSONFileWriter
    ) throws {
        let encoder = makeFileEncoder()
        let manifest = makeManifest(from: package, generatedAt: exportedAt)

        try writer.write("{")
        var rootFirstField = true
        try writeObjectField("envelope", to: writer, encoder: encoder, firstField: &rootFirstField) {
            try writer.write("{")
            var envelopeFirstField = true
            try writeObjectField("delta", to: writer, encoder: encoder, firstField: &envelopeFirstField) {
                try writeDeltaPackage(package, exportedAt: exportedAt, to: writer, encoder: encoder)
            }
            try writeEncodedField("exportedAt", exportedAt, to: writer, encoder: encoder, firstField: &envelopeFirstField)
            try writeEncodedField("manifest", manifest, to: writer, encoder: encoder, firstField: &envelopeFirstField)
            try writeEncodedField("schemaVersion", currentSchemaVersion, to: writer, encoder: encoder, firstField: &envelopeFirstField)
            try writer.write("}")
        }
        try writeEncodedField("exportedAt", exportedAt, to: writer, encoder: encoder, firstField: &rootFirstField)
        try writeEncodedField("schemaVersion", currentSchemaVersion, to: writer, encoder: encoder, firstField: &rootFirstField)
        try writer.write("}")
    }

    private static func writeDeltaPackage(
        _ package: SyncPackage,
        exportedAt: Date,
        to writer: SyncPackageJSONFileWriter,
        encoder: JSONEncoder
    ) throws {
        try writer.write("{")
        var firstField = true
        try writeEncodedField("deletions", [SyncDeleteRecord](), to: writer, encoder: encoder, firstField: &firstField)
        try writeEncodedField("generatedAt", exportedAt, to: writer, encoder: encoder, firstField: &firstField)
        try writeEncodedField("optionsRawValue", package.options.rawValue, to: writer, encoder: encoder, firstField: &firstField)
        try writeObjectField("package", to: writer, encoder: encoder, firstField: &firstField) {
            try writePackage(package, to: writer, encoder: encoder)
        }
        try writeEncodedField("schemaVersion", currentSchemaVersion, to: writer, encoder: encoder, firstField: &firstField)
        try writer.write("}")
    }

    private static func writePackage(
        _ package: SyncPackage,
        to writer: SyncPackageJSONFileWriter,
        encoder: JSONEncoder
    ) throws {
        try writer.write("{")
        var firstField = true
        try writeEncodedField("options", package.options, to: writer, encoder: encoder, firstField: &firstField)
        try writeArrayField("providers", package.providers, to: writer, encoder: encoder, firstField: &firstField)
        try writeArrayField("sessions", package.sessions, to: writer, encoder: encoder, firstField: &firstField)
        try writeArrayField("backgrounds", package.backgrounds, to: writer, encoder: encoder, firstField: &firstField)
        try writeArrayField("memories", package.memories, to: writer, encoder: encoder, firstField: &firstField)
        try writeArrayField("mcpServers", package.mcpServers, to: writer, encoder: encoder, firstField: &firstField)
        try writeArrayField("audioFiles", package.audioFiles, to: writer, encoder: encoder, firstField: &firstField)
        try writeArrayField("imageFiles", package.imageFiles, to: writer, encoder: encoder, firstField: &firstField)
        try writeArrayField("skills", package.skills, to: writer, encoder: encoder, firstField: &firstField)
        try writeArrayField("shortcutTools", package.shortcutTools, to: writer, encoder: encoder, firstField: &firstField)
        try writeArrayField("worldbooks", package.worldbooks, to: writer, encoder: encoder, firstField: &firstField)
        try writeArrayField("feedbackTickets", package.feedbackTickets, to: writer, encoder: encoder, firstField: &firstField)
        try writeArrayField("dailyPulseRuns", package.dailyPulseRuns, to: writer, encoder: encoder, firstField: &firstField)
        try writeArrayField("dailyPulseFeedbackHistory", package.dailyPulseFeedbackHistory, to: writer, encoder: encoder, firstField: &firstField)
        if let dailyPulsePendingCuration = package.dailyPulsePendingCuration {
            try writeEncodedField("dailyPulsePendingCuration", dailyPulsePendingCuration, to: writer, encoder: encoder, firstField: &firstField)
        }
        try writeArrayField("dailyPulseExternalSignals", package.dailyPulseExternalSignals, to: writer, encoder: encoder, firstField: &firstField)
        try writeArrayField("dailyPulseTasks", package.dailyPulseTasks, to: writer, encoder: encoder, firstField: &firstField)
        try writeArrayField("usageStatsDayBundles", package.usageStatsDayBundles, to: writer, encoder: encoder, firstField: &firstField)
        try writeArrayField("fontFiles", package.fontFiles, to: writer, encoder: encoder, firstField: &firstField)
        if let fontRouteConfigurationData = package.fontRouteConfigurationData {
            try writeEncodedField("fontRouteConfigurationData", fontRouteConfigurationData, to: writer, encoder: encoder, firstField: &firstField)
        }
        if let appStorageSnapshot = package.appStorageSnapshot {
            try writeEncodedField("appStorageSnapshot", appStorageSnapshot, to: writer, encoder: encoder, firstField: &firstField)
        }
        if let globalSystemPrompt = package.globalSystemPrompt {
            try writeEncodedField("globalSystemPrompt", globalSystemPrompt, to: writer, encoder: encoder, firstField: &firstField)
        }
        try writer.write("}")
    }

    private static func writeArrayField<T: Encodable>(
        _ name: String,
        _ values: [T],
        to writer: SyncPackageJSONFileWriter,
        encoder: JSONEncoder,
        firstField: inout Bool
    ) throws {
        try writeObjectField(name, to: writer, encoder: encoder, firstField: &firstField) {
            try writer.write("[")
            for (index, value) in values.enumerated() {
                if index > 0 {
                    try writer.write(",")
                }
                try writer.writeEncoded(value, encoder: encoder)
            }
            try writer.write("]")
        }
    }

    private static func writeEncodedField<T: Encodable>(
        _ name: String,
        _ value: T,
        to writer: SyncPackageJSONFileWriter,
        encoder: JSONEncoder,
        firstField: inout Bool
    ) throws {
        try writeObjectField(name, to: writer, encoder: encoder, firstField: &firstField) {
            try writer.writeEncoded(value, encoder: encoder)
        }
    }

    private static func writeObjectField(
        _ name: String,
        to writer: SyncPackageJSONFileWriter,
        encoder: JSONEncoder,
        firstField: inout Bool,
        valueWriter: () throws -> Void
    ) throws {
        if firstField {
            firstField = false
        } else {
            try writer.write(",")
        }
        try writer.writeEncoded(name, encoder: encoder)
        try writer.write(":")
        try valueWriter()
    }

    private static func makeFileEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func isTemporaryExportFile(_ fileURL: URL) -> Bool {
        let fileName = fileURL.lastPathComponent
        guard fileName.contains(temporaryExportFileMarker) else { return false }
        return fileName.hasSuffix(".json") || fileName.hasSuffix(".json.tmp")
    }
}

private final class SyncPackageJSONFileWriter {
    private let stream: OutputStream
    private var isClosed = false

    init(fileURL: URL) throws {
        guard let stream = OutputStream(url: fileURL, append: false) else {
            throw SyncPackageTransferError.unableToCreateOutputFile
        }
        self.stream = stream
        stream.open()
        guard stream.streamStatus == .open || stream.streamStatus == .writing else {
            throw SyncPackageTransferError.fileWriteFailed(
                stream.streamError?.localizedDescription ?? "输出流打开失败"
            )
        }
    }

    deinit {
        close()
    }

    func write(_ text: String) throws {
        guard let data = text.data(using: .utf8) else {
            throw SyncPackageTransferError.fileWriteFailed("无法编码文本片段")
        }
        try write(data)
    }

    func writeEncoded<T: Encodable>(_ value: T, encoder: JSONEncoder) throws {
        let data = try encoder.encode(value)
        try write(data)
    }

    func close() {
        guard !isClosed else { return }
        stream.close()
        isClosed = true
    }

    private func write(_ data: Data) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            var written = 0
            while written < data.count {
                let count = stream.write(baseAddress.advanced(by: written), maxLength: data.count - written)
                if count < 0 {
                    throw SyncPackageTransferError.fileWriteFailed(
                        stream.streamError?.localizedDescription ?? "输出流写入失败"
                    )
                }
                if count == 0 {
                    throw SyncPackageTransferError.fileWriteFailed("输出流未写入任何数据")
                }
                written += count
            }
        }
    }
}
