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

public enum SyncPackageTransferError: LocalizedError {
    case invalidEnvelope
    case unsupportedSchemaVersion(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidEnvelope:
            return "导出包格式无效。"
        case .unsupportedSchemaVersion(let version):
            return "导出包版本过新（schemaVersion=\(version)），当前版本暂不支持。"
        }
    }
}

public enum SyncPackageTransferService {
    public static let currentSchemaVersion: Int = 2

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
}
