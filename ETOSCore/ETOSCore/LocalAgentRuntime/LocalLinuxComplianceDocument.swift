// ============================================================================
// LocalLinuxComplianceDocument.swift
// ============================================================================
// ETOS LLM Studio
//
// 随内置 RootFS 交付的许可、来源与可复核清单。
// ============================================================================

import Foundation

public enum LocalLinuxComplianceDocument: String, CaseIterable, Identifiable, Sendable {
    case sourceOffer = "LocalLinuxRootFS-Source-Offer.txt"
    case packages = "LocalLinuxRootFS-Packages.tsv"
    case sourceAssets = "LocalLinuxRootFS-Source-Assets.tsv"
    case notices = "LocalLinuxRootFS-Third-Party-Notices.txt"
    case projectLicenses = "iSH-PROJECT-LICENSES.txt"
    case sbom = "LocalLinuxRootFS-SBOM.spdx.json"
    case migrations = "ETOSLocalLinuxRootFSMigrations.json"
    case compliance = "LocalLinuxRootFS-Compliance.json"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .sourceOffer:
            return NSLocalizedString("对应源码说明", comment: "Local Linux source offer document")
        case .packages:
            return NSLocalizedString("RootFS 软件包清单", comment: "Local Linux package list document")
        case .sourceAssets:
            return NSLocalizedString("源码资产索引", comment: "Local Linux source assets document")
        case .notices:
            return NSLocalizedString("第三方许可声明", comment: "Local Linux third-party notices document")
        case .projectLicenses:
            return NSLocalizedString("iSH 项目许可", comment: "iSH project licenses document")
        case .sbom:
            return NSLocalizedString("SPDX 软件物料清单", comment: "Local Linux SPDX SBOM document")
        case .migrations:
            return NSLocalizedString("RootFS 更新清单", comment: "Local Linux RootFS migration manifest")
        case .compliance:
            return NSLocalizedString("资源完整性清单", comment: "Local Linux compliance manifest document")
        }
    }

    public func resourceURL(in bundle: Bundle = .main) -> URL? {
        let url = URL(fileURLWithPath: rawValue)
        let name = url.deletingPathExtension().lastPathComponent
        let fileExtension = url.pathExtension
        return bundle.url(forResource: name, withExtension: fileExtension, subdirectory: "LocalLinux")
            ?? bundle.url(forResource: name, withExtension: fileExtension)
    }
}
