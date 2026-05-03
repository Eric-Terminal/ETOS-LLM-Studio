// ============================================================================
// WatchContentFontSupport.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件负责 watchOS 主界面的自定义字体映射、语义推断与字体回退链。
// ============================================================================

import SwiftUI
import Foundation
import Shared
#if canImport(UIKit)
import UIKit
#endif
#if canImport(CoreText)
import CoreText
#endif

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
        let rawDescriptor = String(describing: original)
        let descriptor = FontDescriptorInfo(rawDescription: rawDescriptor)
        let role = inferredRole(from: descriptor)
        let resolvedSample = resolvedSampleText(for: role, override: sampleText)
        let cacheKey = "\(rawDescriptor)|\(role.rawValue)|\(resolvedSample)"
        let cacheToken = FontLibrary.adapterCacheToken()

        if let cached = cachedFont(for: cacheKey, cacheToken: cacheToken) {
            return cached
        }

        guard let postScriptName = FontLibrary.resolvePostScriptName(for: role, sampleText: resolvedSample) else {
            storeAdaptedFont(original, for: cacheKey, cacheToken: cacheToken)
            return original
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
            mapped = .custom(postScriptName, size: scaledPointSize(15), relativeTo: .body)
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
        return scaledPointSize(15)
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
            return 15
        case .callout:
            return 16
        case .footnote:
            return 13
        case .caption:
            return 12
        case .caption2:
            return 11
        @unknown default:
            return 15
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

    init(rawDescription: String) {
        self.raw = rawDescription
        self.lowercasedRaw = rawDescription.lowercased()
    }

    var explicitSize: CGFloat? {
        firstMatchedNumber(after: "size:")
            ?? firstMatchedNumber(after: "size ")
    }

    var textStyle: Font.TextStyle? {
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
        lowercasedRaw.contains("italic")
    }

    var isMonospaced: Bool {
        lowercasedRaw.contains("monospaced") || lowercasedRaw.contains("mono")
    }

    var weight: Font.Weight? {
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
