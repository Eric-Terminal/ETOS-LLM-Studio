import CoreText
import CryptoKit
import Foundation

public struct FontLibrarySnapshot: Equatable, Sendable {
    public let assets: [FontAssetRecord]
    public let routes: FontRouteConfiguration
    let manifest: Data?
    let routeData: Data?
}

/// 沿用 Fonts 目录的两个 JSON 文件；磁盘读写和字体注册不进入 UI 执行器。
public actor FontConfigurationLibrary {
    public static let shared = FontConfigurationLibrary()
    private let directory: URL?
    private let writeMetadata: @Sendable (Data, URL) throws -> Void
    private var root: URL { directory ?? Persistence.getFontDirectory() }
    private static let manifestName = "font-manifest-v1.json"
    private static let routesName = "font-routes-v1.json"
    private static let extensions: Set<String> = ["ttf", "otf", "ttc", "woff", "woff2"]
    init(directory: URL? = nil, writeMetadata: @escaping @Sendable (Data, URL) throws -> Void = { try $0.write(to: $1, options: [.atomic]) }) {
        self.directory = directory; self.writeMetadata = writeMetadata
    }

    public func snapshot() throws -> FontLibrarySnapshot {
        try Task.checkCancellation()
        let root = root
        let manifest = try read(root.appendingPathComponent(Self.manifestName))
        let routes = try read(root.appendingPathComponent(Self.routesName))
        let assets = try manifest.map { try JSONDecoder().decode([FontAssetRecord].self, from: $0) } ?? []
        let configuration = try routes.map { try JSONDecoder().decode(FontRouteConfiguration.self, from: $0) } ?? .init()
        guard Set(assets.map(\.id)).count == assets.count,
              Set(assets.map(\.fileName)).count == assets.count,
              Set(configuration.customTextRules.map(\.id)).count == configuration.customTextRules.count,
              assets.allSatisfy({ !$0.fileName.isEmpty && $0.fileName != "." && $0.fileName != ".." && $0.fileName == URL(fileURLWithPath: $0.fileName).lastPathComponent }) else {
            throw FontConfigurationError.invalidConfiguration
        }
        return FontLibrarySnapshot(assets: assets, routes: configuration, manifest: manifest, routeData: routes)
    }

    public func saveRoutes(_ routes: FontRouteConfiguration, original: FontLibrarySnapshot) throws -> FontLibrarySnapshot {
        try validate(original)
        let validIDs = Set(original.assets.map(\.id))
        let chains = FontSemanticRole.allCases.map { routes.chain(for: $0) } + routes.customTextRules.map(\.fontAssetIDs)
        guard chains.allSatisfy({ Set($0).count == $0.count && Set($0).isSubset(of: validIDs) }),
              Set(routes.customTextRules.map(\.id)).count == routes.customTextRules.count else { throw FontConfigurationError.invalidConfiguration }
        try commit(assets: original.assets, routes: routes, original: original)
        return try snapshot()
    }

    public func importFile(_ source: URL, original: FontLibrarySnapshot) throws -> FontLibrarySnapshot {
        try validate(original)
        guard source.isFileURL, Self.extensions.contains(source.pathExtension.lowercased()) else { throw FontLibraryError.unsupportedFontFileExtension }
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        guard try FileManager.default.attributesOfItem(atPath: source.path)[.type] as? FileAttributeType == .typeRegular else {
            throw FontLibraryError.invalidFontData
        }
        let data = try Data(contentsOf: source)
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromData(data as CFData) as? [CTFontDescriptor],
              let descriptor = descriptors.first,
              let name = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String, !name.isEmpty else {
            throw FontLibraryError.invalidFontData
        }
        let checksum = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        if original.assets.contains(where: { $0.checksum == checksum }) { return original }
        let record = FontAssetRecord(fileName: "font-\(UUID().uuidString).\(source.pathExtension.lowercased())",
                                     checksum: checksum, displayName: name, postScriptName: name)
        var routes = original.routes
        for role in FontSemanticRole.allCases { routes.setChain(routes.chain(for: role) + [record.id], for: role) }
        try Task.checkCancellation()
        try validate(original)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent(record.fileName)
        try data.write(to: destination, options: [.atomic])
        do {
            try commit(assets: [record] + original.assets, routes: routes, original: original)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        return try snapshot()
    }

    public func delete(_ id: UUID, original: FontLibrarySnapshot) throws -> FontLibrarySnapshot {
        try validate(original)
        guard let target = original.assets.first(where: { $0.id == id }) else { throw FontConfigurationError.changed }
        let url = root.appendingPathComponent(target.fileName), manager = FileManager.default
        // 删除确认绑定清单和文件校验和；旧确认不能删除已替换的文件。
        if manager.fileExists(atPath: url.path) {
            guard try manager.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeRegular,
                  SHA256.hash(data: try Data(contentsOf: url)).map({ String(format: "%02x", $0) }).joined() == target.checksum else {
                throw FontConfigurationError.changed
            }
        }
        var routes = original.routes
        for role in FontSemanticRole.allCases { routes.setChain(routes.chain(for: role).filter { $0 != id }, for: role) }
        for key in routes.languageBuckets.keys {
            guard var bucket = routes.languageBuckets[key] else { continue }
            bucket.body.removeAll { $0 == id }; bucket.emphasis.removeAll { $0 == id }
            bucket.strong.removeAll { $0 == id }; bucket.code.removeAll { $0 == id }
            routes.languageBuckets[key] = bucket
        }
        for index in routes.customTextRules.indices { routes.customTextRules[index].fontAssetIDs.removeAll { $0 == id } }
        let staging = try manager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: root, create: true)
        let backup = staging.appendingPathComponent(target.fileName)
        var moved = false, restored = true
        defer { if restored { try? manager.removeItem(at: staging) } }
        if manager.fileExists(atPath: url.path) { try manager.moveItem(at: url, to: backup); moved = true }
        do { try commit(assets: original.assets.filter { $0.id != id }, routes: routes, original: original) }
        catch {
            if moved {
                do { try manager.moveItem(at: backup, to: url) }
                catch { restored = false; throw FontConfigurationError.restoreFailed }
            }
            throw error
        }
        return try snapshot()
    }

    private func validate(_ original: FontLibrarySnapshot) throws {
        guard try snapshot() == original else { throw FontConfigurationError.changed }
    }

    /// 两个兼容文件各自原子替换，第二次写入失败时恢复原字节；不宣称跨文件崩溃原子性。
    private func commit(assets: [FontAssetRecord], routes: FontRouteConfiguration, original: FontLibrarySnapshot) throws {
        try validate(original)
        let root = root, encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let manifest = try encoder.encode(assets), routeData = try encoder.encode(routes)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let routeURL = root.appendingPathComponent(Self.routesName)
        try writeMetadata(routeData, routeURL)
        do { try writeMetadata(manifest, root.appendingPathComponent(Self.manifestName)) }
        catch {
            do {
                if let previous = original.routeData { try previous.write(to: routeURL, options: [.atomic]) }
                else { try FileManager.default.removeItem(at: routeURL) }
            } catch { throw FontConfigurationError.restoreFailed }
            throw FontLibraryError.saveFailed
        }
        if directory == nil {
            FontLibrary.preloadRuntimeCache(forceReload: true)
            NotificationCenter.default.post(name: .syncFontsUpdated, object: nil)
            NotificationCenter.default.post(name: .cloudSyncLocalDataDidChange, object: nil)
        }
    }

    private func read(_ url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeRegular else {
            throw FontConfigurationError.invalidConfiguration
        }
        return try Data(contentsOf: url)
    }
}

public enum FontConfigurationError: LocalizedError {
    case changed, invalidConfiguration, restoreFailed
    public var errorDescription: String? {
        switch self {
        case .changed: NSLocalizedString("配置已在其他页面修改，请重新打开后再编辑。", comment: "")
        case .invalidConfiguration: NSLocalizedString("字体配置无效，请检查字体文件与优先级。", comment: "")
        case .restoreFailed: NSLocalizedString("字体操作失败且无法完整恢复，请检查字体库后重试。", comment: "")
        }
    }
}
