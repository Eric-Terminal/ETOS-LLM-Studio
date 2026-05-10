// ============================================================================
// FontLibrary.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责字体资产、路由配置、运行时缓存与字体解析回退逻辑。
// ============================================================================

import Foundation
#if canImport(CoreText)
import CoreText
#endif
import os.log

private let fontLibraryLogger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "FontLibrary")

public enum FontLibrary {
    private static let manifestFileName = "font-manifest-v1.json"
    private static let routeConfigFileName = "font-routes-v1.json"
    private static let supportedFontFileExtensions: Set<String> = ["ttf", "otf", "ttc", "woff", "woff2"]
    public static let minimumFontScale = 0.5
    public static let maximumFontScale = 2.0
    public static let defaultFontScale = 1.0
    public static let fontScaleStep = 0.05
    private static let cacheLock = NSLock()
    private static let sampledResolutionCacheLimit = 256

    private enum FontResolutionCacheEntry {
        case resolved(String)
        case unresolved
    }

    private struct RuntimeSnapshot {
        var isPrepared = false
        var assets: [FontAssetRecord] = []
        var routeConfiguration = FontRouteConfiguration()
        var fallbackPostScriptNamesByRole: [FontSemanticRole: [String]] = [:]
        var preferredPostScriptNameByRole: [FontSemanticRole: String] = [:]
        var sampledResolutionCache: [String: FontResolutionCacheEntry] = [:]
        var isCustomFontEnabled = true
        var fallbackScope: FontFallbackScope = .segment
        var customFontScale = FontLibrary.defaultFontScale
    }

    private static var runtimeSnapshot = RuntimeSnapshot()

    private static var manifestURL: URL {
        Persistence.getFontDirectory().appendingPathComponent(manifestFileName)
    }

    private static var routeConfigURL: URL {
        Persistence.getFontDirectory().appendingPathComponent(routeConfigFileName)
    }

    public static var isCustomFontEnabled: Bool {
        ensureRuntimeCachePrepared()
        ensureRuntimeSettingsSynchronized()
        return withRuntimeSnapshot { $0.isCustomFontEnabled }
    }

    public static var fallbackScope: FontFallbackScope {
        ensureRuntimeCachePrepared()
        ensureRuntimeSettingsSynchronized()
        return withRuntimeSnapshot { $0.fallbackScope }
    }

    public static var customFontScale: Double {
        ensureRuntimeCachePrepared()
        ensureRuntimeSettingsSynchronized()
        return withRuntimeSnapshot { $0.customFontScale }
    }

    public static func normalizedFontScale(_ value: Double) -> Double {
        guard value.isFinite else { return defaultFontScale }
        return min(max(value, minimumFontScale), maximumFontScale)
    }

    public static func effectiveFontScale(_ value: Double, isCustomFontEnabled: Bool) -> Double {
        isCustomFontEnabled ? normalizedFontScale(value) : defaultFontScale
    }

    public static func effectiveFontScale(isCustomFontEnabled: Bool) -> Double {
        effectiveFontScale(customFontScale, isCustomFontEnabled: isCustomFontEnabled)
    }

    public static func scaledPointSize(_ pointSize: Double, scale: Double, isCustomFontEnabled: Bool) -> Double {
        pointSize * effectiveFontScale(scale, isCustomFontEnabled: isCustomFontEnabled)
    }

    public static func scaledPointSize(_ pointSize: Double, isCustomFontEnabled: Bool) -> Double {
        pointSize * effectiveFontScale(isCustomFontEnabled: isCustomFontEnabled)
    }

    public static func scaledPointSize(_ pointSize: Double) -> Double {
        pointSize * customFontScale
    }

    public static func preloadRuntimeCacheAsync(forceReload: Bool = false) {
        Task.detached(priority: .utility) {
            preloadRuntimeCache(forceReload: forceReload)
            await MainActor.run {
                NotificationCenter.default.post(name: .syncFontsUpdated, object: nil)
            }
        }
    }

    public static func preloadRuntimeCache(forceReload: Bool = false) {
        if !forceReload, withRuntimeSnapshot({ $0.isPrepared }) {
            return
        }

        let assets = loadAssetsFromDisk()
        let routeConfiguration = loadRouteConfigurationFromDisk()
        let settings = loadFontSettingsFromAppConfig()

        if settings.isCustomFontEnabled {
            for asset in assets where asset.isEnabled {
                registerFontFileIfNeeded(fileName: asset.fileName)
            }
        }

        let roleMappings = buildRoleMappings(
            assets: assets,
            routeConfiguration: routeConfiguration,
            isCustomFontEnabled: settings.isCustomFontEnabled
        )

        updateRuntimeSnapshot { snapshot in
            snapshot.isPrepared = true
            snapshot.assets = assets
            snapshot.routeConfiguration = routeConfiguration
            snapshot.fallbackPostScriptNamesByRole = roleMappings.fallback
            snapshot.preferredPostScriptNameByRole = roleMappings.preferred
            snapshot.sampledResolutionCache.removeAll(keepingCapacity: true)
            snapshot.isCustomFontEnabled = settings.isCustomFontEnabled
            snapshot.fallbackScope = settings.fallbackScope
            snapshot.customFontScale = settings.customFontScale
        }
    }

    public static func loadAssets() -> [FontAssetRecord] {
        ensureRuntimeCachePrepared()
        return withRuntimeSnapshot { $0.assets }
    }

    @discardableResult
    public static func saveAssets(_ assets: [FontAssetRecord]) -> Bool {
        let sorted = assets.sorted { lhs, rhs in
            if lhs.importedAt != rhs.importedAt {
                return lhs.importedAt > rhs.importedAt
            }
            return lhs.fileName.localizedCaseInsensitiveCompare(rhs.fileName) == .orderedAscending
        }
        guard let data = try? JSONEncoder().encode(sorted) else { return false }
        do {
            try data.write(to: manifestURL, options: [.atomic])
            preloadRuntimeCache(forceReload: true)
            return true
        } catch {
            fontLibraryLogger.error("Failed to save font manifest: \(error.localizedDescription)")
            return false
        }
    }

    public static func loadRouteConfiguration() -> FontRouteConfiguration {
        ensureRuntimeCachePrepared()
        return withRuntimeSnapshot { $0.routeConfiguration }
    }

    @discardableResult
    public static func saveRouteConfiguration(_ configuration: FontRouteConfiguration) -> Bool {
        guard let data = try? JSONEncoder().encode(configuration) else { return false }
        do {
            try data.write(to: routeConfigURL, options: [.atomic])
            preloadRuntimeCache(forceReload: true)
            return true
        } catch {
            fontLibraryLogger.error("Failed to save font route configuration: \(error.localizedDescription)")
            return false
        }
    }

    public static func loadRouteConfigurationData() -> Data? {
        try? Data(contentsOf: routeConfigURL)
    }

    @discardableResult
    public static func saveRouteConfigurationData(_ data: Data?) -> Bool {
        let directory = Persistence.getFontDirectory()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        guard let data else {
            do {
                if FileManager.default.fileExists(atPath: routeConfigURL.path) {
                    try FileManager.default.removeItem(at: routeConfigURL)
                }
                preloadRuntimeCache(forceReload: true)
                return true
            } catch {
                fontLibraryLogger.error("Failed to remove route config file: \(error.localizedDescription)")
                return false
            }
        }
        do {
            try data.write(to: routeConfigURL, options: [.atomic])
            preloadRuntimeCache(forceReload: true)
            return true
        } catch {
            fontLibraryLogger.error("Failed to save route config data: \(error.localizedDescription)")
            return false
        }
    }

    public static func importFont(
        data: Data,
        fileName: String,
        preferredDisplayName: String? = nil
    ) throws -> FontAssetRecord {
        let normalizedExt = (fileName as NSString).pathExtension.lowercased()
        guard supportedFontFileExtensions.contains(normalizedExt) else {
            throw FontLibraryError.unsupportedFontFileExtension
        }

        guard let postScriptName = extractPostScriptName(from: data), !postScriptName.isEmpty else {
            throw FontLibraryError.invalidFontData
        }

        var assets = loadAssets()
        let checksum = data.sha256Hex
        if let existing = assets.first(where: { $0.checksum == checksum }) {
            registerFontFileIfNeeded(fileName: existing.fileName)
            return existing
        }

        let safeBaseName = sanitizeBaseName((fileName as NSString).deletingPathExtension)
        let targetFileName = uniqueFontFileName(
            baseName: safeBaseName.isEmpty ? "font" : safeBaseName,
            fileExtension: normalizedExt
        )

        guard Persistence.saveFont(data, fileName: targetFileName) != nil else {
            throw FontLibraryError.saveFailed
        }
        registerFontFileIfNeeded(fileName: targetFileName)

        let record = FontAssetRecord(
            fileName: targetFileName,
            checksum: checksum,
            displayName: preferredDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                ?? postScriptName,
            postScriptName: postScriptName
        )

        assets.append(record)
        _ = saveAssets(assets)
        var routes = loadRouteConfiguration()
        for role in FontSemanticRole.allCases {
            var chain = routes.chain(for: role)
            if !chain.contains(record.id) {
                chain.append(record.id)
                routes.setChain(chain, for: role)
            }
        }
        _ = saveRouteConfiguration(routes)
        return record
    }

    public static func deleteFontAsset(id: UUID) throws {
        var assets = loadAssets()
        guard let target = assets.first(where: { $0.id == id }) else { return }
        assets.removeAll { $0.id == id }
        if !saveAssets(assets) {
            throw FontLibraryError.deleteFailed
        }
        Persistence.deleteFont(fileName: target.fileName)
        var routes = loadRouteConfiguration()
        for role in FontSemanticRole.allCases {
            let chain = routes.chain(for: role).filter { $0 != id }
            routes.setChain(chain, for: role)
        }
        _ = saveRouteConfiguration(routes)
    }

    public static func updateChain(_ chain: [UUID], for role: FontSemanticRole) {
        var configuration = loadRouteConfiguration()
        let validIDs = Set(loadAssets().map(\.id))
        let normalizedChain = chain.filter { validIDs.contains($0) }
        configuration.setChain(normalizedChain, for: role)
        _ = saveRouteConfiguration(configuration)
    }

    @discardableResult
    public static func setAssetEnabled(id: UUID, isEnabled: Bool) -> Bool {
        var assets = loadAssets()
        guard let index = assets.firstIndex(where: { $0.id == id }) else { return false }
        guard assets[index].isEnabled != isEnabled else { return true }
        assets[index].isEnabled = isEnabled
        return saveAssets(assets)
    }

    public static func registerAllFontsIfNeeded() {
        preloadRuntimeCache(forceReload: true)
    }

    public static func fallbackPostScriptNames(for role: FontSemanticRole) -> [String] {
        ensureRuntimeCachePrepared()
        ensureRuntimeSettingsSynchronized()
        return withRuntimeSnapshot { snapshot in
            guard snapshot.isPrepared else { return [] }
            return snapshot.fallbackPostScriptNamesByRole[role] ?? []
        }
    }

    public static func resolvedPostScriptName(for role: FontSemanticRole) -> String? {
        ensureRuntimeCachePrepared()
        ensureRuntimeSettingsSynchronized()
        return withRuntimeSnapshot { snapshot in
            guard snapshot.isPrepared else { return nil }
            return snapshot.preferredPostScriptNameByRole[role]
        }
    }

    public static func adapterCacheToken() -> String {
        ensureRuntimeCachePrepared()
        ensureRuntimeSettingsSynchronized()
        return withRuntimeSnapshot { snapshot in
            let roleSignature = FontSemanticRole.allCases
                .map { role -> String in
                    let names = snapshot.fallbackPostScriptNamesByRole[role] ?? []
                    return "\(role.rawValue)=\(names.joined(separator: ","))"
                }
                .joined(separator: "|")
            return "\(snapshot.isPrepared ? 1 : 0)|\(snapshot.isCustomFontEnabled ? 1 : 0)|\(snapshot.fallbackScope.rawValue)|\(snapshot.customFontScale)|\(roleSignature)"
        }
    }

    public static func resolvePostScriptName(
        for role: FontSemanticRole,
        sampleText: String
    ) -> String? {
        ensureRuntimeCachePrepared()
        ensureRuntimeSettingsSynchronized()

        let context = withRuntimeSnapshot { snapshot in
            (
                isPrepared: snapshot.isPrepared,
                isCustomFontEnabled: snapshot.isCustomFontEnabled,
                fallbackScope: snapshot.fallbackScope,
                candidates: snapshot.fallbackPostScriptNamesByRole[role] ?? []
            )
        }
        guard context.isPrepared, context.isCustomFontEnabled else { return nil }
        let candidates = context.candidates
        guard !candidates.isEmpty else { return nil }

        let normalizedSample = normalizeSampleText(sampleText)
        let cacheKey = [
            role.rawValue,
            context.fallbackScope.rawValue,
            candidates.joined(separator: ","),
            normalizedSample
        ].joined(separator: "|")

        let cached = sampledResolution(forKey: cacheKey)
        if cached.hit {
            return cached.value
        }

        let resolved: String?
        switch context.fallbackScope {
        case .segment:
            resolved = resolveFontForSegmentFallback(
                candidates: candidates,
                normalizedSample: normalizedSample
            )
        case .character:
            resolved = resolveFontForCharacterFallback(
                candidates: candidates,
                normalizedSample: normalizedSample
            )
        }

        storeSampledResolution(resolved, forKey: cacheKey)
        return resolved
    }

    private static func sanitizeBaseName(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let mapped = trimmed.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        return String(mapped).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private static func uniqueFontFileName(baseName: String, fileExtension: String) -> String {
        var candidate = "\(baseName).\(fileExtension)"
        var counter = 1
        while FileManager.default.fileExists(atPath: Persistence.getFontDirectory().appendingPathComponent(candidate).path) {
            candidate = "\(baseName)-\(counter).\(fileExtension)"
            counter += 1
        }
        return candidate
    }

    private static func normalizeSampleText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Aa测试あア한ع" }
        let scalars = trimmed.unicodeScalars
            .filter { !$0.properties.isWhitespace && $0.properties.generalCategory != .control }
        let prefix = String(String.UnicodeScalarView(scalars.prefix(96)))
        return prefix.isEmpty ? "Aa测试あア한ع" : prefix
    }

    private static func resolveFontForSegmentFallback(
        candidates: [String],
        normalizedSample: String
    ) -> String? {
        for postScriptName in candidates {
            if fontCanRenderSample(postScriptName: postScriptName, sample: normalizedSample) {
                return postScriptName
            }
        }
        return nil
    }

    private static func resolveFontForCharacterFallback(
        candidates: [String],
        normalizedSample: String
    ) -> String? {
        _ = normalizedSample
        for postScriptName in candidates where !postScriptName.isEmpty {
#if canImport(CoreText)
            if createFontIfExists(postScriptName: postScriptName) != nil {
                return postScriptName
            }
#else
            return postScriptName
#endif
        }
        return nil
    }

    private static func registerFontFileIfNeeded(fileName: String) {
#if canImport(CoreText)
        let fileURL = Persistence.getFontDirectory().appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        var error: Unmanaged<CFError>?
        let registered = CTFontManagerRegisterFontsForURL(fileURL as CFURL, .process, &error)
        if !registered, let nsError = error?.takeRetainedValue() {
            fontLibraryLogger.warning("Failed to register font file \(fileName): \(nsError)")
        }
#else
        _ = fileName
#endif
    }

    private static func fontCanRenderSample(postScriptName: String, sample: String) -> Bool {
#if canImport(CoreText)
        guard !sample.isEmpty else { return true }
        guard let font = createFontIfExists(postScriptName: postScriptName) else { return false }
        let characters = sampleCharacters(sample)
        guard !characters.isEmpty else { return true }

        var mutableCharacters = characters
        var glyphs = Array(repeating: CGGlyph(), count: mutableCharacters.count)
        let mapped = CTFontGetGlyphsForCharacters(font, &mutableCharacters, &glyphs, mutableCharacters.count)
        return mapped && !glyphs.contains(0)
#else
        _ = postScriptName
        _ = sample
        return true
#endif
    }

    private static func sampleCharacters(_ sample: String) -> [UniChar] {
        let filteredScalars = sample.unicodeScalars.filter { scalar in
            !scalar.properties.isWhitespace && scalar.properties.generalCategory != .control
        }
        return filteredScalars.prefix(96).map { scalar -> UniChar in
            if scalar.value <= 0xFFFF {
                return UniChar(scalar.value)
            }
            return UniChar(0xFFFD)
        }
    }

    private static func createFontIfExists(postScriptName: String) -> CTFont? {
#if canImport(CoreText)
        let font = CTFontCreateWithName(postScriptName as CFString, 16, nil)
        let resolvedPostScriptName = CTFontCopyPostScriptName(font) as String
        guard resolvedPostScriptName.caseInsensitiveCompare(postScriptName) == .orderedSame else {
            return nil
        }
        return font
#else
        _ = postScriptName
        return nil
#endif
    }

    private static func ensureRuntimeCachePrepared() {
        if withRuntimeSnapshot({ !$0.isPrepared }) {
            preloadRuntimeCache(forceReload: false)
        }
    }

    private static func ensureRuntimeSettingsSynchronized() {
        let settings = loadFontSettingsFromUserDefaults()
        let needReload = withRuntimeSnapshot { snapshot in
            guard snapshot.isPrepared else { return false }
            return snapshot.isCustomFontEnabled != settings.isCustomFontEnabled
                || snapshot.fallbackScope != settings.fallbackScope
                || snapshot.customFontScale != settings.customFontScale
        }
        if needReload {
            preloadRuntimeCache(forceReload: true)
        }
    }

    private static func sampledResolution(forKey key: String) -> (hit: Bool, value: String?) {
        withRuntimeSnapshot { snapshot in
            guard let cached = snapshot.sampledResolutionCache[key] else {
                return (false, nil)
            }
            switch cached {
            case .resolved(let postScriptName):
                return (true, postScriptName)
            case .unresolved:
                return (true, nil)
            }
        }
    }

    private static func storeSampledResolution(_ value: String?, forKey key: String) {
        updateRuntimeSnapshot { snapshot in
            if snapshot.sampledResolutionCache.count >= sampledResolutionCacheLimit {
                snapshot.sampledResolutionCache.removeAll(keepingCapacity: true)
            }
            if let value {
                snapshot.sampledResolutionCache[key] = .resolved(value)
            } else {
                snapshot.sampledResolutionCache[key] = .unresolved
            }
        }
    }

    private static func withRuntimeSnapshot<T>(_ body: (RuntimeSnapshot) -> T) -> T {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return body(runtimeSnapshot)
    }

    private static func updateRuntimeSnapshot(_ body: (inout RuntimeSnapshot) -> Void) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        body(&runtimeSnapshot)
    }

    private static func loadAssetsFromDisk() -> [FontAssetRecord] {
        guard let data = try? Data(contentsOf: manifestURL),
              let assets = try? JSONDecoder().decode([FontAssetRecord].self, from: data) else {
            return []
        }
        return assets
    }

    private static func loadRouteConfigurationFromDisk() -> FontRouteConfiguration {
        guard let data = try? Data(contentsOf: routeConfigURL),
              let configuration = try? JSONDecoder().decode(FontRouteConfiguration.self, from: data) else {
            return FontRouteConfiguration()
        }
        return configuration
    }

    private static func loadFontSettingsFromAppConfig() -> (isCustomFontEnabled: Bool, fallbackScope: FontFallbackScope, customFontScale: Double) {
        let customEnabled = Persistence.readAppConfigInteger(key: AppConfigKey.fontUseCustomFonts.rawValue).map { $0 != 0 } ?? true
        let scope: FontFallbackScope
        if let rawValue = Persistence.readAppConfigText(key: AppConfigKey.fontFallbackScope.rawValue),
           let parsedScope = FontFallbackScope(rawValue: rawValue) {
            scope = parsedScope
        } else {
            scope = .segment
        }
        let scale = normalizedFontScale(Persistence.readAppConfigReal(key: AppConfigKey.fontCustomScale.rawValue) ?? defaultFontScale)
        return (customEnabled, scope, scale)
    }

    private static func buildRoleMappings(
        assets: [FontAssetRecord],
        routeConfiguration: FontRouteConfiguration,
        isCustomFontEnabled: Bool
    ) -> (fallback: [FontSemanticRole: [String]], preferred: [FontSemanticRole: String]) {
        guard isCustomFontEnabled else {
            return ([:], [:])
        }

        let enabledAssets = Dictionary(
            uniqueKeysWithValues: assets
                .filter(\.isEnabled)
                .map { ($0.id, $0) }
        )

        var fallbackByRole: [FontSemanticRole: [String]] = [:]
        var preferredByRole: [FontSemanticRole: String] = [:]

        for role in FontSemanticRole.allCases {
            let names = routeConfiguration
                .chain(for: role)
                .compactMap { enabledAssets[$0]?.postScriptName }
                .filter { !$0.isEmpty }
            fallbackByRole[role] = names
            if let first = names.first {
                preferredByRole[role] = first
            }
        }
        return (fallbackByRole, preferredByRole)
    }

    private static func extractPostScriptName(from data: Data) -> String? {
#if canImport(CoreText)
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromData(data as CFData) as? [CTFontDescriptor],
              let firstDescriptor = descriptors.first else {
            return nil
        }
        let postScriptName = CTFontDescriptorCopyAttribute(firstDescriptor, kCTFontNameAttribute) as? String
        if let postScriptName, !postScriptName.isEmpty {
            return postScriptName
        }
        let displayName = CTFontDescriptorCopyAttribute(firstDescriptor, kCTFontDisplayNameAttribute) as? String
        return displayName?.nonEmpty
#else
        _ = data
        return nil
#endif
    }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
