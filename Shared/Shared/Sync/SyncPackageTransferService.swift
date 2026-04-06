// ============================================================================
// SyncPackageTransferService.swift
// ============================================================================
// 同步数据包导出与导入编解码服务
// - 导出：使用 ETOS 包装信封写出 JSON，便于识别版本与导出时间
// - 导入：优先解析 ETOS 包装信封，失败后回退解析旧版纯 SyncPackage JSON
// ============================================================================

import Foundation

/// ETOS 同步导出信封。
public struct SyncPackageExportEnvelope: Codable, Sendable {
    public var schemaVersion: Int
    public var exportedAt: Date
    public var package: SyncPackage

    public init(
        schemaVersion: Int,
        exportedAt: Date,
        package: SyncPackage
    ) {
        self.schemaVersion = schemaVersion
        self.exportedAt = exportedAt
        self.package = package
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
    public static let currentSchemaVersion: Int = 1

    /// 导出同步包为 ETOS JSON 信封。
    public static func exportPackage(
        _ package: SyncPackage,
        exportedAt: Date = Date()
    ) throws -> SyncPackageExportOutput {
        let envelope = SyncPackageExportEnvelope(
            schemaVersion: currentSchemaVersion,
            exportedAt: exportedAt,
            package: package
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
    /// 1. 优先解析 ETOS 导出信封
    /// 2. 回退解析旧版纯 SyncPackage JSON
    public static func decodePackage(from data: Data) throws -> SyncPackage {
        let decoder = JSONDecoder()

        if let envelope = try? decoder.decode(SyncPackageExportEnvelope.self, from: data) {
            guard envelope.schemaVersion > 0 else {
                throw SyncPackageTransferError.invalidEnvelope
            }
            guard envelope.schemaVersion <= currentSchemaVersion else {
                throw SyncPackageTransferError.unsupportedSchemaVersion(envelope.schemaVersion)
            }
            return envelope.package
        }

        return try decoder.decode(SyncPackage.self, from: data)
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
}
