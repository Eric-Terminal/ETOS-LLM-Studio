// ============================================================================
// ContentViewFontSupport.swift
// ============================================================================
// ETOS LLM Studio iOS 根视图字体与通知辅助逻辑
// ============================================================================

import SwiftUI
import Foundation
import ETOSCore
#if canImport(UIKit)
import UIKit
#endif
#if canImport(CoreText)
import CoreText
#endif

extension Notification.Name {
    static let requestSwitchToChatTab = Notification.Name("ios.requestSwitchToChatTab")
}

extension View {
    @ViewBuilder
    func etFont(_ font: Font?) -> some View {
        if let font {
            self.font(AppFontAdapter.adaptedFont(from: font))
        } else {
            self.font(nil)
        }
    }

    @ViewBuilder
    func etFont(_ font: Font) -> some View {
        self.font(AppFontAdapter.adaptedFont(from: font))
    }

    @ViewBuilder
    func etFont(_ font: Font?, sampleText: String?) -> some View {
        if let font {
            self.font(AppFontAdapter.adaptedFont(from: font, sampleText: sampleText))
        } else {
            self.font(nil)
        }
    }

    @ViewBuilder
    func etFont(_ font: Font, sampleText: String?) -> some View {
        self.font(AppFontAdapter.adaptedFont(from: font, sampleText: sampleText))
    }
}

extension Text {
    @ViewBuilder
    func etFont(_ font: Font?) -> some View {
        if let font {
            self.font(AppFontAdapter.adaptedFont(from: font, sampleText: TextSampleExtractor.extract(from: self)))
        } else {
            self.font(nil)
        }
    }

    @ViewBuilder
    func etFont(_ font: Font) -> some View {
        self.font(AppFontAdapter.adaptedFont(from: font, sampleText: TextSampleExtractor.extract(from: self)))
    }
}

private enum TextSampleExtractor {
    private static let maxDepth = 10

    static func extract(from text: Text) -> String? {
        let strings = collectStrings(from: text, depth: 0)
        guard !strings.isEmpty else { return nil }

        var ordered: [String] = []
        var seen = Set<String>()
        for item in strings {
            let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if seen.insert(trimmed).inserted {
                ordered.append(trimmed)
            }
        }

        guard !ordered.isEmpty else { return nil }
        return ordered.joined(separator: " ")
    }

    private static func collectStrings(from value: Any, depth: Int) -> [String] {
        guard depth <= maxDepth else { return [] }

        if let string = value as? String {
            return [string]
        }

        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            guard let childValue = mirror.children.first?.value else { return [] }
            return collectStrings(from: childValue, depth: depth + 1)
        }

        var results: [String] = []
        for child in mirror.children {
            if shouldSkip(label: child.label) {
                continue
            }
            results.append(contentsOf: collectStrings(from: child.value, depth: depth + 1))
        }
        return results
    }

    private static func shouldSkip(label: String?) -> Bool {
        switch label {
        case "modifiers", "table", "bundle", "arguments", "hasFormatting":
            return true
        default:
            return false
        }
    }
}

enum AppFontAdapter {
    private static let cacheLock = NSLock()
    private static var adaptedFontCache: [String: Font] = [:]
    private static var adaptedFontCacheToken: String = ""

    static func adaptedFont(from original: Font, sampleText: String? = nil) -> Font {
        let descriptor = FontDescriptorInfo(font: original)
        let role = inferredRole(from: descriptor)
        let resolvedSample = resolvedSampleText(for: role, override: sampleText)
        let cacheKey = "\(descriptor.cacheSignature)|\(role.rawValue)|\(resolvedSample)"
        let cacheToken = FontLibrary.adapterCacheToken()

        guard let postScriptName = FontLibrary.resolvePostScriptName(for: role, sampleText: resolvedSample) else {
            // 系统字体也要应用用户倍率；不缓存该分支，让 Dynamic Type 变化后重新取系统度量。
            return mappedSystemFont(original: original, descriptor: descriptor)
        }

        if let cached = cachedFont(for: cacheKey, cacheToken: cacheToken) {
            return cached
        }

        let fallbackPostScriptNames = FontLibrary.fallbackPostScriptNames(for: role)
        let mapped = mappedFont(
            postScriptName: postScriptName,
            descriptor: descriptor,
            fallbackPostScriptNames: fallbackPostScriptNames
        )
        storeAdaptedFont(mapped, for: cacheKey, cacheToken: cacheToken)
        return mapped
    }

    private static func mappedSystemFont(original: Font, descriptor: FontDescriptorInfo) -> Font {
        let fontScale = CGFloat(FontLibrary.customFontScale)
        guard abs(fontScale - CGFloat(FontLibrary.defaultFontScale)) > 0.001 else {
            return original
        }

        let pointSize: CGFloat
        if let explicitSize = descriptor.explicitSize {
            pointSize = explicitSize * fontScale
        } else if let textStyle = descriptor.textStyle {
            pointSize = defaultPointSize(for: textStyle) * fontScale
        } else {
            pointSize = 17 * fontScale
        }

#if canImport(UIKit)
        let weight = descriptor.weight ?? defaultSystemWeight(for: descriptor.textStyle)
        var systemDescriptor = UIFont.systemFont(
            ofSize: pointSize,
            weight: UIFont.Weight(rawValue: uiFontWeightValue(weight))
        ).fontDescriptor
        if let design = uiSystemDesign(for: descriptor.resolvedDesign),
           let designedDescriptor = systemDescriptor.withDesign(design) {
            systemDescriptor = designedDescriptor
        }
        if descriptor.isItalic,
           let italicDescriptor = systemDescriptor.withSymbolicTraits(.traitItalic) {
            systemDescriptor = italicDescriptor
        }

        let uiFont = UIFont(descriptor: systemDescriptor, size: pointSize)
        if let textStyle = descriptor.textStyle {
            return Font(
                UIFontMetrics(forTextStyle: uiTextStyle(for: textStyle))
                    .scaledFont(for: uiFont)
            )
        }
        return Font(uiFont)
#else
        var mapped = Font.system(
            size: pointSize,
            weight: descriptor.weight ?? defaultSystemWeight(for: descriptor.textStyle),
            design: descriptor.resolvedDesign
        )
        if descriptor.isItalic {
            mapped = mapped.italic()
        }
        return mapped
#endif
    }

    private static func resolvedSampleText(for role: FontSemanticRole, override sampleText: String?) -> String {
        if let sampleText {
            let trimmed = sampleText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let scalars = trimmed.unicodeScalars.filter {
                    !$0.properties.isWhitespace && $0.properties.generalCategory != .control
                }
                let prefix = String(String.UnicodeScalarView(scalars.prefix(96)))
                if !prefix.isEmpty {
                    return prefix
                }
            }
        }
        return self.sampleText(for: role)
    }

    private static func inferredRole(from descriptor: FontDescriptorInfo) -> FontSemanticRole {
        if descriptor.isMonospaced {
            return .code
        }
        if descriptor.isItalic {
            return .emphasis
        }
        if let weight = descriptor.weight, weightStrength(weight) >= weightStrength(.semibold) {
            return .strong
        }
        return .body
    }

    private static func mappedFont(
        postScriptName: String,
        descriptor: FontDescriptorInfo,
        fallbackPostScriptNames: [String]
    ) -> Font {
        if FontLibrary.fallbackScope == .character {
            let fallbackChain = fallbackPostScriptNames.filter {
                !$0.isEmpty && $0.caseInsensitiveCompare(postScriptName) != .orderedSame
            }
            if let cascaded = mappedFontWithCascade(
                primaryPostScriptName: postScriptName,
                fallbackPostScriptNames: fallbackChain,
                descriptor: descriptor
            ) {
                return cascaded
            }
        }

        var mapped: Font
        if let explicitSize = descriptor.explicitSize {
            mapped = .custom(postScriptName, size: scaledPointSize(explicitSize))
        } else if let textStyle = descriptor.textStyle {
            mapped = .custom(
                postScriptName,
                size: scaledPointSize(defaultPointSize(for: textStyle)),
                relativeTo: textStyle
            )
        } else {
            mapped = .custom(postScriptName, size: scaledPointSize(17), relativeTo: .body)
        }

        if descriptor.isItalic {
            mapped = mapped.italic()
        }
        if let weight = descriptor.weight {
            mapped = mapped.weight(weight)
        }
        return mapped
    }

    private static func resolvedPointSize(for descriptor: FontDescriptorInfo) -> CGFloat {
        if let explicitSize = descriptor.explicitSize {
            return scaledPointSize(explicitSize)
        }
        if let textStyle = descriptor.textStyle {
            return scaledPointSize(defaultPointSize(for: textStyle))
        }
        return scaledPointSize(17)
    }

    private static func scaledPointSize(_ pointSize: CGFloat) -> CGFloat {
        pointSize * CGFloat(FontLibrary.customFontScale)
    }

    private static func mappedFontWithCascade(
        primaryPostScriptName: String,
        fallbackPostScriptNames: [String],
        descriptor: FontDescriptorInfo
    ) -> Font? {
#if canImport(UIKit) && canImport(CoreText)
        guard !fallbackPostScriptNames.isEmpty else { return nil }
        let pointSize = resolvedPointSize(for: descriptor)
        guard UIFont(name: primaryPostScriptName, size: pointSize) != nil else { return nil }

        let cascadeDescriptors = fallbackPostScriptNames.compactMap { candidate -> CTFontDescriptor? in
            guard UIFont(name: candidate, size: pointSize) != nil else { return nil }
            return CTFontDescriptorCreateWithNameAndSize(candidate as CFString, pointSize)
        }
        guard !cascadeDescriptors.isEmpty else { return nil }

        let cascadeKey = UIFontDescriptor.AttributeName(rawValue: kCTFontCascadeListAttribute as String)
        var descriptorAttributes: [UIFontDescriptor.AttributeName: Any] = [
            .name: primaryPostScriptName,
            .size: pointSize,
            cascadeKey: cascadeDescriptors
        ]

        if let weight = descriptor.weight {
            descriptorAttributes[.traits] = [
                UIFontDescriptor.TraitKey.weight: uiFontWeightValue(weight)
            ]
        }

        var uiFontDescriptor = UIFontDescriptor(fontAttributes: descriptorAttributes)
        if descriptor.isItalic,
           let italicDescriptor = uiFontDescriptor.withSymbolicTraits(.traitItalic) {
            uiFontDescriptor = italicDescriptor
        }

        let uiFont = UIFont(descriptor: uiFontDescriptor, size: pointSize)
        return Font(uiFont)
#else
        _ = primaryPostScriptName
        _ = fallbackPostScriptNames
        _ = descriptor
        return nil
#endif
    }

    private static func uiFontWeightValue(_ weight: Font.Weight) -> CGFloat {
        switch weight {
        case .ultraLight:
            return UIFont.Weight.ultraLight.rawValue
        case .thin:
            return UIFont.Weight.thin.rawValue
        case .light:
            return UIFont.Weight.light.rawValue
        case .regular:
            return UIFont.Weight.regular.rawValue
        case .medium:
            return UIFont.Weight.medium.rawValue
        case .semibold:
            return UIFont.Weight.semibold.rawValue
        case .bold:
            return UIFont.Weight.bold.rawValue
        case .heavy:
            return UIFont.Weight.heavy.rawValue
        case .black:
            return UIFont.Weight.black.rawValue
        default:
            return UIFont.Weight.regular.rawValue
        }
    }

    private static func defaultSystemWeight(for textStyle: Font.TextStyle?) -> Font.Weight {
        textStyle == .headline ? .semibold : .regular
    }

#if canImport(UIKit)
    private static func uiTextStyle(for textStyle: Font.TextStyle) -> UIFont.TextStyle {
        switch textStyle {
        case .largeTitle: return .largeTitle
        case .title: return .title1
        case .title2: return .title2
        case .title3: return .title3
        case .headline: return .headline
        case .subheadline: return .subheadline
        case .body: return .body
        case .callout: return .callout
        case .footnote: return .footnote
        case .caption: return .caption1
        case .caption2: return .caption2
        @unknown default: return .body
        }
    }

    private static func uiSystemDesign(for design: Font.Design) -> UIFontDescriptor.SystemDesign? {
        switch design {
        case .default: return .default
        case .serif: return .serif
        case .rounded: return .rounded
        case .monospaced: return .monospaced
        @unknown default: return nil
        }
    }
#endif

    private static func sampleText(for role: FontSemanticRole) -> String {
        switch role {
        case .body:
            return "The quick brown fox 你好こんにちは"
        case .emphasis:
            return "Emphasis 斜体预览 こんにちは"
        case .strong:
            return "Strong 粗体预览 こんにちは"
        case .code:
            return "let value = 42 // 代码"
        }
    }

    private static func defaultPointSize(for textStyle: Font.TextStyle) -> CGFloat {
        switch textStyle {
        case .largeTitle:
            return 34
        case .title:
            return 28
        case .title2:
            return 22
        case .title3:
            return 20
        case .headline:
            return 17
        case .subheadline:
            return 15
        case .body:
            return 17
        case .callout:
            return 16
        case .footnote:
            return 13
        case .caption:
            return 12
        case .caption2:
            return 11
        @unknown default:
            return 17
        }
    }

    private static func weightStrength(_ weight: Font.Weight) -> Int {
        switch weight {
        case .ultraLight:
            return 1
        case .thin:
            return 2
        case .light:
            return 3
        case .regular:
            return 4
        case .medium:
            return 5
        case .semibold:
            return 6
        case .bold:
            return 7
        case .heavy:
            return 8
        case .black:
            return 9
        default:
            return 4
        }
    }

    private static func cachedFont(for key: String, cacheToken: String) -> Font? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if adaptedFontCacheToken != cacheToken {
            adaptedFontCacheToken = cacheToken
            adaptedFontCache.removeAll(keepingCapacity: true)
        }
        return adaptedFontCache[key]
    }

    private static func storeAdaptedFont(_ font: Font, for key: String, cacheToken: String) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if adaptedFontCacheToken != cacheToken {
            adaptedFontCacheToken = cacheToken
            adaptedFontCache.removeAll(keepingCapacity: true)
        }
        adaptedFontCache[key] = font
    }
}

private struct FontDescriptorInfo {
    let raw: String
    let lowercasedRaw: String
    private let mirroredExplicitSize: CGFloat?
    private let mirroredTextStyle: Font.TextStyle?
    private let mirroredDesign: Font.Design?
    private let mirroredWeight: Font.Weight?
    private let mirroredIsItalic: Bool
    private let mirroredIsMonospaced: Bool

    init(font: Font) {
        let rawDescription = String(reflecting: font)
        let snapshot = Self.mirrorSnapshot(from: font)
        raw = rawDescription
        lowercasedRaw = rawDescription.lowercased()
        mirroredExplicitSize = snapshot.explicitSize
        mirroredTextStyle = snapshot.textStyle
        mirroredDesign = snapshot.design
        mirroredWeight = snapshot.weight
        mirroredIsItalic = snapshot.isItalic
        mirroredIsMonospaced = snapshot.isMonospaced
    }

    var cacheSignature: String {
        [
            raw,
            explicitSize.map { String(format: "%.4f", Double($0)) } ?? "dynamic",
            textStyle.map { Self.textStyleName($0) } ?? "none",
            Self.designName(resolvedDesign),
            weight.map { Self.weightName($0) } ?? "regular",
            isItalic ? "italic" : "upright",
            isMonospaced ? "monospaced" : "proportional"
        ].joined(separator: "|")
    }

    var explicitSize: CGFloat? {
        mirroredExplicitSize
            ?? firstMatchedNumber(after: "size:")
            ?? firstMatchedNumber(after: "size ")
    }

    var textStyle: Font.TextStyle? {
        if let mirroredTextStyle { return mirroredTextStyle }
        if lowercasedRaw.contains("caption2") { return .caption2 }
        if lowercasedRaw.contains("caption") { return .caption }
        if lowercasedRaw.contains("footnote") { return .footnote }
        if lowercasedRaw.contains("callout") { return .callout }
        if lowercasedRaw.contains("subheadline") { return .subheadline }
        if lowercasedRaw.contains("headline") { return .headline }
        if lowercasedRaw.contains("title3") { return .title3 }
        if lowercasedRaw.contains("title2") { return .title2 }
        if lowercasedRaw.contains("largetitle") || lowercasedRaw.contains("large title") { return .largeTitle }
        if lowercasedRaw.contains("title") { return .title }
        if lowercasedRaw.contains("body") { return .body }
        return nil
    }

    var isItalic: Bool {
        mirroredIsItalic || lowercasedRaw.contains("italic")
    }

    var isMonospaced: Bool {
        mirroredIsMonospaced || lowercasedRaw.contains("monospaced") || lowercasedRaw.contains("mono")
    }

    var design: Font.Design? {
        mirroredDesign
    }

    var resolvedDesign: Font.Design {
        if let design { return design }
        return isMonospaced ? .monospaced : .default
    }

    var weight: Font.Weight? {
        if let mirroredWeight { return mirroredWeight }
        if lowercasedRaw.contains("black") { return .black }
        if lowercasedRaw.contains("heavy") { return .heavy }
        if lowercasedRaw.contains("semibold") { return .semibold }
        if lowercasedRaw.contains("bold") { return .bold }
        if lowercasedRaw.contains("medium") { return .medium }
        if lowercasedRaw.contains("light") { return .light }
        if lowercasedRaw.contains("thin") { return .thin }
        if lowercasedRaw.contains("ultralight") || lowercasedRaw.contains("ultra light") { return .ultraLight }
        return nil
    }

    private struct MirrorSnapshot {
        var explicitSize: CGFloat?
        var textStyle: Font.TextStyle?
        var design: Font.Design?
        var weight: Font.Weight?
        var isItalic = false
        var isMonospaced = false
    }

    private static func mirrorSnapshot(from font: Font) -> MirrorSnapshot {
        var snapshot = MirrorSnapshot()
        inspect(font, label: nil, depth: 0, snapshot: &snapshot)
        return snapshot
    }

    private static func inspect(
        _ value: Any,
        label: String?,
        depth: Int,
        snapshot: inout MirrorSnapshot
    ) {
        guard depth <= 12 else { return }

        if label == "size", snapshot.explicitSize == nil {
            if let size = value as? CGFloat {
                snapshot.explicitSize = size
            } else if let size = value as? Double {
                snapshot.explicitSize = CGFloat(size)
            }
        }
        if let textStyle = value as? Font.TextStyle {
            snapshot.textStyle = textStyle
        }
        if let design = value as? Font.Design {
            snapshot.design = design
            if case .monospaced = design {
                snapshot.isMonospaced = true
            }
        }
        if let weight = value as? Font.Weight {
            snapshot.weight = weight
        }

        let typeName = String(reflecting: type(of: value)).lowercased()
        if typeName.contains("italicmodifier") {
            snapshot.isItalic = true
        }
        if typeName.contains("monospacedmodifier") {
            snapshot.isMonospaced = true
        }
        if typeName.contains("boldmodifier"), snapshot.weight == nil {
            snapshot.weight = .bold
        }

        for child in Mirror(reflecting: value).children {
            inspect(
                child.value,
                label: child.label,
                depth: depth + 1,
                snapshot: &snapshot
            )
        }
    }

    private static func textStyleName(_ textStyle: Font.TextStyle) -> String {
        switch textStyle {
        case .largeTitle: return "largeTitle"
        case .title: return "title"
        case .title2: return "title2"
        case .title3: return "title3"
        case .headline: return "headline"
        case .subheadline: return "subheadline"
        case .body: return "body"
        case .callout: return "callout"
        case .footnote: return "footnote"
        case .caption: return "caption"
        case .caption2: return "caption2"
        @unknown default: return "body"
        }
    }

    private static func designName(_ design: Font.Design) -> String {
        switch design {
        case .default: return "default"
        case .serif: return "serif"
        case .rounded: return "rounded"
        case .monospaced: return "monospaced"
        @unknown default: return "unknown"
        }
    }

    private static func weightName(_ weight: Font.Weight) -> String {
        switch weight {
        case .ultraLight: return "ultraLight"
        case .thin: return "thin"
        case .light: return "light"
        case .regular: return "regular"
        case .medium: return "medium"
        case .semibold: return "semibold"
        case .bold: return "bold"
        case .heavy: return "heavy"
        case .black: return "black"
        default: return "regular"
        }
    }

    private func firstMatchedNumber(after marker: String) -> CGFloat? {
        guard let markerRange = lowercasedRaw.range(of: marker) else { return nil }
        var cursor = markerRange.upperBound
        var digits = ""
        var hasStarted = false

        while cursor < lowercasedRaw.endIndex {
            let character = lowercasedRaw[cursor]
            if character.isNumber || character == "." {
                digits.append(character)
                hasStarted = true
            } else if hasStarted {
                break
            }
            cursor = lowercasedRaw.index(after: cursor)
        }

        guard !digits.isEmpty, let value = Double(digits) else { return nil }
        return CGFloat(value)
    }
}
