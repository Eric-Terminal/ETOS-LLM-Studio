// ============================================================================
// ThirdPartyImportETOS.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件负责解析 ETOS 原生导出的同步数据包。
// ============================================================================

import Foundation

extension ThirdPartyImportService {
    static func parseETOSBackup(fileURL: URL) throws -> SyncPackage {
        let rootURL: URL
        if isDirectory(fileURL) {
            guard let foundURL = findETOSPackageFile(inDirectory: fileURL) else {
                throw ThirdPartyImportError.unsupportedBackupFormat(
                    reason: NSLocalizedString("未在目录中找到 ETOS 可识别的 .elsbackup 快照或 JSON 导出包。", comment: "ETOS import missing export package")
                )
            }
            rootURL = foundURL
        } else {
            rootURL = fileURL
        }

        if isETOSSnapshotFile(rootURL) {
            return try ETOSSnapshotPackageImporter.buildPackage(from: rootURL)
        }

        if isLikelyCompressedBackup(rootURL) {
            throw ThirdPartyImportError.unsupportedBackupFormat(
                reason: NSLocalizedString("ETOS 数据包支持 .elsbackup 快照和旧版 .json 导出，请不要选择 .zip / .bak。", comment: "ETOS import compressed backup unsupported")
            )
        }

        guard let data = try? Data(contentsOf: rootURL) else {
            throw ThirdPartyImportError.fileNotReadable
        }
        guard (try? JSONSerialization.jsonObject(with: data)) != nil else {
            throw ThirdPartyImportError.invalidJSON
        }

        guard let package = try? SyncPackageTransferService.decodePackage(from: data) else {
            throw ThirdPartyImportError.unsupportedBackupFormat(
                reason: NSLocalizedString("文件不是可识别的 ETOS 数据包或 .elsbackup 快照。", comment: "ETOS import unrecognized package")
            )
        }
        guard !package.options.isEmpty else {
            throw ThirdPartyImportError.noImportableContent
        }
        return package
    }

    static func findETOSPackageFile(inDirectory directoryURL: URL) -> URL? {
        guard isDirectory(directoryURL) else { return nil }
        let enumerator = FileManager.default.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        var firstSnapshot: URL?
        var firstJSON: URL?
        while let fileURL = enumerator?.nextObject() as? URL {
            if isDirectory(fileURL) { continue }
            if isETOSSnapshotFile(fileURL) {
                if fileURL.lastPathComponent.hasPrefix("ETOS-Snapshot-") {
                    return fileURL
                }
                firstSnapshot = firstSnapshot ?? fileURL
                continue
            }
            guard fileURL.pathExtension.lowercased() == "json" else { continue }
            if fileURL.lastPathComponent.hasPrefix("ETOS-数据导出-") {
                firstJSON = fileURL
                continue
            }
            firstJSON = firstJSON ?? fileURL
        }

        return firstSnapshot ?? firstJSON
    }

    static func isETOSSnapshotFile(_ fileURL: URL) -> Bool {
        fileURL.pathExtension.lowercased() == SnapshotBuilder.fileExtension
    }
}
