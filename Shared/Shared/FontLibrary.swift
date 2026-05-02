import Foundation
#if canImport(CoreText)
import CoreText
#endif

// MARK: - 字体资产与路由

public enum FontSemanticRole: String, Codable, CaseIterable, Identifiable {
    case body
    case emphasis
    case strong
    case code

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .body:
            return "正文"
        case .emphasis:
            return "斜体"
        case .strong:
            return "粗体"
        case .code:
            return "代码"
        }
    }
}

public enum FontFallbackScope: String, Codable, CaseIterable, Identifiable {
    /// 当前逻辑：以整段样本检测覆盖率，必须整段都可渲染才命中该字体。
    case segment
    /// 新逻辑：按单字回退，只要候选字体能覆盖样本中的任意字符即可命中。
    case character

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .segment:
            return "整段"
        case .character:
            return "单字"
        }
    }

    public var summary: String {
        switch self {
        case .segment:
            return "当前行为：一条文本里只要有字形缺失，就整段降级到下一优先级字体。"
        case .character:
            return "按单字回退：优先保留高优先级字体，缺失字形再由系统进行逐字回退。"
        }
    }
}

public struct FontAssetRecord: Codable, Identifiable, Equatable {
    public var id: UUID
    public var fileName: String
    public var checksum: String
    public var displayName: String
    public var postScriptName: String
    public var importedAt: Date
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        fileName: String,
        checksum: String,
        displayName: String,
        postScriptName: String,
        importedAt: Date = Date(),
        isEnabled: Bool = true
    ) {
        self.id = id
        self.fileName = fileName
        self.checksum = checksum
        self.displayName = displayName
        self.postScriptName = postScriptName
        self.importedAt = importedAt
        self.isEnabled = isEnabled
    }
}

public struct FontRouteConfiguration: Codable, Equatable {
    public struct LanguageBucketConfiguration: Codable, Equatable {
        public var body: [UUID]
        public var emphasis: [UUID]
        public var strong: [UUID]
        public var code: [UUID]

        public init(
            body: [UUID] = [],
            emphasis: [UUID] = [],
            strong: [UUID] = [],
            code: [UUID] = []
        ) {
            self.body = body
            self.emphasis = emphasis
            self.strong = strong
            self.code = code
        }
    }

    public var body: [UUID]
    public var emphasis: [UUID]
    public var strong: [UUID]
    public var code: [UUID]
    /// 预留字段：后续可扩展为按语言桶优先级配置
    public var languageBuckets: [String: LanguageBucketConfiguration]

    public init(
        body: [UUID] = [],
        emphasis: [UUID] = [],
        strong: [UUID] = [],
        code: [UUID] = [],
        languageBuckets: [String: LanguageBucketConfiguration] = [:]
    ) {
        self.body = body
        self.emphasis = emphasis
        self.strong = strong
        self.code = code
        self.languageBuckets = languageBuckets
    }

    public func chain(for role: FontSemanticRole) -> [UUID] {
        switch role {
        case .body:
            return body
        case .emphasis:
            return emphasis
        case .strong:
            return strong
        case .code:
            return code
        }
    }

    public mutating func setChain(_ ids: [UUID], for role: FontSemanticRole) {
        switch role {
        case .body:
            body = ids
        case .emphasis:
            emphasis = ids
        case .strong:
            strong = ids
        case .code:
            code = ids
        }
    }
}

public enum FontLibraryError: LocalizedError {
    case invalidFontData
    case unsupportedFontFileExtension
    case saveFailed
    case deleteFailed

    public var errorDescription: String? {
        switch self {
        case .invalidFontData:
            return "无法识别该字体文件。"
        case .unsupportedFontFileExtension:
            return "仅支持导入 TTF / OTF / TTC / WOFF / WOFF2 字体文件。"
        case .saveFailed:
            return "保存字体文件失败。"
        case .deleteFailed:
            return "删除字体文件失败。"
        }
    }
}

public enum FontLibrary {
    static let manifestFileName = "font-manifest-v1.json"
    static let routeConfigFileName = "font-routes-v1.json"
    static let supportedFontFileExtensions: Set<String> = ["ttf", "otf", "ttc", "woff", "woff2"]
    public static let customFontEnabledStorageKey = "font.useCustomFonts"
    public static let fallbackScopeStorageKey = "font.fallbackScope"
    public static let fontScaleStorageKey = "font.customScale"
    public static let minimumFontScale = 0.5
    public static let maximumFontScale = 2.0
    public static let defaultFontScale = 1.0
    public static let fontScaleStep = 0.05
    static let cacheLock = NSLock()
    static let sampledResolutionCacheLimit = 256

    enum FontResolutionCacheEntry {
        case resolved(String)
        case unresolved
    }

    struct RuntimeSnapshot {
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

    static var runtimeSnapshot = RuntimeSnapshot()

    static var manifestURL: URL {
        Persistence.getFontDirectory().appendingPathComponent(manifestFileName)
    }

    static var routeConfigURL: URL {
        Persistence.getFontDirectory().appendingPathComponent(routeConfigFileName)
    }

    /// 全局开关：是否启用自定义字体（默认启用）。
    public static var isCustomFontEnabled: Bool {
        ensureRuntimeCachePrepared()
        ensureRuntimeSettingsSynchronized()
        return withRuntimeSnapshot { $0.isCustomFontEnabled }
    }

    /// 字体回退范围设置（默认整段）。
    public static var fallbackScope: FontFallbackScope {
        ensureRuntimeCachePrepared()
        ensureRuntimeSettingsSynchronized()
        return withRuntimeSnapshot { $0.fallbackScope }
    }

    /// 自定义字体显示比例，用于校正不同字体视觉大小差异。
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
        let settings = loadFontSettingsFromUserDefaults()

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
            logger.error("Failed to save font manifest: \(error.localizedDescription)")
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
            logger.error("Failed to save font route configuration: \(error.localizedDescription)")
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
                logger.error("Failed to remove route config file: \(error.localizedDescription)")
                return false
            }
        }
        do {
            try data.write(to: routeConfigURL, options: [.atomic])
            preloadRuntimeCache(forceReload: true)
            return true
        } catch {
            logger.error("Failed to save route config data: \(error.localizedDescription)")
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

    /// 按优先级链路查找可用字体；若无命中则返回 nil 由系统字体兜底。
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

    static func sanitizeBaseName(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let mapped = trimmed.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let result = String(mapped).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return result
    }

    static func uniqueFontFileName(baseName: String, fileExtension: String) -> String {
        var candidate = "\(baseName).\(fileExtension)"
        var counter = 1
        while FileManager.default.fileExists(atPath: Persistence.getFontDirectory().appendingPathComponent(candidate).path) {
            candidate = "\(baseName)-\(counter).\(fileExtension)"
            counter += 1
        }
        return candidate
    }

    static func normalizeSampleText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Aa测试あア한ع" }
        let scalars = trimmed.unicodeScalars
            .filter { !$0.properties.isWhitespace && $0.properties.generalCategory != .control }
        let prefix = String(String.UnicodeScalarView(scalars.prefix(96)))
        return prefix.isEmpty ? "Aa测试あア한ع" : prefix
    }

    static func resolveFontForSegmentFallback(
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

    static func resolveFontForCharacterFallback(
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

    static func registerFontFileIfNeeded(fileName: String) {
#if canImport(CoreText)
        let fileURL = Persistence.getFontDirectory().appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        var error: Unmanaged<CFError>?
        let registered = CTFontManagerRegisterFontsForURL(fileURL as CFURL, .process, &error)
        if !registered, let nsError = error?.takeRetainedValue() {
            // 字体已注册等场景可继续运行，这里仅记录警告日志。
            logger.warning("Failed to register font file \(fileName): \(nsError)")
        }
#else
        _ = fileName
#endif
    }

    static func fontCanRenderSample(postScriptName: String, sample: String) -> Bool {
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

    static func sampleCharacters(_ sample: String) -> [UniChar] {
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

    static func createFontIfExists(postScriptName: String) -> CTFont? {
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

    static func ensureRuntimeCachePrepared() {
        if withRuntimeSnapshot({ !$0.isPrepared }) {
            preloadRuntimeCache(forceReload: false)
        }
    }

    static func ensureRuntimeSettingsSynchronized() {
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

    static func sampledResolution(forKey key: String) -> (hit: Bool, value: String?) {
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

    static func storeSampledResolution(_ value: String?, forKey key: String) {
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

    static func withRuntimeSnapshot<T>(_ body: (RuntimeSnapshot) -> T) -> T {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return body(runtimeSnapshot)
    }

    static func updateRuntimeSnapshot(_ body: (inout RuntimeSnapshot) -> Void) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        body(&runtimeSnapshot)
    }

    static func loadAssetsFromDisk() -> [FontAssetRecord] {
        guard let data = try? Data(contentsOf: manifestURL),
              let assets = try? JSONDecoder().decode([FontAssetRecord].self, from: data) else {
            return []
        }
        return assets
    }

    static func loadRouteConfigurationFromDisk() -> FontRouteConfiguration {
        guard let data = try? Data(contentsOf: routeConfigURL),
              let configuration = try? JSONDecoder().decode(FontRouteConfiguration.self, from: data) else {
            return FontRouteConfiguration()
        }
        return configuration
    }

    static func loadFontSettingsFromUserDefaults() -> (isCustomFontEnabled: Bool, fallbackScope: FontFallbackScope, customFontScale: Double) {
        let customEnabled = (UserDefaults.standard.object(forKey: customFontEnabledStorageKey) as? Bool) ?? true
        let scope: FontFallbackScope
        if let rawValue = UserDefaults.standard.string(forKey: fallbackScopeStorageKey),
           let parsedScope = FontFallbackScope(rawValue: rawValue) {
            scope = parsedScope
        } else {
            scope = .segment
        }
        let scale = normalizedFontScale((UserDefaults.standard.object(forKey: fontScaleStorageKey) as? Double) ?? defaultFontScale)
        return (customEnabled, scope, scale)
    }

    static func buildRoleMappings(
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

    static func extractPostScriptName(from data: Data) -> String? {
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

extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
