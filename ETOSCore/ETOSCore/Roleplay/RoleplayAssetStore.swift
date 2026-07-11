// ============================================================================
// RoleplayAssetStore.swift
// ============================================================================
// ETOS LLM Studio
//
// 管理 Character Card V3/CHARX 资源文件及其 HTML URI 映射。
// ============================================================================

import Foundation

public enum RoleplayAssetStore {
    private static var directory: URL {
        Persistence.getImageDirectory()
    }

    public static func install(
        _ imported: [RoleplayImportedCardAsset],
        characterID: UUID
    ) throws -> [RoleplayCardAsset] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var installed: [RoleplayCardAsset] = []
        do {
            for item in imported {
                var asset = item.asset
                if let data = item.data {
                    let ext = safeExtension(asset.fileExtension)
                    let fileName = "roleplay-asset-\(characterID.uuidString)-\(asset.id.uuidString).\(ext)"
                    try data.write(to: directory.appendingPathComponent(fileName), options: .atomic)
                    asset.localFileName = fileName
                }
                installed.append(asset)
            }
            return installed
        } catch {
            deleteFiles(for: installed)
            throw error
        }
    }

    public static func resolvedURL(for asset: RoleplayCardAsset) -> URL? {
        guard let fileName = asset.localFileName else {
            return URL(string: asset.uri)
        }
        return directory.appendingPathComponent(fileName)
    }

    public static func replacingAssetURIs(in source: String, assets: [RoleplayCardAsset]) -> String {
        assets.reduce(source) { output, asset in
            guard let url = resolvedURL(for: asset), asset.localFileName != nil else { return output }
            let packagedPath: String?
            if asset.uri.hasPrefix("embeded://") {
                packagedPath = String(asset.uri.dropFirst("embeded://".count))
            } else if asset.uri.hasPrefix("__asset:") {
                packagedPath = String(asset.uri.dropFirst("__asset:".count))
            } else {
                packagedPath = nil
            }
            return [asset.uri, packagedPath.map { "embeded://\($0)" }, packagedPath.map { "__asset:\($0)" }]
                .compactMap { $0 }
                .reduce(output) { value, uri in
                    value.replacingOccurrences(of: uri, with: url.absoluteString)
                }
        }
    }

    public static func deleteFiles(for assets: [RoleplayCardAsset]) {
        for fileName in assets.compactMap(\.localFileName) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(fileName))
        }
    }

    private static func safeExtension(_ raw: String) -> String {
        let filtered = raw.lowercased().filter { $0.isLetter || $0.isNumber }
        return filtered.isEmpty ? "bin" : String(filtered.prefix(12))
    }
}
