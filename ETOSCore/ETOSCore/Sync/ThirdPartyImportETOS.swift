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
            guard let foundURL = findETOSJSONFile(inDirectory: fileURL) else {
                throw ThirdPartyImportError.unsupportedBackupFormat(
                    reason: NSLocalizedString("未在目录中找到 ETOS 可识别的 JSON 导出包。", comment: "ETOS import missing export package")
                )
            }
            rootURL = foundURL
        } else {
            rootURL = fileURL
        }

        if isLikelyCompressedBackup(rootURL) {
            throw ThirdPartyImportError.unsupportedBackupFormat(
                reason: NSLocalizedString("ETOS 数据包请直接选择 .json 文件，不支持压缩包。", comment: "ETOS import compressed backup unsupported")
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
                reason: NSLocalizedString("文件不是可识别的 ETOS 导出数据包。", comment: "ETOS import unrecognized package")
            )
        }
        guard !package.options.isEmpty else {
            throw ThirdPartyImportError.noImportableContent
        }
        return package
    }
}
